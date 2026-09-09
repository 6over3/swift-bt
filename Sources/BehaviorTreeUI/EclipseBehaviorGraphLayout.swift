import BehaviorTree
import CoreGraphics
import ElkSwift
import Foundation

struct EclipseBehaviorGraphLayout {
  struct Result {
    let groups: [BehaviorTreeDiagramGroup]
    let nodes: [BehaviorTreeDiagramNode]
    let edges: [BehaviorTreeDiagramEdge]
    let contentBounds: CGRect
  }

  enum Error: Swift.Error, Equatable {
    case invalidRoot
    case missingNodes
    case missingNode(String)
    case missingNodeGeometry(String)
    case missingEdge(String)
    case missingEdgeRoute(String)
    case invalidCoordinate(String)
  }

  private let graph: BehaviorControlFlowGraph
  private let configuration: BehaviorTreeDiagramLayout

  init(
    graph: BehaviorControlFlowGraph,
    configuration: BehaviorTreeDiagramLayout
  ) {
    self.graph = graph
    self.configuration = configuration
  }

  func layout() throws -> Result {
    let output: [String: Any]
    do {
      output = try ELK().layout(graph: elkGraph)
    } catch {
      throw BehaviorTreeDiagramError.layoutFailed(String(describing: error))
    }

    let positioned = try positionedNodes(from: output)
    let positionedByID = Dictionary(uniqueKeysWithValues: positioned.map { ($0.id, $0) })
    let frames = positionedByID.mapValues(\.frame)
    let nodes = try graph.nodes.map { node in
      guard let positionedNode = positionedByID[node.id] else {
        throw Error.missingNode(node.id.rawValue)
      }
      return BehaviorTreeDiagramNode(
        id: node.id,
        parentID: node.parentID,
        role: node.role,
        kind: node.kind,
        label: node.label,
        attributes: node.attributes,
        childIDs: node.children.map(\.id),
        depth: positionedNode.rank,
        frame: positionedNode.frame
      )
    }
    let edges = try positionedEdges(from: output)
    let groups: [BehaviorTreeDiagramGroup] = []
    let rawBounds = frames.values.reduce(CGRect.null) { $0.union($1) }
      .union(edges.reduce(CGRect.null) { $0.union($1.bounds) })
      .union(groups.reduce(CGRect.null) { $0.union($1.frame) })
    let contentBounds =
      rawBounds.isNull
      ? .zero
      : rawBounds.insetBy(
        dx: -configuration.contentPadding,
        dy: -configuration.contentPadding
      )
    return Result(
      groups: groups,
      nodes: nodes,
      edges: edges,
      contentBounds: contentBounds
    )
  }

  private var elkGraph: [String: Any] {
    let direction = configuration.direction == .leftToRight ? "RIGHT" : "DOWN"
    return [
      "id": "swift-bt-root",
      "layoutOptions": [
        "elk.algorithm": "layered",
        "elk.direction": direction,
        "elk.edgeRouting": "ORTHOGONAL",
        "elk.contentAlignment": "H_CENTER V_CENTER",
        "elk.layered.considerModelOrder.strategy": "NODES_AND_EDGES",
        "elk.layered.nodePlacement.bk.fixedAlignment": "BALANCED",
        "elk.layered.compaction.postCompaction.strategy": "LEFT_RIGHT_CONSTRAINT_LOCKING",
        "elk.layered.highDegreeNodes.treatment": "true",
        "elk.layered.wrapping.strategy": "OFF",
        "elk.spacing.nodeNode": number(configuration.secondarySpacing),
        "elk.layered.spacing.nodeNodeBetweenLayers": number(configuration.primarySpacing),
        "elk.spacing.edgeEdge": number(configuration.edgeSpacing),
        "elk.layered.spacing.edgeEdgeBetweenLayers": number(configuration.edgeSpacing),
        "elk.layered.spacing.edgeNodeBetweenLayers": number(configuration.edgeSpacing),
        "elk.padding": padding(configuration.contentPadding),
      ],
      "children": graph.nodes.map { node in
        [
          "id": node.id.rawValue,
          "width": Double(configuration.nodeSize.width),
          "height": Double(configuration.nodeSize.height),
        ]
      },
      "edges": graph.edges.enumerated().map { index, edge in
        var value: [String: Any] = [
          "id": edgeID(index),
          "sources": [edge.source.rawValue],
          "targets": [edge.target.rawValue],
        ]
        if let label = edge.label {
          value["labels"] = [
            [
              "text": label,
              "width": Double(max(24, label.count * 7 + 10)),
              "height": 18.0,
              "layoutOptions": [
                "elk.edgeLabels.inline": "true",
                "elk.edgeLabels.placement": "CENTER",
              ],
            ] as [String: Any]
          ]
        }
        return value
      },
    ]
  }

