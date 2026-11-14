import Foundation

/// A bounded English routing heuristic, fixed before a turn starts. It grants
/// output capabilities, not permission for desktop actions or background capture.
/// Provider content, retained history and a merely existing notebook cannot
/// promote the route. A permitted notebook is useful when appropriate, not required.
struct ResponsePolicy: Sendable, Equatable {
  enum Route: String, Sendable { case conversation, screenGuidance, notebook }

  static let maximumTextBytes = 32_000
  let route: Route
  let includesExistingNotebook: Bool
  let permitsScreenEvidence: Bool
  var allowsNotebook: Bool { route == .notebook }

  init(route: Route, includesExistingNotebook: Bool, permitsScreenEvidence: Bool = true) {
    self.route = route
    self.includesExistingNotebook = includesExistingNotebook
    self.permitsScreenEvidence = permitsScreenEvidence
  }

  /// Trusted per-turn instructions. Keep this separate from selected evidence,
  /// which is always untrusted data. The host independently enforces the route.
  var instructions: String {
    let turn =
      switch route {
      case .conversation:
        "Respond conversationally using text units. Do not output scene units or open a notebook. Do not invent on-screen targets or request a screen capture."
      case .screenGuidance:
        "Analyze the supplied current screenshot for the user's task or screen question. For navigation, identify the next visible control, including a control that reveals the requested destination, and emit a grounded click target with a brief instruction. For a question about visible content or state, answer in the instruction of a grounded manual target marking the relevant element. Prefer an exact current actionable accessibility candidateID for a click; native code supplies its bounds. Otherwise emit pixelBounds for the control's full top-left bounds in the exact encoded image; native code normalizes them. Do not mix coordinate representations. Do not require its label to literally repeat the user's wording: infer its role from the page and visual context. Match the functional goal in the actual foreground app, using actual labels. For compact controls use ellipse; fields or large regions may use roundedRectangle. Inspect a fresh frame after user action before choosing a child. Never invent hidden controls, coordinates, or app switches. A specific clarification is appropriate only when a safe visible next target genuinely cannot be identified or the task is complete. Do not replace a visible grounded target with generic steps or a guessed shortcut. Do not output scene units or open a Notebook. You cannot perform desktop actions."
      case .notebook:
        includesExistingNotebook
          ? "The user requested an edit to the current notebook. Use its supplied stable IDs and preserve unrelated content. Use text and scene units only as needed; a scene is permitted, never mandatory. Do not output screen targets."
          : "Use text to answer. A small notebook scene is permitted only if it materially helps the requested visual or mechanism explanation; it is not mandatory. No retained notebook is authorized for editing. Do not output screen targets."
      }
    return
      "Product capability: the native host can display typed 2D and 3D scenes when the current output policy permits them. A text-only or guidance turn is a per-turn restriction, not a missing viewer. Do not claim the application cannot render a model because a previous turn used text.\n"
      + turn
  }

  static func resolve(
    text: String, screenGuidanceEnabled: Bool, explicitGuidance: Bool = false,
    inNotebook: Bool = false, hasNotebook: Bool = false
  ) -> Self {
    guard text.utf8.prefix(maximumTextBytes + 1).count <= maximumTextBytes else {
      return Self(
        route: .conversation, includesExistingNotebook: false, permitsScreenEvidence: false)
    }
    let request = unquoted(text)
    let words = request.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    guard !words.isEmpty else {
      return Self(
        route: .conversation, includesExistingNotebook: false, permitsScreenEvidence: false)
    }
    let tokens = Tokens(words)
    let permitsScreenEvidence = !tokens.screenPrivate
    let conversation = Self(
      route: .conversation, includesExistingNotebook: false,
      permitsScreenEvidence: permitsScreenEvidence)
    if tokens.textOnly { return conversation }

    // Resolve UI help before visual vocabulary: drawing a chart in an app can
    // be a request to guide its controls, rather than to manufacture a diagram.
    let guidance = explicitGuidance || GuidanceIntent.requestsScreenGuidance(text: request)
    if guidance {
      return Self(
        route: screenGuidanceEnabled && !tokens.screenPrivate ? .screenGuidance : .conversation,
        includesExistingNotebook: false, permitsScreenEvidence: permitsScreenEvidence)
    }
    guard !tokens.forbidsNotebook else { return conversation }
    guard !tokens.isDefinition else { return conversation }

    // A privacy preface constrains capture, not an independent positive request
    // after it. Keep all opt-outs above scoped to the complete current input.
    let positive = positiveRequest(afterPrivacyPreface: request)
    let positiveWords = positive.lowercased().split { !$0.isLetter && !$0.isNumber }.map(
      String.init)
    guard !positiveWords.isEmpty else { return conversation }
    let requestTokens = Tokens(positiveWords)
    if inNotebook, hasNotebook, requestTokens.requestsNotebookEdit {
      return Self(
        route: .notebook, includesExistingNotebook: true,
        permitsScreenEvidence: permitsScreenEvidence)
    }
    if requestTokens.requestsVisual || requestTokens.requestsMechanismTeaching {
      return Self(
        route: .notebook, includesExistingNotebook: false,
        permitsScreenEvidence: permitsScreenEvidence)
    }
    return conversation
  }

