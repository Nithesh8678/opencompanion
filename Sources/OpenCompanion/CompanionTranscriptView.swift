import SwiftUI

enum WorkspacePalette {
  static let sidebar = Color(red: 0.075, green: 0.078, blue: 0.085)
  static let background = Color(red: 0.105, green: 0.11, blue: 0.12)
  static let surface = Color(red: 0.15, green: 0.155, blue: 0.17)
  static let raised = Color(red: 0.19, green: 0.195, blue: 0.21)
  static let text = Color(red: 0.94, green: 0.945, blue: 0.95)
  static let secondary = Color(red: 0.60, green: 0.62, blue: 0.66)
  static let blue = Color(red: 0.43, green: 0.70, blue: 0.98)
  static let paper = Color(red: 0.91, green: 0.915, blue: 0.89)
}

/// Shared conversation content for the attached shell and the full workspace.
/// Each host supplies its own header/composer. Incoming thoughts follow only
/// while the reader remains near the live edge; a new user turn follows itself.
struct CompanionTranscriptView: View {
  @ObservedObject var model: AppModel
  @State private var followsLiveEdge = true
  @State private var settlingScroll = false
  @State private var scrollGeneration = 0
  @State private var observedBottom: CGFloat?
  @State private var observedViewport = CGSize.zero
  @Namespace private var scrollSpace
  private let liveEdge = "opencompanion.transcript.live-edge"

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        WorkspaceDotField()
        if model.messages.isEmpty {
          emptyConversation
        } else {
          ScrollViewReader { proxy in
            ScrollView {
              VStack(spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 15) {
                  ForEach(model.messages) { line in
                    TranscriptBubble(line: line).id(line.id)
                  }
                  if model.busy {
                    HStack(spacing: 9) {
                      ProgressView().controlSize(.small)
                      Text("Thinking it through…").font(.system(size: 12))
                        .foregroundStyle(WorkspacePalette.secondary)
                    }.padding(.horizontal, 15).padding(.vertical, 11)
                      .background(WorkspacePalette.surface, in: Capsule())
                      .accessibilityLabel("Preparing a response")
                  }
                }.padding(.horizontal, geometry.size.width < 540 ? 18 : 30)
                  .padding(.vertical, 24).frame(maxWidth: 900)
                  .frame(maxWidth: .infinity)
                // Both this target and the content geometry stay mounted even
                // when the reader is far above the lazy message rows.
                Color.clear.frame(height: 1).id(liveEdge)
              }.background {
                GeometryReader { content in
                  Color.clear.preference(
                    key: TranscriptEdgePreference.self,
                    value: content.frame(in: .named(scrollSpace)).maxY)
                }
              }
            }.coordinateSpace(name: scrollSpace)
              .onPreferenceChange(TranscriptEdgePreference.self) { bottom in
                guard let bottom, bottom.isFinite else { return }
                observedBottom = bottom
                if !settlingScroll, observedViewport == geometry.size {
                  followsLiveEdge = bottom <= geometry.size.height + 80
                }
              }
              .onAppear {
                observedViewport = geometry.size
                follow(using: proxy)
              }
              .onChange(of: geometry.size) { _, size in
                observedViewport = size
                if followsLiveEdge { follow(using: proxy) }
              }
              .onChange(of: settlingScroll) { _, settling in
                if !settling, let bottom = observedBottom {
                  // Do not lose a wheel/trackpad position update which arrived
                  // while a scheduled programmatic scroll was settling.
                  followsLiveEdge = bottom <= geometry.size.height + 80
                }
              }
              .onChange(of: model.messages.first?.id) { _, _ in
                // Opening another saved conversation starts at its live edge.
                follow(using: proxy)
              }
              .onChange(of: model.messages.last?.id) { _, _ in
                if followsLiveEdge || model.messages.last?.role == "user" { follow(using: proxy) }
              }
              .onChange(of: model.messages.last?.text) { _, _ in
                if followsLiveEdge { follow(using: proxy) }
              }
              .onChange(of: model.busy) { _, _ in
                if followsLiveEdge { follow(using: proxy) }
              }
              .overlay(alignment: .bottom) {
                if !followsLiveEdge {
                  Button {
                    follow(using: proxy)
                  } label: {
                    Label("Latest", systemImage: "arrow.down")
                      .font(.system(size: 11, weight: .medium))
                      .padding(.horizontal, 12).padding(.vertical, 7)
                      .background(WorkspacePalette.raised, in: Capsule())
                      .overlay(Capsule().stroke(.white.opacity(0.12)))
                  }.buttonStyle(.plain).foregroundStyle(WorkspacePalette.text)
                    .padding(.bottom, 12)
                }
              }
          }
        }
      }
    }.accessibilityIdentifier("companion.transcript")
  }

  private var emptyConversation: some View {
    VStack(spacing: 12) {
      Image(systemName: "sparkle").font(.system(size: 29, weight: .light))
        .foregroundStyle(WorkspacePalette.blue)
      Text("A little room to think.").font(.system(size: 24, weight: .medium, design: .rounded))
        .foregroundStyle(WorkspacePalette.text)
      Text("Ask a question, bring some context, or talk it through.")
        .font(.system(size: 12)).foregroundStyle(WorkspacePalette.secondary)
        .multilineTextAlignment(.center)
    }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func follow(using proxy: ScrollViewProxy) {
    scrollGeneration += 1
    let generation = scrollGeneration
    followsLiveEdge = true
    settlingScroll = true
    Task { @MainActor in
      await Task.yield()
      guard generation == scrollGeneration else { return }
      proxy.scrollTo(liveEdge, anchor: .bottom)
      await Task.yield()
      if generation == scrollGeneration { settlingScroll = false }
    }
  }
}

