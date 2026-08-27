import SwiftUI

/// The live-call workspace.
///
/// Three zones, and each one has a job:
///
/// - **Chrome** (top, glass) — who is on which audio track and whether capture
///   is actually running. State, not time.
/// - **Stage** (centre, calm ink) — the transcript. The newest turn is set at
///   display size and everything around it recedes, so the eye always lands on
///   what is being said now. This is the only surface with no glass on it.
/// - **Rail** (right, glass) — the assistant's reading of the conversation,
///   beside the transcript rather than over it.
///
/// The timeline floats at the foot of the stage and carries call time plus marks
/// for earlier assistant answers whose timestamps are known. Nothing on it is
/// draggable: a live call cannot be scrubbed, so it reads as an instrument.
struct LiveAssistantView: View {
    let incomingSource: String
    let outgoingSource: String
    let selectedContextCount: Int
    let elapsedTime: TimeInterval
    let currentMoment: AssistantMoment?
    let answerHistory: [AnswerHistoryItem]
    let transcriptTurns: [LiveTranscriptTurn]
    let incomingStatus: RealtimeTrackStatus
    let outgoingStatus: RealtimeTrackStatus
    let incomingFailure: RealtimeFailureDiagnostic?
    let outgoingFailure: RealtimeFailureDiagnostic?
    let guidanceStatus: LiveGuidanceStatus
    let onEndCall: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let railWidth: CGFloat = 344

    var body: some View {
        GeometryReader { proxy in
            workspace(size: proxy.size)
        }
        .background(backdrop)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Color.white.opacity(0.94))
        .frame(minWidth: 720, idealWidth: 1080, minHeight: 640, idealHeight: 720)
    }

    private func workspace(size: CGSize) -> some View {
        let isCompact = size.width < AssistantTheme.liveCompactWidthThreshold
        // Cap the assistant as a fraction of the window rather than a fixed
        // height, so a short window never leaves the transcript with nothing.
        let railHeight = min(210, max(126, size.height * 0.26))

        return VStack(spacing: 14) {
            LiveWorkspaceChrome(
                incomingSource: incomingSource,
                outgoingSource: outgoingSource,
                incomingStatus: incomingStatus,
                outgoingStatus: outgoingStatus,
                selectedContextCount: selectedContextCount,
                isCompact: isCompact
            )

            LiveFailureBanner(
                incomingFailure: incomingFailure,
                outgoingFailure: outgoingFailure,
                incomingStatus: incomingStatus,
                outgoingStatus: outgoingStatus
            )

            if isCompact {
                // Below the breakpoint the timeline drops out of the stage and
                // becomes a sibling: there is no longer enough plate for text to
                // pass behind it and stay readable.
                stage(isCompact: true, floatingTimeline: false)

                guidanceRail
                    .frame(height: railHeight)

                timeline(isCompact: true)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    stage(isCompact: false, floatingTimeline: true)

                    guidanceRail
                        .frame(width: Self.railWidth)
                }
            }
        }
        .padding(16)
    }

    private func stage(isCompact: Bool, floatingTimeline: Bool) -> some View {
        LiveTranscriptStage(
            turns: transcriptTurns,
            guidanceStatus: guidanceStatus,
            isCompact: isCompact,
            bottomInset: floatingTimeline ? 118 : 28
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if floatingTimeline {
                timeline(isCompact: isCompact)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
    }

    private func timeline(isCompact: Bool) -> some View {
        LiveCallTimeline(
            elapsedTime: elapsedTime,
            answerMarks: answerHistory.map(\.elapsedTime),
            isCompact: isCompact,
            onEndCall: onEndCall
        )
    }

    private var guidanceRail: some View {
        // The scroll view has to be outermost: it is what clips the rail to the
        // height the layout gives it. The glass group goes inside, where it
        // merges the card and the feed into one continuous surface.
        ScrollView(.vertical, showsIndicators: false) {
            LiveGlassGroup(spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    CurrentGuidanceCard(moment: currentMoment, status: guidanceStatus)

                    historySection
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Помощник")
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Лента")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.92))

                Text("новые сверху")
                    .font(.system(size: 10.5))
                    .foregroundStyle(AssistantTheme.liveSecondaryText)

                Spacer(minLength: 0)

                Text("\(answerHistory.count)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .accessibilityLabel("Ответов в ленте: \(answerHistory.count)")
            }

            if sortedHistory.isEmpty {
                Text("Предыдущие ответы появятся здесь по ходу разговора.")
                    .font(.system(size: 12))
                    .foregroundStyle(AssistantTheme.liveSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(sortedHistory) { item in
                        AnswerHistoryCard(item: item)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liveGlassPanel(cornerRadius: 16)
    }

    private var backdrop: some View {
        ZStack {
            reduceTransparency ? AssistantTheme.liveBackdropOpaque : AssistantTheme.liveBackdrop

            if !reduceTransparency {
                // A single cool wash so the glass chrome has something to pick
                // up. Anything more and the panel starts competing with the
                // transcript for attention.
                LinearGradient(
                    colors: [AssistantTheme.liveAccent.opacity(0.11), .clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
            }
        }
        .ignoresSafeArea()
    }

    private var sortedHistory: [AnswerHistoryItem] {
        answerHistory.sorted { $0.elapsedTime > $1.elapsedTime }
    }
}