  private struct PositionedNode {
    let id: BehaviorNodeID
    let frame: CGRect
    let rank: Int
  }

  private func positionedNodes(from output: [String: Any]) throws -> [PositionedNode] {
    var rawByID: [String: (raw: [String: Any], origin: CGPoint)] = [:]
    try collectNodes(output, origin: .zero, into: &rawByID)
    let rankByID = ranks()
    return try graph.nodes.map { node in
      guard let positioned = rawByID[node.id.rawValue] else {
        throw Error.missingNode(node.id.rawValue)
      }
      let raw = positioned.raw
      guard
        let x = number(raw["x"]),
        let y = number(raw["y"]),
        let width = number(raw["width"]),
        let height = number(raw["height"])
      else {
        throw Error.missingNodeGeometry(node.id.rawValue)
      }
      let frame = CGRect(
        x: positioned.origin.x + x,
        y: positioned.origin.y + y,
        width: width,
        height: height
      )
      guard frame.isFinite else { throw Error.invalidCoordinate(node.id.rawValue) }
      return PositionedNode(id: node.id, frame: frame, rank: rankByID[node.id, default: 0])
    }
  }

  private func collectNodes(
    _ parent: [String: Any],
    origin: CGPoint,
    into result: inout [String: (raw: [String: Any], origin: CGPoint)]
  ) throws {
    guard let children = parent["children"] as? [[String: Any]] else { return }
    for child in children {
      guard let id = child["id"] as? String else { throw Error.missingNode("unknown") }
      let childOrigin = CGPoint(
        x: origin.x + (number(child["x"]) ?? 0),
        y: origin.y + (number(child["y"]) ?? 0)
      )
      if id.hasPrefix("swift-bt-group-") {
        try collectNodes(child, origin: childOrigin, into: &result)
      } else {
        result[id] = (child, origin)
      }
    }
  }

  private func positionedEdges(from output: [String: Any]) throws -> [BehaviorTreeDiagramEdge] {
    let rawEdges = output["edges"] as? [[String: Any]] ?? []
    let rawByID = Dictionary(
      uniqueKeysWithValues: try rawEdges.map { raw -> (String, [String: Any]) in
        guard let id = raw["id"] as? String else { throw Error.missingEdge("unknown") }
        return (id, raw)
      }
    )
    return try graph.edges.enumerated().map { index, edge in
      let id = edgeID(index)
      guard let raw = rawByID[id] else { throw Error.missingEdge(id) }
      guard let sections = raw["sections"] as? [[String: Any]], !sections.isEmpty else {
        throw Error.missingEdgeRoute(id)
      }
      let points = try sections.flatMap { section -> [CGPoint] in
        guard
          let source = try point(section["startPoint"], context: id),
          let target = try point(section["endPoint"], context: id)
        else { throw Error.missingEdgeRoute(id) }
        let bends = try (section["bendPoints"] as? [[String: Any]] ?? []).compactMap {
          try point($0, context: id)
        }
        return [source] + bends + [target]
      }
      let route = removingConsecutiveDuplicates(orthogonalized(points))
      guard route.count >= 2 else { throw Error.missingEdgeRoute(id) }
      let labelPosition = try edgeLabelPosition(raw, context: id)
      var bounds = route.reduce(CGRect.null) { partial, point in
        partial.union(CGRect(origin: point, size: .zero))
      }
      if let labelPosition {
        bounds = bounds.union(
          CGRect(x: labelPosition.x - 36, y: labelPosition.y - 10, width: 72, height: 20)
        )
      }
      return BehaviorTreeDiagramEdge(
        parentID: edge.source,
        childID: edge.target,
        childRole: edge.targetRole,
        kind: edge.kind,
        label: edge.label,
        points: route,
        labelPosition: labelPosition,
        bounds: bounds.insetBy(dx: -4, dy: -4)
      )
    }
  }

