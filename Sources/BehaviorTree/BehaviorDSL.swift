/// Builds an ordered collection of behavior nodes.
@resultBuilder
public enum BehaviorBuilder<Action, Condition> {
  /// Lowers an action component while the surrounding builder supplies its
  /// condition type.
  public static func buildExpression(
    _ expression: ActionComponent<Action>
  ) -> [Behavior<Action, Condition>] {
    [.action(expression.metadata, expression.value)]
  }

  /// Lowers a condition component while the surrounding builder supplies its
  /// action type.
  public static func buildExpression(
    _ expression: ConditionComponent<Condition>
  ) -> [Behavior<Action, Condition>] {
    [.condition(expression.metadata, expression.value)]
  }

  /// Lowers a domain-independent leaf into the surrounding typed tree.
  public static func buildExpression(
    _ expression: BuiltinLeafComponent
  ) -> [Behavior<Action, Condition>] {
    switch expression.storage {
    case .succeed:
      [.succeed(expression.metadata)]
    case .fail:
      [.fail(expression.metadata)]
    case .wait(let duration):
      [.wait(expression.metadata, duration)]
    case .waitForever:
      [.waitForever(expression.metadata)]
    }
  }

  /// Lowers lifecycle hooks attached directly to an action component.
  public static func buildExpression(
    _ expression: ActionLifecycleComponent<Action>
  ) -> [Behavior<Action, Condition>] {
    [
      .lifecycle(
        BehaviorNodeMetadata(label: expression.label),
        child: .action(expression.action.metadata, expression.action.value),
        onSuccess: expression.success.map {
          .action(BehaviorNodeMetadata(), $0)
        },
        onFailure: expression.failure.map {
          .action(BehaviorNodeMetadata(), $0)
        },
        onCancel: expression.cancellation.map {
          .action(BehaviorNodeMetadata(), $0)
        },
        onExit: expression.exit.map {
          .action(BehaviorNodeMetadata(), $0)
        }
      )
    ]
  }

  public static func buildExpression(
    _ expression: Behavior<Action, Condition>
  ) -> [Behavior<Action, Condition>] {
    [expression]
  }

  public static func buildBlock(
    _ components: [Behavior<Action, Condition>]...
  ) -> [Behavior<Action, Condition>] {
    components.flatMap { $0 }
  }

  public static func buildOptional(
    _ component: [Behavior<Action, Condition>]?
  ) -> [Behavior<Action, Condition>] {
    component ?? []
  }

  public static func buildEither(
    first component: [Behavior<Action, Condition>]
  ) -> [Behavior<Action, Condition>] {
    component
  }

  public static func buildEither(
    second component: [Behavior<Action, Condition>]
  ) -> [Behavior<Action, Condition>] {
    component
  }

  public static func buildArray(
    _ components: [[Behavior<Action, Condition>]]
  ) -> [Behavior<Action, Condition>] {
    components.flatMap { $0 }
  }
}

/// Builds exactly one behavior node for a unary decorator or branch.
///
/// Multiple expressions intentionally fail to type-check; callers make
/// sequencing explicit with ``Sequence``.
@resultBuilder
public enum SingleBehaviorBuilder<Action, Condition> {
  public static func buildExpression(
    _ expression: Behavior<Action, Condition>
  ) -> Behavior<Action, Condition> {
    expression
  }

  public static func buildExpression(
    _ expression: ActionComponent<Action>
  ) -> Behavior<Action, Condition> {
    .action(expression.metadata, expression.value)
  }

  public static func buildExpression(
    _ expression: ConditionComponent<Condition>
  ) -> Behavior<Action, Condition> {
    .condition(expression.metadata, expression.value)
  }

  public static func buildExpression(
    _ expression: BuiltinLeafComponent
  ) -> Behavior<Action, Condition> {
    switch expression.storage {
    case .succeed: .succeed(expression.metadata)
    case .fail: .fail(expression.metadata)
    case .wait(let duration): .wait(expression.metadata, duration)
    case .waitForever: .waitForever(expression.metadata)
    }
  }

  public static func buildExpression(
    _ expression: ActionLifecycleComponent<Action>
  ) -> Behavior<Action, Condition> {
    .lifecycle(
      BehaviorNodeMetadata(label: expression.label),
      child: .action(expression.action.metadata, expression.action.value),
      onSuccess: expression.success.map { .action(BehaviorNodeMetadata(), $0) },
      onFailure: expression.failure.map { .action(BehaviorNodeMetadata(), $0) },
      onCancel: expression.cancellation.map { .action(BehaviorNodeMetadata(), $0) },
      onExit: expression.exit.map { .action(BehaviorNodeMetadata(), $0) }
    )
  }

  public static func buildBlock(
    _ component: Behavior<Action, Condition>
  ) -> Behavior<Action, Condition> {
    component
  }

