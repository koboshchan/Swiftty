import SwiftUI

struct WorkspaceView: View {
  @StateObject private var sessionStore: TerminalSessionStore
  @State private var sidebarSearch = ""
  @State private var commandText = ""

  @State private var sessionToClose: TerminalSession? = nil
  @State private var showCloseAlert = false

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
    
    // Warm up the autocomplete system commands cache asynchronously on launch
    AutocompleteTextField.Coordinator.loadSystemCommands()
  }

  private func attemptCloseSession(_ session: TerminalSession) {
    if session.blocks.contains(where: { $0.isRunning }) {
      sessionToClose = session
      showCloseAlert = true
    } else {
      sessionStore.closeSession(session)
    }
  }

  var body: some View {
    ZStack {
      // Invisible background buttons for global window-level keyboard shortcuts
      Group {
        // ⌘T: New session
        Button("") { sessionStore.addSession() }
          .keyboardShortcut("t", modifiers: .command)
        
        // ⌘W: Close active session
        Button("") {
          if let sel = sessionStore.selectedSession {
            attemptCloseSession(sel)
          }
        }
        .keyboardShortcut("w", modifiers: .command)
        
        // ⇧⌘T: Restore last closed session
        Button("") { sessionStore.restoreLastClosedSession() }
          .keyboardShortcut("t", modifiers: [.command, .shift])
        
        // ⌘[: Select previous session
        Button("") {
          let sessions = sessionStore.sessions
          guard !sessions.isEmpty, let selID = sessionStore.selectedID,
                let idx = sessions.firstIndex(where: { $0.id == selID }) else { return }
          let prevIdx = (idx - 1 + sessions.count) % sessions.count
          sessionStore.selectedID = sessions[prevIdx].id
        }
        .keyboardShortcut("[", modifiers: .command)

        // ⌘]: Select next session
        Button("") {
          let sessions = sessionStore.sessions
          guard !sessions.isEmpty, let selID = sessionStore.selectedID,
                let idx = sessions.firstIndex(where: { $0.id == selID }) else { return }
          let nextIdx = (idx + 1) % sessions.count
          sessionStore.selectedID = sessions[nextIdx].id
        }
        .keyboardShortcut("]", modifiers: .command)
        
        // ⌘K: Clear history blocks of active session
        Button("") {
          if let session = sessionStore.selectedSession {
            session.blocks.removeAll()
            session.selectedBlockIDs.removeAll()
          }
        }
        .keyboardShortcut("k", modifiers: .command)
        
        // ⌘L: Focus bottom input bar
        Button("") {
          sessionStore.selectedSession?.isFieldFocused = true
        }
        .keyboardShortcut("l", modifiers: .command)
        
        // ⌘F: Focus active block filter
        Button("") {
          if let session = sessionStore.selectedSession, let lastBlock = session.blocks.last {
            // Set search active
            if let idx = session.blocks.firstIndex(where: { $0.id == lastBlock.id }) {
              let updatedBlock = CommandBlock(
                id: lastBlock.id,
                directory: lastBlock.directory,
                command: lastBlock.command,
                handle: lastBlock.handle,
                startTime: lastBlock.startTime,
                duration: lastBlock.duration,
                gitInfo: lastBlock.gitInfo,
                isRunning: lastBlock.isRunning,
                isError: lastBlock.isError,
                exitCode: lastBlock.exitCode,
                staticOutput: lastBlock.staticOutput,
                isFilterActive: true
              )
              session.blocks[idx] = updatedBlock
            }
          }
        }
        .keyboardShortcut("f", modifiers: .command)
        
        // Esc: Dismiss autocomplete/history/filters
        Button("") {
          if let session = sessionStore.selectedSession {
            session.isAutocompleteOpen = false
            session.isHistoryOpen = false
            session.selectedBlockIDs.removeAll()
            // Dismiss filters of all blocks
            for i in 0..<session.blocks.count {
              let b = session.blocks[i]
              if b.isFilterActive {
                session.blocks[i] = CommandBlock(
                  id: b.id,
                  directory: b.directory,
                  command: b.command,
                  handle: b.handle,
                  startTime: b.startTime,
                  duration: b.duration,
                  gitInfo: b.gitInfo,
                  isRunning: b.isRunning,
                  isError: b.isError,
                  exitCode: b.exitCode,
                  staticOutput: b.staticOutput,
                  isFilterActive: false
                )
              }
            }
          }
        }
        .keyboardShortcut(.cancelAction)

        // ⌘1 to ⌘9: Select Tab 1 to 9
        ForEach(1...9, id: \.self) { num in
          Button("") {
            if num <= sessionStore.sessions.count {
              sessionStore.selectedID = sessionStore.sessions[num - 1].id
            }
          }
          .keyboardShortcut(KeyEquivalent(Character(String(num))), modifiers: .command)
        }
      }
      .opacity(0)
      .allowsHitTesting(false)
      .frame(width: 0, height: 0)

      NavigationSplitView {
        SessionSidebar(
          sessions: sessionStore.sessions,
          selectedID: $sessionStore.selectedID,
          searchText: $sidebarSearch,
          onNewSession: sessionStore.addSession,
          onCloseSession: attemptCloseSession
        )
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
      } detail: {
        TerminalWorkspace(
          sessions: sessionStore.sessions,
          selectedID: sessionStore.selectedID,
          commandText: $commandText
        )
      }
      .frame(minWidth: 1_000, minHeight: 700)
      .background(Color.swCanvas)
    }
    .alert("Active Commands Running", isPresented: $showCloseAlert) {
      Button("Close Session", role: .destructive) {
        if let session = sessionToClose {
          sessionStore.closeSession(session)
        }
        sessionToClose = nil
      }
      Button("Cancel", role: .cancel) {
        sessionToClose = nil
      }
    } message: {
      Text("This tab has running commands. Closing it will terminate them.")
    }
  }
}

