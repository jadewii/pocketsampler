import SwiftUI

struct ContentView: View {
    @StateObject private var audioEngine = InstantAudioEngine()
    @StateObject private var appState = AppState()
    @State private var waveformCache: [Int: (min: [Float], max: [Float])] = [:]
    @State private var waveformCacheHiRes: [Int: (min: [Float], max: [Float])] = [:]  // High-res for editor

    var body: some View {
        ZStack {
            // Background that covers entire screen
            backgroundColor
                .ignoresSafeArea(.all)
                .animation(.easeInOut(duration: 0.2), value: appState.recordingPad)

            VStack(spacing: 0) {
                // Top context bar
                TopBar()
                    .environmentObject(appState)
                    .frame(height: 44)

                // Waveform editor
                WaveformEditor(
                    audioEngine: audioEngine,
                    waveformCache: $waveformCache,
                    waveformCacheHiRes: $waveformCacheHiRes
                )
                .environmentObject(appState)
                .frame(height: 90)

                // Main grid - includes menu buttons as last row
                GridView(
                    audioEngine: audioEngine,
                    waveformCache: $waveformCache,
                    waveformCacheHiRes: $waveformCacheHiRes
                )
                .environmentObject(appState)
            }
        }
    }

    var backgroundColor: Color {
        // Visible dark red when recording (entire screen)
        appState.recordingPad != nil ? Color(red: 0.25, green: 0.0, blue: 0.0) : Color.black
    }
}

struct WaveformEditor: View {
    @ObservedObject var audioEngine: InstantAudioEngine
    @Binding var waveformCache: [Int: (min: [Float], max: [Float])]
    @Binding var waveformCacheHiRes: [Int: (min: [Float], max: [Float])]
    @EnvironmentObject var appState: AppState

    @State private var draggedMarker: DragMarker? = nil

    enum DragMarker {
        case start, end
    }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height

            ZStack {
                // Background - Game Boy green
                Rectangle()
                    .fill(Color(red: 155/255, green: 188/255, blue: 15/255))

                if let editingPad = appState.editingPad,
                   let waveform = waveformCacheHiRes[editingPad + 1],
                   !waveform.min.isEmpty, !waveform.max.isEmpty {

                    // Waveform (using high-res data)
                    WaveformView(
                        minPeaks: waveform.min,
                        maxPeaks: waveform.max,
                        color: Color.black.opacity(0.8)
                    )
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)

                    // Only show markers if NOT recording
                    if appState.recordingPad == nil {
                        // Start marker
                        let startX = 24 + (W - 48) * CGFloat(appState.trimStart)
                        VStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.green)
                                .frame(width: 6, height: H - 8)
                            Text("START")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.green)
                        }
                        .position(x: startX, y: H / 2)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    draggedMarker = .start
                                    let newX = max(24, min(value.location.x, W - 24))
                                    let newStart = Float((newX - 24) / (W - 48))
                                    appState.trimStart = min(newStart, appState.trimEnd - 0.01)
                                }
                                .onEnded { _ in
                                    draggedMarker = nil
                                }
                        )

                        // End marker
                        let endX = 24 + (W - 48) * CGFloat(appState.trimEnd)
                        VStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.red)
                                .frame(width: 6, height: H - 8)
                            Text("END")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.red)
                        }
                        .position(x: endX, y: H / 2)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    draggedMarker = .end
                                    let newX = max(24, min(value.location.x, W - 24))
                                    let newEnd = Float((newX - 24) / (W - 48))
                                    appState.trimEnd = max(newEnd, appState.trimStart + 0.01)
                                }
                                .onEnded { _ in
                                    draggedMarker = nil
                                }
                        )

                        // Dimmed regions
                        let startDimW = (W - 48) * CGFloat(appState.trimStart)
                        let endDimX = 24 + (W - 48) * CGFloat(appState.trimEnd)
                        let endDimW = W - endDimX

                        Rectangle()
                            .fill(Color.black.opacity(0.5))
                            .frame(width: startDimW, height: H)
                            .position(x: 24 + startDimW / 2, y: H / 2)

                        Rectangle()
                            .fill(Color.black.opacity(0.5))
                            .frame(width: endDimW, height: H)
                            .position(x: endDimX + endDimW / 2, y: H / 2)

                        // Playback line
                        if appState.playingPad == appState.editingPad {
                            let playbackX = 24 + (W - 48) * CGFloat(appState.playbackPosition)
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 2, height: H - 16)
                                .position(x: playbackX, y: H / 2)
                        }
                    } else {
                        // Recording - show REC indicator
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                    Text("REC")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(.red)
                                }
                                .padding(6)
                                .background(Color.black.opacity(0.3))
                                .cornerRadius(4)
                                .padding(8)
                            }
                        }
                    }

                } else if appState.recordingPad != nil {
                    // Recording in progress - show live waveform if available
                    if !audioEngine.liveRecordingWaveform.min.isEmpty {
                        WaveformView(
                            minPeaks: audioEngine.liveRecordingWaveform.min,
                            maxPeaks: audioEngine.liveRecordingWaveform.max,
                            color: Color.red
                        )
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                    } else {
                        Text("RECORDING...")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                    }
                } else {
                    // No waveform - show placeholder
                    Text("Tap a pad to edit")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            if appState.mode == .keys {
                Button(action: { appState.octave -= 1 }) {
                    Text("Oct-")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(6)
                }

                Text(keysModeLabel)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))

                Button(action: { appState.octave += 1 }) {
                    Text("Oct+")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(6)
                }
            } else {
                Text("SAMPLER")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
            }

            Spacer()
        }
        .padding(.horizontal)
        .transaction { $0.animation = nil }
    }

    var keysModeLabel: String {
        if let source = appState.keysSourcePad {
            return "Keys - Pad #\(source) - Oct: \(appState.octave)"
        } else {
            return "Keys - Tap a recorded pad"
        }
    }
}

