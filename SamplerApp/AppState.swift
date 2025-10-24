import SwiftUI

enum GridMode: Equatable {
    case pads
    case keys
}

final class AppState: ObservableObject {
    @Published var mode: GridMode = .pads
    @Published var keysSourcePad: Int? = nil
    @Published var octave: Int = 0  // Octave offset for chromatic keyboard
    @Published var recordingPad: Int? = nil
    @Published var playingPad: Int? = nil
    @Published var editingPad: Int? = nil  // Pad being shown in waveform editor
    @Published var trimStart: Float = 0.0  // 0.0 to 1.0
    @Published var trimEnd: Float = 1.0    // 0.0 to 1.0
    @Published var playbackPosition: Float = 0.0  // 0.0 to 1.0 - playhead position
}
