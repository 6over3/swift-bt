import Synchronization

private struct AdvanceResult {
  let status: BehaviorStatus
  let diagnostic: BehaviorDiagnostic?
  let skipped: Bool
  let remainingNanoseconds: Int64

  static func running() -> Self {
    Self(status: .running, diagnostic: nil, skipped: false, remainingNanoseconds: 0)
  }

  static func succeeded(
    remaining: Int64,
    diagnostic: BehaviorDiagnostic? = nil,
    skipped: Bool = false
  ) -> Self {
    Self(
      status: .succeeded,
      diagnostic: diagnostic,
      skipped: skipped,
      remainingNanoseconds: remaining
    )
  }

  static func failed(
    remaining: Int64,
    diagnostic: BehaviorDiagnostic? = nil
  ) -> Self {
    Self(
      status: .failed,
      diagnostic: diagnostic,
      skipped: false,
      remainingNanoseconds: remaining
    )
  }
}

private struct AdvanceNodeState {
  var status: BehaviorStatus = .idle
  var activation: UInt64
  var runtimeState: BehaviorNodeRuntimeState
  var diagnostic: BehaviorDiagnostic?
  var skipped = false

  init<Action, Condition>(
    operation: BehaviorPlanOperation<Action, Condition>,
    activation: UInt64
  ) {
    self.activation = activation
    switch operation {
    case .wait, .timeout:
      runtimeState = .elapsed(nanoseconds: 0)
    case .sequence, .selector, .orderedSuccess:
      runtimeState = .cursor(0)
    case .branch:
      runtimeState = .branch(selectedChild: nil)
    case .loop:
      runtimeState = .loop(bodyCursor: 0, conditionPassed: false)
    case .retry:
      runtimeState = .retry(
        failedAttempts: 0,
        backoffElapsedNanoseconds: 0,
        isBackingOff: false
      )
    case .repeatBehavior:
      runtimeState = .repetition(completed: 0)
    case .precondition:
      runtimeState = .precondition(passed: false)
    case .lifecycle:
      runtimeState = .lifecycle(stage: .child, outcome: nil)
    default:
      runtimeState = .none
    }
  }

  init(snapshot: BehaviorNodeSnapshot) {
    status = snapshot.status
    activation = snapshot.activation ?? 0
    runtimeState = snapshot.runtimeState
    diagnostic = snapshot.diagnostic
    skipped = snapshot.skipped
  }

  var snapshot: BehaviorNodeSnapshot {
    BehaviorNodeSnapshot(
      status: status,
      activation: activation,
      runtimeState: runtimeState,
      diagnostic: diagnostic,
      skipped: skipped
    )
  }

  var sequentialCursor: Int {
    get {
      guard case .cursor(let cursor) = runtimeState else {
        preconditionFailure("Sequential cursor used by an incompatible node")
      }
      return cursor
    }
    set {
      guard case .cursor = runtimeState else {
        preconditionFailure("Sequential cursor used by an incompatible node")
      }
      runtimeState = .cursor(newValue)
    }
  }

  var timedElapsedNanoseconds: Int64 {
    get {
      guard case .elapsed(let elapsed) = runtimeState else {
        preconditionFailure("Elapsed time used by an incompatible node")
      }
      return elapsed
    }
    set {
      guard case .elapsed = runtimeState else {
        preconditionFailure("Elapsed time used by an incompatible node")
      }
      runtimeState = .elapsed(nanoseconds: newValue)
    }
  }

  var selectedBranchChild: Int? {
    get {
      guard case .branch(let selectedChild) = runtimeState else {
        preconditionFailure("Branch selection used by an incompatible node")
      }
      return selectedChild
    }
    set {
      guard case .branch = runtimeState else {
        preconditionFailure("Branch selection used by an incompatible node")
      }
      runtimeState = .branch(selectedChild: newValue)
    }
  }

  var loopBodyCursor: Int {
    get {
      guard case .loop(let cursor, _) = runtimeState else {
        preconditionFailure("Loop cursor used by an incompatible node")
      }
      return cursor
    }
    set {
      guard case .loop(_, let passed) = runtimeState else {
        preconditionFailure("Loop cursor used by an incompatible node")
      }
      runtimeState = .loop(bodyCursor: newValue, conditionPassed: passed)
    }
  }

  var loopConditionPassed: Bool {
    get {
      guard case .loop(_, let passed) = runtimeState else {
        preconditionFailure("Loop condition state used by an incompatible node")
      }
      return passed
    }
    set {
      guard case .loop(let cursor, _) = runtimeState else {
        preconditionFailure("Loop condition state used by an incompatible node")
      }
      runtimeState = .loop(bodyCursor: cursor, conditionPassed: newValue)
    }
  }

  var failedRetryAttempts: Int {
    get {
      guard case .retry(let attempts, _, _) = runtimeState else {
        preconditionFailure("Retry attempts used by an incompatible node")
      }
      return attempts
    }
    set { updateRetry(failedAttempts: newValue) }
  }

  var retryBackoffElapsedNanoseconds: Int64 {
    get {
      guard case .retry(_, let elapsed, _) = runtimeState else {
        preconditionFailure("Retry backoff used by an incompatible node")
      }
      return elapsed
    }
    set { updateRetry(backoffElapsedNanoseconds: newValue) }
  }

  var isRetryBackingOff: Bool {
    get {
      guard case .retry(_, _, let backingOff) = runtimeState else {
        preconditionFailure("Retry phase used by an incompatible node")
      }
      return backingOff
    }
    set { updateRetry(isBackingOff: newValue) }
  }

