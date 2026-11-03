import SwiftUI

struct CompanionWindowPickerView: View {
  let windows: [CaptureWindow]
  let select: (CaptureWindow) -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Choose a window to share")
        .font(.system(size: 19, weight: .semibold, design: .rounded))
      Text("Only the window you choose is included.")
        .font(.callout).foregroundStyle(.secondary)
      List(windows) { window in
        Button {
          select(window)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(window.title.isEmpty ? "Untitled window" : window.title).lineLimit(1)
            Text(window.appName).font(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }.buttonStyle(.plain)
      }.frame(height: 210)
      Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
    }.padding(22).frame(width: 480).preferredColorScheme(.dark)
  }
}
