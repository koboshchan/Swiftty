import AppKit
import MetalKit
import SwiftTerm
import SwiftUI

/// A `LocalProcessTerminalView` that reports repaints, so the tracker can spot
/// a full-screen program taking over the screen.
final class SwifttyTerminalView: LocalProcessTerminalView {
    weak var blockTracker: BlockTracker?

    /// Height of one terminal row, in points.
    ///
    /// SwiftTerm keeps its own `cellDimension` internal, and dividing the view
    /// height by `terminal.rows` would not do: the row count is a *floor*, so
    /// the leftover slack would inflate the result. This mirrors SwiftTerm's
    /// `computeFontDimensions`, pixel snapping and all, so asking for N rows'
    /// worth of height yields exactly N rows.
    var cellHeight: CGFloat {
        let ctFont = font as CTFont
        let lineHeight = CTFontGetAscent(ctFont)
            + CTFontGetDescent(ctFont)
            + CTFontGetLeading(ctFont)
        let raw = ceil(lineHeight * lineSpacing)
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        return min(max(1, ceil(raw * scale) / scale), 8192)
    }

    /// Lets the frosted window backdrop show through the terminal.
    ///
    /// Three layers all default to opaque and each would block the desktop on
    /// its own: the view's own layer, the Metal layer SwiftTerm renders into,
    /// and the clear color, which the Metal renderer takes straight from
    /// `nativeBackgroundColor` — including its alpha.
    ///
    /// SwiftTerm rebuilds its `MTKView` when the window changes, which discards
    /// these settings — so the opacity is remembered and reapplied whenever a
    /// fresh, still-opaque Metal layer turns up.
    private var backgroundOpacity: Double = 1

    func applyBackground(opacity: Double) {
        backgroundOpacity = opacity
        let translucent = opacity < 0.99
        nativeBackgroundColor = Surface.terminal(opacity)

        wantsLayer = true
        layer?.isOpaque = !translucent
        layer?.backgroundColor = Surface.terminal(opacity).cgColor

        for subview in subviews {
            guard subview is MTKView else { continue }
            subview.layer?.isOpaque = !translucent
            subview.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    /// The Metal view whose transparency has already been set, so the per-frame
    /// heal below can skip the moment nothing has changed.
    private weak var healedMetalView: MTKView?

    /// Reapplies transparency if SwiftTerm has swapped in a new Metal view.
    ///
    /// Setting it once at creation is not enough: attaching to a window rebuilds
    /// the `MTKView`, and the replacement arrives opaque, which is what left the
    /// terminal a solid black band while the rest of the window was see-through.
    ///
    /// This runs on every repaint, so it must stay cheap: it only acts when the
    /// current Metal view is one it has not already fixed. In the steady state —
    /// which is every frame of output — it is a single identity comparison.
    private func healTransparencyIfNeeded() {
        guard backgroundOpacity < 0.99 else { return }
        let current = subviews.first { $0 is MTKView } as? MTKView
        guard current !== healedMetalView else { return }
        applyBackground(opacity: backgroundOpacity)
        healedMetalView = current
    }

    private var cursorBlinks = true

    /// Steady vs blinking block cursor, via the standard DECSCUSR sequence.
    ///
    /// A blinking caret redraws the view twice a second forever, waking the GPU
    /// even at an idle prompt — so honouring "steady" is a real, if small,
    /// energy win, not only a cosmetic preference. Programs can still override
    /// with their own DECSCUSR; this just sets the default.
    func setCursorBlink(_ blinks: Bool) {
        guard blinks != cursorBlinks else { return }
        cursorBlinks = blinks
        terminal?.feed(text: blinks ? "\u{1b}[1 q" : "\u{1b}[2 q")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        healedMetalView = nil
        applyBackground(opacity: backgroundOpacity)
    }

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        healTransparencyIfNeeded()
        blockTracker?.terminalStateChanged()
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        // The shell never sends a D marker for its own exit, so close out
        // whatever was still running before the delegate tears things down.
        blockTracker?.shellExited()
        super.processTerminated(source, exitCode: exitCode)
    }
}

// MARK: - Styling

/// Measurements and colors for the block surface.
///
/// Blocks run full width with hairline rules between them rather than sitting
/// in inset rounded cards, and only failures carry an accent bar and a colored
/// wash. The generous padding is deliberate — it is what makes a wall of
/// terminal output read as discrete, calm units.
private enum BlockStyle {
    static let leadingPadding: CGFloat = 26
    static let trailingPadding: CGFloat = 22
    static let accentWidth: CGFloat = 4

