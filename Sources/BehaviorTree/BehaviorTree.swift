/// A validated, immutable behavior-tree definition.
public struct BehaviorTree<Action, Condition> {
  public let name: String
  public let version: String
  public let templateFamily: BehaviorTreeReference?
  public let root: Behavior<Action, Condition>
  let plan: BehaviorPlan<Action, Condition>

  /// Creates and validates a tree from SwiftUI-style node components.
  public init(
    name: String,
    version: String = "1",
    templateFamily: BehaviorTreeReference? = nil,
    @BehaviorBuilder<Action, Condition> _ content: () -> [Behavior<Action, Condition>]
  ) throws {
    let children = content()
    guard children.count == 1, let root = children.first else {
      if children.isEmpty {
        throw BehaviorTreeValidationError.emptyRoot
      }
      throw BehaviorTreeValidationError.invalidRootCount(children.count)
    }
    self.name = name
    self.version = version
    self.templateFamily = templateFamily
    self.root = root
    try Self.validate(root, at: BehaviorNodeID.root)
    plan = BehaviorPlan(root: root)
  }
}

extension BehaviorTree: Sendable where Action: Sendable, Condition: Sendable {}
extension BehaviorTree: Equatable where Action: Equatable, Condition: Equatable {}
extension BehaviorTree: Hashable where Action: Hashable, Condition: Hashable {}

extension BehaviorTree: Codable where Action: Codable, Condition: Codable {
  private enum CodingKeys: String, CodingKey {
    case name
    case version
    case templateFamily
    case root
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    version = try container.decode(String.self, forKey: .version)
    templateFamily = try container.decodeIfPresent(
      BehaviorTreeReference.self,
      forKey: .templateFamily
    )
    root = try container.decode(Behavior<Action, Condition>.self, forKey: .root)
    try Self.validate(root, at: .root)
    plan = BehaviorPlan(root: root)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    try container.encode(version, forKey: .version)
    try container.encodeIfPresent(templateFamily, forKey: .templateFamily)
    try container.encode(root, forKey: .root)
  }
}

extension BehaviorTree {
  /// Returns the typed action declared at one stable node path.
  ///
  /// Tooling can use this to correlate a data-only definition or execution
  /// snapshot with the application operation represented by an action leaf.
  /// Composite, condition, and synthetic template nodes return `nil`.
  public func action(identifiedBy id: BehaviorNodeID) -> Action? {
    guard let node = plan.nodes.first(where: { $0.id == id }),
      case .action(let action) = node.operation
    else {
      return nil
    }
    return action
  }

  /// Returns the typed condition declared at one stable node path.
  ///
  /// Composite, action, and synthetic template nodes return `nil`.
  public func condition(identifiedBy id: BehaviorNodeID) -> Condition? {
    guard let node = plan.nodes.first(where: { $0.id == id }),
      case .condition(let condition) = node.operation
    else {
      return nil
    }
    return condition
  }
}

/// A stable structural path identifying one node in a tree definition.
public struct BehaviorNodeID: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: String

  /// The root node identifier.
  public static let root = Self(rawValue: "root")

  /// Creates an identifier from its persisted representation.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  /// The persisted path.
  public var description: String { rawValue }

  func child(_ index: Int) -> Self {
    Self(rawValue: "\(rawValue).\(index)")
  }
}

/// A structural problem that prevents deterministic execution.
public enum BehaviorTreeValidationError: Error, Equatable, Sendable {
  case emptyRoot
  case invalidRootCount(Int)
  case emptyChildren(nodeID: BehaviorNodeID)
  case invalidRetryAttempts(nodeID: BehaviorNodeID, attempts: Int)
  case invalidRepeatCount(nodeID: BehaviorNodeID, count: Int)
  case negativeDuration(nodeID: BehaviorNodeID)
  case invalidSuccessThreshold(nodeID: BehaviorNodeID, threshold: Int, children: Int)
  case invalidFailureThreshold(nodeID: BehaviorNodeID, threshold: Int, children: Int)
}

