import SwiftUI

/// The reading surface of the live workspace.
///
/// One turn is in focus at display size; its neighbours recede in size and
/// opacity so the eye lands on what is being said right now. Reading position
/// *is* call time, so a hairline gutter carries every turn's call timecode down
/// the right edge.
///
/// This plate is intentionally the one surface with no glass on it. Everything
/// around it is chrome; this is text.
struct LiveTranscriptStage: View {
    let turns: [LiveTranscriptTurn]
    let guidanceStatus: LiveGuidanceStatus
    var isCompact = false
    /// Space kept clear at the foot of the plate. Large when the timeline floats
    /// over the stage, small when the timeline is a sibling beneath it.
    var bottomInset: CGFloat = 118

    private static let topFade: CGFloat = 92
    private static let bottomAnchorID = "live-transcript-bottom-anchor"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            stage(height: proxy.size.height)
        }
    }

    @ViewBuilder
    private func stage(height: CGFloat) -> some View {
        let rows = visibleTurns

        ZStack {
            RoundedRectangle(cornerRadius: AssistantTheme.liveWorkspaceCornerRadius, style: .continuous)
                .fill(AssistantTheme.liveStage)
                .overlay {
                    RoundedRectangle(cornerRadius: AssistantTheme.liveWorkspaceCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                }

            if rows.isEmpty {
                emptyState
            } else {
                transcript(rows: rows, height: height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AssistantTheme.liveWorkspaceCornerRadius, style: .continuous))
    }

    private func transcript(rows: [LiveTranscriptTurn], height: CGFloat) -> some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Keeps a short transcript resting at the bottom of the
                    // plate instead of floating in the top fade.
                    Spacer(minLength: 0)

                    LazyVStack(alignment: .leading, spacing: isCompact ? 18 : 24) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, turn in
                            LiveTranscriptRow(
                                turn: turn,
                                metrics: metrics(distanceFromFocus: rows.count - 1 - index),
                                gutterWidth: gutterWidth,
                                isCompact: isCompact,
                                guidanceStatus: guidanceStatus
                            )
                            .id(turn.id)
                        }
                    }

                    // Scroll to this anchor, not the focused row. Its height is
                    // the safe area reserved for the floating timeline and fade,
                    // so the latest words always settle above the chrome.
                    Color.clear
                        .frame(height: bottomInset)
                        .id(Self.bottomAnchorID)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, isCompact ? 20 : 34)
                .padding(.top, 30)
                .frame(minHeight: max(height - 24, 0), alignment: .bottom)
            }
            .mask(fadeMask(height: height))
            .overlay(alignment: .trailing) { gutterRule }
            .textSelection(.enabled)
            .onAppear { scrollToFocus(scroller, animated: false) }
            .onValueChange(of: focusKey) { _ in
                scrollToFocus(scroller, animated: !reduceMotion)
            }
        }
    }

    /// Separates what was said from when it was said.
    private var gutterRule: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(width: 1)
            .padding(.trailing, (isCompact ? 20 : 34) + gutterWidth + 14)
            .padding(.vertical, 22)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(AssistantTheme.liveAccent.opacity(0.75))

            Text("Расшифровка появится, как только кто-то заговорит")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))

            Text("Реплики собеседника и ваши идут одной лентой, в порядке звонка.")
                .font(.system(size: 12.5))
                .foregroundStyle(AssistantTheme.liveSecondaryText)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .accessibilityElement(children: .combine)
    }

    private func fadeMask(height: CGFloat) -> some View {
        let resolved = max(height, 1)
        let top = min(Self.topFade / resolved, 0.28)
        let bottom = max(1 - bottomInset / resolved, top + 0.05)

        return LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black, location: top),
                .init(color: .black, location: bottom),
                .init(color: .black.opacity(0.03), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func scrollToFocus(_ scroller: ScrollViewProxy, animated: Bool) {
        guard !visibleTurns.isEmpty else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.28)) {
                scroller.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            scroller.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    private var visibleTurns: [LiveTranscriptTurn] {
        turns
            .filter { $0.state != .superseded }
            .sorted(by: LiveTranscriptTurn.canonicalTimelineOrder)
    }

    /// Re-scroll only for structural changes. Partial deltas can arrive several
    /// times per second; following every character fights text selection and
    /// creates a permanently restarting animation.
    private var focusKey: String {
        let rows = visibleTurns
        guard let last = rows.last else { return "empty" }
        return "\(last.id.uuidString)|\(last.state.rawValue)|\(rows.count)|\(last.text.count / 24)"
    }

    private var gutterWidth: CGFloat {
        isCompact ? 48 : 62
    }

    private func metrics(distanceFromFocus distance: Int) -> LiveTranscriptRow.Metrics {
        guard distance > 0 else {
            return LiveTranscriptRow.Metrics(
                isFocused: true,
                font: .system(size: isCompact ? 22 : 27, weight: .medium),
                tracking: -0.5,
                lineSpacing: isCompact ? 5 : 7,
                textOpacity: 0.97,
                timeOpacity: 0.6,
                tileOpacity: 1
            )
        }

        let textOpacity: Double
        switch distance {
        case 1: textOpacity = 0.70
        case 2: textOpacity = 0.58
        case 3: textOpacity = 0.50
        default: textOpacity = 0.44
        }

        return LiveTranscriptRow.Metrics(
            isFocused: false,
            font: .system(size: isCompact ? 15 : 18, weight: .regular),
            tracking: -0.1,
            lineSpacing: 3,
            textOpacity: textOpacity,
            timeOpacity: max(0.32, textOpacity * 0.72),
            tileOpacity: max(0.52, textOpacity * 1.2)
        )
    }
}

