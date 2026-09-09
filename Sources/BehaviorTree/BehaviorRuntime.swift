private struct RuntimeNodeResult: Sendable {
  let outcome: BehaviorOutcome
  let diagnostic: BehaviorDiagnostic?
  let skipped: Bool

  static let succeeded = Self(outcome: .succeeded, diagnostic: nil, skipped: false)
  static let failed = Self(outcome: .failed, diagnostic: nil, skipped: false)
  static let skipped = Self(outcome: .succeeded, diagnostic: nil, skipped: true)
}

private enum RuntimeReactiveResult: Sendable {
  case completed(RuntimeNodeResult)
  case invalidated(UInt64)
}

extension BehaviorTree where Action: Sendable, Condition: Sendable {
  /// Runs this tree to a terminal outcome using an actor-compatible executor.
  public func run<Executor: BehaviorExecutor>(
    in context: Executor.Context,
    using executor: Executor,
    executionID: BehaviorExecutionID = .make(),
    clock: BehaviorClock = .continuous,
    observing observers: [BehaviorObserver] = []
  ) async throws -> BehaviorRunResult
  where Executor.Action == Action, Executor.Condition == Condition {
    try await runWithInvalidation(
      in: context,
      using: executor,
      executionID: executionID,
      clock: clock,
      observing: observers,
      invalidationSource: nil
    )
  }

  func runWithInvalidation<Executor: BehaviorExecutor>(
    in context: Executor.Context,
    using executor: Executor,
    executionID: BehaviorExecutionID,
    clock: BehaviorClock,
    observing observers: [BehaviorObserver],
    invalidationSource: BehaviorInvalidationSource?
  ) async throws -> BehaviorRunResult
  where Executor.Action == Action, Executor.Condition == Condition {
    guard
      !plan.nodes.contains(where: { node in
        switch node.operation {
        case .sequence(.reactive), .selector(.reactive): return true
        default: return false
        }
      }) || invalidationSource != nil
    else {
      throw BehaviorRuntimeError.reactiveExecutionRequiresWakeUpSource
    }

    let session =
      observers.isEmpty
      ? nil
      : BehaviorEventSession(
        definition: definition(),
        executionID: executionID,
        observers: observers
      )
    return try await BehaviorRuntimeInvalidation.$source.withValue(invalidationSource) {
      try await BehaviorRuntimeClock.$current.withValue(clock) {
        await session?.emit(.executionStarted)
        do {
          let result = try await execute(
            at: 0,
            in: context,
            using: executor,
            session: session
          )
          await session?.emit(
            .executionCompleted,
            outcome: result.outcome,
            diagnostic: result.diagnostic
          )
          return BehaviorRunResult(
            executionID: executionID,
            outcome: result.outcome,
            diagnostic: result.diagnostic
          )
        } catch is CancellationError {
          await session?.emit(.executionCancelled)
          throw CancellationError()
        } catch let error as BehaviorExecutionError {
          await session?.emit(.executionFailed, diagnostic: error.diagnostic)
          throw error
        } catch {
          await session?.emit(.executionFailed)
          throw error
        }
      }
    }
  }

  private func execute<Executor: BehaviorExecutor>(
    at index: Int,
    in context: Executor.Context,
    using executor: Executor,
    session: BehaviorEventSession?,
    honorCancellation: Bool = true
  ) async throws -> RuntimeNodeResult
  where Executor.Action == Action, Executor.Condition == Condition {
    if honorCancellation { try Task.checkCancellation() }
    let nodeID = plan.nodes[index].id
    await session?.emit(.nodeEntered, nodeID: nodeID)
    do {
      let result = try await executeBody(
        at: index,
        in: context,
        using: executor,
        session: session,
        honorCancellation: honorCancellation
      )
      await session?.emit(
        result.skipped
          ? .nodeSkipped
          : (result.outcome == .succeeded ? .nodeSucceeded : .nodeFailed),
        nodeID: nodeID,
        outcome: result.outcome,
        diagnostic: result.diagnostic
      )
      return result
    } catch is CancellationError {
      await session?.emit(.nodeCancelled, nodeID: nodeID)
      throw CancellationError()
    } catch let error as BehaviorExecutionError {
      if error.nodeID == nodeID {
        await session?.emit(
          .nodeFailed,
          nodeID: nodeID,
          outcome: .failed,
          diagnostic: error.diagnostic
        )
      }
      throw error
    } catch {
      let executionError = BehaviorExecutionError(nodeID: nodeID, underlyingError: error)
      await session?.emit(
        .nodeFailed,
        nodeID: nodeID,
        outcome: .failed,
        diagnostic: executionError.diagnostic
      )
      throw executionError
    }
  }

