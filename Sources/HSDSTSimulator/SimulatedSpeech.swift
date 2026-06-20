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
    private var listeners: [UInt64: SimListenerState] = [:]
    private var synthDelegateCallbacks: [UInt64: (SpeechDelegateEvent) -> Void] = [:]
    private var synthUsesFeedback: [UInt64: Bool] = [:]

    private struct SimListenerState {
        var commands: [String]
        var callback: (String) -> Void
        var title: String
        var foregroundOnly: Bool
        var blocksOtherRecognizers: Bool
    }

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

    public func speakToFile(synthesizerID: UInt64, text: String, url: URL) -> Bool {
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

    public func stopAtBoundary(synthesizerID: UInt64, boundary: Int) -> Bool {
        return stop(synthesizerID: synthesizerID)
    }

    public func pause(synthesizerID: UInt64) -> Bool {
        guard var synth = synthesizers[synthesizerID] else { return false }
        guard synth.isSpeaking else { return false }
        synth.isPaused = true
        synthesizers[synthesizerID] = synth
        return true
    }

    public func pauseAtBoundary(synthesizerID: UInt64, boundary: Int) -> Bool {
        return pause(synthesizerID: synthesizerID)
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

    public func isSpeakingDetailed(synthesizerID: UInt64) -> Bool? {
        guard let synth = synthesizers[synthesizerID] else { return nil }
        return synth.isSpeaking
    }

    public func isPaused(synthesizerID: UInt64) -> Bool? {
        guard let synth = synthesizers[synthesizerID] else { return nil }
        return synth.isPaused
    }

    public func voice(synthesizerID: UInt64) -> String? {
        guard let synth = synthesizers[synthesizerID] else { return nil }
        // Return the full voice ID matching the stored voice name
        if let voiceInfo = voices.first(where: { $0.name == synth.voice }) {
            return voiceInfo.id
        }
        // If the stored voice is already a full ID, return it
        return synth.voice
    }

    public func setVoice(synthesizerID: UInt64, voice: String) -> Bool {
        guard var synth = synthesizers[synthesizerID] else { return false }
        synth.voice = voice
        synthesizers[synthesizerID] = synth
        return true
    }

    public func rate(synthesizerID: UInt64) -> Double {
        synthesizers[synthesizerID]?.rate ?? 175.0
    }

    public func setRate(synthesizerID: UInt64, rate: Double) -> Bool {
        guard var synth = synthesizers[synthesizerID] else { return false }
        synth.rate = rate
        synthesizers[synthesizerID] = synth
        return true
    }

    public func volume(synthesizerID: UInt64) -> Float {
        synthesizers[synthesizerID]?.volume ?? 1.0
    }

    public func setVolume(synthesizerID: UInt64, volume: Float) -> Bool {
        guard var synth = synthesizers[synthesizerID] else { return false }
        guard volume >= 0.0, volume <= 1.0 else { return false }
        synth.volume = volume
        synthesizers[synthesizerID] = synth
        return true
    }

    public func usesFeedbackWindow(synthesizerID: UInt64) -> Bool {
        synthUsesFeedback[synthesizerID] ?? false
    }

    public func setUsesFeedbackWindow(synthesizerID: UInt64, value: Bool) {
        synthUsesFeedback[synthesizerID] = value
    }

    public func phonemes(synthesizerID: UInt64, text: String) -> String {
        // Simple simulated phoneme conversion
        return text
    }

    public func phoneticSymbols(synthesizerID: UInt64) -> Any? {
        nil
    }

    public func pitch(synthesizerID: UInt64) -> Double? {
        // Default pitch
        return 50.0
    }

    public func setPitch(synthesizerID: UInt64, value: Double) -> Bool {
        guard synthesizers[synthesizerID] != nil else { return false }
        return true
    }

    public func modulation(synthesizerID: UInt64) -> Double? {
        return 50.0
    }

    public func setModulation(synthesizerID: UInt64, value: Double) -> Bool {
        guard synthesizers[synthesizerID] != nil else { return false }
        return true
    }

    public func reset(synthesizerID: UInt64) -> Bool {
        guard synthesizers[synthesizerID] != nil else { return false }
        return true
    }

    public func setDelegateCallback(synthesizerID: UInt64,
                                    callback: ((SpeechDelegateEvent) -> Void)?) {
        synthDelegateCallbacks[synthesizerID] = callback
    }

    public func destroySynthesizer(synthesizerID: UInt64) -> Bool {
        synthDelegateCallbacks.removeValue(forKey: synthesizerID)
        synthUsesFeedback.removeValue(forKey: synthesizerID)
        return synthesizers.removeValue(forKey: synthesizerID) != nil
    }

    // MARK: - Listener

    public func startListening(commands: [String], callback: @escaping (String) -> Void) -> UInt64? {
        let id = nextID
        nextID += 1
        listeners[id] = SimListenerState(
            commands: commands,
            callback: callback,
            title: "Cosmic Hammer",
            foregroundOnly: true,
            blocksOtherRecognizers: false
        )
        return id
    }

    public func stopListening(listenerID: UInt64) -> Bool {
        listeners.removeValue(forKey: listenerID) != nil
    }

    public func isListening(listenerID: UInt64) -> Bool {
        listeners[listenerID] != nil
    }

    // MARK: - Listener detail methods

    public func listenerSetCommands(listenerID: UInt64, commands: [String]) {
        listeners[listenerID]?.commands = commands
    }

    public func listenerCommands(listenerID: UInt64) -> [String]? {
        listeners[listenerID]?.commands
    }

    public func listenerSetTitle(listenerID: UInt64, title: String) {
        listeners[listenerID]?.title = title
    }

    public func listenerTitle(listenerID: UInt64) -> String? {
        listeners[listenerID]?.title
    }

    public func listenerSetForegroundOnly(listenerID: UInt64, value: Bool) {
        listeners[listenerID]?.foregroundOnly = value
    }

    public func listenerForegroundOnly(listenerID: UInt64) -> Bool {
        listeners[listenerID]?.foregroundOnly ?? true
    }

    public func listenerSetBlocksOtherRecognizers(listenerID: UInt64, value: Bool) {
        listeners[listenerID]?.blocksOtherRecognizers = value
    }

    public func listenerBlocksOtherRecognizers(listenerID: UInt64) -> Bool {
        listeners[listenerID]?.blocksOtherRecognizers ?? false
    }
}
