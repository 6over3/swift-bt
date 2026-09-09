import BehaviorTree

struct BehaviorControlFlowGraph {
  struct Edge: Hashable {
    let source: BehaviorNodeID
    let target: BehaviorNodeID
    let targetRole: BehaviorChildRole
    let kind: BehaviorTreeDiagramEdgeKind
    let label: String?
    let order: Int
  }

  struct Exit: Hashable {
    let nodeID: BehaviorNodeID
    let label: String?
  }

  let root: BehaviorDefinitionNode
  let nodes: [BehaviorDefinitionNode]
  let edges: [Edge]
  let orderByNodeID: [BehaviorNodeID: Int]

  init(definition: BehaviorTreeDefinition) {
    var builder = Builder()
    _ = builder.project(definition.root)
    root = definition.root
    nodes = builder.nodes
    edges = builder.edges
    orderByNodeID = builder.orderByNodeID
  }
}

extension BehaviorControlFlowGraph {
  private struct Builder {
    var nodes: [BehaviorDefinitionNode] = []
    var edges: [Edge] = []
    var orderByNodeID: [BehaviorNodeID: Int] = [:]

    mutating func project(_ node: BehaviorDefinitionNode) -> [Exit] {
      if orderByNodeID[node.id] == nil {
        orderByNodeID[node.id] = nodes.count
        nodes.append(node)
      }

      switch node.kind {
      case .sequence, .orderedSuccess:
        return projectSequence(node)
      case .branch:
        return projectBranch(node)
      case .selector, .parallel:
        return projectAlternatives(node)
      case .loop:
        return projectLoop(node)
      case .dynamicSubtrees:
        return projectDynamicExecutions(node)
      case .precondition:
        return projectPrecondition(node)
      case .lifecycle:
        return projectLifecycle(node)
      case .action, .condition, .succeed, .fail, .wait, .waitForever:
        return [Exit(nodeID: node.id, label: nil)]
      case .subtree, .retry, .repeatBehavior, .untilFailure, .inverter,
        .forceSuccess, .forceFailure, .timeout:
        return projectWrapper(node)
      }
    }

    private mutating func projectSequence(_ node: BehaviorDefinitionNode) -> [Exit] {
      var exits = [Exit(nodeID: node.id, label: nil)]
      for child in node.children {
        let childExits = project(child)
        connect(exits, to: child, kind: .controlFlow)
        exits = childExits
      }
      return exits
    }

    private mutating func projectAlternatives(_ node: BehaviorDefinitionNode) -> [Exit] {
      var exits: [Exit] = []
      for child in node.children {
        let childExits = project(child)
        connect([Exit(nodeID: node.id, label: nil)], to: child, kind: .controlFlow)
        exits.append(contentsOf: childExits)
      }
      return exits.isEmpty ? [Exit(nodeID: node.id, label: nil)] : exits
    }

    private mutating func projectBranch(_ node: BehaviorDefinitionNode) -> [Exit] {
      guard let condition = node.children.first(where: { $0.role == .condition }) else {
        return projectAlternatives(node)
      }
      let conditionExits = project(condition)
      connect([Exit(nodeID: node.id, label: nil)], to: condition, kind: .condition)

      var exits: [Exit] = []
      if let thenNode = node.children.first(where: { $0.role == .thenBranch }) {
        exits.append(contentsOf: project(thenNode))
        connect(
          conditionExits.map { Exit(nodeID: $0.nodeID, label: "Yes") }, to: thenNode,
          kind: .condition)
      }
      if let elseNode = node.children.first(where: { $0.role == .elseBranch }) {
        exits.append(contentsOf: project(elseNode))
        connect(
          conditionExits.map { Exit(nodeID: $0.nodeID, label: "No") }, to: elseNode,
          kind: .condition)
      }
      return exits.isEmpty ? conditionExits : exits
    }

    private mutating func projectPrecondition(_ node: BehaviorDefinitionNode) -> [Exit] {
      guard
        let condition = node.children.first(where: { $0.role == .condition }),
        let wrapped = node.children.first(where: { $0.role == .wrapped })
      else {
        return projectWrapper(node)
      }
      let conditionExits = project(condition)
      let wrappedExits = project(wrapped)
      connect([Exit(nodeID: node.id, label: nil)], to: condition, kind: .condition)
      connect(
        conditionExits.map { Exit(nodeID: $0.nodeID, label: "Yes") }, to: wrapped, kind: .condition)
      return conditionExits.map { Exit(nodeID: $0.nodeID, label: "No") } + wrappedExits
    }

