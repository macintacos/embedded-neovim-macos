//
//  Neovim.swift
//  embedded-macos
//

import Foundation

/// A 0-based line and UTF-8 byte column — how Neovim addresses buffer positions.
struct TextPosition: Equatable {
    var row: Int
    var byteColumn: Int
}

/// What the embedded Neovim reports after every change of mode, text, or cursor.
struct NeovimState: Equatable {
    var mode: String
    var lines: [String]
    var cursor: TextPosition
    /// The other end of the visual selection; equals `cursor` outside visual mode.
    var anchor: TextPosition
    /// The command line being typed, prefixed by its type (`:`, `/`, `?`), or empty.
    var cmdline: String
}

extension NeovimState {
    /// Parses the arguments of the `state` notification sent by `Neovim.startScript`.
    init?(_ params: [MessagePack]) {
        guard params.count == 7,
              let mode = params[0].string,
              let lines = params[1].array?.compactMap(\.string),
              let cursorRow = params[2].int, let cursorColumn = params[3].int,
              let anchorRow = params[4].int, let anchorColumn = params[5].int,
              let cmdline = params[6].string
        else { return nil }
        self.init(
            mode: mode,
            lines: lines,
            cursor: TextPosition(row: cursorRow, byteColumn: cursorColumn),
            anchor: TextPosition(row: anchorRow, byteColumn: anchorColumn),
            cmdline: cmdline
        )
    }
}

/// UTF-16 offset of `position` in `lines` joined by newlines — the indexing NSText uses.
func utf16Offset(of position: TextPosition, in lines: [String]) -> Int {
    let row = min(position.row, lines.count - 1)
    let precedingLines = lines[..<row].reduce(0) { $0 + $1.utf16.count + 1 }
    let column = String(decoding: lines[row].utf8.prefix(position.byteColumn), as: UTF8.self)
    return precedingLines + column.utf16.count
}

func textPosition(ofUTF16Offset offset: Int, in text: String) -> TextPosition {
    let linesBefore = (text as NSString).substring(to: offset).components(separatedBy: "\n")
    return TextPosition(row: linesBefore.count - 1, byteColumn: linesBefore.last!.utf8.count)
}

/// A headless `nvim --embed` child process, driven over msgpack-RPC on its stdin/stdout.
final class Neovim {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var received: [UInt8] = []
    private let onState: (NeovimState) -> Void

    /// Finds `nvim` on `searchPath`, then in the Homebrew prefixes that apps launched from Finder don't have on PATH.
    static func locate(searchPath: String) -> URL? {
        (searchPath.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"])
            .map { URL(fileURLWithPath: $0).appendingPathComponent("nvim") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Starts Neovim editing `lines`. `onState` and `onExit` are called on the main queue.
    init(
        executable: URL,
        lines: [String],
        cursor: TextPosition,
        onState: @escaping (NeovimState) -> Void,
        onExit: @escaping () -> Void
    ) throws {
        self.onState = onState
        process.executableURL = executable
        // --clean: no user config or plugins, no shada. -n: no swap file.
        process.arguments = ["--embed", "--headless", "--clean", "-n"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in DispatchQueue.main.async(execute: onExit) }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { self?.receive(data) }
        }
        // Writing after nvim exits (e.g. the user ran `:q`) must fail with EPIPE, not kill the app.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()

        notify("nvim_exec_lua", .string(Self.startScript), .array([
            .array(lines.map(MessagePack.string)), .int(cursor.row), .int(cursor.byteColumn),
        ]))
    }

    /// Types `keys`, written in Neovim's key notation (`<Esc>`, `<C-r>`, `<lt>` for `<`).
    func send(keys: String) {
        notify("nvim_input", .string(keys))
    }

    /// Replaces the whole buffer as one undoable change.
    func replace(lines: [String], cursor: TextPosition) {
        notify("nvim_buf_set_lines", .int(0), .int(0), .int(-1), .bool(false), .array(lines.map(MessagePack.string)))
        notify("nvim_win_set_cursor", .int(0), .array([.int(cursor.row + 1), .int(cursor.byteColumn)]))
    }

    /// Closing its RPC channel makes Neovim exit.
    func quit() {
        process.terminationHandler = nil
        try? stdin.fileHandleForWriting.close()
    }

    /// API calls go out as notifications: Neovim runs them in order and we never wait on a reply.
    private func notify(_ method: String, _ params: MessagePack...) {
        let message = pack(.array([.int(2), .string(method), .array(params)]))
        try? stdin.fileHandleForWriting.write(contentsOf: message)
    }

    private func receive(_ data: Data) {
        received.append(contentsOf: data)
        do {
            while let (message, length) = try unpack(received) {
                received.removeFirst(length)
                handle(message)
            }
        } catch {
            assertionFailure("Undecodable message from Neovim: \(error)")
            received.removeAll()
        }
    }

    private func handle(_ message: MessagePack) {
        guard let parts = message.array, parts.count == 3, parts[0] == .int(2),
              let params = parts[2].array
        else { return }
        switch parts[1].string {
        case "state": if let state = NeovimState(params) { onState(state) }
        case "nvim_error_event": print("Neovim error:", params)
        default: break
        }
    }

    /// Loads the initial text outside undo history, then reports state on every change.
    private static let startScript = """
        local lines, row, col = ...
        local undolevels = vim.o.undolevels
        vim.o.undolevels = -1
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.o.undolevels = undolevels
        vim.api.nvim_win_set_cursor(0, { row + 1, col })

        local function sync()
          local cursor = vim.api.nvim_win_get_cursor(0)
          local anchor = vim.fn.getpos('v')
          vim.rpcnotify(0, 'state', vim.api.nvim_get_mode().mode, vim.api.nvim_buf_get_lines(0, 0, -1, false),
            cursor[1] - 1, cursor[2], anchor[2] - 1, anchor[3] - 1, vim.fn.getcmdtype() .. vim.fn.getcmdline())
        end
        vim.api.nvim_create_autocmd({ 'ModeChanged', 'TextChanged', 'TextChangedI', 'TextChangedP',
          'CursorMoved', 'CursorMovedI', 'CmdlineChanged' }, { callback = sync })
        sync()
        """
}