  private func executeBody<Executor: BehaviorExecutor>(
    at index: Int,
    in context: Executor.Context,
    using executor: Executor,
    session: BehaviorEventSession?,
    honorCancellation: Bool
  ) async throws -> RuntimeNodeResult
  where Executor.Action == Action, Executor.Condition == Condition {
    let node = plan.nodes[index]
    switch node.operation {
    case .action(let action):
      let reporter = BehaviorReporter(nodeID: node.id) { report in
        switch report {
        case .progress(let progress):
          await session?.emit(.nodeProgress, nodeID: node.id, progress: progress)
        case .inspection(let inspection):
          await session?.emit(
            .nodeInspected,
            nodeID: node.id,
            inspection: inspection
          )
        }
      }
      let result = try await executor.perform(action, in: context, reporting: reporter)
      guard let outcome = result.outcome else {
        throw BehaviorRuntimeError.runningActionRequiresHostDrivenExecution
      }
      return RuntimeNodeResult(
        outcome: outcome,
        diagnostic: result.diagnostic,
        skipped: false
      )

    case .condition(let condition):
      let result = try await executor.evaluate(condition, in: context)
      return RuntimeNodeResult(
        outcome: result.isSatisfied ? .succeeded : .failed,
        diagnostic: result.diagnostic,
        skipped: false
      )
    case .succeed:
      return .succeeded
    case .fail:
      return .failed
    case .wait(let duration):
      try await BehaviorRuntimeClock.current.sleep(for: duration.duration)
      return .succeeded
    case .waitForever:
      try await suspendUntilCancelled()

    case .subtree:
      return try await execute(
        at: node.children[0],
        in: context,
        using: executor,
        session: session,
        honorCancellation: honorCancellation
      )

    case .dynamicSubtrees:
      for child in node.children {
        let result = try await execute(
          at: child,
          in: context,
          using: executor,
          session: session,
          honorCancellation: honorCancellation
        )
        if result.skipped { continue }
        if result.outcome == .failed { return result }
      }
      return .succeeded

    case .sequence(let memory):
      if memory == .reactive {
        return try await executeReactiveComposite(
          children: node.children,
          selector: false,
          in: context,
          using: executor,
          session: session
        )
      }
      for child in node.children {
        let result = try await execute(
          at: child,
          in: context,
          using: executor,
          session: session,
          honorCancellation: honorCancellation
        )
        if result.skipped { continue }
        if result.outcome == .failed { return result }
      }
      return .succeeded

    case .selector(let memory):
      if memory == .reactive {
        return try await executeReactiveComposite(
          children: node.children,
          selector: true,
          in: context,
          using: executor,
          session: session
        )
      }
      var lastFailure = RuntimeNodeResult.failed
      var attempted = false
      for child in node.children {
        let result = try await execute(
          at: child,
          in: context,
          using: executor,
          session: session,
          honorCancellation: honorCancellation
        )
        if result.skipped { continue }
        attempted = true
        if result.outcome == .succeeded { return result }
        lastFailure = result
      }
      return attempted ? lastFailure : .skipped

    case .branch:
      let decision = try await execute(
        at: node.children[0],
        in: context,
        using: executor,
        session: session,
        honorCancellation: honorCancellation
      )
      return try await execute(
        at: node.children[decision.outcome == .succeeded ? 1 : 2],
        in: context,
        using: executor,
        session: session,
        honorCancellation: honorCancellation
      )

    case .parallel(let success, let failure):
      return try await executeParallel(
        node.children,
        success: success,
        failure: failure,
        in: context,
        using: executor,
        session: session
      )
    case .orderedSuccess:
      return try await executeOrderedSuccess(
        node.children,
        in: context,
        using: executor,
        session: session
      )
    case .loop(let checkEveryChild):
      while true {
        try Task.checkCancellation()
        var decision = try await execute(
          at: node.children[0],
          in: context,
          using: executor,
          session: session
        )
        if decision.outcome == .failed { return decision }
        for child in node.children.dropFirst() {
          if checkEveryChild, child != node.children[1] {
            decision = try await execute(
              at: node.children[0],
              in: context,
              using: executor,
              session: session
            )
            if decision.outcome == .failed { return decision }
          }
          let result = try await execute(
            at: child,
            in: context,
            using: executor,
            session: session
          )
          if result.outcome == .failed { return result }
        }
        await Task.yield()
      }
    case .retry(let attempts, let backoff):
      var lastResult = RuntimeNodeResult.failed
      for attempt in 1...attempts {
        try Task.checkCancellation()
        lastResult = try await execute(
          at: node.children[0],
          in: context,
          using: executor,
          session: session
        )
        if lastResult.outcome == .succeeded { return lastResult }
        if attempt < attempts {
          await session?.emit(
            .nodeRetrying,
            nodeID: node.id,
            attempt: attempt + 1,
            diagnostic: lastResult.diagnostic
          )
          if backoff.nanoseconds > 0 {
            try await BehaviorRuntimeClock.current.sleep(for: backoff.duration)
          } else {
            await Task.yield()
          }
        }
      }
      return lastResult
    case .repeatBehavior(let count):
      if count == 0 { return .succeeded }
      var completed = 0
      while true {
        if let count, completed >= count { return .succeeded }
        try Task.checkCancellation()
        let result = try await execute(
          at: node.children[0],
          in: context,
          using: executor,
          session: session
        )
        if result.outcome == .failed { return result }
        completed += 1
        await Task.yield()
      }
    case .untilFailure(let terminalOutcome):
      while true {
        try Task.checkCancellation()
        let result = try await execute(
          at: node.children[0],
          in: context,
          using: executor,
          session: session
        )
        if result.outcome == .failed {
          return RuntimeNodeResult(
            outcome: terminalOutcome == .succeeded ? .succeeded : .failed,
            diagnostic: result.diagnostic,
            skipped: false
          )
        }
        await Task.yield()
      }
    case .invert:
      let result = try await execute(
        at: node.children[0], in: context, using: executor, session: session
      )
      return RuntimeNodeResult(
        outcome: result.outcome == .succeeded ? .failed : .succeeded,
        diagnostic: result.diagnostic,
        skipped: result.skipped
      )
    case .forceSuccess:
      let result = try await execute(
        at: node.children[0], in: context, using: executor, session: session
      )
      return RuntimeNodeResult(
        outcome: .succeeded,
        diagnostic: result.diagnostic,
        skipped: result.skipped
      )
    case .forceFailure:
      let result = try await execute(
        at: node.children[0], in: context, using: executor, session: session
      )
      return RuntimeNodeResult(
        outcome: .failed,
        diagnostic: result.diagnostic,
        skipped: result.skipped
      )
    case .timeout(let duration):
      return try await executeTimeout(
        child: node.children[0],
        duration: duration,
        node: index,
        in: context,
        using: executor,
        session: session
      )
    case .precondition(let policy):
      let decision = try await execute(
        at: node.children[0],
        in: context,
        using: executor,
        session: session
      )
      guard decision.outcome == .succeeded else {
        switch policy {
        case .skip:
          return RuntimeNodeResult(
            outcome: .succeeded,
            diagnostic: decision.diagnostic,
            skipped: true
          )
        case .succeed:
          return RuntimeNodeResult(
            outcome: .succeeded,
            diagnostic: decision.diagnostic,
            skipped: false
          )
        case .fail:
          return decision
        }
      }
      return try await execute(
        at: node.children[1], in: context, using: executor, session: session
      )
    case .lifecycle:
      return try await executeLifecycle(
        at: index,
        in: context,
        using: executor,
        session: session
      )
    }
  }