struct LiveTranscriptRow: View {
    struct Metrics {
        let isFocused: Bool
        let font: Font
        let tracking: CGFloat
        let lineSpacing: CGFloat
        let textOpacity: Double
        let timeOpacity: Double
        let tileOpacity: Double
    }

    let turn: LiveTranscriptTurn
    let metrics: Metrics
    let gutterWidth: CGFloat
    let isCompact: Bool
    let guidanceStatus: LiveGuidanceStatus

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            speakerTile

            // The seam marks the turn in focus. Its width is reserved on every
            // row so text left edges stay on one optical line.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(metrics.isFocused ? tone : .clear)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .shadow(color: metrics.isFocused ? tone.opacity(0.45) : .clear, radius: 7)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: metrics.isFocused ? 7 : 0) {
                if metrics.isFocused {
                    focusedHeader
                }
                turnBody(for: turn)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(LiveTimecode.text(callNanoseconds: turn.startCallNanoseconds))
                .font(.system(size: isCompact ? 10.5 : 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(metrics.timeOpacity))
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.top, metrics.isFocused ? 8 : 2)
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var speakerTile: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tone.opacity(0.16))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tone.opacity(0.36), lineWidth: 1)
            }
            .overlay {
                Image(systemName: AssistantTheme.speakerGlyph(for: turn.track))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tone)
            }
            .frame(width: 30, height: 30)
            .opacity(metrics.tileOpacity)
            .padding(.top, metrics.isFocused ? 4 : 0)
            .accessibilityHidden(true)
    }

    private var focusedHeader: some View {
        HStack(spacing: 8) {
            Text(AssistantTheme.speakerTitle(for: turn.track).uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(1.1)
                .foregroundStyle(tone)

            if turn.state == .partial {
                LiveSpeakingIndicator(tone: tone)
            }

            // Echoes the reference's inline AI marker without pretending to be
            // a control: it only reflects whether guidance is actually running.
            if showsListeningBadge {
                Text("ИИ слушает")
                    .font(.system(size: 9.5, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .liveGlassCapsule()
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func turnBody(for turn: LiveTranscriptTurn) -> some View {
        if turn.state == .gap {
            Label("Разрыв live-аудио", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: isCompact ? 14 : 16, weight: .medium))
                .italic()
                .foregroundStyle(AssistantTheme.liveAmber.opacity(max(metrics.textOpacity, 0.45)))
        } else {
            Text(turn.text.isEmpty ? "…" : turn.text)
                .font(metrics.font)
                .tracking(metrics.tracking)
                .lineSpacing(metrics.lineSpacing)
                .foregroundStyle(Color.white.opacity(metrics.textOpacity))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var showsListeningBadge: Bool {
        guidanceStatus == .active && turn.track == .incoming && turn.state == .partial
    }

    private var tone: Color {
        AssistantTheme.tone(for: turn.track)
    }

    private var accessibilityLabel: String {
        let speaker = AssistantTheme.speakerTitle(for: turn.track)
        let time = LiveTimecode.spokenText(TimeInterval(turn.startCallNanoseconds) / 1_000_000_000)

        if turn.state == .gap {
            return "\(time). \(speaker): разрыв live-аудио."
        }

        let text = turn.text.isEmpty ? "реплика распознаётся" : turn.text
        let suffix = turn.state == .partial ? " Реплика ещё не завершена." : ""
        return "\(time). \(speaker): \(text).\(suffix)"
    }
}

/// A quiet pulse that says "this turn is still being spoken".
private struct LiveSpeakingIndicator: View {
    let tone: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone)
                .frame(width: 5, height: 5)
                .opacity(reduceMotion ? 1 : (isPulsing ? 0.35 : 1))

            Text("говорит")
                .font(.system(size: 9.5, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(tone.opacity(0.85))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
