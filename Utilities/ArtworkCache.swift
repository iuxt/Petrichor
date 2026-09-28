import AppKit
import Foundation

/// A cancelled Operation may never enter main(), so cancellation must also
/// resume the waiter. Protect installation and completion against races.
final class ArtworkLoadOperation: Operation, @unchecked Sendable {
    private let completionLock = NSLock()
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var hasCompleted = false
    private let work: () -> NSImage?

    init(work: @escaping () -> NSImage?) {
        self.work = work
        super.init()
    }

    func install(_ continuation: CheckedContinuation<NSImage?, Never>) {
        completionLock.lock()
        if hasCompleted {
            completionLock.unlock()
            continuation.resume(returning: nil)
        } else {
            self.continuation = continuation
            completionLock.unlock()
        }
    }

    override func main() {
        let image = autoreleasepool { isCancelled ? nil : work() }
        complete(image)
    }

    override func cancel() {
        super.cancel()
        complete(nil)
    }

    private func complete(_ image: NSImage?) {
        completionLock.lock()
        guard !hasCompleted else {
            completionLock.unlock()
            return
        }
        hasCompleted = true
        let waiter = continuation
        continuation = nil
        completionLock.unlock()
        waiter?.resume(returning: image)
    }
}

extension OperationQueue {
    /// Enqueues a render and resumes its continuation when complete.
    /// Cancelling the awaiting task cancels the queued operation; cancelled
    /// operations resume with `nil` without rendering.
    func renderArtwork(_ work: @escaping () -> NSImage?) async -> NSImage? {
        let operation = ArtworkLoadOperation(work: work)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.install(continuation)
                self.addOperation(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}