private struct TranscriptEdgePreference: PreferenceKey {
  static let defaultValue: CGFloat? = nil
  static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
    if let next = nextValue() { value = next }
  }
}

private struct TranscriptBubble: View {
  let line: ChatLine
  private var isUser: Bool { line.role == "user" }
  var body: some View {
    HStack(alignment: .bottom, spacing: 0) {
      if isUser { Spacer(minLength: 55) }
      VStack(alignment: .leading, spacing: 7) {
        if !isUser {
          Text("OpenCompanion").font(.system(size: 10, weight: .medium))
            .foregroundStyle(WorkspacePalette.secondary)
        }
        Text(line.text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
          .foregroundStyle(
            isUser ? Color(red: 0.08, green: 0.14, blue: 0.21) : WorkspacePalette.text
          )
          .padding(.horizontal, 16).padding(.vertical, 12)
          .background {
            if isUser {
              RoundedRectangle(cornerRadius: 17)
                .fill(
                  LinearGradient(
                    colors: [Color(red: 0.70, green: 0.86, blue: 1), WorkspacePalette.blue],
                    startPoint: .top, endPoint: .bottom))
            } else {
              RoundedRectangle(cornerRadius: 17).fill(WorkspacePalette.surface)
            }
          }
          .overlay {
            RoundedRectangle(cornerRadius: 17)
              .stroke(.white.opacity(isUser ? 0.25 : 0.06), lineWidth: 0.7)
          }
      }.frame(maxWidth: 700, alignment: isUser ? .trailing : .leading)
      if !isUser { Spacer(minLength: 45) }
    }.frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
      .accessibilityElement(children: .combine)
  }
}

/// A static, low-contrast ground. It has no animation clock or per-frame state.
struct WorkspaceDotField: View {
  var body: some View {
    Canvas { context, size in
      let step: CGFloat = 15
      var dots = Path()
      for x in stride(from: CGFloat(8), to: size.width, by: step) {
        for y in stride(from: CGFloat(8), to: size.height, by: step) {
          dots.addEllipse(in: CGRect(x: x, y: y, width: 1, height: 1))
        }
      }
      context.fill(dots, with: .color(.white.opacity(0.055)))
    }.background(WorkspacePalette.background).allowsHitTesting(false).accessibilityHidden(true)
  }
}

/// An original, slightly irregular paper edge for a selected workspace row.
struct WorkspacePaperShape: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: 3, y: 1))
      path.addLine(to: CGPoint(x: rect.width * 0.42, y: 0))
      path.addLine(to: CGPoint(x: rect.width - 2, y: 2))
      path.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.58))
      path.addLine(to: CGPoint(x: rect.width - 3, y: rect.height - 1))
      path.addLine(to: CGPoint(x: rect.width * 0.57, y: rect.height))
      path.addLine(to: CGPoint(x: 1, y: rect.height - 2))
      path.addLine(to: CGPoint(x: 0, y: rect.height * 0.38))
      path.closeSubpath()
    }
  }
}
