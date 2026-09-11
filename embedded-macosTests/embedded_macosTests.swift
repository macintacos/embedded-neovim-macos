//
//  embedded_macosTests.swift
//  embedded-macosTests
//
//  Created by Julian Torres on 9/11/26.
//

import AppKit
import SwiftUI
import Testing
@testable import embedded_macos

@MainActor
struct MessagePackTests {
    @Test func roundTripsEveryType() throws {
        let value = MessagePack.array([
            .null, .bool(true), .int(-70_000), .int(42), .double(1.5), .string("héllo 👋"),
            .binary(Data([1, 2, 3])), .ext(1, Data([9])),
            .map([.init(key: .string("k"), value: .array([.int(1)]))]),
        ])
        let bytes = [UInt8](pack(value))
        let decoded = try #require(try unpack(bytes))
        #expect(decoded.value == value)
        #expect(decoded.length == bytes.count)
    }

    @Test func decodesCompactForms() throws {
        // fixarray[4]: fixint 1, fixstr "hi", negative fixint -1, uint16 300
        let decoded = try #require(try unpack([0x94, 0x01, 0xa2, 0x68, 0x69, 0xff, 0xcd, 0x01, 0x2c]))
        #expect(decoded.value == .array([.int(1), .string("hi"), .int(-1), .int(300)]))
    }

    @Test func waitsForTheRestOfAPartialValue() throws {
        #expect(try unpack([0x92, 0x01]) == nil)
    }
}

@MainActor
struct TextPositionTests {
    let lines = ["héllo", "👋 wave"]

    @Test func convertsByteColumnsToUTF16Offsets() {
        #expect(utf16Offset(of: TextPosition(row: 0, byteColumn: 3), in: lines) == 2) // after "hé"
        #expect(utf16Offset(of: TextPosition(row: 1, byteColumn: 4), in: lines) == 8) // after "👋"
    }

    @Test func convertsUTF16OffsetsBackToByteColumns() {
        let text = lines.joined(separator: "\n")
        #expect(textPosition(ofUTF16Offset: 2, in: text) == TextPosition(row: 0, byteColumn: 3))
        #expect(textPosition(ofUTF16Offset: 8, in: text) == TextPosition(row: 1, byteColumn: 4))
    }
}

@MainActor
struct KeyNotationTests {
    @Test func translatesKeys() {
        #expect(neovimKeys(for: keyDown("a")) == "a")
        #expect(neovimKeys(for: keyDown("<")) == "<lt>")
        #expect(neovimKeys(for: keyDown("\u{1b}")) == "<Esc>")
        #expect(neovimKeys(for: keyDown("\r")) == "<CR>")
        #expect(neovimKeys(for: keyDown("\u{7f}")) == "<BS>")
        #expect(neovimKeys(for: keyDown("\u{12}", .control, ignoringModifiers: "r")) == "<C-r>")
    }

    @Test func leavesCommandShortcutsToAppKit() {
        #expect(neovimKeys(for: keyDown("v", .command)) == nil)
    }
}

@MainActor
struct PresentationTests {
    func state(_ mode: String, cursor: Int, anchor: Int? = nil) -> NeovimState {
        NeovimState(
            mode: mode, lines: ["hello world"],
            cursor: TextPosition(row: 0, byteColumn: cursor),
            anchor: TextPosition(row: 0, byteColumn: anchor ?? cursor), cmdline: ""
        )
    }

    @Test func normalModeUsesABlockCaret() {
        #expect(presentation(of: state("n", cursor: 4)).selection == NSRange(location: 4, length: 0))
        #expect(presentation(of: state("n", cursor: 4)).blockCaret)
    }

    @Test func insertModeUsesTheNativeCaret() {
        #expect(!presentation(of: state("i", cursor: 11)).blockCaret)
    }

    @Test func visualModeSelectsInclusively() {
        #expect(presentation(of: state("v", cursor: 0, anchor: 4)).selection == NSRange(location: 0, length: 5))
        #expect(presentation(of: state("V", cursor: 3)).selection == NSRange(location: 0, length: 11))
    }
}

/// Drives a real field in a real window against a real `nvim`, through the same key handler the app uses.
@MainActor
struct NeovimFieldTests {

    @Test func editsTheFieldWithNeovim() async throws {
        try #require(Neovim.locate(searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "") != nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let field = NeovimField(frame: window.contentLayoutRect)
        field.stringValue = "hello world"
        var status = ""
        let coordinator = NeovimTextField.Coordinator(status: Binding(get: { status }, set: { status = $0 }))
        coordinator.field = field
        field.delegate = coordinator
        window.contentView = field
        window.makeKeyAndOrderFront(nil)
        defer {
            coordinator.setNeovimEnabled(false)
            window.close()
        }
        let editor = try #require(field.currentEditor())
        func type(_ keys: String...) {
            for key in keys { NSApp.sendEvent(keyDown(key, window: window)) } // the path a real keypress takes
        }

        coordinator.setNeovimEnabled(true)
        try await until { status == "NORMAL" && field.caretEditor.blockCaret }
        // The key monitor's handler, so nil means AppKit never hands the key to the field. <Esc> is a no-op here.
        #expect(coordinator.handleKeyDown(keyDown("\u{1b}", window: window)) == nil)

        type("u", "x") // the initial text is not undoable, so `u` must leave it for `x` to act on
        try await until { editor.string == "ello world" }

        type("w", "c", "w")
        try await until { status == "INSERT" && !field.caretEditor.blockCaret }
        type("t", "h", "e", "r", "e", "\u{1b}")
        try await until { editor.string == "ello there" && status == "NORMAL" }
        #expect(editor.selectedRange == NSRange(location: 9, length: 0))

        type("0", "v", "e")
        try await until { status == "VISUAL" && editor.selectedRange == NSRange(location: 0, length: 4) }
        type("\u{1b}")
        try await until { status == "NORMAL" }

        editor.selectedRange = NSRange(location: 2, length: 0) // a mouse click
        type("x")
        try await until { editor.string == "elo there" }

        editor.selectedRange = NSRange(location: 9, length: 0) // a paste at the end
        (editor as? NSTextView)?.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await until { editor.selectedRange.location == 9 } // Neovim clamped the pasted-past-the-end caret
        type("u")
        try await until { editor.string == "elo there" }

        type(":", "q", "!", "\r")
        try await until { status == "nvim exited" && !field.caretEditor.blockCaret }
        #expect(coordinator.handleKeyDown(keyDown("x", window: window)) != nil)
    }
}

@MainActor
private func keyDown(
    _ characters: String,
    _ modifiers: NSEvent.ModifierFlags = [],
    ignoringModifiers: String? = nil,
    window: NSWindow? = nil
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
        charactersIgnoringModifiers: ignoringModifiers ?? characters, isARepeat: false, keyCode: 0
    )!
}

private struct TimedOut: Error {}

@MainActor
private func until(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting at line \(sourceLocation.line)", sourceLocation: sourceLocation)
            throw TimedOut()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