extension BehaviorTree {
  private static func validate(
    _ behavior: Behavior<Action, Condition>,
    at nodeID: BehaviorNodeID
  ) throws {
    switch behavior {
    case .action, .condition, .succeed, .fail, .waitForever:
      return

    case .dynamicSubtrees(_, _, let discovery, let start, let completion):
      try validate(discovery, at: nodeID.child(0))
      try validate(start, at: nodeID.child(1))
      try validate(completion, at: nodeID.child(2))

    case .wait(_, let duration):
      if duration.nanoseconds < 0 {
        throw BehaviorTreeValidationError.negativeDuration(nodeID: nodeID)
      }

    case .subtree(_, _, _, let child):
      try validate(child, at: nodeID.child(0))

    case .sequence(_, _, let children),
      .selector(_, _, let children),
      .orderedSuccess(_, let children):
      try validateNonempty(children, at: nodeID)

    case .parallel(_, let success, let failure, let children):
      try validateNonempty(children, at: nodeID)
      try validate(success, childCount: children.count, at: nodeID)
      try validate(failure, childCount: children.count, at: nodeID)

    case .branch(_, let condition, let success, let failure):
      try validate(condition, at: nodeID.child(0))
      try validate(success, at: nodeID.child(1))
      try validate(failure, at: nodeID.child(2))

    case .loop(_, let condition, let body, _):
      guard !body.isEmpty else {
        throw BehaviorTreeValidationError.emptyChildren(nodeID: nodeID)
      }
      try validate(condition, at: nodeID.child(0))
      for (index, child) in body.enumerated() {
        try validate(child, at: nodeID.child(index + 1))
      }

    case .retry(_, let attempts, let backoff, let child):
      guard attempts > 0 else {
        throw BehaviorTreeValidationError.invalidRetryAttempts(
          nodeID: nodeID,
          attempts: attempts
        )
      }
      guard backoff.nanoseconds >= 0 else {
        throw BehaviorTreeValidationError.negativeDuration(nodeID: nodeID)
      }
      try validate(child, at: nodeID.child(0))

    case .repeatBehavior(_, let count, let child):
      if let count, count < 0 {
        throw BehaviorTreeValidationError.invalidRepeatCount(
          nodeID: nodeID,
          count: count
        )
      }
      try validate(child, at: nodeID.child(0))

    case .untilFailure(_, _, let child),
      .invert(_, let child),
      .forceSuccess(_, let child),
      .forceFailure(_, let child):
      try validate(child, at: nodeID.child(0))

    case .timeout(_, let duration, let child):
      guard duration.nanoseconds >= 0 else {
        throw BehaviorTreeValidationError.negativeDuration(nodeID: nodeID)
      }
      try validate(child, at: nodeID.child(0))

    case .precondition(_, let condition, _, let child):
      try validate(condition, at: nodeID.child(0))
      try validate(child, at: nodeID.child(1))

    case .lifecycle(
      _, let child, let onSuccess, let onFailure, let onCancel, let onExit
    ):
      let children = [child, onSuccess, onFailure, onCancel, onExit].compactMap { $0 }
      for (index, child) in children.enumerated() {
        try validate(child, at: nodeID.child(index))
      }
    }
  }

  private static func validateNonempty(
    _ children: [Behavior<Action, Condition>],
    at nodeID: BehaviorNodeID
  ) throws {
    guard !children.isEmpty else {
      throw BehaviorTreeValidationError.emptyChildren(nodeID: nodeID)
    }
    for (index, child) in children.enumerated() {
      try validate(child, at: nodeID.child(index))
    }
  }

  private static func validate(
    _ policy: ParallelSuccessPolicy,
    childCount: Int,
    at nodeID: BehaviorNodeID
  ) throws {
    guard case .atLeast(let threshold) = policy else { return }
    guard (1...childCount).contains(threshold) else {
      throw BehaviorTreeValidationError.invalidSuccessThreshold(
        nodeID: nodeID,
        threshold: threshold,
        children: childCount
      )
    }
  }

  private static func validate(
    _ policy: ParallelFailurePolicy,
    childCount: Int,
    at nodeID: BehaviorNodeID
  ) throws {
    guard case .atLeast(let threshold) = policy else { return }
    guard (1...childCount).contains(threshold) else {
      throw BehaviorTreeValidationError.invalidFailureThreshold(
        nodeID: nodeID,
        threshold: threshold,
        children: childCount
      )
    }
  }
}
