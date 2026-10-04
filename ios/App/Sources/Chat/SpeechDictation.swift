import AVFoundation
import Observation
import Speech

/// Hold-to-talk dictation via the Speech framework (on-device when possible).
@MainActor
@Observable
final class SpeechDictation {
    private(set) var isRecording = false
    private(set) var transcript = ""
    var errorMessage: String?
    /// Recent input loudness, 0…1 (drives the waveform).
    private(set) var level: Float = 0
    private var gotFinal = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) ?? SFSpeechRecognizer()

    func start() async {
        errorMessage = nil
        guard await Self.authorize() else {
            errorMessage = "需要在「设置」里允许使用麦克风和语音识别"
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "现在没法听写，稍后再试"
            return
        }
        do {
            #if !os(macOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            // The tap runs on the audio thread: keep the closure nonisolated.
            nonisolated(unsafe) let sink = request
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
                sink.append(buffer)
                let rms = Self.rms(buffer)
                Task { @MainActor in self?.level = rms }
            }
            engine.prepare()
            try engine.start()
            transcript = ""
            gotFinal = false
            isRecording = true

            task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if error != nil || final {
                        self.gotFinal = true
                        self.stop()
                    }
                }
            }
        } catch {
            errorMessage = "麦克风没打开，再试一次"
            stop()
        }
    }

    /// Stops listening and waits briefly for the recognizer's final text.
    func finish(timeout: Double = 1.5) async -> String {
        guard isRecording || task != nil else { return transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        let deadline = Date().addingTimeInterval(timeout)
        while !gotFinal && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        stop()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops and throws the text away.
    func cancel() {
        task?.cancel()
        stop()
        transcript = ""
    }

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = (sum / Float(n)).squareRoot()
        // Map roughly -50 dB…-10 dB to 0…1.
        let db = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (db + 50) / 40))
    }

    func stop() {
        guard isRecording || engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isRecording = false
        level = 0
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // nonisolated + @Sendable: the system calls back on a background queue, and
    // a main-actor closure there traps at runtime (Swift 6 isolation check).
    nonisolated private static func authorize() async -> Bool {
        let speech: Bool = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in c.resume(returning: status == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
