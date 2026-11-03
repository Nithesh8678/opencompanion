import Foundation
import Testing

@testable import OpenCompanion

struct ResponsePolicyTests {
  private func policy(
    _ text: String, screenEnabled: Bool = true, explicit: Bool = false,
    inNotebook: Bool = false, hasNotebook: Bool = false
  ) -> ResponsePolicy {
    ResponsePolicy.resolve(
      text: text, screenGuidanceEnabled: screenEnabled, explicitGuidance: explicit,
      inNotebook: inNotebook, hasNotebook: hasNotebook)
  }

  @Test(arguments: [
    "How to create a new chat in ChatGPT?",
    "How do I create a new chat in ChatGPT?",
    "I want to create a new chat in ChatGPT",
    "Help me open this dropdown",
    "Show me where to click",
    "How do I create a chart in Excel?",
  ])
  func currentUIHelpHasPriorityOverDecorativeNotebook(_ text: String) {
    let result = policy(text, inNotebook: true, hasNotebook: true)
    #expect(result.route == .screenGuidance)
    #expect(!result.allowsNotebook)
    #expect(!result.includesExistingNotebook)
    #expect(policy(text, screenEnabled: false).route == .conversation)
  }

  @Test(arguments: [
    "Why does the Moon have phases?",
    "What is 2 + 2?",
    "Solve x + 4 = 9",
    "What is a diagram?",
    "What are flowcharts?",
    "Define notebook",
    "Explain what a chart is",
    "Explain this diagram",
    "I draw diagrams for work",
    "A diagram could be interesting",
    "I want to know what a diagram is",
    "Write a poem about light",
    "Teach me how to write an email",
    "Explain how to write a poem",
    "Repeat ‘draw a diagram of a motor’",
    "Explain the sentence \"show me where to click\"",
    "What does ‘plot y=x squared’ mean?",
    "இந்த மோட்டார் எப்படி வேலை செய்கிறது?",
    "",
    "   \n\t",
  ])
  func factsQuotedInstructionsAndMerelyVisualVocabularyStayConversational(_ text: String) {
    let result = policy(text, hasNotebook: true)
    #expect(result.route == .conversation)
    #expect(!result.includesExistingNotebook)
  }

  @Test(arguments: [
    "Draw a diagram of a simplified DC motor",
    "Create a chart comparing the two values",
    "Plot y = x squared",
    "Graph y = sin(x)",
    "Please draw a number line",
    "Could you sketch a circuit?",
    "Show me a flowchart of this algorithm",
    "Explain gravity with a diagram",
    "Explain this visually",
    "Create a notebook about planetary orbits",
    "I want a diagram of the water cycle",
    "Draw a diagram of what is happening",
    "Draw a diagram labeled ‘text only’",
  ])
  func explicitVisualRequestsPermitButDoNotRequireANotebook(_ text: String) {
    let result = policy(text, hasNotebook: true)
    #expect(result.route == .notebook)
    #expect(result.allowsNotebook)
    #expect(!result.includesExistingNotebook)
    #expect(result.instructions.contains("not mandatory"))
  }

  @Test(arguments: [
    "How does a motor work?",
    "Explain how a lever works",
    "Show me how a motor works",
    "How do forces cause motion?",
    "Why does a wheel rotate?",
    "Teach me the relationship between force and torque",
  ])
  func mechanismTeachingCanUseAHelpfulSceneWithoutBindingRetainedWork(_ text: String) {
    let result = policy(text, inNotebook: true, hasNotebook: true)
    #expect(result.route == .notebook)
    #expect(!result.includesExistingNotebook)
    #expect(result.instructions.contains("only if it materially helps"))
  }

  @Test(arguments: [
    "Explain how a motor works, text only",
    "Draw a diagram, but answer only in text",
    "No visuals. Teach me about forces",
    "Explain how a motor works without diagrams",
    "Explain how a motor works. No diagram please",
    "Don't draw a diagram. Explain how the motor works",
    "Do not open a notebook. Teach me about forces",
    "Explain how a motor works without a diagram",
    "I need plain text explaining how a motor works",
  ])
  func explicitPresentationOptOutOverridesLearningAndVisualKeywords(_ text: String) {
    #expect(policy(text, inNotebook: true, hasNotebook: true).route == .conversation)
  }

  @Test(arguments: [
    "Do not capture my screen. How to create a new chat in ChatGPT?",
    "Don't share my screen. Help me open this dropdown",
    "No screenshot. Show me where to click",
    "Keep my screen private. Guide me through this window",
    "Guide me without capturing anything",
    "Help with this screen without a screenshot",
    "Do not access my screen. Help create a new chat in ChatGPT",
  ])
  func privacyBlocksEvenAnExplicitGuidanceOperation(_ text: String) {
    let result = policy(text, explicit: true, inNotebook: true, hasNotebook: true)
    #expect(result.route == .conversation)
    #expect(!result.allowsNotebook)
  }

