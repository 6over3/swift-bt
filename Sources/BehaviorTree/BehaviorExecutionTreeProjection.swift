/// A stable reference to one local node in one concrete execution.
public struct BehaviorExecutionNodeReference: Codable, Hashable, Sendable {
  public let executionID: BehaviorExecutionID
  public let nodeID: BehaviorNodeID

  public init(
    executionID: BehaviorExecutionID,
    nodeID: BehaviorNodeID
  ) {
    self.executionID = executionID
    self.nodeID = nodeID
  }
}

/// One selectable node in a recursively expanded execution projection.
public struct BehaviorExecutionProjectionNode: Hashable, Sendable {
  /// The renderer-local identifier. Use `reference` for application work.
  public let diagramNodeID: BehaviorNodeID
  public let reference: BehaviorExecutionNodeReference
  public let label: String
  public let kind: BehaviorNodeKind
}

/// A complete recursive execution projected for existing tree renderers.
///
/// Local node identifiers are scoped by execution before definitions and
/// snapshots are merged. Concrete runtime executions branch directly from the
/// dynamic declaration that created them, and can themselves contain deeper
/// runtime executions.
public struct BehaviorExecutionTreeProjection: Hashable, Sendable {
  public let definition: BehaviorTreeDefinition
  public let snapshot: BehaviorVisualizationSnapshot
  public let nodes: [BehaviorExecutionProjectionNode]
  /// Every concrete execution available in the source tree, in stable depth-first order.
  public let allExecutionIDs: [BehaviorExecutionID]
  /// The concrete executions included in this projection.
  public let visibleExecutionIDs: Set<BehaviorExecutionID>

  private let referencesByDiagramNodeID: [BehaviorNodeID: BehaviorExecutionNodeReference]
  private let diagramNodeIDsByReference: [BehaviorExecutionNodeReference: BehaviorNodeID]
  private let rootReferencesByExecutionID: [BehaviorExecutionID: BehaviorExecutionNodeReference]

  /// Creates a projection of the complete execution tree.
  public init(tree: BehaviorExecutionTree) throws(BehaviorVisualizationError) {
    try self.init(tree: tree, including: nil)
  }

  /// Creates a path-preserving projection of selected concrete executions.
  ///
  /// A filtered projection includes the root, every selected execution, all of
  /// its ancestors, and all work recursively created by it. Sibling executions
  /// are omitted. This keeps the complete fan-out path visible without mixing
  /// unrelated child work into the diagram.
  public init(
    tree: BehaviorExecutionTree,
    including executionIDs: Set<BehaviorExecutionID>?
  ) throws(BehaviorVisualizationError) {
    let allExecutionIDs = tree.executions.map(\.snapshot.executionID)
    let visibleExecutionIDs = Self.visibleExecutionIDs(
      in: tree,
      selected: executionIDs
    )
    var builder = Builder(visibleExecutionIDs: visibleExecutionIDs)
    let root = try builder.projectExecution(
      tree,
      parentID: nil,
      role: .root,
      isRootExecution: true,
      parentExecutionID: nil
    )
    let definition = BehaviorTreeDefinition(
      name: "\(tree.definition.name).execution-tree",
      version: "\(tree.definition.version)+projection.2",
      root: root
    )
    self.definition = definition
    snapshot = BehaviorVisualizationSnapshot(
      definition: definition,
      executionID: tree.snapshot.executionID,
      sequence: builder.maximumEventSequence,
      status: tree.snapshot.status,
      nodes: builder.nodeStates
    )
    nodes = builder.nodes
    self.allExecutionIDs = allExecutionIDs
    self.visibleExecutionIDs = visibleExecutionIDs
    referencesByDiagramNodeID = builder.referencesByDiagramNodeID
    diagramNodeIDsByReference = builder.diagramNodeIDsByReference
    rootReferencesByExecutionID = builder.rootReferencesByExecutionID
  }

