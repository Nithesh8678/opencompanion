import SwiftUI

/// Shared presentation of the host's guidance session. This surface never
/// captures, activates a window, or decides whether an external action worked.
struct GuidanceProgressView: View {
  @ObservedObject var model: AppModel
  var compact = false

  var body: some View {
    if let title = model.guidanceProgressTitle {
      VStack(alignment: .leading, spacing: compact ? 4 : 6) {
        HStack(spacing: 10) {
          HStack(spacing: 7) {
            Image(systemName: "viewfinder")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.white.opacity(0.65))
              .accessibilityHidden(true)
            Text(title)
              .font(.system(size: 12, weight: .semibold, design: .rounded))
              .foregroundStyle(.white.opacity(0.94))
              .lineLimit(1)
              .accessibilityIdentifier("guidance.progress.title")
          }.layoutPriority(1)
          Spacer(minLength: 0)
          actions
        }
        if !model.guidanceProgressDetail.isEmpty {
          Text(model.guidanceProgressDetail)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.64))
            .lineLimit(compact ? 1 : 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(model.guidanceProgressDetail)
            .accessibilityIdentifier("guidance.progress.detail")
        }
      }
      .padding(.horizontal, 11).padding(.vertical, compact ? 8 : 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(white: 0.045), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08), lineWidth: 1))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("guidance.progress")
    }
  }

  private var actions: some View {
    HStack(spacing: 6) {
      if model.guidanceCanPause {
        control("Pause", symbol: "pause.fill", id: "pause", action: model.pauseGuidance)
      }
      if model.guidanceCanResume {
        if model.guidanceRequiresScopeChoice {
          scopeChoice(title: "Resume", id: "resume")
        } else {
          control("Resume", symbol: "play.fill", id: "resume", action: model.resumeGuidance)
        }
      }
      if model.guidanceCanRecheck {
        if model.guidanceRequiresScopeChoice {
          scopeChoice(title: "Recheck", id: "recheck")
        } else {
          control(
            "Recheck", symbol: "arrow.clockwise", id: "recheck", action: model.recheckGuidance)
        }
      }
      control("Stop", symbol: "stop.fill", id: "stop", action: model.abandonGuidance)
    }.fixedSize(horizontal: true, vertical: false)
  }

  private func scopeChoice(title: String, id: String) -> some View {
    Menu {
      if model.guidanceHasSelectedScope {
        Button("Use selected area", action: model.resumeGuidanceWithSelectedContext)
      }
      Button("Use current screen", action: model.resumeGuidanceOnCurrentScreen)
    } label: {
      Label(title, systemImage: id == "resume" ? "play.fill" : "arrow.clockwise")
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 7).frame(minHeight: 24)
        .foregroundStyle(.white.opacity(0.94))
        .background(Color.white.opacity(0.09), in: Capsule())
    }.menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Choose screen to \(title.lowercased()) guidance")
      .accessibilityIdentifier("guidance.progress.\(id).scope")
  }

  private func control(
    _ title: String, symbol: String, id: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(.system(size: 10, weight: .medium))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 7).frame(minHeight: 24)
        .foregroundStyle(.white.opacity(id == "stop" ? 0.65 : 0.94))
        .background(Color.white.opacity(id == "stop" ? 0.035 : 0.09), in: Capsule())
        .contentShape(Capsule())
    }.buttonStyle(.plain)
      .accessibilityLabel("\(title) screen guidance")
      .accessibilityIdentifier("guidance.progress.\(id)")
  }
}
