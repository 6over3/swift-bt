/// The semantic kind of a node in a static tree definition.
public enum BehaviorNodeKind: String, Codable, Hashable, Sendable {
  case action
  case condition
  case succeed
  case fail
  case wait
  case waitForever
  case subtree
  case sequence
  case selector
  case branch
  case parallel
  case orderedSuccess
  case loop
  case retry
  case repeatBehavior
  case untilFailure
  case inverter
  case forceSuccess
  case forceFailure
  case timeout
  case precondition
  case lifecycle
}

/// One data-only node used by visualization and external tooling.
public struct BehaviorDefinitionNode: Codable, Hashable, Sendable {
  public let id: BehaviorNodeID
  public let parentID: BehaviorNodeID?
  public let role: BehaviorChildRole
  public let kind: BehaviorNodeKind
  public let label: String
  public let attributes: [String: BehaviorMetadataValue]
  public let children: [Self]

  /// Creates a definition node.
  public init(
    id: BehaviorNodeID,
    parentID: BehaviorNodeID?,
    role: BehaviorChildRole = .root,
    kind: BehaviorNodeKind,
    label: String,
    attributes: [String: BehaviorMetadataValue] = [:],
    children: [Self] = []
  ) {
    self.id = id
    self.parentID = parentID
    self.role = role
    self.kind = kind
    self.label = label
    self.attributes = attributes
    self.children = children
  }
}

/// A serializable static hierarchy independent of executor implementation.
public struct BehaviorTreeDefinition: Codable, Hashable, Sendable {
  public let name: String
  public let version: String
  public let root: BehaviorDefinitionNode

  /// Creates a static tree definition.
  public init(name: String, version: String, root: BehaviorDefinitionNode) {
    self.name = name
    self.version = version
    self.root = root
  }

  /// Returns Graphviz DOT describing this tree.
  ///
  /// This operation visits every node and is O(n).
  public func graphviz(
    theme: BehaviorGraphvizTheme = .default
  ) -> String {
    graphvizUnchecked(highlighting: nil, theme: theme)
  }

  /// Returns Graphviz DOT styled with one compatible execution snapshot.
  ///
  /// Running frontier nodes receive stronger emphasis than their active
  /// ancestors. Status, attempts, progress, and diagnostics are included in
  /// node labels when available. This operation is O(n).
  public func graphviz(
    highlighting snapshot: BehaviorVisualizationSnapshot,
    theme: BehaviorGraphvizTheme = .default
  ) throws(BehaviorVisualizationError) -> String {
    guard snapshot.treeName == name,
      snapshot.treeVersion == version,
      Set(snapshot.nodes.keys) == definitionNodeIDs(root)
    else {
      throw .definitionMismatch
    }
    return graphvizUnchecked(highlighting: snapshot, theme: theme)
  }

  func graphvizUnchecked(
    highlighting snapshot: BehaviorVisualizationSnapshot?,
    theme: BehaviorGraphvizTheme
  ) -> String {
    let backgroundColor = graphvizEscaped(theme.backgroundColor)
    let edgeColor = graphvizEscaped(theme.edgeColor)
    let edgeTextColor = graphvizEscaped(theme.edgeTextColor)
    let fontName = graphvizEscaped(theme.fontName)
    var lines = [
      "digraph BehaviorTree {",
      "  rankdir=TB;",
      "  graph [bgcolor=\"\(backgroundColor)\"];",
      "  edge [color=\"\(edgeColor)\", fontcolor=\"\(edgeTextColor)\", fontname=\"\(fontName)\"];",
      "  node [fontname=\"\(fontName)\"];",
    ]
    let frontierNodeIDs =
      snapshot.map {
        runningFrontierNodeIDs(in: root, snapshot: $0)
      } ?? []
    appendGraphviz(
      root,
      highlighting: snapshot,
      frontierNodeIDs: frontierNodeIDs,
      theme: theme,
      to: &lines
    )
    lines.append("}")
    return lines.joined(separator: "\n")
  }
}

