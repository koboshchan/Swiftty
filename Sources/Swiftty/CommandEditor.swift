import AppKit
import SwiftUI

/// The command line, as a real text editor rather than a terminal line.
///
/// Typing goes here instead of straight to the shell, so the caret can be
/// placed with the mouse, text selected and edited with the shortcuts every
/// other macOS app uses, and a command spread over several lines. The whole
/// line is handed to the shell only when it is submitted.
///
/// The shell's own line editor is left switched on and simply never sees
/// interactive typing — a submitted command arrives the way a paste would.
/// That is what keeps prompt themes, aliases and shell functions working.
struct CommandEditor: NSViewRepresentable {
    @Binding var text: String
    /// The greyed-out completion shown after the caret, if any.
    var suggestion: String
    var fontSize: Double
    var onSubmit: (String) -> Void
    var onHistory: (Int) -> Void
    var onAcceptSuggestion: () -> Void
    var onEscape: () -> Void
    /// Bumped to pull the caret back here from wherever it went.
    var focusRequests: Int
    /// Expands the token under the caret; returns the new text and caret.
    var onComplete: (String, Int) -> (String, Int)?
    var onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CommandTextView {
        let view = CommandTextView()
        view.delegate = context.coordinator
        view.commandDelegate = context.coordinator
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.backgroundColor = .clear
        view.insertionPointColor = NSColor(calibratedRed: 0.72, green: 0.55, blue: 0.98, alpha: 1)
        view.textContainerInset = NSSize(width: 0, height: 0)
        view.textContainer?.lineFragmentPadding = 0
        // Quote and dash substitution mangle shell syntax into characters the
        // shell does not understand.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)

        return view
    }