    /// Compact mode tightens the vertical rhythm to fit more on screen; the
    /// horizontal inset stays put so the left edge never moves.
    static func verticalPadding(compact: Bool) -> CGFloat { compact ? 9 : 21 }
    static func headerGap(compact: Bool) -> CGFloat { compact ? 3 : 8 }
    static func outputGap(compact: Bool) -> CGFloat { compact ? 5 : 15 }

    // Sized off the user's chosen font so ⌘+/⌘- scale the whole block, not
    // just the live terminal. Output matches the terminal exactly; the command
    // is a touch larger and bold, the meta line a touch smaller and muted.
    static func outputFont(_ size: Double) -> Font {
        .system(size: size, design: .monospaced)
    }
    static func commandFont(_ size: Double) -> Font {
        .system(size: size + 1, weight: .bold, design: .monospaced)
    }
    static func metaFont(_ size: Double) -> Font {
        .system(size: max(9, size - 2), design: .monospaced)
    }

    static let failure = SwiftUI.Color(red: 0.95, green: 0.45, blue: 0.42)
    static let meta = SwiftUI.Color(red: 0.55, green: 0.56, blue: 0.60)
    static let command = SwiftUI.Color(red: 0.93, green: 0.94, blue: 0.96)
    static let rule = SwiftUI.Color.white.opacity(0.055)
    static let placeholder = SwiftUI.Color(white: 0.62)
    static let hint = SwiftUI.Color(white: 0.45)
    static let chipText = SwiftUI.Color(white: 0.78)
    static let searchRing = SwiftUI.Color(red: 0.98, green: 0.78, blue: 0.35).opacity(0.7)
    static let promptRemote = SwiftUI.Color(red: 0.55, green: 0.85, blue: 0.98)

    static func background(
        _ state: CommandBlock.State,
        selected: Bool,
        hovered: Bool
    ) -> SwiftUI.Color {
        if selected { return SwiftUI.Color.accentColor.opacity(0.14) }
        if state.failed { return failure.opacity(hovered ? 0.115 : 0.085) }
        return SwiftUI.Color.white.opacity(hovered ? 0.035 : 0)
    }
}

/// Marks search hits inside text that already carries its own styling.
enum SearchHighlight {
    private static let fill = SwiftUI.Color(red: 0.98, green: 0.78, blue: 0.35).opacity(0.32)

    static func mark(_ source: String, query: String) -> AttributedString {
        mark(AttributedString(source), query: query)
    }

    /// Adds a highlight behind every occurrence, leaving the ANSI colors the
    /// output already carries untouched.
    static func mark(_ source: AttributedString, query: String) -> AttributedString {
        guard !query.isEmpty else { return source }

        var result = source
        var cursor = result.startIndex
        while cursor < result.endIndex,
              let range = result[cursor...].range(of: query, options: [.caseInsensitive]) {
            result[range].backgroundColor = fill
            cursor = range.upperBound
        }
        return result
    }
}

/// The text field inside the find bar.
///
/// Split out so it can own the `@FocusState` that ⌘F drives, and so Escape
/// closes the bar rather than falling through to the command editor.
private struct FindField: View {
    @Binding var text: String
    var focusRequests: Int
    var onSubmit: () -> Void
    var onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Find", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($isFocused)
            .onSubmit(onSubmit)
            .onExitCommand(perform: onCancel)
            .onAppear { isFocused = true }
            .onChange(of: focusRequests) { _, _ in isFocused = true }
    }
}

/// How many past commands the history palette shows at once.
private let historyWindowSize = 9

// MARK: - Block surface

/// The main terminal surface: finished commands stacked as blocks, with the
/// live terminal at the bottom as the block being typed into.
struct BlockStack<Terminal: View>: View {
    @ObservedObject var tracker: BlockTracker
    let terminal: Terminal
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var store: TerminalStore

