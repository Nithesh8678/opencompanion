import Foundation
import Testing

@testable import OpenCompanion

struct GuidanceIntentTests {
  @Test(arguments: [
    "Can u tell me how to create a new table? Don’t screenshot.",
    "Can u tell me how to create a new table? Don't screenshot.",
    "How do I create a table? Do not screenshot.",
    "Check screen and help me add a column. Never screenshot.",
    "Help me create a folder without screenshotting.",
    "How do I create a table? No screenshotting.",
    "How do I create a table? This must not be screenshotted.",
    "How do I create a table? Don't take screenshots.",
    "How do I create a table? Don't screen-shot.",
    "How do I create a table? Do not screen shot.",
    "How do I create a table? I don't want this to be screen-shotted.",
    "How do I create a table without screen shots?",
  ])
  func trailingScreenshotActionRestrictionsOverrideEarlierGuidanceRequests(_ text: String) {
    #expect(!GuidanceIntent.requestsScreenGuidance(text: text))
  }

  @Test(arguments: [
    "Check screen and tell me why screenshot is not working",
    "Why is this screenshot not working?",
    "Check screen and explain the message ‘Don’t screenshot.’",
  ])
  func screenshotVocabularyDoesNotCreateAnUnrelatedOrQuotedPrivacyVeto(_ text: String) {
    #expect(GuidanceIntent.requestsScreenGuidance(text: text))
  }

  @Test(arguments: [
    "can u tell me how to create a new table",
    "Can you tell me how to create a new table?",
    "How do I create a new table?",
    "How to create a table",
    "Help me add a column",
    "Can u help me duplicate a file?",
    "How do I create a folder?",
    "Help me rename a document",
    "Show me how to open a project",
    "How can I import a spreadsheet?",
    "How do I check my profile?",
    "How do I start a new chat?",
    "Help me open the menu",
  ])
  func proceduralSoftwareTasksCanUseTheCurrentAppWithoutNamingIt(_ text: String) {
    #expect(GuidanceIntent.requestsScreenGuidance(text: text))
  }

  @Test(arguments: [
    "check screen and tell me how to create a new table",
    "check screen",
    "Can u check screen?",
    "Could you please inspect screen and show the next step?",
    "look at screen and show me where to click",
    "Look screen",
    "Take a look at screen and help me create a table",
    "Check out screen and tell me how to open a menu",
    "Analyze screen for the error",
    "Read screen",
    "Describe desktop",
    "Inspect this display now",
    "Check screen: how do I add a column?",
  ])
  func leadingScreenInspectionDoesNotRequireADeterminerOrAppName(_ text: String) {
    #expect(GuidanceIntent.requestsScreenGuidance(text: text))
  }

  @Test(arguments: [
    "Do not check screen and tell me how to create a new table",
    "Can u not check screen?",
    "Don't inspect screen. How do I create a table?",
    "Never tell me how to create a new table",
    "Don't tell me how to create a new table",
    "Check screen but do not capture anything",
    "No screenshot. Can u tell me how to create a new table?",
    "Text only. Check screen and tell me how to create a table",
    "Keep my screen private. Help me add a column",
    "What is a table?",
    "Explain how a multiplication table works",
    "How do I create a truth table?",
    "Help me create a multiplication table",
    "How do I create a wooden table?",
    "How do I create a table with wood?",
    "Help me build dining furniture",
    "How do I create a SQL table?",
    "Help me create a table in Python",
    "How do I create an HTML table?",
    "How can I create a table in LaTeX?",
    "Create a comparison table of the two options",
    "Write a tutorial about how to create a new table",
    "Write a tutorial about how to check the screen",
    "Explain the phrase check screen",
    "Explain screenshot compression",
    "Repeat ‘check screen and tell me how to create a new table’",
    "Translate \"can u tell me how to create a new table\" into Tamil",
    "\"can u tell me how to create a new table\"",
    "‘check screen and tell me how to create a new table’",
    "`How do I create a new table?`",
    "```\ncheck screen and tell me how to create a new table\n```",
  ])
  func implicitSoftwareTasksAndInspectionPreserveContentAndPrivacyBoundaries(_ text: String) {
    #expect(!GuidanceIntent.requestsScreenGuidance(text: text))
  }

  @Test(arguments: [
    "how to check my profile, in the current screen",
    "how to check my profile in the current screen",
    "How do I check my profile?",
    "Show my profile",
    "Where can I view my account?",
    "How do I access my account?",
    "Where is my avatar?",
    "How do I duplicate this?",
    "Can you help me duplicate this?",
    "Help me rename this file",
    "Walk me through renaming this document",
    "Guide me through exporting a PDF",
    "Walk me through saving a copy",
    "How do I change the theme?",
    "Help me enable dark mode",
    "How do I create a document in Obsidian?",
    "How do I create a chart in Excel?",
    "How do I recolor this arrow?",
    "Show me how to rename this label",
    "Guide me through moving the selected node",
    "How do I resize this?",
    "Guide me through resizing the window",
    "How can I zoom in here?",
    "Help me sort this table",
    "How do I go to the next page of this document?",
    "How do I move to the next page of this document?",
    "How do I proceed to the next page of this document?",
    "Point out the failed job on this screen.",
    "Highlight the failed job on this screen.",
    "Identify the error on this screen.",
  ])
  func genericCurrentUiGoalsDoNotDependOnAppNamesOrExactVerbInflections(_ text: String) {
    #expect(GuidanceIntent.requestsScreenGuidance(text: text))
  }

  @Test(arguments: [
    "What does this button do?",
    "What does this icon do?",
    "How does this button work?",
    "Why is this disabled?",
    "Why is that option greyed out?",
    "Explain the error on this screen",
    "Explain this chart",
    "What is this?",
    "What's this?",
    "What is that here?",
    "Summarize this screen",
    "Read the text on this screen",
    "Translate this screen into Tamil",
    "What does the ‘Sync’ button do?",
  ])
  func currentScreenQuestionsCanRequestGroundedExplanatoryMarks(_ text: String) {
    #expect(GuidanceIntent.requestsScreenGuidance(text: text))
  }

  @Test(arguments: [
    "Text only. What does this button do?",
    "Only in text, how do I check my profile?",
    "No visuals. Guide me through exporting a PDF",
    "Do not capture my screen. How do I duplicate this?",
    "Don't look at my screen. What is this?",
    "How do I check my profile without screenshots?",
    "Keep my screen private. What does this icon do?",
    "No screenshot. Walk me through saving a copy",
    "Translate ‘What does this button do?’ into Tamil",
    "Rewrite ‘how to check my profile in the current screen’",
    "Explain ‘How does this button work?’",
    "Is ‘What is this?’ a good question?",
    "Write a tutorial titled ‘How to export a PDF’",
    "Show me a conversation between Alice and Bob",
    "Help me start this motor",
    "Guide me through how a motor works",
    "What is this motor?",
    "Explain screenshot compression",
    "What is a screenshot?",
    "How do I create a database in SQL?",
    "Create an interactive motor diagram",
    "Walk me through creating a diagram of a motor",
    "How do I go about learning math?",
    "How do I go about learning this math topic?",
    "Point out flaws in this poem",
    "Highlight the problems in this essay",
    "Identify the metaphor in this poem",
    "Recolor the selected arrow red",
    "Rename this label",
    "Move the selected node to the left",
    "Change the selected label in this notebook",
    "Please resize this rectangle",
  ])
  func privacyAuthoredExamplesAndConceptualLearningDoNotGrantScreenAccess(_ text: String) {
    #expect(!GuidanceIntent.requestsScreenGuidance(text: text))
  }

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
