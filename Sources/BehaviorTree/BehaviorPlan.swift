/// The semantic relationship between a definition node and its parent.
public enum BehaviorChildRole: Codable, Hashable, Sendable {
  case root
  case child(Int)
  case condition
  case thenBranch
  case elseBranch
  case body(Int)
  case wrapped
  case onSuccess
  case onFailure
  case onCancel
  case onExit
  /// Produces and freezes the concrete inputs of a dynamic collection.
  case discovery
  /// Creates or resumes the concrete child executions.
  case start
  /// Observes the concrete child executions until they are terminal.
  case completion
  /// The declared tree template instantiated by a dynamic-subtree node.
  case template
  /// One concrete execution instantiated from a dynamic-subtree template.
  case execution(Int)
}

struct BehaviorPlan<Action, Condition> {
  let nodes: [BehaviorPlanNode<Action, Condition>]
  let fingerprint: UInt64

  init(root: Behavior<Action, Condition>) {
    var compiler = BehaviorPlanCompiler<Action, Condition>()
    _ = compiler.append(root, id: .root, parent: nil, role: .root)
    nodes = compiler.nodes
    fingerprint = Self.makeFingerprint(nodes: compiler.nodes)
  }

  private static func makeFingerprint(
    nodes: [BehaviorPlanNode<Action, Condition>]
  ) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for node in nodes {
      for byte in "\(node.id.rawValue)|\(node.role.structuralKey)|\(node.operation.structuralKey);"
        .utf8
      {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
      }
    }
    return hash
  }
}

extension BehaviorPlan: Sendable where Action: Sendable, Condition: Sendable {}
extension BehaviorPlan: Equatable where Action: Equatable, Condition: Equatable {}
extension BehaviorPlan: Hashable where Action: Hashable, Condition: Hashable {}

struct BehaviorPlanNode<Action, Condition> {
  let id: BehaviorNodeID
  let parent: Int?
  let role: BehaviorChildRole
  let metadata: BehaviorNodeMetadata
  let operation: BehaviorPlanOperation<Action, Condition>
  let children: [Int]
}

extension BehaviorPlanNode: Sendable where Action: Sendable, Condition: Sendable {}
extension BehaviorPlanNode: Equatable where Action: Equatable, Condition: Equatable {}
extension BehaviorPlanNode: Hashable where Action: Hashable, Condition: Hashable {}

enum BehaviorPlanOperation<Action, Condition> {
  case action(Action)
  case condition(Condition)
  case succeed
  case fail
  case wait(BehaviorDuration)
  case waitForever
  case subtree(name: String, version: String)
  case dynamicSubtrees(templateName: String, templateVersion: String)
  case sequence(BehaviorMemoryPolicy)
  case selector(BehaviorMemoryPolicy)
  case branch
  case parallel(success: ParallelSuccessPolicy, failure: ParallelFailurePolicy)
  case orderedSuccess
  case loop(checkBeforeEveryChild: Bool)
  case retry(maximumAttempts: Int, backoff: BehaviorDuration)
  case repeatBehavior(count: Int?)
  case untilFailure(UntilFailureOutcome)
  case invert
  case forceSuccess
  case forceFailure
  case timeout(BehaviorDuration)
  case precondition(UnsatisfiedPreconditionPolicy)
  case lifecycle
}

extension BehaviorPlanOperation: Sendable where Action: Sendable, Condition: Sendable {}
extension BehaviorPlanOperation: Equatable where Action: Equatable, Condition: Equatable {}
extension BehaviorPlanOperation: Hashable where Action: Hashable, Condition: Hashable {}