    @State private var draft = ""
    @State private var editorHeight: CGFloat = 18
    /// How far back through history the up-arrow has walked. -1 is the draft
    /// the user was writing before they started browsing.
    @State private var historyIndex = -1
    @State private var stashedDraft = ""
    /// The history palette is open while the arrow keys are browsing.
    @State private var historyOpen = false
    /// Bumped whenever the caret should return to the command editor.
    @State private var editorFocusRequests = 0

    /// Blocks only make sense while the shell is at a prompt: there is nothing
    /// to show before the integration loads, and a full-screen program like vim
    /// owns the whole screen, so it gets the whole view until it exits.
    private var showsBlocks: Bool {
        tracker.isIntegrationActive && !tracker.isAlternateScreen
    }

    var body: some View {
        GeometryReader { proxy in
            // The terminal is deliberately NOT inside the scroll view, and
            // appears exactly once in exactly one place in this hierarchy.
            //
            // It is an NSViewRepresentable owning a live shell: whenever
            // SwiftUI decides it has a new identity it tears the old view down
            // and builds another, and every rebuild forks another zsh. A
            // `LazyVStack` recycles its children as they scroll, and an
            // `if/else` that renders the terminal in both branches counts as
            // two different views — either one silently accumulates orphaned
            // shells, and typing then goes to whichever one is no longer on
            // screen. Blocks scroll above it; this stays put.
            VStack(spacing: 0) {
                if showsBlocks {
                    blockHistory
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Collapsed to nothing while the shell waits at a prompt. The
                // composer floats over the blocks instead of sitting in a slot
                // of its own, and a slot with any height would show its own
                // full-width background as a band beneath the card.
                liveBlock(viewport: proxy.size.height)
                    .frame(height: showsBlocks
                        ? (tracker.runningBlock == nil ? 0 : runningHeight(viewport: proxy.size.height))
                        : nil)
            }
            .overlay(alignment: .top) {
                if store.searchVisible {
                    findBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // Closing the find bar, or a command finishing, hands the caret
            // back to the editor — it is where typing goes, so it should never
            // be left without focus.
            .onChange(of: store.searchVisible) { _, visible in
                if !visible { editorFocusRequests += 1 }
            }
            .onChange(of: tracker.runningBlock?.id) { _, running in
                if running == nil { editorFocusRequests += 1 }
            }
            .onChange(of: tracker.isSubmitting) { _, submitting in
                if !submitting { editorFocusRequests += 1 }
            }
            .animation(.easeOut(duration: 0.2), value: store.searchVisible)
            .animation(.easeOut(duration: 0.2), value: tracker.runningBlock?.id)
            .animation(.easeOut(duration: 0.18), value: historyOpen)
            .overlay(alignment: .bottom) {
                if showsBlocks, tracker.runningBlock == nil, !tracker.isSubmitting {
                    VStack(spacing: 0) {
                        if historyOpen, !historyWindow.isEmpty {
                            historyPalette
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        promptEditor
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private var searchQuery: String {
        store.searchQuery.trimmingCharacters(in: .whitespaces)
    }

    /// Blocks containing the search term, in order.
    ///
    /// Search highlights and scrolls rather than filtering: hiding the
    /// non-matching blocks throws away the surrounding output, which is usually
    /// the reason for going looking in the first place.
    private var searchMatches: [CommandBlock.ID] {
        guard !searchQuery.isEmpty else { return [] }
        return tracker.blocks
            .filter { block in
                block.command.localizedCaseInsensitiveContains(searchQuery)
                    || String(block.output.characters)
                        .localizedCaseInsensitiveContains(searchQuery)
            }
            .map(\.id)
    }

    /// The match Return has stepped to, wrapping at both ends.
    private var currentMatch: CommandBlock.ID? {
        let matches = searchMatches
        guard !matches.isEmpty else { return nil }
        let index = ((store.searchMatchIndex % matches.count) + matches.count) % matches.count
        return matches[index]
    }

    /// Floats over the blocks only while searching, rather than taking a slot
    /// in the toolbar for something used occasionally.
    private var findBar: some View {
        let matches = searchMatches
        let position = matches.isEmpty
            ? 0
            : ((store.searchMatchIndex % matches.count) + matches.count) % matches.count + 1

        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            FindField(text: $store.searchQuery, focusRequests: store.searchFocusRequests) {
                store.advanceSearchMatch()
            } onCancel: {
                store.endSearch()
            }

            Text("\(position)/\(matches.count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(BlockStyle.hint)
                .monospacedDigit()

            findButton("chevron.down", "Next match (return)") { store.advanceSearchMatch() }
            findButton("chevron.up", "Previous match") { store.advanceSearchMatch(by: -1) }
            findButton("xmark", "Close (esc)") { store.endSearch() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 420)
        .background(SwiftUI.Color(nsColor: NSColor(calibratedWhite: 0.15, alpha: 0.96)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(SwiftUI.Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.black.opacity(0.4), radius: 16, y: 6)
        .padding(.top, 10)
    }

    private func findButton(
        _ systemName: String,
        _ help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var blockHistory: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tracker.blocks) { block in
                        BlockView(
                            block: block,
                            tracker: tracker,
                            searchQuery: searchQuery,
                            isCurrentMatch: block.id == currentMatch
                        )
                            .id(block.id)
                            // New blocks rise into place instead of appearing
                            // fully formed, which makes it obvious which one
                            // just finished.
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                // Keyed on count, not a mapped id array: blocks only ever
                // append or trim from the front, so count captures every change
                // without allocating an array of every id each render.
                .animation(.easeOut(duration: 0.22), value: tracker.blocks.count)
                .padding(.bottom, tracker.runningBlock == nil && !tracker.isSubmitting ? composerHeight : 0)
            }
            // Blocks stack up from the bottom, so they meet the prompt sitting
            // just below them instead of leaving a gap in a fresh session.
            .defaultScrollAnchor(.bottom)
            .onChange(of: tracker.blocks.count) { _, _ in
                guard let last = tracker.blocks.last else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    scroller.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: tracker.selectedBlockID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    scroller.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: currentMatch) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    scroller.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    /// The command composer: a floating card carrying the context you are
    /// typing into, the editor itself, and what the Return key will do.
    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 13) {
            contextChips

            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Run a command…")
                            .font(.system(size: preferences.terminalFontSize, design: .monospaced))
                            .foregroundStyle(BlockStyle.placeholder)
                            .allowsHitTesting(false)
                    }

                    CommandEditor(
                        text: $draft,
                        suggestion: suggestion,
                        fontSize: preferences.terminalFontSize,
                        onSubmit: submit,
                        onHistory: walkHistory,
                        onAcceptSuggestion: { draft += suggestion },
                        onEscape: dismissHistory,
                        focusRequests: editorFocusRequests,
                        onComplete: completeToken,
                        onHeightChange: { editorHeight = $0 }
                    )
                    .frame(height: editorHeight)
                }

                Spacer(minLength: 8)

                Image(systemName: "return")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BlockStyle.hint)
            }

            HStack(spacing: 16) {
                hint("return", "send command to shell")
                hint("command", "new line", secondSymbol: "return")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // A warm sheen across the top-left, so the card catches light
            // instead of sitting flat on the background.
            LinearGradient(
                colors: [
                    SwiftUI.Color.white.opacity(0.055),
                    SwiftUI.Color.white.opacity(0.012),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .background(Color(nsColor: NSColor(calibratedWhite: 0.14, alpha: 0.88)))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(SwiftUI.Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.black.opacity(0.45), radius: 20, y: 8)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// Expands the token under the caret against PATH and the filesystem.
    private func completeToken(_ text: String, _ caret: Int) -> (String, Int)? {
        // Remote sessions resolve paths on the far end. A miss returns nil and
        // fires a request, so a second Tab completes once the answer lands.
        let lister: Completion.Lister? = tracker.subshell == nil ? nil : { path in
            if let entries = tracker.remoteEntries(for: path) { return entries }
            tracker.requestRemoteListing(path)
            return nil
        }

        guard let result = Completion.complete(
            text: text,
            caret: caret,
            directory: tracker.workingDirectory,
            lister: lister
        ) else { return nil }
        return (result.text, result.caret)
    }

    /// Where the command will run: which shell, which directory, which branch.
    private var contextChips: some View {
        HStack(spacing: 7) {
            if let subshell = tracker.subshell {
                // Standing in for the shell chip: while a subshell is driving,
                // the local shell is not what these commands run in.
                chip("link", subshell)
                    .foregroundStyle(BlockStyle.promptRemote)
            } else {
                chip("terminal", shellName)
            }
            chip("folder", tracker.directoryLabel)
            if let branch = tracker.gitBranch, !branch.isEmpty {
                chip("arrow.triangle.branch", branch)
            }
        }
    }

    private var shellName: String {
        let path = preferences.shellPath.trimmingCharacters(in: .whitespaces)
        let name = (path.isEmpty ? ShellInfo.path : path as String) as NSString
        return name.lastPathComponent
    }

    private func chip(_ systemName: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .medium))
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .foregroundStyle(BlockStyle.chipText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(SwiftUI.Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(SwiftUI.Color.white.opacity(0.09), lineWidth: 1)
        }
    }

    private func hint(
        _ symbol: String,
        _ label: String,
        secondSymbol: String? = nil
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            if let secondSymbol {
                Image(systemName: secondSymbol)
            }
            Text(label)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(BlockStyle.hint)
    }

    /// Everything in the card that is not the editor itself: chips, hints,
    /// padding and the gaps between them.
    private var promptChrome: CGFloat { 22 + 13 + 13 + 14 + 34 + 10 }

    /// The completion trailing the caret, suppressed while browsing history so
    /// it does not fight with what the arrow keys just inserted.
    private var suggestion: String {
        guard historyIndex == -1 else { return "" }
        return tracker.suggestion(for: draft) ?? ""
    }

    private func submit(_ command: String) {
        historyOpen = false
        historyIndex = -1
        stashedDraft = ""
        draft = ""
        tracker.submit(command)
    }

    /// Walks the history list; `offset` is -1 for older, +1 for newer.
    ///
    /// Browsing fills the editor as it goes, so Return runs the highlighted
    /// command without a separate confirm step and Escape puts back whatever
    /// was being written.
    private func walkHistory(_ offset: Int) {
        let history = tracker.commandHistory
        guard !history.isEmpty else { return }

        // Stash whatever was being written before the first step back, so
        // coming forward again returns it rather than an empty line.
        if historyIndex == -1, offset < 0 { stashedDraft = draft }

        let next = historyIndex - offset
        if next < 0 {
            historyIndex = -1
            historyOpen = false
            draft = stashedDraft
        } else {
            historyIndex = min(next, history.count - 1)
            historyOpen = true
            draft = history[historyIndex].command
        }
    }

    /// Escape closes the palette and restores the draft it interrupted.
    private func dismissHistory() {
        guard historyOpen else { return }
        historyOpen = false
        historyIndex = -1
        draft = stashedDraft
    }

    /// Which slice of history the palette shows.
    ///
    /// The window follows the selection instead of being pinned to the newest
    /// entries: walking past the end of a fixed slice would keep filling the
    /// editor while the list sat still, leaving nothing highlighted and no
    /// sense of where in history you were.
    private var historyWindow: Range<Int> {
        let count = tracker.commandHistory.count
        guard count > 0 else { return 0..<0 }
        let size = historyWindowSize
        let oldest = min(count - 1, max(historyIndex, size - 1))
        let newest = max(0, oldest - size + 1)
        return newest..<(oldest + 1)
    }

    private var historyPalette: some View {
        VStack(spacing: 0) {
            HStack {
                Text("HISTORY")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(BlockStyle.chipText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(alignment: .top) {
                if store.searchVisible {
                    findBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // Closing the find bar, or a command finishing, hands the caret
            // back to the editor — it is where typing goes, so it should never
            // be left without focus.
            .onChange(of: store.searchVisible) { _, visible in
                if !visible { editorFocusRequests += 1 }
            }
            .onChange(of: tracker.runningBlock?.id) { _, running in
                if running == nil { editorFocusRequests += 1 }
            }
            .onChange(of: tracker.isSubmitting) { _, submitting in
                if !submitting { editorFocusRequests += 1 }
            }
            .animation(.easeOut(duration: 0.2), value: store.searchVisible)
            .animation(.easeOut(duration: 0.2), value: tracker.runningBlock?.id)
            .animation(.easeOut(duration: 0.18), value: historyOpen)
            .overlay(alignment: .bottom) {
                Rectangle().fill(BlockStyle.rule).frame(height: 1)
            }

            VStack(spacing: 0) {
                // Oldest at the top, so the most recent sits nearest the editor
                // — the direction the up-arrow travels.
                ForEach(historyWindow.reversed(), id: \.self) { index in
                    let entry = tracker.commandHistory[index]
                    // Compared by index, not by text: duplicate commands would
                    // otherwise all light up at once.
                    let isSelected = index == historyIndex

                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right.square")
                            .font(.system(size: 10))
                            .foregroundStyle(BlockStyle.hint)

                        Text(entry.command)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(BlockStyle.command)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 12)

                        if let label = entry.relativeLabel {
                            Text(label)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(BlockStyle.hint)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(isSelected ? SwiftUI.Color.white.opacity(0.09) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { draft = entry.command }
                }
            }
            .padding(.vertical, 4)

            HStack(spacing: 8) {
                hint("arrow.up", "")
                hint("arrow.down", "to navigate")
                Text("esc")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(SwiftUI.Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(BlockStyle.hint)
                Text("to dismiss")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(BlockStyle.hint)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .top) {
                Rectangle().fill(BlockStyle.rule).frame(height: 1)
            }
        }
        .background(SwiftUI.Color(nsColor: NSColor(calibratedWhite: 0.13, alpha: 0.94)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(SwiftUI.Color.white.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.black.opacity(0.45), radius: 20, y: 8)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Height given to a running command's output.
    ///
    /// The whole window. A running command gets every point available; the
    /// history it pushes aside is one scroll away again the moment it finishes.
    ///
    /// This cannot lean on the alternate screen to decide "needs the whole
    /// window" — plenty of interactive tools, Claude Code among them, draw
    /// inline and never switch buffers, so a running command gets the room
    /// whether or not it announces itself as full-screen.
    private func runningHeight(viewport: CGFloat) -> CGFloat {
        max(300, viewport)
    }

    /// Total height of the floating composer, used to keep the block history
    /// scrollable clear of it.
    private var composerHeight: CGFloat { editorHeight + promptChrome }

    /// The running command: its meta line, and the live terminal beneath it.
    ///
    /// Collapses to nothing at a prompt, but the terminal is never removed from
    /// the hierarchy — destroying it would take its shell with it.
    private func liveBlock(viewport: CGFloat) -> some View {
        let isRunning = tracker.runningBlock != nil

        return VStack(alignment: .leading, spacing: 0) {
            // No header for a full-screen program. vim and its like assume they
            // own every row the terminal reports, so anything stacked above the
            // terminal steals rows it has already drawn into — which is what
            // was clipping the bottom of the screen off.
            if let running = tracker.runningBlock, showsBlocks {
                // One line, not two. A running command's header is a label, and
                // every point it takes is a row the program does not get —
                // which matters most for the interactive tools that need the
                // room in the first place.
                HStack(spacing: 9) {
                    Text(running.command)
                        .font(BlockStyle.commandFont(preferences.terminalFontSize))
                        .foregroundStyle(BlockStyle.command)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Text(running.metaLabel)
                        .font(BlockStyle.metaFont(preferences.terminalFontSize))
                        .foregroundStyle(BlockStyle.meta)
                        .lineLimit(1)
                        .truncationMode(.head)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, BlockStyle.leadingPadding)
                .padding(.trailing, BlockStyle.trailingPadding)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }

            // The terminal keeps one size no matter what the slot around it is
            // doing. It lives in an overlay, which unlike a child never
            // proposes its height back to the layout, so the slot can collapse
            // to nothing at a prompt while the pty stays exactly as tall.
            //
            // Letting it collapse resized the pty, and a program that draws
            // then repositions its cursor — fastfetch placing text beside its
            // logo — comes out mangled if it starts before the terminal has
            // grown back. Over SSH that race is lost routinely, because the
            // size change has to reach the far end before the program reads it.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    terminal
                        .frame(height: showsBlocks ? runningHeight(viewport: viewport) : nil)
                        .opacity(isRunning || !showsBlocks ? 1 : 0)
                        .allowsHitTesting(isRunning || !showsBlocks)
                }
                .clipped()
        }
        .clipped()
    }
}

// MARK: - One block

/// A finished command: a pinned header carrying the meta line and the command,
/// and a body carrying the output.
///
/// The meta line, the command and the output are one view sharing a single
/// background. They used to be a pinned `Section` header plus a body, but
/// SwiftUI pins *every* section header, which put an opaque band across each
/// block — the exact opposite of the soft, uniform surface this is after.
private struct BlockView: View {
    let block: CommandBlock
    @ObservedObject var tracker: BlockTracker
    var searchQuery: String = ""
    var isCurrentMatch: Bool = false
    @EnvironmentObject private var preferences: AppPreferences

    @State private var isHovered = false

    private var isSelected: Bool { tracker.selectedBlockID == block.id }

    private var padding: CGFloat {
        BlockStyle.verticalPadding(compact: preferences.compactBlocks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if block.hasOutput {
                BlockOutput(block: block, searchQuery: searchQuery, fontSize: preferences.terminalFontSize)
                    .padding(.top, BlockStyle.outputGap(compact: preferences.compactBlocks))
            }
        }
        .padding(.leading, BlockStyle.leadingPadding)
        .padding(.trailing, BlockStyle.trailingPadding)
        .padding(.vertical, padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(BlockChrome(block: block, isSelected: isSelected, isHovered: isHovered))
        .overlay {
            if isCurrentMatch {
                Rectangle()
                    .strokeBorder(BlockStyle.searchRing, lineWidth: 1.5)
            }
        }
        .animation(.easeOut(duration: 0.14), value: isCurrentMatch)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BlockStyle.rule)
                .frame(height: 1)
        }
        .onHover { isHovered = $0 }
        .onTapGesture { tracker.select(isSelected ? nil : block.id) }
        .contextMenu { BlockMenu(block: block, tracker: tracker) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: BlockStyle.headerGap(compact: preferences.compactBlocks)) {
                Text(block.metaLabel)
                    .font(BlockStyle.metaFont(preferences.terminalFontSize))
                    .foregroundStyle(block.state.failed ? BlockStyle.failure.opacity(0.9) : BlockStyle.meta)
                    .lineLimit(1)
                    .truncationMode(.head)

                Text(SearchHighlight.mark(block.command, query: searchQuery))
                    .font(BlockStyle.commandFont(preferences.terminalFontSize))
                    .foregroundStyle(BlockStyle.command)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            if isHovered {
                BlockMenuButton(block: block, tracker: tracker)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The wash and accent bar shared by a block's header and body.
private struct BlockChrome: ViewModifier {
    let block: CommandBlock
    let isSelected: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .background(
                BlockStyle.background(block.state, selected: isSelected, hovered: isHovered)
            )
            .overlay(alignment: .leading) {
                // Only failures get a bar, which is what makes them stand out
                // at a glance in a long scrollback.
                if block.state.failed {
                    Rectangle()
                        .fill(BlockStyle.failure)
                        .frame(width: BlockStyle.accentWidth)
                } else if isSelected {
                    Rectangle()
                        .fill(SwiftUI.Color.accentColor)
                        .frame(width: BlockStyle.accentWidth)
                }
            }
    }
}

private struct BlockOutput: View {
    let block: CommandBlock
    var searchQuery: String = ""
    var fontSize: Double = 13

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SearchHighlight.mark(
                isExpanded ? block.output : block.outputPreview,
                query: searchQuery
            ))
                .font(BlockStyle.outputFont(fontSize))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if block.isTruncated {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "Collapse" : "Show all \(block.outputLineCount) lines")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Actions

private struct BlockMenuButton: View {
    let block: CommandBlock
    @ObservedObject var tracker: BlockTracker

    var body: some View {
        Menu {
            BlockMenu(block: block, tracker: tracker)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .background(Color.white.opacity(0.08))
        .clipShape(Circle())
        .help("Block actions")
    }
}

private struct BlockMenu: View {
    let block: CommandBlock
    @ObservedObject var tracker: BlockTracker

    var body: some View {
        Button("Copy Command") { Pasteboard.copy(block.command) }
        Button("Copy Output") { Pasteboard.copy(tracker.plainOutput(for: block)) }
        Button("Copy Command and Output") {
            Pasteboard.copy(block.command + "\n" + tracker.plainOutput(for: block))
        }
        Divider()
        Button("Run Again") { tracker.rerun(block.command) }
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