  public static func buildEither(
    first component: Behavior<Action, Condition>
  ) -> Behavior<Action, Condition> {
    component
  }

  public static func buildEither(
    second component: Behavior<Action, Condition>
  ) -> Behavior<Action, Condition> {
    component
  }
}

/// A partially typed action expression used by ``BehaviorBuilder``.
///
/// This value carries only the domain action type, so it can be extracted and
/// reused without inventing or annotating an unrelated condition type.
public struct ActionComponent<Value> {
  let value: Value
  let metadata: BehaviorNodeMetadata

  init(value: Value, metadata: BehaviorNodeMetadata) {
    self.value = value
    self.metadata = metadata
  }

  /// Adds typed action hooks to this leaf.
  public func onLifecycle(
    success: Value? = nil,
    failure: Value? = nil,
    cancel: Value? = nil,
    exit: Value? = nil,
    named label: String? = nil
  ) -> ActionLifecycleComponent<Value> {
    ActionLifecycleComponent(
      action: self,
      success: success,
      failure: failure,
      cancellation: cancel,
      exit: exit,
      label: label
    )
  }
}

extension ActionComponent: Sendable where Value: Sendable {}

/// An action leaf together with optional typed lifecycle hooks.
public struct ActionLifecycleComponent<Value> {
  let action: ActionComponent<Value>
  let success: Value?
  let failure: Value?
  let cancellation: Value?
  let exit: Value?
  let label: String?
}

extension ActionLifecycleComponent: Sendable where Value: Sendable {}

/// A partially typed condition expression used by ``BehaviorBuilder``.
public struct ConditionComponent<Value> {
  let value: Value
  let metadata: BehaviorNodeMetadata

  init(value: Value, metadata: BehaviorNodeMetadata) {
    self.value = value
    self.metadata = metadata
  }
}

extension ConditionComponent: Sendable where Value: Sendable {}

/// A domain-independent leaf expression used by ``BehaviorBuilder``.
public struct BuiltinLeafComponent: Sendable {
  enum Storage: Sendable {
    case succeed
    case fail
    case wait(BehaviorDuration)
    case waitForever
  }

  let storage: Storage
  let metadata: BehaviorNodeMetadata
}

/// Creates an action leaf component.
public func Action<Value>(
  _ action: Value,
  named label: String? = nil,
  attributes: [String: BehaviorMetadataValue] = [:]
) -> ActionComponent<Value> {
  ActionComponent(
    value: action,
    metadata: BehaviorNodeMetadata(label: label, attributes: attributes)
  )
}

/// Creates a condition leaf component.
public func Condition<Value>(
  _ condition: Value,
  named label: String? = nil,
  attributes: [String: BehaviorMetadataValue] = [:]
) -> ConditionComponent<Value> {
  ConditionComponent(
    value: condition,
    metadata: BehaviorNodeMetadata(label: label, attributes: attributes)
  )
}

/// Creates a leaf that always succeeds.
public func Succeed(
  _ label: String? = nil
) -> BuiltinLeafComponent {
  BuiltinLeafComponent(
    storage: .succeed,
    metadata: BehaviorNodeMetadata(label: label)
  )
}

/// Creates a leaf that always fails.
public func Fail(
  _ label: String? = nil
) -> BuiltinLeafComponent {
  BuiltinLeafComponent(
    storage: .fail,
    metadata: BehaviorNodeMetadata(label: label)
  )
}

/// Creates a finite wait leaf.
public func Wait(
  for duration: Duration,
  named label: String? = nil
) -> BuiltinLeafComponent {
  BuiltinLeafComponent(
    storage: .wait(BehaviorDuration(duration)),
    metadata: BehaviorNodeMetadata(label: label)
  )
}

/// Creates a leaf that remains active until cancellation.
public func WaitForever(
  _ label: String? = nil
) -> BuiltinLeafComponent {
  BuiltinLeafComponent(
    storage: .waitForever,
    metadata: BehaviorNodeMetadata(label: label)
  )
}

/// Embeds a reusable tree while preserving a named boundary in definitions,
/// telemetry, snapshots, and visualizations.
///
/// The embedded tree uses the same action and condition types as its parent.
/// Each embedding receives parent-scoped node identifiers and independent
/// runtime state.
public func Subtree<Action, Condition>(
  _ tree: BehaviorTree<Action, Condition>,
  named label: String? = nil,
  attributes: [String: BehaviorMetadataValue] = [:]
) -> Behavior<Action, Condition> {
  .subtree(
    BehaviorNodeMetadata(label: label, attributes: attributes),
    name: tree.name,
    version: tree.version,
    child: tree.root
  )
}