struct GridView: View {
    let audioEngine: InstantAudioEngine
    @Binding var waveformCache: [Int: (min: [Float], max: [Float])]
    @Binding var waveformCacheHiRes: [Int: (min: [Float], max: [Float])]

    @EnvironmentObject var appState: AppState

    // Grid configuration
    let columns = 8
    let padRows = 11  // 11 rows of pads + 1 menu row = 12 total rows
    let gap: CGFloat = 4
    let cornerRadius: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height

            // Total rows = padRows + 1 bottom button row
            let rows = padRows + 1

            // Solve for a single square cell size that fits both axes
            // width fit:
            let cellW = (W - CGFloat(columns - 1) * gap) / CGFloat(columns)
            // height fit:
            let cellH = (H - CGFloat(rows - 1) * gap) / CGFloat(rows)
            let cell = floor(min(cellW, cellH)) // perfect squares

            // Compute the final grid size and center it
            let gridW = CGFloat(columns) * cell + CGFloat(columns - 1) * gap
            let gridH = CGFloat(rows) * cell + CGFloat(rows - 1) * gap
            let offsetX = (W - gridW) / 2
            let offsetY = (H - gridH) / 2

            VStack(spacing: gap) {
                // Pad rows
                ForEach(0..<padRows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<columns, id: \.self) { col in
                            let index = row * columns + col
                            PadSquare(
                                index: index,
                                audioEngine: audioEngine,
                                waveformCache: $waveformCache,
                                waveformCacheHiRes: $waveformCacheHiRes,
                                cornerRadius: cornerRadius
                            )
                            .frame(width: cell, height: cell)
                        }
                    }
                }

                // Menu row (part of the grid)
                HStack(spacing: gap) {
                    ForEach(0..<columns, id: \.self) { col in
                        MenuButton(
                            audioEngine: audioEngine,
                            waveformCache: $waveformCache,
                            waveformCacheHiRes: $waveformCacheHiRes,
                            index: col,
                            cornerRadius: cornerRadius
                        )
                        .frame(width: cell, height: cell)
                    }
                }
            }
            .frame(width: gridW, height: gridH)
            .position(x: offsetX + gridW/2, y: offsetY + gridH/2)
            .transaction { $0.animation = nil }
        }
    }
}

