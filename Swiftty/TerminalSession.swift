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

  init(
    id: UUID = UUID(), directory: String, command: String, handle: TerminalHandle,
    startTime: Date = Date(), duration: Double = 0.0, gitInfo: GitInfo? = nil,
    isRunning: Bool = true, isError: Bool = false
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
  }

  static func == (lhs: CommandBlock, rhs: CommandBlock) -> Bool {
    lhs.id == rhs.id && lhs.isRunning == rhs.isRunning && lhs.isError == rhs.isError
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

  func clearAllTextSelections() {
    for block in blocks {
      block.handle.view?.selectNone()
    }
  }

  init(currentDirectory: String, ordinal: Int) {
    self.currentDirectory = currentDirectory
    self.title = TerminalSession.displayPath(currentDirectory)
    self.subtitle = ordinal == 1 ? "zsh" : "zsh · session \(ordinal)"

    updateGitInfo()
  }

  private static func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path.hasPrefix(home) else { return path }
    return "~" + String(path.dropFirst(home.count))
  }

  static func loadZshHistory() -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let historyPath = URL(fileURLWithPath: home).appendingPathComponent(".zsh_history").path
    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: historyPath))
      if let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
        let lines = content.components(separatedBy: "\n")
        var commands: [String] = []
        var seen = Set<String>()
        for line in lines.reversed() {
          let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { continue }
          
          var cmd = trimmed
          if trimmed.hasPrefix(":") {
            let parts = trimmed.components(separatedBy: ";")
            if parts.count >= 2 {
              cmd = parts.dropFirst().joined(separator: ";")
            }
          }
          
          let finalCmd = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
          if !finalCmd.isEmpty && !seen.contains(finalCmd) {
            seen.insert(finalCmd)
            commands.append(finalCmd)
          }
        }
        return commands
      }
    } catch {
      // Ignore
    }
    return ["ls -la", "git status", "cd ~"]
  }

  func openHistory(filter: String) {
    let allHistory = TerminalSession.loadZshHistory()
    if filter.isEmpty {
      historySuggestions = allHistory
    } else {
      historySuggestions = allHistory.filter { $0.localizedCaseInsensitiveContains(filter) }
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
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    do {
      try process.run()
    } catch {
      let duration = Date().timeIntervalSince(startTime)
      return ("", String(describing: error), 1, duration)
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

    process.waitUntilExit()

    let duration = Date().timeIntervalSince(startTime)
    let output = String(data: outData, encoding: .utf8) ?? ""
    let error = String(data: errData, encoding: .utf8) ?? ""

    return (output, error, process.terminationStatus, duration)
  }

  func updateGitInfo() {
    let dir = self.currentDirectory
    Task.detached {
      let (gitCheck, _, exitCheck, _) = self.runShellCommand(
        "git rev-parse --is-inside-work-tree", directory: dir)
      guard exitCheck == 0, gitCheck.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
      else {
        await MainActor.run {
          self.gitInfo = nil
        }
        return
      }

      let (branchOut, _, _, _) = self.runShellCommand("git branch --show-current", directory: dir)
      let branch = branchOut.trimmingCharacters(in: .whitespacesAndNewlines)

      let (statusOut, _, _, _) = self.runShellCommand("git status --porcelain", directory: dir)
      let dirtyCount = statusOut.components(separatedBy: .newlines).filter {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }.count

      let (diffOut, _, _, _) = self.runShellCommand("git diff --shortstat", directory: dir)
      var additions = 0
      var deletions = 0
      let cleanedDiff = diffOut.trimmingCharacters(in: .whitespacesAndNewlines)
      if !cleanedDiff.isEmpty {
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
    let handle = TerminalHandle()

    let runningBlock = CommandBlock(
      id: blockID,
      directory: dir,
      command: trimmed,
      handle: handle,
      startTime: Date(),
      duration: 0.0,
      gitInfo: currentGit,
      isRunning: true,
      isError: false
    )
    self.blocks.append(runningBlock)

    let isSimpleCd = trimmed == "cd" || (
      trimmed.hasPrefix("cd ") &&
      !trimmed.contains("&&") &&
      !trimmed.contains(";") &&
      !trimmed.contains("|") &&
      !trimmed.contains("\n") &&
      !trimmed.contains("`") &&
      !trimmed.contains("$(")
    )

    if isSimpleCd {
      let cdArg = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
      let commandToRun = cdArg.isEmpty ? "cd && pwd" : "cd \(cdArg) && pwd"

      Task.detached {
        let (resolvedOut, _, code, _) = self.runShellCommand(commandToRun, directory: dir)
        if code == 0 {
          let resolved = resolvedOut.trimmingCharacters(in: .whitespacesAndNewlines)
          if !resolved.isEmpty {
            await MainActor.run {
              self.currentDirectory = resolved
              self.title = TerminalSession.displayPath(resolved)
              self.updateGitInfo()
            }
          }
        }
      }
    }
  }
}

@MainActor
final class TerminalSessionStore: ObservableObject {
  @Published private(set) var sessions: [TerminalSession] = []
  @Published var selectedID: UUID?

  private let currentDirectory: String

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
}
