import AppKit
import SwiftUI
import WiltedDomain

// MARK: - Reports

/// Settings > Reports: spoken weather alerts and headlines at pause points, the daily report, and
/// the location that weather needs. Interruptions are off until the listener turns them on.
struct WiltedMacReportsCard: View {
    let model: WiltedMacModel
    let location: WiltedLocationProvider
    @State private var feedPolicyBoard: WiltedMacFeedPolicyBoard
    @Environment(\.colorScheme) private var colorScheme
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var contactText = ""
    @State private var skipWordsText = ""
    @State private var coordinateProblem = false
    @State private var showsDetails: Bool
    @State private var showsHeadlineSources = false
    @FocusState private var focusedLocationField: LocationField?
    private let readinessOverride: BulletinReadiness?

    private enum LocationField { case latitude, longitude }

    /// The details start folded: interruptions are off by default, and the rest only matters once on.
    init(model: WiltedMacModel, location: WiltedLocationProvider, policyBoard: WiltedMacFeedPolicyBoard? = nil,
         startsExpanded: Bool = false,
         readinessOverride: BulletinReadiness? = nil) {
        self.model = model
        self.location = location
        _feedPolicyBoard = State(initialValue: policyBoard ?? WiltedMacFeedPolicyBoard(model: model))
        self.readinessOverride = readinessOverride
        _showsDetails = State(initialValue: startsExpanded)
    }

    private var settings: WiltedAutomationSettings { model.automationSettings }