/// Declares runtime-discovered child executions using one immutable template.
///
/// Discovery freezes the exact child inputs. Start creates their independent
/// executions. Completion observes those executions until all are terminal.
/// Each phase is an explicit node in definitions, snapshots, and telemetry.
public func DynamicSubtrees<Action, Condition>(
  using template: BehaviorTreeReference,
  discover discovery: Action,
  start: Action,
  await completion: Action,
  named label: String? = nil,
  attributes: [String: BehaviorMetadataValue] = [:]
) -> Behavior<Action, Condition> {
  .dynamicSubtrees(
    BehaviorNodeMetadata(label: label, attributes: attributes),
    template: template,
    discovery: .action(
      BehaviorNodeMetadata(label: "Find items"),
      discovery
    ),
    start: .action(
      BehaviorNodeMetadata(label: "Start processing"),
      start
    ),
    completion: .action(
      BehaviorNodeMetadata(label: "Wait for completion"),
      completion
    )
  )
}

/// Creates a sequence composite.
public func Sequence<Action, Condition>(
  _ label: String? = nil,
  memory: BehaviorMemoryPolicy = .remembering,
  @BehaviorBuilder<Action, Condition> _ children: () -> [Behavior<Action, Condition>]
) -> Behavior<Action, Condition> {
  .sequence(BehaviorNodeMetadata(label: label), memory, children())
}

/// Creates a priority selector composite.
public func Selector<Action, Condition>(
  _ label: String? = nil,
  memory: BehaviorMemoryPolicy = .remembering,
  @BehaviorBuilder<Action, Condition> _ children: () -> [Behavior<Action, Condition>]
) -> Behavior<Action, Condition> {
  .selector(BehaviorNodeMetadata(label: label), memory, children())
}

/// Creates a two-way conditional branch.
public func If<Action, Condition>(
  _ condition: Condition,
  named label: String? = nil,
  @SingleBehaviorBuilder<Action, Condition> then success: () -> Behavior<Action, Condition>,
  @SingleBehaviorBuilder<Action, Condition> else failure: () -> Behavior<Action, Condition>
) -> Behavior<Action, Condition> {
  .branch(
    BehaviorNodeMetadata(label: label),
    condition: .condition(BehaviorNodeMetadata(), condition),
    success: success(),
    failure: failure()
  )
}

/// Creates a parallel composite that requires every child to succeed.
public func WhenAll<Action, Condition>(
  _ label: String? = nil,
  @BehaviorBuilder<Action, Condition> _ children: () -> [Behavior<Action, Condition>]
) -> Behavior<Action, Condition> {
  .parallel(
    BehaviorNodeMetadata(label: label),
    success: .all,
    failure: .any,
    children: children()
  )
}

/// Creates a parallel composite that succeeds when any child succeeds.
public func WhenAny<Action, Condition>(
  _ label: String? = nil,
  @BehaviorBuilder<Action, Condition> _ children: () -> [Behavior<Action, Condition>]
) -> Behavior<Action, Condition> {
  .parallel(
    BehaviorNodeMetadata(label: label),
    success: .any,
    failure: .all,
    children: children()
  )
}

/// Creates a parallel composite that returns the first terminal child result.
public func Race<Action, Condition>(
  _ label: String? = nil,
  @BehaviorBuilder<Action, Condition> _ children: () -> [Behavior<Action, Condition>]
) -> Behavior<Action, Condition> {
  .parallel(
    BehaviorNodeMetadata(label: label),
    success: .any,
    failure: .any,
    children: children()
  )
}

/// Creates a threshold-based parallel composite.
public func Parallel<Action, Condition>(
  _ label: String? = nil,
  success: ParallelSuccessPolicy,
  failure: ParallelFailurePolicy,
  @BehaviorBuilder<Action, Condition> _ children: () -> [Behavior<Action, Condition>]
) -> Behavior<Action, Condition> {
  .parallel(
    BehaviorNodeMetadata(label: label),
    success: success,
    failure: failure,
    children: children()
  )
}

/// Creates a concurrent composite requiring success in declaration order.
public func OrderedSuccess<Action, Condition>(
  _ label: String? = nil,
  @BehaviorBuilder<Action, Condition> _ children: () -> [Behavior<Action, Condition>]
) -> Behavior<Action, Condition> {
  .orderedSuccess(BehaviorNodeMetadata(label: label), children())
}

/// Creates a loop that rechecks its condition before every body child.
public func While<Action, Condition>(
  _ condition: Condition,
  named label: String? = nil,
  @BehaviorBuilder<Action, Condition> _ body: () -> [Behavior<Action, Condition>]
) -> Behavior<Action, Condition> {
  .loop(
    BehaviorNodeMetadata(label: label),
    condition: .condition(BehaviorNodeMetadata(), condition),
    body: body(),
    checkBeforeEveryChild: true
  )
}

