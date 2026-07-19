import AppKit
import ObjectiveC
import SwiftTerm
import SwiftUI

final class SwifttyTerminalView: LocalProcessTerminalView {
  var onClick: (() -> Void)?

  /// Computes the cell height from the terminal font metrics so the host
  /// can build accurate content-based frame sizes.
  var cellHeight: CGFloat {
    let f = font as CTFont
    let h = ceil((CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)) * lineSpacing)
    return max(h, 1)
  }

  override init(frame frameRect: NSRect) {
    _ = TerminalView.swizzleScrollWheel
    super.init(frame: frameRect)
  }

  required init?(coder: NSCoder) {
    _ = TerminalView.swizzleScrollWheel
    super.init(coder: coder)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.window else { return }
      window.makeFirstResponder(self)
    }
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    onClick?()
    super.mouseDown(with: event)
  }
}

extension TerminalView {
  static let swizzleScrollWheel: Void = {
    let originalSelector = #selector(scrollWheel(with:))
    let swizzledSelector = #selector(swizzled_scrollWheel(with:))

    guard let originalMethod = class_getInstanceMethod(TerminalView.self, originalSelector),
      let swizzledMethod = class_getInstanceMethod(TerminalView.self, swizzledSelector)
    else {
      return
    }

    method_exchangeImplementations(originalMethod, swizzledMethod)
  }()

  @objc func swizzled_scrollWheel(with event: NSEvent) {
    if let next = nextResponder {
      next.scrollWheel(with: event)
    } else {
      swizzled_scrollWheel(with: event)
    }
  }
}

@MainActor
final class TerminalHandle {
  weak var view: SwifttyTerminalView?

  func send(_ text: String) {
    guard let view else { return }
    let bytes = Array(text.utf8)
    view.process.send(data: bytes[...])
    view.window?.makeFirstResponder(view)
  }

  func focus() {
    guard let view else { return }
    view.window?.makeFirstResponder(view)
  }
}

class FlippedContainerView: NSView {
  override var isFlipped: Bool { true }
}

struct TerminalSurface: NSViewRepresentable {
  typealias NSViewType = NSView

  let currentDirectory: String
  let command: String?
  let handle: TerminalHandle
  let onClick: (() -> Void)?
  let onExit: ((Int32?) -> Void)?

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
    var parent: TerminalSurface

    init(_ parent: TerminalSurface) {
      self.parent = parent
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
      source.feed(text: "\u{001b}[?25l")
      DispatchQueue.main.async {
        self.parent.onExit?(exitCode)
      }
    }
  }

  func makeNSView(context: Context) -> NSView {
    let container = FlippedContainerView(frame: .zero)
    let view = SwifttyTerminalView(frame: .zero)
    view.onClick = onClick
    handle.view = view
    view.font = NSFont.monospacedSystemFont(ofSize: 12.0, weight: .regular)
    view.lineSpacing = 1.02
    view.nativeBackgroundColor = NSColor(calibratedRed: 0.031, green: 0.043, blue: 0.047, alpha: 1)
    view.nativeForegroundColor = NSColor(calibratedRed: 0.82, green: 0.89, blue: 0.89, alpha: 1)
    view.backspaceSendsControlH = false
    view.processDelegate = context.coordinator

    container.addSubview(view)

    let args: [String]
    if let command = command {
      args = ["-l", "-c", command]
    } else {
      args = ["-l"]
    }

    view.startProcess(
      executable: "/bin/zsh",
      args: args,
      currentDirectory: currentDirectory
    )
    return container
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let terminalView = nsView.subviews.first as? SwifttyTerminalView else { return }
    let ch = terminalView.cellHeight
    let minHeight = 24 * ch
    let targetHeight = max(minHeight, nsView.bounds.height)
    terminalView.frame = NSRect(
      x: 0,
      y: 0,
      width: nsView.bounds.width,
      height: targetHeight
    )
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    if let terminalView = nsView.subviews.first as? SwifttyTerminalView {
      terminalView.terminate()
    }
  }
}
