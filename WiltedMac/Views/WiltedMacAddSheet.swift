import SwiftUI
import WiltedDomain

// MARK: - Add sheet

/// The one way to add anything: a single field, the results beneath it, and one
/// primary action on each result. Opened by the toolbar Add button and ⌘N.
struct WiltedMacAddSheet: View {
    @State private var session: WiltedMacAddSession

    init(model: WiltedMacModel) {
        _session = State(initialValue: model.makeAddSession())
    }

    var body: some View {
        WiltedMacAddSheetContent(session: session)
            .onAppear { session.start() }
            .onDisappear { session.cancel() }
    }
}

/// The sheet's content, separate from the presentation so snapshots render it directly.
struct WiltedMacAddSheetContent: View {
    let session: WiltedMacAddSession
    var focusedOverride: Bool?
    @Environment(\.colorScheme) private var colorScheme

    private var text: Binding<String> {
        Binding(get: { session.text }, set: { session.text = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text("Add")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            HStack(spacing: WiltedTheme.Spacing.medium) {
                WiltedMacLinkField(
                    text: text, placeholder: "Search podcasts or paste a link",
                    identifier: "wilted-add-field", focusedOverride: focusedOverride
                )
                .onSubmit { session.submit() }
                if session.isWorking {
                    ProgressView().controlSize(.small)
                        .accessibilityIdentifier("wilted-add-progress")
                    Button("Stop") { session.cancel() }
                        .accessibilityIdentifier("wilted-add-cancel")
                }
            }
            if let status = session.statusMessage {
                note(status, identifier: "wilted-add-status")
            }
            if !session.rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        resultRow(row)
                    }
                }
                .wiltedCard(colorScheme)
            }
            if let intake = session.intakeMessage {
                note(intake, identifier: "wilted-add-intake-status")
            }
            HStack {
                Spacer()
                Button("Done") { session.close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("wilted-add-done")
            }
        }
        .padding(WiltedTheme.Spacing.large)
        .frame(width: 520)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-add-sheet")
    }

    private func note(_ text: String, identifier: String) -> some View {
        Text(text)
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    private func resultRow(_ row: WiltedMacAddSession.Row) -> some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(2)
                Text(row.detail)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch row.action {
            case .subscribe:
                Button("Subscribe") { session.subscribe(row) }
                    .disabled(session.isSubscribing)
                    .accessibilityLabel("Subscribe to \(row.title)")
                    .accessibilityIdentifier("wilted-add-subscribe-\(row.id)")
            case .following:
                Label("Following", systemImage: "checkmark.circle")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityLabel("Already following \(row.title)")
                    .accessibilityIdentifier("wilted-add-following-\(row.id)")
            case .addArticle:
                Button("Add article") { session.addArticle(row) }
                    .accessibilityIdentifier("wilted-add-article-\(row.id)")
            }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-add-result-\(row.id)")
    }
}
