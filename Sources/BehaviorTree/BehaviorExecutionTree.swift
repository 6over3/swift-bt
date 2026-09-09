/// The discovery state of one dynamic-subtree declaration.
///
/// A pending declaration has not frozen its child inputs. A frozen declaration
/// has completed discovery, including when it found no children. The number of
/// child executions can temporarily be smaller than `discoveredCount` while the
/// host creates or resumes them.
public enum BehaviorDynamicChildrenState: Codable, Hashable, Sendable {
  case pending
  case frozen(discoveredCount: Int)
}

/// Concrete child executions owned by one dynamic-subtree declaration.
public struct BehaviorDynamicChildExecutions: Codable, Hashable, Sendable {
  /// The dynamic-subtree node in the owning execution's definition.
  public let declarationNodeID: BehaviorNodeID

  /// Whether discovery is pending or has frozen a concrete input collection.
  public let state: BehaviorDynamicChildrenState

  /// Child executions already created or restored for the frozen inputs.
  public let executions: [BehaviorExecutionTree]

  /// Creates one runtime fan-out attached to a dynamic-subtree node.
  public init(
    declarationNodeID: BehaviorNodeID,
    state: BehaviorDynamicChildrenState,
    executions: [BehaviorExecutionTree] = []
  ) {
    self.declarationNodeID = declarationNodeID
    self.state = state
    self.executions = executions
  }
}

/// One serializable execution and every runtime execution it created.
///
/// The immutable definition describes the local control flow. `dynamicChildren`
/// attaches independently persisted executions to the exact dynamic-subtree
/// nodes that created them. Every child carries the same structure recursively,
/// so inspection and visualization retain the complete depth of a workflow.
public struct BehaviorExecutionTree: Codable, Hashable, Sendable {
  public let definition: BehaviorTreeDefinition
  public let snapshot: BehaviorExecutionSnapshot
  public let instanceLabel: String?
  public let attributes: [String: BehaviorMetadataValue]
  public let dynamicChildren: [BehaviorDynamicChildExecutions]

  /// Creates and validates a complete recursive execution tree.
  public init(
    definition: BehaviorTreeDefinition,
    snapshot: BehaviorExecutionSnapshot,
    instanceLabel: String? = nil,
    attributes: [String: BehaviorMetadataValue] = [:],
    dynamicChildren: [BehaviorDynamicChildExecutions] = []
  ) throws(BehaviorExecutionTreeError) {
    self.definition = definition
    self.snapshot = snapshot
    self.instanceLabel = instanceLabel
    self.attributes = attributes
    self.dynamicChildren = dynamicChildren
    try validateExecutionTree(self)
  }

  /// Finds one execution anywhere in the recursive tree.
  public func execution(
    identifiedBy executionID: BehaviorExecutionID
  ) -> Self? {
    var pending = [self]
    while let execution = pending.popLast() {
      if execution.snapshot.executionID == executionID { return execution }
      for branch in execution.dynamicChildren.reversed() {
        pending.append(contentsOf: branch.executions.reversed())
      }
    }
    return nil
  }

  /// Every execution in stable depth-first order.
  public var executions: [Self] {
    var result: [Self] = []
    var pending = [self]
    while let execution = pending.popLast() {
      result.append(execution)
      for branch in execution.dynamicChildren.reversed() {
        pending.append(contentsOf: branch.executions.reversed())
      }
    }
    return result
  }

  private enum CodingKeys: String, CodingKey {
    case definition
    case snapshot
    case instanceLabel
    case attributes
    case dynamicChildren
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      definition: values.decode(BehaviorTreeDefinition.self, forKey: .definition),
      snapshot: values.decode(BehaviorExecutionSnapshot.self, forKey: .snapshot),
      instanceLabel: values.decodeIfPresent(String.self, forKey: .instanceLabel),
      attributes: values.decode(
        [String: BehaviorMetadataValue].self,
        forKey: .attributes
      ),
      dynamicChildren: values.decode(
        [BehaviorDynamicChildExecutions].self,
        forKey: .dynamicChildren
      )
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(definition, forKey: .definition)
    try values.encode(snapshot, forKey: .snapshot)
    try values.encodeIfPresent(instanceLabel, forKey: .instanceLabel)
    try values.encode(attributes, forKey: .attributes)
    try values.encode(dynamicChildren, forKey: .dynamicChildren)
  }
}

