import SwiftUI
import WiltedLibrary

/// One Listen next control shared by the Larder cards and Now Playing.
struct LibraryListenNextControl: View {
    let storyID: String
    let request: LibraryListenNextRequestSnapshot?
    let receivedBytes: Int64?
    let statusText: String?
    let message: String?
    let identifierPrefix: String
    let onListenNext: () -> Void
    let onUndo: (String) -> Void
    let onRetry: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var isDownloading: Bool {
        receivedBytes != nil && (request?.audioOffer?.byteCount ?? 0) > 0
    }

    private var resolvedStatus: String {
        if isDownloading { return "Downloading audio" }
        guard let request else { return "Listen next" }
        return statusText ?? LibraryAppModel.listenNextLabel(for: request.status)
    }

    var body: some View {
        if let request {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Label(resolvedStatus, systemImage: request.status == .playing ? "speaker.wave.2.fill" : "text.book.closed")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(resolvedStatus)
                    .accessibilityIdentifier("\(identifierPrefix)-listen-status-\(storyID)")

                if let receivedBytes,
                   let totalBytes = request.audioOffer?.byteCount,
                   totalBytes > 0 {
                    let percentage = min(100, max(0, Int((Double(receivedBytes) / Double(totalBytes)) * 100)))
                    ProgressView(value: Double(receivedBytes), total: Double(totalBytes))
                        .accessibilityLabel("Downloading story audio")
                        .accessibilityValue("\(percentage)%")
                        .accessibilityIdentifier("\(identifierPrefix)-listen-progress-\(storyID)")
                }

                if let message {
                    Text(message)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if request.status == .failed {
                    actionButton("Retry", identifier: "\(identifierPrefix)-listen-retry-\(storyID)") {
                        onRetry(request.requestID)
                    }
                } else if request.status == .completed {
                    actionButton("Listen again next", identifier: "\(identifierPrefix)-listen-next-\(storyID)", action: onListenNext)
                } else if request.status != .playing && !request.isTerminal {
                    actionButton("Undo", identifier: "\(identifierPrefix)-listen-undo-\(storyID)") {
                        onUndo(request.requestID)
                    }
                }
            }
        } else {
            actionButton("Listen next", identifier: "\(identifierPrefix)-listen-next-\(storyID)", action: onListenNext)
        }
    }

    private func actionButton(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "text.book.closed")
        }
        .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityIdentifier(identifier)
    }
}

extension LibraryAppModel {
    /// Returns the newest non-cancelled request for this canonical headline story.
    func listenNextRequest(forStoryID storyID: String) -> LibraryListenNextRequestSnapshot? {
        listenNextRequests
            .filter { $0.storyID == storyID && $0.status != .cancelled }
            .max { $0.createdAt < $1.createdAt }
    }
}
