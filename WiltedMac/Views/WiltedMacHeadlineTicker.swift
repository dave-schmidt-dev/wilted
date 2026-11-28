import SwiftUI
import WiltedLibrary

enum WiltedMacHeadlineTickerMotion {
    /// Steady crawl speed in points per second.
    static let steadySpeed: CGFloat = 36

    static let separator = "•"

    static func shouldAutoScroll(
        reduceMotion: Bool,
        isHovering: Bool,
        hasKeyboardFocus: Bool,
        isPresentingStory: Bool,
        storyCount: Int
    ) -> Bool {
        storyCount > 0 && !reduceMotion && !isHovering && !hasKeyboardFocus && !isPresentingStory
    }

    static func wrapOffset(_ offset: CGFloat, loopWidth: CGFloat) -> CGFloat {
        guard loopWidth > 0 else { return 0 }
        let remainder = offset.truncatingRemainder(dividingBy: loopWidth)
        return remainder >= 0 ? remainder : remainder + loopWidth
    }

    static func copiesNeeded(containerWidth: CGFloat, loopWidth: CGFloat) -> Int {
        guard containerWidth > 0, loopWidth > 0 else { return 2 }
        return max(2, Int(ceil((containerWidth + loopWidth) / loopWidth)) + 1)
    }

    static func estimatedSequenceWidth(for stories: [LibraryHeadlineStory]) -> CGFloat {
        let characters = stories.reduce(0) { $0 + $1.publisherName.count + $1.title.count }
        return max(CGFloat(characters) * 8 + CGFloat(stories.count) * 48, 320)
    }

    static func focusedStoryOffset(leadingEdge: CGFloat, leftInset: CGFloat, loopWidth: CGFloat) -> CGFloat {
        min(max(0, leadingEdge - leftInset), max(0, loopWidth - 1))
    }
}

struct WiltedMacHeadlineTickerMotionState {
    private(set) var accumulatedOffset: CGFloat = 0
    private var resumeDate: Date?

    mutating func resume(at date: Date) {
        resumeDate = date
    }

    mutating func pause(at date: Date, loopWidth: CGFloat) {
        if let resumeDate {
            let elapsed = max(0, date.timeIntervalSince(resumeDate))
            accumulatedOffset = WiltedMacHeadlineTickerMotion.wrapOffset(
                accumulatedOffset + CGFloat(elapsed) * WiltedMacHeadlineTickerMotion.steadySpeed,
                loopWidth: loopWidth
            )
        }
        resumeDate = nil
    }

    mutating func revealFocusedStory(at offset: CGFloat, loopWidth: CGFloat) {
        resumeDate = nil
        accumulatedOffset = WiltedMacHeadlineTickerMotion.wrapOffset(offset, loopWidth: loopWidth)
    }

    func offset(at date: Date, loopWidth: CGFloat) -> CGFloat {
        guard let resumeDate else { return accumulatedOffset }
        let elapsed = max(0, date.timeIntervalSince(resumeDate))
        return WiltedMacHeadlineTickerMotion.wrapOffset(
            accumulatedOffset + CGFloat(elapsed) * WiltedMacHeadlineTickerMotion.steadySpeed,
            loopWidth: loopWidth
        )
    }
}

struct WiltedMacHeadlineTickerSequencePin {
    private(set) var snapshot: [LibraryHeadlineStory]?

    func stories(current: [LibraryHeadlineStory]) -> [LibraryHeadlineStory] {
        snapshot ?? Array(current.prefix(20))
    }

    mutating func pin(_ stories: [LibraryHeadlineStory]) {
        guard snapshot == nil else { return }
        snapshot = Array(stories.prefix(20))
    }

    mutating func release() {
        snapshot = nil
    }
}

enum WiltedMacHeadlineTickerSelection {
    static func currentStory(
        matching snapshot: LibraryHeadlineStory,
        in projection: LibraryHeadlineProjection?
    ) -> LibraryHeadlineStory {
        projection?.saved.first(where: { $0.id == snapshot.id })
            ?? projection?.recent.first(where: { $0.id == snapshot.id })
            ?? snapshot
    }
}

private struct WiltedMacHeadlineTickerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

private struct WiltedMacHeadlineTickerPositionsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// One static copy of the crawl's headlines. Timeline updates move this view as a unit.
private struct WiltedMacHeadlineTickerSequence: View {
    let model: WiltedMacModel
    let stories: [LibraryHeadlineStory]
    let isKeyboardSequence: Bool
    let copyIndex: Int
    @Binding var selectedStorySnapshot: LibraryHeadlineStory?
    @FocusState.Binding var focusedStoryID: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            ForEach(stories) { story in
                Button {
                    selectedStorySnapshot = story
                } label: {
                    HStack(spacing: WiltedTheme.Spacing.xSmall) {
                        Text(story.publisherName)
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        Text(story.title)
                            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    }
                    .wiltedFont(.utility)
                    .padding(.horizontal, WiltedTheme.Spacing.small)
                    .padding(.vertical, WiltedTheme.Spacing.xSmall)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .contextMenu {
                    WiltedMacTickerStoryMenu(model: model, snapshot: story)
                }
                .help("Open story actions")
                .accessibilityLabel(WiltedMacHeadlineTicker.storyAccessibilityLabel(story))
                .accessibilityIdentifier("wilted-headline-ticker-story-\(story.id)-copy-\(copyIndex)")
                .modifier(TickerKeyboardAccess(
                    isKeyboardSequence: isKeyboardSequence,
                    storyID: story.id,
                    focusedStoryID: $focusedStoryID
                ))
                .background {
                    GeometryReader { geometry in
                        if isKeyboardSequence {
                            Color.clear.preference(
                                key: WiltedMacHeadlineTickerPositionsKey.self,
                                value: [story.id: geometry.frame(in: .named("ticker-sequence")).minX]
                            )
                        } else {
                            Color.clear
                        }
                    }
                }

                Text(WiltedMacHeadlineTickerMotion.separator)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.steel, scheme: colorScheme))
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
        .padding(.trailing, WiltedTheme.Spacing.medium)
        .coordinateSpace(name: "ticker-sequence")
    }
}

private struct TickerKeyboardAccess: ViewModifier {
    let isKeyboardSequence: Bool
    let storyID: String
    @FocusState.Binding var focusedStoryID: String?

    func body(content: Content) -> some View {
        if isKeyboardSequence {
            content
                .focused($focusedStoryID, equals: storyID)
                .accessibilityHint(WiltedMacHeadlineTicker.storyAccessibilityHint)
        } else {
            content
                .focusable(false)
                .accessibilityHidden(true)
        }
    }
}

/// A continuous, seamless crawl. The timeline changes only the track's translation;
/// its static sequence owns catalog iteration and is not rebuilt per animation frame.
private struct WiltedMacHeadlineTickerCrawl: View {
    let model: WiltedMacModel
    let stories: [LibraryHeadlineStory]
    let isPaused: Bool
    @Binding var selectedStorySnapshot: LibraryHeadlineStory?
    @FocusState.Binding var focusedStoryID: String?

    @State private var measuredSequenceWidth: CGFloat = 0
    @State private var storyLeadingEdges: [String: CGFloat] = [:]
    @State private var motion = WiltedMacHeadlineTickerMotionState()

    private var loopWidth: CGFloat {
        measuredSequenceWidth > 0
            ? measuredSequenceWidth
            : WiltedMacHeadlineTickerMotion.estimatedSequenceWidth(for: stories)
    }

    var body: some View {
        GeometryReader { geometry in
            let copies = WiltedMacHeadlineTickerMotion.copiesNeeded(
                containerWidth: geometry.size.width, loopWidth: loopWidth)
            let track = HStack(spacing: 0) {
                ForEach(0..<copies, id: \.self) { index in
                    WiltedMacHeadlineTickerSequence(
                        model: model,
                        stories: stories,
                        isKeyboardSequence: index == 0,
                        copyIndex: index,
                        selectedStorySnapshot: $selectedStorySnapshot,
                        focusedStoryID: $focusedStoryID
                    )
                }
            }
            .fixedSize()

            TimelineView(.animation(paused: isPaused)) { context in
                track
                    .offset(x: -displayOffset(at: context.date))
                    .frame(height: geometry.size.height, alignment: .center)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .clipped()
        }
        .frame(height: 26)
        .contentShape(Rectangle())
        .clipped()
        .background {
            WiltedMacHeadlineTickerSequence(
                model: model,
                stories: stories,
                isKeyboardSequence: false,
                copyIndex: -1,
                selectedStorySnapshot: $selectedStorySnapshot,
                focusedStoryID: $focusedStoryID
            )
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: WiltedMacHeadlineTickerWidthKey.self, value: geometry.size.width)
                }
            }
            .hidden()
            .accessibilityHidden(true)
        }
        .onPreferenceChange(WiltedMacHeadlineTickerWidthKey.self) { width in
            if width > 0 && abs(measuredSequenceWidth - width) > 0.5 {
                measuredSequenceWidth = width
            }
        }
        .onPreferenceChange(WiltedMacHeadlineTickerPositionsKey.self) { positions in
            storyLeadingEdges = positions
            revealFocusedStoryIfNeeded()
        }
        .onAppear {
            if !isPaused { motion.resume(at: Date()) }
        }
        .onChange(of: isPaused) { _, paused in
            let now = Date()
            if paused {
                motion.pause(at: now, loopWidth: loopWidth)
            } else {
                motion.resume(at: now)
            }
        }
        .onChange(of: focusedStoryID) { _, _ in
            revealFocusedStoryIfNeeded()
        }
    }

    private func revealFocusedStoryIfNeeded() {
        guard let focusedStoryID, let leadingEdge = storyLeadingEdges[focusedStoryID] else { return }
        let leftInset = WiltedTheme.Spacing.small
        motion.revealFocusedStory(
            at: WiltedMacHeadlineTickerMotion.focusedStoryOffset(
                leadingEdge: leadingEdge, leftInset: leftInset, loopWidth: loopWidth),
            loopWidth: loopWidth
        )
    }

    private func displayOffset(at date: Date) -> CGFloat {
        isPaused ? motion.accumulatedOffset : motion.offset(at: date, loopWidth: loopWidth)
    }
}