/// Invalid persisted topology in a recursive execution tree.
public enum BehaviorExecutionTreeError: Error, Equatable, Sendable {
  case definitionMismatch(executionID: BehaviorExecutionID)
  case duplicateDefinitionNode(BehaviorNodeID)
  case unknownSnapshotNode(executionID: BehaviorExecutionID, nodeID: BehaviorNodeID)
  case duplicateDynamicDeclaration(BehaviorNodeID)
  case missingDynamicDeclarationState(BehaviorNodeID)
  case unknownDynamicDeclaration(BehaviorNodeID)
  case nonDynamicDeclaration(BehaviorNodeID)
  case pendingDeclarationHasExecutions(BehaviorNodeID)
  case invalidDiscoveredCount(nodeID: BehaviorNodeID, count: Int)
  case moreExecutionsThanDiscovered(nodeID: BehaviorNodeID)
  case childTemplateMismatch(
    nodeID: BehaviorNodeID,
    expected: BehaviorTreeReference,
    actual: BehaviorTreeReference
  )
  case duplicateExecution(BehaviorExecutionID)
}

private func validateExecutionTree(
  _ root: BehaviorExecutionTree
) throws(BehaviorExecutionTreeError) {
  var pending = [root]
  var executionIDs = Set<BehaviorExecutionID>()
  while let execution = pending.popLast() {
    let executionID = execution.snapshot.executionID
    guard executionIDs.insert(executionID).inserted else {
      throw .duplicateExecution(executionID)
    }
    guard execution.snapshot.treeName == execution.definition.name,
      execution.snapshot.treeVersion == execution.definition.version
    else {
      throw .definitionMismatch(executionID: executionID)
    }

    var definitionNodes: [BehaviorNodeID: BehaviorDefinitionNode] = [:]
    var definitionPending = [execution.definition.root]
    while let node = definitionPending.popLast() {
      guard definitionNodes.updateValue(node, forKey: node.id) == nil else {
        throw .duplicateDefinitionNode(node.id)
      }
      definitionPending.append(contentsOf: node.children.reversed())
    }
    for nodeID in execution.snapshot.nodes.keys where definitionNodes[nodeID] == nil {
      throw .unknownSnapshotNode(executionID: executionID, nodeID: nodeID)
    }

    var declarationIDs = Set<BehaviorNodeID>()
    for branch in execution.dynamicChildren {
      guard declarationIDs.insert(branch.declarationNodeID).inserted else {
        throw .duplicateDynamicDeclaration(branch.declarationNodeID)
      }
      guard let declaration = definitionNodes[branch.declarationNodeID] else {
        throw .unknownDynamicDeclaration(branch.declarationNodeID)
      }
      guard declaration.kind == .dynamicSubtrees else {
        throw .nonDynamicDeclaration(branch.declarationNodeID)
      }

      switch branch.state {
      case .pending:
        guard branch.executions.isEmpty else {
          throw .pendingDeclarationHasExecutions(branch.declarationNodeID)
        }
      case .frozen(let count):
        guard count >= 0 else {
          throw .invalidDiscoveredCount(
            nodeID: branch.declarationNodeID,
            count: count
          )
        }
        guard branch.executions.count <= count else {
          throw .moreExecutionsThanDiscovered(nodeID: branch.declarationNodeID)
        }
      }

      guard
        case .string(let templateName) = declaration.attributes["templateTreeName"],
        case .string(let templateVersion) = declaration.attributes["templateTreeVersion"]
      else {
        throw .nonDynamicDeclaration(branch.declarationNodeID)
      }
      let expected = BehaviorTreeReference(
        name: templateName,
        version: templateVersion
      )
      for child in branch.executions {
        let actual =
          child.definition.templateFamily
          ?? BehaviorTreeReference(
            name: child.definition.name,
            version: child.definition.version
          )
        guard actual == expected else {
          throw .childTemplateMismatch(
            nodeID: branch.declarationNodeID,
            expected: expected,
            actual: actual
          )
        }
        pending.append(child)
      }
    }
    let expectedDeclarationIDs = Set(
      definitionNodes.values.lazy
        .filter { $0.kind == .dynamicSubtrees }
        .map(\.id)
    )
    if let missing = expectedDeclarationIDs.subtracting(declarationIDs)
      .sorted(by: { $0.rawValue < $1.rawValue })
      .first
    {
      throw .missingDynamicDeclarationState(missing)
    }
  }
}