/// Creates a loop that rechecks its condition between complete iterations.
public func WhileAll<Action, Condition>(
  _ condition: Condition,
  named label: String? = nil,
  @BehaviorBuilder<Action, Condition> _ body: () -> [Behavior<Action, Condition>]
) -> Behavior<Action, Condition> {
  .loop(
    BehaviorNodeMetadata(label: label),
    condition: .condition(BehaviorNodeMetadata(), condition),
    body: body(),
    checkBeforeEveryChild: false
  )
}

/// Creates a retry decorator.
public func Retry<Action, Condition>(
  _ label: String? = nil,
  maximumAttempts: Int,
  backoff: Duration = .zero,
  @SingleBehaviorBuilder<Action, Condition> _ child: () -> Behavior<Action, Condition>
) -> Behavior<Action, Condition> {
  .retry(
    BehaviorNodeMetadata(label: label),
    maximumAttempts: maximumAttempts,
    backoff: BehaviorDuration(backoff),
    child: child()
  )
}

/// Creates a repeat decorator. A nil count repeats until cancellation.
public func Repeat<Action, Condition>(
  _ label: String? = nil,
  count: Int? = nil,
  @SingleBehaviorBuilder<Action, Condition> _ child: () -> Behavior<Action, Condition>
) -> Behavior<Action, Condition> {
  .repeatBehavior(
    BehaviorNodeMetadata(label: label),
    count: count,
    child: child()
  )
}

/// Repeats a child until it fails.
public func UntilFailure<Action, Condition>(
  _ label: String? = nil,
  returns outcome: UntilFailureOutcome = .succeeded,
  @SingleBehaviorBuilder<Action, Condition> _ child: () -> Behavior<Action, Condition>
) -> Behavior<Action, Condition> {
  .untilFailure(
    BehaviorNodeMetadata(label: label),
    outcome: outcome,
    child: child()
  )
}

/// Swaps success and failure from a child.
public func Invert<Action, Condition>(
  _ label: String? = nil,
  @SingleBehaviorBuilder<Action, Condition> _ child: () -> Behavior<Action, Condition>
) -> Behavior<Action, Condition> {
  .invert(BehaviorNodeMetadata(label: label), child())
}

/// Converts either terminal child result into success.
public func ForceSuccess<Action, Condition>(
  _ label: String? = nil,
  @SingleBehaviorBuilder<Action, Condition> _ child: () -> Behavior<Action, Condition>
) -> Behavior<Action, Condition> {
  .forceSuccess(BehaviorNodeMetadata(label: label), child())
}

/// Converts either terminal child result into failure.
public func ForceFailure<Action, Condition>(
  _ label: String? = nil,
  @SingleBehaviorBuilder<Action, Condition> _ child: () -> Behavior<Action, Condition>
) -> Behavior<Action, Condition> {
  .forceFailure(BehaviorNodeMetadata(label: label), child())
}

/// Fails and cancels a child that exceeds a duration.
public func Timeout<Action, Condition>(
  _ duration: Duration,
  named label: String? = nil,
  @SingleBehaviorBuilder<Action, Condition> _ child: () -> Behavior<Action, Condition>
) -> Behavior<Action, Condition> {
  .timeout(
    BehaviorNodeMetadata(label: label),
    BehaviorDuration(duration),
    child()
  )
}

/// Guards a child with a typed condition.
public func Precondition<Action, Condition>(
  _ condition: Condition,
  otherwise: UnsatisfiedPreconditionPolicy = .fail,
  named label: String? = nil,
  @SingleBehaviorBuilder<Action, Condition> _ child: () -> Behavior<Action, Condition>
) -> Behavior<Action, Condition> {
  .precondition(
    BehaviorNodeMetadata(label: label),
    condition: .condition(BehaviorNodeMetadata(), condition),
    otherwise: otherwise,
    child: child()
  )
}

/// Runs typed hook actions around the lifecycle of any child subtree.
public func Lifecycle<Action, Condition>(
  _ label: String? = nil,
  onSuccess: Action? = nil,
  onFailure: Action? = nil,
  onCancel: Action? = nil,
  onExit: Action? = nil,
  @SingleBehaviorBuilder<Action, Condition> _ child: () -> Behavior<Action, Condition>
) -> Behavior<Action, Condition> {
  .lifecycle(
    BehaviorNodeMetadata(label: label),
    child: child(),
    onSuccess: onSuccess.map { .action(BehaviorNodeMetadata(), $0) },
    onFailure: onFailure.map { .action(BehaviorNodeMetadata(), $0) },
    onCancel: onCancel.map { .action(BehaviorNodeMetadata(), $0) },
    onExit: onExit.map { .action(BehaviorNodeMetadata(), $0) }
  )
}
