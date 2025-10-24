import AVFoundation
import Foundation

class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    var audioRecorder: AVAudioRecorder?
    var audioPlayer: AVAudioPlayer?

    @Published var isRecording = false

    override init() {
        super.init()
        setupAudioSession()
    }

    func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
            print("✅ Audio session setup successful")
        } catch {
            print("❌ Failed to set up audio session: \(error)")
        }
    }

    func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func startRecording(padNumber: Int) {
        let audioFilename = getDocumentsDirectory().appendingPathComponent("pad_\(padNumber).m4a")

        print("🎤 Starting recording to: \(audioFilename.path)")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,  // Mono for smaller file size
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000
        ]

        do {
            // Request microphone permission and setup audio session
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)

            print("📱 Audio session category: \(audioSession.category)")
            print("🎙️ Input available: \(audioSession.isInputAvailable)")
            print("🎙️ Input channels: \(audioSession.inputNumberOfChannels)")

            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true  // Enable audio level monitoring
            audioRecorder?.prepareToRecord()

            let success = audioRecorder?.record() ?? false
            isRecording = success

            if success {
                print("✅ Recording started successfully")
                print("🔊 Recording level: \(audioRecorder?.averagePower(forChannel: 0) ?? 0)")
            } else {
                print("❌ Failed to start recording")
            }
        } catch {
            print("❌ Could not start recording: \(error)")
            print("❌ Error details: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        audioRecorder?.stop()
        isRecording = false

        // Check file size to verify recording
        if let url = audioRecorder?.url {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = attributes[.size] as? Int64 ?? 0
                print("⏹️ Recording stopped - File size: \(fileSize) bytes")

                if fileSize < 1000 {
                    print("⚠️ Warning: File is very small, may not contain audio")
                }
            } catch {
                print("❌ Could not check file: \(error)")
            }
        }
    }

    func playRecording(padNumber: Int, completion: (() -> Void)? = nil) -> TimeInterval? {
        let audioFilename = getDocumentsDirectory().appendingPathComponent("pad_\(padNumber).m4a")

        guard FileManager.default.fileExists(atPath: audioFilename.path) else {
            print("❌ No recording found for pad \(padNumber)")
            return nil
        }

        print("▶️ Playing pad \(padNumber): \(audioFilename.path)")

        do {
            // Configure audio session for playback
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            audioPlayer = try AVAudioPlayer(contentsOf: audioFilename)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()

            let duration = audioPlayer?.duration ?? 0
            print("✅ Playback started (duration: \(duration)s)")
            return duration
        } catch {
            print("❌ Could not play recording: \(error)")
            return nil
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
    }

    func hasRecording(padNumber: Int) -> Bool {
        let audioFilename = getDocumentsDirectory().appendingPathComponent("pad_\(padNumber).m4a")
        return FileManager.default.fileExists(atPath: audioFilename.path)
    }

    func deleteRecording(padNumber: Int) {
        let audioFilename = getDocumentsDirectory().appendingPathComponent("pad_\(padNumber).m4a")

        do {
            if FileManager.default.fileExists(atPath: audioFilename.path) {
                try FileManager.default.removeItem(at: audioFilename)
                print("🗑️ Deleted recording for pad \(padNumber)")
            }
        } catch {
            print("❌ Could not delete recording: \(error)")
        }
    }

    func getWaveformData(padNumber: Int, samples: Int = 100) -> [Float] {
        let audioFilename = getDocumentsDirectory().appendingPathComponent("pad_\(padNumber).m4a")

        guard FileManager.default.fileExists(atPath: audioFilename.path) else {
            return []
        }

        do {
            let file = try AVAudioFile(forReading: audioFilename)
            let format = file.processingFormat
            let frameCount = UInt32(file.length)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return []
            }

            try file.read(into: buffer)

            guard let floatData = buffer.floatChannelData else {
                return []
            }

            let channelData = floatData[0]
            let stride = max(1, Int(frameCount) / samples)
            var waveform: [Float] = []

            for i in 0..<samples {
                let index = i * stride
                if index < Int(frameCount) {
                    waveform.append(abs(channelData[index]))
                }
            }

            return waveform
        } catch {
            print("❌ Error reading waveform: \(error)")
            return []
        }
    }
}
