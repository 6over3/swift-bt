import BehaviorTree
import BehaviorTreeUI
import CoreGraphics
import Testing

private enum DiagramAction: String, Sendable {
  case first
  case second
  case discover
  case start
  case awaitChildren
}

private enum DiagramCondition: String, Sendable {
  case ready
}

@Test
func sequenceProjectsAsControlFlowRatherThanContainmentFanOut() throws {
  let tree = try BehaviorTree<DiagramAction, DiagramCondition>(name: "sequence") {
    Sequence {
      Condition(.ready)
      Action(.first)
      Action(.second)
    }
  }
  let first = try BehaviorTreeDiagram(definition: tree.definition())
  let second = try BehaviorTreeDiagram(definition: tree.definition())

  #expect(first == second)
  #expect(
    first.edges.map { "\($0.parentID.rawValue)->\($0.childID.rawValue)" } == [
      "root->root.0",
      "root.0->root.1",
      "root.1->root.2",
    ]
  )
  #expect(first.nodes.map(\.depth) == [0, 1, 2, 3])
  #expect(first.edges.allSatisfy { $0.isOrthogonal })
  #expect(first.contentBounds.width > 0)
  #expect(first.contentBounds.height > 0)
}

@Test
func branchAndLoopUseLabeledForwardAndFeedbackEdges() throws {
  let branch = try BehaviorTree<DiagramAction, DiagramCondition>(name: "branch") {
    If(.ready) {
      Action(.first)
    } else: {
      Action(.second)
    }
  }
  let branchDiagram = try BehaviorTreeDiagram(definition: branch.definition())
  #expect(Set(branchDiagram.edges.compactMap(\.label)) == ["Yes", "No"])
  #expect(branchDiagram.edges.filter { $0.kind == .condition }.count == 3)
  #expect(branchDiagram.edges.allSatisfy { $0.isOrthogonal })

  let loop = try BehaviorTree<DiagramAction, DiagramCondition>(name: "loop") {
    While(.ready) {
      Action(.first)
    }
  }
  let loopDiagram = try BehaviorTreeDiagram(definition: loop.definition())
  let feedback = try #require(loopDiagram.edges.first { $0.kind == .feedback })
  #expect(feedback.label == "Repeat")
  #expect(feedback.isOrthogonal)
  #expect(!feedback.bounds.isEmpty)
}

@Test
func recursiveExecutionsAreNestedBetweenStartAndWait() throws {
  let family = BehaviorTreeReference(name: "child", version: "1")
  let leafDefinition = try BehaviorTree<DiagramAction, DiagramCondition>(
    name: "child.leaf",
    version: "1",
    templateFamily: family
  ) {
    Action(.first, named: "Process leaf")
  }
  .definition(actionName: \.rawValue, conditionName: \.rawValue)
  let leaf = try BehaviorExecutionTree(
    definition: leafDefinition,
    snapshot: snapshot(definition: leafDefinition, executionID: "leaf"),
    instanceLabel: "Leaf item"
  )

  let childDefinition = try dynamicDefinition(
    name: "child.specialized",
    templateFamily: family
  )
  let child = try executionTree(
    definition: childDefinition,
    executionID: "child",
    label: "Child item",
    children: [leaf]
  )
  let rootDefinition = try dynamicDefinition(name: "root")
  let root = try executionTree(
    definition: rootDefinition,
    executionID: "root",
    label: nil,
    children: [child]
  )

  let projection = try BehaviorExecutionTreeProjection(tree: root)
  let diagram = try BehaviorTreeDiagram(
    definition: projection.definition,
    layout: BehaviorTreeDiagramLayout(direction: .leftToRight)
  )
  let start = try #require(
    diagram.nodes.first {
      $0.label == "Start processing" && $0.attributes["executionID"] == .string("root")
    }
  )
  let rootWait = try #require(
    diagram.nodes.first {
      $0.label == "Wait for completion" && $0.attributes["executionID"] == .string("root")
    }
  )
  let childWait = try #require(
    diagram.nodes.first {
      $0.label == "Wait for completion" && $0.attributes["executionID"] == .string("child")
    }
  )
  let childReference = try #require(
    projection.rootReference(for: BehaviorExecutionID(rawValue: "child"))
  )
  let childRoot = try #require(projection.diagramNodeID(for: childReference))
  let leafReference = try #require(
    projection.rootReference(for: BehaviorExecutionID(rawValue: "leaf"))
  )
  let leafRoot = try #require(projection.diagramNodeID(for: leafReference))

  #expect(
    diagram.edges.contains {
      $0.parentID == start.id && $0.childID == childRoot && $0.kind == .childExecution
    }
  )
  #expect(
    diagram.edges.contains {
      $0.parentID == leafRoot && $0.childID == childWait.id && $0.kind == .controlFlow
    }
  )
  #expect(
    diagram.edges.contains {
      $0.parentID == childWait.id && $0.childID == rootWait.id && $0.kind == .controlFlow
    }
  )
  let childGroup = try #require(diagram.groups.first { $0.id == "child" })
  let leafGroup = try #require(diagram.groups.first { $0.id == "leaf" })
  #expect(childGroup.label == "Child item")
  #expect(leafGroup.label == "Leaf item")
  #expect(leafGroup.parentID == "child")
  #expect(childGroup.frame.contains(leafGroup.frame))
  #expect(diagram.edges.allSatisfy { $0.isOrthogonal })
}

