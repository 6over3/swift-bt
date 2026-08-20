import BehaviorTree
import CoreGraphics

/// The primary direction in which tree depth advances.
public enum BehaviorTreeDiagramDirection: Hashable, Sendable {
  case topDown
  case leftToRight
}

/// Immutable spacing and sizing used to lay out a behavior-tree diagram.
public struct BehaviorTreeDiagramLayout: Hashable, Sendable {
  public let direction: BehaviorTreeDiagramDirection
  public let nodeSize: CGSize
  public let horizontalSpacing: CGFloat
  public let verticalSpacing: CGFloat
  public let contentPadding: CGFloat

  /// Creates a tree layout in the requested direction.
  public init(
    direction: BehaviorTreeDiagramDirection = .topDown,
    nodeSize: CGSize = CGSize(width: 184, height: 68),
    horizontalSpacing: CGFloat = 44,
    verticalSpacing: CGFloat = 44,
    contentPadding: CGFloat = 40
  ) {
    precondition(nodeSize.width > 0 && nodeSize.height > 0)
    precondition(horizontalSpacing >= 0 && verticalSpacing >= 0)
    precondition(contentPadding >= 0)
    self.direction = direction
    self.nodeSize = nodeSize
    self.horizontalSpacing = horizontalSpacing
    self.verticalSpacing = verticalSpacing
    self.contentPadding = contentPadding
  }
}

/// One positioned node in a precomputed behavior-tree diagram.
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

/// One positioned edge in a precomputed behavior-tree diagram.
public struct BehaviorTreeDiagramEdge: Hashable, Sendable {
  public let parentID: BehaviorNodeID
  public let childID: BehaviorNodeID
  public let childRole: BehaviorChildRole
  public let start: CGPoint
  public let end: CGPoint
  public let bounds: CGRect
}

/// A renderer-ready, immutable layout of a behavior-tree definition.
///
/// Build this value once when a definition changes, then reuse it for every
/// execution snapshot. Live status updates do not recompute topology.
public struct BehaviorTreeDiagram: Hashable, Sendable {
  public let definition: BehaviorTreeDefinition
  public let layout: BehaviorTreeDiagramLayout
  public let nodes: [BehaviorTreeDiagramNode]
  public let edges: [BehaviorTreeDiagramEdge]
  public let contentBounds: CGRect
  let nodeIndexByID: [BehaviorNodeID: Int]

  /// Lays out a definition in O(n) time and space.
  public init(
    definition: BehaviorTreeDefinition,
    layout: BehaviorTreeDiagramLayout = .init()
  ) {
    var builder = BehaviorTreeDiagramBuilder(layout: layout)
    builder.position(definition.root, depth: 0)
    let built = builder.build(definition.root)
    self.definition = definition
    self.layout = layout
    nodes = built.nodes
    edges = built.edges
    nodeIndexByID = Dictionary(
      uniqueKeysWithValues: built.nodes.enumerated().map { ($0.element.id, $0.offset) }
    )
    contentBounds = CGRect(
      origin: .zero,
      size: CGSize(
        width: builder.contentWidth,
        height: builder.contentHeight
      )
    )
  }
}

private struct BehaviorTreeDiagramBuilder {
  let layout: BehaviorTreeDiagramLayout
  var centers: [BehaviorNodeID: CGPoint] = [:]
  var depths: [BehaviorNodeID: Int] = [:]
  var nextLeafCenter: CGFloat
  var leafCount = 0
  var maximumDepth = 0

  init(layout: BehaviorTreeDiagramLayout) {
    self.layout = layout
    let siblingNodeLength =
      switch layout.direction {
      case .topDown: layout.nodeSize.width
      case .leftToRight: layout.nodeSize.height
      }
    nextLeafCenter = layout.contentPadding + siblingNodeLength / 2
  }

  var contentWidth: CGFloat {
    switch layout.direction {
    case .topDown:
      return siblingContentLength
    case .leftToRight:
      return depthContentLength
    }
  }

  var contentHeight: CGFloat {
    switch layout.direction {
    case .topDown:
      return depthContentLength
    case .leftToRight:
      return siblingContentLength
    }
  }

