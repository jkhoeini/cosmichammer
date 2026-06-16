import Foundation

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
    func stop(synthesizerID: UInt64) -> Bool
    func pause(synthesizerID: UInt64) -> Bool
    func resume(synthesizerID: UInt64) -> Bool
    func isSpeaking(synthesizerID: UInt64) -> Bool
    func setVoice(synthesizerID: UInt64, voice: String) -> Bool
    func setRate(synthesizerID: UInt64, rate: Double) -> Bool
    func setVolume(synthesizerID: UInt64, volume: Float) -> Bool
    func destroySynthesizer(synthesizerID: UInt64) -> Bool

    func startListening(commands: [String], callback: @escaping (String) -> Void) -> UInt64?
    func stopListening(listenerID: UInt64) -> Bool
    func isListening(listenerID: UInt64) -> Bool
}
