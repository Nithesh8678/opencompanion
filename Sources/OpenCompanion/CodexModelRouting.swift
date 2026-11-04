import Foundation

enum GuidanceModelPreference: String, Codable, CaseIterable, Sendable {
  case terra, conversation
}

struct CodexRoutingSelection: Sendable, Equatable {
  enum Reason: String, Codable, Sendable {
    case terraGuidance, conversation, configuredGuidance, terraUnavailableFallback
  }
  let model: String
  let effort: String?
  let reason: Reason
}

struct CodexRoutingModel: Sendable {
  let model: String
  let alias: String?
  let isDefault: Bool
  let supportsImages: Bool
  let supportedEfforts: Set<String>

  func matches(_ selection: String) -> Bool { model == selection || alias == selection }
}

/// Routes only from the bounded visible catalog. A Terra preference never
/// fabricates a newer alias or changes the configured conversation model.
enum CodexModelRouting {
  static func select(
    configuredModel: String, policy: ResponsePolicy, preference: GuidanceModelPreference,
    catalog: [CodexRoutingModel]
  ) throws -> CodexRoutingSelection {
    let configured = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
    let isGuidance = policy.route == .screenGuidance
    if isGuidance, preference == .terra {
      let counts = Dictionary(grouping: catalog, by: \.model).mapValues(\.count)
      let candidates = catalog.compactMap { entry -> (CodexRoutingModel, [Int])? in
        guard entry.supportsImages, counts[entry.model] == 1,
          let version = terraVersion(entry.model)
        else { return nil }
        return (entry, version)
      }
      let latest = candidates.max { left, right in
        let order = compareVersions(left.1, right.1)
        return order == 0 ? left.0.model < right.0.model : order < 0
      }
      if let latest {
        return .init(
          model: latest.0.model, effort: preferredEffort(latest.0.supportedEfforts),
          reason: .terraGuidance)
      }
    }
    let selected: String
    if configured.isEmpty {
      guard let available = catalog.first(where: \.isDefault) ?? catalog.first else {
        throw ProviderError.message("Codex returned no visible models for this account.")
      }
      selected = available.model
    } else {
      selected = configured
    }
    let matches = catalog.filter { $0.matches(selected) }
    if isGuidance, matches.count == 1, matches[0].supportsImages == false {
      throw ProviderError.message(
        "The selected guidance model \(selected.prefix(120)) does not accept images. Choose an image-capable conversation model in Settings, or select Terra when available for screen guidance."
      )
    }
    let effort =
      isGuidance && matches.count == 1
      ? matches.first.flatMap { preferredEffort($0.supportedEfforts) } : nil
    return .init(
      model: selected, effort: effort,
      reason: !isGuidance
        ? .conversation
        : (preference == .terra ? .terraUnavailableFallback : .configuredGuidance))
  }

  private static func preferredEffort(_ supported: Set<String>) -> String? {
    ["low", "minimal", "none"].first(where: supported.contains)
  }

  private static func terraVersion(_ model: String) -> [Int]? {
    let parts = model.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "gpt", parts[2] == "terra" else { return nil }
    let components = parts[1].split(separator: ".", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.count <= 4 else { return nil }
    var result: [Int] = []
    for component in components {
      guard !component.isEmpty, component.utf8.allSatisfy({ (48...57).contains($0) }),
        let number = Int(component)
      else { return nil }
      result.append(number)
    }
    return result
  }

  private static func compareVersions(_ left: [Int], _ right: [Int]) -> Int {
    for index in 0..<max(left.count, right.count) {
      let lhs = index < left.count ? left[index] : 0
      let rhs = index < right.count ? right[index] : 0
      if lhs != rhs { return lhs < rhs ? -1 : 1 }
    }
    return 0
  }
}
