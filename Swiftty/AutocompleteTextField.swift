import AppKit
import SwiftUI

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
  @Binding var height: CGFloat
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
    
    // Configure cell wrapping and disable single line mode
    textField.cell?.isScrollable = false
    textField.cell?.wraps = true
    textField.maximumNumberOfLines = 0
    
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
    
    nsView.placeholderString = text.isEmpty ? placeholder : ""
    
    context.coordinator.adjustHeight(for: nsView)
    
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
        textField.placeholderString = textField.stringValue.isEmpty ? parent.placeholder : ""
        parent.session.originalAutocompleteText = nil
        parent.session.selectedSuggestionIndex = nil
        parent.session.autocompleteTabCount = 0
        parent.session.isAutocompleteOpen = false

        if let textView = textField.currentEditor() as? NSTextView {
          let savedRange = textView.selectedRange()
          let highlighted = highlight(textField.stringValue)
          textView.textStorage?.setAttributedString(highlighted)
          let maxLen = highlighted.length
          let clampedLocation = min(savedRange.location, maxLen)
          let clampedLength = min(savedRange.length, maxLen - clampedLocation)
          textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
        } else {
          textField.attributedStringValue = highlight(textField.stringValue)
        }

        adjustHeight(for: textField)

        updateSuggestions(text: textField.stringValue)

        if parent.session.isHistoryOpen {
          parent.session.openHistory(filter: textField.stringValue)
        }
      }
    }

    func adjustHeight(for textField: NSTextField) {
      let width = textField.frame.width > 0 ? textField.frame.width : 500
      let attributedString = textField.attributedStringValue
      let size = attributedString.boundingRect(
        with: CGSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
      ).size
      let newHeight = max(22, ceil(size.height) + 4)
      if parent.height != newHeight {
        DispatchQueue.main.async {
          self.parent.height = newHeight
        }
      }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      let session = parent.session
      guard let textField = control as? AutocompleteNSTextField else { return false }

      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) || flags.contains(.option) {
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
         commandSelector == #selector(NSResponder.insertBacktab(_:)) ||
         commandSelector == #selector(NSResponder.insertTabIgnoringFieldEditor(_:)) {
        let isShift = NSEvent.modifierFlags.contains(.shift)
        if session.isHistoryOpen {
          navigateHistory(isForward: isShift)
        } else {
          handleTabOrNavigation(textField: textField, isForward: !isShift)
        }
        return true
      }

      if commandSelector == #selector(NSResponder.moveDown(_:)) {
        if session.isHistoryOpen {
          navigateHistory(isForward: false)
          return true
        } else if session.isAutocompleteOpen {
          handleTabOrNavigation(textField: textField, isForward: true)
          return true
        }
      }

      if commandSelector == #selector(NSResponder.moveUp(_:)) {
        if session.isHistoryOpen {
          navigateHistory(isForward: true)
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
          session.originalAutocompleteText = nil
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
          session.originalAutocompleteText = textField.stringValue
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
      let baseText = session.originalAutocompleteText ?? parent.text
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
      session.originalAutocompleteText = nil
    }

    private static var commandCache: [String] = []
    private static var isCommandCacheLoading = false

    @discardableResult
    static func loadSystemCommands() -> [String] {
      if !commandCache.isEmpty {
        return commandCache
      }
      if !isCommandCacheLoading {
        isCommandCacheLoading = true
        Task.detached(priority: .background) {
          let fileManager = FileManager.default
          let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
          var paths = pathEnv.components(separatedBy: ":")
          
          let extraPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/go/bin"
          ]
          for ep in extraPaths {
            if !paths.contains(ep) {
              paths.append(ep)
            }
          }

          var commands = Set<String>()
          for path in paths {
            let dirURL = URL(fileURLWithPath: path)
            do {
              let contents = try fileManager.contentsOfDirectory(atPath: dirURL.path)
              for item in contents {
                let fullPath = dirURL.appendingPathComponent(item).path
                if fileManager.isExecutableFile(atPath: fullPath) {
                  commands.insert(item)
                }
              }
            } catch {
              // Ignore
            }
          }
          let sortedCommands = Array(commands).sorted()
          await MainActor.run {
            commandCache = sortedCommands
            isCommandCacheLoading = false
          }
        }
      }
      return []
    }

    private func isCommandPosition(text: String) -> Bool {
      let components = text.components(separatedBy: " ")
      guard components.count > 0 else { return true }
      if components.count == 1 {
        return true
      }
      let secondToLast = components[components.count - 2]
      if secondToLast == "|" || secondToLast == "&&" || secondToLast == "||" || secondToLast == ";" {
        return true
      }
      return false
    }

    private func updateSuggestions(text: String) {
      let session = parent.session
      let components = text.components(separatedBy: " ")
      guard let last = components.last, !last.isEmpty else {
        session.autocompleteSuggestions = []
        session.ghostText = ""
        return
      }

      // If we are in a command position, try command completion
      if isCommandPosition(text: text) && !last.contains("/") && !last.hasPrefix(".") && !last.hasPrefix("~") {
        let systemCommands = Self.loadSystemCommands()
        let matches = systemCommands.filter {
          $0.lowercased().hasPrefix(last.lowercased())
        }.sorted()

        if !matches.isEmpty {
          session.autocompleteSuggestions = matches
          var common = matches[0]
          for m in matches.dropFirst() {
            while !m.lowercased().hasPrefix(common.lowercased()) {
              common = String(common.dropLast())
            }
          }
          if common.count >= last.count {
            let remainder = String(common.dropFirst(last.count))
            session.ghostText = remainder + (matches.count == 1 ? " " : "")
          } else {
            session.ghostText = ""
          }
          return
        }
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
      let currentText = textField.stringValue
      let components = currentText.components(separatedBy: " ")
      guard let last = components.last, !last.isEmpty else { return }

      // If we are in a command position, try command completion
      if isCommandPosition(text: currentText) && !last.contains("/") && !last.hasPrefix(".") && !last.hasPrefix("~") {
        let systemCommands = Self.loadSystemCommands()
        let matches = systemCommands.filter {
          $0.lowercased().hasPrefix(last.lowercased())
        }.sorted()

        if !matches.isEmpty {
          // Find LCP
          var common = matches[0]
          for m in matches.dropFirst() {
            while !m.lowercased().hasPrefix(common.lowercased()) {
              common = String(common.dropLast())
            }
          }

          let suffix = matches.count == 1 ? " " : ""
          var newComponents = components
          newComponents[newComponents.count - 1] = common + suffix

          let newText = newComponents.joined(separator: " ")
          parent.text = newText
          textField.stringValue = newText

          if let editor = textField.currentEditor() {
            textField.attributedStringValue = highlight(newText)
            editor.selectedRange = NSRange(location: newText.count, length: 0)
          }

          updateSuggestions(text: newText)
          return
        }
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

        newComponents[newComponents.count - 1] = completedToken
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
