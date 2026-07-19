import SwiftUI

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
    NavigationSplitView {
      SessionSidebar(
        sessions: sessionStore.sessions,
        selectedID: $sessionStore.selectedID,
        searchText: $sidebarSearch,
        onNewSession: sessionStore.addSession
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
    List(filteredSessions, selection: $selectedID) { session in
      SessionRow(session: session)
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
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
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
