import AVFoundation
import MCObjCGuard
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
            // Diagnostic: confirm real audio is flowing — and that it isn't
            // all-zero. macOS can report the mic as authorized yet feed a
            // silent (all-zero) stream when the TCC grant didn't truly land at
            // the HAL layer; logging peak amplitude distinguishes "no audio"
            // from "silent audio" from "real audio".
            if n == 1 || n % 100 == 0 {
                var peak: Float = 0
                if let ch = buffer.floatChannelData?[0] {
                    for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[i])) }
                }
                let peakStr = String(format: "%.4f", peak)
                logger.info("tap: appended \(n) buffers (frames=\(buffer.frameLength) peak=\(peakStr, privacy: .public))")
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

    // Use the user's current locale (e.g. en-GB) — its on-device speech assets
    // are the ones macOS actually provisions; hardcoding en-US picks a recognizer
    // whose assets may be absent. Fall back to en-US only if the current locale
    // has no recognizer.
    private let recognizer = SFSpeechRecognizer()
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// The engine for the *current* listening session, built in `startEngine`
    /// and torn down in `teardownEngine` — deliberately not a long-lived one.
    ///
    /// `AVAudioEngine` fixes its input node's format when the node is first
    /// configured and keeps reporting that format afterwards, so an engine
    /// that outlives an input-route change reports the format of the device
    /// that is *gone*: plug a headset in and the hardware becomes 16 kHz mono
    /// (HFP wideband speech) while the node still claims 48 kHz; unplug it and
    /// the hardware returns to 44.1/48 kHz while the node still claims 16 kHz.
    /// Installing a tap with that stale format makes AVFAudio raise
    /// `NSException` ("Failed to create tap due to format mismatch"), which
    /// takes the whole daemon down a few seconds later — see `startEngine`.
    /// Building the engine per session means its node is always configured
    /// against the device that is current now.
    private var audioEngine: AVAudioEngine?

    /// Registration for `AVAudioEngineConfigurationChange` on the live engine.
    private var configObserver: NSObjectProtocol?

    private let holder = RequestHolder()
    private var task: SFSpeechRecognitionTask?
    private var engineRunning = false

    /// Identifies the current recognition session. A task's completion handler
    /// also fires when *we* cancel the task, reporting `kLSRErrorDomain 301`
    /// — indistinguishable, from inside the handler, from the recognizer
    /// giving up on its own. Restarting on that would fight whoever did the
    /// cancelling: tear a live session down (a route change) and its dying
    /// handler would restart it, cancelling the replacement, whose handler
    /// would restart it again, forever. So every handler remembers the
    /// generation it belongs to and a stale one does nothing.
    private var sessionGeneration = 0

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

        // The on-device model must be provisioned. On macOS < 26 there is no
        // AssetInventory API to download it ourselves, and with the model
        // absent `requiresOnDeviceRecognition = true` produces NO transcription
        // — silently. We refuse to fall back to Apple's server recognition
        // (the spoken command would leave the machine, breaking the on-device
        // guarantee in this file's header), so fail fast with an actionable
        // message instead of appearing to do nothing.
        guard recognizer.supportsOnDeviceRecognition else {
            Self.logger.error(
                "voice: on-device recognition unsupported for locale \(recognizer.locale.identifier, privacy: .public) — model not installed; refusing server fallback"
            )
            onError?("On-device speech model isn’t installed — turn on Dictation for your language in System Settings ▸ Keyboard, then try ⌘L again.")
            return
        }

        Self.logger.info(
            "voice start: speechAuth=\(SFSpeechRecognizer.authorizationStatus().rawValue, privacy: .public) micAuth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue, privacy: .public) onDevice=\(recognizer.supportsOnDeviceRecognition, privacy: .public) locale=\(recognizer.locale.identifier, privacy: .public)"
        )

        guard startEngine() else { return }

        active = true
        isListening = true
        onListeningChanged?(true)
        Self.logger.info("voice listening started (continuous)")
        beginSession()
    }

    // MARK: - Audio engine

    /// Build the audio engine for a session and start capturing into `holder`.
    /// Returns false — having reported the reason through `onError` — if the
    /// microphone cannot be tapped.
    private func startEngine() -> Bool {
        teardownEngine()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // The tap format must be the input node's *hardware* format: that is
        // the one AVFAudio validates a tap against (the "input hw" in its
        // mismatch error). `outputFormat(forBus:)` is the node's
        // post-conversion output, which legitimately differs from the
        // hardware — after a route change AVFAudio inserts a converter and
        // keeps producing the old format, and passing *that* to installTap is
        // what raised the exception that killed the daemon.
        let format = input.inputFormat(forBus: 0)
        // A zero/invalid input format (no or busy mic device) also makes
        // installTap raise — bail first.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError?("No usable microphone input.")
            return false
        }
        Self.logger.info(
            "voice engine: inFmt=\(format.sampleRate, privacy: .public)Hz x\(format.channelCount, privacy: .public)"
        )

        let holder = self.holder
        do {
            // installTap raises an Obj-C NSException on a format mismatch.
            // Swift cannot catch that, and letting it unwind through these
            // frames leaves the concurrency runtime's per-thread executor
            // bookkeeping dangling — the daemon then dies with a bus error
            // inside swift_task_isCurrentExecutor at the next @objc entry
            // point (a mic click, a key-monitor callback), taking the Haskell
            // brain with it. Reading the hardware format above should make a
            // mismatch impossible; the guard is here because the input device
            // can still change in the microseconds between the two calls, and
            // "voice didn't start" must never escalate to "the window manager
            // died".
            try MCObjCGuard.perform {
                // Tap runs on the realtime audio thread — @Sendable, never
                // main-isolated.
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
                    holder.append(buffer)
                }
            }
        } catch {
            Self.logger.error(
                "voice: installTap refused the input format: \(error.localizedDescription, privacy: .public)"
            )
            onError?("The microphone changed while starting — press ⌘L to listen again.")
            return false
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            onError?("Microphone failed to start: \(error.localizedDescription)")
            return false
        }

        // AVFAudio stops the engine and drops its taps when the input device
        // changes under it — headphones going in mid-sentence. Without this
        // the mic just goes deaf while the UI still shows it listening.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // Delivered on an arbitrary thread: hop before touching state.
            DispatchQueue.main.async { @MainActor in
                self?.restartForRouteChange()
            }
        }

        audioEngine = engine
        engineRunning = true
        return true
    }

    /// Stop capturing and drop the engine, its tap and its observer.
    private func teardownEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let audioEngine {
            if engineRunning {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            self.audioEngine = nil
        }
        engineRunning = false
    }

    /// The input device changed while we were listening. Rebuild the engine
    /// against the new device, keeping the user's intent (`active`) intact.
    private func restartForRouteChange() {
        guard active else { return }
        Self.logger.info("voice: input route changed — rebuilding the session")
        holder.set(nil)
        task?.cancel()
        task = nil
        guard startEngine() else {
            // startEngine has already reported why through onError.
            active = false
            isListening = false
            onListeningChanged?(false)
            return
        }
        beginSession()
    }

    /// Start one recognition request/task. Restarted automatically whenever a
    /// task ends, for as long as `active` holds.
    private func beginSession() {
        guard active, let recognizer else { return }

        sessionGeneration &+= 1
        let generation = sessionGeneration

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // `start()` already guaranteed on-device support, so keep recognition
        // local unconditionally — spoken commands never leave the machine.
        req.requiresOnDeviceRecognition = true
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
                // Surface domain+code: kLSRErrorDomain 102 / kAFAssistantErrorDomain
                // 1101/203 mean the on-device model is missing or unusable —
                // the difference between "mic broken" and "model not installed".
                let ns = error as NSError
                recogLogger.error("recog error: domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                guard let self, self.sessionGeneration == generation else { return }
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
                        guard self.active, self.sessionGeneration == generation else { return }
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
        teardownEngine()
        isListening = false
        onListeningChanged?(false)
        Self.logger.info("voice listening stopped")
    }
}