extension BehaviorTree {
  /// Builds the data-only hierarchy used by visualizers and observability tools.
  ///
  /// Leaf naming closures should return stable, privacy-safe display names.
  public func definition(
    actionName: (Action) -> String = { _ in "Action" },
    conditionName: (Condition) -> String = { _ in "Condition" }
  ) -> BehaviorTreeDefinition {
    BehaviorTreeDefinition(
      name: name,
      version: version,
      root: makeDefinitionNode(
        at: 0,
        actionName: actionName,
        conditionName: conditionName
      )
    )
  }

  private func makeDefinitionNode(
    at index: Int,
    actionName: (Action) -> String,
    conditionName: (Condition) -> String
  ) -> BehaviorDefinitionNode {
    let node = plan.nodes[index]
    let description = definitionDescription(
      of: node.operation,
      actionName: actionName,
      conditionName: conditionName
    )
    return BehaviorDefinitionNode(
      id: node.id,
      parentID: node.parent.map { plan.nodes[$0].id },
      role: node.role,
      kind: description.kind,
      label: node.metadata.label ?? description.fallbackLabel,
      attributes: node.metadata.attributes.merging(description.attributes) {
        declared, _ in declared
      },
      children: node.children.map {
        makeDefinitionNode(
          at: $0,
          actionName: actionName,
          conditionName: conditionName
        )
      }
    )
  }
}

func definitionDescription<Action, Condition>(
  of operation: BehaviorPlanOperation<Action, Condition>,
  actionName: (Action) -> String,
  conditionName: (Condition) -> String
) -> (
  kind: BehaviorNodeKind,
  fallbackLabel: String,
  attributes: [String: BehaviorMetadataValue]
) {
  switch operation {
  case .action(let action): return (.action, actionName(action), [:])
  case .condition(let condition): return (.condition, conditionName(condition), [:])
  case .succeed: return (.succeed, "Succeed", [:])
  case .fail: return (.fail, "Fail", [:])
  case .wait(let duration):
    return (.wait, "Wait", ["nanoseconds": .integer(duration.nanoseconds)])
  case .waitForever: return (.waitForever, "Wait Forever", [:])
  case .subtree(let name, let version):
    return (
      .subtree,
      name,
      [
        "treeName": .string(name),
        "treeVersion": .string(version),
      ]
    )
  case .sequence(let memory):
    return (.sequence, "Sequence", ["memory": .string(memory.rawValue)])
  case .selector(let memory):
    return (.selector, "Selector", ["memory": .string(memory.rawValue)])
  case .branch: return (.branch, "If", [:])
  case .parallel(let success, let failure):
    return (
      .parallel,
      parallelLabel(success: success, failure: failure),
      [
        "successPolicy": .string(success.description),
        "failurePolicy": .string(failure.description),
      ]
    )
  case .orderedSuccess: return (.orderedSuccess, "Ordered Success", [:])
  case .loop(let everyChild):
    return (.loop, everyChild ? "While" : "While All", [:])
  case .retry(let attempts, let backoff):
    return (
      .retry,
      "Retry",
      [
        "maximumAttempts": .integer(Int64(attempts)),
        "backoffNanoseconds": .integer(backoff.nanoseconds),
      ]
    )
  case .repeatBehavior(let count):
    return (
      .repeatBehavior,
      "Repeat",
      count.map { ["count": .integer(Int64($0))] }
        ?? ["count": .string("unlimited")]
    )
  case .untilFailure(let outcome):
    return (
      .untilFailure,
      "Until Failure",
      ["outcome": .string(outcome.rawValue)]
    )
  case .invert: return (.inverter, "Invert", [:])
  case .forceSuccess: return (.forceSuccess, "Force Success", [:])
  case .forceFailure: return (.forceFailure, "Force Failure", [:])
  case .timeout(let duration):
    return (
      .timeout,
      "Timeout",
      ["nanoseconds": .integer(duration.nanoseconds)]
    )
  case .precondition(let policy):
    return (
      .precondition,
      "Precondition",
      ["otherwise": .string(policy.rawValue)]
    )
  case .lifecycle: return (.lifecycle, "Lifecycle", [:])
  }
}

