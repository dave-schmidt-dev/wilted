import Foundation

@MainActor
final class WiltedMacHeadlineToastTimer {
    typealias SleepOperation = @MainActor (Duration) async throws -> Void

    private let sleep: SleepOperation
    private var task: Task<Void, Never>?
    private var deadline: ContinuousClock.Instant?
    private var remaining: Duration = .zero
    private var onFade: (@MainActor () -> Void)?
    private var isPaused = false
    private var generation = UUID()

    init(sleep: @escaping SleepOperation = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func start(after seconds: Double, onFade: @escaping @MainActor () -> Void) {
        cancel()
        remaining = .seconds(max(seconds, 0.1))
        self.onFade = onFade
        schedule()
    }

    func pause() {
        guard !isPaused, let deadline else { return }
        remaining = max(.zero, ContinuousClock().now.duration(to: deadline))
        task?.cancel()
        task = nil
        self.deadline = nil
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        schedule()
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        deadline = nil
        remaining = .zero
        onFade = nil
        isPaused = false
    }

    private func schedule() {
        guard let onFade else { return }
        guard remaining > .zero else {
            self.onFade = nil
            onFade()
            return
        }
        let clock = ContinuousClock()
        let duration = remaining
        let token = UUID()
        generation = token
        deadline = clock.now.advanced(by: duration)
        let sleep = self.sleep
        task = Task { [weak self] in
            do { try await sleep(duration) }
            catch { return }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.task = nil
            self.deadline = nil
            self.remaining = .zero
            self.onFade = nil
            onFade()
        }
    }
}
