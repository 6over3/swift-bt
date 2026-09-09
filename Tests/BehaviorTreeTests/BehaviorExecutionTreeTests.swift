import Foundation
import Testing

@testable import BehaviorTree

private enum ExecutionTreeAction: String, Codable, Sendable {
  case discover
  case start
  case awaitChildren
}

private enum ExecutionTreeCondition: String, Codable, Sendable {
  case unused
}

@Test
func executionTreeProjectsEveryRuntimeDepthAndRoundTrips() throws {
  let childDefinition = try dynamicDefinition(name: "child")
  let deepest = try executionTree(
    definition: childDefinition,
    executionID: "deepest",
    label: "Face C",
    state: .pending
  )
  let child = try executionTree(
    definition: childDefinition,
    executionID: "child",
    label: "Face B",
    state: .frozen(discoveredCount: 1),
    children: [deepest]
  )
  let root = try executionTree(
    definition: try dynamicDefinition(name: "root"),
    executionID: "root",
    label: nil,
    state: .frozen(discoveredCount: 1),
    children: [child]
  )

  let projection = try BehaviorExecutionTreeProjection(tree: root)
  let runtimeEdges = projection.definition.allNodes.flatMap { parent in
    parent.children.filter {
      if case .execution = $0.role { true } else { false }
    }
  }

  #expect(
    root.executions.map(\.snapshot.executionID.rawValue) == [
      "root", "child", "deepest",
    ])
  #expect(runtimeEdges.count == 2)
  #expect(runtimeEdges.map(\.label) == ["Face B · 1 children", "Face C · discovery pending"])
  #expect(
    projection.nodes.allSatisfy { node in
      projection.reference(for: node.diagramNodeID) == node.reference
        && projection.diagramNodeID(for: node.reference) == node.diagramNodeID
    })

  let encoded = try JSONEncoder().encode(root)
  let decoded = try JSONDecoder().decode(BehaviorExecutionTree.self, from: encoded)
  #expect(decoded == root)
}

@Test
func frozenEmptyFanOutIsDifferentFromPendingDiscovery() throws {
  let definition = try dynamicDefinition(name: "empty")
  let pending = try executionTree(
    definition: definition,
    executionID: "pending",
    label: nil,
    state: .pending
  )
  let empty = try executionTree(
    definition: definition,
    executionID: "empty",
    label: nil,
    state: .frozen(discoveredCount: 0)
  )

  let pendingProjection = try BehaviorExecutionTreeProjection(tree: pending)
  let emptyProjection = try BehaviorExecutionTreeProjection(tree: empty)
  #expect(pendingProjection.definition.root.label.contains("discovery pending"))
  #expect(emptyProjection.definition.root.label.contains("0 children"))
}

@Test
func filteredExecutionKeepsItsCompletePathAndDescendants() throws {
  let rootDefinition = try dynamicDefinition(name: "filter")
  let childDefinition = try dynamicDefinition(name: "child")
  let grandchild = try executionTree(
    definition: childDefinition,
    executionID: "grandchild",
    label: "Nested evidence",
    state: .frozen(discoveredCount: 0)
  )
  let selectedChild = try executionTree(
    definition: childDefinition,
    executionID: "selected",
    label: "Selected region",
    state: .frozen(discoveredCount: 1),
    children: [grandchild]
  )
  let sibling = try executionTree(
    definition: childDefinition,
    executionID: "sibling",
    label: "Unrelated region",
    state: .frozen(discoveredCount: 0)
  )
  let root = try executionTree(
    definition: rootDefinition,
    executionID: "root",
    label: nil,
    state: .frozen(discoveredCount: 2),
    children: [selectedChild, sibling]
  )

  let projection = try BehaviorExecutionTreeProjection(
    tree: root,
    including: [BehaviorExecutionID(rawValue: "selected")]
  )

  #expect(
    projection.visibleExecutionIDs == [
      BehaviorExecutionID(rawValue: "root"),
      BehaviorExecutionID(rawValue: "selected"),
      BehaviorExecutionID(rawValue: "grandchild"),
    ]
  )
  #expect(
    projection.rootReference(for: BehaviorExecutionID(rawValue: "root")) != nil
  )
  #expect(
    projection.rootReference(for: BehaviorExecutionID(rawValue: "selected")) != nil
  )
  #expect(
    projection.rootReference(for: BehaviorExecutionID(rawValue: "grandchild")) != nil
  )
  #expect(
    projection.rootReference(for: BehaviorExecutionID(rawValue: "sibling")) == nil
  )
}