    private mutating func projectLoop(_ node: BehaviorDefinitionNode) -> [Exit] {
      guard let condition = node.children.first(where: { $0.role == .condition }) else {
        return projectWrapper(node)
      }
      let conditionExits = project(condition)
      connect([Exit(nodeID: node.id, label: nil)], to: condition, kind: .condition)

      let body = node.children.filter {
        if case .body = $0.role { return true }
        return false
      }
      var bodyExits = conditionExits
      for (index, child) in body.enumerated() {
        let childExits = project(child)
        connect(
          bodyExits.map { Exit(nodeID: $0.nodeID, label: index == 0 ? "Yes" : nil) },
          to: child,
          kind: index == 0 ? .condition : .controlFlow
        )
        bodyExits = childExits
      }
      for exit in bodyExits where exit.nodeID != condition.id {
        addEdge(
          source: exit.nodeID,
          target: condition.id,
          targetRole: condition.role,
          kind: .feedback,
          label: "Repeat"
        )
      }
      return conditionExits.map { Exit(nodeID: $0.nodeID, label: "No") }
    }

    private mutating func projectDynamicExecutions(_ node: BehaviorDefinitionNode) -> [Exit] {
      let discovery = node.children.first(where: { $0.role == .discovery })
      let start = node.children.first(where: { $0.role == .start })
      let completion = node.children.first(where: { $0.role == .completion })
      let template = node.children.first(where: { $0.role == .template })
      let executions = node.children.filter {
        if case .execution = $0.role { return true }
        return false
      }

      var exits = [Exit(nodeID: node.id, label: nil)]
      for phase in [discovery, start].compactMap({ $0 }) {
        let phaseExits = project(phase)
        connect(exits, to: phase, kind: .controlFlow)
        exits = phaseExits
      }

      if let template {
        _ = project(template)
        addEdge(
          source: node.id,
          target: template.id,
          targetRole: template.role,
          kind: .auxiliary,
          label: "Child workflow"
        )
      }

      if !executions.isEmpty {
        var executionExits: [Exit] = []
        for execution in executions {
          let childExits = project(execution)
          connect(exits, to: execution, kind: .childExecution)
          executionExits.append(contentsOf: childExits)
        }
        exits = executionExits
      }

      guard let completion else { return exits }
      let completionExits = project(completion)
      connect(exits, to: completion, kind: .controlFlow)
      return completionExits
    }

    private mutating func projectLifecycle(_ node: BehaviorDefinitionNode) -> [Exit] {
      guard let wrapped = node.children.first(where: { $0.role == .wrapped }) else {
        return projectAlternatives(node)
      }
      var exits = project(wrapped)
      connect([Exit(nodeID: node.id, label: nil)], to: wrapped, kind: .controlFlow)
      for hook in node.children where hook.id != wrapped.id {
        let hookExits = project(hook)
        let label: String? =
          switch hook.role {
          case .onSuccess: "Success"
          case .onFailure: "Failure"
          case .onCancel: "Cancelled"
          case .onExit: "Always"
          default: nil
          }
        connect(exits.map { Exit(nodeID: $0.nodeID, label: label) }, to: hook, kind: .condition)
        exits.append(contentsOf: hookExits)
      }
      return exits
    }

    private mutating func projectWrapper(_ node: BehaviorDefinitionNode) -> [Exit] {
      guard let child = node.children.first else {
        return [Exit(nodeID: node.id, label: nil)]
      }
      let childExits = project(child)
      connect([Exit(nodeID: node.id, label: nil)], to: child, kind: .controlFlow)
      for auxiliary in node.children.dropFirst() {
        _ = project(auxiliary)
        addEdge(
          source: node.id,
          target: auxiliary.id,
          targetRole: auxiliary.role,
          kind: .auxiliary,
          label: nil
        )
      }
      return childExits
    }

    private mutating func connect(
      _ exits: [Exit],
      to target: BehaviorDefinitionNode,
      kind: BehaviorTreeDiagramEdgeKind
    ) {
      for exit in exits {
        addEdge(
          source: exit.nodeID,
          target: target.id,
          targetRole: target.role,
          kind: kind,
          label: exit.label
        )
      }
    }

    private mutating func addEdge(
      source: BehaviorNodeID,
      target: BehaviorNodeID,
      targetRole: BehaviorChildRole,
      kind: BehaviorTreeDiagramEdgeKind,
      label: String?
    ) {
      edges.append(
        Edge(
          source: source,
          target: target,
          targetRole: targetRole,
          kind: kind,
          label: label,
          order: edges.count
        )
      )
    }
  }
}
