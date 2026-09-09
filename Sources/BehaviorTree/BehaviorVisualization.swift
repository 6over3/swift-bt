import Synchronization

/// The display state of one node in a live behavior-tree execution.
public enum BehaviorVisualizationStatus: String, Codable, Hashable, Sendable {
  case idle
  case running
  case succeeded
  case failed
  case skipped
  case cancelled
}

/// The latest visualization data associated with one definition node.
public struct BehaviorNodeVisualizationState: Codable, Hashable, Sendable {
  public let status: BehaviorVisualizationStatus
  public let activation: UInt64?
  public let attempt: Int?
  public let progress: BehaviorProgress?
  public let inspection: BehaviorInspection?
  public let diagnostic: BehaviorDiagnostic?
  public let lastEventSequence: UInt64?

  /// Creates visualization state for one node.
  public init(
    status: BehaviorVisualizationStatus = .idle,
    activation: UInt64? = nil,
    attempt: Int? = nil,
    progress: BehaviorProgress? = nil,
    inspection: BehaviorInspection? = nil,
    diagnostic: BehaviorDiagnostic? = nil,
    lastEventSequence: UInt64? = nil
  ) {
    self.status = status
    self.activation = activation
    self.attempt = attempt
    self.progress = progress
    self.inspection = inspection
    self.diagnostic = diagnostic
    self.lastEventSequence = lastEventSequence
  }
}

/// A data-only projection of execution events onto a complete tree definition.
public struct BehaviorVisualizationSnapshot: Codable, Hashable, Sendable {
  public let treeName: String
  public let treeVersion: String
  public private(set) var executionID: BehaviorExecutionID?
  public private(set) var sequence: UInt64
  public private(set) var status: BehaviorStatus
  public private(set) var diagnostic: BehaviorDiagnostic?
  public private(set) var latestEvent: BehaviorEvent?
  public private(set) var nodes: [BehaviorNodeID: BehaviorNodeVisualizationState]

  /// Creates an idle snapshot containing every node in a definition.
  public init(definition: BehaviorTreeDefinition) {
    treeName = definition.name
    treeVersion = definition.version
    executionID = nil
    sequence = 0
    status = .idle
    diagnostic = nil
    latestEvent = nil
    nodes = visualizationNodeStates(in: definition.root)
  }

  /// Reconstructs display state from one durable host checkpoint.
  ///
  /// Checkpoints contain only nodes that have participated in the execution.
  /// Definition nodes absent from the checkpoint remain idle. This initializer
  /// makes restored and historical executions inspectable without replaying an
  /// event stream that the host was not required to persist.
  public init(
    definition: BehaviorTreeDefinition,
    execution: BehaviorExecutionSnapshot
  ) throws(BehaviorVisualizationError) {
    guard execution.treeName == definition.name,
      execution.treeVersion == definition.version
    else {
      throw .eventTreeMismatch(
        expectedName: definition.name,
        expectedVersion: definition.version,
        actualName: execution.treeName,
        actualVersion: execution.treeVersion
      )
    }

    var nodeStates = visualizationNodeStates(in: definition.root)
    for (nodeID, checkpoint) in execution.nodes {
      guard nodeStates[nodeID] != nil else {
        throw .unknownNode(nodeID)
      }
      nodeStates[nodeID] = BehaviorNodeVisualizationState(
        status: checkpoint.skipped
          ? .skipped
          : visualizationStatus(checkpoint.status),
        activation: checkpoint.activation,
        inspection: checkpoint.inspection,
        diagnostic: checkpoint.diagnostic
      )
    }

    treeName = definition.name
    treeVersion = definition.version
    executionID = execution.executionID
    sequence = execution.eventSequence
    status = execution.status
    diagnostic = nil
    latestEvent = nil
    nodes = nodeStates
  }

  init(
    definition: BehaviorTreeDefinition,
    executionID: BehaviorExecutionID,
    sequence: UInt64,
    status: BehaviorStatus,
    nodes: [BehaviorNodeID: BehaviorNodeVisualizationState]
  ) {
    treeName = definition.name
    treeVersion = definition.version
    self.executionID = executionID
    self.sequence = sequence
    self.status = status
    diagnostic = nil
    latestEvent = nil
    self.nodes = nodes
  }

