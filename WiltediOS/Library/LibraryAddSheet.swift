import SwiftUI
import WiltedDomain
import WiltedLibrary

/// The one way to add anything from the phone: a single field, the results beneath it, and one primary
/// action on each result. Search runs on the phone; a chosen result or link is sent to the Mac, which
/// does the adding. The sheet reuses the Mac Add sheet's words and card layout. Opened by the Larder's
/// plus button.
struct LibraryAddSheet: View {
    @ObservedObject var model: LibraryAppModel
    @StateObject private var session: LibraryAddSession
    let onDone: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFieldFocused: Bool

    init(model: LibraryAppModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
        _session = StateObject(wrappedValue: model.makeAddSession())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
                    fieldCard
                    // Why adding is off comes first: it changes what every result below can do.
                    if let notice = model.addNotice ?? model.addCapabilityNotice {
                        statusLine(
                            LibraryAddStatus(text: notice, tone: .caution, symbol: "exclamationmark.triangle"),
                            identifier: "wilted-add-notice")
                    }
                    if let status = session.statusMessage { note(status, identifier: "wilted-add-status") }
                    if !session.rows.isEmpty { resultsCard }
                    if !model.adds.isEmpty { sentCard }
                }
                .padding(WiltedTheme.Spacing.large)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(WiltedTheme.color(.page, scheme: colorScheme))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Add").wiltedFont(.title)
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onDone) { Text("Done").wiltedFont(.body) }
                        .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                        .accessibilityIdentifier("wilted-add-done")
                }
            }
        }
        .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
        .task {
            session.start()
            isFieldFocused = true
        }
        .onDisappear {
            session.cancel()
            model.clearFinishedAdds()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-add-sheet")
    }

    // MARK: Field

    private var fieldCard: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityHidden(true)
            TextField("Search podcasts or paste a link", text: text)
                .wiltedFont(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.search)
                .focused($isFieldFocused)
                .onSubmit {
                    isFieldFocused = false
                    session.submit()
                }
                .accessibilityIdentifier("wilted-add-field")
            if session.isWorking {
                ProgressView()
                    .accessibilityLabel("Working")
                    .accessibilityIdentifier("wilted-add-progress")
                Button { session.cancel() } label: { Text("Stop").wiltedFont(.utility) }
                    .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityIdentifier("wilted-add-cancel")
            } else if !model.addDraft.isEmpty {
                Button { session.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityLabel("Clear")
                    .accessibilityIdentifier("wilted-add-clear")
            }
        }
        .padding(.horizontal, WiltedTheme.Spacing.large)
        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
        .background(WiltedTheme.color(.card, scheme: colorScheme), in: RoundedRectangle(cornerRadius: WiltedTheme.Spacing.medium))
    }

    private var text: Binding<String> {
        Binding(get: { session.text }, set: { session.text = $0 })
    }

    // MARK: Results

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(session.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                resultRow(row)
            }
        }
        .wiltedCard(colorScheme)
    }

    private func resultRow(_ row: LibraryAddSession.Row) -> some View {
        let titles = VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Text(row.title)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .lineLimit(2)
            Text(row.detail)
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        return Group {
            switch row.kind {
            case let .show(feed, following):
                // One decision, beside the show it affects.
                HStack(spacing: WiltedTheme.Spacing.medium) {
                    titles
                    showAction(row, feed: feed, following: following)
                }
            case let .link(url):
                // The phone cannot tell what a link is, so the choice sits under it.
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                    titles
                    HStack(spacing: WiltedTheme.Spacing.medium) {
                        button("Article", enabled: model.canAdd(.article(url)), label: "Add \(row.title) as an article",
                               identifier: "wilted-add-article-\(row.id)") { await session.send(row, as: .article) }
                        button("Podcast feed", enabled: model.canAdd(.subscribe(url)),
                               label: "Subscribe to \(row.title) as a podcast feed",
                               identifier: "wilted-add-feed-\(row.id)") { await session.send(row, as: .podcastFeed) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WiltedTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-add-result-\(row.id)")
    }

    @ViewBuilder
    private func showAction(_ row: LibraryAddSession.Row, feed: URL, following: Bool) -> some View {
        if row.requestPhase != nil || following {
            // Sent and applied read like the Mac's row; the request's own words are in the list below.
            let isSent = row.requestPhase == .sent
            Label(isSent ? "Sent" : "Following", systemImage: isSent ? "paperplane" : "checkmark.circle")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget, alignment: .trailing)
                .accessibilityLabel(isSent ? "Sent to your Mac: \(row.title)" : "Following \(row.title)")
                .accessibilityIdentifier("wilted-add-following-\(row.id)")
        } else {
            button("Subscribe", enabled: model.canAdd(.subscribe(feed)), label: "Subscribe to \(row.title)",
                   identifier: "wilted-add-subscribe-\(row.id)") { await session.send(row) }
        }
    }

    private func button(
        _ title: String, enabled: Bool, label: String, identifier: String, action: @escaping () async -> Void
    ) -> some View {
        Button { Task { await action() } } label: {
            Text(title).wiltedFont(.body).frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget - 16)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Sent

    private var sentCard: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            Text("Your requests")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.adds.enumerated()), id: \.element.id) { index, add in
                    if index > 0 { Divider() }
                    sentRow(add)
                }
            }
            .wiltedCard(colorScheme)
        }
        .accessibilityIdentifier("wilted-add-requests")
    }

    private func sentRow(_ add: PendingAdd) -> some View {
        HStack(alignment: .top, spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text(add.title)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(2)
                Text(add.isSubscribe ? "Podcast" : "Article")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                statusLine(model.addStatus(for: add), identifier: "wilted-add-request-status-\(add.id)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if add.isFinished {
                Button { model.dismissAdd(add.id) } label: { Image(systemName: "xmark") }
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .frame(minWidth: WiltedTheme.Spacing.minimumTouchTarget, minHeight: WiltedTheme.Spacing.minimumTouchTarget)
                    .accessibilityLabel("Dismiss")
                    .accessibilityIdentifier("wilted-add-dismiss-\(add.id)")
            }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-add-request-\(add.id)")
    }

    // MARK: Words

    private func note(_ string: String, identifier: String) -> some View {
        Text(string)
            .wiltedFont(.utility)
            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    /// A status in words, an icon and a tone; the tone never carries the state alone (W-INV-010).
    private func statusLine(_ status: LibraryAddStatus, identifier: String) -> some View {
        Label {
            Text(status.text).wiltedFont(.utility)
        } icon: {
            Image(systemName: status.symbol)
        }
        .foregroundStyle(status.tone.color(colorScheme))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