  private static func visibleExecutionIDs(
    in tree: BehaviorExecutionTree,
    selected: Set<BehaviorExecutionID>?
  ) -> Set<BehaviorExecutionID> {
    let all = Set(tree.executions.map(\.snapshot.executionID))
    guard let selected else { return all }

    var parentByExecutionID: [BehaviorExecutionID: BehaviorExecutionID] = [:]
    var executionByID: [BehaviorExecutionID: BehaviorExecutionTree] = [:]
    var pending = [tree]
    while let execution = pending.popLast() {
      let executionID = execution.snapshot.executionID
      executionByID[executionID] = execution
      for branch in execution.dynamicChildren.reversed() {
        for child in branch.executions.reversed() {
          parentByExecutionID[child.snapshot.executionID] = executionID
          pending.append(child)
        }
      }
    }

    var visible: Set<BehaviorExecutionID> = [tree.snapshot.executionID]
    for selectedID in selected where executionByID[selectedID] != nil {
      var ancestorID: BehaviorExecutionID? = selectedID
      while let current = ancestorID, visible.insert(current).inserted {
        ancestorID = parentByExecutionID[current]
      }

      var descendants = [executionByID[selectedID]!]
      while let descendant = descendants.popLast() {
        visible.insert(descendant.snapshot.executionID)
        for branch in descendant.dynamicChildren.reversed() {
          descendants.append(contentsOf: branch.executions.reversed())
        }
      }
    }
    return visible
  }

  public func reference(
    for diagramNodeID: BehaviorNodeID?
  ) -> BehaviorExecutionNodeReference? {
    diagramNodeID.flatMap { referencesByDiagramNodeID[$0] }
  }

  public func diagramNodeID(
    for reference: BehaviorExecutionNodeReference?
  ) -> BehaviorNodeID? {
    reference.flatMap { diagramNodeIDsByReference[$0] }
  }

  public func rootReference(
    for executionID: BehaviorExecutionID
  ) -> BehaviorExecutionNodeReference? {
    rootReferencesByExecutionID[executionID]
  }
}

extension BehaviorExecutionTreeProjection {
  private struct Builder {
    let visibleExecutionIDs: Set<BehaviorExecutionID>
    var referencesByDiagramNodeID: [BehaviorNodeID: BehaviorExecutionNodeReference] = [:]
    var diagramNodeIDsByReference: [BehaviorExecutionNodeReference: BehaviorNodeID] = [:]
    var rootReferencesByExecutionID: [BehaviorExecutionID: BehaviorExecutionNodeReference] = [:]
    var nodes: [BehaviorExecutionProjectionNode] = []
    var nodeStates: [BehaviorNodeID: BehaviorNodeVisualizationState] = [:]
    var maximumEventSequence: UInt64 = 0

    mutating func projectExecution(
      _ execution: BehaviorExecutionTree,
      parentID: BehaviorNodeID?,
      role: BehaviorChildRole,
      isRootExecution: Bool,
      parentExecutionID: BehaviorExecutionID?
    ) throws(BehaviorVisualizationError) -> BehaviorDefinitionNode {
      maximumEventSequence = max(
        maximumEventSequence,
        execution.snapshot.eventSequence
      )
      let visualization = try BehaviorVisualizationSnapshot(
        definition: execution.definition,
        execution: execution.snapshot
      )
      let reference = BehaviorExecutionNodeReference(
        executionID: execution.snapshot.executionID,
        nodeID: execution.definition.root.id
      )
      rootReferencesByExecutionID[execution.snapshot.executionID] = reference
      let dynamicChildren = Dictionary(
        uniqueKeysWithValues: execution.dynamicChildren.map {
          ($0.declarationNodeID, $0)
        }
      )
      return try projectNode(
        execution.definition.root,
        execution: execution,
        visualization: visualization,
        dynamicChildren: dynamicChildren,
        parentID: parentID,
        role: role,
        rootLabel: isRootExecution ? nil : execution.instanceLabel,
        isExecutionRoot: true,
        parentExecutionID: parentExecutionID
      )
    }

