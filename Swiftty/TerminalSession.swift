import Combine
import Foundation
import SwiftTerm
import SwiftUI

struct GitInfo: Equatable {
  let branch: String
  let dirtyFiles: Int
  let additions: Int
  let deletions: Int

  var displayString: String {
    var parts: [String] = []
    if dirtyFiles > 0 {
      parts.append("\(dirtyFiles) *")
    }
    if additions > 0 {
      parts.append("+\(additions)")
    }
    if deletions > 0 {
      parts.append("-\(deletions)")
    }
    return parts.joined(separator: " ")
  }
}

@MainActor
struct CommandBlock: Identifiable, Equatable {
  let id: UUID
  let directory: String
  let command: String
  let handle: TerminalHandle
  let startTime: Date
  let duration: Double
  let gitInfo: GitInfo?
  let isRunning: Bool
  let isError: Bool
  let exitCode: Int32?
  let staticOutput: AttributedString?
  let isFilterActive: Bool

  init(
    id: UUID = UUID(), directory: String, command: String, handle: TerminalHandle,
    startTime: Date = Date(), duration: Double = 0.0, gitInfo: GitInfo? = nil,
    isRunning: Bool = true, isError: Bool = false, exitCode: Int32? = nil,
    staticOutput: AttributedString? = nil, isFilterActive: Bool = false
  ) {
    self.id = id
    self.directory = directory
    self.command = command
    self.handle = handle
    self.startTime = startTime
    self.duration = duration
    self.gitInfo = gitInfo
    self.isRunning = isRunning
    self.isError = isError
    self.exitCode = exitCode
    self.staticOutput = staticOutput
    self.isFilterActive = isFilterActive
  }

  static func == (lhs: CommandBlock, rhs: CommandBlock) -> Bool {
    lhs.id == rhs.id && lhs.isRunning == rhs.isRunning && lhs.isError == rhs.isError && lhs.exitCode == rhs.exitCode && lhs.staticOutput == rhs.staticOutput && lhs.isFilterActive == rhs.isFilterActive
  }
}

struct ScrollToBlock: Equatable {
  let id: UUID
  let anchor: UnitPoint
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
  let id = UUID()
  let handle = TerminalHandle()
  @Published var currentDirectory: String
  @Published var title: String
  let subtitle: String

  @Published var blocks: [CommandBlock] = []
  @Published var gitInfo: GitInfo? = nil
  @Published var scrollTrigger = UUID()
  @Published var selectedBlockIDs: Set<UUID> = []
  @Published var lastSelectedBlockID: UUID? = nil
  @Published var scrollToBlockID: ScrollToBlock? = nil
  @Published var autocompleteSuggestions: [String] = []
  @Published var selectedSuggestionIndex: Int? = nil
  @Published var ghostText: String = ""
  @Published var autocompleteTabCount: Int = 0
  @Published var isAutocompleteOpen: Bool = false
  @Published var originalAutocompleteText: String? = nil
  @Published var historySuggestions: [String] = []
  @Published var isHistoryOpen: Bool = false
  @Published var selectedHistoryIndex: Int? = nil
  @Published var pendingCommand: String? = nil
  
  @Published var isFieldFocused: Bool = true
  @Published var activeBlockID: UUID? = nil
  
  var persistentTerminalView: SwifttyTerminalView?
  private var commandStartLine: Int = 0

  func clearAllTextSelections() {
    for block in blocks {
      block.handle.view?.selectNone()
    }
  }