  /// Applies the next ordered event and returns the updated snapshot.
  ///
  /// Sequence gaps are accepted so bounded telemetry streams may discard older
  /// events. Duplicate and out-of-order events are rejected.
  @discardableResult
  public mutating func apply(
    _ event: BehaviorEvent
  ) throws(BehaviorVisualizationError) -> Self {
    guard event.treeName == treeName, event.treeVersion == treeVersion else {
      throw .eventTreeMismatch(
        expectedName: treeName,
        expectedVersion: treeVersion,
        actualName: event.treeName,
        actualVersion: event.treeVersion
      )
    }
    if event.phase.isNodePhase, event.nodeID == nil {
      throw .missingNode(phase: event.phase)
    }
    if let nodeID = event.nodeID, nodes[nodeID] == nil {
      throw .unknownNode(nodeID)
    }

    if event.phase == .executionStarted,
      let executionID,
      executionID != event.executionID
    {
      resetExecution()
    }
    if let executionID, executionID != event.executionID {
      throw .executionMismatch(
        expected: executionID,
        actual: event.executionID
      )
    }
    guard event.sequence > sequence else {
      throw .outOfOrderEvent(
        lastSequence: sequence,
        receivedSequence: event.sequence
      )
    }
    if event.phase == .executionCompleted, event.outcome == nil {
      throw .missingOutcome(phase: event.phase)
    }
    if event.phase == .nodeInspected, event.inspection == nil {
      throw .missingInspection
    }

    executionID = event.executionID
    sequence = event.sequence
    latestEvent = event

    switch event.phase {
    case .executionStarted:
      status = .running
      diagnostic = nil
    case .executionCompleted:
      status = event.outcome == .succeeded ? .succeeded : .failed
      diagnostic = event.diagnostic
    case .executionFailed:
      status = .failed
      diagnostic = event.diagnostic
    case .executionCancelled:
      status = .cancelled
      diagnostic = event.diagnostic
    case .nodeEntered, .nodeRunning, .nodeSucceeded, .nodeFailed,
      .nodeSkipped, .nodeCancelled, .nodeProgress, .nodeInspected, .nodeRetrying,
      .nodeTimedOut, .nodeReset:
      if status == .idle { status = .running }
      applyNodeEvent(event)
    }
    return self
  }

  /// Clears execution state while retaining the complete definition topology.
  public mutating func reset() {
    resetExecution()
  }

  private mutating func applyNodeEvent(_ event: BehaviorEvent) {
    guard let nodeID = event.nodeID, let current = nodes[nodeID] else { return }
    let next: BehaviorNodeVisualizationState
    switch event.phase {
    case .nodeEntered:
      next = BehaviorNodeVisualizationState(
        status: .running,
        activation: event.activation,
        attempt: event.attempt,
        diagnostic: event.diagnostic,
        lastEventSequence: event.sequence
      )
    case .nodeRunning:
      next = BehaviorNodeVisualizationState(
        status: .running,
        activation: event.activation ?? current.activation,
        attempt: event.attempt ?? current.attempt,
        progress: current.progress,
        inspection: current.inspection,
        diagnostic: event.diagnostic ?? current.diagnostic,
        lastEventSequence: event.sequence
      )
    case .nodeSucceeded:
      next = terminalNodeState(.succeeded, event: event, current: current)
    case .nodeFailed, .nodeTimedOut:
      next = terminalNodeState(.failed, event: event, current: current)
    case .nodeSkipped:
      next = terminalNodeState(.skipped, event: event, current: current)
    case .nodeCancelled:
      next = terminalNodeState(.cancelled, event: event, current: current)
    case .nodeProgress:
      next = BehaviorNodeVisualizationState(
        status: current.status == .idle ? .running : current.status,
        activation: event.activation ?? current.activation,
        attempt: event.attempt ?? current.attempt,
        progress: event.progress,
        inspection: current.inspection,
        diagnostic: event.diagnostic ?? current.diagnostic,
        lastEventSequence: event.sequence
      )
    case .nodeInspected:
      next = BehaviorNodeVisualizationState(
        status: current.status == .idle ? .running : current.status,
        activation: event.activation ?? current.activation,
        attempt: event.attempt ?? current.attempt,
        progress: current.progress,
        inspection: event.inspection,
        diagnostic: current.diagnostic,
        lastEventSequence: event.sequence
      )
    case .nodeRetrying:
      next = BehaviorNodeVisualizationState(
        status: .running,
        activation: event.activation ?? current.activation,
        attempt: event.attempt,
        progress: nil,
        inspection: current.inspection,
        diagnostic: event.diagnostic,
        lastEventSequence: event.sequence
      )
    case .nodeReset:
      next = BehaviorNodeVisualizationState()
    case .executionStarted, .executionCompleted, .executionFailed,
      .executionCancelled:
      return
    }
    nodes[nodeID] = next
  }