  private func executeParallel<Executor: BehaviorExecutor>(
    _ children: [Int],
    success: ParallelSuccessPolicy,
    failure: ParallelFailurePolicy,
    in context: Executor.Context,
    using executor: Executor,
    session: BehaviorEventSession?
  ) async throws -> RuntimeNodeResult
  where Executor.Action == Action, Executor.Condition == Condition {
    try await withThrowingTaskGroup(of: RuntimeNodeResult.self) { group in
      for child in children {
        group.addTask {
          try await execute(
            at: child, in: context, using: executor, session: session
          )
        }
      }
      var successes = 0
      var failures = 0
      var skipped = 0
      var completed = 0
      var lastDiagnostic: BehaviorDiagnostic?
      while let result = try await group.next() {
        completed += 1
        lastDiagnostic = result.diagnostic
        if result.skipped {
          skipped += 1
        } else if result.outcome == .succeeded {
          successes += 1
        } else {
          failures += 1
        }
        let eligible = children.count - skipped
        let remaining = children.count - completed
        if eligible == 0, completed == children.count {
          return .skipped
        }
        let successThreshold = runtimeThreshold(success, eligibleCount: eligible)
        if successes >= successThreshold {
          group.cancelAll()
          return RuntimeNodeResult(
            outcome: .succeeded,
            diagnostic: result.diagnostic,
            skipped: false
          )
        }
        if runtimeFailureReached(
          failure,
          failures: failures,
          successes: successes,
          remaining: remaining,
          successThreshold: successThreshold,
          eligibleCount: eligible
        ) {
          group.cancelAll()
          return RuntimeNodeResult(
            outcome: .failed,
            diagnostic: result.diagnostic,
            skipped: false
          )
        }
      }
      return RuntimeNodeResult(
        outcome: failures > 0 ? .failed : .succeeded,
        diagnostic: lastDiagnostic,
        skipped: skipped == children.count
      )
    }
  }