  var completedRepetitions: Int {
    get {
      guard case .repetition(let completed) = runtimeState else {
        preconditionFailure("Repetition count used by an incompatible node")
      }
      return completed
    }
    set {
      guard case .repetition = runtimeState else {
        preconditionFailure("Repetition count used by an incompatible node")
      }
      runtimeState = .repetition(completed: newValue)
    }
  }

  var preconditionPassed: Bool {
    get {
      guard case .precondition(let passed) = runtimeState else {
        preconditionFailure("Precondition state used by an incompatible node")
      }
      return passed
    }
    set {
      guard case .precondition = runtimeState else {
        preconditionFailure("Precondition state used by an incompatible node")
      }
      runtimeState = .precondition(passed: newValue)
    }
  }

  var lifecycleStage: BehaviorLifecycleStage {
    get {
      guard case .lifecycle(let stage, _) = runtimeState else {
        preconditionFailure("Lifecycle stage used by an incompatible node")
      }
      return stage
    }
    set {
      guard case .lifecycle(_, let outcome) = runtimeState else {
        preconditionFailure("Lifecycle stage used by an incompatible node")
      }
      runtimeState = .lifecycle(stage: newValue, outcome: outcome)
    }
  }

  var lifecycleOutcome: BehaviorOutcome? {
    get {
      guard case .lifecycle(_, let outcome) = runtimeState else {
        preconditionFailure("Lifecycle outcome used by an incompatible node")
      }
      return outcome
    }
    set {
      guard case .lifecycle(let stage, _) = runtimeState else {
        preconditionFailure("Lifecycle outcome used by an incompatible node")
      }
      runtimeState = .lifecycle(stage: stage, outcome: newValue)
    }
  }

  private mutating func updateRetry(
    failedAttempts: Int? = nil,
    backoffElapsedNanoseconds: Int64? = nil,
    isBackingOff: Bool? = nil
  ) {
    guard
      case .retry(let currentAttempts, let currentElapsed, let currentBackingOff) =
        runtimeState
    else {
      preconditionFailure("Retry state used by an incompatible node")
    }
    runtimeState = .retry(
      failedAttempts: failedAttempts ?? currentAttempts,
      backoffElapsedNanoseconds: backoffElapsedNanoseconds ?? currentElapsed,
      isBackingOff: isBackingOff ?? currentBackingOff
    )
  }
}

/// Mutable cursor state for a tree advanced by an application-owned loop.
public struct BehaviorExecution<Action: Sendable, Condition: Sendable> {
  private let tree: BehaviorTree<Action, Condition>
  private let observers: [BehaviorObserver]
  private var states: [AdvanceNodeState?]
  private var activationCounts: [UInt64]
  private var eventSequence: UInt64
  private var elapsedNanoseconds: Int64
  private var didStart: Bool

  /// The stable identity shared by snapshots and telemetry.
  public let executionID: BehaviorExecutionID

  /// The execution's current root lifecycle state.
  public private(set) var status: BehaviorStatus

  fileprivate init(
    tree: BehaviorTree<Action, Condition>,
    executionID: BehaviorExecutionID,
    observers: [BehaviorObserver],
    snapshot: BehaviorExecutionSnapshot? = nil
  ) {
    self.tree = tree
    self.executionID = executionID
    self.observers = observers
    states = Array(repeating: nil, count: tree.plan.nodes.count)
    activationCounts = Array(repeating: 0, count: tree.plan.nodes.count)
    if let snapshot {
      let indexByID = Dictionary(
        uniqueKeysWithValues: tree.plan.nodes.enumerated().map { ($0.element.id, $0.offset) }
      )
      for (id, nodeSnapshot) in snapshot.nodes {
        if let index = indexByID[id] {
          states[index] = AdvanceNodeState(snapshot: nodeSnapshot)
          activationCounts[index] = nodeSnapshot.activation ?? 0
        }
      }
    }
    eventSequence = snapshot?.eventSequence ?? 0
    elapsedNanoseconds = snapshot?.elapsedNanoseconds ?? 0
    status = snapshot?.status ?? .idle
    didStart = snapshot.map { $0.status != .idle } ?? false
  }

  /// Advances the tree once using elapsed time supplied by the host.
  ///
  /// The host may call this from a display loop, a simulation, an event
  /// callback, or only after application work makes forward progress.
  @discardableResult
  public mutating func advance<Executor: BehaviorExecutor>(
    in context: Executor.Context,
    using executor: Executor,
    elapsed: Duration = .zero
  ) async throws -> BehaviorStatus
  where Executor.Action == Action, Executor.Condition == Condition {
    let delta = BehaviorDuration(elapsed).nanoseconds
    guard delta >= 0 else { throw BehaviorAdvanceError.negativeElapsed }
    if status == .succeeded || status == .failed || status == .cancelled {
      return status
    }
    elapsedNanoseconds = saturatingAdd(elapsedNanoseconds, delta)
    if !didStart {
      didStart = true
      status = .running
      emit(.executionStarted)
    }
    do {
      let result = try await stepNode(
        at: 0,
        in: context,
        using: executor,
        elapsedNanoseconds: delta
      )
      status = result.status
      if let outcome = status.outcome {
        emit(.executionCompleted, outcome: outcome, diagnostic: result.diagnostic)
      }
      return status
    } catch {
      emit(.executionFailed)
      throw error
    }
  }