  private func terminalNodeState(
    _ status: BehaviorVisualizationStatus,
    event: BehaviorEvent,
    current: BehaviorNodeVisualizationState
  ) -> BehaviorNodeVisualizationState {
    BehaviorNodeVisualizationState(
      status: status,
      activation: event.activation ?? current.activation,
      attempt: event.attempt ?? current.attempt,
      progress: current.progress,
      inspection: current.inspection,
      diagnostic: event.diagnostic ?? current.diagnostic,
      lastEventSequence: event.sequence
    )
  }

  private mutating func resetExecution() {
    executionID = nil
    sequence = 0
    status = .idle
    diagnostic = nil
    latestEvent = nil
    for nodeID in nodes.keys {
      nodes[nodeID] = BehaviorNodeVisualizationState()
    }
  }
}

private func visualizationStatus(
  _ status: BehaviorStatus
) -> BehaviorVisualizationStatus {
  switch status {
  case .idle: .idle
  case .running: .running
  case .succeeded: .succeeded
  case .failed: .failed
  case .cancelled: .cancelled
  }
}

/// An incompatible or unordered update to live visualization state.
public enum BehaviorVisualizationError: Error, Equatable, Sendable {
  case eventTreeMismatch(
    expectedName: String,
    expectedVersion: String,
    actualName: String,
    actualVersion: String
  )
  case definitionMismatch
  case executionMismatch(
    expected: BehaviorExecutionID,
    actual: BehaviorExecutionID
  )
  case outOfOrderEvent(lastSequence: UInt64, receivedSequence: UInt64)
  case unknownNode(BehaviorNodeID)
  case missingNode(phase: BehaviorEventPhase)
  case missingOutcome(phase: BehaviorEventPhase)
  case missingInspection
}

/// A concurrency-safe reducer and snapshot stream for a live tree definition.
public final class BehaviorVisualizationStore: Sendable {
  /// The static topology shared by every emitted snapshot.
  public let definition: BehaviorTreeDefinition

  /// Buffered snapshots emitted after each accepted event or explicit reset.
  public let snapshots: AsyncStream<BehaviorVisualizationSnapshot>

  private struct Storage: Sendable {
    var snapshot: BehaviorVisualizationSnapshot
    var lastError: BehaviorVisualizationError?
    var nextSubscriberID = 0
    var subscribers: [Int: AsyncStream<BehaviorVisualizationSnapshot>.Continuation] = [:]
  }

  private let storage: Mutex<Storage>
  private let continuation: AsyncStream<BehaviorVisualizationSnapshot>.Continuation

  /// Creates a live store and emits its initial idle snapshot.
  public init(
    definition: BehaviorTreeDefinition,
    snapshotBufferCapacity: Int = 1
  ) {
    precondition(snapshotBufferCapacity > 0, "Snapshot buffer capacity must be positive")
    self.definition = definition
    let initial = BehaviorVisualizationSnapshot(definition: definition)
    let (snapshots, continuation) = AsyncStream.makeStream(
      of: BehaviorVisualizationSnapshot.self,
      bufferingPolicy: .bufferingNewest(snapshotBufferCapacity)
    )
    self.snapshots = snapshots
    self.continuation = continuation
    storage = Mutex(Storage(snapshot: initial, lastError: nil))
    continuation.yield(initial)
  }

  deinit {
    continuation.finish()
    let subscribers = storage.withLock { storage in
      let subscribers = Array(storage.subscribers.values)
      storage.subscribers.removeAll()
      return subscribers
    }
    for subscriber in subscribers { subscriber.finish() }
  }

  /// An observer that reduces runtime events synchronously and in order.
  public var observer: BehaviorObserver {
    BehaviorObserver { [weak self] event in
      self?.receive(event)
    }
  }

  /// The most recently accepted visualization snapshot.
  public var snapshot: BehaviorVisualizationSnapshot {
    storage.withLock { $0.snapshot }
  }

  /// The latest event-reduction error received through `observer`, if any.
  public var lastError: BehaviorVisualizationError? {
    storage.withLock { $0.lastError }
  }