extension BehaviorChildRole {
  fileprivate var structuralKey: String {
    switch self {
    case .root: return "root"
    case .child(let index): return "child:\(index)"
    case .condition: return "condition"
    case .thenBranch: return "then"
    case .elseBranch: return "else"
    case .body(let index): return "body:\(index)"
    case .wrapped: return "wrapped"
    case .onSuccess: return "success"
    case .onFailure: return "failure"
    case .onCancel: return "cancel"
    case .onExit: return "exit"
    case .discovery: return "discovery"
    case .start: return "start"
    case .completion: return "completion"
    case .template: return "template"
    case .execution(let index): return "execution:\(index)"
    }
  }
}

extension BehaviorPlanOperation {
  fileprivate var structuralKey: String {
    switch self {
    case .action: return "action"
    case .condition: return "condition"
    case .succeed: return "succeed"
    case .fail: return "fail"
    case .wait(let duration): return "wait:\(duration.nanoseconds)"
    case .waitForever: return "waitForever"
    case .subtree(let name, let version):
      return "subtree:\(name.utf8.count):\(name):\(version.utf8.count):\(version)"
    case .dynamicSubtrees(let name, let version):
      return "dynamicSubtrees:\(name.utf8.count):\(name):\(version.utf8.count):\(version)"
    case .sequence(let memory): return "sequence:\(memory.rawValue)"
    case .selector(let memory): return "selector:\(memory.rawValue)"
    case .branch: return "branch"
    case .parallel(let success, let failure):
      return "parallel:\(success.structuralKey):\(failure.structuralKey)"
    case .orderedSuccess: return "orderedSuccess"
    case .loop(let everyChild): return "loop:\(everyChild)"
    case .retry(let attempts, let backoff):
      return "retry:\(attempts):\(backoff.nanoseconds)"
    case .repeatBehavior(let count): return "repeat:\(count.map(String.init) ?? "nil")"
    case .untilFailure(let outcome): return "untilFailure:\(outcome.rawValue)"
    case .invert: return "invert"
    case .forceSuccess: return "forceSuccess"
    case .forceFailure: return "forceFailure"
    case .timeout(let duration): return "timeout:\(duration.nanoseconds)"
    case .precondition(let policy): return "precondition:\(policy.rawValue)"
    case .lifecycle: return "lifecycle"
    }
  }
}

extension ParallelSuccessPolicy {
  fileprivate var structuralKey: String {
    switch self {
    case .all: return "all"
    case .any: return "any"
    case .atLeast(let count): return "atLeast:\(count)"
    }
  }
}

extension ParallelFailurePolicy {
  fileprivate var structuralKey: String {
    switch self {
    case .any: return "any"
    case .all: return "all"
    case .atLeast(let count): return "atLeast:\(count)"
    case .whenSuccessBecomesImpossible: return "impossible"
    }
  }
}

private struct BehaviorPlanCompiler<Action, Condition> {
  var nodes: [BehaviorPlanNode<Action, Condition>] = []

  mutating func append(
    _ behavior: Behavior<Action, Condition>,
    id: BehaviorNodeID,
    parent: Int?,
    role: BehaviorChildRole
  ) -> Int {
    let index = nodes.count
    let description = planDescription(of: behavior)
    nodes.append(
      BehaviorPlanNode(
        id: id,
        parent: parent,
        role: role,
        metadata: description.metadata,
        operation: description.operation,
        children: []
      )
    )
    let children = planChildren(of: behavior)
    let childIndexes = children.enumerated().map { offset, child in
      append(
        child.behavior,
        id: id.child(offset),
        parent: index,
        role: child.role
      )
    }
    nodes[index] = BehaviorPlanNode(
      id: id,
      parent: parent,
      role: role,
      metadata: description.metadata,
      operation: description.operation,
      children: childIndexes
    )
    return index
  }
}

