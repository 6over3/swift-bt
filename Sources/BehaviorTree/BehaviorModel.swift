/// Metadata attached to one declarative node.
public struct BehaviorNodeMetadata: Codable, Hashable, Sendable {
  public let label: String?
  public let attributes: [String: BehaviorMetadataValue]

  /// Creates node metadata.
  public init(
    label: String? = nil,
    attributes: [String: BehaviorMetadataValue] = [:]
  ) {
    self.label = label
    self.attributes = attributes
  }
}

/// Whether a sequential composite remembers its active child.
public enum BehaviorMemoryPolicy: String, Codable, Hashable, Sendable {
  case remembering
  case reactive
}

/// The number of successful parallel children required for success.
public enum ParallelSuccessPolicy: Codable, Hashable, Sendable {
  case all
  case any
  case atLeast(Int)
}

/// The number of failed parallel children required for failure.
public enum ParallelFailurePolicy: Codable, Hashable, Sendable {
  case any
  case all
  case atLeast(Int)
  case whenSuccessBecomesImpossible
}

/// The terminal result produced when an until-failure child fails.
public enum UntilFailureOutcome: String, Codable, Hashable, Sendable {
  case succeeded
  case failed
}

/// The result returned when a precondition is unsatisfied.
public enum UnsatisfiedPreconditionPolicy: String, Codable, Hashable, Sendable {
  case skip
  case succeed
  case fail
}

/// An immutable behavior-tree node.
public indirect enum Behavior<Action, Condition> {
  case action(BehaviorNodeMetadata, Action)
  case condition(BehaviorNodeMetadata, Condition)
  case succeed(BehaviorNodeMetadata)
  case fail(BehaviorNodeMetadata)
  case wait(BehaviorNodeMetadata, BehaviorDuration)
  case waitForever(BehaviorNodeMetadata)
  case subtree(
    BehaviorNodeMetadata,
    name: String,
    version: String,
    child: Self
  )
  case sequence(BehaviorNodeMetadata, BehaviorMemoryPolicy, [Self])
  case selector(BehaviorNodeMetadata, BehaviorMemoryPolicy, [Self])
  case branch(BehaviorNodeMetadata, condition: Self, success: Self, failure: Self)
  case parallel(
    BehaviorNodeMetadata,
    success: ParallelSuccessPolicy,
    failure: ParallelFailurePolicy,
    children: [Self]
  )
  case orderedSuccess(BehaviorNodeMetadata, [Self])
  case loop(
    BehaviorNodeMetadata,
    condition: Self,
    body: [Self],
    checkBeforeEveryChild: Bool
  )
  case retry(
    BehaviorNodeMetadata,
    maximumAttempts: Int,
    backoff: BehaviorDuration,
    child: Self
  )
  case repeatBehavior(BehaviorNodeMetadata, count: Int?, child: Self)
  case untilFailure(BehaviorNodeMetadata, outcome: UntilFailureOutcome, child: Self)
  case invert(BehaviorNodeMetadata, Self)
  case forceSuccess(BehaviorNodeMetadata, Self)
  case forceFailure(BehaviorNodeMetadata, Self)
  case timeout(BehaviorNodeMetadata, BehaviorDuration, Self)
  case precondition(
    BehaviorNodeMetadata,
    condition: Self,
    otherwise: UnsatisfiedPreconditionPolicy,
    child: Self
  )
  case lifecycle(
    BehaviorNodeMetadata,
    child: Self,
    onSuccess: Self?,
    onFailure: Self?,
    onCancel: Self?,
    onExit: Self?
  )
}

extension Behavior: Sendable where Action: Sendable, Condition: Sendable {}
extension Behavior: Equatable where Action: Equatable, Condition: Equatable {}
extension Behavior: Hashable where Action: Hashable, Condition: Hashable {}
extension Behavior: Codable where Action: Codable, Condition: Codable {}

extension Behavior {
  /// Wraps this node with a condition that must be satisfied before entry.
  public func guarded(
    by condition: Condition,
    otherwise: UnsatisfiedPreconditionPolicy = .fail,
    named label: String? = nil
  ) -> Self {
    .precondition(
      BehaviorNodeMetadata(label: label),
      condition: .condition(BehaviorNodeMetadata(), condition),
      otherwise: otherwise,
      child: self
    )
  }

  /// Runs typed hook actions for selected lifecycle outcomes.
  public func onLifecycle(
    success: Action? = nil,
    failure: Action? = nil,
    cancel: Action? = nil,
    exit: Action? = nil,
    named label: String? = nil
  ) -> Self {
    .lifecycle(
      BehaviorNodeMetadata(label: label),
      child: self,
      onSuccess: success.map { .action(BehaviorNodeMetadata(), $0) },
      onFailure: failure.map { .action(BehaviorNodeMetadata(), $0) },
      onCancel: cancel.map { .action(BehaviorNodeMetadata(), $0) },
      onExit: exit.map { .action(BehaviorNodeMetadata(), $0) }
    )
  }
}