struct LazyWaveformThumbnail: View {
    let hiResSamples: (min: [Float], max: [Float])
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let width = Int(geo.size.width * UIScreen.main.scale)

            if width > 0 && !hiResSamples.min.isEmpty && !hiResSamples.max.isEmpty {
                let peaks = downsampleToPeaks(hiResSamples, targetWidth: width)
                WaveformView(minPeaks: peaks.min, maxPeaks: peaks.max, color: color)
            } else {
                Color.clear
            }
        }
    }

    private func downsampleToPeaks(_ samples: (min: [Float], max: [Float]), targetWidth: Int) -> (min: [Float], max: [Float]) {
        let sourceCount = samples.min.count

        // If source is smaller than target, just use source
        if sourceCount <= targetWidth {
            return samples
        }

        // Downsample: divide source samples into targetWidth buckets
        var minPeaks: [Float] = []
        var maxPeaks: [Float] = []
        minPeaks.reserveCapacity(targetWidth)
        maxPeaks.reserveCapacity(targetWidth)

        for i in 0..<targetWidth {
            let startIdx = i * sourceCount / targetWidth
            let endIdx = (i + 1) * sourceCount / targetWidth

            var minVal: Float = 1.0
            var maxVal: Float = -1.0

            for j in startIdx..<endIdx {
                if j < sourceCount {
                    minVal = min(minVal, samples.min[j])
                    maxVal = max(maxVal, samples.max[j])
                }
            }

            minPeaks.append(minVal)
            maxPeaks.append(maxVal)
        }

        return (min: minPeaks, max: maxPeaks)
    }
}

struct PadSquare: View {
    let index: Int
    let audioEngine: InstantAudioEngine
    @Binding var waveformCache: [Int: (min: [Float], max: [Float])]
    @Binding var waveformCacheHiRes: [Int: (min: [Float], max: [Float])]
    let cornerRadius: CGFloat

    @EnvironmentObject var appState: AppState
    @State private var isPressed = false
    @State private var pressStartTime: Date?
    @State private var recordingTimer: Timer?
    @State private var playbackTimer: Timer?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(backgroundColor)

