import AVFoundation
import Speech
import os

/// Voice input for the Spotlight command runner, built on Apple's
/// `Speech.framework` — which is free and, on Apple-silicon macOS, runs
/// fully on-device (`requiresOnDeviceRecognition`), so spoken commands never
/// leave the machine.
///
/// The flow: tap the default input device with `AVAudioEngine`, stream PCM
/// buffers into an `SFSpeechAudioBufferRecognitionRequest`, and surface
/// partial transcripts live (`onPartial`) plus a final transcript
/// (`onFinal`) when the speaker pauses. The controller feeds partials into
/// the search field and runs the command parser on the final string.
///
/// Permissions degrade gracefully: if speech-recognition or microphone
/// authorization is unavailable (e.g. a bare daemon binary whose enclosing
/// bundle TCC can't resolve), `requestAuthorization` reports `false`, the
/// controller hides the mic affordance, and everything else keeps working.
@MainActor
final class VoiceInput {
    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "Voice"
    )

    /// Carries a non-Sendable reference across the audio render thread
    /// boundary. `SFSpeechAudioBufferRecognitionRequest.append` is documented
    /// as safe to call from the realtime tap callback.
    private struct UnsafeBox<T>: @unchecked Sendable { let value: T }

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onListeningChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private(set) var isListening = false

    /// Whether the recognizer exists and is currently available. Auth is
    /// checked separately via `requestAuthorization`.
    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    // MARK: - Authorization

    /// Request both speech-recognition and microphone permission. Calls back
    /// on the main actor with the combined result.
    func requestAuthorization(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard recognizer != nil else {
            completion(false)
            return
        }
        // These handlers are invoked by TCC/AVFoundation on background queues.
        // Mark them @Sendable so the compiler does NOT infer main-actor
        // isolation from this @MainActor method — otherwise the Swift runtime
        // asserts "not on the main queue" and SIGTRAPs when they fire.
        SFSpeechRecognizer.requestAuthorization { @Sendable speechStatus in
            let speechOK = (speechStatus == .authorized)
            guard speechOK else {
                completion(false)
                return
            }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                completion(true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { @Sendable micOK in
                    completion(micOK)
                }
            default:
                completion(false)
            }
        }
    }

    // MARK: - Listening

    func toggle() {
        if isListening { stop() } else { start() }
    }

    func start() {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            onError?("Speech recognition is not available right now.")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Guard against a zero/invalid input format (no or busy mic device),
        // which makes installTap throw an exception that would crash us.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError?("No usable microphone input.")
            request = nil
            return
        }

        let box = UnsafeBox(value: req)
        // The tap fires on the realtime audio render thread — must be
        // @Sendable (never main-actor-isolated) or the runtime traps.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            box.value.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            request = nil
            onError?("Microphone failed to start: \(error.localizedDescription)")
            return
        }

        isListening = true
        onListeningChanged?(true)
        Self.logger.info("voice listening started")

        task = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            // Extract Sendable values on the recognition queue, then hop to
            // the main actor — never transfer the non-Sendable result object.
            // @Sendable: this handler is called off-main; without it the
            // compiler would infer main-actor isolation and the runtime traps.
            let text: String? = result.map { $0.bestTranscription.formattedString }
            let isFinal = result?.isFinal ?? false
            let failed = (error != nil)
            Task { @MainActor in
                guard let self else { return }
                if let text, !text.isEmpty {
                    if isFinal {
                        self.onFinal?(text)
                        self.stop()
                    } else {
                        self.onPartial?(text)
                    }
                } else if failed {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        onListeningChanged?(false)
        Self.logger.info("voice listening stopped")
    }
}
