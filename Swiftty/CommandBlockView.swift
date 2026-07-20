import SwiftUI
import SwiftTerm

struct CommandBlockView: View {
  let block: CommandBlock
  @ObservedObject var session: TerminalSession
  @State private var isHovered = false
  @State private var elapsedDuration: Double = 0.0
  @State private var timer: Timer? = nil
  @State private var terminalHeight: CGFloat = 30
  @State private var filterText = ""


  private var isSelected: Bool { session.selectedBlockIDs.contains(block.id) }

  private var isPrevSelected: Bool {
    guard let idx = session.blocks.firstIndex(where: { $0.id == block.id }), idx > 0 else { return false }
    return session.selectedBlockIDs.contains(session.blocks[idx - 1].id)
  }

  private var isNextSelected: Bool {
    guard let idx = session.blocks.firstIndex(where: { $0.id == block.id }), idx < session.blocks.count - 1 else { return false }
    return session.selectedBlockIDs.contains(session.blocks[idx + 1].id)
  }

  private var topRadius: CGFloat {
    (isSelected && isPrevSelected) ? 0 : 12
  }

  private var bottomRadius: CGFloat {
    (isSelected && isNextSelected) ? 0 : 12
  }

  private var hasOutput: Bool {
    if block.isRunning {
      return true
    }
    if let staticOutput = block.staticOutput {
      let str = String(staticOutput.characters)
      return !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return false
  }

  // Extracted so the type-checker doesn't have to resolve this modifier chain
  // together with the surrounding if/else branches (it times out otherwise).
  @ViewBuilder
  private func staticOutputView(_ output: AttributedString) -> some View {
    Text(output)
      .font(.system(size: 12, design: .monospaced))
      .lineSpacing(4)
      .textSelection(.enabled)
      .foregroundStyle(Color.swText)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func getSelectedBlocks() -> [CommandBlock] {
    if session.selectedBlockIDs.contains(block.id) {
      return session.blocks.filter { session.selectedBlockIDs.contains($0.id) }
    } else {
      return [block]
    }
  }

  // MARK: Context menu items (shared by right-click and 3-dots button)
  @ViewBuilder
  private func blockContextMenu() -> some View {
    let targetBlocks = getSelectedBlocks()
    let isPlural = targetBlocks.count > 1

    Button(isPlural ? "Copy Blocks" : "Copy") {
      var lines: [String] = []
      for b in targetBlocks {
        let cmd = b.command
        let output: String
        if b.isRunning, let view = session.persistentTerminalView {
          output = getAllOutput(for: view)
        } else {
          output = b.staticOutput.map { String($0.characters) } ?? ""
        }
        let trimmedOut = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = trimmedOut.isEmpty ? cmd : "\(cmd)\n\(trimmedOut)"
        lines.append(full)
      }
      let fullText = lines.joined(separator: "\n\n")
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(fullText, forType: .string)
    }
    Button(isPlural ? "Copy Commands" : "Copy Command") {
      let cmds = targetBlocks.map { $0.command }.joined(separator: "\n")
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(cmds, forType: .string)
    }
    Button(isPlural ? "Copy Outputs" : "Copy Output") {
      var outputs: [String] = []
      for b in targetBlocks {
        let output: String
        if b.isRunning, let view = session.persistentTerminalView {
          output = getAllOutput(for: view)
        } else {
          output = b.staticOutput.map { String($0.characters) } ?? ""
        }
        outputs.append(output)
      }
      let fullOutputs = outputs.joined(separator: "\n\n")
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(fullOutputs, forType: .string)
    }
    Button(isPlural ? "Copy Working Directories" : "Copy Working Directory") {
      let dirs = Array(Set(targetBlocks.map { $0.directory })).sorted().joined(separator: "\n")
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(dirs, forType: .string)
    }
    if !isPlural, let git = block.gitInfo {
      Button("Copy Git Branch") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(git.branch, forType: .string)
      }
    }
    Divider()
    if !isPlural {
      Button("Find Within Block") {
        withAnimation(.easeOut(duration: 0.15)) {
          setFilterActive(true)
        }
      }
      Divider()
      Button("Scroll to Top of Block") {
        session.scrollToBlockID = ScrollToBlock(id: block.id, anchor: .top)
      }
      Button("Scroll to Bottom of Block") {
        session.scrollToBlockID = ScrollToBlock(id: block.id, anchor: .bottom)
      }
      Divider()
      Button("Re-run Command") {
        session.runCommand(block.command)
      }
      Divider()
    }
    Button("Clear Blocks") {
      session.blocks.removeAll()
      session.selectedBlockIDs.removeAll()
    }
    Button(isPlural ? "Delete Blocks" : "Delete Block", role: .destructive) {
      for b in targetBlocks {
        session.selectedBlockIDs.remove(b.id)
        if let idx = session.blocks.firstIndex(where: { $0.id == b.id }) {
          session.blocks.remove(at: idx)
        }
      }
    }
  }

  // MARK: Selection logic
  private func handleBlockClick() {
    session.clearAllTextSelections()
    let flags = NSEvent.modifierFlags
    if flags.contains(.command) {
      // Command-click: toggle this block
      if session.selectedBlockIDs.contains(block.id) {
        session.selectedBlockIDs.remove(block.id)
        if session.lastSelectedBlockID == block.id {
          session.lastSelectedBlockID = session.selectedBlockIDs.first
        }
      } else {
        session.selectedBlockIDs.insert(block.id)
        session.lastSelectedBlockID = block.id
      }
    } else if flags.contains(.shift), let lastID = session.lastSelectedBlockID {
      // Shift-click: range select
      let ids = session.blocks.map { $0.id }
      if let fromIdx = ids.firstIndex(of: lastID),
         let toIdx = ids.firstIndex(of: block.id) {
        let range = fromIdx <= toIdx ? fromIdx...toIdx : toIdx...fromIdx
        for idx in range { session.selectedBlockIDs.insert(ids[idx]) }
      }
    } else {
      // Plain click: select only this block
      session.selectedBlockIDs = [block.id]
      session.lastSelectedBlockID = block.id
    }
  }

  // MARK: Body sections (kept as separate @ViewBuilder members — a single
  // giant `body` expression makes the type-checker time out on this file).
  @ViewBuilder
  private var headerRow: some View {
    HStack(spacing: 8) {
      Text("base")
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.swMuted)

      Text(block.directory)
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .foregroundStyle(Color.swAmber)

      if let git = block.gitInfo {
        HStack(spacing: 4) {
          Text("git:(\(git.branch))")
            .foregroundStyle(Color.swMint)

          let disp = git.displayString
          if !disp.isEmpty {
            Text(disp)
              .foregroundStyle(Color.swMuted)
          }
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
      }

      Text(
        block.isRunning
          ? String(format: "(%.1fs)", elapsedDuration) : String(format: "(%.3fs)", block.duration)
      )
      .font(.system(size: 11, weight: .regular, design: .monospaced))
      .foregroundStyle(Color.swDim)

      Spacer()

      if isHovered && !block.isRunning {
        HStack(spacing: 6) {
          if hasOutput {
            SmallIconButton(
              systemName: "line.3.horizontal.decrease.circle",
              help: "Filter output",
              tint: block.isFilterActive ? .swMint : .swMuted
            ) {
              withAnimation(.easeOut(duration: 0.15)) {
                let nextVal = !block.isFilterActive
                setFilterActive(nextVal)
                if !nextVal { filterText = "" }
              }
            }
          }

          Menu { blockContextMenu() } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: 12, weight: .medium))
              .frame(width: 25, height: 25)
              .foregroundStyle(Color.swMuted)
              .contentShape(Rectangle())
          }
          .menuStyle(.button)
          .buttonStyle(.plain)
        }
        .transition(.opacity)
      }
    }
    .frame(height: 20)
  }

  @ViewBuilder
  private var commandLine: some View {
    Text(block.command)
      .font(.system(size: 13.5, weight: .bold, design: .monospaced))
      .foregroundStyle(block.isError ? Color.swCoral : Color.swMint)
      .padding(.bottom, 2)
  }

  private func currentOutputText() -> String {
    if block.isRunning, let view = session.persistentTerminalView {
      return getAllOutput(for: view)
    }
    return block.staticOutput.map { String($0.characters) } ?? ""
  }

  @ViewBuilder
  private var filteredOutputView: some View {
    let filtered = getFilteredOutput(for: currentOutputText(), query: filterText)
    if filtered.isEmpty {
      Text("No matches found")
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color.swMuted)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      ScrollView(.horizontal) {
        Text(filtered)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(Color.swText)
          .lineSpacing(4)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(maxHeight: 300)
    }
  }

  @ViewBuilder
  private var liveOrStaticOutputView: some View {
    if block.isRunning, let terminalView = session.persistentTerminalView {
      TerminalSurface(
        terminalView: terminalView,
        session: session,
        onClick: { handleBlockClick() },
        onSelectionChanged: {
          session.selectedBlockIDs.removeAll()
          session.lastSelectedBlockID = nil
        }
      )
      .frame(height: terminalHeight)
      .cornerRadius(8)
    } else if hasOutput, let staticOutput = block.staticOutput {
      staticOutputView(staticOutput)
    }
  }

  @ViewBuilder
  private var outputSection: some View {
    if block.isFilterActive && !filterText.isEmpty {
      filteredOutputView
    } else {
      liveOrStaticOutputView
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      headerRow

      if block.isFilterActive {
        TextField("Filter output...", text: $filterText)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 11, design: .monospaced))
          .frame(maxWidth: 300)
          .padding(.bottom, 4)
      }

      commandLine

      outputSection
    }
    .padding(.horizontal, 20)
    .padding(.top, 14)
    .padding(.bottom, (isSelected && isNextSelected) ? 30 : 14)
    .background(
      UnequallyRoundedRectShape(
        topLeading: topRadius,
        bottomLeading: bottomRadius,
        bottomTrailing: bottomRadius,
        topTrailing: topRadius
      )
      .fill(
        isSelected
          ? Color(red: 0.063, green: 0.165, blue: 0.208)
          : (isHovered ? Color.swRaised.opacity(0.18) : Color.clear)
      )
    )
    .overlay(
      UnequallyRoundedRectShape(
        topLeading: topRadius,
        bottomLeading: bottomRadius,
        bottomTrailing: bottomRadius,
        topTrailing: topRadius
      )
      .stroke(
        isSelected ? Color.accentColor.opacity(0.6) : (isHovered ? Color.swLine : Color.clear),
        lineWidth: isSelected ? 1.0 : 0.8
      )
    )
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.15)) {
        isHovered = hovering
      }
    }
    .onTapGesture {
      handleBlockClick()
    }
    .contextMenu { blockContextMenu() }
    .onAppear {
      if block.isRunning {
        elapsedDuration = 0.0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
          DispatchQueue.main.async {
            elapsedDuration = Date().timeIntervalSince(block.startTime)
            if let view = session.persistentTerminalView {
              let computedHeight = computeHeight(for: view)
              // Only grow during running — never shrink, to prevent jumping
              if computedHeight > terminalHeight {
                terminalHeight = computedHeight
              }
            }
            // Always fire scrollTrigger so multi-chunk output keeps scrolled to bottom
            session.scrollTrigger = UUID()
          }
        }
      }
    }
    .onChange(of: block.isRunning) { _, isRunning in
      // Stop the polling timer once the command finishes. The block stays on
      // screen after completing (isRunning flips to false but onDisappear never
      // fires), so without this the timer keeps firing scrollTrigger every 0.1s
      // forever — repeatedly snapping the scroll view back to the bottom and
      // preventing the user from scrolling up through history.
      if !isRunning {
        timer?.invalidate()
        timer = nil
      }
    }
    .onDisappear {
      timer?.invalidate()
      timer = nil
    }
    .contentShape(Rectangle())
  }

  private func computeHeight(for view: SwifttyTerminalView) -> CGFloat {
    let ch = view.cellHeight
    guard let terminal = view.terminal else { return ch }
    let buffer = terminal.buffer
    let linesTop = buffer.totalLinesTrimmed

    var totalLines = linesTop
    while terminal.getScrollInvariantLine(row: totalLines) != nil {
      totalLines += 1
    }

    var lastUsedRow = linesTop
    for r in stride(from: totalLines - 1, through: linesTop, by: -1) {
      if let line = terminal.getScrollInvariantLine(row: r) {
        let text = line.translateToString(trimRight: true)
        if !text.isEmpty {
          lastUsedRow = r
          break
        }
      }
    }

    let cursorRow = linesTop + buffer.yDisp + buffer.y
    let contentRows = max(lastUsedRow - linesTop + 1, cursorRow - linesTop + 1)
    return max(CGFloat(contentRows) * ch, ch)
  }

  private func getFilteredOutput(for text: String, query: String) -> String {
    let lines = text.components(separatedBy: "\n")
    let matchingLines = lines.filter { $0.localizedCaseInsensitiveContains(query) }
    return matchingLines.joined(separator: "\n")
  }

  private func getAllOutput(for view: SwifttyTerminalView) -> String {
    guard let terminal = view.terminal else { return "" }
    let buffer = terminal.buffer
    let linesTop = buffer.totalLinesTrimmed
    
    var totalLines = linesTop
    while terminal.getScrollInvariantLine(row: totalLines) != nil {
      totalLines += 1
    }
    
    var allLines: [String] = []
    for r in linesTop..<totalLines {
      if let line = terminal.getScrollInvariantLine(row: r) {
        allLines.append(line.translateToString(trimRight: true))
      }
    }
    return allLines.joined(separator: "\n")
  }

  private func setFilterActive(_ active: Bool) {
    guard let idx = session.blocks.firstIndex(where: { $0.id == block.id }) else { return }
    let updatedBlock = CommandBlock(
      id: block.id,
      directory: block.directory,
      command: block.command,
      handle: block.handle,
      startTime: block.startTime,
      duration: block.duration,
      gitInfo: block.gitInfo,
      isRunning: block.isRunning,
      isError: block.isError,
      exitCode: block.exitCode,
      staticOutput: block.staticOutput,
      isFilterActive: active
    )
    session.blocks[idx] = updatedBlock
  }
}

