import Foundation

/// Actor reentrancy alone does not serialize awaited SCStream updates. Each
/// update waits for the complete previous operation, including its framework ACK.
actor PrivacyFilterQueue {
    private var tail: Task<Void, Never>?
    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        let job = Task {
            if let previous { await previous.value }
            try await operation()
        }
        tail = Task { _ = try? await job.value }
        try await job.value
    }
}