    var body: some View {
        WiltedSettingsCard(title: "Reports") {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                HStack {
                    Toggle("Read bulletins while playing", isOn: reportsBinding(\.interruptionsEnabled))
                        .accessibilityIdentifier("wilted-reports-interruptions")
                    Spacer(minLength: WiltedTheme.Spacing.small)
                    Button("Add headline feed") { showsHeadlineSources = true }
                        .accessibilityIdentifier("wilted-reports-add-news-feed")
                }
                #if canImport(WiltedProducer)
                if settings.interruptionsEnabled {
                    readinessSection
                }
                #endif
                DisclosureGroup(isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                        if let line = Self.interruptionsOffNote(interruptionsEnabled: settings.interruptionsEnabled) {
                            note(line, id: "wilted-reports-interruptions-off-note")
                        }
                        Toggle("Weather alerts", isOn: reportsBinding(\.alertsEnabled))
                            .disabled(!settings.interruptionsEnabled)
                            .accessibilityIdentifier("wilted-reports-alerts")
                        Toggle("Headlines", isOn: reportsBinding(\.headlinesEnabled))
                            .disabled(!settings.interruptionsEnabled)
                            .accessibilityIdentifier("wilted-reports-headlines")
                        topicsSection
                            .padding(.leading, WiltedTheme.Spacing.large)
                            .disabled(!settings.reportEnabled && !(settings.interruptionsEnabled && settings.headlinesEnabled))
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
#if canImport(WiltedProducer)
        .sheet(isPresented: $showsHeadlineSources) {
            WiltedMacHeadlineSourceSheet(model: model, policyBoard: feedPolicyBoard)
        }
#endif
        .task {
            latitudeText = settings.typedLatitude.map(Self.decimal) ?? ""
            longitudeText = settings.typedLongitude.map(Self.decimal) ?? ""
            contactText = settings.nwsContact
            skipWordsText = Self.wordsText(settings.skippedHeadlineWords)
            location.typedCoordinates = settings.typedCoordinates
        }
    }

    #if canImport(WiltedProducer)
    @ViewBuilder private var readinessSection: some View {
        let hub = model.bulletinHub
        let readiness = readinessOverride ?? hub.readiness
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            ForEach(readiness.lines, id: \.self) { line in readinessRow(line) }
            Button("Play a test bulletin") { _ = model.bulletinHub.playTestBulletin() }
                .accessibilityIdentifier("wilted-reports-test-bulletin")
        }
        .padding(.leading, WiltedTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-reports-readiness")
        .task(id: model.store.map(ObjectIdentifier.init)) {
            await hub.refreshNewsSourceReadiness()
        }
        .onChange(of: model.isPresentingAddSheet) { _, presented in
            if !presented { refreshNewsSourceReadiness() }
        }
        .onChange(of: model.subscriptions) { _, _ in refreshNewsSourceReadiness() }
    }

    @ViewBuilder private func readinessRow(_ line: BulletinReadiness.Line) -> some View {
        HStack(alignment: .top, spacing: WiltedTheme.Spacing.small) {
            Text(line.text)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(readinessColor(line), scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch line {
            case .news:
                EmptyView()
            case .weather, .locationDenied:
                Button("Set location") { focusLocationFields() }
                    .accessibilityIdentifier("wilted-reports-set-location")
            case .sound:
                Button("Try again") { model.bulletinHub.retryBulletinOutputCheck() }
                    .accessibilityIdentifier("wilted-reports-retry-sound-check")
            case .ready, .checkingNews:
                EmptyView()
            case .unknownNews:
                Button("Check headline feeds") { refreshNewsSourceReadiness() }
                    .accessibilityIdentifier("wilted-reports-refresh-news-readiness")
            case .chooseSources:
                Button("Choose bulletins") { showsDetails = true }
            }
        }
    }

    private func readinessColor(_ line: BulletinReadiness.Line) -> WiltedTheme.ColorToken {
        switch line {
        case .ready: .success
        case .checkingNews: .secondaryText
        default: .degraded
        }
    }

    private func refreshNewsSourceReadiness() {
        Task { await model.bulletinHub.refreshNewsSourceReadiness() }
    }

    private func focusLocationFields() {
        showsDetails = true
        Task { @MainActor in
            await Task.yield()
            focusedLocationField = .latitude
        }
    }
    #endif

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
                .focused($focusedLocationField, equals: .latitude)
                .onSubmit(commitCoordinates)
                .accessibilityIdentifier("wilted-reports-latitude")
        }
        LabeledContent("Longitude") {
            TextField("Longitude", text: $longitudeText, prompt: Text("-77.04"))
                .labelsHidden()
                .frame(maxWidth: 140)
                .focused($focusedLocationField, equals: .longitude)
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

    /// Skip sports, the listener's own words, and how many of the current headlines they skip.
    @ViewBuilder private var topicsSection: some View {
        Toggle("Skip sports headlines", isOn: reportsBinding(\.skipSportsHeadlines))
            .accessibilityIdentifier("wilted-reports-skip-sports")
        LabeledContent("Also skip") {
            TextField("Also skip", text: $skipWordsText, prompt: Text("Words, separated by commas"))
                .labelsHidden()
                .frame(maxWidth: 280)
                .onSubmit(commitSkipWords)
                .accessibilityIdentifier("wilted-reports-skip-words")
        }
        if let line = Self.skippedNote(model.bulletinHub.status.skippedHeadlineCount) {
            note(line, id: "wilted-reports-skipped-count")
        }
    }

    private func commitSkipWords() {
        let words = skipWordsText.split(separator: ",").map(String.init)
        model.updateAutomationSettings { current in current.updatingReports { $0.skippedHeadlineWords = words } }
        skipWordsText = Self.wordsText(model.automationSettings.skippedHeadlineWords)
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
                .help(WiltedMorningReportState.buildNowHelp(
                    state: controller.state, reportEnabled: settings.reportEnabled))
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
        + "Headlines about sports, or containing any word you list under Also skip, are never read. "
        + "Typed coordinates are used whenever this Mac has no location fix; press Return to save them, or clear both to remove. "
        + "The National Weather Service contact is sent with weather requests so the service can reach you; press Return to save it.")

    static func wordsText(_ words: [String]) -> String { words.joined(separator: ", ") }

    /// How many of the headlines the news feeds list now are skipped; nil when none is.
    static func skippedNote(_ count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 current headline is skipped by these topics."
        default: "\(count) current headlines are skipped by these topics."
        }
    }

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

    /// Why the alerts, headlines and their steppers are disabled while interruptions are off.
    static func interruptionsOffNote(interruptionsEnabled: Bool) -> String? {
        interruptionsEnabled ? nil : "Turn on Read bulletins while playing to use alerts and headlines."
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
