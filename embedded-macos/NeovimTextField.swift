//
//  NeovimTextField.swift
//  embedded-macos
//

import AppKit
import SwiftUI

/// A borderless native text field that, when `neovimEnabled`, is edited by an embedded Neovim.
struct NeovimTextField: NSViewRepresentable {
    let neovimEnabled: Bool
    /// The mode indicator: "NORMAL", "INSERT", the command line being typed, or an error.
    @Binding var status: String

    func makeCoordinator() -> Coordinator {
        Coordinator(status: $status)
    }

    func makeNSView(context: Context) -> NeovimField {
        let field = NeovimField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .title3)
        field.placeholderString = "Type something…"
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.delegate = context.coordinator
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NeovimField, context: Context) {
        // Starting Neovim may set `status`, which SwiftUI forbids during a view update.
        let coordinator = context.coordinator
        DispatchQueue.main.async { [neovimEnabled] in coordinator.setNeovimEnabled(neovimEnabled) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NeovimField, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSView(_ field: NeovimField, coordinator: Coordinator) {
        coordinator.setNeovimEnabled(false)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var field: NeovimField?
        private let status: Binding<String>
        private var enabled = false
        private var neovim: Neovim?
        private var keyMonitor: Any?
        /// The last selection taken from Neovim; the field differing from it means the user clicked elsewhere.
        private var appliedSelection = NSRange()

        init(status: Binding<String>) {
            self.status = status
        }

        func setNeovimEnabled(_ enabled: Bool) {
            guard enabled != self.enabled else { return }
            self.enabled = enabled
            if enabled { start() } else { stop() }
        }

        private func start() {
            guard let field else { return }
            guard let executable = Neovim.locate(searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "") else {
                status.wrappedValue = "nvim not found"
                return
            }
            let text = field.currentEditor()?.string ?? field.stringValue
            let caret = field.currentEditor()?.selectedRange.location ?? 0
            do {
                neovim = try Neovim(
                    executable: executable,
                    lines: text.components(separatedBy: "\n"),
                    cursor: textPosition(ofUTF16Offset: caret, in: text),
                    onState: { [weak self] in self?.apply($0) },
                    onExit: { [weak self] in
                        self?.stop()
                        self?.status.wrappedValue = "nvim exited"
                    }
                )
            } catch {
                status.wrappedValue = "nvim failed: \(error.localizedDescription)"
                return
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event) ?? event
            }
        }

        private func stop() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            neovim?.quit()
            neovim = nil
            field?.caretEditor.blockCaret = false
        }

        /// Forwards a key typed into the field to Neovim; returns nil when it was consumed.
        func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            guard let neovim, let field, event.window === field.window,
                  let editor = field.currentEditor(),
                  let keys = neovimKeys(for: event)
            else { return event }
            neovim.send(keys: cursorMoveSinceLastApply(in: editor) + keys)
            return nil
        }

        /// A `<Cmd>` that moves Neovim's cursor where the user clicked, sent ahead of the next key so it stays in order.
        private func cursorMoveSinceLastApply(in editor: NSText) -> String {
            let selection = editor.selectedRange
            guard selection != appliedSelection, selection.length == 0 else { return "" }
            appliedSelection = selection
            let position = textPosition(ofUTF16Offset: selection.location, in: editor.string)
            return "<Cmd>call cursor(\(position.row + 1), \(position.byteColumn + 1))<CR>"
        }

        /// Pastes, cuts, and anything else that edits the field natively are pushed into Neovim.
        func controlTextDidChange(_ notification: Notification) {
            guard let neovim, let editor = field?.currentEditor() else { return }
            let text = editor.string
            neovim.replace(
                lines: text.components(separatedBy: "\n"),
                cursor: textPosition(ofUTF16Offset: editor.selectedRange.location, in: text)
            )
        }

        private func apply(_ state: NeovimState) {
            guard let field else { return }
            let shown = presentation(of: state)
            status.wrappedValue = modeLabel(for: state)
            field.caretEditor.blockCaret = shown.blockCaret
            guard let editor = field.currentEditor() else {
                field.stringValue = shown.text
                return
            }
            // Programmatic edits don't reach controlTextDidChange, so this doesn't echo back to Neovim.
            if editor.string != shown.text { editor.string = shown.text }
            editor.selectedRange = shown.selection
            appliedSelection = shown.selection
        }
    }
}

final class NeovimField: NSTextField {
    let caretEditor: CaretTextView = {
        // TextKit 1: TextKit 2 draws its caret with NSTextInsertionIndicator and never calls drawInsertionPoint.
        let editor = CaretTextView(usingTextLayoutManager: false)
        editor.isFieldEditor = true
        return editor
    }()

