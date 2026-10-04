import Foundation
import AVFoundation

/// Captures microphone audio and emits 16-bit mono PCM chunks at a target rate
/// (OpenAI gpt-realtime-whisper wants 24 kHz). AVAudioEngine + AVAudioConverter
/// so output is independent of the hardware rate. Cross-platform — only the
/// AVAudioSession setup is iOS-specific (macOS has no session model).
public final class AudioCaptureService: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case converterUnavailable
        var errorDescription: String? { "Could not create audio converter." }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    /// The input format the current `converter` was built from. The tap delivers
    /// the input node's live format, which can change between/within sessions
    /// (e.g. unplugging a display switches the audio route to a 24 kHz Bluetooth
    /// mic), so the converter is rebuilt whenever the incoming format changes.
    private var converterInputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat!
    private var targetRate: Double = 16000
    public private(set) var isRunning = false

    /// Called on the audio queue with each PCM chunk as it arrives.
    public var onPCM: (@Sendable (Data) -> Void)?

    /// PaloAlly: every engine / session operation runs here, in order.
    /// `setActive(true)` + `engine.start()` can take hundreds of ms on a device
    /// (more when the category changes); on the main thread that froze the
    /// press animation until the mic was live. Serial (and shared by every
    /// instance, since the audio session is process-wide), so a stop queued
    /// right after a start still lands after it.
    private static let control = DispatchQueue(label: "paloally.audio.control", qos: .userInteractive)
    private var control: DispatchQueue { Self.control }
    private var loggedFirstBuffer = false
    private var engineStartedAt: TimeInterval = 0

    public init() {}

    // MARK: - Warm session (PaloAlly)
    //
    // Device logs showed the first mic buffer ~700 ms after engine.start
    // whenever the session had to be (re)activated per press — the input
    // hardware waking up — so the first words were lost. With the session
    // already active it was ~50 ms. So the session stays active while the app
    // is in the foreground and only the engine starts/stops per recording.
    //
    // Category .playAndRecord + .mixWithOthers: an active session must not
    // stop or duck the user's music (.record would silence it for as long as
    // the app is open). .defaultToSpeaker keeps playback on the speaker instead
    // of the earpiece; .allowBluetoothA2DP keeps headphones in high-quality
    // A2DP for music (the built-in mic records) rather than switching them to
    // the low-quality HFP profile. Mode .default keeps the system's standard
    // input processing (gain, noise) — no voice-chat ducking.
    //
    // An active session alone doesn't light the orange mic indicator; that
    // shows only while input I/O runs (engine started).

    private static var warmWanted = false
    private static var sessionReady = false
    private static var observing = false

    /// Keep the audio session active (foreground) or let it go (background).
    /// Only when microphone access is already granted — never prompts.
    public static func setSessionWarm(_ warm: Bool) {
        #if os(iOS)
        control.async {
            warmWanted = warm
            if warm {
                guard MicPermission.micAuthorizedSync() else { return }
                observeInterruptions()
                _ = try? activateSessionNow(reason: "warm")
            } else {
                deactivateSessionNow()
            }
        }
        #endif
    }

    #if os(iOS)
    /// Configures + activates the session if it isn't already (control queue).
    @discardableResult
    private static func activateSessionNow(reason: String) throws -> Bool {
        let session = AVAudioSession.sharedInstance()
        // Another engine (the Apple speech path) may have changed the category.
        if sessionReady, session.category == .playAndRecord { return false }
        let t0 = Date()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        let afterCategory = Int(Date().timeIntervalSince(t0) * 1000)
        // Smaller hardware I/O buffers: audio reaches the tap sooner.
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        sessionReady = true
        dlog("[voice] audio session activated (\(reason)): category \(afterCategory)ms, setActive \(Int(Date().timeIntervalSince(t0) * 1000) - afterCategory)ms, io \(Int(session.ioBufferDuration * 1000))ms")
        return true
    }

    private static func deactivateSessionNow() {
        guard sessionReady else { return }
        sessionReady = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        dlog("[voice] audio session released")
    }

    /// A call / Siri / another app takes the session: re-activate when it ends.
    private static func observeInterruptions() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            control.async {
                if type == .began {
                    sessionReady = false
                    dlog("[voice] audio session interrupted")
                } else if type == .ended, warmWanted {
                    _ = try? activateSessionNow(reason: "interruption ended")
                }
            }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
            control.async {
                sessionReady = false
                if warmWanted { _ = try? activateSessionNow(reason: "media services reset") }
            }
        }
    }
    #endif

    /// Pre-allocate the engine's resources WITHOUT going live, so the later
    /// `start()` reaches the mic in a few ms instead of paying the ~100-300ms
    /// cold-start tax. Called when a voice gesture is *likely* (e.g. the right
    /// button goes down) to overlap warm-up with the hold threshold the user is
    /// already waiting through. Never lights the mic indicator — only `start()`
    /// activates input. No-op once running.
    public func prewarm() {
        control.async { self.prewarmNow() }
    }

    private func prewarmNow() {
        guard !isRunning else { return }
        #if os(iOS)
        // PaloAlly: prewarm happens in the foreground (composer shown / app
        // active), so it also makes the session warm: active, no input I/O,
        // no mic indicator. Idempotent.
        if MicPermission.micAuthorizedSync() {
            Self.warmWanted = true
            Self.observeInterruptions()
            _ = try? Self.activateSessionNow(reason: "prewarm")
        }
        #endif
        // Touch the input node so CoreAudio instantiates the HAL unit now, then
        // preallocate render resources. Both costs are otherwise paid on start().
        _ = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
    }

    /// Starts capture off the main thread; `completion` runs on the control
    /// queue (nil = the mic is live).
    public func startAsync(targetSampleRate: Double = 16000, completion: @escaping @Sendable (Error?) -> Void) {
        control.async {
            do {
                try self.startNow(targetSampleRate: targetSampleRate)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    public func start(targetSampleRate: Double = 16000) throws {
        try control.sync { try startNow(targetSampleRate: targetSampleRate) }
    }

    private func startNow(targetSampleRate: Double) throws {
        let t0 = Date()
        let ms = { Int(Date().timeIntervalSince(t0) * 1000) }
        // Never stack a second engine/tap on top of a running one: installing two
        // taps on the same input bus corrupts CoreAudio and hangs the main thread.
        // A prior session that failed without a clean stop must be torn down first.
        if isRunning { stopNow() }
        engine.inputNode.removeTap(onBus: 0)   // belt-and-suspenders: drop any stale tap
        self.targetRate = targetSampleRate
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
        #if os(iOS)
        // Mode `.default` (bento): keeps the system's standard input processing
        // (AGC, noise handling); `.measurement` made far-field speech quiet and
        // noisy. PaloAlly: the session is normally already active (warm), so
        // this is ~0 ms; see the warm-session notes above.
        // Recording only happens in the foreground: keep the session warm
        // afterwards too (e.g. the first press right after granting the mic).
        Self.warmWanted = true
        Self.observeInterruptions()
        if try !Self.activateSessionNow(reason: "start") {
            dlog("[voice] audio session already active (warm)")
        }
        #endif

        let input = engine.inputNode
        // Sanity-check the mic is ready (macOS can hand back a 0Hz/0ch format
        // before it is). Don't reuse this format for the tap, though — read it
        // again at the moment of install via `nil`.
        let nodeFormat = input.outputFormat(forBus: 0)
        guard nodeFormat.sampleRate > 0, nodeFormat.channelCount > 0 else {
            throw CaptureError.converterUnavailable
        }
        // Converter is built lazily in handleBuffer from the ACTUAL buffer format.
        converter = nil
        converterInputFormat = nil

        // Install with `nil` format → the tap uses the input node's LIVE format.
        // Passing an explicit (possibly stale) format crashes hard: when the
        // device switched samplerate (e.g. 48kHz → a 24kHz Bluetooth mic after a
        // display unplug), installTap throws an uncatchable ObjC exception
        // ("Format mismatch: input hw 24000 Hz, client format 48000 Hz") and the
        // app dies. nil can never mismatch.
        // PaloAlly: 1024 frames (≈20 ms) instead of 4096, so audio reaches the
        // gate/socket sooner (a request; the system may still batch).
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, when in
            self?.handleBuffer(buffer, when: when)
        }

        loggedFirstBuffer = false
        let beforeEngine = ms()
        engine.prepare()
        engineStartedAt = ProcessInfo.processInfo.systemUptime
        try engine.start()
        isRunning = true
        dlog("[voice] engine.start \(ms() - beforeEngine)ms (capture start total \(ms())ms)")
    }

    public func stop() {
        control.async { self.stopNow() }
    }

    private func stopNow() {
        guard isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false
        converter = nil
        converterInputFormat = nil

        #if os(iOS)
        // PaloAlly: keep the session warm for the next press (released when
        // the app leaves the foreground); keep the engine's resources ready.
        if Self.warmWanted {
            engine.prepare()
        } else {
            Self.deactivateSessionNow()
        }
        #endif
    }

    private func handleBuffer(_ inputBuffer: AVAudioPCMBuffer, when: AVAudioTime? = nil) {
        guard let outputFormat else { return }
        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            // When the first SAMPLE was captured (host time, same base as the
            // touch's uptime) vs when this callback arrived.
            let now = ProcessInfo.processInfo.systemUptime
            var captured = ""
            if let when, when.isHostTimeValid {
                let t = AVAudioTime.seconds(forHostTime: when.hostTime)
                captured = voiceTouchUptime > 0
                    ? "first sample captured \(Int((t - voiceTouchUptime) * 1000))ms after touch, "
                    : "first sample captured \(Int((t - engineStartedAt) * 1000))ms after engine.start, "
            }
            dlog("[voice] first mic buffer: \(captured)callback \(Int((now - engineStartedAt) * 1000))ms after engine.start (\(inputBuffer.frameLength) frames @\(Int(inputBuffer.format.sampleRate))Hz)")
        }
        // Build / rebuild the converter to match the ACTUAL incoming format. The
        // nil-format tap delivers the node's live format, which may differ from
        // what we saw at start() (or change mid-session on a route switch), so the
        // converter is always derived from the buffer in hand.
        if converter == nil || converterInputFormat != inputBuffer.format {
            converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat)
            converterInputFormat = inputBuffer.format
        }
        guard let converter else { return }
        let inputRate = inputBuffer.format.sampleRate
        let estFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * targetRate / inputRate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: estFrames) else {
            return
        }

        var error: NSError?
        var didProvide = false
        let status = converter.convert(to: outBuf, error: &error) { _, status in
            if didProvide {
                // `.noDataNow` (not `.endOfStream`): we've handed over this tap
                // buffer; the converter consumes it and stays usable for the next
                // buffer. `.endOfStream` would permanently end the (reused)
                // converter, so only the first 100ms ever converted.
                status.pointee = .noDataNow
                return nil
            }
            didProvide = true
            status.pointee = .haveData
            return inputBuffer
        }

        guard error == nil, status != .error else { return }
        guard let int16Ptr = outBuf.int16ChannelData?[0] else { return }

        let frames = Int(outBuf.frameLength)
        let byteCount = frames * MemoryLayout<Int16>.stride
        guard byteCount > 0 else { return }   // never emit an empty chunk (→ "invalid audio")
        let data = Data(bytes: int16Ptr, count: byteCount)
        onPCM?(data)
    }
}
