import Foundation
import HSDSTCore

public final class SimulatedSpeech: SpeechProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var synthesizers: [UInt64: SpeechSynthesizerHandle] = [:]
    public var spokenTexts: [(synthesizerID: UInt64, text: String)] = []
    public var voices: [VoiceInfo] = [
        VoiceInfo(id: "com.apple.speech.synthesis.voice.Alex", name: "Alex", language: "en_US", gender: "male"),
        VoiceInfo(id: "com.apple.speech.synthesis.voice.Samantha", name: "Samantha", language: "en_US", gender: "female"),
        VoiceInfo(id: "com.apple.speech.synthesis.voice.Daniel", name: "Daniel", language: "en_GB", gender: "male"),
    ]

    private var nextID: UInt64 = 1
    private var listeners: [UInt64: (commands: [String], callback: (String) -> Void)] = [:]

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func availableVoices() -> [VoiceInfo] { voices }

    public func createSynthesizer(voice: String?) -> UInt64 {
        let id = nextID
        nextID += 1
        let voiceName = voice ?? voices.first?.name ?? "Alex"
        synthesizers[id] = SpeechSynthesizerHandle(id: id, voice: voiceName)
        return id
    }

    public func speak(synthesizerID: UInt64, text: String) -> Bool {
        guard var synth = synthesizers[synthesizerID] else { return false }
        synth.isSpeaking = true
        synth.isPaused = false
        synthesizers[synthesizerID] = synth
        spokenTexts.append((synthesizerID: synthesizerID, text: text))
        return true
    }

    public func stop(synthesizerID: UInt64) -> Bool {
        guard var synth = synthesizers[synthesizerID] else { return false }
        synth.isSpeaking = false
        synth.isPaused = false
        synthesizers[synthesizerID] = synth
        return true
    }

    public func pause(synthesizerID: UInt64) -> Bool {
        guard var synth = synthesizers[synthesizerID] else { return false }
        guard synth.isSpeaking else { return false }
        synth.isPaused = true
        synthesizers[synthesizerID] = synth
        return true
    }

    public func resume(synthesizerID: UInt64) -> Bool {
        guard var synth = synthesizers[synthesizerID] else { return false }
        guard synth.isPaused else { return false }
        synth.isPaused = false
        synthesizers[synthesizerID] = synth
        return true
    }

    public func isSpeaking(synthesizerID: UInt64) -> Bool {
        synthesizers[synthesizerID]?.isSpeaking ?? false
    }

    public func setVoice(synthesizerID: UInt64, voice: String) -> Bool {
        guard var synth = synthesizers[synthesizerID] else { return false }
        synth.voice = voice
        synthesizers[synthesizerID] = synth
        return true
    }

    public func setRate(synthesizerID: UInt64, rate: Double) -> Bool {
        guard var synth = synthesizers[synthesizerID] else { return false }
        synth.rate = rate
        synthesizers[synthesizerID] = synth
        return true
    }

    public func setVolume(synthesizerID: UInt64, volume: Float) -> Bool {
        guard var synth = synthesizers[synthesizerID] else { return false }
        guard volume >= 0.0, volume <= 1.0 else { return false }
        synth.volume = volume
        synthesizers[synthesizerID] = synth
        return true
    }

    public func destroySynthesizer(synthesizerID: UInt64) -> Bool {
        synthesizers.removeValue(forKey: synthesizerID) != nil
    }

    public func startListening(commands: [String], callback: @escaping (String) -> Void) -> UInt64? {
        let id = nextID
        nextID += 1
        listeners[id] = (commands: commands, callback: callback)
        return id
    }

    public func stopListening(listenerID: UInt64) -> Bool {
        listeners.removeValue(forKey: listenerID) != nil
    }

    public func isListening(listenerID: UInt64) -> Bool {
        listeners[listenerID] != nil
    }
}
