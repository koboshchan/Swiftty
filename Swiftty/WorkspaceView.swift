import Combine
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
  @Published var historySuggestions: [String] = []
  @Published var isHistoryOpen: Bool = false
  @Published var selectedHistoryIndex: Int? = nil
  @Published var historyTab: String = "All"

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

struct WorkspaceView: View {
  @StateObject private var sessionStore: TerminalSessionStore
  @State private var sidebarSearch = ""
  @State private var commandText = ""

  private let workspaceDirectory: String

  init() {
    let project = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Projects/Swiftty", isDirectory: true)
    let directory =
      FileManager.default.fileExists(atPath: project.path)
      ? project.path
      : FileManager.default.homeDirectoryForCurrentUser.path

    self.workspaceDirectory = directory
    _sessionStore = StateObject(wrappedValue: TerminalSessionStore(currentDirectory: directory))
  }

  var body: some View {
    HStack(spacing: 0) {
      SessionSidebar(
        sessions: sessionStore.sessions,
        selectedID: $sessionStore.selectedID,
        searchText: $sidebarSearch,
        onNewSession: sessionStore.addSession
      )
      .frame(width: 326)

      Rectangle()
        .fill(Color.swLine)
        .frame(width: 1)

      TerminalWorkspace(
        sessions: sessionStore.sessions,
        selectedID: sessionStore.selectedID,
        commandText: $commandText
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 1_000, minHeight: 700)
    .background(Color.swCanvas)
    .ignoresSafeArea(.container, edges: .bottom)
  }
}

private struct SessionSidebar: View {
  let sessions: [TerminalSession]
  @Binding var selectedID: UUID?
  @Binding var searchText: String
  let onNewSession: () -> Void

  private var filteredSessions: [TerminalSession] {
    guard !searchText.isEmpty else { return sessions }
    return sessions.filter {
      $0.title.localizedCaseInsensitiveContains(searchText)
        || $0.subtitle.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 10) {
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(Color.swMuted)
            TextField("Search tabs...", text: $searchText)
              .textFieldStyle(.plain)
              .font(.system(size: 13, weight: .regular, design: .rounded))
              .foregroundStyle(Color.swText)
          }
          .padding(.horizontal, 11)
          .frame(height: 34)
          .glassEffect(.clear, in: .rect(cornerRadius: 8))

          SmallIconButton(systemName: "slider.horizontal.3", help: "Filter tabs") {}
          SmallIconButton(
            systemName: "plus", help: "New terminal", tint: .swText, action: onNewSession)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
      }
      .background(Color.swSidebar)

      Rectangle()
        .fill(Color.swLine)
        .frame(height: 1)

      if filteredSessions.isEmpty {
        VStack(spacing: 9) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(Color.swDim)
          Text("No sessions")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.swMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(filteredSessions) { session in
              SessionRow(
                session: session,
                selected: selectedID == session.id
              ) {
                selectedID = session.id
              }
            }
          }
        }
        .scrollIndicators(.hidden)
      }
    }
    .background(Color.swSidebar)
  }
}

private struct SessionRow: View {
  @ObservedObject var session: TerminalSession
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 13) {
        ZStack {
          Circle()
            .fill(selected ? Color.swRaised : Color(hex: 0x202020))
          Text(">_")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(selected ? Color.swMint : Color.swMuted)
        }
        .frame(width: 32, height: 32)

        VStack(alignment: .leading, spacing: 4) {
          Text(session.title)
            .font(.system(size: 13, weight: selected ? .medium : .regular, design: .monospaced))
            .foregroundStyle(selected ? Color.swText : Color.swMuted)
            .lineLimit(1)
          Text(session.subtitle)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(selected ? Color.swMuted : Color.swDim)
            .lineLimit(1)
        }

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 22)
      .frame(height: 76)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(selected ? Color.swRaised.opacity(0.58) : .clear)
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(Color.swLine.opacity(selected ? 0.8 : 0.55))
          .frame(height: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .ifSelectedGlass(selected)
  }
}

