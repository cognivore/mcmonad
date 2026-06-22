import AVFoundation
import Speech
import os

/// Voice input for the Spotlight command runner, built on Apple's
/// `Speech.framework` — which is free and, on Apple-silicon macOS, runs
/// fully on-device (`requiresOnDeviceRecognition`), so spoken commands never
/// leave the machine.
///
/// **Continuous listening.** The on-device recognizer finalises a recognition
/// task after a pause in speech (and caps a single task at ~1 minute). To keep
/// the mic live the whole time the launcher is open, the `AVAudioEngine` tap
/// stays running and only the `SFSpeechAudioBufferRecognitionRequest` + task
/// are recycled: when a task ends (final result, silence, or error) we start a
/// fresh one, until `stop()` is called (the user typed, dismissed, or a spoken
/// command fired). The tap feeds whichever request is current through a small
/// locked holder, so swapping requests never drops or misroutes audio.
///
/// Permissions degrade gracefully: if speech-recognition or microphone
/// authorization is unavailable, `requestAuthorization` reports `false`, the
/// controller hides the mic affordance, and everything else keeps working.
@MainActor
final class VoiceInput {
    private static let logger = Logger(
        subsystem: "com.mcmonad.core",
        category: "Voice"
    )

    /// Routes realtime audio buffers to the current recognition request. The
    /// tap closure runs on the audio render thread; `set` runs on the main
    /// actor when a session is (re)started. A lock keeps the swap safe.
    /// `SFSpeechAudioBufferRecognitionRequest.append` is documented as safe to
    /// call from the tap callback.
    private final class RequestHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var appended = 0
        private let logger = Logger(subsystem: "com.mcmonad.core", category: "Voice")
        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            let r = request
            appended += 1
            let n = appended
            lock.unlock()
            r?.append(buffer)
            // Diagnostic: confirm real audio is flowing from the mic tap.
            if n == 1 || n % 100 == 0 {
                logger.info("tap: appended \(n) buffers (frames=\(buffer.frameLength))")
            }
        }
        func set(_ r: SFSpeechAudioBufferRecognitionRequest?) {
            lock.lock()
            request = r
            appended = 0
            lock.unlock()
        }
    }

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onListeningChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let holder = RequestHolder()
    private var task: SFSpeechRecognitionTask?
    private var engineRunning = false

    /// The user's intent to be listening. Stays true across automatic session
    /// restarts; only `stop()` clears it. `isListening` mirrors it for the UI.
    private var active = false
    private(set) var isListening = false

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    /// True when speech or mic permission is still undecided, i.e. requesting
    /// authorization now would surface a system prompt. Used to decide whether
    /// to bring the daemon forward so that prompt is actually visible.
    var needsAuthorizationPrompt: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined
            || AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    // MARK: - Authorization

    /// Request both speech-recognition and microphone permission. Calls back
    /// with the combined result. The handler runs on a background queue (TCC),
    /// so it is @Sendable to keep the compiler from inferring main-actor
    /// isolation — which the runtime would then trap on.
    func requestAuthorization(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard recognizer != nil else {
            Self.logger.error("requestAuth: recognizer is nil (locale unsupported)")
            completion(false)
            return
        }
        let log = Self.logger
        SFSpeechRecognizer.requestAuthorization { @Sendable speechStatus in
            log.info("requestAuth: speechStatus=\(speechStatus.rawValue, privacy: .public)")
            let speechOK = (speechStatus == .authorized)
            guard speechOK else {
                completion(false)
                return
            }
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            log.info("requestAuth: micStatus=\(micStatus.rawValue, privacy: .public)")
            switch micStatus {
            case .authorized:
                completion(true)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { @Sendable micOK in
                    log.info("requestAuth: micGranted=\(micOK, privacy: .public)")
                    completion(micOK)
                }
            default:
                completion(false)
            }
        }
    }

    // MARK: - Listening

    func toggle() {
        if active { stop() } else { start() }
    }

    /// Begin continuous listening. Idempotent while already active.
    func start() {
        guard !active else { return }
        guard let recognizer, recognizer.isAvailable else {
            onError?("Speech recognition is not available right now.")
            return
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A zero/invalid input format (no or busy mic device) makes installTap
        // throw an Obj-C exception that would crash us — bail first.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError?("No usable microphone input.")
            return
        }

        Self.logger.info(
            "voice start: speechAuth=\(SFSpeechRecognizer.authorizationStatus().rawValue, privacy: .public) micAuth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue, privacy: .public) inFmt=\(format.sampleRate, privacy: .public)Hz x\(format.channelCount, privacy: .public)"
        )

        let holder = self.holder
        // Tap runs on the realtime audio thread — @Sendable, never main-isolated.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            holder.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            onError?("Microphone failed to start: \(error.localizedDescription)")
            return
        }
        engineRunning = true

        active = true
        isListening = true
        onListeningChanged?(true)
        Self.logger.info("voice listening started (continuous)")
        beginSession()
    }

    /// Start one recognition request/task. Restarted automatically whenever a
    /// task ends, for as long as `active` holds.
    private func beginSession() {
        guard active, let recognizer else { return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        holder.set(req)

        let recogLogger = Self.logger
        task = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            // Extract Sendable values on the recognition queue, then hop to the
            // main actor — never transfer the non-Sendable result object. The
            // handler is @Sendable so it is not inferred main-actor-isolated
            // (it runs off-main; the runtime would otherwise trap).
            let text: String? = result.map { $0.bestTranscription.formattedString }
            let isFinal = result?.isFinal ?? false
            let failed = (error != nil)
            if let text {
                recogLogger.info("recog \(isFinal ? "final" : "partial", privacy: .public): \(text, privacy: .public)")
            }
            if let error {
                recogLogger.error("recog error: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                guard let self else { return }
                if let text, !text.isEmpty {
                    if isFinal {
                        self.onFinal?(text)
                    } else {
                        self.onPartial?(text)
                    }
                }
                // A task ends on final result, silence, or error. Keep the mic
                // live by starting a fresh session — unless onFinal triggered a
                // command that stopped us (active == false), or audio is gone.
                if (isFinal || failed), self.active {
                    if failed {
                        // Brief backoff so a persistently-failing recognizer
                        // can't spin a hot restart loop.
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        guard self.active else { return }
                    }
                    self.restartSession()
                }
            }
        }
    }

    /// Recycle the recognition request/task while keeping the engine + tap up.
    private func restartSession() {
        holder.set(nil)
        task?.cancel()
        task = nil
        guard active, engineRunning else { return }
        beginSession()
    }

    func stop() {
        guard active else { return }
        active = false
        holder.set(nil)
        task?.cancel()
        task = nil
        if engineRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            engineRunning = false
        }
        isListening = false
        onListeningChanged?(false)
        Self.logger.info("voice listening stopped")
    }
}
