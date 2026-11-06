import Foundation
import AVFoundation
import PaloAllyObjC

/// Captures microphone audio and emits 16-bit mono PCM chunks at a target rate
/// (OpenAI gpt-realtime-whisper wants 24 kHz). AVAudioEngine + AVAudioConverter
/// so output is independent of the hardware rate. Cross-platform — only the
/// AVAudioSession setup is iOS-specific (macOS has no session model).
public final class AudioCaptureService: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case converterUnavailable
        case micUnavailable(String)
        var errorDescription: String? {
            switch self {
            case .converterUnavailable: "Could not create audio converter."
            case .micUnavailable(let reason): "The microphone could not start: \(reason)"
            }
        }
    }

    /// Replaced when the input hardware changed under it (see `engineChanged`).
    private var engine = AVAudioEngine()
    /// The input or output hardware changed (a device came or went, the Mac
    /// slept): the engine's graph may describe a device that's gone, and
    /// installing a tap on it raises (this Mac, 10-27, after 11 hours asleep).
    /// The next start makes a fresh engine.
    private var engineStale = false
    private var configObserver: NSObjectProtocol?
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

    public init() {
        observeConfiguration()
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    private func observeConfiguration() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.control.async {
                dlog("[voice] audio hardware changed: the next recording uses a fresh engine")
                self.engineStale = true
            }
        }
    }

    /// A new engine in place of one whose graph may be out of date. On the control queue, not running.
    private func replaceEngine() {
        _ = PAOCatchException { self.engine.inputNode.removeTap(onBus: 0) }
        engine = AVAudioEngine()
        engineStale = false
        observeConfiguration()
    }

    // MARK: - Warm session (PaloAlly)
    //
    // Device logs showed the first mic buffer ~700 ms after engine.start
    // whenever the session had to be (re)activated per press — the input
    // hardware waking up — so the first words were lost. With the session
    // already active it was ~50 ms.
    //
    // So they stay warm (the session active, the engine prepared) while the
    // app is in front, but only when that takes nothing from anyone (11-03,
    // the owner: music sounded wrong with PaloAlly open, voice unused):
    // - a phone or iPad: not while another app plays sound (our play-and-record
    //   session with a 20 ms buffer reshaped the music's output);
    // - the Mac: not while the input is a Bluetooth device (a prepared engine
    //   holds the input open, which turns AirPods to their call profile).
    // Checked every few seconds and after each recording; when it can't stay
    // warm the audio is given back (the music told it may carry on) and a
    // press pays the wake-up instead.
    //
    // Category .playAndRecord + .mixWithOthers: an active session must not
    // stop or duck the user's music. .defaultToSpeaker keeps playback on the
    // speaker instead of the earpiece; .allowBluetoothA2DP keeps headphones
    // in high-quality A2DP for music (the built-in mic records) rather than
    // switching them to the low-quality HFP profile. Mode .default keeps the
    // system's standard input processing (gain, noise) — no voice-chat ducking.

    /// The capture warmed last (one per app in practice), for `setSessionWarm(false)`.
    private static weak var current: AudioCaptureService?
    /// The app is in front with a composer: warmth is wanted when allowed.
    private var inFront = false
    /// The session is active and the engine prepared, ahead of a press.
    private var warm = false
    private var recheck: DispatchSourceTimer?

    /// Whether staying warm takes nothing from anyone now (control queue).
    private static func mayStayWarm() -> Bool {
        // Never before the mic is granted: touching the input would ask for it.
        #if targetEnvironment(macCatalyst)
        // The Mac: never (11-05, music sounded wrong after a recording on the
        // owner's company Mac): the mic opens at the press, closes after.
        return false
        #elseif os(iOS)
        return MicPermission.micAuthorizedSync() && !AVAudioSession.sharedInstance().isOtherAudioPlaying
        #else
        return true
        #endif
    }

    /// Warms or lets go, as `inFront` and `mayStayWarm` say (control queue).
    private func reconsider() {
        guard !isRunning else { return }
        let want = inFront && Self.mayStayWarm()
        if want, !warm {
            #if os(iOS)
            Self.warmWanted = true
            Self.observeInterruptions()
            guard (try? Self.activateSessionNow(reason: "warm")) != nil else { return }
            #endif
            if engineStale { replaceEngine() }
            _ = engine.inputNode.outputFormat(forBus: 0)
            if PAOCatchException({ self.engine.prepare() }) != nil { engineStale = true }
            warm = true
            dlog("[voice] warm: ready for a press")
        } else if !want, warm {
            engine.reset()
            #if os(iOS)
            Self.deactivateSessionNow()
            #endif
            warm = false
            dlog("[voice] cold: the audio given back (\(inFront ? "another app needs it" : "app away"))")
        }
    }

    private static var warmWanted = false
    private static var sessionReady = false
    private static var observing = false

    /// Keep the audio session active (foreground) or let it go (background).
    /// Only when microphone access is already granted — never prompts.
    public static func setSessionWarm(_ warm: Bool) {
        if !warm {
            control.async {
                guard let c = current else { return }
                c.inFront = false
                c.recheck?.cancel()
                c.recheck = nil
                c.reconsider()
            }
        }
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
        // Not on the Mac: a dictation app there leaves the device's buffer
        // alone (it is the whole Mac's, the music's too).
        #if !targetEnvironment(macCatalyst)
        try? session.setPreferredIOBufferDuration(0.02)
        #endif
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

    /// A call / Siri / another app takes the session: it's theirs until the next recording.
    private static func observeInterruptions() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            control.async {
                // Not taken back when it ends: the next recording takes it.
                if type == .began {
                    sessionReady = false
                    dlog("[voice] audio session interrupted")
                }
            }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
            control.async { sessionReady = false }
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
        // PaloAlly: warm only while that takes nothing from anyone, checked
        // again every 3 s (see Warm session above).
        Self.current = self
        inFront = true
        reconsider()
        guard recheck == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.reconsider() }
        timer.resume()
        recheck = timer
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
        if engineStale { replaceEngine() }
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
        Self.warmWanted = true
        Self.observeInterruptions()
        if try !Self.activateSessionNow(reason: "start") {
            dlog("[voice] audio session already active (warm)")
        }
        #endif

        #if targetEnvironment(macCatalyst)
        // The Mac: a Bluetooth headset's mic is never used: opening it switches the headset to its
        // call profile, mono and 8 to 16 kHz, for the music too, and it comes
        // back only well after. The built-in mic records instead, as other
        // dictation apps do (Wispr Flow, Superwhisper).
        let picked = MacAudioInput.preferBuiltIn(for: engine.inputNode)
        dlog("[voice] audio before: \(MacAudioInput.describe())\(picked.map { ", recording from \($0)" } ?? "")")
        #endif
        // The input node is touched only now, the session set to record: on
        // the Mac one made before had no channels, for good (11-05, every
        // press failed once nothing kept the session warm).
        engine.inputNode.removeTap(onBus: 0)   // belt-and-suspenders: drop any stale tap
        var input = engine.inputNode
        // Sanity-check the mic is ready (macOS can hand back a 0Hz/0ch format
        // before it is). Don't reuse this format for the tap, though — read it
        // again at the moment of install via `nil`. Empty: once more on a
        // fresh engine, made after the session.
        var nodeFormat = input.outputFormat(forBus: 0)
        if nodeFormat.sampleRate <= 0 || nodeFormat.channelCount == 0 {
            dlog("[voice] the mic's format was empty (\(nodeFormat.sampleRate) Hz, \(nodeFormat.channelCount) ch): a fresh engine")
            replaceEngine()
            #if targetEnvironment(macCatalyst)
            _ = MacAudioInput.preferBuiltIn(for: engine.inputNode)
            #endif
            input = engine.inputNode
            nodeFormat = input.outputFormat(forBus: 0)
            dlog("[voice] fresh engine's mic: \(nodeFormat.sampleRate) Hz, \(nodeFormat.channelCount) ch")
        }
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
        //
        // It can still raise when the engine's graph is out of date (the input
        // device changed while the app wasn't told): caught, a fresh engine
        // gets one more try, and a second failure is an error, not a crash.
        if let exception = installTap(on: input) {
            dlog("[voice] installTap raised \(exception.name.rawValue): \(exception.reason ?? "") — retrying on a fresh engine")
            replaceEngine()
            let fresh = engine.inputNode.outputFormat(forBus: 0)
            guard fresh.sampleRate > 0, fresh.channelCount > 0 else {
                throw CaptureError.converterUnavailable
            }
            if let again = installTap(on: engine.inputNode) {
                dlog("[voice] installTap raised again \(again.name.rawValue): \(again.reason ?? "")")
                throw CaptureError.micUnavailable(again.reason ?? again.name.rawValue)
            }
        }

        loggedFirstBuffer = false
        let beforeEngine = ms()
        if let exception = PAOCatchException({ self.engine.prepare() }) {
            engine.inputNode.removeTap(onBus: 0)
            engineStale = true
            throw CaptureError.micUnavailable(exception.reason ?? exception.name.rawValue)
        }
        engineStartedAt = ProcessInfo.processInfo.systemUptime
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engineStale = true
            throw error
        }
        isRunning = true
        dlog("[voice] engine.start \(ms() - beforeEngine)ms (capture start total \(ms())ms)")
    }

    public func stop() {
        control.async { self.stopNow() }
    }

    /// The tap that feeds `handleBuffer`; the exception if installing it raised.
    private func installTap(on input: AVAudioInputNode) -> NSException? {
        PAOCatchException {
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, when in
                self?.handleBuffer(buffer, when: when)
            }
        }
    }

    private func stopNow() {
        guard isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false
        converter = nil
        converterInputFormat = nil

        // PaloAlly: warm again for the next press when that takes nothing
        // from anyone, else the input closes and the session goes.
        warm = false
        engine.reset()
        if inFront && Self.mayStayWarm() {
            reconsider()
        } else {
            #if os(iOS)
            Self.deactivateSessionNow()
            #endif
        }
        #if targetEnvironment(macCatalyst)
        // Whether the headset stayed in its music profile, and came back (the log).
        dlog("[voice] audio after: \(MacAudioInput.describe())")
        Self.control.asyncAfter(deadline: .now() + 5) { dlog("[voice] audio 5 s after: \(MacAudioInput.describe())") }
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

#if targetEnvironment(macCatalyst)
import CoreAudio

/// The Mac's audio devices, as CoreAudio has them.
enum MacAudioInput {
    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        _ = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return value
    }

    private static func defaultDevice(input: Bool) -> AudioDeviceID {
        property(AudioObjectID(kAudioObjectSystemObject),
                 input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0))
    }

    private static func name(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return "?" }
        return name.takeRetainedValue() as String
    }

    private static func transport(_ device: AudioDeviceID) -> UInt32 { property(device, kAudioDevicePropertyTransportType, UInt32(0)) }

    private static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let t = transport(device)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    /// "in: MacBook Air Microphone (built-in, 48000 Hz) · out: AirPods (Bluetooth, 48000 Hz)", for the log.
    static func describe() -> String {
        func one(_ d: AudioDeviceID) -> String {
            let kind = isBluetooth(d) ? "Bluetooth" : transport(d) == kAudioDeviceTransportTypeBuiltIn ? "built-in" : "other"
            let rate = property(d, kAudioDevicePropertyNominalSampleRate, Float64(0))
            return "\(name(d)) (\(kind), \(Int(rate)) Hz)"
        }
        return "in: \(one(defaultDevice(input: true))) · out: \(one(defaultDevice(input: false)))"
    }

    /// The input node records from the built-in mic when the default input
    /// is a Bluetooth headset. The device's name when it switched, else nil.
    static func preferBuiltIn(for input: AVAudioInputNode) -> String? {
        guard isBluetooth(defaultDevice(input: true)), let unit = input.audioUnit else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        for d in devices where transport(d) == kAudioDeviceTransportTypeBuiltIn {
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes = UInt32(0)
            guard AudioObjectGetPropertyDataSize(d, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { continue }
            var id = d
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status == noErr { return name(d) }
            dlog("[voice] the built-in mic couldn't be picked (\(status)): the default input records")
            return nil
        }
        return nil
    }

}
#endif
