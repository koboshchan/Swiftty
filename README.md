# Swiftty

[![Version](https://img.shields.io/badge/version-0.1.0-blue.svg)](Info.plist)
[![Platform](https://img.shields.io/badge/platform-macOS%2026.0%2B-black.svg)](Package.swift)
[![Swift](https://img.shields.io/badge/swift-6.0-orange.svg)](Package.swift)

Swiftty is a high-performance, native macOS terminal emulator built with SwiftUI, AppKit, and Metal. Designed as a modern replacement for traditional continuous scrollback terminals, Swiftty structures shell execution into Warp-style command blocks with rich context awareness, low-latency GPU rendering, and native AI capabilities.

> [!NOTE]
> Swiftty requires macOS 26.0 or later and the Swift 6.0 toolchain.

---

## Features

- **Warp-Style Command Blocks**: Uses OSC 133 semantic prompt markers to group shell output into distinct blocks complete with execution timing, working directory context, failure highlighting, output copying, and automatic folding for logs over 24 lines.
- **Metal GPU Acceleration**: Powered by SwiftTerm with a custom Metal rendering pipeline (`.perRowPersistent`) for instant row updates and zero CPU utilization when idle.
- **Floating Command Composer**: An interactive bottom input card displaying live context chips for active shell type, working directory, and Git branch.
- **Transparent SSH & Remote Integration**: Detects interactive SSH sessions and injects lightweight OSC 133 prompt markers into remote subshells automatically—no remote daemon installation needed.
- **Remote Path & Autocomplete Tracking**: Transmits current remote path updates (`OSC 7`) and supports remote directory autocompletion seamlessly.
- **AI Integrations**: Native configuration for OpenAI, Anthropic, OpenRouter, Ollama, LM Studio, and OpenAI-compatible local/remote models with secure macOS Keychain storage.
- **Native macOS Customizations**: Glassmorphism window translucency, configurable background blur, window opacity, and compact block display modes.

---

## Prerequisites

- **Operating System**: macOS 26.0 or higher
- **Developer Toolchain**: Swift 6.0+ (Xcode 16+ or command line tools)

---

## Quick Start

### Build and Package

To build the executable and assemble the native `.app` bundle:

```bash
# Clone the repository
git clone https://github.com/yuk1n0w/Swiftty.git
cd Swiftty

# Compile and launch Swiftty.app
./scripts/build-app.sh
```

The script compiles the target via `swift build --disable-sandbox`, packages `build/Swiftty.app`, copies Metal shaders from the `SwiftTerm` resource bundle into `Contents/Resources`, re-signs the application, and launches Swiftty.

> [!IMPORTANT]
> Swiftty executes unsandboxed by design to manage local login shells, Unix PTY descriptors, and system processes without security-scoped sandbox restrictions.

---

## Key Shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘T` | Open a new terminal tab |
| `⌘W` | Close current terminal tab |
| `⌘↑` / `⌘↓` | Navigate between command blocks |
| `⌘⇧C` | Copy selected command block output |
| `⌘K` | Clear block history |
| `⇧⌘E` | Manually inject remote OSC 133 shell hooks |

---

## Architecture & Shell Integration

Swiftty relies on semantic prompt markers to delimit command execution boundaries:

```
[OSC 133;A (Prompt)] ➔ [OSC 133;C (Pre-Execution)] ➔ [OSC 133;D (Execution Finish & Exit Code)]
```

- **Local Bootstrapping**: `ShellIntegration` configures environment hooks for `zsh` (via `ZDOTDIR`) and `bash` (via `--rcfile`) without altering your existing shell theme, completion scripts, or prompt configuration.
- **Remote Adoption**: When an interactive `ssh` command is identified, Swiftty waits for shell prompt stabilization and injects standard prompt hooks into the remote session.
- **Alternate Screen Buffer**: Full-screen terminal programs (e.g., `vim`, `htop`, `tmux`) temporarily bypass block formatting while active and restore block mode upon exit.

---

## Configuration

Open Settings (`⌘,`) to customize:

- **General**: Window opacity, background blur effects, and compact block spacing mode.
- **Terminal**: Cursor style, font size, and scrollback configuration.
- **Models & AI**: Select AI providers (OpenAI, Anthropic, Ollama, LM Studio), set API base URLs, and store API keys securely in the macOS Keychain.
