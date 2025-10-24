import AVFoundation
import Accelerate

// MARK: - Sample Bank (In-Memory Audio Storage)
struct SampleData {
    let buffer: AVAudioPCMBuffer
    let waveformHiRes: (min: [Float], max: [Float])
}

class InstantAudioEngine: NSObject, ObservableObject {
    // MARK: - Sample Bank
    private var sampleBank: [Int: SampleData] = [:]  // padNumber -> decoded audio + waveform
    private let sampleBankQueue = DispatchQueue(label: "com.samplerapp.samplebank", qos: .userInitiated)

    // MARK: - Recording (AVAudioEngine-based with live waveform)
    private var isRecording = false
    private var currentPadNumber: Int?
    private var recordedSamples: [Float] = []  // Accumulate samples during recording
    private var recordingSampleRate: Double = 44100.0  // Track actual input sample rate
    private var waveformUpdateTimer: Timer?

    @Published var liveRecordingWaveform: (min: [Float], max: [Float]) = ([], [])

    // MARK: - Permanent AVAudioEngine + Voice Pool
    private let engine: AVAudioEngine
    private let voicePool: [Voice]
    private var nextVoiceIndex = 0
    private let voiceCount = 12

    struct Voice {
        let playerNode: AVAudioPlayerNode
        let pitchNode: AVAudioUnitTimePitch
    }

    @Published var engineReady = false

    override init() {
        // Build permanent engine + voice pool BEFORE calling super.init()
        engine = AVAudioEngine()

        // Define consistent audio format: 44.1kHz MONO (matches our recordings)
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 1,  // MONO - matches AVAudioRecorder settings
            interleaved: false
        ) else {
            fatalError("Failed to create audio format")
        }

        // Create voice pool
        var voices: [Voice] = []
        for i in 0..<12 {
            let player = AVAudioPlayerNode()
            let pitch = AVAudioUnitTimePitch()

            engine.attach(player)
            engine.attach(pitch)

            // CRITICAL: Connect with explicit MONO format (not nil!)
            engine.connect(player, to: pitch, format: monoFormat)
            engine.connect(pitch, to: engine.mainMixerNode, format: monoFormat)

            voices.append(Voice(playerNode: player, pitchNode: pitch))
            print("🎹 Voice \(i) created and connected (mono 44.1kHz)")
        }
        voicePool = voices

        super.init()
        print("🎵 InstantAudioEngine initializing...")

