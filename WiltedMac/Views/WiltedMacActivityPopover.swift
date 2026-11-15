import SwiftUI

/// What the Activity popover shows: one line for each thing the Mac does in the background.
///
/// The sidebar's sync line opens it. It shows state only and has no controls: every row is a
/// `WiltedSettingsRow` built from `WiltedMacModel.activitySummary`, so its wording stays the
/// summary's. While it is on screen it asks the model to re-read the upload state every two
/// seconds, because nothing pushes that state to the model between sync rounds.
struct WiltedMacActivityContent: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    /// The popover's fixed width, in points.
    static let width: CGFloat = 380
    /// How often the upload state is re-read while the popover is open.
    static let refreshInterval: Duration = .seconds(2)
    /// The summary row that carries the iCloud request rate.
    static let rateRowID = "rate"

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
            Text("Activity")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .accessibilityAddTraits(.isHeader)
            ForEach(model.activitySummary.groups) { group in
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                    Text(group.title)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.rows) { row in
                        if row.id == Self.rateRowID {
                            // The request counters are not observed, so this row re-reads them on a
                            // 30 s timeline, as the Sync card's request line does.
                            TimelineView(.periodic(from: .now, by: 30)) { _ in
                                line(currentRow(row.id) ?? row)
                            }
                        } else {
                            line(row)
                        }
                    }
                }
            }
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(width: Self.width, alignment: .leading)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-activity")
        // Tied to the popover's lifetime: SwiftUI cancels it when the content disappears.
        .task {
            while !Task.isCancelled {
                await model.refreshMediaActivity()
                do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
            }
        }
    }

    private func line(_ row: WiltedMacActivitySummary.Row) -> some View {
        WiltedSettingsRow(row.label, value: row.value, identifier: "wilted-activity-\(row.id)", tone: row.tone)
    }

    /// The row as the model reads it now, for a row whose inputs are not observed.
    private func currentRow(_ id: String) -> WiltedMacActivitySummary.Row? {
        model.activitySummary.groups.lazy.flatMap(\.rows).first { $0.id == id }
    }
}
