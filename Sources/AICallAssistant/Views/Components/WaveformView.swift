import SwiftUI

struct WaveformView: View {
    var progress: Double = 0

    private let levels: [CGFloat] = [
        0.28, 0.52, 0.36, 0.74, 0.46, 0.92, 0.58, 0.34, 0.70,
        0.44, 0.84, 0.62, 0.40, 0.76, 0.50, 0.88, 0.56, 0.32,
        0.68, 0.48, 0.80, 0.60, 0.38, 0.72, 0.54, 0.90, 0.42
    ]

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    Capsule(style: .continuous)
                        .fill(barColor(at: index))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, proxy.size.height * level))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Волновая форма аудиозаписи")
        .accessibilityValue("Воспроизведено \(Int(clampedProgress * 100)) процентов")
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private func barColor(at index: Int) -> Color {
        let threshold = Double(index + 1) / Double(levels.count)
        return threshold <= clampedProgress ? AssistantTheme.accent : AssistantTheme.secondaryText.opacity(0.34)
    }
}