        // CRITICAL: Setup audio session and start engine SYNCHRONOUSLY
        // Must be ready before any playback attempts
        setupAudioSession()
    }

    private func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()

        do {
            // Configure for both recording and playback with speaker output
            // SET ONCE AT LAUNCH - NEVER RECONFIGURE
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])

            print("✅ Audio session ready")
            print("📱 Category: \(audioSession.category.rawValue)")
            print("🔊 Route: \(audioSession.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", "))")

            // Start engine ONCE and NEVER stop it
            try engine.start()
            print("✅ AVAudioEngine started (will run forever)")
            print("   isRunning: \(engine.isRunning)")

            DispatchQueue.main.async { [weak self] in
                self?.engineReady = true
            }

        } catch {
            print("❌ Audio session/engine setup FAILED: \(error)")
            print("❌ This will prevent playback from working!")
            print("❌ Make sure microphone permissions are granted")

            // Still set engineReady to avoid blocking UI, but engine won't work
            DispatchQueue.main.async { [weak self] in
                self?.engineReady = true
            }
        }
    }

    func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func urlForPad(_ padNumber: Int) -> URL {
        getDocumentsDirectory().appendingPathComponent("pad_\(padNumber).m4a")
    }

    func startRecording(padNumber: Int) {
        guard !isRecording else {
            print("⚠️ Already recording")
            return
        }

        guard engine.isRunning else {
            print("❌ Engine not running, cannot record")
            return
        }

        // Install tap on input node to capture live audio
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Validate input format - simulator may have invalid format (0.0Hz)
        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            print("❌ Invalid input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")
            print("❌ This usually means:")
            print("   - Running on simulator without microphone access")
            print("   - No audio input device available")
            print("   - Try running on a real device")
            return
        }

        currentPadNumber = padNumber
        isRecording = true
        recordedSamples = []

        // Reset live waveform
        DispatchQueue.main.async { [weak self] in
            self?.liveRecordingWaveform = ([], [])
        }

        // Store the actual input sample rate so we can create buffers correctly
        recordingSampleRate = inputFormat.sampleRate

        print("🎤 Starting AVAudioEngine recording for pad \(padNumber)")
        print("   Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")

        // Install tap to capture PCM samples (use nil format to get native format)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, time in
            guard let self = self, self.isRecording else { return }

            // Extract samples from buffer (always use first channel for mono)
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

            // Append to recorded samples
            self.recordedSamples.append(contentsOf: samples)
        }

        // Start timer to update live waveform every 50ms
        waveformUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateLiveWaveform()
        }

        print("✅ Recording started with live waveform capture")
    }

    func stopRecording(completion: @escaping () -> Void) {
        guard isRecording, let padNumber = currentPadNumber else {
            print("⚠️ stopRecording called but not recording")
            completion()
            return
        }

        isRecording = false

        // Stop timer
        waveformUpdateTimer?.invalidate()
        waveformUpdateTimer = nil

        // Remove tap from input node (wrapped in safety check)
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
        }

        print("⏹️ Recording stopped for pad \(padNumber)")
        print("   Captured \(recordedSamples.count) samples (\(Double(recordedSamples.count) / recordingSampleRate)s)")

        // Clear live waveform
        DispatchQueue.main.async { [weak self] in
            self?.liveRecordingWaveform = ([], [])
        }

        // Process recorded samples in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processRecordedSamples(padNumber: padNumber) {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }

    private func updateLiveWaveform() {
        guard isRecording && !recordedSamples.isEmpty else { return }

        // Generate waveform from current recorded samples (200 samples for display)
        let waveform = generateWaveformFromSamples(recordedSamples, targetSamples: 200)

        DispatchQueue.main.async { [weak self] in
            self?.liveRecordingWaveform = waveform
        }
    }

    private func generateWaveformFromSamples(_ samples: [Float], targetSamples: Int) -> (min: [Float], max: [Float]) {
        guard !samples.isEmpty else { return ([], []) }

        let sampleCount = samples.count
        let window = max(1, sampleCount / targetSamples)
        var mins: [Float] = []
        var maxs: [Float] = []
        mins.reserveCapacity(targetSamples)
        maxs.reserveCapacity(targetSamples)

        var i = 0
        while i < sampleCount {
            let end = min(i + window, sampleCount)
            var mn: Float = 1.0
            var mx: Float = -1.0
            var j = i
            while j < end {
                let v = samples[j]
                if v < mn { mn = v }
                if v > mx { mx = v }
                j += 1
            }
            mins.append(mn)
            maxs.append(mx)
            i += window
        }

        return (min: mins, max: maxs)
    }

    private func processRecordedSamples(padNumber: Int, completion: @escaping () -> Void) {
        guard !recordedSamples.isEmpty else {
            print("❌ No samples recorded")
            completion()
            return
        }

        // Create buffer with the ACTUAL recording sample rate (not 44.1kHz)
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: recordingSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            print("❌ Failed to create input format at \(recordingSampleRate)Hz")
            completion()
            return
        }

        let frameCount = recordedSamples.count
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            print("❌ Failed to allocate input buffer")
            completion()
            return
        }

        inputBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy samples to input buffer
        if let channelData = inputBuffer.floatChannelData {
            channelData[0].update(from: recordedSamples, count: frameCount)
        }

        print("📼 Processing \(frameCount) samples at \(recordingSampleRate)Hz")

        // Resample to 44.1kHz mono if needed
        let targetSampleRate: Double = 44100.0
        let finalBuffer: AVAudioPCMBuffer

        if recordingSampleRate != targetSampleRate {
            print("🔄 Resampling from \(recordingSampleRate)Hz to \(targetSampleRate)Hz")

            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            ) else {
                print("❌ Failed to create output format")
                completion()
                return
            }

            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                print("❌ Failed to create converter")
                completion()
                return
            }

            // Calculate output frame count
            let outputFrameCount = AVAudioFrameCount(Double(frameCount) * targetSampleRate / recordingSampleRate)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount + 1024) else {
                print("❌ Failed to allocate output buffer")
                completion()
                return
            }

            var error: NSError?
            let inputBufferCopy = inputBuffer // Keep reference

            converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return inputBufferCopy
            }

            if let error = error {
                print("❌ Conversion failed: \(error)")
                completion()
                return
            }

            finalBuffer = outputBuffer
            print("✅ Resampled to \(outputBuffer.frameLength) frames at 44.1kHz")
        } else {
            finalBuffer = inputBuffer
            print("✓ Already at 44.1kHz, no resampling needed")
        }

        // Now process the buffer (trim, fade, normalize, store)
        let trimmedBuffer = trimSilence(from: finalBuffer)
        applyFades(to: trimmedBuffer)
        normalize(buffer: trimmedBuffer)

        // Generate hi-res waveform
        let waveformHiRes = extractWaveform(from: trimmedBuffer, samples: 200)

        // Convert to AAC and save to file
        let fileURL = urlForPad(padNumber)
        do {
            try convertToAAC(buffer: trimmedBuffer, outputURL: fileURL, format: trimmedBuffer.format)
            print("✅ Saved recording to: \(fileURL.path)")
        } catch {
            print("❌ Failed to save AAC file: \(error)")
            completion()
            return
        }

        // Store in sample bank
        sampleBankQueue.async { [weak self] in
            guard let self = self else { return }

            // Create a copy for storage
            guard let storedBuffer = AVAudioPCMBuffer(pcmFormat: trimmedBuffer.format, frameCapacity: trimmedBuffer.frameCapacity) else {
                print("❌ Failed to copy buffer")
                completion()
                return
            }
            storedBuffer.frameLength = trimmedBuffer.frameLength

            if let srcData = trimmedBuffer.floatChannelData,
               let dstData = storedBuffer.floatChannelData {
                for channel in 0..<Int(trimmedBuffer.format.channelCount) {
                    dstData[channel].update(from: srcData[channel], count: Int(trimmedBuffer.frameLength))
                }
            }

            let sampleData = SampleData(buffer: storedBuffer, waveformHiRes: waveformHiRes)
            self.sampleBank[padNumber] = sampleData

            print("✅ Pad \(padNumber) stored in sample bank")
            completion()
        }
    }

    private func processRecording(padNumber: Int, completion: @escaping () -> Void) {
        let fileURL = urlForPad(padNumber)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("❌ processRecording: File doesn't exist at \(fileURL.path)")
            completion()
            return
        }

        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let format = audioFile.processingFormat
            let frameCount = UInt32(audioFile.length)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                print("❌ Failed to allocate buffer for pad \(padNumber), deleting file")
                try? FileManager.default.removeItem(at: fileURL)
                completion()
                return
            }

            try audioFile.read(into: buffer)

            // Trim silence from beginning
            let trimmedBuffer = trimSilence(from: buffer)

            // Apply fades and normalize
            applyFades(to: trimmedBuffer)
            normalize(buffer: trimmedBuffer)

            // Generate hi-res waveform from trimmed buffer (200 samples for editor)
            let waveformHiRes = extractWaveform(from: trimmedBuffer, samples: 200)

            // Store in sample bank (ALL HEAVY WORK DONE NOW, NOT ON PLAYBACK)
            sampleBankQueue.async { [weak self] in
                guard let self = self else { return }

                // Create a copy of the buffer for storage
                guard let storedBuffer = AVAudioPCMBuffer(pcmFormat: trimmedBuffer.format, frameCapacity: trimmedBuffer.frameCapacity) else {
                    print("❌ Failed to copy buffer for pad \(padNumber), deleting file")
                    try? FileManager.default.removeItem(at: fileURL)
                    completion()
                    return
                }
                storedBuffer.frameLength = trimmedBuffer.frameLength

                // Copy audio data
                if let srcData = trimmedBuffer.floatChannelData,
                   let dstData = storedBuffer.floatChannelData {
                    for channel in 0..<Int(trimmedBuffer.format.channelCount) {
                        dstData[channel].update(from: srcData[channel], count: Int(trimmedBuffer.frameLength))
                    }
                }

                let sampleData = SampleData(buffer: storedBuffer, waveformHiRes: waveformHiRes)
                self.sampleBank[padNumber] = sampleData

                print("✅ Pad \(padNumber) decoded and stored in sample bank")
                print("   Buffer: \(storedBuffer.frameLength) frames")
                print("   Waveform: \(waveformHiRes.min.count) samples")

                completion()
            }

        } catch {
            print("❌ Failed to process recording for pad \(padNumber): \(error)")
            print("   Deleting corrupt file")
            try? FileManager.default.removeItem(at: fileURL)
            completion()
        }
    }

    private func trimSilence(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let channelData = buffer.floatChannelData else { return buffer }

        let frameCount = Int(buffer.frameLength)
        let data = channelData[0]
        let threshold: Float = 0.02  // Silence threshold (adjust as needed)

        // Find first sample above threshold
        var startFrame = 0
        for i in 0..<frameCount {
            if abs(data[i]) > threshold {
                // Include a small pre-roll (50ms at 44.1kHz = ~2200 samples)
                startFrame = max(0, i - 2200)
                break
            }
        }

        // If no sound detected, return original buffer
        if startFrame >= frameCount - 100 {
            print("⚠️ No sound detected above threshold, keeping original")
            return buffer
        }

        // Create new buffer with trimmed audio
        let trimmedLength = frameCount - startFrame
        guard let trimmedBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(trimmedLength)) else {
            return buffer
        }

        trimmedBuffer.frameLength = AVAudioFrameCount(trimmedLength)

        // Copy data
        if let trimmedData = trimmedBuffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                let src = channelData[channel].advanced(by: startFrame)
                let dst = trimmedData[channel]
                dst.update(from: src, count: trimmedLength)
            }
        }

        print("✅ Trimmed \(startFrame) silent samples (\(Float(startFrame) / 44100.0)s)")
        return trimmedBuffer
    }


    private func applyFades(to buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let fadeLength = min(220, frameCount / 10) // 5ms fade at 44.1kHz

        let data = channelData[0]

        // Fade in
        for i in 0..<fadeLength {
            let gain = Float(i) / Float(fadeLength)
            data[i] *= gain
        }

        // Fade out
        for i in 0..<fadeLength {
            let index = frameCount - fadeLength + i
            if index < frameCount {
                let gain = Float(fadeLength - i) / Float(fadeLength)
                data[index] *= gain
            }
        }
    }

    private func normalize(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let data = channelData[0]

        // Find peak
        var peak: Float = 0
        vDSP_maxv(data, 1, &peak, vDSP_Length(frameCount))

        // Normalize to -0.1dB (0.9)
        if peak > 0.001 {
            var gain: Float = 0.9 / peak
            vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(frameCount))
        }
    }

    private func extractWaveform(from buffer: AVAudioPCMBuffer, samples: Int) -> (min: [Float], max: [Float]) {
        guard let channelData = buffer.floatChannelData else {
            return ([], [])
        }

        let frameCount = Int(buffer.frameLength)
        let data = channelData[0]
        let window = max(1, frameCount / samples)
        var mins: [Float] = []
        var maxs: [Float] = []
        mins.reserveCapacity(samples)
        maxs.reserveCapacity(samples)

        var i = 0
        while i < frameCount {
            let end = min(i + window, frameCount)
            var mn: Float =  1.0
            var mx: Float = -1.0
            var j = i
            while j < end {
                let v = data[j]
                if v < mn { mn = v }
                if v > mx { mx = v }
                j += 1
            }
            mins.append(mn)
            maxs.append(mx)
            i += window
        }

        return (mins, maxs)
    }

    private func convertToAAC(buffer: AVAudioPCMBuffer, outputURL: URL, format: AVAudioFormat) throws {
        // Delete existing file
        try? FileManager.default.removeItem(at: outputURL)

        // Create AAC file
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
        try outputFile.write(from: buffer)
    }

    func playRecordingWithPitch(padNumber: Int, semitoneOffset: Int) -> TimeInterval? {
        // Check if sample is in bank
        var sampleData: SampleData?

        if let cached = sampleBank[padNumber] {
            sampleData = cached
        } else {
            // Lazy load from disk
            print("⚠️ Sample \(padNumber) not in bank, loading from disk...")
            let fileURL = urlForPad(padNumber)

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                print("❌ No file found for pad \(padNumber)")
                return nil
            }

            do {
                let audioFile = try AVAudioFile(forReading: fileURL)
                let format = audioFile.processingFormat
                let frameCount = UInt32(audioFile.length)

                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                    return nil
                }

                try audioFile.read(into: buffer)
                let waveform = extractWaveform(from: buffer, samples: 200)
                let loaded = SampleData(buffer: buffer, waveformHiRes: waveform)
                sampleBank[padNumber] = loaded
                sampleData = loaded
                print("✅ Loaded pad \(padNumber) into sample bank")

            } catch {
                print("❌ Failed to load pad \(padNumber): \(error)")
                return nil
            }
        }

        guard let sample = sampleData else { return nil }

        // Safety check: make sure engine is running BEFORE any voice operations
        guard engine.isRunning else {
            print("❌ playRecordingWithPitch: Engine not running, cannot play pad \(padNumber)")
            print("   Check console for engine startup errors")
            return nil
        }

        // Voice stealing: grab next voice from pool (round-robin)
        let voice = voicePool[nextVoiceIndex]
        nextVoiceIndex = (nextVoiceIndex + 1) % voiceCount

        // Stop voice if currently playing (safe because engine.isRunning == true)
        voice.playerNode.stop()

        // Set pitch (100 cents = 1 semitone)
        voice.pitchNode.pitch = Float(semitoneOffset * 100)

        // Schedule buffer (buffer already in memory)
        voice.playerNode.scheduleBuffer(sample.buffer, at: nil, options: [], completionHandler: nil)

        // Play NOW
        voice.playerNode.play()

        let duration = Double(sample.buffer.frameLength) / sample.buffer.format.sampleRate
        print("🎹 Playing pad \(padNumber) at \(semitoneOffset > 0 ? "+" : "")\(semitoneOffset) semitones - Voice \(nextVoiceIndex - 1)")

        return duration
    }

    func playRecording(padNumber: Int) -> TimeInterval? {
        // Check if sample is in bank
        if let sampleData = sampleBank[padNumber] {
            // FAST PATH: Play from memory
            return playFromSampleBank(sampleData: sampleData, padNumber: padNumber)
        }

        // SLOW PATH: Sample not in bank yet (old recording or not processed)
        // Try to load it from file
        print("⚠️ Sample \(padNumber) not in bank, loading from disk...")

        let fileURL = urlForPad(padNumber)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("❌ No file found for pad \(padNumber)")
            return nil
        }

        // Load file into sample bank (this will take a moment)
        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let format = audioFile.processingFormat
            let frameCount = UInt32(audioFile.length)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return nil
            }

            try audioFile.read(into: buffer)

            // Generate waveform
            let waveform = extractWaveform(from: buffer, samples: 200)

            // Store in sample bank
            let sampleData = SampleData(buffer: buffer, waveformHiRes: waveform)
            sampleBank[padNumber] = sampleData

            print("✅ Loaded pad \(padNumber) into sample bank")

            // Now play it
            return playFromSampleBank(sampleData: sampleData, padNumber: padNumber)

        } catch {
            print("❌ Failed to load pad \(padNumber): \(error)")
            return nil
        }
    }

    private func playFromSampleBank(sampleData: SampleData, padNumber: Int) -> TimeInterval? {
        // Safety check: make sure engine is running BEFORE any voice operations
        guard engine.isRunning else {
            print("❌ playFromSampleBank: Engine not running, cannot play pad \(padNumber)")
            print("   Check console for engine startup errors")
            return nil
        }

        // Voice stealing: grab next voice from pool (round-robin)
        let voice = voicePool[nextVoiceIndex]
        nextVoiceIndex = (nextVoiceIndex + 1) % voiceCount

        // Stop voice if currently playing (safe because engine.isRunning == true)
        voice.playerNode.stop()

        // No pitch shift for regular playback
        voice.pitchNode.pitch = 0

        // Schedule buffer (buffer already in memory)
        voice.playerNode.scheduleBuffer(sampleData.buffer, at: nil, options: [], completionHandler: nil)

        // Play NOW
        voice.playerNode.play()

        let duration = Double(sampleData.buffer.frameLength) / sampleData.buffer.format.sampleRate
        print("▶️ Playing pad \(padNumber) - Voice \(nextVoiceIndex - 1) - Duration: \(duration)s")

        return duration
    }

    func hasRecording(padNumber: Int) -> Bool {
        // Check sample bank first (fast)
        if sampleBank[padNumber] != nil {
            return true
        }

        // Fallback: check if file exists on disk (for old recordings)
        let fileURL = urlForPad(padNumber)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    func deleteRecording(padNumber: Int) {
        // Remove from sample bank
        sampleBankQueue.async { [weak self] in
            self?.sampleBank[padNumber] = nil
        }

        // Also delete file
        let fileURL = urlForPad(padNumber)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Safe Clear Operations

    func stopAllVoices() {
        // Safety: Only stop if engine is running
        guard engine.isRunning else {
            print("⚠️ stopAllVoices: Engine not running, skipping")
            return
        }

        // Stop all voices in the pool (don't destroy, just stop playback)
        for voice in voicePool {
            voice.playerNode.stop()
        }
        print("🛑 Stopped all voices")
    }

    func stopRecordingIfActive() {
        guard isRecording else { return }

        print("🛑 Stopping active recording (forced)")
        isRecording = false

        // Stop timer
        waveformUpdateTimer?.invalidate()
        waveformUpdateTimer = nil

        // Remove tap (wrapped in safety check)
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
        }

        // Clear samples
        recordedSamples = []
        currentPadNumber = nil

        // Clear live waveform
        DispatchQueue.main.async { [weak self] in
            self?.liveRecordingWaveform = ([], [])
        }
    }

    func clearPad(_ padNumber: Int) {
        // Stop any voices playing this pad (if engine is running)
        if engine.isRunning {
            for voice in voicePool {
                voice.playerNode.stop()
            }
        }

        // Stop recording if this pad is being recorded
        if isRecording && currentPadNumber == padNumber {
            stopRecordingIfActive()
        }

        // Remove from sample bank
        sampleBankQueue.sync {
            sampleBank[padNumber] = nil
        }

        // Delete file on disk
        let fileURL = urlForPad(padNumber)
        try? FileManager.default.removeItem(at: fileURL)

        print("🗑️ Cleared pad \(padNumber)")
    }

    func clearAllPads() {
        print("🗑️ Clearing all pads...")

        // Stop all voices first
        stopAllVoices()

        // Stop any active recording
        stopRecordingIfActive()

        // Clear each pad individually (safe, in-place)
        for padNumber in 1...(11 * 8) {
            sampleBankQueue.sync {
                sampleBank[padNumber] = nil
            }

            // Delete file
            let fileURL = urlForPad(padNumber)
            try? FileManager.default.removeItem(at: fileURL)
        }

        print("✅ All pads cleared")
    }

    func getWaveformData(padNumber: Int, samples: Int) -> (min: [Float], max: [Float]) {
        // FAST PATH: If sample is in bank, return waveform (already computed)
        if let sampleData = sampleBank[padNumber] {
            // Downsample if needed
            if samples == 200 || sampleData.waveformHiRes.min.count == samples {
                return sampleData.waveformHiRes
            }
            // Need different resolution - extract from buffer
            return extractWaveform(from: sampleData.buffer, samples: samples)
        }

        // SLOW PATH: Sample not in bank yet (old recording or during recording)
        let fileURL = urlForPad(padNumber)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ([], [])
        }

        // Try to read file and generate waveform
        do {
            let file = try AVAudioFile(forReading: fileURL)
            let format = file.processingFormat
            let frameCount = UInt32(file.length)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return ([], [])
            }

            try file.read(into: buffer)
            let waveform = extractWaveform(from: buffer, samples: samples)

            // If not currently recording this pad, store in sample bank for future use
            if !isRecording || currentPadNumber != padNumber {
                let hiResWaveform = extractWaveform(from: buffer, samples: 200)
                let sampleData = SampleData(buffer: buffer, waveformHiRes: hiResWaveform)
                sampleBank[padNumber] = sampleData
                print("✅ Lazy-loaded pad \(padNumber) into sample bank (from getWaveformData)")
            }

            return waveform

        } catch {
            // File not ready yet (or error reading)
            return ([], [])
        }
    }
}
