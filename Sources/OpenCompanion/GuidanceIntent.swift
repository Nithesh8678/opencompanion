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
    let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
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
        ["no", "screenshot"], ["no", "screen", "capture"],
      ]
      if contains(["private"]) || privacyPhrases.contains(where: has) { return false }
    }
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
    let uiContext = contains(uiWords)
    let nearContext = contains(contextual)
    let appContext = words.enumerated().contains { index, word in
      apps.contains(word) && index > 0
        && ["in", "on", "using", "with", "open"].contains(words[index - 1])
    }

    if contains(pointerActions), uiContext || nearContext || contains(["where", "which"]) {
      if has(["show", "me"]) || has(["guide", "me"]) || has(["help", "me"])
        || contains(["where", "which"]) || pointerActions.contains(words[0])
        || (words[0] == "please" && words.count > 1 && pointerActions.contains(words[1]))
      {
        return true
      }
    }
    if contains(["diagram", "illustration", "poem", "story", "essay", "code"]),
      !uiContext && !appContext
    {
      return false
    }
    if has(["guide", "me"]), uiContext || nearContext || appContext { return true }
    if has(["help", "me"]), contains(actions), uiContext || nearContext || appContext {
      return true
    }
    if contains(["where", "which"]), uiContext { return true }

    let procedural =
      has(["how", "can", "i"]) || has(["how", "do", "i"]) || has(["how", "to"])
      || has(["show", "me", "how", "to"])
    if procedural, contains(actions), uiContext || nearContext || appContext { return true }
    return actions.contains(words[0]) && (uiContext || appContext)
  }
}
