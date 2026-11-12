import AppKit
import DiVoiceCore
import DiVoiceEngine
import SwiftUI

/// Settings › History: the dictations of the last 7 days, kept only on this Mac, to copy a
/// text again or take back what was said before the cleanup.
struct HistoryView: View {
  @ObservedObject var history: HistoryStore
  @State private var search = ""
  @State private var confirmClear = false

  private var entries: [HistoryEntry] {
    let query = search.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return history.entries }
    return history.entries.filter {
      $0.text.localizedCaseInsensitiveContains(query) || $0.raw.localizedCaseInsensitiveContains(query)
        || ($0.appName ?? "").localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    CardPage {
      HStack(spacing: 10) {
        TextField("", text: $search, prompt: Text("Search"))
          .textFieldStyle(.roundedBorder)
          .frame(width: 260)
        Spacer()
        Button("Clear history…", role: .destructive) { confirmClear = true }
          .buttonStyle(.secondary)
          .disabled(history.entries.isEmpty)
      }
      Text("Your dictations from the last 7 days, only on this Mac. Copy a text again, or what you said before the cleanup to rewrite it.")
        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if entries.isEmpty {
        Text(history.entries.isEmpty ? "No dictations yet." : "No dictation matches your search.")
          .font(.system(size: 13)).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 40)
      } else {
        LazyVStack(spacing: 10) {
          ForEach(entries) { HistoryRow(entry: $0) }
        }
      }
    }
    .confirmationDialog("Clear the history?", isPresented: $confirmClear) {
      Button("Clear history", role: .destructive) { history.clear() }
    } message: {
      Text("The text of your recent dictations is deleted from this Mac. Your statistics stay.")
    }
  }
}

private struct HistoryRow: View {
  let entry: HistoryEntry
  @State private var showSaid = false
  @State private var copied: Copied?

  private enum Copied { case text, said }

  /// What was said, when the cleanup or Scribe changed it.
  private var said: String? {
    let raw = entry.raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty || raw == entry.text.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : raw
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(entry.date, format: .dateTime.day().month(.abbreviated).hour().minute())
          .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
        if let app = entry.appName {
          Text(verbatim: "·").foregroundStyle(.tertiary)
          Text(verbatim: app).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        // The kind of app diVoice recognized: it decides the tone.
        if let category = AppCategory(rawValue: entry.category) {
          Text(verbatim: "·").foregroundStyle(.tertiary)
          Text(verbatim: category.title).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        if entry.mode == DictationMode.scribe.rawValue { Pill("Scribe", icon: "wand.and.stars") }
        // Scribe didn't answer: the text is the transcript.
        if entry.cleanup == DictationOutput.Processing.scribeFallback.rawValue { Pill("Not rewritten", icon: "exclamationmark.triangle", tint: .orange) }
        Spacer()
        Button(copied == .text ? "Copied" : "Copy") { copy(entry.text, .text) }.buttonStyle(.secondary)
      }
      Text(verbatim: entry.text)
        .font(.system(size: 13))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      if let said {
        DisclosureGroup(isExpanded: $showSaid) {
          VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: said)
              .font(.system(size: 12.5)).foregroundStyle(.secondary)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
            Button(copied == .said ? "Copied" : "Copy what you said") { copy(said, .said) }.buttonStyle(.secondary)
          }
          .padding(.top, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
          Text("What you said").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .card(radius: 16)
  }

  private func copy(_ text: String, _ which: Copied) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    copied = which
  }
}
