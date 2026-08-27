import SwiftUI

/// Top chrome of the live workspace: identity, capture state, and the two audio
/// tracks. Chrome carries *state*; the timeline below carries *time*.
struct LiveWorkspaceChrome: View {
    let incomingSource: String
    let outgoingSource: String
    let incomingStatus: RealtimeTrackStatus
    let outgoingStatus: RealtimeTrackStatus
    let selectedContextCount: Int
    let isCompact: Bool

    var body: some View {
        LiveGlassGroup(spacing: 14) {
            HStack(spacing: 12) {
                identity

                Spacer(minLength: 12)

                LiveTrackCapsule(
                    track: .incoming,
                    source: incomingSource,
                    status: incomingStatus,
                    showsSource: !isCompact
                )

                LiveTrackCapsule(
                    track: .outgoing,
                    source: outgoingSource,
                    status: outgoingStatus,
                    showsSource: !isCompact
                )

                if !isCompact {
                    contextCapsule
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .liveGlassPanel(cornerRadius: 18)
    }

    private var identity: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(AssistantTheme.liveAccent.opacity(0.18))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(AssistantTheme.liveAccent.opacity(0.35), lineWidth: 1)
                }
                .overlay {
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AssistantTheme.liveAccent)
                }
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            if !isCompact {
                Text("Живой разговор")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.94))
            }

            LiveRecordingBadge()
        }
    }

    private var contextCapsule: some View {
        Label(contextDescription, systemImage: "square.stack.3d.up")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.74))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .liveInsetCapsule()
            .accessibilityLabel(contextDescription)
    }

    private var contextDescription: String {
        switch selectedContextCount {
        case 0: "Контексты не выбраны"
        case 1: "1 контекст"
        case 2...4: "\(selectedContextCount) контекста"
        default: "\(selectedContextCount) контекстов"
        }
    }
}

/// Non-interactive capture indicator. It reports that the call is recording; it
/// does not offer to stop it — that lives on the timeline.
struct LiveRecordingBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .shadow(color: Color.red.opacity(0.5), radius: 4)
                .opacity(reduceMotion ? 1 : (isPulsing ? 0.35 : 1))

            Text("ЗАПИСЬ")
                .font(.system(size: 9.5, weight: .medium))
                .tracking(1)
                .foregroundStyle(Color.white.opacity(0.82))
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .liveInsetCapsule()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Идёт запись звонка")
    }
}

/// One audio track as a glass status capsule: who, from where, and whether live
/// transcription is actually running on it.
struct LiveTrackCapsule: View {
    let track: AudioTrack
    let source: String
    let status: RealtimeTrackStatus
    let showsSource: Bool

    var body: some View {
        let presentation = RealtimeTrackStatusPresentation(status)
        let tone = AssistantTheme.tone(for: track)

        return HStack(spacing: 7) {
            Image(systemName: AssistantTheme.speakerGlyph(for: track))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tone)

            Text(AssistantTheme.speakerTitle(for: track))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))

            if showsSource {
                Text(source)
                    .font(.system(size: 11))
                    .foregroundStyle(AssistantTheme.liveSecondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150)
            }

            Circle()
                .fill(LiveStatusTone.color(presentation.indicatorTone))
                .frame(width: 6, height: 6)
                .shadow(color: LiveStatusTone.color(presentation.indicatorTone).opacity(0.4), radius: 3)
                .help(presentation.indicatorHelp)

            Text(presentation.statusText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.62))
                .lineLimit(1)

            if let warning = presentation.warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(AssistantTheme.liveAmber)
                    .help(warning)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .liveInsetCapsule(tint: presentation.indicatorTone == .error ? .red : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(presentation))
    }

    private func label(_ presentation: RealtimeTrackStatusPresentation) -> String {
        var result = "\(AssistantTheme.speakerTitle(for: track)): \(source), \(presentation.statusText)"
        if let warning = presentation.warning {
            result += ", \(warning)"
        }
        return result
    }
}

enum LiveStatusTone {
    static func color(_ tone: RealtimeTrackStatusPresentation.IndicatorTone) -> Color {
        switch tone {
        case .active: AssistantTheme.liveGreen
        case .pending: .orange
        case .warning: AssistantTheme.liveAmber
        case .error: .red
        }
    }
}

/// Surfaces a permanently failed Realtime track without hiding the transcript.
/// Recording keeps running, and the copy says so.
struct LiveFailureBanner: View {
    let incomingFailure: RealtimeFailureDiagnostic?
    let outgoingFailure: RealtimeFailureDiagnostic?
    let incomingStatus: RealtimeTrackStatus
    let outgoingStatus: RealtimeTrackStatus

    var body: some View {
        if messages.isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(red: 1, green: 0.56, blue: 0.53))
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(messages, id: \.self) { message in
                        Text(message)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Запись звонка продолжается.")
                        .font(.system(size: 11))
                        .foregroundStyle(AssistantTheme.liveSecondaryText)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .liveGlassPanel(cornerRadius: 14, tint: .red)
            .accessibilityElement(children: .combine)
        }
    }

    private var messages: [String] {
        var result: [String] = []
        if incomingStatus == .failed, let incomingFailure {
            result.append("Собеседник: \(RealtimeFailurePresentation(incomingFailure).message)")
        }
        if outgoingStatus == .failed, let outgoingFailure {
            result.append("Вы: \(RealtimeFailurePresentation(outgoingFailure).message)")
        }
        return result
    }
}