  static func isExplicitTextOnly(_ text: String) -> Bool {
    guard text.utf8.count <= maximumTextBytes else { return true }
    let words = unquoted(text).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    return Tokens(words).textOnly
  }

  static func requestsExplicit3D(_ text: String) -> Bool {
    guard text.utf8.count <= maximumTextBytes else { return false }
    let words = unquoted(text).lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let tokens = Tokens(words)
    return words.contains("3d") && tokens.requestsVisual && !tokens.textOnly
      && !tokens.forbidsNotebook && !tokens.isDefinition
  }

  private static func positiveRequest(afterPrivacyPreface request: String) -> String {
    let clauses = request.split { ".,;:!?\n\r".contains($0) }
    guard clauses.count > 1 else { return request }
    var index = 0
    while index < clauses.count {
      let words = clauses[index].lowercased().split { !$0.isLetter && !$0.isNumber }.map(
        String.init)
      guard !words.isEmpty, Tokens(words).screenPrivate else { break }
      index += 1
    }
    guard index > 0 else { return request }
    return clauses.dropFirst(index).joined(separator: " ")
  }

  /// Quoted examples are content, not positive routing instructions. Apostrophes
  /// inside words remain intact, so "don't" still participates in opt-out rules.
  private static func unquoted(_ text: String) -> String {
    let characters = Array(text)
    // Count future closing delimiters once. Scanning the remaining suffix for
    // each unmatched opening quote would make adversarial input quadratic.
    let delimiters: Set<Character> = ["\"", "”", "’", "'", "`"]
    var remaining: [Character: Int] = [:]
    for character in characters where delimiters.contains(character) {
      remaining[character, default: 0] += 1
    }
    var result = ""
    var closing: Character?
    for index in characters.indices {
      let character = characters[index]
      if delimiters.contains(character) { remaining[character, default: 0] -= 1 }
      let previousIsWord =
        index > 0 && (characters[index - 1].isLetter || characters[index - 1].isNumber)
      let nextIsWord =
        index + 1 < characters.count
        && (characters[index + 1].isLetter || characters[index + 1].isNumber)
      if let delimiter = closing {
        if character == delimiter,
          !((delimiter == "'" || delimiter == "’") && previousIsWord && nextIsWord)
        {
          closing = nil
        }
        result.append(" ")
        continue
      }
      let delimiter: Character?
      switch character {
      case "\"": delimiter = "\""
      case "`": delimiter = "`"
      case "“": delimiter = "”"
      case "‘": delimiter = "’"
      case "'" where !previousIsWord: delimiter = "'"
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

  private struct Tokens {
    let words: [String]
    let vocabulary: Set<String>

    init(_ words: [String]) {
      self.words = words
      vocabulary = Set(words)
    }

    func has(_ phrase: [String]) -> Bool {
      guard words.count >= phrase.count else { return false }
      return words.indices.prefix(words.count - phrase.count + 1).contains { index in
        words[index..<(index + phrase.count)].elementsEqual(phrase)
      }
    }

    func contains(_ choices: Set<String>) -> Bool { !vocabulary.isDisjoint(with: choices) }

    var textOnly: Bool {
      [
        ["text", "only"], ["only", "text"], ["just", "text"], ["plain", "text"],
        ["only", "in", "text"], ["answer", "with", "text"], ["respond", "with", "text"],
        ["words", "only"], ["only", "words"], ["answer", "in", "words"],
        ["no", "visuals"], ["without", "visuals"], ["without", "any", "visuals"],
      ].contains(where: has)
    }

    var screenPrivate: Bool {
      if [
        ["no", "screenshot"], ["no", "screenshots"], ["no", "screen", "capture"],
        ["no", "screen"],
        ["no", "capture"], ["no", "screen", "recording"],
        ["without", "capturing"], ["without", "sharing"], ["without", "looking"],
        ["without", "taking"], ["without", "seeing"], ["without", "reading"],
        ["without", "screenshots"], ["without", "a", "screenshot"],
        ["without", "any", "screenshots"],
        ["without", "screen", "access"],
      ].contains(where: has) {
        return true
      }
      if contains(["private"]), contains(["screen", "desktop", "display", "screenshot"]) {
        return true
      }
      return negates([
        "capture", "share", "look", "take", "record", "inspect", "see", "read", "access", "view",
        "screenshot", "screenshots", "screenshotting", "screenshotted",
      ]) || negatesScreenShot() || negatesScreenInspection()
    }

    private func negatesScreenInspection() -> Bool {
      for index in words.indices
      where ["not", "never", "dont", "without"].contains(words[index])
        || words[index] == "t" && index > 0 && words[index - 1] == "don"
      {
        let nearby = Set(words[(index + 1)..<min(words.count, index + 8)])
        if !nearby.isDisjoint(with: ["capture", "capturing", "record", "recording"]) {
          return true
        }
        if !nearby.isDisjoint(with: ["screen", "desktop", "display", "screenshot", "screenshots"]),
          !nearby.isDisjoint(with: [
            "share", "sharing", "look", "looking", "take", "taking", "inspect", "inspecting",
            "access", "accessing", "read", "reading", "view", "viewing", "see", "seeing",
            "check", "checking", "analyze", "analyzing", "analyse", "analysing", "examine",
            "examining",
          ])
        {
          return true
        }
      }
      return false
    }

    private func negatesScreenShot() -> Bool {
      for index in words.indices
      where ["not", "never", "dont", "no", "without"].contains(words[index])
        || words[index] == "t" && index > 0 && words[index - 1] == "don"
      {
        let end = min(words.count, index + 8)
        if !Set(words[(index + 1)..<end]).isDisjoint(with: [
          "screenshot", "screenshots", "screenshotting", "screenshotted",
        ]) {
          return true
        }
        guard index + 2 < end else { continue }
        for next in (index + 1)..<(end - 1)
        where words[next] == "screen"
          && ["shot", "shots", "shotting", "shotted"].contains(words[next + 1])
        { return true }
      }
      return false
    }

    var forbidsNotebook: Bool {
      let objects: Set<String> = [
        "diagram", "diagrams", "chart", "charts", "graph", "graphs", "drawing", "drawings",
        "notebook", "canvas", "sketch", "sketches", "animation", "animations", "visuals",
        "model", "models", "scene", "scenes", "cutaway", "cutaways",
      ]
      for index in words.indices where words[index] == "no" || words[index] == "without" {
        let fillers: Set<String> = ["need", "for", "a", "an", "the", "any", "more"]
        var next = index + 1
        while next < words.count, next <= index + 5, fillers.contains(words[next]) { next += 1 }
        if next < words.count, objects.contains(words[next]) { return true }
      }
      if negates(["draw", "sketch", "plot", "graph", "visualize", "visualise", "animate"]) {
        return true
      }
      return negates(["open", "create", "make", "show", "use", "generate", "include"])
        && contains(objects)
    }

    var isDefinition: Bool {
      words.first == "what"
        && (has(["what", "is"]) || has(["what", "are"])
          || contains(["mean", "means", "meaning"]))
        || words.first == "define" || words.first == "meaning"
        || contains(["phrase", "wording"]) && !contains(["draw", "plot", "sketch"])
    }

    var requestLead: Bool {
      let imperative: Set<String> = [
        "draw", "diagram", "sketch", "plot", "graph", "visualize", "visualise", "illustrate",
        "animate", "create", "make", "build", "show", "design", "generate", "render", "add",
        "explain", "teach",
        "change", "edit", "update", "recolor", "recolour", "color", "colour", "rename", "resize",
        "move", "rotate", "remove", "delete", "replace", "reverse", "flip", "adjust",
      ]
      return imperative.contains(words[0])
        || words[0] == "please" && words.count > 1 && imperative.contains(words[1])
        || [
          ["can", "you"], ["could", "you"], ["would", "you"], ["i", "want"],
          ["i", "need"], ["help", "me"], ["show", "me"],
        ].contains(where: has)
    }

    var requestsNotebookEdit: Bool {
      let edits: Set<String> = [
        "change", "edit", "update", "recolor", "recolour", "color", "colour", "rename", "resize",
        "move", "rotate", "remove", "delete", "replace", "reverse", "flip", "adjust", "add", "make",
      ]
      let references: Set<String> = [
        "notebook", "canvas", "diagram", "drawing", "shape", "shapes", "arrow", "arrows",
        "node", "nodes", "label", "labels", "selected", "rectangle", "ellipse", "line", "title",
        "it", "this", "that",
      ]
      return requestLead && contains(edits) && contains(references) && !negates(edits)
    }

    var requestsVisual: Bool {
      guard requestLead else { return false }
      let direct: Set<String> = [
        "draw", "diagram", "sketch", "plot", "graph", "visualize", "visualise", "illustrate",
        "animate",
      ]
      var leading = words[...]
      if leading.first == "please" { leading = leading.dropFirst() }
      if leading.count >= 2,
        ["can", "could", "would"].contains(leading.first ?? ""), leading.dropFirst().first == "you"
      {
        leading = leading.dropFirst(2)
      }
      if leading.first == "please" { leading = leading.dropFirst() }
      if let first = leading.first, direct.contains(first) { return true }
      if contains(["visually", "graphically"]), contains(["explain", "show", "teach"]) {
        return true
      }
      if contains(["3d", "2d"]),
        contains(["create", "make", "build", "show", "design", "generate", "render", "explain"])
      {
        return true
      }
      let objects: Set<String> = [
        "diagram", "diagrams", "chart", "charts", "graph", "graphs", "plot", "plots", "flowchart",
        "sketch", "drawing", "illustration", "visualization", "visualisation", "notebook", "canvas",
        "timeline", "animation",
      ]
      return contains(objects)
        && contains(["create", "make", "build", "show", "design", "draw", "add"])
        || contains(objects) && has(["with", "a"]) && contains(["explain", "teach", "understand"])
        || contains(objects) && (has(["i", "want"]) || has(["i", "need"]))
          && !contains(["know", "understand", "definition", "meaning"])
    }

    var requestsMechanismTeaching: Bool {
      if has(["teach", "me"]), !contains(["write", "code", "poem", "essay", "email"]) {
        return true
      }
      let mechanism: Set<String> = [
        "work", "works", "working", "operate", "operates", "happen", "happens", "form", "forms",
        "function", "functions", "move", "moves", "flow", "flows", "affect", "affects", "cause",
        "causes", "produce", "produces", "rotate", "rotates", "spin", "spins",
      ]
      return contains(mechanism)
        && (has(["explain", "how"]) || has(["how", "does"]) || has(["how", "do"])
          || has(["why", "does"]) || has(["why", "do"]) || has(["show", "me", "how"]))
    }

    private func negates(_ actions: Set<String>) -> Bool {
      for index in words.indices
      where ["not", "never", "dont"].contains(words[index])
        || words[index] == "t" && index > 0 && words[index - 1] == "don"
      {
        if !Set(words[(index + 1)..<min(words.count, index + 4)]).isDisjoint(with: actions) {
          return true
        }
      }
      return false
    }
  }
}
