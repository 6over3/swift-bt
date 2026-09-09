/// The active stage of lifecycle-hook execution.
public enum BehaviorLifecycleStage: String, Codable, Hashable, Sendable {
  case child
  case outcomeHook
  case exitHook
}

/// Node-kind-specific cursor data for a host-driven execution.
public enum BehaviorNodeRuntimeState: Codable, Hashable, Sendable {
  case none
  case elapsed(nanoseconds: Int64)
  case cursor(Int)
  case branch(selectedChild: Int?)
  case loop(bodyCursor: Int, conditionPassed: Bool)
  case retry(
    failedAttempts: Int,
    backoffElapsedNanoseconds: Int64,
    isBackingOff: Bool
  )
  case repetition(completed: Int)
  case precondition(passed: Bool)
  case lifecycle(stage: BehaviorLifecycleStage, outcome: BehaviorOutcome?)
}

/// Serializable state for one node at a host-controlled checkpoint.
public struct BehaviorNodeSnapshot: Codable, Hashable, Sendable {
  public let status: BehaviorStatus
  public let activation: UInt64?
  public let runtimeState: BehaviorNodeRuntimeState
  public let inspection: BehaviorInspection?
  public let diagnostic: BehaviorDiagnostic?
  public let skipped: Bool

  /// Creates persisted state for one node path.
  public init(
    status: BehaviorStatus,
    activation: UInt64? = nil,
    runtimeState: BehaviorNodeRuntimeState = .none,
    inspection: BehaviorInspection? = nil,
    diagnostic: BehaviorDiagnostic? = nil,
    skipped: Bool = false
  ) {
    self.status = status
    self.activation = activation
    self.runtimeState = runtimeState
    self.inspection = inspection
    self.diagnostic = diagnostic
    self.skipped = skipped
  }
}

/// A data-only checkpoint for a host-driven execution.
public struct BehaviorExecutionSnapshot: Codable, Hashable, Sendable {
  public let treeName: String
  public let treeVersion: String
  public let executionID: BehaviorExecutionID
  public let definitionFingerprint: UInt64
  public let status: BehaviorStatus
  public let eventSequence: UInt64
  public let elapsedNanoseconds: Int64
  public let nodes: [BehaviorNodeID: BehaviorNodeSnapshot]

  /// Creates a persisted execution checkpoint.
  public init(
    treeName: String,
    treeVersion: String,
    executionID: BehaviorExecutionID,
    definitionFingerprint: UInt64,
    status: BehaviorStatus,
    eventSequence: UInt64,
    elapsedNanoseconds: Int64,
    nodes: [BehaviorNodeID: BehaviorNodeSnapshot]
  ) {
    self.treeName = treeName
    self.treeVersion = treeVersion
    self.executionID = executionID
    self.definitionFingerprint = definitionFingerprint
    self.status = status
    self.eventSequence = eventSequence
    self.elapsedNanoseconds = elapsedNanoseconds
    self.nodes = nodes
  }
}

/// An application-owned persistence boundary for host-driven execution.
///
/// The execution invokes this sink after each durable node transition. The
/// sink decides where and how snapshots are stored; the behavior-tree runtime
/// never owns application persistence.
public struct BehaviorCheckpointSink: Sendable {
  private let saveSnapshot: @Sendable (BehaviorExecutionSnapshot) async throws -> Void

  /// Creates a checkpoint sink from an asynchronous persistence operation.
  public init(
    _ saveSnapshot:
      @escaping @Sendable (BehaviorExecutionSnapshot) async throws -> Void
  ) {
    self.saveSnapshot = saveSnapshot
  }

  func save(_ snapshot: BehaviorExecutionSnapshot) async throws {
    try await saveSnapshot(snapshot)
  }
}