@Test
func executionTreeRejectsIncompleteOrContradictoryFanOut() throws {
  let definition = try dynamicDefinition(name: "invalid")
  let child = try executionTree(
    definition: definition,
    executionID: "child",
    label: nil,
    state: .pending
  )

  #expect(throws: BehaviorExecutionTreeError.missingDynamicDeclarationState(.root)) {
    try BehaviorExecutionTree(
      definition: definition,
      snapshot: snapshot(definition: definition, executionID: "missing")
    )
  }
  #expect(throws: BehaviorExecutionTreeError.pendingDeclarationHasExecutions(.root)) {
    try BehaviorExecutionTree(
      definition: definition,
      snapshot: snapshot(definition: definition, executionID: "pending"),
      dynamicChildren: [
        BehaviorDynamicChildExecutions(
          declarationNodeID: .root,
          state: .pending,
          executions: [child]
        )
      ]
    )
  }
}

@Test
func executionTreeAcceptsExplicitTemplateFamilySpecializations() throws {
  let family = BehaviorTreeReference(name: "child", version: "1")
  let specializedDefinition = try BehaviorTree<
    ExecutionTreeAction,
    ExecutionTreeCondition
  >(
    name: "child.music-release",
    version: "1",
    templateFamily: family
  ) {
    Succeed("Specialized child")
  }
  .definition(actionName: \.rawValue, conditionName: \.rawValue)
  let specializedChild = try BehaviorExecutionTree(
    definition: specializedDefinition,
    snapshot: snapshot(
      definition: specializedDefinition,
      executionID: "specialized"
    )
  )
  let root = try executionTree(
    definition: try dynamicDefinition(name: "root"),
    executionID: "root",
    label: nil,
    state: .frozen(discoveredCount: 1),
    children: [specializedChild]
  )

  #expect(root.execution(identifiedBy: .init(rawValue: "specialized")) != nil)
  #expect(
    try BehaviorExecutionTreeProjection(tree: root).definition.allNodes
      .contains { $0.label == "Specialized child" }
  )
}

@Test
func executionTreeRejectsAnUnrelatedTemplateFamily() throws {
  let specializedDefinition = try BehaviorTree<
    ExecutionTreeAction,
    ExecutionTreeCondition
  >(
    name: "unrelated.specialization",
    version: "1",
    templateFamily: BehaviorTreeReference(name: "unrelated", version: "1")
  ) {
    Succeed("Unrelated child")
  }
  .definition(actionName: \.rawValue, conditionName: \.rawValue)
  let child = try BehaviorExecutionTree(
    definition: specializedDefinition,
    snapshot: snapshot(definition: specializedDefinition, executionID: "unrelated")
  )

  #expect(
    throws: BehaviorExecutionTreeError.childTemplateMismatch(
      nodeID: .root,
      expected: BehaviorTreeReference(name: "child", version: "1"),
      actual: BehaviorTreeReference(name: "unrelated", version: "1")
    )
  ) {
    try executionTree(
      definition: try dynamicDefinition(name: "root"),
      executionID: "root",
      label: nil,
      state: .frozen(discoveredCount: 1),
      children: [child]
    )
  }
}

private func dynamicDefinition(
  name: String
) throws -> BehaviorTreeDefinition {
  try BehaviorTree<ExecutionTreeAction, ExecutionTreeCondition>(name: name) {
    DynamicSubtrees(
      using: BehaviorTreeReference(name: "child", version: "1"),
      discover: .discover,
      start: .start,
      await: .awaitChildren,
      named: "Run children"
    )
  }
  .definition(actionName: \.rawValue, conditionName: \.rawValue)
}

private func executionTree(
  definition: BehaviorTreeDefinition,
  executionID: String,
  label: String?,
  state: BehaviorDynamicChildrenState,
  children: [BehaviorExecutionTree] = []
) throws -> BehaviorExecutionTree {
  try BehaviorExecutionTree(
    definition: definition,
    snapshot: snapshot(definition: definition, executionID: executionID),
    instanceLabel: label,
    dynamicChildren: [
      BehaviorDynamicChildExecutions(
        declarationNodeID: .root,
        state: state,
        executions: children
      )
    ]
  )
}

private func snapshot(
  definition: BehaviorTreeDefinition,
  executionID: String
) -> BehaviorExecutionSnapshot {
  BehaviorExecutionSnapshot(
    treeName: definition.name,
    treeVersion: definition.version,
    executionID: BehaviorExecutionID(rawValue: executionID),
    definitionFingerprint: 0,
    status: .running,
    eventSequence: 1,
    elapsedNanoseconds: 0,
    nodes: [:]
  )
}

extension BehaviorTreeDefinition {
  fileprivate var allNodes: [BehaviorDefinitionNode] {
    var result: [BehaviorDefinitionNode] = []
    var pending = [root]
    while let node = pending.popLast() {
      result.append(node)
      pending.append(contentsOf: node.children.reversed())
    }
    return result
  }
}