  @discardableResult
  mutating func position(
    _ node: BehaviorDefinitionNode,
    depth: Int
  ) -> CGFloat {
    maximumDepth = max(maximumDepth, depth)
    depths[node.id] = depth
    let childCenters = node.children.map { child in
      position(child, depth: depth + 1)
    }
    let siblingCenter: CGFloat
    if let first = childCenters.first, let last = childCenters.last {
      siblingCenter = (first + last) / 2
    } else {
      siblingCenter = nextLeafCenter
      nextLeafCenter += siblingNodeLength + siblingSpacing
      leafCount += 1
    }
    let depthCenter =
      layout.contentPadding + depthNodeLength / 2
      + CGFloat(depth) * (depthNodeLength + depthSpacing)
    switch layout.direction {
    case .topDown:
      centers[node.id] = CGPoint(x: siblingCenter, y: depthCenter)
    case .leftToRight:
      centers[node.id] = CGPoint(x: depthCenter, y: siblingCenter)
    }
    return siblingCenter
  }

  func build(
    _ root: BehaviorDefinitionNode
  ) -> (nodes: [BehaviorTreeDiagramNode], edges: [BehaviorTreeDiagramEdge]) {
    var nodes: [BehaviorTreeDiagramNode] = []
    var edges: [BehaviorTreeDiagramEdge] = []
    append(root, nodes: &nodes, edges: &edges)
    return (nodes, edges)
  }

  private func append(
    _ node: BehaviorDefinitionNode,
    nodes: inout [BehaviorTreeDiagramNode],
    edges: inout [BehaviorTreeDiagramEdge]
  ) {
    guard let center = centers[node.id], let depth = depths[node.id] else {
      preconditionFailure("Every definition node must be positioned")
    }
    let frame = CGRect(
      x: center.x - layout.nodeSize.width / 2,
      y: center.y - layout.nodeSize.height / 2,
      width: layout.nodeSize.width,
      height: layout.nodeSize.height
    )
    nodes.append(
      BehaviorTreeDiagramNode(
        id: node.id,
        parentID: node.parentID,
        role: node.role,
        kind: node.kind,
        label: node.label,
        attributes: node.attributes,
        childIDs: node.children.map(\.id),
        depth: depth,
        frame: frame
      )
    )
    for child in node.children {
      guard let childCenter = centers[child.id] else {
        preconditionFailure("Every definition child must be positioned")
      }
      let endpoints = edgeEndpoints(
        parentFrame: frame,
        childCenter: childCenter
      )
      let start = endpoints.start
      let end = endpoints.end
      edges.append(
        BehaviorTreeDiagramEdge(
          parentID: node.id,
          childID: child.id,
          childRole: child.role,
          start: start,
          end: end,
          bounds: CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
          ).insetBy(dx: -2, dy: -2)
        )
      )
      append(child, nodes: &nodes, edges: &edges)
    }
  }

  private var siblingNodeLength: CGFloat {
    switch layout.direction {
    case .topDown: layout.nodeSize.width
    case .leftToRight: layout.nodeSize.height
    }
  }

  private var siblingSpacing: CGFloat {
    switch layout.direction {
    case .topDown: layout.horizontalSpacing
    case .leftToRight: layout.verticalSpacing
    }
  }

  private var depthNodeLength: CGFloat {
    switch layout.direction {
    case .topDown: layout.nodeSize.height
    case .leftToRight: layout.nodeSize.width
    }
  }

  private var depthSpacing: CGFloat {
    switch layout.direction {
    case .topDown: layout.verticalSpacing
    case .leftToRight: layout.horizontalSpacing
    }
  }

  private var siblingContentLength: CGFloat {
    layout.contentPadding * 2
      + CGFloat(leafCount) * siblingNodeLength
      + CGFloat(max(0, leafCount - 1)) * siblingSpacing
  }

  private var depthContentLength: CGFloat {
    layout.contentPadding * 2
      + CGFloat(maximumDepth + 1) * depthNodeLength
      + CGFloat(maximumDepth) * depthSpacing
  }

  private func edgeEndpoints(
    parentFrame: CGRect,
    childCenter: CGPoint
  ) -> (start: CGPoint, end: CGPoint) {
    switch layout.direction {
    case .topDown:
      return (
        CGPoint(x: parentFrame.midX, y: parentFrame.maxY),
        CGPoint(
          x: childCenter.x,
          y: childCenter.y - layout.nodeSize.height / 2
        )
      )
    case .leftToRight:
      return (
        CGPoint(x: parentFrame.maxX, y: parentFrame.midY),
        CGPoint(
          x: childCenter.x - layout.nodeSize.width / 2,
          y: childCenter.y
        )
      )
    }
  }
}