struct StyledTextSegment {
  let text: String
  var color: SwiftUI.Color? = nil
  var isBold: Bool = false
}

func parseANSIText(_ text: String) -> Text {
  var segments: [StyledTextSegment] = []
  let parts = text.components(separatedBy: "\u{001B}")
  if let first = parts.first, !first.isEmpty {
    segments.append(StyledTextSegment(text: first))
  }

  var currentColor: SwiftUI.Color? = nil
  var isBold = false

  for part in parts.dropFirst() {
    guard !part.isEmpty else { continue }
    if part.hasPrefix("["), let mIndex = part.firstIndex(of: "m") {
      let codeString = part[part.index(after: part.startIndex)..<mIndex]
      let remainingText = String(part[part.index(after: mIndex)...])

      let codes = codeString.components(separatedBy: ";").compactMap { Int($0) }
      for code in codes {
        switch code {
        case 0:
          currentColor = nil
          isBold = false
        case 1:
          isBold = true
        case 30: currentColor = .black
        case 31: currentColor = .swCoral
        case 32: currentColor = .swMint
        case 33: currentColor = .swAmber
        case 34: currentColor = .swBlue
        case 35: currentColor = .swViolet
        case 36: currentColor = .swTerminalCyan
        case 37: currentColor = .swText
        case 90: currentColor = .swMuted
        case 91: currentColor = .swCoral
        case 92: currentColor = .swMint
        case 93: currentColor = .swAmber
        case 94: currentColor = .swBlue
        case 95: currentColor = .swViolet
        case 96: currentColor = .swTerminalCyan
        case 97: currentColor = .white
        default:
          break
        }
      }
      if !remainingText.isEmpty {
        segments.append(StyledTextSegment(text: remainingText, color: currentColor, isBold: isBold))
      }
    } else {
      segments.append(
        StyledTextSegment(text: "\u{001B}" + part, color: currentColor, isBold: isBold))
    }
  }

  var attributed = AttributedString()
  for segment in segments {
    var segmentAttr = AttributedString(segment.text)
    if let color = segment.color {
      segmentAttr.foregroundColor = color
    } else {
      segmentAttr.foregroundColor = .swText
    }
    if segment.isBold {
      segmentAttr.inlinePresentationIntent = .stronglyEmphasized
    }
    attributed.append(segmentAttr)
  }
  return Text(attributed)
}

