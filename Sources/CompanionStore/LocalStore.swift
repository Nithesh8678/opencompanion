import CSQLite
import Foundation

/// Durable local content and app-running job checkpoints. This actor does not
/// claim to schedule execution while the application is quit or the Mac sleeps.
public actor LocalStore {
    private let database: SQLiteDatabase
    public static let schemaVersion = 3

    public init(url: URL) throws { database = try SQLiteDatabase(url: url) }

    @discardableResult
    public func saveRecord(id: String = UUID().uuidString, kind: String, title: String,
                           body: String, payload: Data? = nil) throws -> StoredRecord {
        guard !id.isEmpty, !kind.isEmpty else { throw StoreError.invalidValue("Saved content needs an ID and kind.") }
        let now = Date().timeIntervalSince1970
        try database.execute("""
        INSERT INTO records(id, kind, title, body, payload, created_at, updated_at) VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, title=excluded.title, body=excluded.body,
        payload=excluded.payload, updated_at=excluded.updated_at
        """, [.text(id), .text(kind), .text(title), .text(body), .optional(payload), .real(now), .real(now)])
        guard let record = try database.query("SELECT * FROM records WHERE id=?", [.text(id)], map: Self.record).first else {
            throw StoreError.notFound(id)
        }
        return record
    }

    public func records(kind: String? = nil, query: String = "") throws -> [StoredRecord] {
        var predicates: [String] = []
        var values: [SQLValue] = []
        if let kind { predicates.append("kind=?"); values.append(.text(kind)) }
        if !query.isEmpty {
            let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            predicates.append("(title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\')")
            values += [.text("%\(escaped)%"), .text("%\(escaped)%")]
        }
        let filter = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        return try database.query("SELECT * FROM records" + filter + " ORDER BY updated_at DESC, id", values, map: Self.record)
    }

    public func deleteRecord(id: String) throws { try database.execute("DELETE FROM records WHERE id=?", [.text(id)]) }

    /// A point-in-time JSON export; Keychain credentials and temporary screen
    /// evidence are deliberately absent from this database.
    public func exportData() throws -> Data {
        struct Export: Encodable {
            let schemaVersion: Int
            let exportedAt: Date
            let records: [StoredRecord]
            let jobs: [DurableJob]
            let receipts: [ActionReceipt]
            let routines: [Routine]
        }
        return try database.transaction {
            let contents = Export(schemaVersion: Self.schemaVersion, exportedAt: Date(), records: try records(),
                                  jobs: try jobs(), receipts: try database.query("SELECT * FROM action_receipts ORDER BY created_at, id", map: Self.receipt),
                                  routines: try routines())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(contents)
        }
    }

    @discardableResult
    public func enqueueJob(id: String = UUID().uuidString, instruction: String, scope: String,
                           checkpoint: Data? = nil, retryClass: RetryClass = .requiresReconciliation,
                           retryBudget: Int = 0, nextRunAt: Date? = nil, now: Date = Date()) throws -> DurableJob {
        guard !id.isEmpty, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, retryBudget >= 0 else {
            throw StoreError.invalidValue("A job needs an instruction, a unique ID, and a nonnegative retry budget.")
        }
        try database.execute("""
        INSERT INTO jobs(id,instruction,scope,checkpoint,status,retry_class,retry_budget,next_run_at,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        """, [.text(id), .text(instruction), .text(scope), .optional(checkpoint), .text(JobStatus.queued.rawValue),
              .text(retryClass.rawValue), .integer(retryBudget), .optional(nextRunAt),
              .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        return try job(id: id)
    }

    public func jobs() throws -> [DurableJob] {
        try database.query("SELECT * FROM jobs ORDER BY created_at DESC, id", map: Self.job)
    }

    public func job(id: String) throws -> DurableJob {
        guard let job = try database.query("SELECT * FROM jobs WHERE id=?", [.text(id)], map: Self.job).first else {
            throw StoreError.notFound(id)
        }
        return job
    }

    public func acquireLease(jobID: String, owner: String, duration: TimeInterval = 60,
                             now: Date = Date()) throws -> JobLease {
        guard !owner.isEmpty, duration.isFinite, duration > 0 else { throw StoreError.invalidValue("A lease needs an owner and positive duration.") }
        return try database.transaction {
            _ = try recoverExpired(now: now)
            let current = try job(id: jobID)
            guard current.status != .outcomeUnknown else { throw StoreError.reconciliationRequired }
            guard current.status == .queued, current.nextRunAt.map({ $0 <= now }) ?? true else { throw StoreError.leaseUnavailable }
            let lease = JobLease(jobID: jobID, owner: owner, token: UUID().uuidString,
                                 expiresAt: now.addingTimeInterval(duration), cancellationGeneration: current.cancellationGeneration)
            try database.execute("""
            UPDATE jobs SET status=?,lease_owner=?,lease_token=?,lease_expires_at=?,attempts=attempts+1,updated_at=? WHERE id=?
            """, [.text(JobStatus.running.rawValue), .text(owner), .text(lease.token), .real(lease.expiresAt.timeIntervalSince1970),
                  .real(now.timeIntervalSince1970), .text(jobID)])
            return lease
        }
    }

    public func renewLease(_ lease: JobLease, duration: TimeInterval = 60, now: Date = Date()) throws -> JobLease {
        guard duration.isFinite, duration > 0 else { throw StoreError.invalidValue("Lease duration must be positive.") }
        return try database.transaction {
            try validate(lease, now: now)
            let expiresAt = now.addingTimeInterval(duration)
            try database.execute("UPDATE jobs SET lease_expires_at=?,updated_at=? WHERE id=?",
                                 [.real(expiresAt.timeIntervalSince1970), .real(now.timeIntervalSince1970), .text(lease.jobID)])
            return JobLease(jobID: lease.jobID, owner: lease.owner, token: lease.token,
                            expiresAt: expiresAt, cancellationGeneration: lease.cancellationGeneration)
        }
    }

    public func checkpointJob(_ lease: JobLease, checkpoint: Data?, progress: Double, now: Date = Date()) throws {
        guard progress.isFinite, (0...1).contains(progress) else { throw StoreError.invalidValue("Progress must be between zero and one.") }
        try database.transaction {
            try validate(lease, now: now)
            try database.execute("UPDATE jobs SET checkpoint=?,progress=?,updated_at=? WHERE id=?",
                                 [.optional(checkpoint), .real(progress), .real(now.timeIntervalSince1970), .text(lease.jobID)])
        }
    }

    /// Persist this receipt before dispatching an effect. Reusing an action ID is
    /// rejected, including after a crash; inspect/reconcile its receipt instead.
    @discardableResult
    public func startAction(_ lease: JobLease, id: String = UUID().uuidString, operation: String,
                            retryClass: RetryClass = .requiresReconciliation, idempotencyKey: String? = nil,
                            now: Date = Date()) throws -> ActionReceipt {
        guard !id.isEmpty, !operation.isEmpty else { throw StoreError.invalidValue("An action needs an ID and operation.") }
        return try database.transaction {
            try validate(lease, now: now)
            let existing = try database.query("SELECT id FROM action_receipts WHERE id=?", [.text(id)]) { SQLColumn.text($0, 0) }
            guard existing.isEmpty else { throw StoreError.reconciliationRequired }
            try database.execute("""
            INSERT INTO action_receipts(id,job_id,operation,retry_class,idempotency_key,status,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?)
            """, [.text(id), .text(lease.jobID), .text(operation), .text(retryClass.rawValue), .optional(idempotencyKey),
                  .text(ActionStatus.inFlight.rawValue), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
            return try receipt(id: id)
        }
    }

    public func completeAction(_ lease: JobLease, actionID: String, succeeded: Bool, result: Data? = nil,
                               now: Date = Date()) throws {
        try database.transaction {
            try validate(lease, now: now)
            let current = try receipt(id: actionID)
            guard current.jobID == lease.jobID, current.status == .inFlight else { throw StoreError.invalidValue("This action is not in flight for the leased job.") }
            try database.execute("UPDATE action_receipts SET status=?,result=?,updated_at=? WHERE id=?",
                                 [.text(succeeded ? ActionStatus.succeeded.rawValue : ActionStatus.failed.rawValue),
                                  .optional(result), .real(now.timeIntervalSince1970), .text(actionID)])
        }
    }

    public func actionReceipts(jobID: String) throws -> [ActionReceipt] {
        try database.query("SELECT * FROM action_receipts WHERE job_id=? ORDER BY created_at, id", [.text(jobID)], map: Self.receipt)
    }

    public func finishJob(_ lease: JobLease, succeeded: Bool, error: String? = nil, now: Date = Date()) throws {
        try database.transaction {
            try validate(lease, now: now)
            let unsettled = try actionReceipts(jobID: lease.jobID).contains { $0.status == .inFlight || $0.status == .outcomeUnknown }
            guard !unsettled else { throw StoreError.reconciliationRequired }
            try database.execute("""
            UPDATE jobs SET status=?,progress=CASE WHEN ?=1 THEN 1 ELSE progress END,last_error=?,
            lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,updated_at=? WHERE id=?
            """, [.text(succeeded ? JobStatus.succeeded.rawValue : JobStatus.failed.rawValue), .integer(succeeded ? 1 : 0),
                  .optional(error), .real(now.timeIntervalSince1970), .text(lease.jobID)])
        }
    }

    /// Records interruption without claiming that an externally dispatched effect
    /// failed. Non-idempotent in-flight actions remain unknown until observed.
    public func interruptJob(_ lease: JobLease, error: String, now: Date = Date()) throws {
        try database.transaction {
            try validate(lease, now: now)
            let actions = try actionReceipts(jobID: lease.jobID)
            var unknown = actions.contains { $0.status == .outcomeUnknown }
            for action in actions where action.status == .inFlight {
                let status: ActionStatus = action.retryClass == .idempotent ? .failed : .outcomeUnknown
                unknown = unknown || status == .outcomeUnknown
                try database.execute("UPDATE action_receipts SET status=?,updated_at=? WHERE id=?",
                                     [.text(status.rawValue), .real(now.timeIntervalSince1970), .text(action.id)])
            }
            try database.execute("""
            UPDATE jobs SET status=?,last_error=?,lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,updated_at=? WHERE id=?
            """, [.text(unknown ? JobStatus.outcomeUnknown.rawValue : JobStatus.failed.rawValue), .text(String(error.prefix(2_000))),
                  .real(now.timeIntervalSince1970), .text(lease.jobID)])
        }
    }

    public func deleteJob(id: String) throws {
        try database.transaction {
            let current = try job(id: id)
            guard current.status != .running else { throw StoreError.invalidValue("Cancel the running job before deleting it.") }
            try database.execute("DELETE FROM jobs WHERE id=?", [.text(id)])
        }
    }

    /// Consumers pass cancellationGeneration into their tool tasks and cancel
    /// those tasks immediately. The increment rejects all late checkpoints.
    public func cancelJob(id: String, now: Date = Date()) throws {
        try database.transaction {
            _ = try job(id: id)
            try database.execute("""
            UPDATE action_receipts SET status=?,updated_at=? WHERE job_id=? AND status=?
            """, [.text(ActionStatus.outcomeUnknown.rawValue), .real(now.timeIntervalSince1970), .text(id), .text(ActionStatus.inFlight.rawValue)])
            try database.execute("""
            UPDATE jobs SET status=?,cancellation_generation=cancellation_generation+1,
            lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,updated_at=? WHERE id=?
            """, [.text(JobStatus.cancelled.rawValue), .real(now.timeIntervalSince1970), .text(id)])
        }
    }

    /// Call at launch and before selecting a job. An unexpired lease belongs to
    /// another live process until proven otherwise and is never stolen.
    @discardableResult
    public func recoverInterruptedJobs(now: Date = Date()) throws -> [DurableJob] {
        try database.transaction { try recoverExpired(now: now) }
    }

    /// Reconciliation is an observation made by the caller, never an automatic
    /// assumption that an interrupted effect failed.
    public func reconcileAction(id: String, observedSucceeded: Bool, evidence: Data, now: Date = Date()) throws {
        guard !evidence.isEmpty else { throw StoreError.invalidValue("Reconciliation requires observation evidence.") }
        try database.transaction {
            let current = try receipt(id: id)
            guard current.status == .outcomeUnknown else { throw StoreError.invalidValue("Only an unknown action outcome can be reconciled.") }
            try database.execute("UPDATE action_receipts SET status=?,result=?,updated_at=? WHERE id=?",
                                 [.text(observedSucceeded ? ActionStatus.succeeded.rawValue : ActionStatus.failed.rawValue),
                                  .blob(evidence), .real(now.timeIntervalSince1970), .text(id)])
        }
    }

    public func retryJob(id: String, now: Date = Date()) throws {
        try database.transaction {
            let current = try job(id: id)
            guard current.status == .failed || current.status == .outcomeUnknown else { throw StoreError.invalidValue("Only interrupted or failed jobs can be resumed.") }
            guard !(try actionReceipts(jobID: id).contains { $0.status == .outcomeUnknown || $0.status == .inFlight }) else {
                throw StoreError.reconciliationRequired
            }
            guard current.retryClass != .never, current.attempts <= current.retryBudget else {
                throw StoreError.invalidValue("This job has no retry budget remaining.")
            }
            try database.execute("UPDATE jobs SET status=?,last_error=NULL,next_run_at=?,updated_at=? WHERE id=?",
                                 [.text(JobStatus.queued.rawValue), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970), .text(id)])
        }
    }

    public func saveRoutine(_ routine: Routine) throws {
        guard !routine.id.isEmpty, !routine.instruction.isEmpty, routine.interval.isFinite, routine.interval >= 1 else {
            throw StoreError.invalidValue("A routine needs an instruction and an interval of at least one second.")
        }
        try database.execute("""
        INSERT INTO routines(id,title,instruction,scope,interval_seconds,next_run_at,missed_run_policy,enabled,last_enqueued_at)
        VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,instruction=excluded.instruction,
        scope=excluded.scope,interval_seconds=excluded.interval_seconds,next_run_at=excluded.next_run_at,
        missed_run_policy=excluded.missed_run_policy,enabled=excluded.enabled,last_enqueued_at=excluded.last_enqueued_at
        """, [.text(routine.id), .text(routine.title), .text(routine.instruction), .text(routine.scope), .real(routine.interval),
              .real(routine.nextRunAt.timeIntervalSince1970), .text(routine.missedRunPolicy.rawValue), .integer(routine.enabled ? 1 : 0),
              .optional(routine.lastEnqueuedAt)])
    }

    public func routines() throws -> [Routine] {
        try database.query("SELECT * FROM routines ORDER BY next_run_at, id", map: Self.routine)
    }

    public func deleteRoutine(id: String) throws { try database.execute("DELETE FROM routines WHERE id=?", [.text(id)]) }

    /// Atomically advances a routine and enqueues at most one occurrence. Callers
    /// drive this while the app is running; missed intervals cannot flood jobs.
    @discardableResult
    public func enqueueDueRoutines(now: Date = Date()) throws -> [DurableJob] {
        try database.transaction {
            var enqueued: [DurableJob] = []
            for routine in try routines() where routine.enabled && routine.nextRunAt <= now {
                let delay = now.timeIntervalSince(routine.nextRunAt)
                let missed = delay >= routine.interval
                if !missed || routine.missedRunPolicy == .runOnce {
                    let occurrenceID = "routine:\(routine.id):\(routine.nextRunAt.timeIntervalSince1970)"
                    let existing = try database.query("SELECT id FROM jobs WHERE id=?", [.text(occurrenceID)]) { SQLColumn.text($0, 0) }
                    if existing.isEmpty {
                        enqueued.append(try enqueueJob(id: occurrenceID, instruction: routine.instruction, scope: routine.scope, now: now))
                    }
                }
                let intervals = floor(delay / routine.interval) + 1
                let next = routine.nextRunAt.addingTimeInterval(intervals * routine.interval)
                try database.execute("UPDATE routines SET next_run_at=?,last_enqueued_at=? WHERE id=?",
                                     [.real(next.timeIntervalSince1970), (!missed || routine.missedRunPolicy == .runOnce) ? .real(now.timeIntervalSince1970) : .optional(routine.lastEnqueuedAt), .text(routine.id)])
            }
            return enqueued
        }
    }

    private func validate(_ lease: JobLease, now: Date) throws {
        let valid = try database.query("""
        SELECT id FROM jobs WHERE id=? AND status=? AND lease_owner=? AND lease_token=?
        AND lease_expires_at>? AND cancellation_generation=?
        """, [.text(lease.jobID), .text(JobStatus.running.rawValue), .text(lease.owner), .text(lease.token),
              .real(now.timeIntervalSince1970), .integer(lease.cancellationGeneration)]) { SQLColumn.text($0, 0) }
        guard !valid.isEmpty else { throw StoreError.staleLease }
    }

    private func receipt(id: String) throws -> ActionReceipt {
        guard let value = try database.query("SELECT * FROM action_receipts WHERE id=?", [.text(id)], map: Self.receipt).first else {
            throw StoreError.notFound(id)
        }
        return value
    }

    private func recoverExpired(now: Date) throws -> [DurableJob] {
        let expired = try database.query("SELECT * FROM jobs WHERE status=? AND (lease_expires_at IS NULL OR lease_expires_at<=?)",
                                         [.text(JobStatus.running.rawValue), .real(now.timeIntervalSince1970)], map: Self.job)
        for job in expired {
            let actions = try actionReceipts(jobID: job.id)
            let unknown = actions.contains { ($0.status == .inFlight && $0.retryClass != .idempotent) || $0.status == .outcomeUnknown }
            for action in actions where action.status == .inFlight {
                try database.execute("UPDATE action_receipts SET status=?,updated_at=? WHERE id=?",
                                     [.text(action.retryClass == .idempotent ? ActionStatus.failed.rawValue : ActionStatus.outcomeUnknown.rawValue),
                                      .real(now.timeIntervalSince1970), .text(action.id)])
            }
            let canRetry = job.retryClass == .idempotent && job.attempts <= job.retryBudget
            let status: JobStatus = unknown ? .outcomeUnknown : (canRetry ? .queued : .failed)
            try database.execute("""
            UPDATE jobs SET status=?,lease_owner=NULL,lease_token=NULL,lease_expires_at=NULL,last_error=?,updated_at=? WHERE id=?
            """, [.text(status.rawValue), .text(unknown ? "Interrupted effect requires observation before retry." : "Execution was interrupted after its lease expired."),
                  .real(now.timeIntervalSince1970), .text(job.id)])
        }
        return try expired.map { try job(id: $0.id) }
    }

    private static func record(_ statement: OpaquePointer) -> StoredRecord {
        StoredRecord(id: SQLColumn.text(statement, 0), kind: SQLColumn.text(statement, 1), title: SQLColumn.text(statement, 2),
                     body: SQLColumn.text(statement, 3), payload: SQLColumn.data(statement, 4),
                     createdAt: SQLColumn.date(statement, 5), updatedAt: SQLColumn.date(statement, 6))
    }

    private static func job(_ statement: OpaquePointer) throws -> DurableJob {
        guard let status = JobStatus(rawValue: SQLColumn.text(statement, 4)), let retry = RetryClass(rawValue: SQLColumn.text(statement, 6)) else {
            throw StoreError.invalidValue("A job has an unsupported stored state.")
        }
        return DurableJob(id: SQLColumn.text(statement, 0), instruction: SQLColumn.text(statement, 1), scope: SQLColumn.text(statement, 2),
                          checkpoint: SQLColumn.data(statement, 3), status: status, progress: sqlite3_column_double(statement, 5), retryClass: retry,
                          retryBudget: Int(sqlite3_column_int64(statement, 7)), attempts: Int(sqlite3_column_int64(statement, 8)),
                          cancellationGeneration: Int(sqlite3_column_int64(statement, 9)), nextRunAt: SQLColumn.optionalDate(statement, 10),
                          lastError: SQLColumn.optionalText(statement, 14), createdAt: SQLColumn.date(statement, 15), updatedAt: SQLColumn.date(statement, 16))
    }

    private static func receipt(_ statement: OpaquePointer) throws -> ActionReceipt {
        guard let retry = RetryClass(rawValue: SQLColumn.text(statement, 3)), let status = ActionStatus(rawValue: SQLColumn.text(statement, 5)) else {
            throw StoreError.invalidValue("An action receipt has an unsupported stored state.")
        }
        return ActionReceipt(id: SQLColumn.text(statement, 0), jobID: SQLColumn.text(statement, 1), operation: SQLColumn.text(statement, 2),
                             retryClass: retry, idempotencyKey: SQLColumn.optionalText(statement, 4), status: status, result: SQLColumn.data(statement, 6),
                             createdAt: SQLColumn.date(statement, 7), updatedAt: SQLColumn.date(statement, 8))
    }

    private static func routine(_ statement: OpaquePointer) throws -> Routine {
        guard let policy = MissedRunPolicy(rawValue: SQLColumn.text(statement, 6)) else { throw StoreError.invalidValue("A routine has an unsupported missed-run policy.") }
        return Routine(id: SQLColumn.text(statement, 0), title: SQLColumn.text(statement, 1), instruction: SQLColumn.text(statement, 2),
                       scope: SQLColumn.text(statement, 3), interval: sqlite3_column_double(statement, 4), nextRunAt: SQLColumn.date(statement, 5),
                       missedRunPolicy: policy, enabled: sqlite3_column_int(statement, 7) != 0, lastEnqueuedAt: SQLColumn.optionalDate(statement, 8))
    }
}