  @Test func forcedGuidanceStillRequiresEnabledScreenHelpAndRespectsTextOnly() {
    #expect(policy("Help with the next step", explicit: true).route == .screenGuidance)
    #expect(
      policy("Help with the next step", screenEnabled: false, explicit: true).route == .conversation
    )
    #expect(policy("Explain how a motor works, text only", explicit: true).route == .conversation)
    // With no capture operation, refusing a screenshot does not forbid an
    // independently requested conceptual drawing.
    #expect(policy("No screenshot. Draw a diagram of a lever").route == .notebook)
  }

  @Test(arguments: [
    "No screenshot. Draw a diagram of a lever",
    "Do not capture my screen; please draw a cat",
    "Keep my screen private: plot y=x squared",
    "No screenshot, could you sketch a circuit?",
    "Don't capture my screen. Don't share my screen. Draw a diagram of a motor",
  ])
  func privacyPrefaceDoesNotEraseAnIndependentVisualRequest(_ text: String) {
    let result = policy(text)
    #expect(result.route == .notebook)
    #expect(!result.includesExistingNotebook)
  }

  @Test(arguments: [
    "No screenshot. No diagram. Draw a cat",
    "No screenshot. Text only. Explain how a motor works",
    "No screenshot. Repeat ‘draw a diagram of a lever’",
    "No screenshot. I sometimes draw diagrams for work",
    "No screenshot. Help me create a new chat in ChatGPT",
  ])
  func privacyClauseHandlingPreservesNegativeQuotedAndContextBoundaries(_ text: String) {
    #expect(policy(text).route == .conversation)
  }

  @Test func privacyPrefaceStillRequiresActualNotebookContextForAnEdit() {
    let text = "Do not capture my screen. Recolor the selected arrow red"
    #expect(policy(text, inNotebook: true, hasNotebook: true).includesExistingNotebook)
    #expect(policy(text, hasNotebook: true).route == .conversation)
  }

  @Test(arguments: [
    "Recolor the selected arrow red",
    "Make it red",
    "Rename this label",
    "Move the selected node to the left",
    "Change the title of the notebook",
  ])
  func retainedNotebookRequiresBothCurrentContextAndClearEditIntent(_ text: String) {
    let editing = policy(text, inNotebook: true, hasNotebook: true)
    #expect(editing.route == .notebook)
    #expect(editing.includesExistingNotebook)
    #expect(!policy(text, hasNotebook: true).includesExistingNotebook)
    #expect(!policy(text, inNotebook: true, hasNotebook: false).includesExistingNotebook)
  }

  @Test func retainedNotebookAndStickyNavigationNeverAuthorizeAnUnrelatedTurn() {
    let unrelated = policy("What is 2 + 2?", inNotebook: true, hasNotebook: true)
    #expect(unrelated.route == .conversation)
    #expect(!unrelated.allowsNotebook)
    let descriptive = policy("Explain this diagram", inNotebook: true, hasNotebook: true)
    #expect(descriptive.route == .conversation)
    let outside = policy("Recolor the selected arrow red", hasNotebook: true)
    #expect(outside.route == .conversation)
    #expect(!outside.includesExistingNotebook)
  }

  @Test func inputBudgetRejectsTheWholeRequestInsteadOfClassifyingItsPrefix() {
    let command = "Draw a diagram of a motor"
    let exact =
      command + String(repeating: " ", count: ResponsePolicy.maximumTextBytes - command.utf8.count)
    #expect(exact.utf8.count == 32_000)
    #expect(policy(exact).allowsNotebook)
    #expect(policy(exact + "x", explicit: true).route == .conversation)
    #expect(policy(command + String(repeating: "🙂", count: 8_000)).route == .conversation)
  }

  @Test func longUnmatchedQuotesRemainInsideTheWholeInputWorkBudget() {
    for quote in ["‘", "“"] {
      let text = String(repeating: quote, count: 10_000)
      #expect(text.utf8.count == 30_000)
      #expect(policy(text).route == .conversation)
    }
    #expect(policy("Don't draw a diagram. Explain how a motor works").route == .conversation)
    #expect(policy("Repeat 'don't draw a diagram'").route == .conversation)
  }

  @Test func immutablePolicyContainsOnlyCurrentTurnCapabilities() {
    let current = policy("What is 2 + 2?")
    _ = policy("Draw a diagram of a motor")
    #expect(current == policy("What is 2 + 2?"))
    #expect(current.instructions.contains("Do not output scene units"))
    let guidance = policy("Help with this screen", explicit: true)
    #expect(guidance.instructions.contains("grounded target"))
    #expect(guidance.instructions.contains("Do not output scene units"))
  }
}
