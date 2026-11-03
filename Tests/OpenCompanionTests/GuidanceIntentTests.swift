import Foundation
import Testing

@testable import OpenCompanion

struct GuidanceIntentTests {
  @Test(arguments: [
    "How can I create a table in Supabase?",
    "Show me where to click",
    "Help me open this",
    "Click here",
    "Guide me through this screen",
    "Which button on this screen should I press?",
    "Help me find the export option in this window.",
    "Where is the save button?",
    "How do I add a column in Supabase?",
    "Please click that button",
    "SHOW ME WHERE TO CLICK!",
    "Show me how to open this dropdown",
  ])
  func recognizesRequestsForOnScreenHelp(_ text: String) {
    #expect(GuidanceIntent.requestsScreenGuidance(text: text))
  }

  @Test(arguments: [
    "Why does the Moon have phases?",
    "How does a motor work?",
    "Create a diagram of a motor",
    "Explain how databases work",
    "Show me how a motor works",
    "How do I create a SQL table?",
    "Where does this function get called?",
    "What does ‘click here’ mean?",
    "Explain the phrase ‘show me where to click’",
    "Help me understand the Moon",
    "Please create a poem about this",
    "How can I create a diagram of this motor?",
    "Help me create a diagram of this motor",
    "What is Supabase?",
    "The word clickhere is not a command",
    "",
    "   \n\t",
    "இந்த மோட்டார் எப்படி வேலை செய்கிறது?",
  ])
  func conceptualQuestionsAndQuotedPhrasesDoNotRequestCapture(_ text: String) {
    #expect(!GuidanceIntent.requestsScreenGuidance(text: text))
  }

  @Test(arguments: [
    "Do not capture my screen. How can I create a table in Supabase?",
    "Don't share my screen; show me where to click.",
    "Guide me through this screen without capturing it.",
    "No screenshot. Help me open this.",
    "Please don't take a screenshot. Show me where to click.",
    "Keep my screen private. Guide me through this window.",
  ])
  func explicitScreenPrivacyInstructionsTakePrecedence(_ text: String) {
    #expect(!GuidanceIntent.requestsScreenGuidance(text: text))
  }

  @Test func byteLimitIsExactAndOversizeInputIsRejectedInsteadOfTruncated() {
    let command = "Show me where to click"
    let exact = command + String(repeating: " ", count: 32_000 - command.utf8.count)
    #expect(exact.utf8.count == GuidanceIntent.maximumTextBytes)
    #expect(GuidanceIntent.requestsScreenGuidance(text: exact))
    #expect(!GuidanceIntent.requestsScreenGuidance(text: exact + "x"))
    let multibyte = command + String(repeating: "🙂", count: 8_000)
    #expect(multibyte.count < GuidanceIntent.maximumTextBytes)
    #expect(!GuidanceIntent.requestsScreenGuidance(text: multibyte))
  }

  @Test func oldPreferencesPreserveBothExistingChoicesAndDefaultGuidanceOn() throws {
    for enabled in [false, true] {
      for showReplies in [false, true] {
        let data = try JSONSerialization.data(withJSONObject: [
          "enabled": enabled, "showReplies": showReplies,
        ])
        let decoded = try JSONDecoder().decode(CursorCompanionPreferences.self, from: data)
        #expect(decoded.enabled == enabled)
        #expect(decoded.showReplies == showReplies)
        #expect(decoded.screenGuidanceEnabled)
      }
    }
  }

  @Test func guidancePreferenceRoundTripsIndependentlyAndMissingValuesDefaultOn() throws {
    let configured = CursorCompanionPreferences(
      enabled: false, showReplies: true, screenGuidanceEnabled: false)
    let roundTrip = try JSONDecoder().decode(
      CursorCompanionPreferences.self, from: JSONEncoder().encode(configured))
    #expect(roundTrip == configured)
    let missing = try JSONDecoder().decode(CursorCompanionPreferences.self, from: Data("{}".utf8))
    #expect(missing == CursorCompanionPreferences())
    let partial = try JSONDecoder().decode(
      CursorCompanionPreferences.self, from: Data(#"{"showReplies":false}"#.utf8))
    #expect(partial.enabled && !partial.showReplies && partial.screenGuidanceEnabled)
  }
}