            contentOverlay
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.red, lineWidth: appState.editingPad == index ? 3 : 0)
        )
        .contentShape(Rectangle())
        .contentTransition(.identity)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                        pressStartTime = Date()
                        handlePressDown()
                    }
                }
                .onEnded { _ in
                    if let startTime = pressStartTime {
                        let duration = Date().timeIntervalSince(startTime)
                        handlePressUp(duration: duration)
                    }
                    isPressed = false
                    pressStartTime = nil
                }
        )
    }

    var backgroundColor: Color {
        switch appState.mode {
        case .pads:
            if appState.recordingPad == index {
                return Color.red
            } else if appState.playingPad == index {
                return Color(red: 1.0, green: 0.8, blue: 0.4)  // Lighter orange
            } else if hasRecording {
                return Color.orange
            } else {
                return Color.white
            }
        case .keys:
            // Keyboard mode - light pink for natural keys, dark pink for black keys
            if appState.playingPad == index {
                return Color(red: 1.0, green: 0.8, blue: 0.4)  // Lighter orange
            } else if isBlackKey {
                return Color(red: 0.8, green: 0.2, blue: 0.6)  // Dark pink
            } else {
                return Color(red: 1.0, green: 0.7, blue: 1.0)  // Light pink (like KEYS button)
            }
        }
    }

    @ViewBuilder
    var contentOverlay: some View {
        switch appState.mode {
        case .pads:
            if hasRecording {
                // Use hi-res data and generate thumbnail on-demand based on actual cell width
                if let hiResWaveform = waveformCacheHiRes[index + 1],
                   !hiResWaveform.min.isEmpty && !hiResWaveform.max.isEmpty {
                    LazyWaveformThumbnail(hiResSamples: hiResWaveform, color: .white)
                        .padding(6)
                } else {
                    Color.clear.onAppear {
                        print("⚠️ Pad \(index + 1): No hi-res waveform available")
                    }
                }
            }
        case .keys:
            // No overlays in keyboard mode
            EmptyView()
        }
    }

    var hasRecording: Bool {
        audioEngine.hasRecording(padNumber: index + 1)
    }

    func handlePressDown() {
        switch appState.mode {
        case .pads:
            if hasRecording {
                // Show waveform in editor when pressing
                appState.editingPad = index
                // DON'T re-record on hold - orange pads only play on tap
            } else {
                // No recording - start recording immediately on white pads
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
                startRecording()
            }

        case .keys:
            // Always play note in keyboard mode
            playNote()

        }
    }

    func handlePressUp(duration: TimeInterval) {
        switch appState.mode {
        case .pads:
            if hasRecording && duration < 0.15 && appState.recordingPad == nil {
                // Quick tap - play it
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                playPad()
            } else if appState.recordingPad == index {
                // Was recording - stop it
                stopRecording()
            }

        case .keys:
            // One-shot playback, nothing to do on release
            break
        }
    }

    func startRecording() {
        appState.recordingPad = index  // Store index, not padNumber
        appState.editingPad = index  // Show in editor while recording

        audioEngine.startRecording(padNumber: index + 1)

        print("🎙️ Started recording pad \(index + 1)")

        // No live waveform timer for now - just show recording state
        // (Live waveform requires AVAudioEngine-based recording, not AVAudioRecorder)
    }

    func stopRecording() {
        print("🛑 Stopping recording pad \(index + 1)")

        audioEngine.stopRecording { [index] in
            DispatchQueue.global(qos: .userInitiated).async {
                // Generate thumbnail waveform (50 samples for pad display)
                let waveform = audioEngine.getWaveformData(padNumber: index + 1, samples: 50)
                print("📸 Thumbnail waveform: \(waveform.min.count) samples")

                // Generate high-res waveform (200 samples for editor)
                let waveformHiRes = audioEngine.getWaveformData(padNumber: index + 1, samples: 200)
                print("📊 HiRes waveform: \(waveformHiRes.min.count) samples")

                DispatchQueue.main.async {
                    waveformCache[index + 1] = waveform
                    waveformCacheHiRes[index + 1] = waveformHiRes
                    appState.recordingPad = nil
                    appState.editingPad = index  // Show in waveform editor
                    appState.trimStart = 0.0  // Reset trim points
                    appState.trimEnd = 1.0

                    print("✅ Stored waveforms in cache for pad \(index + 1)")
                    print("   hasRecording: \(audioEngine.hasRecording(padNumber: index + 1))")
                }
            }
        }
    }

    func playPad() {
        print("▶️ safePlayPad(\(index + 1))")

        // Don't play if currently recording this pad
        if appState.recordingPad == index {
            print("⏳ Pad \(index + 1) is still recording, ignoring tap")
            return
        }

        // Must actually have a recording
        guard hasRecording else {
            print("❌ Pad \(index + 1) says no recording, ignoring tap")
            return
        }

        // Try to play with current trim settings
        guard let duration = audioEngine.playRecording(
            padNumber: index + 1,
            trimStart: appState.trimStart,
            trimEnd: appState.trimEnd
        ) else {
            print("❌ playRecording failed for pad \(index + 1)")
            return
        }

        // Success - update UI
        appState.playingPad = index
        appState.editingPad = index
        appState.playbackPosition = 0.0

        // Animate playback position (within trim range)
        let startTime = Date()
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [self] _ in
            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(Float(elapsed / duration), 1.0)
            // Map progress to trimmed range
            appState.playbackPosition = appState.trimStart + progress * (appState.trimEnd - appState.trimStart)

            if progress >= 1.0 {
                playbackTimer?.invalidate()
                playbackTimer = nil
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if appState.playingPad == index {
                appState.playingPad = nil
                appState.playbackPosition = 0.0
            }
        }
    }

    func playNote() {
        guard let sourcePad = appState.keysSourcePad else { return }

        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()

        appState.playingPad = index  // Store index, not padNumber
        let duration = audioEngine.playRecordingWithPitch(
            padNumber: sourcePad,
            semitoneOffset: semitoneOffset
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + (duration ?? 0.3)) {
            if appState.playingPad == index {
                appState.playingPad = nil
            }
        }
    }

    // Chromatic keyboard mapping
    var semitoneOffset: Int {
        let baseOffset = index - 44  // Middle C at index 44
        let octaveShift = appState.octave * 12
        return baseOffset + octaveShift
    }

    var isBlackKey: Bool {
        let note = (semitoneOffset % 12 + 12) % 12
        return [1, 3, 6, 8, 10].contains(note)  // C#, D#, F#, G#, A#
    }

    var noteName: String {
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let note = (semitoneOffset % 12 + 12) % 12
        let octave = (semitoneOffset + 60) / 12 - 5
        return "\(noteNames[note])\(octave)"
    }
}