extension View {
  @ViewBuilder
  fileprivate func ifSelectedGlass(_ selected: Bool) -> some View {
    if selected {
      self.glassEffect(.regular.tint(Color.white.opacity(0.025)), in: .rect(cornerRadius: 8))
    } else {
      self
    }
  }
}

private struct SessionWorkspaceView: View {
  @ObservedObject var session: TerminalSession

  var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 8) {
            Spacer()
            ForEach(session.blocks) { block in
              CommandBlockView(block: block, session: session)
                .id(block.id)
            }
          }
          .frame(minHeight: geometry.size.height - 20, alignment: .bottom)
          .padding(.top, 16)
        }
        .onChange(of: session.blocks) { oldValue, newValue in
          if let lastBlock = newValue.last {
            withAnimation(.easeOut(duration: 0.2)) {
              proxy.scrollTo(lastBlock.id, anchor: .bottom)
            }
          }
        }
        .onChange(of: session.scrollTrigger) { oldValue, newValue in
          if let lastBlock = session.blocks.last {
            withAnimation(.easeOut(duration: 0.15)) {
              proxy.scrollTo(lastBlock.id, anchor: .bottom)
            }
          }
        }
        .onChange(of: session.scrollToBlockID) { oldValue, newValue in
          if let target = newValue {
            withAnimation(.easeOut(duration: 0.2)) {
              proxy.scrollTo(target.id, anchor: target.anchor == .top ? .top : .bottom)
            }
            session.scrollToBlockID = nil
          }
        }
        .onAppear {
          if let lastBlock = session.blocks.last {
            proxy.scrollTo(lastBlock.id, anchor: .bottom)
          }
        }
      }
    }
  }
}

private struct TerminalWorkspace: View {
  let sessions: [TerminalSession]
  let selectedID: UUID?
  @Binding var commandText: String

  private var selectedSession: TerminalSession? {
    sessions.first { $0.id == selectedID }
  }

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        ForEach(sessions) { session in
          SessionWorkspaceView(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.swCanvas)
            .opacity(selectedID == session.id ? 1 : 0)
            .zIndex(selectedID == session.id ? 1 : 0)
            .allowsHitTesting(selectedID == session.id)
        }
      }
      .background(Color.black)

      if let selectedSession, !selectedSession.blocks.contains(where: { $0.isRunning }) {
        CommandInputBar(
          commandText: $commandText,
          session: selectedSession
        ) {
          let cmd = commandText
          commandText = ""
          selectedSession.runCommand(cmd)
        }
      }
    }
    .background(Color.black)
  }
}

private struct CommandInputBar: View {
  @Binding var commandText: String
  @ObservedObject var session: TerminalSession
  let submit: () -> Void

  @State private var isFieldFocused = true