  private func executeReactiveComposite<Executor: BehaviorExecutor>(
    children: [Int],
    selector: Bool,
    in context: Executor.Context,
    using executor: Executor,
    session: BehaviorEventSession?
  ) async throws -> RuntimeNodeResult
  where Executor.Action == Action, Executor.Condition == Condition {
    guard let invalidationSource = BehaviorRuntimeInvalidation.source else {
      throw BehaviorRuntimeError.reactiveExecutionRequiresWakeUpSource
    }
    var generation = await invalidationSource.currentGeneration()
    while true {
      let observedGeneration = generation
      let result = try await withThrowingTaskGroup(
        of: RuntimeReactiveResult.self,
        returning: RuntimeReactiveResult.self
      ) { group in
        group.addTask {
          if selector {
            var lastFailure = RuntimeNodeResult.failed
            var attempted = false
            for child in children {
              let result = try await execute(
                at: child,
                in: context,
                using: executor,
                session: session
              )
              if result.skipped { continue }
              attempted = true
              if result.outcome == .succeeded {
                return .completed(result)
              }
              lastFailure = result
            }
            return .completed(attempted ? lastFailure : .skipped)
          }
          for child in children {
            let result = try await execute(
              at: child,
              in: context,
              using: executor,
              session: session
            )
            if result.skipped { continue }
            if result.outcome == .failed { return .completed(result) }
          }
          return .completed(.succeeded)
        }
        group.addTask {
          .invalidated(
            try await invalidationSource.waitForInvalidation(
              after: observedGeneration
            )
          )
        }
        guard let first = try await group.next() else {
          preconditionFailure("A reactive composite must start evaluation and wake-up tasks")
        }
        group.cancelAll()
        return first
      }
      switch result {
      case .completed(let result):
        return result
      case .invalidated(let nextGeneration):
        generation = nextGeneration
        await Task.yield()
      }
    }
  }