  /// Cancels active nodes, runs lifecycle hooks, and marks the execution terminal.
  public mutating func cancel<Executor: BehaviorExecutor>(
    in context: Executor.Context,
    using executor: Executor
  ) async throws where Executor.Action == Action, Executor.Condition == Condition {
    guard status == .idle || status == .running else { return }
    try await cancelSubtree(at: 0, in: context, using: executor)
    status = .cancelled
    emit(.executionCancelled)
  }

  /// Clears all cursors so the same immutable definition can run again.
  public mutating func reset() {
    for index in states.indices where states[index] != nil {
      emit(.nodeReset, nodeIndex: index)
    }
    states = Array(repeating: nil, count: tree.plan.nodes.count)
    activationCounts = Array(repeating: 0, count: tree.plan.nodes.count)
    status = .idle
    elapsedNanoseconds = 0
    didStart = false
  }

  /// Captures data-only cursor state at the current host boundary.
  public func snapshot() -> BehaviorExecutionSnapshot {
    var nodes: [BehaviorNodeID: BehaviorNodeSnapshot] = [:]
    for (index, state) in states.enumerated() {
      if let state { nodes[tree.plan.nodes[index].id] = state.snapshot }
    }
    return BehaviorExecutionSnapshot(
      treeName: tree.name,
      treeVersion: tree.version,
      executionID: executionID,
      definitionFingerprint: tree.plan.fingerprint,
      status: status,
      eventSequence: eventSequence,
      elapsedNanoseconds: elapsedNanoseconds,
      nodes: nodes
    )
  }