  private static func writeBootstrapFiles(for sessionId: UUID) -> String? {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("Swiftty-Session-\(sessionId.uuidString)")
    
    do {
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      
      let origZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"] ?? NSHomeDirectory()
      
      let zshenvContent = """
      export SWIFFTY_ORIG_ZDOTDIR="\(origZdotdir)"
      if [[ -f "$SWIFFTY_ORIG_ZDOTDIR/.zshenv" ]]; then
        source "$SWIFFTY_ORIG_ZDOTDIR/.zshenv"
      fi
      """
      
      let zshrcContent = """
      if [[ -f "$SWIFFTY_ORIG_ZDOTDIR/.zshrc" ]]; then
        source "$SWIFFTY_ORIG_ZDOTDIR/.zshrc"
      fi
      
      swiftty_hex_encode() {
        builtin printf "%s" "$1" | command od -An -v -tx1 | command tr -d ' \\n'
      }
      
      swiftty_precmd() {
        local exit_code=$?
        local pwd_escaped
        pwd_escaped=$(pwd)
        local json="{\\"hook\\":\\"Precmd\\",\\"exit_code\\":$exit_code,\\"pwd\\":\\"$pwd_escaped\\"}"
        local hex
        hex=$(swiftty_hex_encode "$json")
        builtin printf "\\e]0;[Swiftty-JSON-Data:%s]\\a" "$hex"
        # Re-blank the prompt every cycle: user prompt themes (e.g. powerlevel10k)
        # register their own precmd hook while sourcing ~/.zshrc above, and that hook
        # runs before this one and repopulates PROMPT/RPROMPT each time. Blanking
        # only once at shell init isn't enough, so we clear it again here, last.
        PROMPT=""
        PS1=""
        RPROMPT=""
        RPROMPT2=""
      }
      
      swiftty_preexec() {
        local cmd="$1"
        local cmd_escaped
        cmd_escaped=$(builtin printf "%s" "$cmd" | command sed 's/\\\\/\\\\\\\\/g; s/\\"/\\\\\\"/g')
        local json="{\\"hook\\":\\"Preexec\\",\\"command\\":\\"$cmd_escaped\\"}"
        local hex
        hex=$(swiftty_hex_encode "$json")
        builtin printf "\\e]0;[Swiftty-JSON-Data:%s]\\a" "$hex"
      }
      
      autoload -Uz add-zsh-hook
      add-zsh-hook precmd swiftty_precmd
      add-zsh-hook preexec swiftty_preexec
      
      export PROMPT=""
      export PS1=""
      export PS2=""
      export PS3=""
      export PS4=""
      export RPROMPT=""
      export RPROMPT2=""
      unsetopt ZLE
      # With ZLE off, zsh reads input via a plain blocking read and leaves
      # character echo to the pty's cooked-mode line discipline — so every
      # command we feed programmatically (TerminalSurface.send) gets echoed
      # straight back into the captured output, duplicating the command text
      # that CommandBlockView already renders in its own header. Disabling
      # tty echo here stops that at the source.
      stty -echo
      # zsh prints a highlighted "%" and forces a fresh line whenever the
      # previous command's output didn't end in a newline (PROMPT_SP/CR).
      # That's meant for a real prompt line, which we've blanked out above,
      # so left on it just leaks stray "%" characters into captured output.
      unsetopt PROMPT_SP
      unsetopt PROMPT_CR
      """
      
      try zshenvContent.write(to: tempDir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
      try zshrcContent.write(to: tempDir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
      
      return tempDir.path
    } catch {
      print("Failed to create bootstrap files: \(error)")
      return nil
    }
  }

  init(currentDirectory: String, ordinal: Int) {
    self.currentDirectory = currentDirectory
    self.title = TerminalSession.displayPath(currentDirectory)
    self.subtitle = ordinal == 1 ? "zsh" : "zsh · session \(ordinal)"

    let view = SwifttyTerminalView(frame: .zero)
    view.font = NSFont.monospacedSystemFont(ofSize: 12.0, weight: .regular)
    view.lineSpacing = 1.02
    view.nativeBackgroundColor = NSColor(calibratedRed: 0.031, green: 0.043, blue: 0.047, alpha: 1)
    view.nativeForegroundColor = NSColor(calibratedRed: 0.82, green: 0.89, blue: 0.89, alpha: 1)
    view.backspaceSendsControlH = false
    
    self.persistentTerminalView = view
    
    updateGitInfo()
    
    // Set delegate
    view.processDelegate = self
    
    let sessionId = self.id
    if let bootstrapPath = TerminalSession.writeBootstrapFiles(for: sessionId) {
      view.startProcess(
        executable: "/usr/bin/env",
        args: ["ZDOTDIR=" + bootstrapPath, "/bin/zsh", "-l"],
        currentDirectory: currentDirectory
      )
    } else {
      view.startProcess(
        executable: "/bin/zsh",
        args: ["-l"],
        currentDirectory: currentDirectory
      )
    }
  }

  deinit {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("Swiftty-Session-\(self.id.uuidString)")
    try? FileManager.default.removeItem(at: tempDir)
  }

  private static func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path.hasPrefix(home) else { return path }
    return "~" + String(path.dropFirst(home.count))
  }

  func openHistory(filter: String) {
    let localHistory = blocks.map { $0.command.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    var uniqueHistory: [String] = []
    var seen = Set<String>()
    for cmd in localHistory.reversed() {
      if !seen.contains(cmd) {
        seen.insert(cmd)
        uniqueHistory.append(cmd)
      }
    }

    if filter.isEmpty {
      historySuggestions = uniqueHistory
    } else {
      historySuggestions = uniqueHistory.filter { $0.localizedCaseInsensitiveContains(filter) }
    }
    selectedHistoryIndex = historySuggestions.isEmpty ? nil : 0
    isHistoryOpen = true
  }

  nonisolated private func runShellCommand(_ command: String, directory: String) -> (
    output: String, error: String, exitCode: Int32, duration: Double
  ) {
    let startTime = Date()
    let process = Process()
    let outPipe = Pipe()
    let errPipe = Pipe()

    process.standardOutput = outPipe
    process.standardError = errPipe
    process.arguments = ["-c", command]
    process.launchPath = "/bin/zsh"
    process.currentDirectoryPath = directory

    process.launch()
    process.waitUntilExit()

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

    let output = String(data: outData, encoding: .utf8) ?? ""
    let error = String(data: errData, encoding: .utf8) ?? ""
    let duration = Date().timeIntervalSince(startTime)

    return (output, error, process.terminationStatus, duration)
  }

  func updateGitInfo() {
    let dir = self.currentDirectory
    Task.detached {
      let (out, _, code, _) = self.runShellCommand("git branch --show-current", directory: dir)
      guard code == 0 else {
        await MainActor.run { self.gitInfo = nil }
        return
      }
      let branch = out.trimmingCharacters(in: .whitespacesAndNewlines)

      let (diffOut, _, diffCode, _) = self.runShellCommand("git status --porcelain && git diff --shortstat", directory: dir)
      var dirtyCount = 0
      var additions = 0
      var deletions = 0

      if diffCode == 0 {
        let lines = diffOut.components(separatedBy: "\n")
        let porcelainLines = lines.filter { !$0.isEmpty && !$0.contains("file changed") }
        dirtyCount = porcelainLines.count

        let cleanedDiff = diffOut.replacingOccurrences(of: "\n", with: " ")
        if let addRange = cleanedDiff.range(of: #"(\d+) insertion"#, options: .regularExpression) {
          let addPart = cleanedDiff[addRange].prefix(while: { $0.isNumber })
          additions = Int(addPart) ?? 0
        }
        if let delRange = cleanedDiff.range(of: #"(\d+) deletion"#, options: .regularExpression) {
          let delPart = cleanedDiff[delRange].prefix(while: { $0.isNumber })
          deletions = Int(delPart) ?? 0
        }
      }

      let info = GitInfo(
        branch: branch.isEmpty ? "main" : branch, dirtyFiles: dirtyCount, additions: additions,
        deletions: deletions)
      await MainActor.run {
        self.gitInfo = info
      }
    }
  }

  func runCommand(_ command: String) {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    let blockID = UUID()
    let dir = self.currentDirectory
    let currentGit = self.gitInfo
    
    // Point handle's view to our persistent view
    handle.view = persistentTerminalView
    
    if let terminal = persistentTerminalView?.terminal {
      let buffer = terminal.buffer
      // Start capturing from the cursor's current absolute row — that's exactly
      // where this command's output will begin. This previously counted every
      // allocated buffer line (totalLinesTrimmed plus all the blank on-screen
      // rows below the cursor), so the start line landed far past the real
      // output and getRichOutput read an empty range: the block would flash the
      // output for a frame and then render blank.
      commandStartLine = buffer.totalLinesTrimmed + buffer.yDisp + buffer.y
    } else {
      commandStartLine = 0
    }

    let runningBlock = CommandBlock(
      id: blockID,
      directory: dir,
      command: trimmed,
      handle: handle,
      startTime: Date(),
      duration: 0.0,
      gitInfo: currentGit,
      isRunning: true,
      isError: false,
      exitCode: nil,
      staticOutput: nil
    )
    
    self.pendingCommand = trimmed
    self.blocks.append(runningBlock)
    self.activeBlockID = blockID
    self.isFieldFocused = false
    
    // Focus the shell view
    if let view = persistentTerminalView {
      view.window?.makeFirstResponder(view)
    }
  }
  
  private func completeActiveCommand(exitCode: Int32, endLine: Int?) {
    guard let blockID = activeBlockID,
          let idx = blocks.firstIndex(where: { $0.id == blockID }) else { return }

    let block = blocks[idx]
    activeBlockID = nil

    let staticText = getRichOutput(from: commandStartLine, to: endLine)
    let elapsed = Date().timeIntervalSince(block.startTime)
    let isError = exitCode != 0
    
    blocks[idx] = CommandBlock(
      id: block.id,
      directory: block.directory,
      command: block.command,
      handle: block.handle,
      startTime: block.startTime,
      duration: elapsed,
      gitInfo: self.gitInfo,
      isRunning: false,
      isError: isError,
      exitCode: exitCode,
      staticOutput: staticText
    )
    
    // Reset the shared terminal buffer so the next block starts clean.
    // This used to send a real "clear\n" to the shell, but that round-trips
    // through the pty and fires its own precmd hook — if the next command
    // started before that hook landed, it got misattributed as this block's
    // completion (via activeBlockID), completing it instantly with an empty
    // captured range. Resetting the buffer directly is synchronous and never
    // touches the shell, so there's no hook to race.
    persistentTerminalView?.terminal?.resetToInitialState()
    
    // Shift focus back to text input bar
    isFieldFocused = true
    
    updateGitInfo()
  }
  
  /// The cursor's current absolute (scroll-invariant) row in the shared
  /// terminal buffer, or nil if there is no terminal yet. Callers use this to
  /// mark where a command's output ends the moment its precmd marker arrives.
  private func currentAbsoluteCursorLine() -> Int? {
    guard let terminal = persistentTerminalView?.terminal else { return nil }
    let buffer = terminal.buffer
    return buffer.totalLinesTrimmed + buffer.yDisp + buffer.y
  }

  private func getRichOutput(from startLine: Int, to explicitEnd: Int?) -> AttributedString {
    guard let view = persistentTerminalView, let terminal = view.terminal else { return AttributedString("") }
    let buffer = terminal.buffer
    var totalLines = buffer.totalLinesTrimmed
    while terminal.getScrollInvariantLine(row: totalLines) != nil {
      totalLines += 1
    }

    let linesTop = buffer.totalLinesTrimmed
    // Prefer the end row snapshotted the instant the precmd marker arrived —
    // that's the end of the command's output, before the next prompt was drawn.
    // Falling back to the live cursor would read whatever is on screen now,
    // which includes the freshly rendered (possibly un-blanked) shell prompt.
    let cursorRow = explicitEnd ?? (linesTop + buffer.yDisp + buffer.y)
    let endLine = max(startLine, min(totalLines, cursorRow))

    var richString = AttributedString("")
    for r in startLine..<endLine {
      if let line = terminal.getScrollInvariantLine(row: r) {
        var col = 0
        while col < line.count {
          let cell = line[col]
          let char = cell.getCharacter()
          let charStr = (char == "\0") ? " " : String(char)
          
          let fg = cell.attribute.fg
          let bg = cell.attribute.bg
          let style = cell.attribute.style
          
          var runText = charStr
          col += 1
          while col < line.count {
            let nextCell = line[col]
            if nextCell.attribute.fg == fg && nextCell.attribute.bg == bg && nextCell.attribute.style == style {
              let nextChar = nextCell.getCharacter()
              runText.append(nextChar == "\0" ? " " : String(nextChar))
              col += 1
            } else {
              break
            }
          }
          
          var foreground = colorFor(fg)
          var background = colorFor(bg)
          if style.contains(.inverse) {
            swap(&foreground, &background)
          }

          if col >= line.count && background == nil {
            runText = runText.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
          }

          guard !runText.isEmpty else { continue }
          guard !style.contains(.invisible) else { continue }

          var run = AttributedString(runText)
          run.foregroundColor = foreground ?? .swText
          if let background {
            run.backgroundColor = background
          }

          var intent: InlinePresentationIntent = []
          if style.contains(.bold) { intent.insert(.stronglyEmphasized) }
          if style.contains(.italic) { intent.insert(.emphasized) }
          if !intent.isEmpty { run.inlinePresentationIntent = intent }
          if style.contains(.underline) { run.underlineStyle = .single }
          if style.contains(.crossedOut) { run.strikethroughStyle = .single }

          richString.append(run)
        }
      }
      richString.append(AttributedString("\n"))
    }

    return richString
  }

  private func colorFor(_ color: Attribute.Color) -> SwiftUI.Color? {
    switch color {
    case .ansi256(let code):
      return mapAnsiColor(code)
    case .trueColor(let red, let green, let blue):
      return SwiftUI.Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    case .defaultColor, .defaultInvertedColor:
      return nil
    }
  }

  private func mapAnsiColor(_ code: UInt8) -> SwiftUI.Color {
    switch code {
    case 0: return .black
    case 1: return .swCoral
    case 2: return .swMint
    case 3: return .swAmber
    case 4: return .swBlue
    case 5: return .swViolet
    case 6: return .swTerminalCyan
    case 7: return .swText
    case 8: return .swMuted
    case 9: return .swCoral
    case 10: return .swMint
    case 11: return .swAmber
    case 12: return .swBlue
    case 13: return .swViolet
    case 14: return .swTerminalCyan
    case 15: return .white
    case 16...231:
      // 6x6x6 RGB color cube used by the xterm 256-color palette.
      let index = Int(code) - 16
      let steps: [Double] = [0, 95, 135, 175, 215, 255]
      let red = steps[index / 36]
      let green = steps[(index / 6) % 6]
      let blue = steps[index % 6]
      return SwiftUI.Color(red: red / 255, green: green / 255, blue: blue / 255)
    default:
      // 232...255: grayscale ramp.
      let level = Double(8 + (Int(code) - 232) * 10) / 255
      return SwiftUI.Color(red: level, green: level, blue: level)
    }
  }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
  
  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    if title.hasPrefix("[Swiftty-JSON-Data:") && title.hasSuffix("]") {
      let startIdx = title.index(title.startIndex, offsetBy: 19)
      let endIdx = title.index(title.endIndex, offsetBy: -1)
      let hexString = String(title[startIdx..<endIdx])
      
      if let data = dataFromHexString(hexString) {
        do {
          if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
             let hook = json["hook"] as? String {
            handleSubshellHook(hook: hook, payload: json)
          }
        } catch {
          print("Failed to parse JSON hook: \(error)")
        }
      }
    } else {
      self.title = title
    }
  }
  
  private func dataFromHexString(_ hex: String) -> Data? {
    var data = Data()
    let hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if hexStr.count % 2 != 0 { return nil }
    
    var index = hexStr.startIndex
    while index < hexStr.endIndex {
      let nextIndex = hexStr.index(index, offsetBy: 2)
      let byteStr = String(hexStr[index..<nextIndex])
      if let byte = UInt8(byteStr, radix: 16) {
        data.append(byte)
      } else {
        return nil
      }
      index = nextIndex
    }
    return data
  }
  
  private func handleSubshellHook(hook: String, payload: [String: Any]) {
    switch hook {
    case "Precmd":
      let exitCode = (payload["exit_code"] as? Int32) ?? 0
      let pwd = (payload["pwd"] as? String) ?? ""

      // Snapshot the cursor's absolute row now, synchronously. This runs from
      // SwiftTerm's feed on the main thread at the exact byte position of the
      // precmd marker — i.e. right after the command's output and before zsh
      // draws the next prompt. Deferring this read into the async block below
      // would instead sample the cursor once the prompt is already on screen,
      // pulling that prompt line (which prompt themes like powerlevel10k
      // repopulate after our blanking) into the captured block output.
      let capturedEnd = currentAbsoluteCursorLine()

      DispatchQueue.main.async {
        if !pwd.isEmpty && pwd != self.currentDirectory {
          self.currentDirectory = pwd
          self.title = TerminalSession.displayPath(pwd)
          self.updateGitInfo()
        }

        if self.activeBlockID != nil {
          self.completeActiveCommand(exitCode: exitCode, endLine: capturedEnd)
        }
      }
    default:
      break
    }
  }
  
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    // Rely on Precmd hook for directory changes, but keep fallback
    if let directory = directory, !directory.isEmpty {
      DispatchQueue.main.async {
        if self.currentDirectory != directory {
          self.currentDirectory = directory
          self.title = TerminalSession.displayPath(directory)
          self.updateGitInfo()
        }
      }
    }
  }
  
