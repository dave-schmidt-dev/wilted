import Foundation
import Network
import OSLog

private let locatorLog = Logger(subsystem: "com.zerodelta.wilted", category: "LocalMacLocator")

/// Browses for the Mac's `_wilted-media._tcp` service, only while a direct download is wanted: one
/// browse per call, stopped when the call returns. The service name and TXT record carry nothing about
/// the Mac or the account, so a neighbour's Mac is found too and turned away by the handshake.
struct LocalMacLocator: LocalMacLocating {
    static let serviceType = "_wilted-media._tcp"
    /// `kDNSServiceErr_PolicyDenied`: how a refused Local Network permission shows in the browser's state.
    private static let policyDenied: Int32 = -65570

    func locate(within budget: Duration) async -> LocalMacSearch {
        let session = BrowseSession()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<LocalMacSearch, Never>) in
                session.begin(continuation, budget: budget)
            }
        } onCancel: { session.finish(.none) }
    }

    /// One browse. Finishes exactly once: with the first non-empty result set, a denial, or the budget.
    private final class BrowseSession: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<LocalMacSearch, Never>?
        private var finished: LocalMacSearch?
        private var browser: NWBrowser?
        private let queue = DispatchQueue(label: "com.zerodelta.wilted.locator")

        func begin(_ continuation: CheckedContinuation<LocalMacSearch, Never>, budget: Duration) {
            let early = lock.withLock { () -> LocalMacSearch? in
                if let finished { return finished }
                self.continuation = continuation
                return nil
            }
            if let early { continuation.resume(returning: early); return }
            let browser = NWBrowser(for: .bonjour(type: LocalMacLocator.serviceType, domain: nil), using: NWParameters())
            browser.stateUpdateHandler = { [weak self] state in
                guard case let .waiting(error) = state else { return }
                if case let .dns(code) = error, code == LocalMacLocator.policyDenied {
                    locatorLog.notice("Local Network access is off for Wilted")
                    self?.finish(.denied)
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let endpoints = results.map(\.endpoint)
                if !endpoints.isEmpty { self?.finish(.found(endpoints)) }
            }
            let stored = lock.withLock { () -> Bool in
                guard finished == nil else { return false }
                self.browser = browser
                return true
            }
            guard stored else { return }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(budget.components.seconds) * 1_000_000_000
                + Int(budget.components.attoseconds / 1_000_000_000))) { [weak self] in self?.finish(.none) }
        }

        func finish(_ result: LocalMacSearch) {
            let (pending, browser) = lock.withLock { () -> (CheckedContinuation<LocalMacSearch, Never>?, NWBrowser?) in
                guard finished == nil else { return (nil, nil) }
                finished = result
                defer { continuation = nil; self.browser = nil }
                return (continuation, self.browser)
            }
            browser?.cancel()
            pending?.resume(returning: result)
        }
    }
}
