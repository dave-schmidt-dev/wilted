import SwiftUI
import WiltedDomain
import WiltedLibrary

/// A producer report belongs to its raw copy, even when another copy supplies the audio.
struct LibraryPreparationAnnotation: Equatable, Sendable, Identifiable {
    let memberID: ItemID
    let status: LibraryPreparationStatus
    var isOtherCopy = false
    var id: ItemID { memberID }

    private static let knownStages: Set<String> = [
        "preparing", "fetching", "extracting", "synthesizing", "assembling", "saving",
        "pipeline.start", "pipeline.result", "pipeline.complete", "audio.publish",
        "transcript.published.fetch", "transcript.published.parse", "transcript.published.accepted",
        "transcript.published.aligned", "transcript.published.unverified", "transcript.published.unreadable",
        "transcript.published.unreachable", "transcript.published.unparseable", "transcript.published.misaligned",
        "transcript.stt.start", "transcript.stt.complete", "transcript.stt.failed", "transcript.absent", "transcript.remap",
        "transcript.glossary.terms", "transcript.glossary.progress", "transcript.glossary.complete",
        "ads.model.load", "ads.detect.start", "ads.detect.calls", "ads.detect.complete",
        "ads.cut.start", "ads.cut.complete", "ads.cut.refused", "ads.cut.empty"
    ]

    var text: String {
        let prefix = isOtherCopy ? "Other copy: " : ""
        let message: String
        switch status.state {
        case .queued: message = "Queued on Mac"
        case .failed: message = "Preparation failed on Mac. Retry from the Mac."
        case .cancelled: message = "Preparation cancelled on Mac"
        case .active:
            let detail = status.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            message = Self.knownStages.contains(status.stage) && !detail.isEmpty
                ? "Preparing on Mac: \(detail)" : "Preparing on Mac"
        }
        let percent = progress.map { " · \(Int(($0 * 100).rounded()))% of this stage" } ?? ""
        return prefix + message + percent
    }

    /// A stage fraction is never interpreted as progress for the whole preparation or group.
    var progress: Double? { status.state == .active ? status.fraction : nil }
    var lastReportedText: String { "Last reported \(LibraryDateFormat.dayAndTime(status.updatedAt))" }
    var accessibilityText: String { "\(text). \(lastReportedText)." }
    var tone: WiltedStatusTone {
        switch status.state {
        case .queued, .active: .active
        case .failed: .failure
        case .cancelled: .neutral
        }
    }
}

/// Stateless producer status in the existing Larder utility line; it grants no action.
struct LibraryPreparationStatusLine: View {
    let annotation: LibraryPreparationAnnotation
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var textSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Text(annotation.text)
                .font(.system(size: textSize, weight: .medium, design: .monospaced))
                .foregroundStyle(annotation.tone.color(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(annotation.lastReportedText)
                .font(.system(size: textSize, weight: .medium, design: .monospaced))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if let fraction = annotation.progress {
                ProgressView(value: fraction)
                    .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(annotation.accessibilityText)
        .accessibilityIdentifier("wilted-library-preparation-\(annotation.memberID.rawValue)")
    }
}