private struct SessionSidebar: View {
  let sessions: [TerminalSession]
  @Binding var selectedID: UUID?
  @Binding var searchText: String
  let onNewSession: () -> Void
  let onCloseSession: (TerminalSession) -> Void

  private var filteredSessions: [TerminalSession] {
    guard !searchText.isEmpty else { return sessions }
    return sessions.filter {
      $0.title.localizedCaseInsensitiveContains(searchText)
        || $0.subtitle.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    List(filteredSessions, selection: $selectedID) { session in
      SessionRow(session: session, onClose: { onCloseSession(session) })
        .tag(session.id)
    }
    .listStyle(.sidebar)
    .searchable(text: $searchText, placement: .sidebar, prompt: "Search tabs...")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(action: onNewSession) {
          Label("New Terminal", systemImage: "plus")
        }
        .help("New Terminal")
      }
    }
  }
}

private struct SessionRow: View {
  @ObservedObject var session: TerminalSession
  let onClose: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 12) {
      ZStack {
        Circle()
          .fill(Color.swRaised)
        Text(">_")
          .font(.system(size: 11, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.swMint)
      }
      .frame(width: 28, height: 28)

      VStack(alignment: .leading, spacing: 3) {
        Text(session.title)
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color.primary)
          .lineLimit(1)
        Text(session.subtitle)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(Color.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      
      if isHovered {
        Button(action: onClose) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 13))
            .foregroundStyle(Color.secondary)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
      }
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .onHover { hovering in
      isHovered = hovering
    }
  }
}

private struct SessionWorkspaceView: View {
  @ObservedObject var session: TerminalSession

  // Whether the scroll view is pinned near the bottom. Auto-scroll from
  // streaming output only applies when this is true, so scrolling up to read
  // history isn't fought by the follow-the-output behavior.
  @State private var isNearBottom = true

  var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 0) {
            // Flexible top spacer pushes the blocks down so the newest one
            // rests just above the input bar when there are only a few. Once
            // the blocks fill the height it collapses to zero and they scroll.
            Spacer(minLength: 0)
            ForEach(Array(session.blocks.enumerated()), id: \.element.id) { idx, block in
              let nextBlockSelected = (idx < session.blocks.count - 1) &&
                                      session.selectedBlockIDs.contains(block.id) &&
                                      session.selectedBlockIDs.contains(session.blocks[idx + 1].id)
              CommandBlockView(block: block, session: session)
                .id(block.id)
                .padding(.bottom, nextBlockSelected ? 0 : 16)
            }
            // Fixed clearance so the last block clears the floating input bar
            // overlay. Fixed (not a flexible Spacer) so it doesn't compete with
            // the top spacer and strand the blocks in the middle.
            Color.clear
              .frame(height: 150)
              .id("bottom_spacer")
          }
          .padding(.horizontal, 16)
          .frame(minHeight: geometry.size.height, alignment: .bottom)
          .padding(.top, 16)
        }
        .onScrollGeometryChange(for: Bool.self) { geo in
          // Near the bottom if the remaining scroll distance is within a small
          // threshold. Bottom-anchored content can sit a hair past the exact
          // bottom, so a generous threshold keeps "follow output" feeling sticky.
          geo.contentOffset.y >= geo.contentSize.height - geo.containerSize.height - 120
        } action: { _, nearBottom in
          isNearBottom = nearBottom
        }
        .onChange(of: session.blocks) { oldValue, newValue in
          // A new command (or a block completing) always jumps to the bottom.
          withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottom_spacer", anchor: .bottom)
          }
        }
        .onChange(of: session.scrollTrigger) { oldValue, newValue in
          // Streaming output only follows to the bottom while the user is
          // already there — otherwise leave their scroll position alone.
          guard isNearBottom else { return }
          withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("bottom_spacer", anchor: .bottom)
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
          proxy.scrollTo("bottom_spacer", anchor: .bottom)
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
    ZStack(alignment: .bottom) {
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
          selectedSession.ghostText = ""
          selectedSession.autocompleteSuggestions = []
          selectedSession.isAutocompleteOpen = false
          selectedSession.selectedSuggestionIndex = nil
          selectedSession.originalAutocompleteText = nil
          selectedSession.autocompleteTabCount = 0
          selectedSession.runCommand(cmd)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .zIndex(10)
      }
    }
    .background(Color.black)
  }
}
