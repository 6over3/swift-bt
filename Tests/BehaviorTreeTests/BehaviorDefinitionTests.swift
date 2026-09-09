import Foundation
import Testing

@testable import BehaviorTree

private enum TestAction: String, Codable, Hashable, Sendable {
  case validate
  case analyze
  case publish
}

private enum TestCondition: String, Codable, Hashable, Sendable {
  case isSupported
  case needsAnalysis
}

@Test
func swiftUIStyleDSLBuildsStableDefinition() throws {
  let tree = try BehaviorTree<TestAction, TestCondition>(name: "pipeline") {
    Sequence("ingest") {
      Action(.validate)
      Condition(.isSupported)
      WhenAll("analysis") {
        Action(.analyze)
        Action(.publish)
      }
    }
  }

  let definition = tree.definition(
    actionName: { $0.rawValue },
    conditionName: { $0.rawValue }
  )

  #expect(definition.root.id == .root)
  #expect(definition.root.label == "ingest")
  #expect(
    definition.root.children.map(\.id.rawValue) == [
      "root.0", "root.1", "root.2",
    ])
  #expect(definition.root.children[1].kind == .condition)
  #expect(definition.root.children[2].children.count == 2)
}

@Test
func definitionRoundTripsThroughCodable() throws {
  let tree = try BehaviorTree<TestAction, TestCondition>(name: "pipeline") {
    Selector {
      Condition(.isSupported)
      Action(.validate)
    }
  }

  let data = try JSONEncoder().encode(tree)
  let decoded = try JSONDecoder().decode(
    BehaviorTree<TestAction, TestCondition>.self,
    from: data
  )
  #expect(decoded == tree)
}

@Test
func reusableSubtreesPreserveBoundariesAndParentScopedIdentity() throws {
  let analysis = try BehaviorTree<TestAction, TestCondition>(
    name: "analysis",
    version: "3"
  ) {
    Sequence("analyze input") {
      Condition(.needsAnalysis)
      Action(.analyze)
    }
  }
  let tree = try BehaviorTree<TestAction, TestCondition>(name: "pipeline") {
    Sequence {
      Subtree(analysis, named: "primary analysis")
      Subtree(analysis)
    }
  }

  let definition = tree.definition()
  let primary = definition.root.children[0]
  let repeated = definition.root.children[1]

  #expect(primary.kind == .subtree)
  #expect(primary.label == "primary analysis")
  #expect(primary.attributes["treeName"] == .string("analysis"))
  #expect(primary.attributes["treeVersion"] == .string("3"))
  #expect(primary.children[0].id.rawValue == "root.0.0")
  #expect(repeated.label == "analysis")
  #expect(repeated.children[0].id.rawValue == "root.1.0")

  let graph = definition.graphviz()
  #expect(graph.contains("shape=component"))

  let data = try JSONEncoder().encode(tree)
  let decoded = try JSONDecoder().decode(
    BehaviorTree<TestAction, TestCondition>.self,
    from: data
  )
  #expect(decoded == tree)
}

@Test
func dynamicSubtreesDeclareTheirTemplateAndRoundTrip() throws {
  let template = BehaviorTreeReference(name: "image-region", version: "3")
  let tree = try BehaviorTree<TestAction, TestCondition>(name: "pipeline") {
    DynamicSubtrees(
      using: template,
      discover: .validate,
      start: .analyze,
      await: .publish,
      named: "Process regions",
      attributes: ["source": .string("image-analysis")]
    )
  }

  let definition = tree.definition(actionName: { $0.rawValue })
  #expect(definition.root.kind == .dynamicSubtrees)
  #expect(definition.root.label == "Process regions")
  #expect(definition.root.children.count == 4)
  #expect(definition.root.children[0].role == .discovery)
  #expect(definition.root.children[0].label == "Find items")
  #expect(definition.root.children[1].role == .start)
  #expect(definition.root.children[1].label == "Start processing")
  #expect(definition.root.children[2].role == .completion)
  #expect(definition.root.children[2].label == "Wait for completion")
  let templateChild = definition.root.children[3]
  #expect(templateChild.role == .template)
  #expect(templateChild.kind == .subtree)
  #expect(templateChild.label == "image-region")
  #expect(templateChild.attributes["treeName"] == .string("image-region"))
  #expect(templateChild.attributes["treeVersion"] == .string("3"))
  #expect(definition.root.attributes["source"] == .string("image-analysis"))
  #expect(definition.root.attributes["templateTreeName"] == .string("image-region"))
  #expect(definition.root.attributes["templateTreeVersion"] == .string("3"))
  #expect(definition.graphviz().contains("shape=folder"))

  let data = try JSONEncoder().encode(tree)
  let decoded = try JSONDecoder().decode(
    BehaviorTree<TestAction, TestCondition>.self,
    from: data
  )
  #expect(decoded == tree)
}

@Test
func validationRejectsInvalidRetryAndEmptyComposite() {
  #expect(throws: BehaviorTreeValidationError.self) {
    try BehaviorTree<TestAction, TestCondition>(name: "invalid") {
      Retry(maximumAttempts: 0) {
        Action(.analyze)
      }
    }
  }

  #expect(throws: BehaviorTreeValidationError.self) {
    try BehaviorTree<TestAction, TestCondition>(name: "invalid") {
      Sequence {}
    }
  }
}

@Test
func treeRequiresOneExplicitRootComponent() {
  #expect(throws: BehaviorTreeValidationError.invalidRootCount(2)) {
    try BehaviorTree<TestAction, TestCondition>(name: "ambiguous") {
      Action(.validate)
      Action(.publish)
    }
  }
}

@Test
func extractedLeavesCarryOnlyTheirOwnDomainType() throws {
  let validate: ActionComponent<TestAction> = Action(.validate)
  let supported: ConditionComponent<TestCondition> = Condition(.isSupported)
  let tree = try BehaviorTree<TestAction, TestCondition>(name: "reused") {
    Sequence {
      validate
      supported
    }
  }

  #expect(tree.definition().root.children.count == 2)
}

@Test
func definitionPreservesParallelPolicyAndLifecycleRoles() throws {
  let action: ActionLifecycleComponent<TestAction> = Action(.analyze)
    .onLifecycle(success: .publish, cancel: .validate)
  let tree = try BehaviorTree<TestAction, TestCondition>(name: "roles") {
    Parallel(success: .atLeast(1), failure: .whenSuccessBecomesImpossible) {
      action
      Action(.publish)
    }
  }

  let definition = tree.definition()
  #expect(definition.root.attributes["successPolicy"] == .string("atLeast:1"))
  let lifecycle = definition.root.children[0]
  #expect(lifecycle.children.map(\.role) == [.wrapped, .onSuccess, .onCancel])
}

@Test
func graphvizEscapesLabelsAndDistinguishesLeafShapes() throws {
  let tree = try BehaviorTree<TestAction, TestCondition>(name: "graph") {
    Sequence("quoted \"root\"") {
      Condition(.needsAnalysis, named: "needs\nanalysis")
      Action(.analyze)
    }
  }

  let graph = tree.definition().graphviz()
  #expect(graph.contains("quoted \\\"root\\\""))
  #expect(graph.contains("needs\\nanalysis"))
  #expect(graph.contains("shape=ellipse"))
  #expect(graph.contains("shape=box"))
}
