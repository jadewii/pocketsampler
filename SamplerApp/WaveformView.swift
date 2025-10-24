import SwiftUI

struct WaveformView: View {
    let minPeaks: [Float]
    let maxPeaks: [Float]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Canvas { ctx, size in
                guard !minPeaks.isEmpty,
                      !maxPeaks.isEmpty,
                      minPeaks.count == maxPeaks.count else { return }

                let cols = minPeaks.count
                let step = size.width / CGFloat(cols)
                let midY = size.height / 2
                let halfH = size.height / 2.5  // Use 80% of height (2.5 = 1/0.4)

                var path = Path()

                // Draw top peaks (left to right)
                for xIdx in 0..<cols {
                    let x = CGFloat(xIdx) * step
                    let mx = max(-1, min(1, maxPeaks[xIdx]))
                    let y = midY - CGFloat(mx) * halfH

                    if xIdx == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                // Draw bottom peaks (right to left)
                for xIdx in (0..<cols).reversed() {
                    let x = CGFloat(xIdx) * step
                    let mn = max(-1, min(1, minPeaks[xIdx]))
                    let y = midY - CGFloat(mn) * halfH
                    path.addLine(to: CGPoint(x: x, y: y))
                }

                path.closeSubpath()
                ctx.fill(path, with: .color(color))
            }
        }
        .clipped()
    }
}

#Preview {
    WaveformView(
        minPeaks: [-0.1, -0.3, -0.5, -0.7, -0.9, -0.7, -0.5, -0.3, -0.1],
        maxPeaks: [0.1, 0.3, 0.5, 0.7, 0.9, 0.7, 0.5, 0.3, 0.1],
        color: .white
    )
    .frame(height: 40)
    .padding()
    .background(Color.orange)
}
