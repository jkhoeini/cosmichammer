import AppKit
import Foundation
import HSDSTCore

final class ProductionSpeech: SpeechProtocol {
    private var nextID: UInt64 = 1
    private var synthesizers: [UInt64: SynthState] = [:]
    private var listeners: [UInt64: ListenerState] = [:]

    private class SynthState: NSObject, NSSpeechSynthesizerDelegate {
        let synth: NSSpeechSynthesizer
        var delegateCallback: ((SpeechDelegateEvent) -> Void)?

        init(synth: NSSpeechSynthesizer) {
            self.synth = synth
            super.init()
            self.synth.delegate = self
        }

        // MARK: - NSSpeechSynthesizerDelegate

        func speechSynthesizer(_ sender: NSSpeechSynthesizer,
                               willSpeakWord wordToSpeak: NSRange, of text: String) {
            delegateCallback?(.willSpeakWord(
                wordStart: wordToSpeak.location,
                wordEnd: NSMaxRange(wordToSpeak),
                text: text))
        }

        func speechSynthesizer(_ sender: NSSpeechSynthesizer,
                               willSpeakPhoneme phonemeOpcode: Int16) {
            delegateCallback?(.willSpeakPhoneme(phonemeOpcode: phonemeOpcode))
        }

        func speechSynthesizer(_ sender: NSSpeechSynthesizer,
                               didEncounterErrorAt characterIndex: Int,
                               of text: String, message errorMessage: String) {
            delegateCallback?(.didEncounterError(
                characterIndex: characterIndex,
                text: text,
                message: errorMessage))
        }

        func speechSynthesizer(_ sender: NSSpeechSynthesizer,
                               didEncounterSyncMessage errorMessage: String) {
            var syncValue: Any?
            do {
                syncValue = try sender.object(
                    forProperty: NSSpeechSynthesizer.SpeechPropertyKey.recentSync)
            } catch {}
            delegateCallback?(.didEncounterSync(syncValue: syncValue))
        }

        func speechSynthesizer(_ sender: NSSpeechSynthesizer,
                               didFinishSpeaking success: Bool) {
            delegateCallback?(.didFinish(success: success))
        }
    }

    private class ListenerState {
        let recognizer: NSSpeechRecognizer
        let callback: (String) -> Void
        var delegate: RecognizerDelegate?

        init(recognizer: NSSpeechRecognizer, callback: @escaping (String) -> Void) {
            self.recognizer = recognizer
            self.callback = callback
        }
    }

    private class RecognizerDelegate: NSObject, NSSpeechRecognizerDelegate {
        let callback: (String) -> Void

        init(callback: @escaping (String) -> Void) {
            self.callback = callback
        }

        func speechRecognizer(_ sender: NSSpeechRecognizer,
                              didRecognizeCommand command: String) {
            callback(command)
        }
    }

    func availableVoices() -> [VoiceInfo] {
        NSSpeechSynthesizer.availableVoices.compactMap { voiceName in
            let attrs = NSSpeechSynthesizer.attributes(forVoice: voiceName)
            let id = voiceName.rawValue
            let name = attrs[.name] as? String ?? voiceName.rawValue
            let lang = attrs[.localeIdentifier] as? String ?? "en_US"
            let gender: String
            if let g = attrs[.gender] as? String {
                gender = g == "VoiceGenderMale" ? "male"
                    : g == "VoiceGenderFemale" ? "female" : "other"
            } else {
                gender = "other"
            }
            return VoiceInfo(id: id, name: name, language: lang, gender: gender)
        }
    }

    func createSynthesizer(voice: String?) -> UInt64 {
        let synth: NSSpeechSynthesizer
        if let voice = voice {
            synth = NSSpeechSynthesizer(voice: NSSpeechSynthesizer.VoiceName(rawValue: voice))
                ?? NSSpeechSynthesizer()
        } else {
            synth = NSSpeechSynthesizer()
        }
        let id = nextID
        nextID += 1
        synthesizers[id] = SynthState(synth: synth)
        return id
    }