  private func confirmSuggestion(_ suggestion: String) {
    let components = commandText.components(separatedBy: " ")
    guard let last = components.last, !last.isEmpty else { return }

    var newComponents = components
    let suffix = suggestion.hasSuffix("/") ? "" : " "

    if last.contains("/") {
      let pathComponents = last.components(separatedBy: "/")
      let parentPath = pathComponents.dropLast().joined(separator: "/")
      let prefix = parentPath.isEmpty ? "" : parentPath + "/"
      newComponents[newComponents.count - 1] = prefix + suggestion + suffix
    } else {
      newComponents[newComponents.count - 1] = suggestion + suffix
    }

    commandText = newComponents.joined(separator: " ")
    session.autocompleteSuggestions = []
    session.selectedSuggestionIndex = nil
    session.ghostText = ""
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Suggestion Dropdown Panel (Autocomplete)
      if session.isAutocompleteOpen && !session.autocompleteSuggestions.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ScrollView {
            VStack(alignment: .leading, spacing: 2) {
              ForEach(Array(session.autocompleteSuggestions.enumerated()), id: \.element) { idx, suggestion in
                let isSelected = session.selectedSuggestionIndex == idx
                Button(action: {
                  confirmSuggestion(suggestion)
                }) {
                  HStack(spacing: 12) {
                    Image(systemName: suggestion.hasSuffix("/") ? "folder.fill" : "doc.text.fill")
                      .font(.system(size: 11))
                      .foregroundStyle(isSelected ? Color.white : (suggestion.hasSuffix("/") ? Color.swBlue : Color.swMuted))
                    Text(suggestion)
                      .font(.system(size: 13, design: .monospaced))
                    Spacer()
                    Text(suggestion.hasSuffix("/") ? "Folder" : "File")
                      .font(.system(size: 11))
                      .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.swDim)
                  }
                  .padding(.horizontal, 10)
                  .padding(.vertical, 6)
                  .background(isSelected ? Color.swBlue : Color.clear)
                  .foregroundStyle(isSelected ? Color.white : Color.swText)
                  .cornerRadius(4)
                }
                .buttonStyle(.plain)
              }
            }
            .padding(6)
          }
          .frame(maxHeight: 180)
        }
        .glassEffect(.regular.tint(Color.white.opacity(0.015)), in: .rect(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
      }

      // History Popup Panel
      if session.isHistoryOpen && !session.historySuggestions.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          // Tab bar header
          HStack(spacing: 16) {
            Text("HISTORY")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(Color.swMuted)
            
            ForEach(["All", "Commands", "Prompts"], id: \.self) { tab in
              let isSelected = session.historyTab == tab
              Button(action: { session.historyTab = tab }) {
                Text(tab)
                  .font(.system(size: 11, weight: isSelected ? .bold : .regular))
                  .foregroundStyle(isSelected ? Color.swText : Color.swMuted)
                  .padding(.horizontal, 8)
                  .padding(.vertical, 3)
                  .background(isSelected ? Color.swRaised.opacity(0.4) : Color.clear)
                  .cornerRadius(4)
              }
              .buttonStyle(.plain)
            }
            Spacer()
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          
          Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.8)
          
          ScrollView {
            VStack(alignment: .leading, spacing: 1) {
              ForEach(Array(session.historySuggestions.enumerated()), id: \.element) { idx, suggestion in
                let isSelected = session.selectedHistoryIndex == idx
                Button(action: {
                  commandText = suggestion
                  session.isHistoryOpen = false
                  session.historySuggestions = []
                  session.selectedHistoryIndex = nil
                }) {
                  HStack(spacing: 12) {
                    Image(systemName: "terminal.fill")
                      .font(.system(size: 10))
                      .foregroundStyle(isSelected ? Color.white : Color.swDim)
                    Text(suggestion)
                      .font(.system(size: 13, design: .monospaced))
                      .lineLimit(1)
                    Spacer()
                  }
                  .padding(.horizontal, 10)
                  .padding(.vertical, 6)
                  .background(isSelected ? Color.swBlue : Color.clear)
                  .foregroundStyle(isSelected ? Color.white : Color.swText)
                  .cornerRadius(4)
                }
                .buttonStyle(.plain)
              }
            }
            .padding(6)
          }
          .frame(maxHeight: 200)
          
          Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.8)
          
          // Footer hints
          HStack(spacing: 12) {
            HStack(spacing: 3) {
              Text("↑")
                .font(.system(size: 9))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.swRaised)
                .cornerRadius(3)
              Text("↓")
                .font(.system(size: 9))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.swRaised)
                .cornerRadius(3)
              Text("to navigate")
                .foregroundStyle(Color.swDim)
            }
            HStack(spacing: 3) {
              Text("⇧ tab")
                .font(.system(size: 9))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.swRaised)
                .cornerRadius(3)
              Text("to cycle tabs")
                .foregroundStyle(Color.swDim)
            }
            HStack(spacing: 3) {
              Text("esc")
                .font(.system(size: 9))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.swRaised)
                .cornerRadius(3)
              Text("to dismiss")
                .foregroundStyle(Color.swDim)
            }
            Spacer()
          }
          .font(.system(size: 10, design: .monospaced))
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
        }
        .glassEffect(.regular.tint(Color.white.opacity(0.015)), in: .rect(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
      }

      Rectangle()
        .fill(Color.swLine)
        .frame(height: 1)

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
          SmallPromptChip(systemName: "terminal", text: "base", tint: .swMuted)
          SmallPromptChip(systemName: "folder", text: session.title, tint: .swMuted)

          if let git = session.gitInfo {
            SmallPromptChip(systemName: "arrow.triangle.pull", text: git.branch, tint: .swMint)

            let disp = git.displayString
            if !disp.isEmpty {
              SmallPromptChip(systemName: "doc.text", text: disp, tint: .swAmber)
            }
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)

        HStack(spacing: 10) {
          ZStack(alignment: .leading) {
            // Render inline ghost text completion using spaces padding
            if !session.ghostText.isEmpty {
              Text(String(repeating: " ", count: commandText.count) + session.ghostText)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.swMuted.opacity(0.6))
                .allowsHitTesting(false)
            }

            AutocompleteTextField(
              text: $commandText,
              placeholder: "Run a command...",
              currentDirectory: session.currentDirectory,
              isFocused: isFieldFocused,
              session: session,
              onSubmit: submit
            )
            .frame(height: 22)
          }

          Button(action: submit) {
            Image(systemName: "return")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(Color.swMuted)
              .frame(width: 28, height: 28)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
      }
      .background(Color.swPanel)

      HStack(spacing: 16) {
        HStack(spacing: 4) {
          Text("↵")
            .foregroundStyle(Color.swMuted)
          Text("send command to shell")
            .foregroundStyle(Color.swDim)
        }
        HStack(spacing: 4) {
          Text("⌘↵")
            .foregroundStyle(Color.swMuted)
          Text("new line")
            .foregroundStyle(Color.swDim)
        }
      }
      .font(.system(size: 11, weight: .regular, design: .monospaced))
      .padding(.horizontal, 20)
      .padding(.bottom, 12)
      .padding(.top, 8)
      .background(Color.swPanel)
    }
    .onAppear {
      isFieldFocused = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        isFieldFocused = true
      }
    }
    .onChange(of: session.id) { _, _ in
      isFieldFocused = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        isFieldFocused = true
      }
    }
    .onChange(of: session.blocks.count) { _, _ in
      isFieldFocused = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        isFieldFocused = true
      }
    }
  }
}