private func parallelLabel(
  success: ParallelSuccessPolicy,
  failure: ParallelFailurePolicy
) -> String {
  switch (success, failure) {
  case (.all, .any): return "When All"
  case (.any, .all): return "When Any"
  case (.any, .any): return "Race"
  default: return "Parallel"
  }
}

extension ParallelSuccessPolicy {
  fileprivate var description: String {
    switch self {
    case .all: return "all"
    case .any: return "any"
    case .atLeast(let count): return "atLeast:\(count)"
    }
  }
}

extension ParallelFailurePolicy {
  fileprivate var description: String {
    switch self {
    case .any: return "any"
    case .all: return "all"
    case .atLeast(let count): return "atLeast:\(count)"
    case .whenSuccessBecomesImpossible: return "whenSuccessBecomesImpossible"
    }
  }
}

private func appendGraphviz(
  _ node: BehaviorDefinitionNode,
  highlighting snapshot: BehaviorVisualizationSnapshot?,
  frontierNodeIDs: Set<BehaviorNodeID>,
  theme: BehaviorGraphvizTheme,
  to lines: inout [String]
) {
  let shape: String
  switch node.kind {
  case .condition: shape = "ellipse"
  case .action: shape = "box"
  case .subtree: shape = "component"
  case .sequence, .selector, .parallel, .orderedSuccess, .branch, .loop:
    shape = "diamond"
  case .succeed, .fail, .wait, .waitForever: shape = "oval"
  default: shape = "hexagon"
  }
  let state = snapshot?.nodes[node.id]
  let status = state?.status ?? .idle
  let isFrontier = frontierNodeIDs.contains(node.id)
  let label = graphvizLabel(for: node, state: state)
  let tooltip = graphvizTooltip(for: node, state: state)
  var attributes = [
    "label=\"\(graphvizEscaped(label))\"",
    "tooltip=\"\(graphvizEscaped(tooltip))\"",
    "shape=\(shape)",
  ]
  attributes.append(
    contentsOf: graphvizAttributes(
      for: status,
      isFrontier: isFrontier,
      theme: theme
    )
  )
  lines.append(
    "  \"\(graphvizEscaped(node.id.rawValue))\" [\(attributes.joined(separator: ", "))];"
  )
  for child in node.children {
    var edgeAttributes =
      graphvizRoleLabel(child.role).map {
        ["label=\"\(graphvizEscaped($0))\""]
      } ?? []
    if let snapshot, let childState = snapshot.nodes[child.id] {
      edgeAttributes.append(
        contentsOf: graphvizEdgeAttributes(
          for: childState.status,
          isFrontier: frontierNodeIDs.contains(child.id),
          theme: theme
        )
      )
    }
    let renderedEdgeAttributes =
      edgeAttributes.isEmpty
      ? ""
      : " [\(edgeAttributes.joined(separator: ", "))]"
    lines.append(
      "  \"\(graphvizEscaped(node.id.rawValue))\" -> \"\(graphvizEscaped(child.id.rawValue))\"\(renderedEdgeAttributes);"
    )
    appendGraphviz(
      child,
      highlighting: snapshot,
      frontierNodeIDs: frontierNodeIDs,
      theme: theme,
      to: &lines
    )
  }
}

private func graphvizEdgeAttributes(
  for status: BehaviorVisualizationStatus,
  isFrontier: Bool,
  theme: BehaviorGraphvizTheme
) -> [String] {
  guard status != .idle else { return [] }
  let nodeStyle = theme.nodeStyle(for: status)
  var attributes = ["color=\"\(graphvizEscaped(nodeStyle.borderColor))\""]
  if status == .running {
    attributes.append(
      "penwidth=\(isFrontier ? theme.frontierPenWidth : theme.runningPenWidth)"
    )
  }
  if nodeStyle.style.split(separator: ",").contains("dashed") {
    attributes.append("style=dashed")
  }
  return attributes
}