    mutating func projectNode(
      _ node: BehaviorDefinitionNode,
      execution: BehaviorExecutionTree,
      visualization: BehaviorVisualizationSnapshot,
      dynamicChildren: [BehaviorNodeID: BehaviorDynamicChildExecutions],
      parentID: BehaviorNodeID?,
      role: BehaviorChildRole,
      rootLabel: String? = nil,
      isExecutionRoot: Bool = false,
      parentExecutionID: BehaviorExecutionID? = nil
    ) throws(BehaviorVisualizationError) -> BehaviorDefinitionNode {
      let reference = BehaviorExecutionNodeReference(
        executionID: execution.snapshot.executionID,
        nodeID: node.id
      )
      let diagramNodeID = scopedNodeID(for: reference)
      referencesByDiagramNodeID[diagramNodeID] = reference
      diagramNodeIDsByReference[reference] = diagramNodeID
      if let state = visualization.nodes[node.id] {
        nodeStates[diagramNodeID] = state
      }

      let branch = dynamicChildren[node.id]
      let presentation = presentation(
        of: node,
        rootLabel: rootLabel,
        execution: execution,
        branch: branch,
        isExecutionRoot: isExecutionRoot,
        parentExecutionID: parentExecutionID
      )
      nodes.append(
        BehaviorExecutionProjectionNode(
          diagramNodeID: diagramNodeID,
          reference: reference,
          label: presentation.label,
          kind: node.kind
        )
      )

      var projectedChildren: [BehaviorDefinitionNode] = []
      projectedChildren.reserveCapacity(
        node.children.count + (dynamicChildren[node.id]?.executions.count ?? 0)
      )
      for child in node.children {
        projectedChildren.append(
          try projectNode(
            child,
            execution: execution,
            visualization: visualization,
            dynamicChildren: dynamicChildren,
            parentID: diagramNodeID,
            role: child.role
          )
        )
      }
      if let branch {
        let visibleChildren = branch.executions.filter {
          visibleExecutionIDs.contains($0.snapshot.executionID)
        }
        for (index, child) in visibleChildren.enumerated() {
          projectedChildren.append(
            try projectExecution(
              child,
              parentID: diagramNodeID,
              role: .execution(index),
              isRootExecution: false,
              parentExecutionID: execution.snapshot.executionID
            )
          )
        }
      }

      return BehaviorDefinitionNode(
        id: diagramNodeID,
        parentID: parentID,
        role: role,
        kind: node.kind,
        label: presentation.label,
        attributes: presentation.attributes,
        children: projectedChildren
      )
    }

    private func presentation(
      of node: BehaviorDefinitionNode,
      rootLabel: String?,
      execution: BehaviorExecutionTree,
      branch: BehaviorDynamicChildExecutions?,
      isExecutionRoot: Bool,
      parentExecutionID: BehaviorExecutionID?
    ) -> (label: String, attributes: [String: BehaviorMetadataValue]) {
      var attributes = node.attributes.merging(execution.attributes) {
        declared, _ in declared
      }
      attributes["executionID"] = .string(execution.snapshot.executionID.rawValue)
      if isExecutionRoot {
        attributes["isExecutionRoot"] = .boolean(true)
        attributes["executionLabel"] = .string(rootLabel ?? execution.definition.root.label)
      }
      if let parentExecutionID {
        attributes["parentExecutionID"] = .string(parentExecutionID.rawValue)
      }
      let baseLabel = rootLabel ?? node.label
      guard let branch else { return (baseLabel, attributes) }

      attributes["startedChildExecutions"] = .integer(
        Int64(branch.executions.count)
      )
      let visibleChildCount = branch.executions.count {
        visibleExecutionIDs.contains($0.snapshot.executionID)
      }
      attributes["visibleChildExecutions"] = .integer(Int64(visibleChildCount))
      attributes["hiddenChildExecutions"] = .integer(
        Int64(branch.executions.count - visibleChildCount)
      )
      switch branch.state {
      case .pending:
        attributes["childDiscoveryState"] = .string("pending")
        return ("\(baseLabel) · discovery pending", attributes)
      case .frozen(let discoveredCount):
        attributes["childDiscoveryState"] = .string("frozen")
        attributes["discoveredChildren"] = .integer(Int64(discoveredCount))
        if discoveredCount == branch.executions.count {
          return ("\(baseLabel) · \(discoveredCount) children", attributes)
        }
        return (
          "\(baseLabel) · \(branch.executions.count) of \(discoveredCount) started",
          attributes
        )
      }
    }

    private func scopedNodeID(
      for reference: BehaviorExecutionNodeReference
    ) -> BehaviorNodeID {
      let executionID = reference.executionID.rawValue
      return BehaviorNodeID(
        rawValue:
          "execution:\(executionID.utf8.count):\(executionID):node:\(reference.nodeID.rawValue)"
      )
    }
  }
}
