import AppKit
import SwiftUI
import WiltedDomain

// MARK: - Reports

/// Settings > Reports: spoken weather alerts and headlines at pause points, the daily report, and
/// the location that weather needs. Interruptions are off until the listener turns them on.
struct WiltedMacReportsCard: View {
    let model: WiltedMacModel
    let location: WiltedLocationProvider
    @Environment(\.colorScheme) private var colorScheme
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var contactText = ""
    @State private var coordinateProblem = false
    @State private var showsDetails: Bool

    /// The details start folded: interruptions are off by default, and the rest only matters once on.
    init(model: WiltedMacModel, location: WiltedLocationProvider, startsExpanded: Bool = false) {
        self.model = model
        self.location = location
        _showsDetails = State(initialValue: startsExpanded)
    }

    private var settings: WiltedAutomationSettings { model.automationSettings }

    var body: some View {
        WiltedSettingsCard(title: "Reports") {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Toggle("Read bulletins while playing", isOn: reportsBinding(\.interruptionsEnabled))
                    .accessibilityIdentifier("wilted-reports-interruptions")
                #if canImport(WiltedProducer)
                if let status = model.bulletinHub.routeProtectionStatus {
                    Text(status)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-reports-route-status")
                }
                #endif
                DisclosureGroup(isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                        Toggle("Weather alerts", isOn: reportsBinding(\.alertsEnabled))
                            .disabled(!settings.interruptionsEnabled)
                            .accessibilityIdentifier("wilted-reports-alerts")
                        Toggle("Headlines", isOn: reportsBinding(\.headlinesEnabled))
                            .disabled(!settings.interruptionsEnabled)
                            .accessibilityIdentifier("wilted-reports-headlines")
                        Stepper(value: reportsBinding(\.waitLimitSeconds), in: WiltedAutomationSettings.waitLimitRange, step: 10) {
                            labeledValue("Wait for a break", "\(settings.waitLimitSeconds) seconds")
                        }
                        .disabled(!settings.interruptionsEnabled)
                        .accessibilityIdentifier("wilted-reports-wait-limit")
                        Stepper(value: reportsBinding(\.headlineMinimumGapMinutes),
                                in: WiltedAutomationSettings.headlineGapRange, step: 5) {
                            labeledValue("Between headlines", "\(settings.headlineMinimumGapMinutes) minutes")
                        }
                        .disabled(!settings.interruptionsEnabled)
                        .accessibilityIdentifier("wilted-reports-headline-gap")
                        if let line = WiltedMacBulletinHub.statusLine(model.bulletinHub.status) {
                            note(line, id: "wilted-reports-bulletin-status")
                        }

                        Divider()

                        Toggle("Daily report", isOn: reportsBinding(\.reportEnabled))
                            .accessibilityIdentifier("wilted-reports-daily")
                        DatePicker("Report time", selection: reportTimeBinding, displayedComponents: .hourAndMinute)
                            .disabled(!settings.reportEnabled)
                            .accessibilityIdentifier("wilted-reports-time")
                        #if canImport(WiltedProducer)
                        reportStatusRow
                        #endif

                        Divider()

                        locationSection

                        Divider()

                        LabeledContent("Weather service contact") {
                            TextField("Weather service contact", text: $contactText, prompt: Text("Email or web address"))
                                .labelsHidden()
                                .frame(maxWidth: 280)
                                .onSubmit(commitContact)
                                .accessibilityIdentifier("wilted-reports-nws-contact")
                        }
                    }
                    .padding(.top, WiltedTheme.Spacing.small)
                } label: {
                    Text("Alerts, headlines, daily report and location")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
                .accessibilityIdentifier("wilted-reports-details")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-reports-controls")
        .overlay(alignment: .topTrailing) {
            WiltedMacHelpButton(content: Self.help, identifier: "wilted-reports-help")
                .padding(WiltedTheme.Spacing.medium)
        }
        .task {
            latitudeText = settings.typedLatitude.map(Self.decimal) ?? ""
            longitudeText = settings.typedLongitude.map(Self.decimal) ?? ""
            contactText = settings.nwsContact
            location.typedCoordinates = settings.typedCoordinates
        }
    }

    // MARK: Location

    @ViewBuilder private var locationSection: some View {
        WiltedSettingsRow(
            "Location", value: Self.statusText(location.status),
            identifier: "wilted-reports-location-status", tone: Self.tone(location.status))
        if location.detail != .usingTyped {
            note(Self.detailText(location.detail), id: "wilted-reports-location-detail")
        }
        locationButton
        LabeledContent("Latitude") {
            TextField("Latitude", text: $latitudeText, prompt: Text("38.90"))
                .labelsHidden()
                .frame(maxWidth: 140)
                .onSubmit(commitCoordinates)
                .accessibilityIdentifier("wilted-reports-latitude")
        }
        LabeledContent("Longitude") {
            TextField("Longitude", text: $longitudeText, prompt: Text("-77.04"))
                .labelsHidden()
                .frame(maxWidth: 140)
                .onSubmit(commitCoordinates)
                .accessibilityIdentifier("wilted-reports-longitude")
        }
        if coordinateProblem {
            Text("Latitude must be from -90 to 90 and longitude from -180 to 180.")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.degraded, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-reports-coordinate-problem")
        }
    }

    @ViewBuilder private var locationButton: some View {
        switch location.authorization {
        case .notDetermined:
            Button("Allow location access") { location.requestPermission() }
                .accessibilityIdentifier("wilted-reports-location-allow")
        case .denied:
            Button("Open Location settings") { Self.openLocationSettings() }
                .accessibilityIdentifier("wilted-reports-location-open-settings")
        case .authorized:
            Button("Update location") { location.refresh() }
                .accessibilityIdentifier("wilted-reports-location-refresh")
        }
    }

    private func commitCoordinates() {
        let lat = latitudeText.trimmingCharacters(in: .whitespaces)
        let lon = longitudeText.trimmingCharacters(in: .whitespaces)
        if lat.isEmpty && lon.isEmpty {
            coordinateProblem = false
            setTyped(latitude: nil, longitude: nil)
        } else if let latitude = Double(lat), let longitude = Double(lon),
                  WiltedCoordinates(latitude: latitude, longitude: longitude) != nil {
            coordinateProblem = false
            setTyped(latitude: latitude, longitude: longitude)
        } else {
            coordinateProblem = true
            return
        }
        latitudeText = model.automationSettings.typedLatitude.map(Self.decimal) ?? ""
        longitudeText = model.automationSettings.typedLongitude.map(Self.decimal) ?? ""
    }

    private func setTyped(latitude: Double?, longitude: Double?) {
        model.updateAutomationSettings { current in
            current.updatingReports { $0.typedLatitude = latitude; $0.typedLongitude = longitude }
        }
        location.typedCoordinates = model.automationSettings.typedCoordinates
    }

    private func commitContact() {
        model.updateAutomationSettings { current in current.updatingReports { $0.nwsContact = contactText } }
        contactText = model.automationSettings.nwsContact
    }

    // MARK: Bindings and text

    private func reportsBinding<Value>(_ keyPath: WritableKeyPath<WiltedAutomationSettings.ReportsFields, Value>)
        -> Binding<Value> {
        Binding(
            get: { WiltedAutomationSettings.ReportsFields(model.automationSettings)[keyPath: keyPath] },
            set: { value in
                model.updateAutomationSettings { current in current.updatingReports { $0[keyPath: keyPath] = value } }
            })
    }

    private var reportTimeBinding: Binding<Date> {
        Binding(
            get: {
                let time = settings.reportTime
                return Calendar.current.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                guard let hour = parts.hour, let minute = parts.minute,
                      let time = WiltedAutomationLocalTime(hour: hour, minute: minute) else { return }
                model.updateAutomationSettings { current in current.updatingReports { $0.reportTime = time } }
            })
    }

    #if canImport(WiltedProducer)
    /// The last report's outcome in one caption line, and a text button to build one now.
    @ViewBuilder private var reportStatusRow: some View {
        let controller = model.morningReport
        HStack(alignment: .firstTextBaseline) {
            if let line = controller.state.caption() {
                note(line, id: "wilted-reports-daily-status")
            }
            Spacer(minLength: WiltedTheme.Spacing.large)
            Button("Build now") { Task { await controller.buildNow() } }
                .disabled(WiltedMorningReportState.buildNowDisabled(
                    state: controller.state, reportEnabled: settings.reportEnabled))
                .help("Build today's report now")
                .accessibilityIdentifier("wilted-reports-build-now")
        }
    }
    #endif

    private func note(_ text: String, id: String) -> some View {
        Text(text)
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(id)
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: WiltedTheme.Spacing.large)
            Text(value).foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
    }