  private mutating func stepNode<Executor: BehaviorExecutor>(
    at index: Int,
    in context: Executor.Context,
    using executor: Executor,
    elapsedNanoseconds: Int64
  ) async throws -> AdvanceResult
  where Executor.Action == Action, Executor.Condition == Condition {
    if let state = states[index], state.status == .succeeded || state.status == .failed {
      return AdvanceResult(
        status: state.status,
        diagnostic: state.diagnostic,
        skipped: state.skipped,
        remainingNanoseconds: elapsedNanoseconds
      )
    }
    if states[index] == nil {
      activationCounts[index] &+= 1
      states[index] = AdvanceNodeState(
        operation: tree.plan.nodes[index].operation,
        activation: activationCounts[index]
      )
    }
    if states[index]!.status == .idle {
      states[index]!.status = .running
      emit(.nodeEntered, nodeIndex: index)
    }

    let result: AdvanceResult
    do {
      result = try await stepBody(
        at: index,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
    } catch let error as BehaviorExecutionError {
      throw error
    } catch {
      throw BehaviorExecutionError(
        nodeID: tree.plan.nodes[index].id,
        underlyingError: error
      )
    }

    if result.status == .running {
      emit(.nodeRunning, nodeIndex: index, diagnostic: result.diagnostic)
    } else {
      states[index]!.status = result.status
      states[index]!.diagnostic = result.diagnostic
      states[index]!.skipped = result.skipped
      emit(
        result.skipped
          ? .nodeSkipped
          : (result.status == .succeeded ? .nodeSucceeded : .nodeFailed),
        nodeIndex: index,
        outcome: result.status.outcome,
        diagnostic: result.diagnostic
      )
    }
    return result
  }

  private mutating func stepBody<Executor: BehaviorExecutor>(
    at index: Int,
    in context: Executor.Context,
    using executor: Executor,
    elapsedNanoseconds: Int64
  ) async throws -> AdvanceResult
  where Executor.Action == Action, Executor.Condition == Condition {
    let node = tree.plan.nodes[index]
    switch node.operation {
    case .action(let action):
      let progressSequence = Mutex(eventSequence)
      let description = definitionDescription(
        of: node.operation,
        actionName: { _ in "Action" },
        conditionName: { _ in "Condition" }
      )
      let attributes = node.metadata.attributes.merging(description.attributes) {
        declared, _ in declared
      }
      let treeName = tree.name
      let treeVersion = tree.version
      let executionID = executionID
      let activation = states[index]?.activation
      let parentID = node.parent.map { tree.plan.nodes[$0].id }
      let observers = observers
      let elapsedNanoseconds = elapsedNanoseconds
      let reporter = BehaviorReporter { report in
        let sequence = progressSequence.withLock { sequence in
          sequence &+= 1
          return sequence
        }
        let phase: BehaviorEventPhase
        let progress: BehaviorProgress?
        let inspection: BehaviorInspection?
        switch report {
        case .progress(let value):
          phase = .nodeProgress
          progress = value
          inspection = nil
        case .inspection(let value):
          phase = .nodeInspected
          progress = nil
          inspection = value
        }
        let event = BehaviorEvent(
          treeName: treeName,
          treeVersion: treeVersion,
          executionID: executionID,
          sequence: sequence,
          nodeID: node.id,
          activation: activation,
          parentID: parentID,
          childRole: node.role,
          nodeKind: description.kind,
          label: node.metadata.label ?? description.fallbackLabel,
          attributes: attributes,
          phase: phase,
          progress: progress,
          inspection: inspection,
          elapsedNanoseconds: elapsedNanoseconds
        )
        for observer in observers { observer.receive(event) }
      }
      let result: BehaviorActionResult
      do {
        result = try await executor.perform(
          action,
          in: context,
          reporting: reporter
        )
      } catch {
        eventSequence = progressSequence.withLock { $0 }
        throw error
      }
      eventSequence = progressSequence.withLock { $0 }
      return AdvanceResult(
        status: result.outcome == .succeeded ? .succeeded : .failed,
        diagnostic: result.diagnostic,
        skipped: false,
        remainingNanoseconds: elapsedNanoseconds
      )

    case .condition(let condition):
      let result = try await executor.evaluate(condition, in: context)
      return result.isSatisfied
        ? .succeeded(remaining: elapsedNanoseconds, diagnostic: result.diagnostic)
        : .failed(remaining: elapsedNanoseconds, diagnostic: result.diagnostic)

    case .succeed:
      return .succeeded(remaining: elapsedNanoseconds)
    case .fail:
      return .failed(remaining: elapsedNanoseconds)
    case .wait(let duration):
      let needed = max(
        0,
        duration.nanoseconds - states[index]!.timedElapsedNanoseconds
      )
      let consumed = min(needed, elapsedNanoseconds)
      states[index]!.timedElapsedNanoseconds = saturatingAdd(
        states[index]!.timedElapsedNanoseconds,
        consumed
      )
      return states[index]!.timedElapsedNanoseconds >= duration.nanoseconds
        ? .succeeded(remaining: elapsedNanoseconds - consumed)
        : .running()
    case .waitForever:
      return .running()

    case .subtree:
      return try await stepWrappedChild(
        at: index,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )

    case .sequence(let memory):
      return try await stepSequence(
        at: index,
        memory: memory,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
    case .selector(let memory):
      return try await stepSelector(
        at: index,
        memory: memory,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
    case .branch:
      if states[index]!.selectedBranchChild == nil {
        let decision = try await stepNode(
          at: node.children[0],
          in: context,
          using: executor,
          elapsedNanoseconds: elapsedNanoseconds
        )
        guard decision.status != .running else { return .running() }
        let selectedChild = decision.status == .succeeded ? 1 : 2
        states[index]!.selectedBranchChild = selectedChild
        return try await stepNode(
          at: node.children[selectedChild],
          in: context,
          using: executor,
          elapsedNanoseconds: decision.remainingNanoseconds
        )
      }
      guard let selectedChild = states[index]!.selectedBranchChild else {
        preconditionFailure("A resumed branch must retain its selected child")
      }
      return try await stepNode(
        at: node.children[selectedChild],
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )

    case .parallel(let success, let failure):
      return try await stepParallel(
        at: index,
        success: success,
        failure: failure,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
    case .orderedSuccess:
      return try await stepOrderedSuccess(
        at: index,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
    case .loop(let everyChild):
      return try await stepLoop(
        at: index,
        checkBeforeEveryChild: everyChild,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
    case .retry(let attempts, let backoff):
      return try await stepRetry(
        at: index,
        maximumAttempts: attempts,
        backoff: backoff,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
    case .repeatBehavior(let count):
      if count == 0 { return .succeeded(remaining: elapsedNanoseconds) }
      let result = try await stepNode(
        at: node.children[0],
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
      guard result.status != .running else { return result }
      guard result.status == .succeeded else { return result }
      states[index]!.completedRepetitions += 1
      if let count, states[index]!.completedRepetitions >= count { return result }
      resetSubtree(at: node.children[0])
      return .running()

    case .untilFailure(let outcome):
      let result = try await stepNode(
        at: node.children[0],
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
      if result.status == .running { return result }
      if result.status == .failed {
        return outcome == .succeeded
          ? .succeeded(remaining: result.remainingNanoseconds, diagnostic: result.diagnostic)
          : result
      }
      resetSubtree(at: node.children[0])
      return .running()

    case .invert:
      let result = try await stepWrappedChild(
        at: index,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
      guard let outcome = result.status.outcome else { return result }
      return outcome == .succeeded
        ? .failed(remaining: result.remainingNanoseconds, diagnostic: result.diagnostic)
        : .succeeded(remaining: result.remainingNanoseconds, diagnostic: result.diagnostic)
    case .forceSuccess:
      let result = try await stepWrappedChild(
        at: index,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
      guard result.status.outcome != nil else { return result }
      return .succeeded(
        remaining: result.remainingNanoseconds,
        diagnostic: result.diagnostic,
        skipped: result.skipped
      )
    case .forceFailure:
      let result = try await stepWrappedChild(
        at: index,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
      guard result.status.outcome != nil else { return result }
      return .failed(remaining: result.remainingNanoseconds, diagnostic: result.diagnostic)
    case .timeout(let duration):
      let deadlineRemaining = max(
        0,
        duration.nanoseconds - states[index]!.timedElapsedNanoseconds
      )
      let childBudget = min(elapsedNanoseconds, deadlineRemaining)
      let result = try await stepWrappedChild(
        at: index,
        in: context,
        using: executor,
        elapsedNanoseconds: childBudget
      )
      if result.status.outcome != nil {
        return AdvanceResult(
          status: result.status,
          diagnostic: result.diagnostic,
          skipped: result.skipped,
          remainingNanoseconds: result.remainingNanoseconds
            + (elapsedNanoseconds - childBudget)
        )
      }
      states[index]!.timedElapsedNanoseconds = saturatingAdd(
        states[index]!.timedElapsedNanoseconds,
        childBudget
      )
      guard states[index]!.timedElapsedNanoseconds >= duration.nanoseconds else {
        return .running()
      }
      try await cancelSubtree(at: node.children[0], in: context, using: executor)
      let diagnostic = BehaviorDiagnostic(code: "behavior.timeout")
      emit(.nodeTimedOut, nodeIndex: index, diagnostic: diagnostic)
      return .failed(
        remaining: elapsedNanoseconds - childBudget,
        diagnostic: diagnostic
      )
    case .precondition(let policy):
      if !states[index]!.preconditionPassed {
        let result = try await stepNode(
          at: node.children[0],
          in: context,
          using: executor,
          elapsedNanoseconds: elapsedNanoseconds
        )
        guard result.status != .running else { return result }
        if result.status == .failed {
          switch policy {
          case .skip:
            return .succeeded(
              remaining: result.remainingNanoseconds,
              diagnostic: result.diagnostic,
              skipped: true
            )
          case .succeed:
            return .succeeded(
              remaining: result.remainingNanoseconds,
              diagnostic: result.diagnostic
            )
          case .fail:
            return result
          }
        }
        states[index]!.preconditionPassed = true
        return try await stepNode(
          at: node.children[1],
          in: context,
          using: executor,
          elapsedNanoseconds: result.remainingNanoseconds
        )
      }
      return try await stepNode(
        at: node.children[1],
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
    case .lifecycle:
      return try await stepLifecycle(
        at: index,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
    }
  }

  private mutating func stepSequence<Executor: BehaviorExecutor>(
    at index: Int,
    memory: BehaviorMemoryPolicy,
    in context: Executor.Context,
    using executor: Executor,
    elapsedNanoseconds: Int64
  ) async throws -> AdvanceResult
  where Executor.Action == Action, Executor.Condition == Condition {
    let children = tree.plan.nodes[index].children
    let previous = states[index]!.sequentialCursor
    var childOffset = memory == .reactive ? 0 : previous
    var remaining = elapsedNanoseconds
    while childOffset < children.count {
      let child = children[childOffset]
      if memory == .reactive, childOffset < previous { resetSubtree(at: child) }
      let result = try await stepNode(
        at: child,
        in: context,
        using: executor,
        elapsedNanoseconds: remaining
      )
      remaining = result.remainingNanoseconds
      if result.skipped || result.status == .succeeded {
        childOffset += 1
        states[index]!.sequentialCursor = childOffset
        continue
      }
      if memory == .reactive, childOffset != previous, previous < children.count {
        try await cancelSubtree(at: children[previous], in: context, using: executor)
      }
      states[index]!.sequentialCursor = childOffset
      return result
    }
    return .succeeded(remaining: remaining)
  }

  private mutating func stepSelector<Executor: BehaviorExecutor>(
    at index: Int,
    memory: BehaviorMemoryPolicy,
    in context: Executor.Context,
    using executor: Executor,
    elapsedNanoseconds: Int64
  ) async throws -> AdvanceResult
  where Executor.Action == Action, Executor.Condition == Condition {
    let children = tree.plan.nodes[index].children
    let previous = states[index]!.sequentialCursor
    var childOffset = memory == .reactive ? 0 : previous
    var remaining = elapsedNanoseconds
    var lastFailure = AdvanceResult.failed(remaining: remaining)
    var attempted = false
    while childOffset < children.count {
      let child = children[childOffset]
      if memory == .reactive, childOffset < previous { resetSubtree(at: child) }
      let result = try await stepNode(
        at: child,
        in: context,
        using: executor,
        elapsedNanoseconds: remaining
      )
      remaining = result.remainingNanoseconds
      if result.skipped {
        childOffset += 1
        continue
      }
      attempted = true
      if result.status == .failed {
        lastFailure = result
        childOffset += 1
        states[index]!.sequentialCursor = childOffset
        continue
      }
      if memory == .reactive, childOffset != previous, previous < children.count {
        try await cancelSubtree(at: children[previous], in: context, using: executor)
      }
      states[index]!.sequentialCursor = childOffset
      return result
    }
    return attempted
      ? lastFailure
      : .succeeded(remaining: remaining, skipped: true)
  }

  private mutating func stepParallel<Executor: BehaviorExecutor>(
    at index: Int,
    success: ParallelSuccessPolicy,
    failure: ParallelFailurePolicy,
    in context: Executor.Context,
    using executor: Executor,
    elapsedNanoseconds: Int64
  ) async throws -> AdvanceResult
  where Executor.Action == Action, Executor.Condition == Condition {
    let children = tree.plan.nodes[index].children
    var successes = 0
    var failures = 0
    var skipped = 0
    var minimumRemaining = elapsedNanoseconds
    var decisiveDiagnostic: BehaviorDiagnostic?
    for child in children {
      let result = try await stepNode(
        at: child,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
      minimumRemaining = min(minimumRemaining, result.remainingNanoseconds)
      if result.skipped {
        skipped += 1
      } else if result.status == .succeeded {
        successes += 1
        decisiveDiagnostic = result.diagnostic
      } else if result.status == .failed {
        failures += 1
        decisiveDiagnostic = result.diagnostic
      }
    }
    let eligible = children.count - skipped
    if eligible == 0 {
      return .succeeded(remaining: minimumRemaining, skipped: true)
    }
    let successCount = advanceThreshold(success, eligibleCount: eligible)
    let remainingChildren = eligible - successes - failures
    let outcome: BehaviorOutcome?
    if successes >= successCount {
      outcome = .succeeded
    } else if advanceFailureReached(
      failure,
      failures: failures,
      successes: successes,
      remaining: remainingChildren,
      successThreshold: successCount,
      eligibleCount: eligible
    ) {
      outcome = .failed
    } else {
      outcome = nil
    }
    guard let outcome else { return .running() }
    for child in children where states[child]?.status == .running {
      try await cancelSubtree(at: child, in: context, using: executor)
    }
    return outcome == .succeeded
      ? .succeeded(remaining: minimumRemaining, diagnostic: decisiveDiagnostic)
      : .failed(remaining: minimumRemaining, diagnostic: decisiveDiagnostic)
  }

  private mutating func stepOrderedSuccess<Executor: BehaviorExecutor>(
    at index: Int,
    in context: Executor.Context,
    using executor: Executor,
    elapsedNanoseconds: Int64
  ) async throws -> AdvanceResult
  where Executor.Action == Action, Executor.Condition == Condition {
    let children = tree.plan.nodes[index].children
    var minimumRemaining = elapsedNanoseconds
    for (offset, child) in children.enumerated()
    where states[child]?.status.outcome == nil {
      let result = try await stepNode(
        at: child,
        in: context,
        using: executor,
        elapsedNanoseconds: elapsedNanoseconds
      )
      minimumRemaining = min(minimumRemaining, result.remainingNanoseconds)
      if result.skipped {
        if offset == states[index]!.sequentialCursor {
          states[index]!.sequentialCursor += 1
        }
      } else if result.status == .failed
        || (result.status == .succeeded && offset != states[index]!.sequentialCursor)
      {
        for other in children where other != child {
          try await cancelSubtree(at: other, in: context, using: executor)
        }
        return .failed(remaining: minimumRemaining, diagnostic: result.diagnostic)
      } else if result.status == .succeeded {
        states[index]!.sequentialCursor += 1
      }
    }
    return states[index]!.sequentialCursor == children.count
      ? .succeeded(remaining: minimumRemaining)
      : .running()
  }

  private mutating func stepLoop<Executor: BehaviorExecutor>(
    at index: Int,
    checkBeforeEveryChild: Bool,
    in context: Executor.Context,
    using executor: Executor,
    elapsedNanoseconds: Int64
  ) async throws -> AdvanceResult
  where Executor.Action == Action, Executor.Condition == Condition {
    let children = tree.plan.nodes[index].children
    var remaining = elapsedNanoseconds
    if !states[index]!.loopConditionPassed || checkBeforeEveryChild {
      resetSubtree(at: children[0])
      let decision = try await stepNode(
        at: children[0],
        in: context,
        using: executor,
        elapsedNanoseconds: remaining
      )
      remaining = decision.remainingNanoseconds
      guard decision.status == .succeeded else { return decision }
      states[index]!.loopConditionPassed = true
    }
    let bodyOffset = states[index]!.loopBodyCursor
    let child = children[bodyOffset + 1]
    let result = try await stepNode(
      at: child,
      in: context,
      using: executor,
      elapsedNanoseconds: remaining
    )
    guard result.status == .succeeded || result.skipped else { return result }
    states[index]!.loopBodyCursor += 1
    if states[index]!.loopBodyCursor == children.count - 1 {
      for child in children.dropFirst() { resetSubtree(at: child) }
      states[index]!.loopBodyCursor = 0
      states[index]!.loopConditionPassed = false
    }
    return .running()
  }

  private mutating func stepRetry<Executor: BehaviorExecutor>(
    at index: Int,
    maximumAttempts: Int,
    backoff: BehaviorDuration,
    in context: Executor.Context,
    using executor: Executor,
    elapsedNanoseconds: Int64
  ) async throws -> AdvanceResult
  where Executor.Action == Action, Executor.Condition == Condition {
    let child = tree.plan.nodes[index].children[0]
    var remaining = elapsedNanoseconds
    while true {
      if states[index]!.isRetryBackingOff {
        let needed = max(
          0,
          backoff.nanoseconds - states[index]!.retryBackoffElapsedNanoseconds
        )
        let consumed = min(needed, remaining)
        states[index]!.retryBackoffElapsedNanoseconds += consumed
        remaining -= consumed
        guard states[index]!.retryBackoffElapsedNanoseconds >= backoff.nanoseconds else {
          return .running()
        }
        states[index]!.isRetryBackingOff = false
        states[index]!.retryBackoffElapsedNanoseconds = 0
      }
      let result = try await stepNode(
        at: child,
        in: context,
        using: executor,
        elapsedNanoseconds: remaining
      )
      remaining = result.remainingNanoseconds
      if result.status == .running || result.status == .succeeded { return result }
      states[index]!.failedRetryAttempts += 1
      guard states[index]!.failedRetryAttempts < maximumAttempts else { return result }
      emit(
        .nodeRetrying,
        nodeIndex: index,
        attempt: states[index]!.failedRetryAttempts + 1,
        diagnostic: result.diagnostic
      )
      resetSubtree(at: child)
      if backoff.nanoseconds > 0 {
        states[index]!.isRetryBackingOff = true
        states[index]!.retryBackoffElapsedNanoseconds = 0
      }
    }
  }

  private mutating func stepWrappedChild<Executor: BehaviorExecutor>(
    at index: Int,
    in context: Executor.Context,
    using executor: Executor,
    elapsedNanoseconds: Int64
  ) async throws -> AdvanceResult
  where Executor.Action == Action, Executor.Condition == Condition {
    try await stepNode(
      at: tree.plan.nodes[index].children[0],
      in: context,
      using: executor,
      elapsedNanoseconds: elapsedNanoseconds
    )
  }

  private mutating func stepLifecycle<Executor: BehaviorExecutor>(
    at index: Int,
    in context: Executor.Context,
    using executor: Executor,
    elapsedNanoseconds: Int64
  ) async throws -> AdvanceResult
  where Executor.Action == Action, Executor.Condition == Condition {
    let node = tree.plan.nodes[index]
    var remaining = elapsedNanoseconds
    if states[index]!.lifecycleStage == .child {
      guard let child = child(of: node, role: .wrapped) else {
        preconditionFailure("A validated lifecycle node must have a wrapped child")
      }
      let result = try await stepNode(
        at: child,
        in: context,
        using: executor,
        elapsedNanoseconds: remaining
      )
      remaining = result.remainingNanoseconds
      guard let outcome = result.status.outcome else { return result }
      states[index]!.lifecycleOutcome = outcome
      states[index]!.diagnostic = result.diagnostic
      states[index]!.lifecycleStage = .outcomeHook
    }
    if states[index]!.lifecycleStage == .outcomeHook {
      let role: BehaviorChildRole =
        states[index]!.lifecycleOutcome == .succeeded
        ? .onSuccess : .onFailure
      if let hook = child(of: node, role: role) {
        let result = try await stepNode(
          at: hook,
          in: context,
          using: executor,
          elapsedNanoseconds: remaining
        )
        remaining = result.remainingNanoseconds
        if result.status == .running || result.status == .failed { return result }
      }
      states[index]!.lifecycleStage = .exitHook
    }
    if let exit = child(of: node, role: .onExit) {
      let result = try await stepNode(
        at: exit,
        in: context,
        using: executor,
        elapsedNanoseconds: remaining
      )
      remaining = result.remainingNanoseconds
      if result.status == .running || result.status == .failed { return result }
    }
    return states[index]!.lifecycleOutcome == .succeeded
      ? .succeeded(remaining: remaining, diagnostic: states[index]!.diagnostic)
      : .failed(remaining: remaining, diagnostic: states[index]!.diagnostic)
  }

  private mutating func cancelSubtree<Executor: BehaviorExecutor>(
    at index: Int,
    in context: Executor.Context,
    using executor: Executor
  ) async throws where Executor.Action == Action, Executor.Condition == Condition {
    guard states[index]?.status == .running else { return }
    let node = tree.plan.nodes[index]
    if case .lifecycle = node.operation {
      for child in node.children where states[child]?.status == .running {
        try await cancelSubtree(at: child, in: context, using: executor)
      }
      if let hook = child(of: node, role: .onCancel) {
        let result = try await stepNode(
          at: hook,
          in: context,
          using: executor,
          elapsedNanoseconds: 0
        )
        guard result.status != .running else {
          throw BehaviorAdvanceError.cancellationHookDidNotComplete(
            nodeID: tree.plan.nodes[hook].id
          )
        }
        guard result.status == .succeeded else {
          throw BehaviorAdvanceError.cancellationHookFailed(
            nodeID: tree.plan.nodes[hook].id
          )
        }
      }
      if let exit = child(of: node, role: .onExit) {
        let result = try await stepNode(
          at: exit,
          in: context,
          using: executor,
          elapsedNanoseconds: 0
        )
        guard result.status != .running else {
          throw BehaviorAdvanceError.cancellationHookDidNotComplete(
            nodeID: tree.plan.nodes[exit].id
          )
        }
        guard result.status == .succeeded else {
          throw BehaviorAdvanceError.cancellationHookFailed(
            nodeID: tree.plan.nodes[exit].id
          )
        }
      }
      states[index]!.status = .cancelled
      emit(.nodeCancelled, nodeIndex: index)
      return
    }
    for child in node.children {
      try await cancelSubtree(at: child, in: context, using: executor)
    }
    states[index]!.status = .cancelled
    emit(.nodeCancelled, nodeIndex: index)
  }

  private mutating func resetSubtree(at index: Int) {
    states[index] = nil
    for child in tree.plan.nodes[index].children { resetSubtree(at: child) }
  }

  private mutating func emit(
    _ phase: BehaviorEventPhase,
    nodeIndex: Int? = nil,
    attempt: Int? = nil,
    outcome: BehaviorOutcome? = nil,
    diagnostic: BehaviorDiagnostic? = nil
  ) {
    guard !observers.isEmpty else { return }
    eventSequence &+= 1
    let node = nodeIndex.map { tree.plan.nodes[$0] }
    let description = node.map {
      definitionDescription(
        of: $0.operation,
        actionName: { _ in "Action" },
        conditionName: { _ in "Condition" }
      )
    }
    let event = BehaviorEvent(
      treeName: tree.name,
      treeVersion: tree.version,
      executionID: executionID,
      sequence: eventSequence,
      nodeID: node?.id,
      activation: nodeIndex.flatMap { states[$0]?.activation },
      attempt: attempt,
      parentID: node?.parent.map { tree.plan.nodes[$0].id },
      childRole: node?.role,
      nodeKind: description?.kind,
      label: node?.metadata.label ?? description?.fallbackLabel,
      attributes: node?.metadata.attributes.merging(description?.attributes ?? [:]) {
        declared, _ in declared
      } ?? [:],
      phase: phase,
      outcome: outcome,
      diagnostic: diagnostic,
      elapsedNanoseconds: elapsedNanoseconds
    )
    for observer in observers { observer.receive(event) }
  }
}

extension BehaviorTree where Action: Sendable, Condition: Sendable {
  /// Creates fresh host-driven cursor state for this immutable tree.
  public func makeExecution(
    executionID: BehaviorExecutionID = .make(),
    observing observers: [BehaviorObserver] = []
  ) -> BehaviorExecution<Action, Condition> {
    BehaviorExecution(tree: self, executionID: executionID, observers: observers)
  }

  /// Restores compatible host-driven cursor state.
  public func makeExecution(
    restoring snapshot: BehaviorExecutionSnapshot,
    observing observers: [BehaviorObserver] = []
  ) throws -> BehaviorExecution<Action, Condition> {
    guard snapshot.treeName == name, snapshot.treeVersion == version else {
      throw BehaviorAdvanceError.snapshotTreeMismatch(
        expectedName: name,
        expectedVersion: version,
        actualName: snapshot.treeName,
        actualVersion: snapshot.treeVersion
      )
    }
    guard snapshot.definitionFingerprint == plan.fingerprint else {
      throw BehaviorAdvanceError.invalidSnapshot
    }
    guard snapshot.elapsedNanoseconds >= 0 else {
      throw BehaviorAdvanceError.invalidSnapshot
    }
    let knownIDs = Set(plan.nodes.map(\.id))
    guard Set(snapshot.nodes.keys).isSubset(of: knownIDs) else {
      throw BehaviorAdvanceError.invalidSnapshot
    }
    for (id, state) in snapshot.nodes {
      guard let index = plan.nodes.firstIndex(where: { $0.id == id }),
        snapshotStateIsValid(state, for: plan.nodes[index])
      else {
        throw BehaviorAdvanceError.invalidSnapshot
      }
    }
    switch snapshot.status {
    case .idle:
      guard snapshot.nodes.isEmpty, snapshot.elapsedNanoseconds == 0 else {
        throw BehaviorAdvanceError.invalidSnapshot
      }
    case .running, .succeeded, .failed, .cancelled:
      guard let root = snapshot.nodes[.root], root.status == snapshot.status else {
        throw BehaviorAdvanceError.invalidSnapshot
      }
    }
    return BehaviorExecution(
      tree: self,
      executionID: snapshot.executionID,
      observers: observers,
      snapshot: snapshot
    )
  }
}

private func snapshotStateIsValid<Action, Condition>(
  _ state: BehaviorNodeSnapshot,
  for node: BehaviorPlanNode<Action, Condition>
) -> Bool {
  guard state.status != .idle, state.activation.map({ $0 > 0 }) ?? true else {
    return false
  }
  switch (node.operation, state.runtimeState) {
  case (.wait(let duration), .elapsed(let elapsed)):
    return elapsed >= 0 && elapsed <= duration.nanoseconds

  case (.timeout(let duration), .elapsed(let elapsed)):
    return elapsed >= 0 && elapsed <= duration.nanoseconds

  case (.sequence, .cursor(let cursor)),
    (.selector, .cursor(let cursor)),
    (.orderedSuccess, .cursor(let cursor)):
    return cursor >= 0 && cursor <= node.children.count

  case (.branch, .branch(let selectedChild)):
    guard let selectedChild else { return true }
    return selectedChild == 1 || selectedChild == 2

  case (.loop, .loop(let bodyCursor, _)):
    let bodyCount = node.children.count - 1
    return bodyCursor >= 0 && bodyCursor < bodyCount

  case (
    .retry(let maximumAttempts, let backoff),
    .retry(let failedAttempts, let elapsed, let isBackingOff)
  ):
    guard failedAttempts >= 0, failedAttempts <= maximumAttempts,
      elapsed >= 0, elapsed <= backoff.nanoseconds
    else { return false }
    return isBackingOff ? backoff.nanoseconds > 0 : elapsed == 0

  case (.repeatBehavior(let count), .repetition(let completed)):
    guard completed >= 0 else { return false }
    return count.map { completed <= $0 } ?? true

  case (.precondition, .precondition):
    return true

  case (.lifecycle, .lifecycle(let stage, let outcome)):
    switch stage {
    case .child:
      return outcome == nil
    case .outcomeHook, .exitHook:
      return outcome != nil
    }

  case (.action, .none), (.condition, .none), (.succeed, .none),
    (.fail, .none), (.waitForever, .none), (.parallel, .none),
    (.untilFailure, .none), (.invert, .none), (.forceSuccess, .none),
    (.forceFailure, .none), (.subtree, .none):
    return true

  default:
    return false
  }
}

extension BehaviorExecution {
  fileprivate func child(
    of node: BehaviorPlanNode<Action, Condition>,
    role: BehaviorChildRole
  ) -> Int? {
    node.children.first { tree.plan.nodes[$0].role == role }
  }
}

private func advanceThreshold(
  _ policy: ParallelSuccessPolicy,
  eligibleCount: Int
) -> Int {
  switch policy {
  case .all: return eligibleCount
  case .any: return 1
  case .atLeast(let count): return count
  }
}

private func advanceFailureReached(
  _ policy: ParallelFailurePolicy,
  failures: Int,
  successes: Int,
  remaining: Int,
  successThreshold: Int,
  eligibleCount: Int
) -> Bool {
  switch policy {
  case .any: return failures >= 1
  case .all: return failures >= eligibleCount
  case .atLeast(let count): return failures >= count
  case .whenSuccessBecomesImpossible:
    return successes + remaining < successThreshold
  }
}

private func definitionKind<Action, Condition>(
  of operation: BehaviorPlanOperation<Action, Condition>
) -> BehaviorNodeKind {
  switch operation {
  case .action: return .action
  case .condition: return .condition
  case .succeed: return .succeed
  case .fail: return .fail
  case .wait: return .wait
  case .waitForever: return .waitForever
  case .subtree: return .subtree
  case .sequence: return .sequence
  case .selector: return .selector
  case .branch: return .branch
  case .parallel: return .parallel
  case .orderedSuccess: return .orderedSuccess
  case .loop: return .loop
  case .retry: return .retry
  case .repeatBehavior: return .repeatBehavior
  case .untilFailure: return .untilFailure
  case .invert: return .inverter
  case .forceSuccess: return .forceSuccess
  case .forceFailure: return .forceFailure
  case .timeout: return .timeout
  case .precondition: return .precondition
  case .lifecycle: return .lifecycle
  }
}

private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
  let result = lhs.addingReportingOverflow(rhs)
  return result.overflow ? .max : result.partialValue
}
