import AppKit
import AVFoundation
import Observation
import Speech

/// Live French dictation with the system speech recognizer (on-device when available).
@MainActor
@Observable
final class Dictation {
    var isRecording = false
    var transcript = ""
    var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() { isRecording ? stop() : start() }

    private func log(_ s: String) { PanelController.debug("dictée : " + s) }

    func start() {
        error = nil
        transcript = ""
        log("démarrage, micro=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) voix=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
        if SFSpeechRecognizer.authorizationStatus() == .authorized && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            begin(); return
        }
        // The system permission dialog must not be hidden behind the always-on-top panel.
        PanelController.shared.lowerForSystemDialog()
        NSApp.activate(ignoringOtherApps: true)
        SFSpeechRecognizer.requestAuthorization { status in
            PanelController.debug("dictée : réponse autorisation voix = \(status.rawValue)")
            Task { @MainActor in
                PanelController.shared.restoreAfterSystemDialog()
                guard status == .authorized else { self.error = "Autorisez la reconnaissance vocale dans Réglages Système › Confidentialité et sécurité › Reconnaissance vocale."; return }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        guard granted else { self.error = "Autorisez le micro dans Réglages Système › Confidentialité."; return }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { error = "Reconnaissance vocale indisponible."; log("recognizer indisponible"); return }
        log("on-device possible=\(recognizer.supportsOnDeviceRecognition)")
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        self.request = request
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
        log("format micro \(input.outputFormat(forBus: 0))")
        do { engine.prepare(); try engine.start() } catch { self.error = error.localizedDescription; log("moteur audio : \(error)"); return }
        log("écoute démarrée")
        transcript = ""
        isRecording = true
        task = recognizer.recognitionTask(with: request) { result, err in
            Task { @MainActor in
                if let result { self.transcript = result.bestTranscription.formattedString }
                if let err {
                    self.log("erreur reconnaissance : \(err)")
                    // Silence (1110) or stopping the dictation (cancellation codes) is not an error.
                    let benign: Set<Int> = [1110, 203, 216, 301, 1101]
                    let code = (err as NSError).code
                    if self.transcript.isEmpty && !benign.contains(code) && (err as NSError).domain != NSCocoaErrorDomain {
                        self.error = "Dictée impossible : \(err.localizedDescription)"
                    }
                    self.stop()
                } else if result?.isFinal ?? false { self.stop() }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        isRecording = false
    }
}