    func updateNSView(_ view: CommandTextView, context: Context) {
        context.coordinator.parent = self

        // The font only changes when the size does, but setting it re-lays out
        // the text — so touch it only when it actually differs, and re-measure
        // the height just then. Typing reports its own height from
        // textDidChange, so the common update path does no measuring at all.
        let fontChanged = context.coordinator.lastFontSize != fontSize
        if fontChanged {
            context.coordinator.lastFontSize = fontSize
            view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            view.applyHighlighting()
        }

        // An explicit request wins outright — it means something that had the
        // keyboard, the find bar say, has just gone away and the caret belongs
        // back here. `claimFocusFromTerminal` deliberately will not take focus
        // from another text field, so it cannot cover that case on its own.
        if focusRequests != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequests
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else {
            view.claimFocusFromTerminal()
        }

        if view.string != text {
            view.string = text
            view.applyHighlighting()
        }
        if view.suggestion != suggestion {
            view.suggestion = suggestion
            view.needsDisplay = true
        }

        if fontChanged {
            DispatchQueue.main.async {
                let height = view.contentHeight
                if abs(height - context.coordinator.lastReportedHeight) > 0.5 {
                    context.coordinator.lastReportedHeight = height
                    onHeightChange(height)
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, CommandTextViewDelegate {
        var parent: CommandEditor
        var lastReportedHeight: CGFloat = 0
        var lastFocusRequest = 0
        var lastFontSize: Double = 0

        init(_ parent: CommandEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? CommandTextView else { return }
            parent.text = view.string
            view.applyHighlighting()

            let height = view.contentHeight
            if abs(height - lastReportedHeight) > 0.5 {
                lastReportedHeight = height
                parent.onHeightChange(height)
            }
        }

        func commandTextViewDidSubmit(_ view: CommandTextView) {
            let command = view.string
            view.string = ""
            parent.text = ""
            parent.onSubmit(command)
        }

        func commandTextView(_ view: CommandTextView, didRequestHistory offset: Int) {
            parent.onHistory(offset)
        }

        func commandTextViewDidAcceptSuggestion(_ view: CommandTextView) {
            parent.onAcceptSuggestion()
        }

        func commandTextViewDidEscape(_ view: CommandTextView) {
            parent.onEscape()
        }

        func commandTextViewDidRequestCompletion(_ view: CommandTextView) {
            let caret = view.selectedRange().location
            guard let (text, newCaret) = parent.onComplete(view.string, caret) else { return }
            view.string = text
            view.applyHighlighting()
            view.setSelectedRange(NSRange(location: min(newCaret, (text as NSString).length), length: 0))
            parent.text = text
        }
    }
}

@MainActor
protocol CommandTextViewDelegate: AnyObject {
    func commandTextViewDidSubmit(_ view: CommandTextView)
    func commandTextView(_ view: CommandTextView, didRequestHistory offset: Int)
    func commandTextViewDidAcceptSuggestion(_ view: CommandTextView)
    func commandTextViewDidRequestCompletion(_ view: CommandTextView)
    func commandTextViewDidEscape(_ view: CommandTextView)
}

/// An `NSTextView` that behaves like a shell prompt: Return submits, the arrow
/// keys reach for history at the edges of the text, and a greyed-out suggestion
/// trails the caret.
final class CommandTextView: NSTextView {
    weak var commandDelegate: CommandTextViewDelegate?
    var suggestion: String = ""

    /// Height the text actually occupies, so the editor can grow with content.
    var contentHeight: CGFloat {
        guard let layoutManager, let textContainer else { return 20 }
        layoutManager.ensureLayout(for: textContainer)
        return max(layoutManager.usedRect(for: textContainer).height, 18)
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimFocusFromTerminal()
    }

    /// Takes the keyboard from the terminal when the editor is on screen.
    ///
    /// The terminal is hidden behind the editor but still a live view, and if
    /// it holds first responder the keystrokes meant for the editor go into the
    /// shell's own line buffer instead — invisibly, since the terminal is not
    /// drawn. They then get prepended to whatever is submitted next, turning
    /// `ls -la` into `lsls -la`.
    ///
    /// Only the terminal and an unfocused window are taken from, so clicking
    /// into the sidebar or a settings field is never interrupted.
    func claimFocusFromTerminal() {
        guard let window, window.firstResponder !== self else { return }
        let holder = window.firstResponder
        guard holder is SwifttyTerminalView || holder === window else { return }
        window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)

        switch event.keyCode {
        case 36, 76:  // Return, Enter
            // Shift-Return and Cmd-Return both open a new line — the card
            // advertises Cmd-Return, and Shift-Return is the habit most
            // shells and chat apps have already taught.
            if shift || command {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                commandDelegate?.commandTextViewDidSubmit(self)
            }
            return

        case 126 where !command:  // Up
            // Only reach for history from the top line, so the arrow keys still
            // navigate a multi-line command the way they would anywhere else.
            if isOnFirstLine {
                commandDelegate?.commandTextView(self, didRequestHistory: -1)
                return
            }

        case 125 where !command:  // Down
            if isOnLastLine {
                commandDelegate?.commandTextView(self, didRequestHistory: 1)
                return
            }

        case 53:  // Escape
            commandDelegate?.commandTextViewDidEscape(self)
            return

        case 48:  // Tab
            // The ghost suggestion is the more specific thing on offer, so Tab
            // takes it when there is one and falls back to expanding the token.
            if !suggestion.isEmpty, isCaretAtEnd {
                commandDelegate?.commandTextViewDidAcceptSuggestion(self)
            } else {
                commandDelegate?.commandTextViewDidRequestCompletion(self)
            }
            return

        case 124:  // Right
            if !suggestion.isEmpty, isCaretAtEnd {
                commandDelegate?.commandTextViewDidAcceptSuggestion(self)
                return
            }

        default:
            break
        }

        // Ctrl-F accepts the suggestion too, matching shell autosuggest plugins.
        if event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers == "f",
           !suggestion.isEmpty, isCaretAtEnd {
            commandDelegate?.commandTextViewDidAcceptSuggestion(self)
            return
        }

        super.keyDown(with: event)
    }

    private var caretLocation: Int {
        selectedRange().location
    }

    private var isCaretAtEnd: Bool {
        selectedRange().location + selectedRange().length >= (string as NSString).length
    }

    private var isOnFirstLine: Bool {
        let text = string as NSString
        guard text.length > 0 else { return true }
        let upToCaret = text.substring(to: min(caretLocation, text.length))
        return !upToCaret.contains("\n")
    }

    private var isOnLastLine: Bool {
        let text = string as NSString
        guard text.length > 0 else { return true }
        let afterCaret = text.substring(from: min(caretLocation, text.length))
        return !afterCaret.contains("\n")
    }

    // MARK: - Suggestion

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !suggestion.isEmpty,
              let layoutManager,
              let textContainer,
              let font else { return }

        let text = string as NSString
        let origin: NSPoint
        if text.length == 0 {
            origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        } else {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: text.length - 1, length: 1),
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            origin = NSPoint(
                x: rect.maxX + textContainerInset.width,
                y: rect.minY + textContainerInset.height
            )
        }

        (suggestion as NSString).draw(at: origin, withAttributes: [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.28),
        ])
    }