private struct SmallPromptChip: View {
  let systemName: String?
  let text: String
  let tint: SwiftUI.Color

  var body: some View {
    HStack(spacing: 5) {
      if let systemName {
        Image(systemName: systemName)
          .font(.system(size: 9, weight: .semibold))
      }
      Text(text)
    }
    .foregroundStyle(tint)
    .font(.system(size: 11, weight: .medium, design: .monospaced))
    .padding(.horizontal, 8)
    .padding(.vertical, 4.5)
    .background(Color.swRaised.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.swLine, lineWidth: 0.6)
    )
  }
}

private struct PromptChip: View {
  let systemName: String?
  let text: String
  let tint: SwiftUI.Color

  var body: some View {
    HStack(spacing: 6) {
      if let systemName {
        Image(systemName: systemName)
          .font(.system(size: 10, weight: .semibold))
      }
      Text(text)
    }
    .foregroundStyle(tint)
    .font(.system(size: 12, weight: .medium, design: .monospaced))
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .glassEffect(.clear, in: .rect(cornerRadius: 6))
  }
}

private struct CommandBlockView: View {
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
        HStack(spacing: 8) {
          Image(systemName: "line.3.horizontal.decrease.circle")
            .font(.system(size: 11))
            .foregroundStyle(Color.swMuted)
          TextField("Filter output...", text: $filterText)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.swText)
          