/// A compact, optional ticker for opening recent headlines without interrupting playback.
struct WiltedMacHeadlineTicker: View {
    @Bindable private var model: WiltedMacModel
    private let stories: [LibraryHeadlineStory]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedStorySnapshot: LibraryHeadlineStory?
    @State private var isHovering = false
    @State private var sequencePin = WiltedMacHeadlineTickerSequencePin()
    @FocusState private var focusedStoryID: String?
    private let motionPausedForTesting: Bool

    static func storyAccessibilityLabel(_ story: LibraryHeadlineStory) -> String {
        "\(story.publisherName): \(story.title)"
    }

    static let storyAccessibilityHint =
        "Show story actions. Read the article, queue audio after the current episode, or save it to Notebook."

    init(model: WiltedMacModel, stories: [LibraryHeadlineStory]) {
        self.init(model: model, stories: stories, motionPausedForTesting: false)
    }

    init(model: WiltedMacModel, stories: [LibraryHeadlineStory], motionPausedForTesting: Bool) {
        _model = Bindable(model)
        self.stories = Array(stories.prefix(20))
        self.motionPausedForTesting = motionPausedForTesting
    }

    private var autoScrollEnabled: Bool {
        !motionPausedForTesting && WiltedMacHeadlineTickerMotion.shouldAutoScroll(
            reduceMotion: reduceMotion,
            isHovering: isHovering,
            hasKeyboardFocus: focusedStoryID != nil,
            isPresentingStory: selectedStorySnapshot != nil,
            storyCount: visibleStories.count)
    }

    private var visibleStories: [LibraryHeadlineStory] {
        sequencePin.stories(current: stories)
    }

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            Label("Headlines", systemImage: "newspaper")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize()

            if stories.isEmpty {
                Text("No recent stories yet")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            } else {
                WiltedMacHeadlineTickerCrawl(
                    model: model,
                    stories: visibleStories,
                    isPaused: !autoScrollEnabled,
                    selectedStorySnapshot: $selectedStorySnapshot,
                    focusedStoryID: $focusedStoryID
                )
                .accessibilityIdentifier("wilted-headline-ticker-stories")
            }
        }
        .padding(.horizontal, WiltedTheme.Spacing.medium)
        .padding(.vertical, WiltedTheme.Spacing.xSmall)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .overlay(alignment: .top) {
            WiltedTheme.color(.steel, scheme: colorScheme).frame(height: 1)
        }
        .onHover { hovering in
            if hovering {
                sequencePin.pin(visibleStories)
            } else if selectedStorySnapshot == nil && focusedStoryID == nil {
                sequencePin.release()
            }
            isHovering = hovering
        }
        .popover(item: $selectedStorySnapshot, arrowEdge: .bottom) { snapshot in
            storyActions(for: snapshot)
        }
        .onChange(of: selectedStorySnapshot) { _, snapshot in
            if snapshot != nil {
                sequencePin.pin(visibleStories)
            } else if !isHovering && focusedStoryID == nil {
                sequencePin.release()
            }
        }
        .onChange(of: focusedStoryID) { _, storyID in
            if storyID != nil {
                sequencePin.pin(visibleStories)
            } else if !isHovering && selectedStorySnapshot == nil {
                sequencePin.release()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-headline-ticker")
    }

    @ViewBuilder
    func storyActions(for snapshot: LibraryHeadlineStory) -> some View {
        let story = WiltedMacHeadlineTickerSelection.currentStory(
            matching: snapshot, in: model.headlineCatalogState.projection)
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            WiltedMacTickerAddToLarder(model: model, story: story)
            WiltedMacPlayerHeadlineCard(
                model: model,
                story: story,
                isSpeakingHeadline: model.speakingBulletin?.kind == .headline
                    && model.speakingBulletin?.headlineStoryID == story.id,
                stopReading: model.skipSpokenBulletin)
        }
        .id(story.id)
        .frame(width: 440)
        .padding(WiltedTheme.Spacing.small)
    }
}