  /// Creates an independent snapshot stream for one additional consumer.
  ///
  /// Every subscriber receives the current snapshot immediately and then each
  /// accepted update. Slow subscribers retain only their newest buffered
  /// values and never block execution or other subscribers.
  public func makeSnapshotStream(
    bufferingNewest capacity: Int = 1
  ) -> AsyncStream<BehaviorVisualizationSnapshot> {
    precondition(capacity > 0, "Snapshot buffer capacity must be positive")
    let (stream, continuation) = AsyncStream.makeStream(
      of: BehaviorVisualizationSnapshot.self,
      bufferingPolicy: .bufferingNewest(capacity)
    )
    let registration = storage.withLock { storage in
      let subscriberID = storage.nextSubscriberID
      storage.nextSubscriberID += 1
      storage.subscribers[subscriberID] = continuation
      return (subscriberID, storage.snapshot)
    }
    let subscriberID = registration.0
    continuation.onTermination = { [weak self] _ in
      self?.removeSubscriber(subscriberID)
    }
    continuation.yield(registration.1)
    return stream
  }

  /// Reduces one event, emits the resulting snapshot, and returns it.
  @discardableResult
  public func record(
    _ event: BehaviorEvent
  ) throws(BehaviorVisualizationError) -> BehaviorVisualizationSnapshot {
    let publication = try storage.withLock {
      storage throws(BehaviorVisualizationError) in
      try storage.snapshot.apply(event)
      storage.lastError = nil
      return (storage.snapshot, Array(storage.subscribers.values))
    }
    continuation.yield(publication.0)
    for subscriber in publication.1 { subscriber.yield(publication.0) }
    return publication.0
  }

  /// Clears live state and emits a fresh idle snapshot.
  @discardableResult
  public func reset() -> BehaviorVisualizationSnapshot {
    let publication = storage.withLock { storage in
      storage.snapshot.reset()
      storage.lastError = nil
      return (storage.snapshot, Array(storage.subscribers.values))
    }
    continuation.yield(publication.0)
    for subscriber in publication.1 { subscriber.yield(publication.0) }
    return publication.0
  }

  /// Returns Graphviz DOT for the store's latest accepted snapshot.
  public func graphviz(
    theme: BehaviorGraphvizTheme = .default
  ) -> String {
    definition.graphvizUnchecked(highlighting: snapshot, theme: theme)
  }

  private func receive(_ event: BehaviorEvent) {
    do {
      try record(event)
    } catch {
      storage.withLock { $0.lastError = error }
    }
  }

  private func removeSubscriber(_ subscriberID: Int) {
    _ = storage.withLock { storage in
      storage.subscribers.removeValue(forKey: subscriberID)
    }
  }
}

private func visualizationNodeStates(
  in node: BehaviorDefinitionNode
) -> [BehaviorNodeID: BehaviorNodeVisualizationState] {
  var result = [node.id: BehaviorNodeVisualizationState()]
  for child in node.children {
    result.merge(visualizationNodeStates(in: child)) { current, _ in current }
  }
  return result
}

extension BehaviorEventPhase {
  fileprivate var isNodePhase: Bool {
    switch self {
    case .nodeEntered, .nodeRunning, .nodeSucceeded, .nodeFailed,
      .nodeSkipped, .nodeCancelled, .nodeProgress, .nodeInspected, .nodeRetrying,
      .nodeTimedOut, .nodeReset:
      true
    case .executionStarted, .executionCompleted, .executionFailed,
      .executionCancelled:
      false
    }
  }
}

extension BehaviorTree {
  /// Creates the live visualization bridge for the complete tree.
  ///
  /// The naming closures only supply stable, privacy-safe display labels for
  /// typed leaves. The returned store contains the entire tree definition and
  /// can be passed directly to `BehaviorTreeView` or another renderer.
  public func makeVisualization(
    actionLabel: (Action) -> String,
    conditionLabel: (Condition) -> String,
    snapshotBufferCapacity: Int = 1
  ) -> BehaviorVisualizationStore {
    BehaviorVisualizationStore(
      definition: definition(
        actionName: actionLabel,
        conditionName: conditionLabel
      ),
      snapshotBufferCapacity: snapshotBufferCapacity
    )
  }
}

extension BehaviorTree
where
  Action: RawRepresentable,
  Action.RawValue == String,
  Condition: RawRepresentable,
  Condition.RawValue == String
{
  /// Creates the live visualization bridge for a tree whose typed leaves use
  /// string raw values as their display labels.
  public func makeVisualization(
    snapshotBufferCapacity: Int = 1
  ) -> BehaviorVisualizationStore {
    makeVisualization(
      actionLabel: \.rawValue,
      conditionLabel: \.rawValue,
      snapshotBufferCapacity: snapshotBufferCapacity
    )
  }
}
