import BehaviorTree
import CoreGraphics

/// The primary direction in which control flow advances.
public enum BehaviorTreeDiagramDirection: Hashable, Sendable {
  case topDown
  case leftToRight
}

/// Immutable spacing and sizing used to lay out a behavior graph.
public struct BehaviorTreeDiagramLayout: Hashable, Sendable {
  public let direction: BehaviorTreeDiagramDirection
  public let nodeSize: CGSize
  public let horizontalSpacing: CGFloat
  public let verticalSpacing: CGFloat
  public let contentPadding: CGFloat
  public let executionGroupPadding: CGFloat

  /// Creates a layered control-flow layout in the requested direction.
  public init(
    direction: BehaviorTreeDiagramDirection = .topDown,
    nodeSize: CGSize = CGSize(width: 184, height: 68),
    horizontalSpacing: CGFloat = 44,
    verticalSpacing: CGFloat = 44,
    contentPadding: CGFloat = 40,
    executionGroupPadding: CGFloat = 24
  ) {
    precondition(nodeSize.width > 0 && nodeSize.height > 0)
    precondition(horizontalSpacing >= 0 && verticalSpacing >= 0)
    precondition(contentPadding >= 0 && executionGroupPadding >= 0)
    self.direction = direction
    self.nodeSize = nodeSize
    self.horizontalSpacing = horizontalSpacing
    self.verticalSpacing = verticalSpacing
    self.contentPadding = contentPadding
    self.executionGroupPadding = executionGroupPadding
  }
}

/// The semantic purpose of a routed control-flow edge.
public enum BehaviorTreeDiagramEdgeKind: Hashable, Sendable {
  case controlFlow
  case condition
  case feedback
  case auxiliary
  case childExecution
}

/// One positioned node in a precomputed behavior graph.
public struct BehaviorTreeDiagramNode: Identifiable, Hashable, Sendable {
  public let id: BehaviorNodeID
  public let parentID: BehaviorNodeID?
  public let role: BehaviorChildRole
  public let kind: BehaviorNodeKind
  public let label: String
  public let attributes: [String: BehaviorMetadataValue]
  public let childIDs: [BehaviorNodeID]
  public let depth: Int
  public let frame: CGRect
}

/// One routed edge in a precomputed behavior graph.
public struct BehaviorTreeDiagramEdge: Hashable, Sendable {
  public let parentID: BehaviorNodeID
  public let childID: BehaviorNodeID
  public let childRole: BehaviorChildRole
  public let kind: BehaviorTreeDiagramEdgeKind
  public let label: String?
  public let points: [CGPoint]
  public let labelPosition: CGPoint?
  public let bounds: CGRect

  public var start: CGPoint { points.first ?? .zero }
  public var end: CGPoint { points.last ?? .zero }
}

/// The control-flow scope represented by one visual boundary.
public enum BehaviorTreeDiagramGroupKind: Hashable, Sendable {
  case execution
  case parallel
  case decision
  case loop
  case fanOut
}

/// A visual boundary around one execution or structured control-flow scope.
public struct BehaviorTreeDiagramGroup: Identifiable, Hashable, Sendable {
  public let id: String
  public let parentID: String?
  public let kind: BehaviorTreeDiagramGroupKind
  public let label: String
  public let depth: Int
  public let frame: CGRect
}

/// A renderer-ready, immutable layout of a behavior-tree definition.
///
/// The definition remains a containment tree. The diagram is a control-flow
/// projection of that definition. Eclipse ELK owns hierarchical rank,
/// placement, crossing minimization, and orthogonal edge routing.
public struct BehaviorTreeDiagram: Hashable, Sendable {
  public let definition: BehaviorTreeDefinition
  public let layout: BehaviorTreeDiagramLayout
  public let groups: [BehaviorTreeDiagramGroup]
  public let nodes: [BehaviorTreeDiagramNode]
  public let edges: [BehaviorTreeDiagramEdge]
  public let contentBounds: CGRect
  let nodeIndexByID: [BehaviorNodeID: Int]

  /// Projects and lays out the definition as structured control flow.
  public init(
    definition: BehaviorTreeDefinition,
    layout: BehaviorTreeDiagramLayout = .init()
  ) throws {
    let graph = BehaviorControlFlowGraph(definition: definition)
    let result = try EclipseBehaviorGraphLayout(
      graph: graph,
      configuration: layout
    ).layout()
    self.definition = definition
    self.layout = layout
    groups = result.groups
    nodes = result.nodes
    edges = result.edges
    contentBounds = result.contentBounds
    nodeIndexByID = Dictionary(
      uniqueKeysWithValues: result.nodes.enumerated().map { ($0.element.id, $0.offset) }
    )
  }
}

/// A failure to produce a renderer-ready diagram from a valid behavior tree.
public enum BehaviorTreeDiagramError: Error, Equatable, Sendable {
  case layoutFailed(String)
}