          if !filterText.isEmpty {
            Button(action: { filterText = "" }) {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.swMuted)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.swPanel, in: RoundedRectangle(cornerRadius: 4))
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
          onClick: { handleBlockClick() }
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

private struct StyledTextSegment {
  let text: String
  var color: SwiftUI.Color? = nil
  var isBold: Bool = false
}

private func parseANSIText(_ text: String) -> Text {
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


/// NSTextField subclass that intercepts Tab before SwiftUI's focus engine can swallow it.
class AutocompleteNSTextField: NSTextField {
  var onTab: (() -> Void)?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.keyCode == 48 { // Tab
      onTab?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 48 {
      onTab?()
    } else {
      super.keyDown(with: event)
    }
  }
}

struct AutocompleteTextField: NSViewRepresentable {
  @Binding var text: String
  let placeholder: String
  let currentDirectory: String
  var isFocused: Bool
  let session: TerminalSession
  let onSubmit: () -> Void

  func makeNSView(context: Context) -> AutocompleteNSTextField {
    let textField = AutocompleteNSTextField()
    textField.placeholderString = placeholder
    textField.isBordered = false
    textField.drawsBackground = false
    textField.focusRingType = .none
    textField.font = NSFont.monospacedSystemFont(ofSize: 14.0, weight: .regular)
    textField.textColor = NSColor(red: 214/255, green: 214/255, blue: 214/255, alpha: 1)
    textField.delegate = context.coordinator
    let coordinator = context.coordinator
    textField.onTab = {
      coordinator.handleTabOrNavigation(textField: textField, isForward: true)
    }
    return textField
  }

  func updateNSView(_ nsView: AutocompleteNSTextField, context: Context) {
    context.coordinator.parent = self

    if nsView.stringValue != text {
      nsView.stringValue = text
      let highlighted = context.coordinator.highlight(text)
      if let textView = nsView.currentEditor() as? NSTextView {
        textView.textStorage?.setAttributedString(highlighted)
      } else {
        nsView.attributedStringValue = highlighted
      }
      if let editor = nsView.currentEditor() {
        editor.selectedRange = NSRange(location: text.count, length: 0)
      }
    }
    if isFocused {
      DispatchQueue.main.async {
        if nsView.window != nil && nsView.window?.firstResponder != nsView.currentEditor() {
          nsView.window?.makeFirstResponder(nsView)
        }
      }
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: AutocompleteTextField
    var originalText: String? = nil

    init(_ parent: AutocompleteTextField) {
      self.parent = parent
    }

    func highlight(_ text: String) -> NSAttributedString {
      let attr = NSMutableAttributedString(string: text)
      let font = NSFont.monospacedSystemFont(ofSize: 14.0, weight: .regular)
      let fullRange = NSRange(location: 0, length: text.count)
      attr.addAttribute(.font, value: font, range: fullRange)
      attr.addAttribute(.foregroundColor, value: NSColor(red: 214/255, green: 214/255, blue: 214/255, alpha: 1), range: fullRange)

      let components = text.components(separatedBy: " ")
      var currentPos = 0
      var expectCommand = true

      for comp in components {
        let range = NSRange(location: currentPos, length: comp.count)
        
        if comp == "|" || comp == "&&" || comp == "||" || comp == ";" {
          attr.addAttribute(.foregroundColor, value: NSColor(red: 214/255, green: 214/255, blue: 214/255, alpha: 1), range: range)
          expectCommand = true
        } else if expectCommand && !comp.isEmpty {
          attr.addAttribute(.foregroundColor, value: NSColor(red: 152/255, green: 195/255, blue: 121/255, alpha: 1), range: range)
          expectCommand = false
        } else if comp.hasPrefix("-") && !comp.isEmpty {
          attr.addAttribute(.foregroundColor, value: NSColor(red: 86/255, green: 182/255, blue: 194/255, alpha: 1), range: range)
        } else {
          attr.addAttribute(.foregroundColor, value: NSColor(red: 214/255, green: 214/255, blue: 214/255, alpha: 1), range: range)
        }
        currentPos += comp.count + 1
      }
      return attr
    }

    func controlTextDidChange(_ obj: Notification) {
      if let textField = obj.object as? NSTextField {
        parent.text = textField.stringValue
        originalText = nil
        parent.session.selectedSuggestionIndex = nil
        parent.session.autocompleteTabCount = 0
        parent.session.isAutocompleteOpen = false

        if let textView = textField.currentEditor() as? NSTextView {
          let highlighted = highlight(textField.stringValue)
          textView.textStorage?.setAttributedString(highlighted)
        } else {
          textField.attributedStringValue = highlight(textField.stringValue)
        }

        updateSuggestions(text: textField.stringValue)

        if parent.session.isHistoryOpen {
          parent.session.openHistory(filter: textField.stringValue)
        }
      }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      let session = parent.session
      guard let textField = control as? AutocompleteNSTextField else { return false }

      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
          textView.insertText("\n", replacementRange: textView.selectedRange())
          return true
        }

        if session.isHistoryOpen, let idx = session.selectedHistoryIndex {
          confirmHistorySelection(textField: textField, index: idx)
          return true
        } else if session.isAutocompleteOpen && !session.autocompleteSuggestions.isEmpty, let idx = session.selectedSuggestionIndex {
          confirmSuggestion(textField: textField, index: idx)
          return true
        } else {
          parent.onSubmit()
          return true
        }
      }

      if commandSelector == #selector(NSResponder.insertTab(_:)) ||
         commandSelector == Selector(("insertBacktab:")) ||
         commandSelector == Selector(("insertTabIgnoringFieldEditor:")) {
        if session.isHistoryOpen {
          // Cycle history tabs
          let tabs = ["All", "Commands", "Prompts"]
          if let idx = tabs.firstIndex(of: session.historyTab) {
            let isShift = NSEvent.modifierFlags.contains(.shift)
            let nextIdx = isShift ? (idx - 1 + tabs.count) % tabs.count : (idx + 1) % tabs.count
            session.historyTab = tabs[nextIdx]
          }
        } else {
          handleTabOrNavigation(textField: textField, isForward: true)
        }
        return true
      }

      if commandSelector == #selector(NSResponder.moveDown(_:)) {
        if session.isHistoryOpen {
          navigateHistory(isForward: true)
          return true
        } else if session.isAutocompleteOpen {
          handleTabOrNavigation(textField: textField, isForward: true)
          return true
        }
      }

      if commandSelector == #selector(NSResponder.moveUp(_:)) {
        if session.isHistoryOpen {
          navigateHistory(isForward: false)
          return true
        } else if session.isAutocompleteOpen {
          handleTabOrNavigation(textField: textField, isForward: false)
          return true
        } else {
          // Up Arrow opens history suggestions
          session.openHistory(filter: parent.text)
          return true
        }
      }

      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        var handled = false
        if session.isHistoryOpen {
          session.isHistoryOpen = false
          session.historySuggestions = []
          session.selectedHistoryIndex = nil
          handled = true
        }
        if session.isAutocompleteOpen || !session.autocompleteSuggestions.isEmpty {
          session.autocompleteSuggestions = []
          session.selectedSuggestionIndex = nil
          session.ghostText = ""
          session.isAutocompleteOpen = false
          session.autocompleteTabCount = 0
          originalText = nil
          handled = true
        }
        return handled
      }

