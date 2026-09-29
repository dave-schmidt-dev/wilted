import SwiftUI
import WiltedDomain
import WiltedLibrary

/// The iPhone Larder: the Mac's queue, in the Mac's order. Builds the production CloudKit
/// environment unless a test or preview injects a model.
struct LibraryRoot: View {
    @StateObject private var model: LibraryAppModel
    @Environment(\.scenePhase) private var scenePhase

    init(model: LibraryAppModel? = nil) {
        _model = StateObject(wrappedValue: model ?? LibraryEnvironment.makeModel())
    }

    var body: some View {
        LibraryListView(model: model)
            .task {
                LibraryPushHandler.shared.attach { await model.handleSilentPush() }
                await model.start()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.refresh() } }
            }
    }
}

struct LibraryListView: View {
    @ObservedObject var model: LibraryAppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            if model.accountQuarantined {
                Section {
                    WiltedAccountRecoveryNotice { Task { await model.recoverFromAccountChange() } }
                }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedStatusTone.caution.color(colorScheme))
                        .accessibilityIdentifier("wilted-library-error")
                }
            }
            if model.queued.isEmpty && model.removed.isEmpty {
                emptyState
            } else {
                Section {
                    ForEach(model.queued) { LibraryRowView(row: $0) }
                }
                if !model.removed.isEmpty {
                    Section {
                        Picker("Sort removed by", selection: $model.removedSort) {
                            ForEach(LibraryRemovedSort.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("wilted-library-removed-sort")
                        ForEach(model.removed) { LibraryRowView(row: $0) }
                    } header: {
                        Text("Removed")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .refreshable { await model.refresh() }
        .navigationTitle(WiltedScreenCopy.library)
        .accessibilityIdentifier("wilted-library-list")
    }

    @ViewBuilder private var emptyState: some View {
        if model.isRefreshing {
            HStack(spacing: WiltedTheme.Spacing.medium) {
                ProgressView()
                Text("Fetching the Larder").wiltedFont(.body)
            }
            .accessibilityIdentifier("wilted-library-loading")
        } else {
            ContentUnavailableView {
                Label("Nothing in the Larder", symbol: .larder)
            } description: {
                Text("Episodes queued on your Mac appear here.")
            }
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("wilted-library-empty")
        }
    }
}

struct LibraryRowView: View {
    let row: LibraryRow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            Text(row.title)
                .wiltedFont(.body)
                .lineLimit(2)
                .accessibilityIdentifier("wilted-library-title-\(row.id.rawValue)")
            Text(subtitle)
                .wiltedFont(.utility)
                .foregroundStyle(secondary)
                .lineLimit(1)
            if let removal = row.removalText {
                Text(removal)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedStatusTone.caution.color(colorScheme))
                    .accessibilityIdentifier("wilted-library-removal-\(row.id.rawValue)")
            }
            if let checkpoint = row.checkpointText {
                Text(checkpoint)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.progress, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-library-checkpoint-\(row.id.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, minHeight: WiltedTheme.Spacing.minimumTouchTarget, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-library-row-\(row.id.rawValue)")
    }

    private var subtitle: String { [row.showTitle, row.durationText].compactMap { $0 }.joined(separator: " · ") }
    private var secondary: Color { WiltedTheme.color(.secondaryText, scheme: colorScheme) }
}

#if DEBUG
/// Preview-only data: a Mac writer and an iPhone reader on one in-memory server.
enum LibraryPreviewData {
    @MainActor static func model() async -> LibraryAppModel {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let show = LibrarySource(id: try! ItemID(rawValue: "show-1"), kind: .podcastFeed, title: "Example Show")
        var changes: [LibraryChange] = [.source(show)]
        for (index, title) in ["Queued first", "Queued second"].enumerated() {
            let id = try! ItemID(rawValue: "entry-\(index)")
            let entry = try! LibraryEntry(
                id: id, kind: .podcastEpisode, sourceID: show.id, title: title, summary: "",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 1_800 + Double(index) * 600)
            changes += [.entry(entry), .slot(try! QueueSlot(entryID: id, sortKey: Double(index)))]
        }
        let pending = changes.enumerated().map { PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0) }
        _ = try? await mac.push(changes: pending)
        return LibraryAppModel(transport: InMemoryLibraryTransport(deviceID: "phone", server: server), deviceID: "phone")
    }
}

private struct LibraryPreviewHost: View {
    @State private var model: LibraryAppModel?

    var body: some View {
        Group {
            if let model { LibraryRoot(model: model) } else { ProgressView() }
        }
        .task { model = await LibraryPreviewData.model() }
    }
}

#Preview("Larder") {
    NavigationStack { LibraryPreviewHost() }.preferredColorScheme(.dark)
}
#endif
