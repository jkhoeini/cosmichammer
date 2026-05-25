import Cocoa
import Foundation
import LuaSkin
import AudioToolbox

// MARK: - Constants

private let NUM_BUFFERS = 1
private let kSampleRate: Int32 = 44100

private let USERDATA_TAG = "hs.noises"
private var refTable: LSRefTable = LUA_NOREF

// MARK: - C++ interop (extern "C" functions from detectors.h / detectors.cpp)
//
// The detectors library is compiled as C++ in the HSExtensions target.
// detectors.h exposes these three functions with extern "C" linkage.
// Since the HSSwiftExtensions target cannot include C headers directly,
// we forward-declare them here.  They resolve at link time because both
// targets are linked into the same binary.

// detectors_t is typedef'd as void in detectors.h -- OpaquePointer in Swift.
@_silgen_name("detectors_new")
private func detectors_new() -> OpaquePointer

@_silgen_name("detectors_free")
private func detectors_free(_ detectors: OpaquePointer?)

@_silgen_name("detectors_process")
private func detectors_process(_ detectors: OpaquePointer?, _ buffer: UnsafePointer<Float>?) -> Int32

// Constants from detectors.h
private let DETECTORS_BLOCK_SIZE: Int32 = 512
private let TSS_START_CODE: Int32 = 1
private let TSS_STOP_CODE: Int32 = 2
private let POP_CODE: Int32 = 4

// MARK: - RecordState

private struct RecordState {
    var dataFormat = AudioStreamBasicDescription()
    var queue: AudioQueueRef?
    var buffers: [AudioQueueBufferRef?] = Array(repeating: nil, count: NUM_BUFFERS)
    var audioFile: AudioFileID?
    var currentFrame: UInt64 = 0
    var recording: Bool = false
}

// MARK: - AudioInputCallback

private func audioInputCallback(
    inUserData: UnsafeMutableRawPointer?,
    inAQ: AudioQueueRef,
    inBuffer: AudioQueueBufferRef,
    inStartTime: UnsafePointer<AudioTimeStamp>,
    inNumberPacketDescriptions: UInt32,
    inPacketDescs: UnsafePointer<AudioStreamPacketDescription>?
) {
    guard let userData = inUserData else { return }
    let rec = Unmanaged<NoisesListener>.fromOpaque(userData).takeUnretainedValue()
    guard rec.recordState.recording else { return }

    AudioQueueEnqueueBuffer(rec.recordState.queue!, inBuffer, 0, nil)
    rec.feedSamples(toEngine: inBuffer.pointee.mAudioDataBytesCapacity,
                    audioData: inBuffer.pointee.mAudioData)
}

// MARK: - NoisesListener

/// The listener class that owns the audio queue and detectors engine.
/// Named NoisesListener (rather than Listener) to avoid symbol collisions
/// with the ObjC Listener class in the same linkage unit.
private class NoisesListener: NSObject {
    var fn: Int32 = LUA_NOREF
    var recordState = RecordState()
    private var detectors: OpaquePointer?

    func initPlugins() -> NoisesListener {
        self.fn = LUA_NOREF
        recordState.recording = false
        detectors = detectors_new()
        return self
    }

    deinit {
        stopRecording()
        if let d = detectors {
            detectors_free(d)
        }
    }

    func setupAudioFormat(_ format: inout AudioStreamBasicDescription) {
        format.mSampleRate = Float64(kSampleRate)
        format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked
        format.mFramesPerPacket = 1
        format.mChannelsPerFrame = 1
        format.mBytesPerFrame = UInt32(MemoryLayout<Float>.size)
        format.mBytesPerPacket = UInt32(MemoryLayout<Float>.size)
        format.mBitsPerChannel = UInt32(MemoryLayout<Float>.size * 8)
    }

    func startRecording() {
        if recordState.recording { return }
        setupAudioFormat(&recordState.dataFormat)

        recordState.currentFrame = 0

        let status = AudioQueueNewInput(
            &recordState.dataFormat,
            audioInputCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            CFRunLoopMode.commonModes.rawValue,
            0,
            &recordState.queue
        )

        if status == 0 {
            for i in 0..<NUM_BUFFERS {
                AudioQueueAllocateBuffer(
                    recordState.queue!,
                    UInt32(DETECTORS_BLOCK_SIZE) * UInt32(MemoryLayout<Float>.size),
                    &recordState.buffers[i]
                )
                AudioQueueEnqueueBuffer(recordState.queue!, recordState.buffers[i]!, 0, nil)
            }

            recordState.recording = true
            AudioQueueStart(recordState.queue!, nil)
        } else {
            NSLog("Error: Couldn't open audio queue.")
        }
    }

    func stopRecording() {
        if !recordState.recording { return }
        recordState.recording = false

        AudioQueueStop(recordState.queue!, true)

        for i in 0..<NUM_BUFFERS {
            if let buffer = recordState.buffers[i] {
                AudioQueueFreeBuffer(recordState.queue!, buffer)
            }
        }

        AudioQueueDispose(recordState.queue!, true)
        if let audioFile = recordState.audioFile {
            AudioFileClose(audioFile)
        }
    }