private func planDescription<Action, Condition>(
  of behavior: Behavior<Action, Condition>
) -> (
  metadata: BehaviorNodeMetadata,
  operation: BehaviorPlanOperation<Action, Condition>
) {
  switch behavior {
  case .action(let metadata, let value): return (metadata, .action(value))
  case .condition(let metadata, let value): return (metadata, .condition(value))
  case .succeed(let metadata): return (metadata, .succeed)
  case .fail(let metadata): return (metadata, .fail)
  case .wait(let metadata, let duration): return (metadata, .wait(duration))
  case .waitForever(let metadata): return (metadata, .waitForever)
  case .subtree(let metadata, let name, let version, _):
    return (metadata, .subtree(name: name, version: version))
  case .dynamicSubtrees(let metadata, let template, _, _, _):
    return (
      metadata,
      .dynamicSubtrees(
        templateName: template.name,
        templateVersion: template.version
      )
    )
  case .sequence(let metadata, let memory, _): return (metadata, .sequence(memory))
  case .selector(let metadata, let memory, _): return (metadata, .selector(memory))
  case .branch(let metadata, _, _, _): return (metadata, .branch)
  case .parallel(let metadata, let success, let failure, _):
    return (metadata, .parallel(success: success, failure: failure))
  case .orderedSuccess(let metadata, _): return (metadata, .orderedSuccess)
  case .loop(let metadata, _, _, let everyChild):
    return (metadata, .loop(checkBeforeEveryChild: everyChild))
  case .retry(let metadata, let attempts, let backoff, _):
    return (metadata, .retry(maximumAttempts: attempts, backoff: backoff))
  case .repeatBehavior(let metadata, let count, _):
    return (metadata, .repeatBehavior(count: count))
  case .untilFailure(let metadata, let outcome, _):
    return (metadata, .untilFailure(outcome))
  case .invert(let metadata, _): return (metadata, .invert)
  case .forceSuccess(let metadata, _): return (metadata, .forceSuccess)
  case .forceFailure(let metadata, _): return (metadata, .forceFailure)
  case .timeout(let metadata, let duration, _): return (metadata, .timeout(duration))
  case .precondition(let metadata, _, let policy, _):
    return (metadata, .precondition(policy))
  case .lifecycle(let metadata, _, _, _, _, _): return (metadata, .lifecycle)
  }
}

private func planChildren<Action, Condition>(
  of behavior: Behavior<Action, Condition>
) -> [(behavior: Behavior<Action, Condition>, role: BehaviorChildRole)] {
  switch behavior {
  case .action, .condition, .succeed, .fail, .wait,
    .waitForever:
    return []
  case .dynamicSubtrees(_, _, let discovery, let start, let completion):
    return [
      (discovery, .discovery),
      (start, .start),
      (completion, .completion),
    ]
  case .subtree(_, _, _, let child):
    return [(child, .wrapped)]
  case .sequence(_, _, let children), .selector(_, _, let children),
    .parallel(_, _, _, let children), .orderedSuccess(_, let children):
    return children.enumerated().map { ($0.element, .child($0.offset)) }
  case .branch(_, let condition, let success, let failure):
    return [(condition, .condition), (success, .thenBranch), (failure, .elseBranch)]
  case .loop(_, let condition, let body, _):
    return [(condition, .condition)]
      + body.enumerated().map { ($0.element, .body($0.offset)) }
  case .retry(_, _, _, let child), .repeatBehavior(_, _, let child),
    .untilFailure(_, _, let child), .invert(_, let child),
    .forceSuccess(_, let child), .forceFailure(_, let child),
    .timeout(_, _, let child):
    return [(child, .wrapped)]
  case .precondition(_, let condition, _, let child):
    return [(condition, .condition), (child, .wrapped)]
  case .lifecycle(_, let child, let success, let failure, let cancellation, let exit):
    var children: [(Behavior<Action, Condition>, BehaviorChildRole)] = [(child, .wrapped)]
    if let success { children.append((success, .onSuccess)) }
    if let failure { children.append((failure, .onFailure)) }
    if let cancellation { children.append((cancellation, .onCancel)) }
    if let exit { children.append((exit, .onExit)) }
    return children
  }
}
