import Foundation
import Testing

@testable import OpenCompanion

struct GuidanceIntentTests {
  @Test(arguments: [
    "I want to create a new chat in ChatGPT",
    "Could you please open a new conversation in Chat GPT?",
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
    "How can I create a project in Obsidian?",
    "How do I add a record in Baserow?",
    "Guide me to create a board in Linear",
    "Can you create a new task in this app?",
  ])
  func recognizesRequestsForOnScreenHelp(_ text: String) {
    #expect(GuidanceIntent.requestsScreenGuidance(text: text))
  }

  @Test(arguments: [
    "how to create a new chat in ChatGPT",
    "How do I create a new chat in Chat GPT?",
    "How can I start a new conversation in ChatGPT?",
    "How do you open a new chat on Chat G P T?",
    "How do we begin a new conversation in Chat G.P.T.?",
    "How can I make a new chat on chat gbt?",
    "Show me how I can create a new conversation in Chat GPT.",
    "Show me how to start a new chat in chat g p tea.",
    "Show me where the new chat button is in ChatGPT.",
    "Show me the new chat button.",
    "Can you show me a new chat button?",
    "Help me start a new conversation here.",
    "How to start a new chat",
    "Start a new chat in ChatGPT",
    "Chat GPT, show me how to create a new chat.",
    "Could you show me how to open a new chat?",
    "How do I open ChatGPT?",
  ])
  func chatGPTNewChatRequestsAndDictationVariantsRequestGuidance(_ text: String) {
    #expect(GuidanceIntent.requestsScreenGuidance(text: text))
  }

  @Test(arguments: [
    "How does ChatGPT work?",
    "Why does ChatGPT create new chats?",
    "Explain the difference between a new chat and a project in ChatGPT.",
    "What does ‘new chat’ mean in ChatGPT?",
    "Create an example of a new chat in ChatGPT.",
    "Create a diagram of ChatGPT conversation history.",
    "How do I create a poem in ChatGPT?",
    "How do I create a chatbot using ChatGPT?",
    "How do I create an API conversation in Python?",
    "How can I start a new conversation with a stranger?",
    "How can I start this motor?",
    "Show me a new chat between Alice and Bob.",
    "Show me why the new chat button is useful.",
    "Translate 'how to create a new chat in ChatGPT' into Tamil.",
    "Please repeat ‘show me the new chat button in Chat GPT’.",
    "Can you rewrite ‘how to create a new chat in ChatGPT’ more clearly?",
    "Explain 'how to create a new chat in ChatGPT'.",
    "Is ‘How do I start a new chat in ChatGPT?’ a good question?",
    "Write a tutorial titled ‘How to create a new chat in ChatGPT’.",
    "How can I create a new chat in ChatGPT without screenshots?",
    "Do not inspect my screen. Show me how to start a new chat in Chat GPT.",
    "Don't read my screen; how can I create a new chat in ChatGPT?",
  ])
  func chatGPTExplanationsContentQuotationAndPrivacyStayConversational(_ text: String) {
    #expect(!GuidanceIntent.requestsScreenGuidance(text: text))
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
    "How do I create a folder in my essay?",
    "How do I create a table in Python? Write code.",
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
