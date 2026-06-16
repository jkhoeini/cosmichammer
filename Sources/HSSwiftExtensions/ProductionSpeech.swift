import AppKit
import Foundation
import HSDSTCore

final class ProductionSpeech: SpeechProtocol {
    private var nextID: UInt64 = 1
    private var synthesizers: [UInt64: SynthState] = [:]
    private var listeners: [UInt64: ListenerState] = [:]

    private class SynthState: NSObject, NSSpeechSynthesizerDelegate {
        let synth: NSSpeechSynthesizer

        init(synth: NSSpeechSynthesizer) {
            self.synth = synth
            super.init()
            self.synth.delegate = self
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

    func stop(synthesizerID: UInt64) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        state.synth.stopSpeaking()
        return true
    }

    func pause(synthesizerID: UInt64) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        state.synth.pauseSpeaking(at: .immediateBoundary)
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

    func setVoice(synthesizerID: UInt64, voice: String) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        return state.synth.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: voice))
    }

    func setRate(synthesizerID: UInt64, rate: Double) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        state.synth.rate = Float(rate)
        return true
    }

    func setVolume(synthesizerID: UInt64, volume: Float) -> Bool {
        guard let state = synthesizers[synthesizerID] else { return false }
        state.synth.volume = volume
        return true
    }

    func destroySynthesizer(synthesizerID: UInt64) -> Bool {
        guard let state = synthesizers.removeValue(forKey: synthesizerID) else { return false }
        state.synth.stopSpeaking()
        return true
    }

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
}
