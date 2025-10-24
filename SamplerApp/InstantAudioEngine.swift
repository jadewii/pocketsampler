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

    // MARK: - Recording (AVAudioEngine input tap for live waveform)
    private var isRecording = false
    private var currentPadNumber: Int?
    private var recordingFileWriter: AVAudioFile?
    private var accumulatedBuffer: AVAudioPCMBuffer?
    private let recordingQueue = DispatchQueue(label: "com.samplerapp.recording", qos: .userInitiated)

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

    func tempWavUrlForPad(_ padNumber: Int) -> URL {
        getDocumentsDirectory().appendingPathComponent("pad_\(padNumber)_temp.wav")
    }

    func startRecording(padNumber: Int) {
        guard !isRecording else {
            print("⚠️ Already recording")
            return
        }

        // Check engine state and try to restart if needed
        if !engine.isRunning {
            print("⚠️ Engine not running when starting recording, attempting to restart...")
            do {
                try engine.start()
                print("✅ Engine restarted successfully")
            } catch {
                print("❌ Cannot start recording: engine failed to start - \(error)")
                return
            }
        }

        currentPadNumber = padNumber
        let tempURL = tempWavUrlForPad(padNumber)

        // Delete existing temp file
        try? FileManager.default.removeItem(at: tempURL)

        // Get input node
        let inputNode = engine.inputNode

        // Create our target mono format (44.1kHz mono to match playback)
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 1,
            interleaved: false
        ) else {
            print("❌ Failed to create recording format")
            return
        }

        do {
            // Create WAV file writer
            recordingFileWriter = try AVAudioFile(forWriting: tempURL, settings: recordingFormat.settings)

            // Create accumulation buffer (start small, grow as needed)
            accumulatedBuffer = AVAudioPCMBuffer(pcmFormat: recordingFormat, frameCapacity: 44100 * 10) // 10 seconds max
            accumulatedBuffer?.frameLength = 0

            // Reset live waveform
            DispatchQueue.main.async { [weak self] in
                self?.liveRecordingWaveform = ([], [])
            }

            isRecording = true

            // Install tap on input node to capture audio buffers
            // Pass nil for format to use the node's natural format
            print("🎤 Installing tap on input node...")
            var bufferCount = 0
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, time in
                guard let self = self, self.isRecording else { return }

                bufferCount += 1
                if bufferCount == 1 {
                    print("🎧 First audio buffer received! Format: \(buffer.format.sampleRate)Hz, \(buffer.format.channelCount)ch, \(buffer.frameLength) frames")
                }

                // Get the actual input format from the buffer
                let inputFormat = buffer.format

                self.recordingQueue.async {
                    self.handleRecordingBuffer(buffer, originalFormat: inputFormat, targetFormat: recordingFormat)
                }
            }

            // CRITICAL: Must restart engine after installing tap for it to take effect
            print("🔄 Restarting engine to activate tap...")
            engine.stop()
            try engine.start()
            print("✅ Engine restarted with tap active")

            print("✅ Recording started for pad \(padNumber)")
            print("📂 Recording to: \(tempURL.path)")

        } catch {
            print("❌ Failed to start recording: \(error)")
            print("❌ Error details: \(error.localizedDescription)")
            isRecording = false
            recordingFileWriter = nil
            accumulatedBuffer = nil

            // Try to restart engine if it stopped
            if !engine.isRunning {
                print("⚠️ Engine stopped, attempting to restart...")
                do {
                    try engine.start()
                    print("✅ Engine restarted after error")
                } catch {
                    print("❌ Failed to restart engine: \(error)")
                }
            }
        }
    }

    private func handleRecordingBuffer(_ buffer: AVAudioPCMBuffer, originalFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        // Convert buffer to target format if needed (e.g., 48kHz stereo -> 44.1kHz mono)
        guard let convertedBuffer = convertBuffer(buffer, from: originalFormat, to: targetFormat) else {
            print("⚠️ Failed to convert recording buffer")
            return
        }

        print("📝 Processing buffer: \(convertedBuffer.frameLength) frames")

        // Write to file
        do {
            try recordingFileWriter?.write(from: convertedBuffer)
            print("✍️ Wrote \(convertedBuffer.frameLength) frames to file")
        } catch {
            print("❌ Failed to write recording buffer: \(error)")
        }

        // Accumulate buffer for live waveform
        guard let accumulated = accumulatedBuffer,
              let convertedData = convertedBuffer.floatChannelData,
              let accumulatedData = accumulated.floatChannelData else {
            return
        }

        let framesToCopy = Int(convertedBuffer.frameLength)
        let currentFrames = Int(accumulated.frameLength)
        let newTotalFrames = currentFrames + framesToCopy

        // Make sure we don't overflow
        guard newTotalFrames <= accumulated.frameCapacity else {
            print("⚠️ Recording buffer full, stopping accumulation")
            return
        }

        // Append new audio data
        for channel in 0..<Int(targetFormat.channelCount) {
            let src = convertedData[channel]
            let dst = accumulatedData[channel].advanced(by: currentFrames)
            dst.update(from: src, count: framesToCopy)
        }

        accumulated.frameLength = AVAudioFrameCount(newTotalFrames)

        // Update live waveform every ~0.1 seconds worth of audio
        if framesToCopy > 0 {
            let waveform = extractWaveform(from: accumulated, samples: 200)

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isRecording else { return }
                self.liveRecordingWaveform = waveform
            }
        }
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer, from sourceFormat: AVAudioFormat, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        // If formats match, just return the buffer
        if sourceFormat == targetFormat {
            return buffer
        }

        // Create converter
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            print("❌ Failed to create audio converter")
            return nil
        }

        // Calculate output frame count (handle sample rate conversion)
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            print("❌ Failed to create converted buffer")
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("❌ Conversion error: \(error)")
            return nil
        }

        return convertedBuffer
    }

    func stopRecording(completion: @escaping () -> Void) {
        guard isRecording, let padNumber = currentPadNumber else {
            print("⚠️ stopRecording called but not recording")
            completion()
            return
        }

        isRecording = false

        // Remove tap from input node
        engine.inputNode.removeTap(onBus: 0)

        // Close file writer
        recordingFileWriter = nil

        let tempWavURL = tempWavUrlForPad(padNumber)

        // Check temp WAV file was created
        if FileManager.default.fileExists(atPath: tempWavURL.path) {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: tempWavURL.path)
                let fileSize = attrs[.size] as? Int64 ?? 0
                print("⏹️ Recording stopped for pad \(padNumber) - Size: \(fileSize) bytes")

                if fileSize < 1000 {
                    print("⚠️ Warning: Recording is very small")
                }
            } catch {
                print("⚠️ Could not check recording size: \(error)")
            }
        } else {
            print("❌ Warning: Temp WAV file not found after stop")
        }

        // Clear live waveform
        DispatchQueue.main.async { [weak self] in
            self?.liveRecordingWaveform = ([], [])
        }

        // Process in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processRecording(padNumber: padNumber) {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }


    private func processRecording(padNumber: Int, completion: @escaping () -> Void) {
        let tempWavURL = tempWavUrlForPad(padNumber)
        let finalM4aURL = urlForPad(padNumber)

        guard FileManager.default.fileExists(atPath: tempWavURL.path) else {
            print("❌ processRecording: Temp WAV file doesn't exist at \(tempWavURL.path)")
            completion()
            return
        }

        do {
            // Read the temp WAV file
            let audioFile = try AVAudioFile(forReading: tempWavURL)
            let format = audioFile.processingFormat
            let frameCount = UInt32(audioFile.length)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                print("❌ Failed to allocate buffer for pad \(padNumber), deleting temp file")
                try? FileManager.default.removeItem(at: tempWavURL)
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

            // Convert to AAC and save to final .m4a file
            do {
                try convertToAAC(buffer: trimmedBuffer, outputURL: finalM4aURL, format: format)
                print("✅ Converted to AAC and saved to: \(finalM4aURL.path)")
            } catch {
                print("❌ Failed to convert to AAC: \(error)")
                try? FileManager.default.removeItem(at: tempWavURL)
                completion()
                return
            }

            // Delete temp WAV file
            try? FileManager.default.removeItem(at: tempWavURL)
            print("🗑️ Deleted temp WAV file")

            // Store in sample bank (ALL HEAVY WORK DONE NOW, NOT ON PLAYBACK)
            sampleBankQueue.async { [weak self] in
                guard let self = self else { return }

                // Create a copy of the buffer for storage
                guard let storedBuffer = AVAudioPCMBuffer(pcmFormat: trimmedBuffer.format, frameCapacity: trimmedBuffer.frameCapacity) else {
                    print("❌ Failed to copy buffer for pad \(padNumber)")
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
            print("   Deleting corrupt temp file")
            try? FileManager.default.removeItem(at: tempWavURL)
            completion()
        }
    }

    private func trimSilence(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let channelData = buffer.floatChannelData else { return buffer }

        let frameCount = Int(buffer.frameLength)
        let data = channelData[0]
        let threshold: Float = 0.005  // More aggressive silence threshold

        // Find first sample above threshold
        var startFrame = 0
        for i in 0..<frameCount {
            if abs(data[i]) > threshold {
                // Include minimal pre-roll (2ms at 44.1kHz = ~88 samples)
                startFrame = max(0, i - 88)
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

    func playRecording(padNumber: Int, trimStart: Float = 0.0, trimEnd: Float = 1.0) -> TimeInterval? {
        // Check if sample is in bank
        if let sampleData = sampleBank[padNumber] {
            // FAST PATH: Play from memory
            return playFromSampleBank(sampleData: sampleData, padNumber: padNumber, trimStart: trimStart, trimEnd: trimEnd)
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
            return playFromSampleBank(sampleData: sampleData, padNumber: padNumber, trimStart: trimStart, trimEnd: trimEnd)

        } catch {
            print("❌ Failed to load pad \(padNumber): \(error)")
            return nil
        }
    }

    func playFromSampleBank(sampleData: SampleData, padNumber: Int, trimStart: Float = 0.0, trimEnd: Float = 1.0) -> TimeInterval? {
        // Safety check: make sure engine is running BEFORE any voice operations
        guard engine.isRunning else {
            print("❌ playFromSampleBank: Engine not running, cannot play pad \(padNumber)")
            print("   Check console for engine startup errors")
            return nil
        }

        // Apply trim markers to buffer
        let bufferToPlay: AVAudioPCMBuffer
        let actualDuration: TimeInterval

        if trimStart > 0.0 || trimEnd < 1.0 {
            // Need to trim the buffer
            guard let trimmedBuffer = applyTrimToBuffer(sampleData.buffer, trimStart: trimStart, trimEnd: trimEnd) else {
                print("❌ Failed to apply trim")
                return nil
            }
            bufferToPlay = trimmedBuffer
            actualDuration = Double(trimmedBuffer.frameLength) / trimmedBuffer.format.sampleRate
            print("✂️ Playing trimmed: \(trimStart) to \(trimEnd) - Duration: \(actualDuration)s")
        } else {
            // Play full buffer
            bufferToPlay = sampleData.buffer
            actualDuration = Double(sampleData.buffer.frameLength) / sampleData.buffer.format.sampleRate
        }

        // Voice stealing: grab next voice from pool (round-robin)
        let voice = voicePool[nextVoiceIndex]
        nextVoiceIndex = (nextVoiceIndex + 1) % voiceCount

        // Stop voice if currently playing (safe because engine.isRunning == true)
        voice.playerNode.stop()

        // No pitch shift for regular playback
        voice.pitchNode.pitch = 0

        // Schedule buffer (buffer already in memory)
        voice.playerNode.scheduleBuffer(bufferToPlay, at: nil, options: [], completionHandler: nil)

        // Play NOW
        voice.playerNode.play()

        print("▶️ Playing pad \(padNumber) - Voice \(nextVoiceIndex - 1) - Duration: \(actualDuration)s")

        return actualDuration
    }

    private func applyTrimToBuffer(_ buffer: AVAudioPCMBuffer, trimStart: Float, trimEnd: Float) -> AVAudioPCMBuffer? {
        let totalFrames = Int(buffer.frameLength)
        let startFrame = Int(Float(totalFrames) * max(0, min(1, trimStart)))
        let endFrame = Int(Float(totalFrames) * max(0, min(1, trimEnd)))
        let trimmedLength = endFrame - startFrame

        guard trimmedLength > 0 else { return nil }

        guard let trimmedBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(trimmedLength)) else {
            return nil
        }

        trimmedBuffer.frameLength = AVAudioFrameCount(trimmedLength)

        // Copy trimmed portion
        if let srcData = buffer.floatChannelData,
           let dstData = trimmedBuffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                let src = srcData[channel].advanced(by: startFrame)
                let dst = dstData[channel]
                dst.update(from: src, count: trimmedLength)
            }
        }

        return trimmedBuffer
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

        // Remove tap from input node
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
        }

        // Close file writer
        recordingFileWriter = nil
        accumulatedBuffer = nil

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
