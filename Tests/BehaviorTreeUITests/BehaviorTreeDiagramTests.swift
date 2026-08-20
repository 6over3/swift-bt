import BehaviorTree
import BehaviorTreeUI
import CoreGraphics
import Testing

private enum DiagramAction: Sendable {
  case first
  case second
}

private enum DiagramCondition: Sendable {
  case ready
}

@Test
func diagramLayoutIsStableAndCentersParentsOverChildren() throws {
  let subtree = try BehaviorTree<DiagramAction, DiagramCondition>(name: "work") {
    Sequence {
      Condition(.ready)
      Action(.first)
    }
  }
  let tree = try BehaviorTree<DiagramAction, DiagramCondition>(name: "root") {
    Selector {
      Subtree(subtree)
      Action(.second)
    }
  }
  let definition = tree.definition()
  let first = BehaviorTreeDiagram(definition: definition)
  let second = BehaviorTreeDiagram(definition: definition)

  #expect(first == second)
  #expect(
    first.nodes.map(\.id.rawValue) == [
      "root", "root.0", "root.0.0", "root.0.0.0", "root.0.0.1", "root.1",
    ])
  #expect(first.edges.count == first.nodes.count - 1)
  #expect(first.contentBounds.width > 0)
  #expect(first.contentBounds.height > 0)

  let root = try #require(first.nodes.first { $0.id == .root })
  let children = first.nodes.filter { $0.parentID == .root }
  #expect(children.count == 2)
  #expect(root.frame.midX == (children[0].frame.midX + children[1].frame.midX) / 2)
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
  let diagram = BehaviorTreeDiagram(
    definition: tree.definition(),
    layout: layout
  )

  #expect(diagram.nodes[0].frame.size == CGSize(width: 200, height: 80))
  #expect(diagram.contentBounds.size == CGSize(width: 240, height: 120))
}

@Test
func leftToRightLayoutAdvancesDepthHorizontally() throws {
  let tree = try BehaviorTree<DiagramAction, DiagramCondition>(name: "horizontal") {
    Sequence {
      Condition(.ready)
      Action(.first)
      Action(.second)
    }
  }
  let layout = BehaviorTreeDiagramLayout(
    direction: .leftToRight,
    nodeSize: CGSize(width: 180, height: 60),
    horizontalSpacing: 50,
    verticalSpacing: 20,
    contentPadding: 30
  )
  let diagram = BehaviorTreeDiagram(
    definition: tree.definition(),
    layout: layout
  )
  let root = try #require(diagram.nodes.first { $0.id == .root })
  let children = diagram.nodes.filter { $0.parentID == .root }

  #expect(diagram.layout.direction == .leftToRight)
  #expect(children.allSatisfy { $0.frame.minX > root.frame.maxX })
  #expect(root.frame.midY == (children.first!.frame.midY + children.last!.frame.midY) / 2)
  #expect(diagram.edges.allSatisfy { $0.start.x < $0.end.x })
}