  func processTerminated(source: TerminalView, exitCode: Int32?) {
    DispatchQueue.main.async {
      if self.activeBlockID != nil {
        // No precmd marker fires when the shell process itself exits, so there
        // is no pre-prompt snapshot — fall back to the live cursor position.
        self.completeActiveCommand(exitCode: exitCode ?? 0, endLine: nil)
      }
    }
  }
}

@MainActor
final class TerminalSessionStore: ObservableObject {
  @Published private(set) var sessions: [TerminalSession] = []
  @Published var selectedID: UUID?

  private let currentDirectory: String
  private var closedSessionsQueue: [(session: TerminalSession, closedTime: Date)] = []

  init(currentDirectory: String) {
    self.currentDirectory = currentDirectory
    addSession()
  }

  var selectedSession: TerminalSession? {
    sessions.first { $0.id == selectedID }
  }

  func addSession() {
    let session = TerminalSession(currentDirectory: currentDirectory, ordinal: sessions.count + 1)
    sessions.append(session)
    selectedID = session.id
  }

  func closeSession(_ session: TerminalSession) {
    guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return }
    sessions.remove(at: idx)
    
    // Add to recovery queue
    closedSessionsQueue.append((session: session, closedTime: Date()))
    
    // Select next session if the closed one was selected
    if selectedID == session.id {
      if idx < sessions.count {
        selectedID = sessions[idx].id
      } else if !sessions.isEmpty {
        selectedID = sessions.last?.id
      } else {
        selectedID = nil
      }
    }
  }

  func restoreLastClosedSession() {
    // Filter out sessions older than 100 seconds
    closedSessionsQueue = closedSessionsQueue.filter { Date().timeIntervalSince($0.closedTime) <= 100 }
    
    guard let last = closedSessionsQueue.popLast() else { return }
    sessions.append(last.session)
    selectedID = last.session.id
  }
}
