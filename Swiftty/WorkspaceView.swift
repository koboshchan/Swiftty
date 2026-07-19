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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
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
          AutocompleteTextField(
            text: $commandText,
            placeholder: "Run a command...",
            currentDirectory: session.currentDirectory,
            isFocused: isFieldFocused,
            onSubmit: submit
          )
          .frame(height: 22)

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

      HStack(spacing: 12) {
        HStack(spacing: 4) {
          Text("⌘")
            .foregroundStyle(Color.swMuted)
          Text("↵")
            .foregroundStyle(Color.swDim)
          Text("send command to shell")
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
            SmallIconButton(systemName: "doc.on.doc", help: "Copy command") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(block.command, forType: .string)
            }
            
            SmallIconButton(
              systemName: "line.3.horizontal.decrease.circle",
              help: "Filter output",
              tint: isFilterActive ? .swMint : .swMuted
            ) {
              withAnimation(.easeOut(duration: 0.15)) {
                isFilterActive.toggle()
                if !isFilterActive {
                  filterText = ""
                }
              }
            }

            Menu {
              Button("Copy Output") {
                if let view = block.handle.view {
                  let text = getAllOutput(for: view)
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(text, forType: .string)
                }
              }
              Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(block.command, forType: .string)
              }
              Button("Re-run Command") {
                session.runCommand(block.command)
              }
              Divider()
              Button("Delete Block", role: .destructive) {
                if let idx = session.blocks.firstIndex(where: { $0.id == block.id }) {
                  session.blocks.remove(at: idx)
                }
              }
            } label: {
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
          handle: block.handle
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
        .fill(isHovered ? Color.swRaised.opacity(0.18) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(isHovered ? Color.swLine : Color.clear, lineWidth: 0.8)
    )
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.15)) {
        isHovered = hovering
      }
    }
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
                session.scrollTrigger = UUID()
              }
            }
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

struct AutocompleteTextField: NSViewRepresentable {
  @Binding var text: String
  let placeholder: String
  let currentDirectory: String
  var isFocused: Bool
  let onSubmit: () -> Void

  func makeNSView(context: Context) -> NSTextField {
    let textField = NSTextField()
    textField.placeholderString = placeholder
    textField.isBordered = false
    textField.drawsBackground = false
    textField.focusRingType = .none
    textField.font = NSFont.monospacedSystemFont(ofSize: 14.0, weight: .regular)
    textField.textColor = NSColor(red: 0xD6/255, green: 0xD6/255, blue: 0xD6/255, alpha: 1)
    textField.delegate = context.coordinator
    return textField
  }

  func updateNSView(_ nsView: NSTextField, context: Context) {
    if nsView.stringValue != text {
      nsView.stringValue = text
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

    init(_ parent: AutocompleteTextField) {
      self.parent = parent
    }

    func controlTextDidChange(_ obj: Notification) {
      if let textField = obj.object as? NSTextField {
        parent.text = textField.stringValue
      }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      if commandSelector == #selector(NSResponder.insertTab(_:)) {
        let completed = autocomplete(text: parent.text, currentDirectory: parent.currentDirectory)
        parent.text = completed
        if let textField = control as? NSTextField {
          textField.stringValue = completed
          if let textEditor = textField.currentEditor() {
            textEditor.selectedRange = NSRange(location: completed.count, length: 0)
          }
        }
        return true
      } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        parent.onSubmit()
        return true
      }
      return false
    }

    private func autocomplete(text: String, currentDirectory: String) -> String {
      let components = text.components(separatedBy: " ")
      guard let last = components.last, !last.isEmpty else { return text }
      
      let fileManager = FileManager.default
      let searchDir: String
      let searchPrefix: String
      
      if last.contains("/") {
        let url = URL(fileURLWithPath: last, relativeTo: URL(fileURLWithPath: currentDirectory))
        let parentURL = url.deletingLastPathComponent()
        searchDir = parentURL.path
        searchPrefix = url.lastPathComponent
      } else {
        searchDir = currentDirectory
        searchPrefix = last
      }
      
      do {
        let contents = try fileManager.contentsOfDirectory(atPath: searchDir)
        let matches = contents.filter { $0.lowercased().hasPrefix(searchPrefix.lowercased()) }
        
        if matches.count == 1 {
          let match = matches[0]
          let fullPath = URL(fileURLWithPath: searchDir).appendingPathComponent(match).path
          var isDir: ObjCBool = false
          let exists = fileManager.fileExists(atPath: fullPath, isDirectory: &isDir)
          let suffix = (exists && isDir.boolValue) ? "/" : " "
          
          var newComponents = components
          if last.contains("/") {
            let pathComponents = last.components(separatedBy: "/")
            let completedPath = pathComponents.dropLast().joined(separator: "/") + "/" + match + suffix
            newComponents[newComponents.count - 1] = completedPath
          } else {
            newComponents[newComponents.count - 1] = match + suffix
          }
          return newComponents.joined(separator: " ")
        } else if matches.count > 1 {
          let sorted = matches.sorted()
          let first = sorted.first!
          let lastMatch = sorted.last!
          var common = ""
          for (c1, c2) in zip(first, lastMatch) {
            if c1 == c2 {
              common.append(c1)
            } else {
              break
            }
          }
          
          if common.count > searchPrefix.count {
            var newComponents = components
            if last.contains("/") {
              let pathComponents = last.components(separatedBy: "/")
              let completedPath = pathComponents.dropLast().joined(separator: "/") + "/" + common
              newComponents[newComponents.count - 1] = completedPath
            } else {
              newComponents[newComponents.count - 1] = common
            }
            return newComponents.joined(separator: " ")
          }
        }
      } catch {
        // Ignore
      }
      return text
    }
  }
}

