import BehaviorTree
import SwiftUI

/// A SwiftUI view of one recursively expanded execution tree.
///
/// Selection uses ``BehaviorExecutionNodeReference`` so applications receive
/// the concrete execution and its local node instead of renderer-scoped IDs.
public struct BehaviorExecutionTreeView: View {
  private let projection: BehaviorExecutionTreeProjection
  private let layout: BehaviorTreeDiagramLayout
  private let selection: Binding<BehaviorExecutionNodeReference?>?
  @State private var internalSelection: BehaviorExecutionNodeReference?

  public init(
    projection: BehaviorExecutionTreeProjection,
    layout: BehaviorTreeDiagramLayout = .init()
  ) {
    self.projection = projection
    self.layout = layout
    selection = nil
  }

  public init(
    projection: BehaviorExecutionTreeProjection,
    selection: Binding<BehaviorExecutionNodeReference?>,
    layout: BehaviorTreeDiagramLayout = .init()
  ) {
    self.projection = projection
    self.layout = layout
    self.selection = selection
  }

  public var body: some View {
    BehaviorTreeView(
      definition: projection.definition,
      snapshot: projection.snapshot,
      selection: diagramSelection,
      layout: layout
    )
  }

  private var activeSelection: Binding<BehaviorExecutionNodeReference?> {
    selection ?? $internalSelection
  }

  private var diagramSelection: Binding<BehaviorNodeID?> {
    Binding(
      get: {
        projection.diagramNodeID(for: activeSelection.wrappedValue)
      },
      set: { diagramNodeID in
        activeSelection.wrappedValue = projection.reference(for: diagramNodeID)
      }
    )
  }
}