    // MARK: - Highlighting

    /// Colors the command the way an editor would: the program name, its flags,
    /// quoted strings and the operators joining commands together.
    func applyHighlighting() {
        guard let storage = textStorage, let font else { return }
        let full = NSRange(location: 0, length: (string as NSString).length)

        storage.beginEditing()
        storage.setAttributes([
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.90, alpha: 1),
        ], range: full)

        for token in CommandSyntax.tokens(in: string) {
            storage.addAttribute(.foregroundColor, value: token.kind.color, range: token.range)
            if token.kind == .command {
                storage.addAttribute(
                    .font,
                    value: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold),
                    range: token.range
                )
            }
        }
        storage.endEditing()
    }
}

/// A deliberately small shell tokenizer — enough to tint a command line, not to
/// parse one. Anything it cannot classify is simply left in the default color.
enum CommandSyntax {
    enum Kind {
        case command
        case flag
        case string
        case op

        var color: NSColor {
            switch self {
            case .command: return NSColor(calibratedRed: 0.55, green: 0.80, blue: 1.00, alpha: 1)
            case .flag: return NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.45, alpha: 1)
            case .string: return NSColor(calibratedRed: 0.60, green: 0.90, blue: 0.63, alpha: 1)
            case .op: return NSColor(calibratedRed: 0.80, green: 0.60, blue: 0.98, alpha: 1)
            }
        }
    }

    struct Token {
        let range: NSRange
        let kind: Kind
    }

    static func tokens(in source: String) -> [Token] {
        let text = source as NSString
        var tokens: [Token] = []
        var index = 0
        // The first word of the line, and of anything after a `|` or `&&`, is a
        // program name rather than an argument.
        var expectingCommand = true

        while index < text.length {
            let character = text.character(at: index)
            let scalar = Character(UnicodeScalar(character) ?? " ")

            if scalar == " " || scalar == "\t" || scalar == "\n" {
                index += 1
                continue
            }

            if scalar == "\"" || scalar == "'" {
                let start = index
                index += 1
                while index < text.length,
                      Character(UnicodeScalar(text.character(at: index)) ?? " ") != scalar {
                    index += 1
                }
                if index < text.length { index += 1 }
                tokens.append(Token(range: NSRange(location: start, length: index - start), kind: .string))
                continue
            }

            if "|&;><".contains(scalar) {
                let start = index
                while index < text.length,
                      "|&;><".contains(Character(UnicodeScalar(text.character(at: index)) ?? " ")) {
                    index += 1
                }
                tokens.append(Token(range: NSRange(location: start, length: index - start), kind: .op))
                expectingCommand = true
                continue
            }

            let start = index
            while index < text.length {
                let next = Character(UnicodeScalar(text.character(at: index)) ?? " ")
                if next == " " || next == "\t" || next == "\n" || "|&;><\"'".contains(next) { break }
                index += 1
            }
            let range = NSRange(location: start, length: index - start)
            let word = text.substring(with: range)

            if word.hasPrefix("-") {
                tokens.append(Token(range: range, kind: .flag))
            } else if expectingCommand {
                tokens.append(Token(range: range, kind: .command))
                expectingCommand = false
            }
        }

        return tokens
    }
}
