import SwiftUI

struct HistoryItem: Identifiable {
  let id: Int
  let command: String
}

struct AutocompleteItem: Identifiable {
  let id: Int
  let suggestion: String
}

struct CommandInputBar: View {
  @Binding var commandText: String
  @ObservedObject var session: TerminalSession
  let submit: () -> Void

  @State private var inputHeight: CGFloat = 22

  var historyItems: [HistoryItem] {
    session.historySuggestions.enumerated().reversed().map { HistoryItem(id: $0.offset, command: $0.element) }
  }

  var autocompleteItems: [AutocompleteItem] {
    session.autocompleteSuggestions.enumerated().map { AutocompleteItem(id: $0.offset, suggestion: $0.element) }
  }

  private func confirmSuggestion(_ suggestion: String) {
    let baseText = session.originalAutocompleteText ?? commandText
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

    commandText = newComponents.joined(separator: " ")
    session.autocompleteSuggestions = []
    session.selectedSuggestionIndex = nil
    session.ghostText = ""
    session.originalAutocompleteText = nil
  }

  private func isSystemCommand(_ name: String) -> Bool {
    let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
    let paths = pathEnv.components(separatedBy: ":")
    let fileManager = FileManager.default
    for path in paths {
      let fullPath = URL(fileURLWithPath: path).appendingPathComponent(name).path
      if fileManager.isExecutableFile(atPath: fullPath) {
        return true
      }
    }
    return false
  }

  private func suggestionInfo(for suggestion: String) -> (icon: String, typeText: String, color: Color) {
    if suggestion.hasSuffix("/") {
      return ("folder.fill", "Folder", Color.accentColor)
    } else if !suggestion.contains("/") && isSystemCommand(suggestion) {
      return ("terminal.fill", "Command", Color.swMint)
    } else {
      return ("doc.text.fill", "File", Color.swMuted)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Suggestion Dropdown Panel (Autocomplete)
      if session.isAutocompleteOpen && !session.autocompleteSuggestions.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 2) {
                ForEach(autocompleteItems) { item in
                  let idx = item.id
                  let suggestion = item.suggestion
                  let isSelected = session.selectedSuggestionIndex == idx
                  let info = suggestionInfo(for: suggestion)
                  Button(action: {
                    confirmSuggestion(suggestion)
                  }) {
                    HStack(spacing: 12) {
                      Image(systemName: info.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white : info.color)
                      Text(suggestion)
                        .font(.system(size: 13, design: .monospaced))
                      Spacer()
                      Text(info.typeText)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.swDim)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isSelected ? Color.accentColor : Color.clear)
                    .foregroundStyle(isSelected ? Color.white : Color.swText)
                    .cornerRadius(8)
                  }
                  .buttonStyle(.plain)
                  .id(idx)
                }
              }
              .padding(6)
            }
            .frame(maxHeight: 180)
            .onChange(of: session.selectedSuggestionIndex) { _, newIdx in
              if let idx = newIdx {
                withAnimation(.easeOut(duration: 0.1)) {
                  proxy.scrollTo(idx, anchor: .center)
                }
              }
            }
          }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
          RoundedRectangle(cornerRadius: 14)
            .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
        )
        .padding(.bottom, 8)
      }

      // History Popup Panel
      if session.isHistoryOpen && !session.historySuggestions.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          // Header
          HStack(spacing: 16) {
            Text("COMMAND HISTORY")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(Color.swMuted)
            Spacer()
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          
          Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.8)
          
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 1) {
                ForEach(historyItems) { item in
                  let idx = item.id
                  let suggestion = item.command
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
                    .background(isSelected ? Color.accentColor : Color.clear)
                    .foregroundStyle(isSelected ? Color.white : Color.swText)
                    .cornerRadius(8)
                  }
                  .buttonStyle(.plain)
                  .id(idx)
                }
              }
              .padding(6)
            }
            .frame(maxHeight: 200)
            .onChange(of: session.selectedHistoryIndex) { _, newIdx in
              if let idx = newIdx {
                withAnimation(.easeOut(duration: 0.1)) {
                  proxy.scrollTo(idx, anchor: .center)
                }
              }
            }
          }
          
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
                .cornerRadius(5)
              Text("↓")
                .font(.system(size: 9))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.swRaised)
                .cornerRadius(5)
              Text("tab")
                .font(.system(size: 9))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.swRaised)
                .cornerRadius(5)
              Text("to navigate")
                .foregroundStyle(Color.swDim)
            }
            HStack(spacing: 3) {
              Text("esc")
                .font(.system(size: 9))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.swRaised)
                .cornerRadius(5)
              Text("to dismiss")
                .foregroundStyle(Color.swDim)
            }
            Spacer()
          }
          .font(.system(size: 10, design: .monospaced))
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
          RoundedRectangle(cornerRadius: 14)
            .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
        )
        .padding(.bottom, 8)
      }

      VStack(alignment: .leading, spacing: 0) {
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
        .padding(.top, 14)

        HStack(spacing: 10) {
          ZStack(alignment: .leading) {
            // Render inline ghost text completion using spaces padding
            if !commandText.isEmpty && !session.ghostText.isEmpty {
              Text(String(repeating: " ", count: commandText.count) + session.ghostText)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.swMuted.opacity(0.6))
                .allowsHitTesting(false)
            }

            AutocompleteTextField(
              text: $commandText,
              height: $inputHeight,
              placeholder: "Run a command...",
              currentDirectory: session.currentDirectory,
              isFocused: session.isFieldFocused,
              session: session,
              onSubmit: submit
            )
            .frame(height: inputHeight)
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
        .padding(.top, 10)
        .padding(.bottom, 6)

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
        .padding(.bottom, 14)
        .padding(.top, 8)
      }
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
      .overlay(
        RoundedRectangle(cornerRadius: 16)
          .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
      )
      .shadow(color: Color.black.opacity(0.4), radius: 15, x: 0, y: 8)
    }
    .onAppear {
      session.isFieldFocused = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        session.isFieldFocused = true
      }
    }
    .onChange(of: session.id) { _, _ in
      session.isFieldFocused = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        session.isFieldFocused = true
      }
    }
    .onChange(of: session.blocks.count) { _, _ in
      session.isFieldFocused = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        session.isFieldFocused = true
      }
    }
  }
}

struct SmallPromptChip: View {
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
    .background(Color.swRaised.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.swLine, lineWidth: 0.6)
    )
  }
}

struct PromptChip: View {
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
    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }
}
