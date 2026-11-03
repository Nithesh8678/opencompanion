import Foundation

public enum StoreError: Error, LocalizedError, Sendable, Equatable {
    case database(code: Int32, message: String)
    case unsupportedSchema(Int)
    case invalidValue(String)
    case notFound(String)
    case leaseUnavailable
    case staleLease
    case reconciliationRequired

    public var errorDescription: String? {
        switch self {
        case let .database(code, message): "Local database error (\(code)): \(message)"
        case let .unsupportedSchema(version): "This database uses a newer schema (\(version)). Update the app before opening it."
        case let .invalidValue(message): message
        case let .notFound(id): "No saved item was found for \(id)."
        case .leaseUnavailable: "This job already has an owner or is not ready to run."
        case .staleLease: "The job lease expired, was cancelled, or changed ownership."
        case .reconciliationRequired: "The previous action's outcome must be checked before this job can resume."
        }
    }
}

public struct StoredRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let title: String
    public let body: String
    public let payload: Data?
    public let createdAt: Date
    public let updatedAt: Date
}

public enum JobStatus: String, Codable, Sendable, CaseIterable {
    case queued, running, paused, succeeded, failed, cancelled, outcomeUnknown
}

/// A provider key alone does not make a desktop action idempotent. Use
/// `requiresReconciliation` unless replay is demonstrably safe.
public enum RetryClass: String, Codable, Sendable, CaseIterable {
    case idempotent, requiresReconciliation, never
}

public struct DurableJob: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let instruction: String
    public let scope: String
    public let checkpoint: Data?
    public let status: JobStatus
    public let progress: Double
    public let retryClass: RetryClass
    public let retryBudget: Int
    public let attempts: Int
    public let cancellationGeneration: Int
    public let nextRunAt: Date?
    public let lastError: String?
    public let createdAt: Date
    public let updatedAt: Date
}

public struct JobLease: Codable, Sendable, Equatable {
    public let jobID: String
    public let owner: String
    public let token: String
    public let expiresAt: Date
    public let cancellationGeneration: Int
}

public enum ActionStatus: String, Codable, Sendable {
    case inFlight, succeeded, failed, outcomeUnknown
}

public struct ActionReceipt: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let jobID: String
    public let operation: String
    public let retryClass: RetryClass
    public let idempotencyKey: String?
    public let status: ActionStatus
    public let result: Data?
    public let createdAt: Date
    public let updatedAt: Date
}

public enum MissedRunPolicy: String, Codable, Sendable, CaseIterable {
    /// Schedule the next interval after now; do not run missed occurrences.
    case skip
    /// Run once for any number of missed occurrences; never create a backlog.
    case runOnce
}

public struct Routine: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let instruction: String
    public let scope: String
    public let interval: TimeInterval
    public let nextRunAt: Date
    public let missedRunPolicy: MissedRunPolicy
    public let enabled: Bool
    public let lastEnqueuedAt: Date?

    public init(id: String = UUID().uuidString, title: String, instruction: String, scope: String,
                interval: TimeInterval, nextRunAt: Date, missedRunPolicy: MissedRunPolicy = .runOnce,
                enabled: Bool = true, lastEnqueuedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.scope = scope
        self.interval = interval
        self.nextRunAt = nextRunAt
        self.missedRunPolicy = missedRunPolicy
        self.enabled = enabled
        self.lastEnqueuedAt = lastEnqueuedAt
    }
}