struct UnequallyRoundedRectShape: Shape {
  var topLeading: CGFloat
  var bottomLeading: CGFloat
  var bottomTrailing: CGFloat
  var topTrailing: CGFloat

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let w = rect.width
    let h = rect.height
    
    // Start at top-middle
    path.move(to: CGPoint(x: w / 2, y: 0))
    
    // Top-right corner
    path.addLine(to: CGPoint(x: w - topTrailing, y: 0))
    if topTrailing > 0 {
      path.addArc(
        center: CGPoint(x: w - topTrailing, y: topTrailing),
        radius: topTrailing,
        startAngle: Angle(degrees: -90),
        endAngle: Angle(degrees: 0),
        clockwise: false
      )
    } else {
      path.addLine(to: CGPoint(x: w, y: 0))
    }
    
    // Bottom-right corner
    path.addLine(to: CGPoint(x: w, y: h - bottomTrailing))
    if bottomTrailing > 0 {
      path.addArc(
        center: CGPoint(x: w - bottomTrailing, y: h - bottomTrailing),
        radius: bottomTrailing,
        startAngle: Angle(degrees: 0),
        endAngle: Angle(degrees: 90),
        clockwise: false
      )
    } else {
      path.addLine(to: CGPoint(x: w, y: h))
    }
    
    // Bottom-left corner
    path.addLine(to: CGPoint(x: bottomLeading, y: h))
    if bottomLeading > 0 {
      path.addArc(
        center: CGPoint(x: bottomLeading, y: h - bottomLeading),
        radius: bottomLeading,
        startAngle: Angle(degrees: 90),
        endAngle: Angle(degrees: 180),
        clockwise: false
      )
    } else {
      path.addLine(to: CGPoint(x: 0, y: h))
    }
    
    // Top-left corner
    path.addLine(to: CGPoint(x: 0, y: topLeading))
    if topLeading > 0 {
      path.addArc(
        center: CGPoint(x: topLeading, y: topLeading),
        radius: topLeading,
        startAngle: Angle(degrees: 180),
        endAngle: Angle(degrees: 270),
        clockwise: false
      )
    } else {
      path.addLine(to: CGPoint(x: 0, y: 0))
    }
    
    path.closeSubpath()
    return path
  }
}

