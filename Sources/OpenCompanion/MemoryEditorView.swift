import CompanionStore
import SwiftUI

/// An existing memory's editable draft. Saving never creates a replacement ID
/// and never silently changes a newer persisted version.
@MainActor struct MemoryEditorView: View {
  let store: LocalStore
  let record: StoredRecord
  let onSaved: (StoredRecord) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var bodyText: String
  @State private var saving = false
  @State private var error: String?
  @State private var confirmingDiscard = false

  init(
    store: LocalStore, record: StoredRecord,
    onSaved: @escaping (StoredRecord) -> Void = { _ in }
  ) {
    self.store = store
    self.record = record
    self.onSaved = onSaved
    _title = State(initialValue: record.title)
    _bodyText = State(initialValue: record.body)
  }

  private var changed: Bool { title != record.title || bodyText != record.body }
  private var valid: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 17) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Edit memory").font(.system(size: 25, weight: .medium, design: .rounded))
        Text("Keep the details you want to use again.").font(.callout).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 7) {
        Text("Title").font(.callout.weight(.medium))
        TextField("Memory title", text: $title)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("memory.editor.title")
      }
      VStack(alignment: .leading, spacing: 7) {
        Text("Memory").font(.callout.weight(.medium))
        TextEditor(text: $bodyText)
          .font(.system(size: 14))
          .scrollContentBackground(.hidden)
          .padding(8)
          .frame(minHeight: 200, maxHeight: .infinity)
          .background(.background, in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
          .accessibilityLabel("Memory text")
          .accessibilityIdentifier("memory.editor.body")
      }
      if let error {
        Label(error, systemImage: "exclamationmark.circle")
          .font(.callout)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .accessibilityIdentifier("memory.editor.error")
      }
      HStack(spacing: 10) {
        if saving {
          ProgressView().controlSize(.small)
          Text("Saving…").font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel") { if changed { confirmingDiscard = true } else { dismiss() } }
          .keyboardShortcut(.cancelAction)
          .disabled(saving)
        Button("Save changes", action: save)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(saving || !valid || !changed || record.kind != "memory")
          .accessibilityIdentifier("memory.editor.save")
      }
    }
    .padding(25)
    .frame(minWidth: 500, idealWidth: 560, minHeight: 440, idealHeight: 510)
    .disabled(saving)
    .interactiveDismissDisabled(saving || changed)
    .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard) {
      Button("Discard changes", role: .destructive) { dismiss() }
      Button("Keep editing", role: .cancel) {}
    } message: {
      Text("The saved memory will stay as it was.")
    }
  }

  private func save() {
    guard !saving, valid, changed else { return }
    saving = true
    error = nil
    let draftTitle = title
    let draftBody = bodyText
    Task { @MainActor in
      do {
        let updated = try await store.updateMemory(record, title: draftTitle, body: draftBody)
        saving = false
        onSaved(updated)
        dismiss()
      } catch {
        saving = false
        self.error = error.localizedDescription
      }
    }
  }
}
