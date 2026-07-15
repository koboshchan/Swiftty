import AppKit
import SwiftTerm
import SwiftUI

final class SwifttyTerminalView: LocalProcessTerminalView {
    private var configuredMetal = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard window != nil, !configuredMetal else { return }
        configuredMetal = (try? setUseMetal(true)) != nil
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
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

struct TerminalSurface: NSViewRepresentable {
    let currentDirectory: String
    let command: String?
    let handle: TerminalHandle
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
            DispatchQueue.main.async {
                self.parent.onExit?(exitCode)
            }
        }
    }

    func makeNSView(context: Context) -> SwifttyTerminalView {
        let view = SwifttyTerminalView(frame: .zero)
        handle.view = view
        view.font = NSFont.monospacedSystemFont(ofSize: 12.0, weight: .regular)
        view.lineSpacing = 1.02
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.031, green: 0.043, blue: 0.047, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedRed: 0.82, green: 0.89, blue: 0.89, alpha: 1)
        view.backspaceSendsControlH = false
        view.processDelegate = context.coordinator
        
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
        return view
    }

    func updateNSView(_ nsView: SwifttyTerminalView, context: Context) { }

    static func dismantleNSView(_ nsView: SwifttyTerminalView, coordinator: Coordinator) {
        nsView.terminate()
    }
}