    func speak(synthesizerID: UInt64, text: String) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        return state.synth.startSpeaking(text)
    }

    func speakToFile(synthesizerID: UInt64, text: String, url: URL) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        return state.synth.startSpeaking(text, to: url)
    }

    func stop(synthesizerID: UInt64) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        state.synth.stopSpeaking()
        return true
    }

    func stopAtBoundary(synthesizerID: UInt64, boundary: Int) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        let b = NSSpeechSynthesizer.Boundary(rawValue: UInt(boundary))
            ?? .immediateBoundary
        state.synth.stopSpeaking(at: b)
        return true
    }

    func pause(synthesizerID: UInt64) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        state.synth.pauseSpeaking(at: .immediateBoundary)
        return true
    }

    func pauseAtBoundary(synthesizerID: UInt64, boundary: Int) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        let b = NSSpeechSynthesizer.Boundary(rawValue: UInt(boundary))
            ?? .immediateBoundary
        state.synth.pauseSpeaking(at: b)
        return true
    }

    func resume(synthesizerID: UInt64) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        state.synth.continueSpeaking()
        return true
    }

    func isSpeaking(synthesizerID: UInt64) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        return state.synth.isSpeaking
    }

    func isSpeakingDetailed(synthesizerID: UInt64) -> Bool? {
        guard let state = synthesizers[synthesizerID] else { return nil }
        do {
            let status = try state.synth.object(forProperty: .status) as? NSDictionary
            if let result = status?[NSSpeechSynthesizer.SpeechPropertyKey.StatusKey.outputBusy] as? NSNumber {
                return result.boolValue
            }
        } catch {}
        return nil
    }

    func isPaused(synthesizerID: UInt64) -> Bool? {
        guard let state = synthesizers[synthesizerID] else { return nil }
        do {
            let status = try state.synth.object(forProperty: .status) as? NSDictionary
            if let result = status?[NSSpeechSynthesizer.SpeechPropertyKey.StatusKey.outputPaused] as? NSNumber {
                return result.boolValue
            }
        } catch {}
        return nil
    }

    func voice(synthesizerID: UInt64) -> String? {
        guard let state = synthesizers[synthesizerID] else { return nil }
        return state.synth.voice()?.rawValue
    }

    func setVoice(synthesizerID: UInt64, voice: String) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        return state.synth.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: voice))
    }

    func rate(synthesizerID: UInt64) -> Double {
        guard let state = synthesizers[synthesizerID] else { return 175.0 }
        return Double(state.synth.rate)
    }

    func setRate(synthesizerID: UInt64, rate: Double) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        state.synth.rate = Float(rate)
        return true
    }

    func volume(synthesizerID: UInt64) -> Float {
        guard let state = synthesizers[synthesizerID] else { return 1.0 }
        return state.synth.volume
    }

    func setVolume(synthesizerID: UInt64, volume: Float) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        state.synth.volume = volume
        return true
    }

    func usesFeedbackWindow(synthesizerID: UInt64) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        return state.synth.usesFeedbackWindow
    }

    func setUsesFeedbackWindow(synthesizerID: UInt64, value: Bool) {
        guard let state = synthesizers[synthesizerID] else { return }
        state.synth.usesFeedbackWindow = value
    }

    func phonemes(synthesizerID: UInt64, text: String) -> String {
        guard let state = synthesizers[synthesizerID] else { return "" }
        return state.synth.phonemes(from: text)
    }

    func phoneticSymbols(synthesizerID: UInt64) -> Any? {
        guard let state = synthesizers[synthesizerID] else { return nil }
        do {
            return try state.synth.object(forProperty: .phonemeSymbols)
        } catch {
            return nil
        }
    }

    func pitch(synthesizerID: UInt64) -> Double? {
        guard let state = synthesizers[synthesizerID] else { return nil }
        do {
            let value = try state.synth.object(forProperty: .pitchBase)
            return (value as? NSNumber)?.doubleValue
        } catch {
            return nil
        }
    }

    func setPitch(synthesizerID: UInt64, value: Double) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        do {
            try state.synth.setObject(NSNumber(value: value), forProperty: .pitchBase)
            return true
        } catch {
            return false
        }
    }

    func modulation(synthesizerID: UInt64) -> Double? {
        guard let state = synthesizers[synthesizerID] else { return nil }
        do {
            let value = try state.synth.object(forProperty: .pitchMod)
            return (value as? NSNumber)?.doubleValue
        } catch {
            return nil
        }
    }

    func setModulation(synthesizerID: UInt64, value: Double) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        do {
            try state.synth.setObject(NSNumber(value: value), forProperty: .pitchMod)
            return true
        } catch {
            return false
        }
    }

    func reset(synthesizerID: UInt64) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        do {
            try state.synth.setObject(nil, forProperty: .reset)
            return true
        } catch {
            return false
        }
    }

    func setDelegateCallback(synthesizerID: UInt64,
                             callback: ((SpeechDelegateEvent) -> Void)?) {
        guard let state = synthesizers[synthesizerID] else { return }
        state.delegateCallback = callback
    }

    func destroySynthesizer(synthesizerID: UInt64) -> Bool {
        guard let state = synthesizers.removeValue(forKey: synthesizerID) else { return false }
        state.synth.stopSpeaking()
        state.delegateCallback = nil
        return true
    }

    // MARK: - Listener

    func startListening(commands: [String],
                        callback: @escaping (String) -> Void) -> UInt64?
    {
        guard let recognizer = NSSpeechRecognizer() else { return nil }
        recognizer.commands = commands
        let delegate = RecognizerDelegate(callback: callback)
        recognizer.delegate = delegate
        recognizer.startListening()

        let id = nextID
        nextID += 1
        let state = ListenerState(recognizer: recognizer, callback: callback)
        state.delegate = delegate
        listeners[id] = state
        return id
    }

    func stopListening(listenerID: UInt64) -> Bool {
        guard let state = listeners.removeValue(forKey: listenerID) else { return false }
        state.recognizer.stopListening()
        return true
    }

    func isListening(listenerID: UInt64) -> Bool {
        listeners[listenerID] != nil
    }

    // MARK: - Listener detail methods

    func listenerSetCommands(listenerID: UInt64, commands: [String]) {
        guard let state = listeners[listenerID] else { return }
        state.recognizer.commands = commands
    }

    func listenerCommands(listenerID: UInt64) -> [String]? {
        guard let state = listeners[listenerID] else { return nil }
        return state.recognizer.commands as? [String]
    }

    func listenerSetTitle(listenerID: UInt64, title: String) {
        guard let state = listeners[listenerID] else { return }
        state.recognizer.displayedCommandsTitle = title
    }

    func listenerTitle(listenerID: UInt64) -> String? {
        guard let state = listeners[listenerID] else { return nil }
        return state.recognizer.displayedCommandsTitle
    }

    func listenerSetForegroundOnly(listenerID: UInt64, value: Bool) {
        guard let state = listeners[listenerID] else { return }
        state.recognizer.listensInForegroundOnly = value
    }

    func listenerForegroundOnly(listenerID: UInt64) -> Bool {
        guard let state = listeners[listenerID] else { return true }
        return state.recognizer.listensInForegroundOnly
    }

    func listenerSetBlocksOtherRecognizers(listenerID: UInt64, value: Bool) {
        guard let state = listeners[listenerID] else { return }
        state.recognizer.blocksOtherRecognizers = value
    }

    func listenerBlocksOtherRecognizers(listenerID: UInt64) -> Bool {
        guard let state = listeners[listenerID] else { return false }
        return state.recognizer.blocksOtherRecognizers
    }
}