  private func edgeLabelPosition(
    _ edge: [String: Any],
    context: String
  ) throws -> CGPoint? {
    guard let label = (edge["labels"] as? [[String: Any]])?.first else { return nil }
    guard
      let x = number(label["x"]),
      let y = number(label["y"]),
      let width = number(label["width"]),
      let height = number(label["height"])
    else { throw Error.invalidCoordinate(context) }
    return CGPoint(x: x + width / 2, y: y + height / 2)
  }

  private func point(_ value: Any?, context: String) throws -> CGPoint? {
    guard let value = value as? [String: Any] else { return nil }
    guard let x = number(value["x"]), let y = number(value["y"]) else {
      throw Error.invalidCoordinate(context)
    }
    let result = CGPoint(x: x, y: y)
    guard result.isFinite else { throw Error.invalidCoordinate(context) }
    return result
  }

  private func ranks() -> [BehaviorNodeID: Int] {
    let forwardEdges = graph.edges.filter { $0.kind != .feedback }
    var incoming = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, 0) })
    var outgoing: [BehaviorNodeID: [BehaviorNodeID]] = [:]
    for edge in forwardEdges {
      incoming[edge.target, default: 0] += 1
      outgoing[edge.source, default: []].append(edge.target)
    }
    var queue = graph.nodes.filter { incoming[$0.id] == 0 }.map(\.id)
    var rank = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, 0) })
    var index = 0
    while index < queue.count {
      let source = queue[index]
      index += 1
      for target in outgoing[source, default: []] {
        rank[target] = max(rank[target, default: 0], rank[source, default: 0] + 1)
        incoming[target, default: 0] -= 1
        if incoming[target] == 0 { queue.append(target) }
      }
    }
    return rank
  }

  private func number(_ value: Any?) -> CGFloat? {
    switch value {
    case let value as Double: CGFloat(value)
    case let value as Float: CGFloat(value)
    case let value as CGFloat: value
    case let value as Int: CGFloat(value)
    case let value as NSNumber: CGFloat(truncating: value)
    default: nil
    }
  }

  private func number(_ value: CGFloat) -> String {
    String(format: "%.3f", Double(value))
  }

  private func padding(_ value: CGFloat) -> String {
    let value = number(value)
    return "[top=\(value),left=\(value),bottom=\(value),right=\(value)]"
  }

  private func edgeID(_ index: Int) -> String { "swift-bt-edge-\(index)" }

  private func removingConsecutiveDuplicates(_ points: [CGPoint]) -> [CGPoint] {
    points.reduce(into: []) { result, point in
      if result.last != point { result.append(point) }
    }
  }

  private func orthogonalized(_ points: [CGPoint]) -> [CGPoint] {
    guard let first = points.first else { return [] }
    return points.dropFirst().reduce(into: [first]) { result, point in
      let previous = result[result.count - 1]
      let deltaX = abs(point.x - previous.x)
      let deltaY = abs(point.y - previous.y)
      if deltaX <= 0.001 {
        result.append(CGPoint(x: previous.x, y: point.y))
      } else if deltaY <= 0.001 {
        result.append(CGPoint(x: point.x, y: previous.y))
      } else {
        result.append(point)
      }
    }
  }
}

private extension BehaviorTreeDiagramLayout {
  var primarySpacing: CGFloat {
    direction == .leftToRight ? horizontalSpacing : verticalSpacing
  }

  var secondarySpacing: CGFloat {
    direction == .leftToRight ? verticalSpacing : horizontalSpacing
  }

  var edgeSpacing: CGFloat {
    max(8, min(primarySpacing, secondarySpacing) / 3)
  }
}

private extension CGRect {
  var isFinite: Bool {
    [origin.x, origin.y, size.width, size.height].allSatisfy(\.isFinite)
  }
}

private extension CGPoint {
  var isFinite: Bool { x.isFinite && y.isFinite }
}