private func definitionNodeIDs(
  _ node: BehaviorDefinitionNode
) -> Set<BehaviorNodeID> {
  node.children.reduce(into: Set([node.id])) { result, child in
    result.formUnion(definitionNodeIDs(child))
  }
}

private func runningFrontierNodeIDs(
  in root: BehaviorDefinitionNode,
  snapshot: BehaviorVisualizationSnapshot
) -> Set<BehaviorNodeID> {
  var frontier: Set<BehaviorNodeID> = []
  func visit(_ node: BehaviorDefinitionNode) -> Bool {
    var hasRunningDescendant = false
    for child in node.children where visit(child) {
      hasRunningDescendant = true
    }
    let isRunning = snapshot.nodes[node.id]?.status == .running
    if isRunning, !hasRunningDescendant { frontier.insert(node.id) }
    return isRunning || hasRunningDescendant
  }
  _ = visit(root)
  return frontier
}

private func graphvizLabel(
  for node: BehaviorDefinitionNode,
  state: BehaviorNodeVisualizationState?
) -> String {
  guard let state, state.status != .idle else { return node.label }
  var details = [state.status.rawValue]
  if let attempt = state.attempt { details.append("attempt \(attempt)") }
  if let progress = state.progress {
    if let completed = progress.completed, let total = progress.total {
      details.append("\(completed)/\(total)")
    } else if let fraction = progress.fraction {
      details.append("progress \(fraction)")
    }
    if let message = progress.message { details.append(message) }
  }
  if let diagnostic = state.diagnostic {
    details.append(diagnostic.summary ?? diagnostic.code)
  }
  if let summary = state.inspection?.summary {
    details.append(summary)
  }
  return node.label + "\n" + details.joined(separator: " · ")
}

private func graphvizTooltip(
  for node: BehaviorDefinitionNode,
  state: BehaviorNodeVisualizationState?
) -> String {
  var lines = [graphvizLabel(for: node, state: state)]
  if let diagnostic = state?.diagnostic {
    for key in diagnostic.attributes.keys.sorted() {
      if let value = diagnostic.attributes[key] {
        lines.append("diagnostic.\(key): \(value)")
      }
    }
  }
  if let inspection = state?.inspection {
    for key in inspection.values.keys.sorted() {
      if let value = inspection.values[key] {
        lines.append("\(key): \(value)")
      }
    }
  }
  return lines.joined(separator: "\n")
}

private func graphvizAttributes(
  for status: BehaviorVisualizationStatus,
  isFrontier: Bool,
  theme: BehaviorGraphvizTheme
) -> [String] {
  let nodeStyle = theme.nodeStyle(for: status)
  var attributes = [
    "style=\"\(graphvizEscaped(nodeStyle.style))\"",
    "color=\"\(graphvizEscaped(nodeStyle.borderColor))\"",
    "fillcolor=\"\(graphvizEscaped(nodeStyle.fillColor))\"",
    "fontcolor=\"\(graphvizEscaped(nodeStyle.textColor))\"",
  ]
  if status == .running {
    attributes.append(
      "penwidth=\(isFrontier ? theme.frontierPenWidth : theme.runningPenWidth)"
    )
  }
  return attributes
}

private func graphvizRoleLabel(_ role: BehaviorChildRole) -> String? {
  switch role {
  case .root, .child, .wrapped: return nil
  case .condition: return "condition"
  case .thenBranch: return "then"
  case .elseBranch: return "else"
  case .body(let index): return "body \(index + 1)"
  case .onSuccess: return "on success"
  case .onFailure: return "on failure"
  case .onCancel: return "on cancel"
  case .onExit: return "on exit"
  }
}

private func graphvizEscaped(_ value: String) -> String {
  var escaped = ""
  escaped.reserveCapacity(value.utf8.count)
  for character in value {
    switch character {
    case "\\": escaped.append("\\\\")
    case "\"": escaped.append("\\\"")
    case "\n": escaped.append("\\n")
    default: escaped.append(character)
    }
  }
  return escaped
}
