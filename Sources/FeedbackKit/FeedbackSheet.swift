#if canImport(UIKit)
import SwiftUI
import UIKit

/// Bug or idea, a note, an optional screenshot, and a look at everything that will be
/// sent. Calls `close` when sent or cancelled.
public struct FeedbackSheet: View {
    let screenshot: UIImage?
    let context: FeedbackContext
    let diagnostics: String?
    let client: FeedbackClient
    let close: () -> Void

    @State private var kind: FeedbackKind = .bug
    @State private var text = ""
    @State private var attach = true
    @State private var sending = false
    @State private var sentID: Int?
    @State private var error: String?
    @State private var queuedEntry: String?
    @FocusState private var focused: Bool

    public init(screenshot: UIImage?, context: FeedbackContext, diagnostics: String?,
                client: FeedbackClient, close: @escaping () -> Void) {
        self.screenshot = screenshot
        self.context = context
        self.diagnostics = diagnostics
        self.client = client
        self.close = close
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        NavigationStack {
            Group {
                if let sentID {
                    sent(sentID)
                } else {
                    form
                }
            }
            .navigationTitle(kind == .bug ? "Report a bug" : "Suggest an idea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: close).disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else if sentID == nil {
                        Button("Send") { Task { await send() } }
                            .fontWeight(.bold)
                            .disabled(trimmed.isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(sending || (!text.isEmpty && sentID == nil && queuedEntry == nil))
    }

    private var form: some View {
        Form {
            Section {
                Picker("Kind", selection: $kind) {
                    Label("Bug", systemImage: "ladybug").tag(FeedbackKind.bug)
                    Label("Idea", systemImage: "lightbulb").tag(FeedbackKind.idea)
                }
                .pickerStyle(.segmented)
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(kind == .bug ? "What happened, and what did you expect?" : "What would make this better?")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .focused($focused)
                        .frame(minHeight: 140)
                        .onChange(of: text) { _, new in
                            if new.count > FeedbackLimits.maxTextLength { text = FeedbackLimits.clampText(new) }
                        }
                }
            } footer: {
                Text("\(text.count)/\(FeedbackLimits.maxTextLength)")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let screenshot {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        Image(uiImage: screenshot).resizable().scaledToFit()
                            .frame(height: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
                            .opacity(attach ? 1 : 0.3)
                            .onTapGesture { withAnimation { attach.toggle() } }
                            .accessibilityLabel("Screenshot preview")
                        Toggle("Attach screenshot", isOn: $attach.animation())
                    }
                }
            }

            Section {
                DisclosureGroup("What will be sent") {
                    row("Kind", kind.rawValue)
                    row("Note", "\(trimmed.count) characters")
                    ForEach(context.dictionary.sorted(by: { $0.key < $1.key }), id: \.key) { row($0.key, $0.value) }
                    row("Screenshot", screenshot != nil && attach ? "yes" : "no")
                    if let diagnostics {
                        row("Diagnostics", ByteCountFormatter.string(fromByteCount: Int64(diagnostics.utf8.count),
                                                                     countStyle: .file))
                        Text(diagnostics.suffix(600))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                    }
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                    if queuedEntry != nil {
                        Button("Close; send it later", action: close)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focused = true }
    }

    private func row(_ name: String, _ value: String) -> some View {
        LabeledContent(name, value: value).font(.callout)
    }

    private func sent(_ id: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64)).foregroundStyle(.green)
            Text("Thanks!").font(.title.weight(.bold))
            Text(id > 0 ? "Sent as #\(id)." : "Sent.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func send() async {
        focused = false
        sending = true
        defer { sending = false }
        error = nil
        // A retry replaces the copy queued by the failed attempt, so it is never sent twice.
        if let queuedEntry { client.queue.remove(queuedEntry); self.queuedEntry = nil }
        let jpeg = attach ? screenshot.flatMap(FeedbackScreenshot.jpeg) : nil
        let payload = FeedbackPayload(kind: kind, text: trimmed, context: context.dictionary,
                                      diagnostics: diagnostics, screenshotJPEG: jpeg)
        do {
            let receipt = try await client.send(payload)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation { sentID = receipt.id }
            try? await Task.sleep(for: .seconds(1.4))
            close()
        } catch let failure {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            if case let FeedbackSendError.queued(entryID, _) = failure { queuedEntry = entryID }
            error = "Couldn't send: \(failure.localizedDescription)"
        }
    }
}
#endif