    override class var cellClass: AnyClass? {
        get { CaretFieldCell.self }
        set {}
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

/// Hands the field its own field editor instead of the window's shared one.
final class CaretFieldCell: NSTextFieldCell {
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        (controlView as? NeovimField)?.caretEditor
    }
}

/// A field editor whose insertion point can be drawn as a block over the character it sits on.
final class CaretTextView: NSTextView {
    var blockCaret = false {
        didSet {
            guard blockCaret != oldValue else { return }
            needsDisplay = true
            updateInsertionPointStateAndRestartTimer(true)
        }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard blockCaret else { return super.drawInsertionPoint(in: rect, color: color, turnedOn: flag) }
        var block = rect
        block.size.width = blockWidth
        if flag {
            color.withAlphaComponent(0.5).setFill()
            block.fill(using: .sourceOver)
        } else {
            setNeedsDisplay(block, avoidAdditionalLayout: true)
        }
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        var widened = rect
        widened.size.width += blockWidth
        super.setNeedsDisplay(widened, avoidAdditionalLayout: flag)
    }

    /// Width of the character under the caret, or of "0" at the end of a line.
    private var blockWidth: CGFloat {
        let text = string as NSString
        let location = selectedRange().location
        let character = location < text.length && text.character(at: location) != 0x0a
            ? text.substring(with: text.rangeOfComposedCharacterSequence(at: location))
            : "0"
        return (character as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 0)]).width
    }
}

/// How the field shows a Neovim state: the text, and a selection that is the caret or the visual selection.
struct FieldPresentation: Equatable {
    var text: String
    var selection: NSRange
    var blockCaret: Bool
}

func presentation(of state: NeovimState) -> FieldPresentation {
    let text = state.lines.joined(separator: "\n")
    let cursor = utf16Offset(of: state.cursor, in: state.lines)
    let caret = NSRange(location: cursor, length: 0)
    switch state.mode.first {
    case "i":
        return FieldPresentation(text: text, selection: caret, blockCaret: false)
    case "V":
        let first = min(state.anchor.row, state.cursor.row)
        let last = max(state.anchor.row, state.cursor.row)
        let start = utf16Offset(of: TextPosition(row: first, byteColumn: 0), in: state.lines)
        let end = utf16Offset(of: TextPosition(row: last, byteColumn: state.lines[last].utf8.count), in: state.lines)
        return FieldPresentation(text: text, selection: NSRange(start..<end), blockCaret: false)
    case "v", "\u{16}", "s", "S", "\u{13}":
        // ponytail: blockwise visual (Ctrl-V) is shown charwise; a rectangle needs more than one NSRange.
        let anchor = utf16Offset(of: state.anchor, in: state.lines)
        let start = min(anchor, cursor)
        let last = max(anchor, cursor)
        let nsText = text as NSString
        let end = last < nsText.length ? NSMaxRange(nsText.rangeOfComposedCharacterSequence(at: last)) : last
        return FieldPresentation(text: text, selection: NSRange(start..<end), blockCaret: false)
    default:
        return FieldPresentation(text: text, selection: caret, blockCaret: true)
    }
}

func modeLabel(for state: NeovimState) -> String {
    switch state.mode.first {
    case "c": state.cmdline
    case "i": "INSERT"
    case "R": "REPLACE"
    case "v": "VISUAL"
    case "V": "V-LINE"
    case "\u{16}": "V-BLOCK"
    case "s", "S", "\u{13}": "SELECT"
    default: "NORMAL"
    }
}

private let specialKeyNames: [NSEvent.SpecialKey: String] = [
    .carriageReturn: "CR", .enter: "CR", .newline: "CR", .tab: "Tab", .backTab: "S-Tab",
    .delete: "BS", .deleteForward: "Del", .home: "Home", .end: "End", .pageUp: "PageUp", .pageDown: "PageDown",
    .upArrow: "Up", .downArrow: "Down", .leftArrow: "Left", .rightArrow: "Right",
]

/// The key in Neovim's notation, or nil to leave it to AppKit (⌘ shortcuts, dead keys, function keys).
func neovimKeys(for event: NSEvent) -> String? {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard !modifiers.contains(.command) else { return nil }
    if let special = event.specialKey {
        return specialKeyNames[special].map { "<\($0)>" }
    }
    if event.characters == "\u{1b}" { return "<Esc>" }
    if modifiers.contains(.control), let key = event.charactersIgnoringModifiers, !key.isEmpty {
        return "<C-\(key == "<" ? "lt" : key)>"
    }
    guard let characters = event.characters, !characters.isEmpty else { return nil }
    return characters.replacingOccurrences(of: "<", with: "<lt>")
}