      return false
    }

    func handleTabOrNavigation(textField: AutocompleteNSTextField, isForward: Bool) {
      let session = parent.session
      if !session.isAutocompleteOpen {
        session.autocompleteTabCount += 1
        if session.autocompleteTabCount == 1 {
          performAutocomplete(textField: textField)
        } else if session.autocompleteTabCount >= 2 {
          session.isAutocompleteOpen = true
          if !session.autocompleteSuggestions.isEmpty {
            session.selectedSuggestionIndex = 0
            updateTextInputWithSuggestion(textField: textField, index: 0)
          }
        }
      } else {
        let count = session.autocompleteSuggestions.count
        guard count > 0 else { return }

        if let currentIdx = session.selectedSuggestionIndex {
          let nextIdx = isForward ? (currentIdx + 1) % count : (currentIdx - 1 + count) % count
          session.selectedSuggestionIndex = nextIdx
          updateTextInputWithSuggestion(textField: textField, index: nextIdx)
        } else {
          let firstIdx = isForward ? 0 : count - 1
          session.selectedSuggestionIndex = firstIdx
          updateTextInputWithSuggestion(textField: textField, index: firstIdx)
        }
      }
    }

    private func navigateHistory(isForward: Bool) {
      let session = parent.session
      let count = session.historySuggestions.count
      guard count > 0 else { return }

      if let currentIdx = session.selectedHistoryIndex {
        let nextIdx = isForward ? (currentIdx + 1) % count : (currentIdx - 1 + count) % count
        session.selectedHistoryIndex = nextIdx
      } else {
        session.selectedHistoryIndex = isForward ? 0 : count - 1
      }
    }

    private func confirmHistorySelection(textField: AutocompleteNSTextField, index: Int) {
      let session = parent.session
      let command = session.historySuggestions[index]
      parent.text = command
      textField.stringValue = command

      if let textView = textField.currentEditor() as? NSTextView {
        let highlighted = highlight(command)
        textView.textStorage?.setAttributedString(highlighted)
      } else {
        textField.attributedStringValue = highlight(command)
      }

      session.isHistoryOpen = false
      session.historySuggestions = []
      session.selectedHistoryIndex = nil
    }

    private func updateTextInputWithSuggestion(textField: AutocompleteNSTextField, index: Int) {
      let session = parent.session
      let suggestion = session.autocompleteSuggestions[index]
      let baseText = originalText ?? parent.text
      let components = baseText.components(separatedBy: " ")
      guard let last = components.last, !last.isEmpty else { return }

      var newComponents = components
      let suffix = suggestion.hasSuffix("/") ? "" : " "

      if last.contains("/") {
        let pathComponents = last.components(separatedBy: "/")
        let parentPath = pathComponents.dropLast().joined(separator: "/")
        let prefix = parentPath.isEmpty ? "" : parentPath + "/"
        newComponents[newComponents.count - 1] = prefix + suggestion + suffix
      } else {
        newComponents[newComponents.count - 1] = suggestion + suffix
      }

      let newText = newComponents.joined(separator: " ")
      parent.text = newText
      textField.stringValue = newText

      if let textView = textField.currentEditor() as? NSTextView {
        let highlighted = highlight(newText)
        textView.textStorage?.setAttributedString(highlighted)
      } else {
        textField.attributedStringValue = highlight(newText)
      }

      if let editor = textField.currentEditor() {
        editor.selectedRange = NSRange(location: newText.count, length: 0)
      }

      session.ghostText = ""
    }

    private func confirmSuggestion(textField: AutocompleteNSTextField, index: Int) {
      let session = parent.session
      session.autocompleteSuggestions = []
      session.selectedSuggestionIndex = nil
      session.ghostText = ""
      session.isAutocompleteOpen = false
      session.autocompleteTabCount = 0
      originalText = nil
    }

    private func updateSuggestions(text: String) {
      let session = parent.session
      let components = text.components(separatedBy: " ")
      guard let last = components.last, !last.isEmpty else {
        session.autocompleteSuggestions = []
        session.ghostText = ""
        return
      }

      let fileManager = FileManager.default
      let expandedLast = last.hasPrefix("~") ? NSString(string: last).expandingTildeInPath : last
      let sessionDir = NSString(string: parent.currentDirectory).expandingTildeInPath

      let searchDir: String
      let searchPrefix: String

      if expandedLast.contains("/") {
        let nsLast = expandedLast as NSString
        let relParent = nsLast.deletingLastPathComponent
        searchPrefix = nsLast.lastPathComponent

        if relParent.hasPrefix("/") {
          searchDir = relParent
        } else {
          let baseURl = URL(fileURLWithPath: sessionDir)
          let resolvedURL = URL(fileURLWithPath: relParent, relativeTo: baseURl)
          searchDir = resolvedURL.path
        }
      } else {
        searchDir = sessionDir
        searchPrefix = expandedLast
      }

      do {
        let contents = try fileManager.contentsOfDirectory(atPath: searchDir)
        let matches = contents.filter {
          $0.lowercased().hasPrefix(searchPrefix.lowercased())
        }.sorted()

        if matches.isEmpty {
          session.autocompleteSuggestions = []
          session.ghostText = ""
          return
        }

        var displayMatches: [String] = []
        for m in matches {
          let fullPath = (searchDir as NSString).appendingPathComponent(m)
          var isDir: ObjCBool = false
          let exists = fileManager.fileExists(atPath: fullPath, isDirectory: &isDir)
          if exists && isDir.boolValue {
            displayMatches.append(m + "/")
          } else {
            displayMatches.append(m)
          }
        }

        session.autocompleteSuggestions = displayMatches

        // Compute LCP
        var common = matches[0]
        for m in matches.dropFirst() {
          while !m.lowercased().hasPrefix(common.lowercased()) {
            common = String(common.dropLast())
          }
        }

        if common.count >= searchPrefix.count {
          let remainder = String(common.dropFirst(searchPrefix.count))
          if matches.count == 1 {
            let fullPath = (searchDir as NSString).appendingPathComponent(matches[0])
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: fullPath, isDirectory: &isDir)
            let suffix = (exists && isDir.boolValue) ? "/" : " "
            session.ghostText = remainder + suffix
          } else {
            session.ghostText = remainder
          }
        } else {
          session.ghostText = ""
        }
      } catch {
        session.autocompleteSuggestions = []
        session.ghostText = ""
      }
    }

    private func performAutocomplete(textField: AutocompleteNSTextField) {
      let session = parent.session
      let currentText = textField.stringValue
      let components = currentText.components(separatedBy: " ")
      guard let last = components.last, !last.isEmpty else { return }

      let fileManager = FileManager.default
      let expandedLast = last.hasPrefix("~") ? NSString(string: last).expandingTildeInPath : last
      let sessionDir = NSString(string: parent.currentDirectory).expandingTildeInPath

      let searchDir: String
      let searchPrefix: String

      if expandedLast.contains("/") {
        let nsLast = expandedLast as NSString
        let relParent = nsLast.deletingLastPathComponent
        searchPrefix = nsLast.lastPathComponent

        if relParent.hasPrefix("/") {
          searchDir = relParent
        } else {
          let baseURl = URL(fileURLWithPath: sessionDir)
          let resolvedURL = URL(fileURLWithPath: relParent, relativeTo: baseURl)
          searchDir = resolvedURL.path
        }
      } else {
        searchDir = sessionDir
        searchPrefix = expandedLast
      }

      do {
        let contents = try fileManager.contentsOfDirectory(atPath: searchDir)
        let matches = contents.filter {
          $0.lowercased().hasPrefix(searchPrefix.lowercased())
        }.sorted()

        guard !matches.isEmpty else { return }

        // Find LCP
        var common = matches[0]
        for m in matches.dropFirst() {
          while !m.lowercased().hasPrefix(common.lowercased()) {
            common = String(common.dropLast())
          }
        }

        let suffix: String
        if matches.count == 1 {
          let fullPath = (searchDir as NSString).appendingPathComponent(common)
          var isDir: ObjCBool = false
          let exists = fileManager.fileExists(atPath: fullPath, isDirectory: &isDir)
          suffix = (exists && isDir.boolValue) ? "/" : " "
        } else {
          suffix = ""
        }

        var newComponents = components
        let completedToken: String
        if expandedLast.contains("/") {
          let nsLast = expandedLast as NSString
          let relParent = nsLast.deletingLastPathComponent
          
          if relParent.hasPrefix("/") {
            completedToken = (relParent as NSString).appendingPathComponent(common) + suffix
          } else {
            completedToken = (relParent as NSString).appendingPathComponent(common) + suffix
          }
        } else {
          completedToken = common + suffix
        }

        let newText = newComponents.joined(separator: " ")
        parent.text = newText
        textField.stringValue = newText

        if let editor = textField.currentEditor() {
          textField.attributedStringValue = highlight(newText)
          editor.selectedRange = NSRange(location: newText.count, length: 0)
        }

        // Open suggestions dropdown showing matches under the newly completed prefix
        updateSuggestions(text: newText)
      } catch {
        // Ignore
      }
    }
  }
}