@Test
func customDiagramLayoutControlsGeometry() throws {
  let tree = try BehaviorTree<DiagramAction, DiagramCondition>(name: "single") {
    Action(.first)
  }
  let layout = BehaviorTreeDiagramLayout(
    nodeSize: CGSize(width: 200, height: 80),
    horizontalSpacing: 40,
    verticalSpacing: 60,
    contentPadding: 20
  )
  let diagram = try BehaviorTreeDiagram(
    definition: tree.definition(),
    layout: layout
  )

  #expect(diagram.nodes[0].frame.size == CGSize(width: 200, height: 80))
  #expect(diagram.contentBounds.size == CGSize(width: 240, height: 120))
}

@Test
func leftToRightLayoutAdvancesControlFlowHorizontally() throws {
  let tree = try BehaviorTree<DiagramAction, DiagramCondition>(name: "horizontal") {
    Sequence {
      Condition(.ready)
      Action(.first)
      Action(.second)
    }
  }
  let diagram = try BehaviorTreeDiagram(
    definition: tree.definition(),
    layout: BehaviorTreeDiagramLayout(
      direction: .leftToRight,
      nodeSize: CGSize(width: 180, height: 60),
      horizontalSpacing: 50,
      verticalSpacing: 20,
      contentPadding: 30
    )
  )
  let ordered = diagram.nodes.sorted { $0.depth < $1.depth }

  #expect(diagram.layout.direction == .leftToRight)
  #expect(zip(ordered, ordered.dropFirst()).allSatisfy { $0.frame.maxX < $1.frame.minX })
  #expect(diagram.edges.allSatisfy { $0.start.x < $0.end.x })
}

private func dynamicDefinition(
  name: String,
  templateFamily: BehaviorTreeReference? = nil
) throws -> BehaviorTreeDefinition {
  try BehaviorTree<DiagramAction, DiagramCondition>(
    name: name,
    version: "1",
    templateFamily: templateFamily
  ) {
    DynamicSubtrees(
      using: BehaviorTreeReference(name: "child", version: "1"),
      discover: .discover,
      start: .start,
      await: .awaitChildren,
      named: "Process children"
    )
  }
  .definition(actionName: \.rawValue, conditionName: \.rawValue)
}

private func executionTree(
  definition: BehaviorTreeDefinition,
  executionID: String,
  label: String?,
  children: [BehaviorExecutionTree]
) throws -> BehaviorExecutionTree {
  try BehaviorExecutionTree(
    definition: definition,
    snapshot: snapshot(definition: definition, executionID: executionID),
    instanceLabel: label,
    dynamicChildren: [
      BehaviorDynamicChildExecutions(
        declarationNodeID: .root,
        state: .frozen(discoveredCount: children.count),
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

extension BehaviorTreeDiagramEdge {
  fileprivate var isOrthogonal: Bool {
    zip(points, points.dropFirst()).allSatisfy { lhs, rhs in
      lhs.x == rhs.x || lhs.y == rhs.y
    }
  }
}
