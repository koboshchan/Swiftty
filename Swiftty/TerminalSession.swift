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
  
  @Published var isFieldFocused: Bool = true
  @Published var activeBlockID: UUID? = nil
  
  var persistentTerminalView: SwifttyTerminalView?
  private var commandStartLine: Int = 0
  private var outputCheckTimer: Timer? = nil

  func clearAllTextSelections() {
    for block in blocks {
      block.handle.view?.selectNone()
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
    
    // Start shell
    view.startProcess(
      executable: "/bin/zsh",
      args: ["-l"],
      currentDirectory: currentDirectory
    )
    
    // Configure zsh hook to output delimiter
    view.send(txt: "precmd() { echo -n \"\\n[Swiftty-Command-Done:$?]\\n\" }\n")
    view.send(txt: "clear\n")
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

  func processTerminated(blockID: UUID, exitCode: Int32?) {
    guard let idx = self.blocks.firstIndex(where: { $0.id == blockID }) else { return }
    let block = self.blocks[idx]
    guard block.isRunning else { return }

    let isError = (exitCode ?? 0) != 0
    let elapsed = Date().timeIntervalSince(block.startTime)

    self.blocks[idx] = CommandBlock(
      id: block.id,
      directory: block.directory,
      command: block.command,
      handle: block.handle,
      startTime: block.startTime,
      duration: elapsed,
      gitInfo: self.gitInfo,
      isRunning: false,
      isError: isError
    )

    updateGitInfo()
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
      commandStartLine = terminal.buffer.totalLinesTrimmed
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
    self.blocks.append(runningBlock)
    self.activeBlockID = blockID
    self.isFieldFocused = false
    
    // Send command to the shell
    persistentTerminalView?.send(txt: trimmed + "\n")
    
    // Focus the shell view
    if let view = persistentTerminalView {
      view.window?.makeFirstResponder(view)
    }

    outputCheckTimer?.invalidate()
    outputCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      Task { @MainActor in
        self.checkActiveCommandOutput()
      }
    }
  }
  
  private func checkActiveCommandOutput() {
    guard let view = persistentTerminalView, let terminal = view.terminal else { return }
    let buffer = terminal.buffer
    let linesTop = buffer.totalLinesTrimmed
    
    var totalLines = linesTop
    while terminal.getScrollInvariantLine(row: totalLines) != nil {
      totalLines += 1
    }
    
    let checkStart = max(linesTop, totalLines - 4)
    for r in checkStart..<totalLines {
      if let line = terminal.getScrollInvariantLine(row: r) {
        let text = line.translateToString(trimRight: true)
        if text.contains("[Swiftty-Command-Done:") {
          if let range = text.range(of: "[Swiftty-Command-Done:") {
            let suffix = text[range.upperBound...]
            if let closeRange = suffix.range(of: "]") {
              let codeStr = suffix[..<closeRange.lowerBound]
              let exitCode = Int32(codeStr) ?? 0
              completeActiveCommand(exitCode: exitCode)
              break
            }
          }
        }
      }
    }
  }
  
  private func completeActiveCommand(exitCode: Int32) {
    outputCheckTimer?.invalidate()
    outputCheckTimer = nil
    
    guard let blockID = activeBlockID,
          let idx = blocks.firstIndex(where: { $0.id == blockID }) else { return }
    
    let block = blocks[idx]
    activeBlockID = nil
    
    let staticText = getRichOutput(from: commandStartLine)
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
    
    // Clear terminal screen so next block starts clean
    persistentTerminalView?.send(txt: "clear\n")
    
    // Shift focus back to text input bar
    isFieldFocused = true
    
    updateGitInfo()
  }
  
  private func getRichOutput(from startLine: Int) -> AttributedString {
    guard let view = persistentTerminalView, let terminal = view.terminal else { return AttributedString("") }
    let buffer = terminal.buffer
    var totalLines = buffer.totalLinesTrimmed
    while terminal.getScrollInvariantLine(row: totalLines) != nil {
      totalLines += 1
    }
    
    var endLine = totalLines
    for r in startLine..<totalLines {
      if let line = terminal.getScrollInvariantLine(row: r) {
        let text = line.translateToString(trimRight: true)
        if text.contains("[Swiftty-Command-Done:") {
          endLine = r
          break
        }
      }
    }
    
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
          
          if col >= line.count {
            runText = runText.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
          }
          
          guard !runText.isEmpty else { continue }
          
          var run = AttributedString(runText)
          switch fg {
          case .ansi256(let c):
            run.foregroundColor = mapAnsiColor(c)
          case .trueColor(let red, let green, let blue):
            run.foregroundColor = SwiftUI.Color(red: Double(red)/255, green: Double(green)/255, blue: Double(blue)/255)
          default:
            run.foregroundColor = .swText
          }
          
          if style.contains(.bold) {
            run.inlinePresentationIntent = .stronglyEmphasized
          }
          
          richString.append(run)
        }
      }
      richString.append(AttributedString("\n"))
    }
    
    return richString
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
    default:
      return .swText
    }
  }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
  
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    if let directory = directory, !directory.isEmpty {
      DispatchQueue.main.async {
        self.currentDirectory = directory
        self.title = TerminalSession.displayPath(directory)
        self.updateGitInfo()
      }
    }
  }
  
  func processTerminated(source: TerminalView, exitCode: Int32?) {
    DispatchQueue.main.async {
      if self.activeBlockID != nil {
        self.completeActiveCommand(exitCode: exitCode ?? 0)
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
