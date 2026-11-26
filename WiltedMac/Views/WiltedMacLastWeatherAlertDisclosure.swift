import SwiftUI
import WiltedLibrary

/// A short path from Reports back to the most recent Mac weather notice.
struct WiltedMacLastWeatherAlertDisclosure: View {
    let bulletin: Bulletin?
    @State private var presentedBulletin: Bulletin?

    var body: some View {
        if let bulletin {
            Button("Last weather alert") {
                presentedBulletin = bulletin
            }
            .accessibilityIdentifier("wilted-reports-last-weather-alert")
            .sheet(item: $presentedBulletin) { alert in
                WiltedMacLastWeatherAlertDetails(bulletin: alert)
            }
        }
    }
}

/// Offline copy of the complete CAP details and NWS wording for the last spoken alert.
struct WiltedMacLastWeatherAlertDetails: View {
    @Environment(\.dismiss) private var dismiss
    let bulletin: Bulletin

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack {
                Text("Last weather alert")
                    .wiltedFont(.display)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if let officialURL = bulletin.link {
                Link("Open full NWS alert", destination: officialURL)
                    .wiltedFont(.utility)
            }

            ScrollView {
                Text(bulletin.originalText ?? bulletin.text)
                    .wiltedFont(.utility)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("wilted-reports-last-weather-alert-original")
            }
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(minWidth: 460, idealWidth: 620, minHeight: 360, idealHeight: 560)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-reports-last-weather-alert-details")
    }
}
