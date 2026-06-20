import Foundation

/// Events fired by a speech synthesizer via its delegate callback.
public enum SpeechDelegateEvent: Sendable {
    /// The synthesizer is about to speak a word range in the given text.
    case willSpeakWord(wordStart: Int, wordEnd: Int, text: String)
    /// The synthesizer is about to speak a phoneme.
    case willSpeakPhoneme(phonemeOpcode: Int16)
    /// The synthesizer encountered an error at a character index.
    case didEncounterError(characterIndex: Int, text: String, message: String)
    /// The synthesizer encountered a sync message.
    case didEncounterSync(syncValue: Any?)
    /// The synthesizer finished speaking.
    case didFinish(success: Bool)
}

public struct VoiceInfo: Sendable {
    public var id: String
    public var name: String
    public var language: String
    public var gender: String

    public init(id: String = "com.apple.speech.synthesis.voice.Alex",
                name: String = "Alex", language: String = "en_US",
                gender: String = "male") {
        self.id = id
        self.name = name
        self.language = language
        self.gender = gender
    }
}

public struct SpeechSynthesizerHandle: Sendable {
    public var id: UInt64
    public var voice: String
    public var rate: Double
    public var volume: Float
    public var isSpeaking: Bool
    public var isPaused: Bool

    public init(id: UInt64, voice: String = "Alex", rate: Double = 175.0,
                volume: Float = 1.0, isSpeaking: Bool = false,
                isPaused: Bool = false) {
        self.id = id
        self.voice = voice
        self.rate = rate
        self.volume = volume
        self.isSpeaking = isSpeaking
        self.isPaused = isPaused
    }
}

public protocol SpeechProtocol: AnyObject {
    func availableVoices() -> [VoiceInfo]
    func createSynthesizer(voice: String?) -> UInt64
    func speak(synthesizerID: UInt64, text: String) -> Bool
    func speakToFile(synthesizerID: UInt64, text: String, url: URL) -> Bool
    func stop(synthesizerID: UInt64) -> Bool
    func stopAtBoundary(synthesizerID: UInt64, boundary: Int) -> Bool
    func pause(synthesizerID: UInt64) -> Bool
    func pauseAtBoundary(synthesizerID: UInt64, boundary: Int) -> Bool
    func resume(synthesizerID: UInt64) -> Bool
    func isSpeaking(synthesizerID: UInt64) -> Bool
    func isSpeakingDetailed(synthesizerID: UInt64) -> Bool?
    func isPaused(synthesizerID: UInt64) -> Bool?
    func voice(synthesizerID: UInt64) -> String?
    func setVoice(synthesizerID: UInt64, voice: String) -> Bool
    func rate(synthesizerID: UInt64) -> Double
    func setRate(synthesizerID: UInt64, rate: Double) -> Bool
    func volume(synthesizerID: UInt64) -> Float
    func setVolume(synthesizerID: UInt64, volume: Float) -> Bool
    func usesFeedbackWindow(synthesizerID: UInt64) -> Bool
    func setUsesFeedbackWindow(synthesizerID: UInt64, value: Bool)
    func phonemes(synthesizerID: UInt64, text: String) -> String
    func phoneticSymbols(synthesizerID: UInt64) -> Any?
    func pitch(synthesizerID: UInt64) -> Double?
    func setPitch(synthesizerID: UInt64, value: Double) -> Bool
    func modulation(synthesizerID: UInt64) -> Double?
    func setModulation(synthesizerID: UInt64, value: Double) -> Bool
    func reset(synthesizerID: UInt64) -> Bool
    func setDelegateCallback(synthesizerID: UInt64, callback: ((SpeechDelegateEvent) -> Void)?)
    func destroySynthesizer(synthesizerID: UInt64) -> Bool

    func startListening(commands: [String], callback: @escaping (String) -> Void) -> UInt64?
    func stopListening(listenerID: UInt64) -> Bool
    func isListening(listenerID: UInt64) -> Bool

    // MARK: - Listener detail methods
    func listenerSetCommands(listenerID: UInt64, commands: [String])
    func listenerCommands(listenerID: UInt64) -> [String]?
    func listenerSetTitle(listenerID: UInt64, title: String)
    func listenerTitle(listenerID: UInt64) -> String?
    func listenerSetForegroundOnly(listenerID: UInt64, value: Bool)
    func listenerForegroundOnly(listenerID: UInt64) -> Bool
    func listenerSetBlocksOtherRecognizers(listenerID: UInt64, value: Bool)
    func listenerBlocksOtherRecognizers(listenerID: UInt64) -> Bool
}

// Default implementations so existing conformers don't break.
public extension SpeechProtocol {
    func speakToFile(synthesizerID: UInt64, text: String, url: URL) -> Bool { false }
    func stopAtBoundary(synthesizerID: UInt64, boundary: Int) -> Bool { stop(synthesizerID: synthesizerID) }
    func pauseAtBoundary(synthesizerID: UInt64, boundary: Int) -> Bool { pause(synthesizerID: synthesizerID) }
    func isSpeakingDetailed(synthesizerID: UInt64) -> Bool? { isSpeaking(synthesizerID: synthesizerID) }
    func isPaused(synthesizerID: UInt64) -> Bool? { false }
    func voice(synthesizerID: UInt64) -> String? { nil }
    func rate(synthesizerID: UInt64) -> Double { 175.0 }
    func volume(synthesizerID: UInt64) -> Float { 1.0 }
    func usesFeedbackWindow(synthesizerID: UInt64) -> Bool { false }
    func setUsesFeedbackWindow(synthesizerID: UInt64, value: Bool) {}
    func phonemes(synthesizerID: UInt64, text: String) -> String { "" }
    func phoneticSymbols(synthesizerID: UInt64) -> Any? { nil }
    func pitch(synthesizerID: UInt64) -> Double? { nil }
    func setPitch(synthesizerID: UInt64, value: Double) -> Bool { false }
    func modulation(synthesizerID: UInt64) -> Double? { nil }
    func setModulation(synthesizerID: UInt64, value: Double) -> Bool { false }
    func reset(synthesizerID: UInt64) -> Bool { false }
    func setDelegateCallback(synthesizerID: UInt64, callback: ((SpeechDelegateEvent) -> Void)?) {}
    func listenerSetCommands(listenerID: UInt64, commands: [String]) {}
    func listenerCommands(listenerID: UInt64) -> [String]? { nil }
    func listenerSetTitle(listenerID: UInt64, title: String) {}
    func listenerTitle(listenerID: UInt64) -> String? { nil }
    func listenerSetForegroundOnly(listenerID: UInt64, value: Bool) {}
    func listenerForegroundOnly(listenerID: UInt64) -> Bool { true }
    func listenerSetBlocksOtherRecognizers(listenerID: UInt64, value: Bool) {}
    func listenerBlocksOtherRecognizers(listenerID: UInt64) -> Bool { false }
}
