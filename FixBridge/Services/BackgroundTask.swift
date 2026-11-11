import Foundation

/// Bridges bounded blocking work without losing cancellation from its caller.
enum BackgroundTask {
    static func run<Value: Sendable>(
        priority: TaskPriority = .utility,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            task.cancel()
        }
    }
}