    static let help = WiltedMacHelpContent(title: "Reports", text:
        "Playback pauses at a natural break, reads the bulletin, then resumes. Interruptions are off until you turn them on. "
        + "Typed coordinates are used whenever this Mac has no location fix; press Return to save them, or clear both to remove. "
        + "The National Weather Service contact is sent with weather requests so the service can reach you; press Return to save it.")

    static func statusText(_ status: WiltedLocationStatus) -> String {
        switch status {
        case .none: "Not set up"
        case .denied: "Access off"
        case .noFix: "No fix"
        case .typed: "Typed coordinates"
        case .located: "Located"
        }
    }

    static func tone(_ status: WiltedLocationStatus) -> WiltedStatusTone {
        switch status {
        case .located, .typed: .positive
        case .denied, .noFix: .caution
        case .none: .neutral
        }
    }

    static func detailText(_ detail: WiltedLocationDetail) -> String {
        switch detail {
        case .notRequested:
            "Weather needs a location. Allow access, or type coordinates below."
        case .permissionDenied:
            "Location access is off for Wilted. Allow it in System Settings, or type coordinates below."
        case .wifiOff:
            "Wi-Fi is off. This Mac finds its location from nearby Wi-Fi, so turn Wi-Fi on or type coordinates below."
        case .fixFailed:
            "No location fix yet. Try again, or type coordinates below."
        case .fixDiscardedWifiOff:
            "Wi-Fi turned off while locating, so the result was discarded. Turn Wi-Fi on or type coordinates below."
        case .usingTyped:
            "Using the coordinates you typed."
        case .fixAccepted:
            "Found from nearby Wi-Fi and rounded to about 1 km. Kept in memory only."
        }
    }

    private static func decimal(_ value: Double) -> String { String(format: "%g", value) }

    private static func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}
