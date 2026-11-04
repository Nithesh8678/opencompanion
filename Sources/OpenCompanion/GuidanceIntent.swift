import Foundation

/// A bounded English heuristic, not language understanding or permission to act.
/// A positive result requests one screen-evidence capture; it never authorizes
/// continuous observation, clicks, file access, or sending retained evidence.
enum GuidanceIntent {
  static let maximumTextBytes = 32_000

  static func requestsScreenGuidance(text: String) -> Bool {
    // Never classify a truncated prefix that could omit a later privacy choice.
    guard text.utf8.prefix(maximumTextBytes + 1).count <= maximumTextBytes else { return false }
    let request = outsideQuotedContent(text)
    let words = normalizeAppNames(
      request.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    guard !words.isEmpty else { return false }
    let vocabulary = Set(words)
    func has(_ phrase: [String]) -> Bool {
      guard words.count >= phrase.count else { return false }
      return words.indices.prefix(words.count - phrase.count + 1).contains { start in
        words[start..<(start + phrase.count)].elementsEqual(phrase)
      }
    }
    func contains(_ choices: Set<String>) -> Bool { !vocabulary.isDisjoint(with: choices) }

    let textOnly: [[String]] = [
      ["text", "only"], ["only", "text"], ["just", "text"], ["plain", "text"],
      ["only", "in", "text"], ["answer", "with", "text"], ["respond", "with", "text"],
      ["words", "only"], ["only", "words"], ["answer", "in", "words"],
      ["no", "visuals"], ["without", "visuals"], ["without", "any", "visuals"],
    ]
    if textOnly.contains(where: has) { return false }
    let privacy: [[String]] = [
      ["no", "screenshot"], ["no", "screenshots"], ["no", "screen"],
      ["no", "capture"], ["without", "screenshots"], ["without", "a", "screenshot"],
      ["without", "any", "screenshots"], ["without", "screen", "access"],
      ["screen", "private"], ["desktop", "private"], ["display", "private"],
    ]
    if privacy.contains(where: has) { return false }
    let screenObjects: Set<String> = ["screen", "desktop", "display", "screenshot", "screenshots"]
    for index in words.indices {
      let negation =
        ["not", "never", "dont", "without"].contains(words[index])
        || words[index] == "t" && index > 0 && words[index - 1] == "don"
      guard negation else { continue }
      let nearby = Set(words[(index + 1)..<min(words.count, index + 8)])
      // Explicit capture/record restrictions remain conservative.
      if !nearby.isDisjoint(with: ["capture", "capturing", "record", "recording"]) {
        return false
      }
      if !nearby.isDisjoint(with: screenObjects),
        !nearby.isDisjoint(with: [
          "share", "sharing", "look", "looking", "take", "taking", "inspect", "inspecting",
          "access", "accessing", "read", "reading", "view", "viewing", "see", "seeing",
        ])
      {
        return false
      }
    }

    let polite: Set<String> = [
      "please", "can", "could", "would", "will", "you", "i", "want", "need", "to", "just", "kindly",
    ]
    let leading = words.drop(while: { polite.contains($0) }).first ?? words[0]
    let current: Set<String> = ["this", "that", "here", "there", "current", "selected"]
    let near = contains(current)
    let explicitScreen = words.enumerated().contains { index, word in
      screenObjects.contains(word)
        && (near || index > 0 && ["my", "your", "the", "on", "current"].contains(words[index - 1]))
    }
    let uiObjects: Set<String> = [
      "window", "app", "application", "button", "menu", "dropdown", "dialog", "toolbar",
      "sidebar", "tab", "link", "checkbox", "toggle", "settings", "preferences", "option",
      "dashboard", "interface", "theme", "profile", "avatar", "account", "notification",
      "notifications", "permission", "permissions", "shortcut", "cursor", "selection",
      "login", "logout", "password", "username", "pdf", "export", "import", "icon", "control",
      "panel", "modal", "popover", "field", "input", "form", "setting", "resolution",
    ]
    let newConversation =
      has(["new", "conversation"])
      && (near || contains(["chatgpt", "app", "application", "window", "screen", "tab"]))
    let uiContext =
      explicitScreen || contains(uiObjects) || has(["dark", "mode"])
      || has(["light", "mode"]) || has(["new", "chat"]) || newConversation
    let softwareObjects: Set<String> = [
      "workspace", "workspaces", "project", "projects", "record", "records", "database",
      "databases", "table", "tables", "column", "columns", "folder", "folders", "repository",
      "repositories", "board", "boards", "spreadsheet", "spreadsheets", "note", "notes",
      "document", "documents", "file", "files", "page", "pages", "task", "tasks",
      "chart", "charts", "graph", "graphs",
    ]
    let technicalContent = contains([
      "python", "javascript", "typescript", "swift", "sql", "algorithm", "pseudocode",
    ])
    let namedSoftwareContext =
      !technicalContent && contains(softwareObjects)
      && words.enumerated().contains { index, word in
        ["in", "on", "using", "with"].contains(word) && index + 1 < words.count
          && !["a", "an", "the", "my", "our", "your", "this", "that", "life", "general", "theory"]
            .contains(words[index + 1])
      }

    // These guards describe the user's requested output, not words found inside
    // evidence. They keep authored tutorials, science lessons and quoted examples
    // from granting screen access accidentally.
    let contentLead: Set<String> = [
      "translate", "rewrite", "rephrase", "proofread", "summarize", "summarise", "quote",
      "repeat", "say", "pronounce", "define", "paraphrase", "write",
    ]
    let screenReadingRequest =
      explicitScreen
      || near
        && contains([
          "button", "menu", "dialog", "error", "warning", "chart", "table", "selection", "text",
        ])
    if contentLead.contains(leading), !screenReadingRequest { return false }
    if contains(["phrase", "sentence", "wording", "quote", "quoted", "transcript", "titled"])
      || has(["show", "me", "why"]) || has(["difference", "between"])
    {
      return false
    }
    if contains(["mean", "means", "meaning"]), !near && !explicitScreen { return false }
    if has(["chat", "between"]) || has(["conversation", "between"]) { return false }
    let authored = contains([
      "diagram", "illustration", "poem", "story", "essay", "code", "script", "article",
      "tutorial", "prompt", "email", "example", "sample",
    ])
    if authored, !uiContext { return false }
    if authored, contains(["chatgpt"]), !explicitScreen, !near { return false }
    if technicalContent, !uiContext, !explicitScreen { return false }
    if contains(["motor", "engine", "circuit", "lever"]), !uiContext, !namedSoftwareContext {
      return false
    }
    if screenReadingRequest,
      ["translate", "summarize", "summarise", "read", "describe", "explain"].contains(leading)
    {
      return true
    }

    let actions: Set<String> = [
      "open", "find", "create", "add", "insert", "delete", "remove", "change", "edit", "save",
      "export", "import", "upload", "download", "connect", "configure", "enable", "disable",
      "select", "choose", "navigate", "click", "press", "tap", "duplicate", "rename", "resize",
      "copy", "cut", "paste", "move", "zoom", "undo", "redo", "search", "sort", "filter",
      "print", "scroll", "share", "expand", "collapse", "pin", "unpin", "manage", "switch",
      "close", "install", "launch", "attach", "detach", "hide", "show", "format", "render",
      "rotate", "focus", "reset", "submit", "type", "drag", "drop", "check", "uncheck",
      "view", "access", "see", "visit", "start", "begin", "make", "record",
      "go", "proceed", "point", "highlight", "identify",
      "recolor", "recolour", "color", "colour", "update", "adjust", "replace", "reverse", "flip",
    ]
    func actionRoot(_ word: String) -> String? {
      if actions.contains(word) { return word }
      for suffix in ["ing", "ed", "es", "s"]
      where word.hasSuffix(suffix) && word.count > suffix.count {
        let stem = String(word.dropLast(suffix.count))
        if actions.contains(stem) { return stem }
        if actions.contains(stem + "e") { return stem + "e" }
        if stem.count > 1, stem.last == stem.dropLast().last,
          actions.contains(String(stem.dropLast()))
        {
          return String(stem.dropLast())
        }
      }
      return nil
    }
    let requestedActions = Set(words.compactMap(actionRoot))
    let actionRequested = !requestedActions.isEmpty
    let procedural = [
      ["how", "can", "i"], ["how", "do", "i"], ["how", "to"], ["how", "can", "you"],
      ["how", "do", "you"], ["how", "can", "we"], ["how", "do", "we"],
      ["how", "should", "i"], ["how", "would", "i"],
    ].contains(where: has)
    let guide = has(["guide", "me"]) || has(["walk", "me", "through"])
    let artifact = contains([
      "arrow", "arrows", "node", "nodes", "label", "labels", "shape", "shapes", "rectangle",
      "ellipse", "line", "diagram", "drawing", "notebook", "canvas",
    ])
    let artifactEdit = !requestedActions.isDisjoint(with: [
      "recolor", "recolour", "color", "colour", "rename", "resize", "move", "rotate", "remove",
      "delete", "replace", "change", "edit", "update", "add", "make", "reverse", "flip", "adjust",
    ])
    // Direct retained-artifact edits are never permission to inspect the desktop.
    // ResponsePolicy separately requires an actual active notebook to apply them.
    // An explicit how-to/guide or external UI context still requests guidance.
    if artifact, artifactEdit, !procedural, !guide, !uiContext, !namedSoftwareContext {
      return false
    }
    let pointerActions: Set<String> = ["click", "press", "tap", "select", "choose"]
    if !requestedActions.isDisjoint(with: pointerActions),
      contains(["where", "which"]) || near || uiContext || pointerActions.contains(leading)
        || has(["show", "me"]) || has(["guide", "me"]) || has(["help", "me"])
    {
      return true
    }
    let helping = has(["help", "me"]) || has(["show", "me"])
    let querying =
      ["what", "why", "where", "which", "explain", "describe"].contains(leading)
      || words.first == "what" || words.first == "why"
      || has(["how", "does"]) || has(["how", "do"])
    // A UI question can request a mark without requesting a click. In contrast,
    // "How does a motor work?" has no UI object or exact deictic question.
    let specificControl =
      contains(["the", "my", "your"])
      && contains([
        "button", "menu", "dropdown", "dialog", "toolbar", "sidebar", "settings", "preferences",
        "profile", "avatar", "account", "theme", "option",
      ])
    if querying, explicitScreen || screenReadingRequest || near && uiContext || specificControl {
      return true
    }
    if contains(["where", "which"]), uiContext { return true }
    if has(["what", "is", "this"]) || has(["what", "is", "that"])
      || has(["what", "s", "this"]) || has(["what", "s", "that"])
    {
      let substantive = words.filter {
        !["what", "is", "s", "this", "that", "here", "there", "please"].contains($0)
      }
      if substantive.isEmpty { return true }
    }
    if near, querying, contains(["disabled", "enabled", "greyed", "grayed", "error", "warning"]) {
      return true
    }
    if guide, actionRequested, !authored { return true }
    if guide, uiContext || namedSoftwareContext || near && !authored { return true }
    if helping, uiContext || namedSoftwareContext || near,
      actionRequested || screenReadingRequest
    {
      return true
    }
    if procedural, actionRequested, uiContext || namedSoftwareContext { return true }
    if procedural, near, contains(softwareObjects),
      !requestedActions.isDisjoint(with: ["go", "move", "proceed"])
    {
      return true
    }
    // Preserve spoken assistant launch requests without using a product list to
    // dispatch ordinary UI goals. Other named apps use explicit app/UI context.
    if procedural, contains(["chatgpt"]), !requestedActions.isDisjoint(with: ["open", "launch"]) {
      return true
    }
    let softwareDeicticActions: Set<String> = [
      "duplicate", "rename", "resize", "copy", "cut", "paste", "zoom", "undo", "redo",
      "export", "import", "upload", "download", "scroll", "select", "choose", "click",
      "press", "tap", "drag", "drop", "save", "print", "check", "view", "access", "visit",
      "move", "highlight", "identify", "point",
      "recolor", "recolour", "color", "colour", "update", "adjust", "replace", "rotate",
    ]
    if procedural, near, !requestedActions.isDisjoint(with: softwareDeicticActions) { return true }
    if helping, near, actionRoot(leading) == nil,
      !requestedActions.isDisjoint(with: ["open", "find", "create", "add"])
    {
      return true
    }
    let imperative = actionRoot(leading) != nil
    return imperative && (uiContext || namedSoftwareContext || near && !authored)
  }

  /// Remove paired quoted examples in linear work. Apostrophes inside words
  /// remain available for privacy contractions such as "don't".
  private static func outsideQuotedContent(_ text: String) -> String {
    let characters = Array(text)
    let closers: Set<Character> = ["\"", "”", "’", "'"]
    var remaining: [Character: Int] = [:]
    for character in characters where closers.contains(character) {
      remaining[character, default: 0] += 1
    }
    var result = ""
    var closing: Character?
    for index in characters.indices {
      let character = characters[index]
      if closers.contains(character) { remaining[character, default: 0] -= 1 }
      let previousWord =
        index > 0 && (characters[index - 1].isLetter || characters[index - 1].isNumber)
      let nextWord =
        index + 1 < characters.count
        && (characters[index + 1].isLetter || characters[index + 1].isNumber)
      if let delimiter = closing {
        if character == delimiter,
          !((delimiter == "'" || delimiter == "’") && previousWord && nextWord)
        {
          closing = nil
        }
        result.append(" ")
        continue
      }
      let delimiter: Character?
      switch character {
      case "\"": delimiter = "\""
      case "“": delimiter = "”"
      case "‘": delimiter = "’"
      case "'" where !previousWord: delimiter = "'"
      default: delimiter = nil
      }
      if let delimiter, remaining[delimiter, default: 0] > 0 {
        closing = delimiter
        result.append(" ")
      } else {
        result.append(character)
      }
    }
    return result
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
