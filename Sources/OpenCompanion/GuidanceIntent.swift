import Foundation

/// A bounded English heuristic, not language understanding or permission to act.
/// A positive result requests one screen-evidence capture; it never authorizes
/// continuous observation, clicks, file access, or sending retained evidence.
enum GuidanceIntent {
  static let maximumTextBytes = 32_000

  static func requestsScreenGuidance(text: String) -> Bool {
    // Reject oversize input rather than classify a prefix that could omit a
    // later instruction to keep the screen private.
    guard text.utf8.prefix(maximumTextBytes + 1).count <= maximumTextBytes else { return false }
    let words = normalizeAppNames(
      text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    guard !words.isEmpty else { return false }
    let vocabulary = Set(words)
    func has(_ phrase: [String]) -> Bool {
      guard words.count >= phrase.count else { return false }
      return words.indices.prefix(words.count - phrase.count + 1).contains { start in
        words[start..<(start + phrase.count)].elementsEqual(phrase)
      }
    }
    func contains(_ choices: Set<String>) -> Bool { !vocabulary.isDisjoint(with: choices) }

    let screenWords: Set<String> = ["screen", "desktop", "display", "screenshot", "screenshots"]
    if contains(screenWords) {
      let privacyPhrases: [[String]] = [
        ["do", "not", "capture"], ["don", "t", "capture"], ["dont", "capture"],
        ["do", "not", "share"], ["don", "t", "share"], ["dont", "share"],
        ["do", "not", "look"], ["don", "t", "look"], ["dont", "look"],
        ["do", "not", "take"], ["don", "t", "take"], ["dont", "take"],
        ["do", "not", "record"], ["don", "t", "record"], ["dont", "record"],
        ["without", "capturing"], ["without", "sharing"], ["without", "looking"],
        ["without", "taking"], ["without", "seeing"], ["without", "reading"],
        ["without", "screenshots"], ["without", "a", "screenshot"],
        ["no", "screenshot"], ["no", "screenshots"], ["no", "screen", "capture"],
      ]
      let negated = has(["do", "not"]) || has(["don", "t"]) || contains(["dont"])
      let screenAccess = contains([
        "capture", "share", "look", "take", "record", "inspect", "access", "read", "view", "see",
      ])
      if contains(["private"]) || privacyPhrases.contains(where: has) || (negated && screenAccess) {
        return false
      }
    }
    // A request to translate/repeat/write tutorial wording is not a request to
    // inspect the application described inside that wording.
    let politePrefix: Set<String> = [
      "please", "can", "could", "would", "will", "you", "i", "want", "to", "just", "kindly",
    ]
    let leadingRequest = words.drop(while: { politePrefix.contains($0) }).first
    let contentRequests: Set<String> = [
      "translate", "rewrite", "rephrase", "proofread", "summarize", "summarise", "quote",
      "repeat", "say", "pronounce", "define", "paraphrase", "write",
    ]
    if let leadingRequest, contentRequests.contains(leadingRequest) { return false }
    if contains(["phrase", "sentence", "wording", "quote", "quoted", "transcript", "titled"]) {
      return false
    }
    let hasQuotation =
      text.contains("\"") || text.contains("“") || text.contains("‘")
      || text.lazy.filter { $0 == "'" }.prefix(2).count == 2
    if hasQuotation, leadingRequest == "explain" || contains(["question"]) { return false }
    if has(["show", "me", "why"]) { return false }
    // Discussing a tutorial phrase is different from asking to perform it.
    if contains(["mean", "means", "meaning", "phrase", "word", "wording"]),
      has(["what", "does"]) || has(["what", "is"]) || words.first == "define"
        || words.first == "explain"
    {
      return false
    }

    let uiWords: Set<String> = [
      "screen", "desktop", "window", "app", "button", "menu", "dropdown", "dialog",
      "toolbar", "sidebar", "tab", "link", "checkbox", "toggle", "settings", "option",
      "export", "import", "dashboard", "interface",
    ]
    let contextual: Set<String> = ["this", "that", "here", "there", "current"]
    let actions: Set<String> = [
      "open", "find", "create", "add", "insert", "delete", "remove", "change", "edit",
      "save", "export", "import", "upload", "download", "connect", "configure", "enable",
      "disable", "select", "choose", "navigate", "click", "press", "tap",
    ]
    let pointerActions: Set<String> = ["click", "press", "tap", "select", "choose"]
    let apps: Set<String> = [
      "supabase", "notion", "excel", "sheets", "figma", "canva", "airtable", "github",
      "slack", "finder", "safari", "chrome", "vscode", "xcode",
    ]
    let chatGPT = contains(["chatgpt"])
    let newChat = has(["new", "chat"]) || has(["new", "chats"])
    let newConversation = has(["new", "conversation"]) || has(["new", "conversations"])
    let chatInterface =
      chatGPT
      && contains([
        "chat", "chats", "conversation", "conversations", "history", "project", "projects",
      ])
    let explicitUIContext = contains(uiWords)
    let uiContext = explicitUIContext || newChat
    let nearContext = contains(contextual)
    let knownAppContext = words.enumerated().contains { index, word in
      apps.contains(word) && index > 0
        && ["in", "on", "using", "with", "open"].contains(words[index - 1])
    }
    let chatGPTContext =
      chatGPT && (chatInterface || explicitUIContext || contains(["open", "launch"]))
    let appContext = knownAppContext || chatGPTContext
    let chatActions: Set<String> = ["start", "begin", "make"]
    let actionRequested =
      contains(actions)
      || (contains(chatActions)
        && (uiContext || appContext || (newConversation && nearContext)))

    if contains(pointerActions), uiContext || nearContext || contains(["where", "which"]) {
      if has(["show", "me"]) || has(["guide", "me"]) || has(["help", "me"])
        || contains(["where", "which"]) || pointerActions.contains(words[0])
        || (words[0] == "please" && words.count > 1 && pointerActions.contains(words[1]))
      {
        return true
      }
    }
    let authoredContent =
      contains([
        "diagram", "illustration", "poem", "story", "essay", "code", "script", "article",
        "tutorial", "prompt", "email", "example", "sample",
      ]) || has(["chat", "between"]) || has(["conversation", "between"])
    if authoredContent, chatGPT || (!explicitUIContext && !knownAppContext) {
      return false
    }
    if has(["guide", "me"]), uiContext || nearContext || appContext { return true }
    if has(["help", "me"]), actionRequested, uiContext || nearContext || appContext {
      return true
    }
    if contains(["where", "which"]), uiContext { return true }
    if has(["show", "me"]), uiContext || nearContext || appContext {
      if actionRequested
        || contains(["button", "menu", "dropdown", "toolbar", "sidebar", "settings", "option"])
      {
        return true
      }
    }

    let procedural =
      has(["how", "can", "i"]) || has(["how", "do", "i"]) || has(["how", "to"])
      || has(["how", "can", "you"]) || has(["how", "do", "you"])
      || has(["how", "can", "we"]) || has(["how", "do", "we"])
      || has(["how", "should", "i"]) || has(["how", "would", "i"])
    if procedural, actionRequested, uiContext || nearContext || appContext { return true }
    let requestedAction = leadingRequest ?? words[0]
    return (actions.contains(requestedAction) || chatActions.contains(requestedAction))
      && (uiContext || appContext)
  }

  /// Collapse only known spoken spellings, not arbitrary words beginning with
  /// "chat". All scans remain inside the already bounded input token array.
  private static func normalizeAppNames(_ words: [String]) -> [String] {
    let spellings = [
      ["chat", "g", "p", "tea"], ["chat", "g", "p", "t"],
      ["chat", "gpt"], ["chat", "gbt"], ["chat", "g", "pt"],
    ]
    var result: [String] = []
    result.reserveCapacity(words.count)
    var index = 0
    while index < words.count {
      if let spelling = spellings.first(where: {
        index + $0.count <= words.count
          && words[index..<(index + $0.count)].elementsEqual($0)
      }) {
        result.append("chatgpt")
        index += spelling.count
      } else {
        result.append(words[index])
        index += 1
      }
    }
    return result
  }
}