    func mainThreadCallback(_ evNumber: Int) {
        performSelector(onMainThread: #selector(runCallback(withEvent:)),
                        with: NSNumber(value: evNumber),
                        waitUntilDone: false)
    }

    func feedSamples(toEngine audioDataBytesCapacity: UInt32, audioData: UnsafeMutableRawPointer) {
        let sampleCount = Int(audioDataBytesCapacity) / MemoryLayout<Float>.size
        let samples = audioData.assumingMemoryBound(to: Float.self)
        assert(sampleCount == Int(DETECTORS_BLOCK_SIZE), "Incorrect buffer size \(sampleCount)")

        let result = detectors_process(detectors, samples)
        if (result & TSS_START_CODE) == TSS_START_CODE {
            mainThreadCallback(1) // Tss on
        }
        if (result & TSS_STOP_CODE) == TSS_STOP_CODE {
            mainThreadCallback(2) // Tss off
        }
        if (result & POP_CODE) == POP_CODE {
            mainThreadCallback(3) // Pop
        }

        recordState.currentFrame += UInt64(sampleCount)
    }

    @objc func runCallback(withEvent evNumber: NSNumber) {
        if fn != LUA_NOREF {
            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            _lua_stackguard_entry(L)
            skin.pushLuaRef(refTable, ref: fn)
            lua_pushinteger(L, lua_Integer(evNumber.intValue))
            skin.protectedCallAndError("hs.noises callback", nargs: 1, nresults: 0)
            _lua_stackguard_exit(L)
        }
    }
}

// MARK: - Lua functions

private let noises_listener_gc: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    let userdata = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = userdata.pointee {
        let listener = Unmanaged<NoisesListener>.fromOpaque(rawPtr).takeRetainedValue()
        listener.stopRecording()
        listener.fn = skin.luaUnref(refTable, ref: listener.fn)
        userdata.pointee = nil
    }
    return 0
}

/// hs.noises:stop() -> self
/// Method
/// Stops the listener from recording and analyzing microphone input.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.noises` object
private let noises_listener_stop: lua_CFunction = { L in
    let userdata = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let listener = Unmanaged<NoisesListener>.fromOpaque(userdata.pointee!).takeUnretainedValue()
    listener.stopRecording()
    lua_settop(L, 1)
    return 1
}

/// hs.noises:start() -> self
/// Method
/// Starts listening to the microphone and passing the audio to the recognizer.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.noises` object
private let noises_listener_start: lua_CFunction = { L in
    let userdata = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let listener = Unmanaged<NoisesListener>.fromOpaque(userdata.pointee!).takeUnretainedValue()
    listener.startRecording()
    lua_settop(L, 1)
    return 1
}

private let noises_listener_eq: lua_CFunction = { L in
    let udA = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let udB = luaL_checkudata(L, 2, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    lua_pushboolean(L, udA.pointee == udB.pointee ? 1 : 0)
    return 1
}

private func noises_new_listener(_ L: UnsafeMutablePointer<lua_State>!, _ listener: NoisesListener) {
    let listenptr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    listenptr.pointee = Unmanaged.passRetained(listener).toOpaque()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
}

/// hs.noises.new(fn) -> listener
/// Constructor
/// Creates a new listener for mouth noise recognition
///
/// Parameters:
///  * A function that is called when a mouth noise is recognized. It should accept a single parameter which will be a number representing the event type (see module docs).
///
/// Returns:
///  * An `hs.noises` object
private let noises_listener_new: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TFUNCTION, LS_TBREAK)

    let listener = NoisesListener().initPlugins()

    lua_pushvalue(L, 1)
    listener.fn = skin.luaRef(refTable)
    noises_new_listener(L, listener)
    return 1
}

private let noises_meta_gc: lua_CFunction = { _ in
    return 0
}

// MARK: - Lua registration tables

// Metatable for created objects when _new invoked
private var noises_metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"),  func: noises_listener_start),
    luaL_Reg(name: strdup("stop"),   func: noises_listener_stop),
    luaL_Reg(name: strdup("__gc"),   func: noises_listener_gc),
    luaL_Reg(name: strdup("__eq"),   func: noises_listener_eq),
    luaL_Reg(name: nil,              func: nil),
]

// Functions for returned object when module loads
private var noisesLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"),  func: noises_listener_new),
    luaL_Reg(name: nil,            func: nil),
]

// Metatable for returned object when module loads
private var noises_meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: noises_meta_gc),
    luaL_Reg(name: nil,            func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libnoises")
public func luaopen_hs_libnoises(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &noisesLib,
                                    metaFunctions: &noises_meta_gcLib,
                                    objectFunctions: &noises_metalib)
    return 1
}
