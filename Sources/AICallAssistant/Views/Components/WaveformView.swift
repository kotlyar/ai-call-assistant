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
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    let barWidth: CGFloat = 2
                    let gap: CGFloat = 2.5
                    let step = barWidth + gap
                    let barCount = max(1, Int((size.width + gap) / step))
                    let playedWidth = size.width * clampedProgress

                    for index in 0..<barCount {
                        let x = CGFloat(index) * step
                        let level = levels[index % levels.count]
                        let height = max(3, size.height * level)
                        let rect = CGRect(
                            x: x,
                            y: (size.height - height) / 2,
                            width: barWidth,
                            height: height
                        )
                        let color = x + barWidth / 2 <= playedWidth
                            ? AssistantTheme.accent
                            : AssistantTheme.secondaryText.opacity(0.28)

                        context.fill(
                            Path(roundedRect: rect, cornerRadius: barWidth / 2),
                            with: .color(color)
                        )
                    }
                }

                if clampedProgress > 0 {
                    Capsule(style: .continuous)
                        .fill(AssistantTheme.accent)
                        .frame(width: 1.5, height: proxy.size.height + 4)
                        .offset(x: playheadOffset(in: proxy.size.width))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Волновая форма аудиозаписи")
        .accessibilityValue("Воспроизведено \(Int(clampedProgress * 100)) процентов")
    }

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private func playheadOffset(in width: CGFloat) -> CGFloat {
        min(max(0, width * clampedProgress - 0.75), max(0, width - 1.5))
    }
}