struct MenuButton: View {
    let audioEngine: InstantAudioEngine
    @Binding var waveformCache: [Int: (min: [Float], max: [Float])]
    @Binding var waveformCacheHiRes: [Int: (min: [Float], max: [Float])]
    let index: Int
    let cornerRadius: CGFloat

    @EnvironmentObject var appState: AppState

    var body: some View {
        Button(action: {
            handleAction()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(pastelColor)

                if index == 5 {
                    Text("KITS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                } else if index == 6 {
                    Text("KEYS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                } else if index == 7 {
                    Text("CLR")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                } else if index == 3 {
                    Text("SET")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
        }
    }

    func handleAction() {
        switch index {
        case 6: // KEYS button
            if appState.mode == .keys {
                // Exit keyboard mode
                appState.mode = .pads
                appState.keysSourcePad = nil
            } else {
                // Enter keyboard mode - use editing pad or find first recording
                appState.mode = .keys

                // Try to use the currently edited pad (red outline)
                if let editingPad = appState.editingPad,
                   audioEngine.hasRecording(padNumber: editingPad + 1) {
                    appState.keysSourcePad = editingPad + 1
                } else {
                    // Find first available recording
                    for padNumber in 1...(11 * 8) {
                        if audioEngine.hasRecording(padNumber: padNumber) {
                            appState.keysSourcePad = padNumber
                            appState.editingPad = padNumber - 1  // Set red outline
                            break
                        }
                    }
                }
            }
        case 7: // CLEAR button
            if appState.mode == .pads {
                print("🗑️ CLEAR button pressed")

                let impact = UIImpactFeedbackGenerator(style: .heavy)
                impact.impactOccurred()

                // SAFE CLEAR: Clear audio engine state first
                audioEngine.clearAllPads()

                // Reset UI state on main thread
                DispatchQueue.main.async {
                    // Reset app state
                    appState.recordingPad = nil
                    appState.playingPad = nil
                    appState.editingPad = nil
                    appState.playbackPosition = 0.0
                    appState.trimStart = 0.0
                    appState.trimEnd = 1.0

                    // Clear waveform caches by creating new empty dictionaries
                    // This is SAFE because we're on main thread and it's atomic
                    waveformCache = [:]
                    waveformCacheHiRes = [:]

                    print("✅ CLEAR complete")
                }
            }
        default:
            // Other menu buttons (future features)
            break
        }
    }

    var pastelColor: Color {
        let colors: [Color] = [
            Color(red: 1.0, green: 0.7, blue: 0.7),    // Pastel red
            Color(red: 1.0, green: 0.85, blue: 0.6),   // Pastel orange
            Color(red: 1.0, green: 1.0, blue: 0.6),    // Pastel yellow
            Color(red: 0.6, green: 0.6, blue: 0.6),    // Gray (SETTINGS)
            Color(red: 0.6, green: 0.85, blue: 1.0),   // Pastel blue
            Color(red: 0.75, green: 0.7, blue: 1.0),   // Pastel indigo (KITS)
            Color(red: 1.0, green: 0.7, blue: 1.0),    // Pastel violet (KEYS)
            Color(red: 0.9, green: 0.6, blue: 0.6)     // Pastel pink (CLR)
        ]
        return colors[index]
    }
}

#Preview {
    ContentView()
}