/// The persistent bottom surface: elapsed call time, a scale of ticks, marks for
/// earlier assistant answers with known timestamps, and the one real control.
///
/// Nothing on the track is interactive — a live call cannot be scrubbed — so it
/// reads as an instrument, not a player.
struct LiveCallTimeline: View {
    let elapsedTime: TimeInterval
    let answerMarks: [TimeInterval]
    let isCompact: Bool
    let onEndCall: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            GeometryReader { proxy in
                track(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(trackAccessibilityLabel)

            clock

            endCallButton
        }
        .padding(.horizontal, 16)
        .frame(height: 68)
        .liveGlassPanel(cornerRadius: 18)
    }

    private func track(width: CGFloat, height: CGFloat) -> some View {
        let usable = max(width, 1)
        let baselineY = height * 0.38

        return ZStack(alignment: .topLeading) {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.09))
                .frame(width: usable, height: 2)
                .position(x: usable / 2, y: baselineY)

            ForEach(tickTimes, id: \.self) { time in
                let isMajor = isMajorTick(time)
                Rectangle()
                    .fill(Color.white.opacity(isMajor ? 0.24 : 0.13))
                    .frame(width: 1, height: isMajor ? 11 : 6)
                    .position(x: x(for: time, in: usable), y: baselineY + (isMajor ? 8.5 : 6))
            }

            if !isCompact {
                ForEach(labelledTickTimes, id: \.self) { time in
                    Text(LiveTimecode.text(time))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.28))
                        .fixedSize()
                        .position(
                            x: min(max(x(for: time, in: usable), 18), usable - 18),
                            y: baselineY + 23
                        )
                }
            }

            ForEach(Array(answerMarks.enumerated()), id: \.offset) { _, time in
                Capsule(style: .continuous)
                    .fill(AssistantTheme.liveAccent)
                    .frame(width: 3, height: 12)
                    .shadow(color: AssistantTheme.liveAccent.opacity(0.5), radius: 4)
                    .position(x: x(for: time, in: usable), y: baselineY - 7)
            }

            playhead(x: x(for: elapsedTime, in: usable), baselineY: baselineY)
        }
        .frame(width: usable, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func playhead(x: CGFloat, baselineY: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(AssistantTheme.liveGreen)
                .frame(width: 1.5, height: 26)
                .position(x: x, y: baselineY + 2)

            Circle()
                .fill(AssistantTheme.liveGreen)
                .frame(width: 7, height: 7)
                .shadow(color: AssistantTheme.liveGreen.opacity(0.6), radius: 5)
                .position(x: x, y: baselineY - 11)
        }
    }

    private var clock: some View {
        HStack(spacing: 7) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AssistantTheme.liveGreen)

            Text(LiveTimecode.text(elapsedTime))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.95))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .liveInsetCapsule()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Идёт \(LiveTimecode.spokenText(elapsedTime))")
    }

    private var endCallButton: some View {
        Button(action: onEndCall) {
            HStack(spacing: 7) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 11, weight: .medium))

                if !isCompact {
                    Text("Завершить")
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .foregroundStyle(quietRed)
            .padding(.horizontal, isCompact ? 0 : 17)
            .frame(minWidth: isCompact ? 44 : 126, minHeight: 44, maxHeight: 44)
            .background(
                quietRed.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(quietRed.opacity(0.24), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(LiveGlassButtonStyle())
        .keyboardShortcut(".", modifiers: [.command])
        .accessibilityLabel("Завершить звонок")
        .accessibilityHint("Останавливает анализ и сохраняет запись звонка")
    }

    private var quietRed: Color {
        Color(red: 1, green: 0.53, blue: 0.5)
    }

    private var span: TimeInterval {
        max(elapsedTime, 60)
    }

    private func x(for time: TimeInterval, in width: CGFloat) -> CGFloat {
        let fraction = min(max(time / span, 0), 1)
        return width * CGFloat(fraction)
    }

    /// Keeps roughly 8–12 ticks on screen whatever the call length.
    private var tickInterval: TimeInterval {
        let candidates: [TimeInterval] = [15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let target = span / 10
        return candidates.first { $0 >= target } ?? 3600
    }

    private var tickTimes: [TimeInterval] {
        Array(stride(from: 0, through: span, by: tickInterval))
    }

    private func isMajorTick(_ time: TimeInterval) -> Bool {
        Int((time / tickInterval).rounded()) % 2 == 0
    }

    private var labelledTickTimes: [TimeInterval] {
        // Drop the last label so it never collides with the playhead.
        tickTimes.filter { isMajorTick($0) && $0 < span - tickInterval * 0.5 }
    }

    private var trackAccessibilityLabel: String {
        let base = "Хронология звонка. Прошло \(LiveTimecode.spokenText(elapsedTime))."
        guard !answerMarks.isEmpty else {
            return base + " Ответов ассистента пока нет."
        }
        return base + " Отметок с ответами ассистента: \(answerMarks.count)."
    }
}