  private func executeOrderedSuccess<Executor: BehaviorExecutor>(
    _ children: [Int],
    in context: Executor.Context,
    using executor: Executor,
    session: BehaviorEventSession?
  ) async throws -> RuntimeNodeResult
  where Executor.Action == Action, Executor.Condition == Condition {
    try await withThrowingTaskGroup(of: (Int, RuntimeNodeResult).self) { group in
      for (offset, child) in children.enumerated() {
        group.addTask {
          (
            offset,
            try await execute(
              at: child, in: context, using: executor, session: session
            )
          )
        }
      }
      var next = 0
      while let (offset, result) = try await group.next() {
        if result.skipped, offset == next {
          next += 1
          continue
        }
        guard result.outcome == .succeeded, offset == next else {
          group.cancelAll()
          return RuntimeNodeResult(
            outcome: .failed,
            diagnostic: result.diagnostic,
            skipped: false
          )
        }
        next += 1
      }
      return .succeeded
    }
  }

  private func executeTimeout<Executor: BehaviorExecutor>(
    child: Int,
    duration: BehaviorDuration,
    node index: Int,
    in context: Executor.Context,
    using executor: Executor,
    session: BehaviorEventSession?
  ) async throws -> RuntimeNodeResult
  where Executor.Action == Action, Executor.Condition == Condition {
    try await withThrowingTaskGroup(of: RuntimeNodeResult.self) { group in
      group.addTask {
        try await execute(
          at: child, in: context, using: executor, session: session
        )
      }
      group.addTask {
        try await BehaviorRuntimeClock.current.sleep(for: duration.duration)
        let diagnostic = BehaviorDiagnostic(code: "behavior.timeout")
        await session?.emit(
          .nodeTimedOut,
          nodeID: plan.nodes[index].id,
          diagnostic: diagnostic
        )
        return RuntimeNodeResult(
          outcome: .failed,
          diagnostic: diagnostic,
          skipped: false
        )
      }
      guard let first = try await group.next() else {
        preconditionFailure("A timeout must start child and clock tasks")
      }
      group.cancelAll()
      return first
    }
  }

  private func executeLifecycle<Executor: BehaviorExecutor>(
    at index: Int,
    in context: Executor.Context,
    using executor: Executor,
    session: BehaviorEventSession?
  ) async throws -> RuntimeNodeResult
  where Executor.Action == Action, Executor.Condition == Condition {
    let node = plan.nodes[index]
    guard let wrapped = child(of: node, role: .wrapped) else {
      preconditionFailure("A validated lifecycle node must have a wrapped child")
    }
    var didEnterExit = false
    do {
      let result = try await execute(
        at: wrapped, in: context, using: executor, session: session
      )
      let outcomeRole: BehaviorChildRole =
        result.outcome == .succeeded
        ? .onSuccess : .onFailure
      if let hook = child(of: node, role: outcomeRole) {
        let hookResult = try await execute(
          at: hook, in: context, using: executor, session: session
        )
        if hookResult.outcome == .failed { return hookResult }
      }
      if let exit = child(of: node, role: .onExit) {
        didEnterExit = true
        let exitResult = try await execute(
          at: exit, in: context, using: executor, session: session
        )
        if exitResult.outcome == .failed { return exitResult }
      }
      return result
    } catch is CancellationError {
      if let cancellation = child(of: node, role: .onCancel) {
        _ = try await execute(
          at: cancellation,
          in: context,
          using: executor,
          session: session,
          honorCancellation: false
        )
      }
      if !didEnterExit, let exit = child(of: node, role: .onExit) {
        _ = try await execute(
          at: exit,
          in: context,
          using: executor,
          session: session,
          honorCancellation: false
        )
      }
      throw CancellationError()
    } catch {
      if !didEnterExit, let exit = child(of: node, role: .onExit) {
        _ = try await execute(
          at: exit,
          in: context,
          using: executor,
          session: session,
          honorCancellation: false
        )
      }
      throw error
    }
  }

  private func child(
    of node: BehaviorPlanNode<Action, Condition>,
    role: BehaviorChildRole
  ) -> Int? {
    node.children.first { plan.nodes[$0].role == role }
  }
}

private func runtimeThreshold(
  _ policy: ParallelSuccessPolicy,
  eligibleCount: Int
) -> Int {
  switch policy {
  case .all: return eligibleCount
  case .any: return 1
  case .atLeast(let count): return count
  }
}

private func runtimeFailureReached(
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
