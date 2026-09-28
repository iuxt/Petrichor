import Foundation

/// Bounds the entire read/decode/compress pipeline, before it allocates image data.
/// Waiting rows hold only continuations and are removed when they disappear.
actor ArtworkLoadLimiter {
    private let limit: Int
    private var active = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int = 2) {
        precondition(limit > 0)
        self.limit = limit
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if active < limit {
                    active += 1
                    continuation.resume(returning: true)
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // Cancellation may race a permit being handed to this waiter.
        if acquired && Task.isCancelled {
            release()
            return false
        }
        return acquired
    }

    func release() {
        if waiting.isEmpty {
            active -= 1
        } else {
            waiting.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }
}
