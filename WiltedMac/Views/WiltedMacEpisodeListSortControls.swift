import SwiftUI

/// The same sort menu and direction button on every Mac episode listing.
struct WiltedMacEpisodeListSortControls: View {
    let label: String
    let identifierPrefix: String
    @Binding var sort: WiltedMacLarderSort
    @Binding var direction: WiltedMacLarderSortDirection

    static func toggled(
        sort: WiltedMacLarderSort,
        direction: WiltedMacLarderSortDirection
    ) -> (sort: WiltedMacLarderSort, direction: WiltedMacLarderSortDirection) {
        (sort.canonical, (sort.legacyDirection ?? direction).reversed)
    }

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            Menu {
                ForEach(WiltedMacLarderSort.presentationOptions, id: \.id) { option in
                    Button {
                        sort = option
                    } label: {
                        if sort.canonical == option {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            } label: {
                Label("Sort by: \(sort.displayName)", systemImage: "arrow.up.arrow.down")
                    .wiltedFont(.utility)
            }
            .menuStyle(.button)
            .controlSize(.regular)
            .accessibilityLabel("Sort \(label): \(sort.displayName)")
            .accessibilityIdentifier("\(identifierPrefix)-sort")

            if sort.canonical != .custom {
                Button {
                    let next = Self.toggled(sort: sort, direction: direction)
                    sort = next.sort
                    direction = next.direction
                } label: {
                    Image(systemName: direction == .ascending ? "arrow.up" : "arrow.down")
                        .wiltedFont(.utility)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Sort direction: \(direction.displayName)")
                .accessibilityLabel("\(label) sort direction: \(direction.displayName)")
                .accessibilityIdentifier("\(identifierPrefix)-sort-direction")
            }
        }
    }
}
