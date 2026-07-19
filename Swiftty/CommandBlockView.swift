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
  @State private var isFilterActive = false

  private var isSelected: Bool { session.selectedBlockIDs.contains(block.id) }

  // MARK: Context menu items (shared by right-click and 3-dots button)
  @ViewBuilder
  private func blockContextMenu() -> some View {
    Button("Copy") {
      let cmd = block.command
      let output = block.handle.view.map { getAllOutput(for: $0) } ?? ""
      let full = output.isEmpty ? cmd : "\(cmd)\n\(output)"
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(full, forType: .string)
    }
    Button("Copy Command") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(block.command, forType: .string)
    }
    Button("Copy Output") {
      let output = block.handle.view.map { getAllOutput(for: $0) } ?? ""
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(output, forType: .string)
    }
    Button("Copy Working Directory") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(block.directory, forType: .string)
    }
    if let git = block.gitInfo {
      Button("Copy Git Branch") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(git.branch, forType: .string)
      }
    }
    Divider()
    Button("Find Within Block") {
      withAnimation(.easeOut(duration: 0.15)) {
        isFilterActive = true
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
    Button("Clear Blocks") {
      session.blocks.removeAll()
      session.selectedBlockIDs.removeAll()
    }
    Button("Delete Block", role: .destructive) {
      session.selectedBlockIDs.remove(block.id)
      if let idx = session.blocks.firstIndex(where: { $0.id == block.id }) {
        session.blocks.remove(at: idx)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
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
            SmallIconButton(
              systemName: "line.3.horizontal.decrease.circle",
              help: "Filter output",
              tint: isFilterActive ? .swMint : .swMuted
            ) {
              withAnimation(.easeOut(duration: 0.15)) {
                isFilterActive.toggle()
                if !isFilterActive { filterText = "" }
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

      if isFilterActive {
        TextField("Filter output...", text: $filterText)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 11, design: .monospaced))
          .frame(maxWidth: 300)
          .padding(.bottom, 4)
      }

      Text(block.command)
        .font(.system(size: 13.5, weight: .bold, design: .monospaced))
        .foregroundStyle(block.isError ? Color.swCoral : Color.swMint)
        .padding(.bottom, 2)

      if isFilterActive && !filterText.isEmpty {
        if let view = block.handle.view {
          let filtered = getFilteredOutput(for: view, query: filterText)
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
      } else {
        TerminalSurface(
          currentDirectory: block.directory,
          command: block.command,
          handle: block.handle,
          onClick: { handleBlockClick() },
          onSelectionChanged: {
            session.selectedBlockIDs.removeAll()
            session.lastSelectedBlockID = nil
          }
        ) { exitCode in
          session.processTerminated(blockID: block.id, exitCode: exitCode)
        }
        .frame(height: terminalHeight)
        .cornerRadius(4)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(
          isSelected
            ? Color(red: 0.063, green: 0.165, blue: 0.208)
            : (isHovered ? Color.swRaised.opacity(0.18) : Color.clear)
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(
          isSelected ? Color.swBlue.opacity(0.6) : (isHovered ? Color.swLine : Color.clear),
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
            if let view = block.handle.view {
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
      } else {
        // Already finished — set final height
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          if let view = block.handle.view {
            terminalHeight = computeHeight(for: view)
            session.scrollTrigger = UUID()
          }
        }
      }
    }
    .onDisappear {
      timer?.invalidate()
    }
    .onChange(of: block.isRunning) { oldValue, newValue in
      if !newValue {
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
          if let view = block.handle.view {
            terminalHeight = computeHeight(for: view)
            session.scrollTrigger = UUID()
          }
        }
      }
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

  private func getFilteredOutput(for view: SwifttyTerminalView, query: String) -> String {
    guard let terminal = view.terminal else { return "" }
    let buffer = terminal.buffer
    let linesTop = buffer.totalLinesTrimmed
    
    var totalLines = linesTop
    while terminal.getScrollInvariantLine(row: totalLines) != nil {
      totalLines += 1
    }
    
    var matchingLines: [String] = []
    for r in linesTop..<totalLines {
      if let line = terminal.getScrollInvariantLine(row: r) {
        let text = line.translateToString(trimRight: true)
        if text.localizedCaseInsensitiveContains(query) {
          matchingLines.append(text)
        }
      }
    }
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
