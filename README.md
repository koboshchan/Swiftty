# Swiftty

Swiftty is a high-performance, native macOS terminal emulator built with SwiftUI, AppKit, and Metal. It replaces traditional continuous terminal surfaces with Warp-style command blocks, rich context awareness, and native macOS aesthetics.

> [!NOTE]
> Swiftty requires macOS 26.0 or later and the Swift 6.0 toolchain.

---

## Features

- **Warp-Style Command Blocks**: Powered by OSC 133 semantic shell integration for `zsh` and `bash`. Commands are rendered as distinct blocks with execution timing, working directory context, failure highlighting, output copying, and automatic output folding for long logs.
- **Metal-Accelerated Rendering**: Uses SwiftTerm with a custom Metal GPU rendering pipeline (`.perRowPersistent`) for low-latency text updates and zero CPU usage when idle.
- **Floating Command Composer**: Features a command input bar equipped with context chips displaying active shell type, current directory, and Git branch.
- **Transparent SSH & Remote Support**: Automatically detects SSH sessions and injects lightweight OSC 133 markers into remote subshells without requiring server-side agent installation.
- **Remote Directory & Path Autocomplete**: Serves current remote path updates (`OSC 7`) and directory autocompletion seamlessly across local and remote sessions.
- **AI Integrations**: Built-in provider support for OpenAI, Anthropic, OpenRouter, Ollama, LM Studio, and OpenAI-compatible local/remote models. API keys are securely managed via the macOS Keychain.
- **Native macOS Customizations**: Glassmorphism translucent windows, configurable background blur, customizable window opacity, and compact block display modes.

---

## Prerequisites

- **macOS**: macOS 26.0 or higher
- **Swift Toolchain**: Swift 6.0+

---

## Quick Start

### Build and Run

To compile and launch the native `.app` bundle:

```bash
# Clone the repository
git clone https://github.com/yuk1n0w/Swiftty.git
cd Swiftty

# Build the executable and assemble Swiftty.app
./scripts/build-app.sh
```

The script builds the project using `swift build --disable-sandbox`, packages `build/Swiftty.app`, copies required Metal shaders from the `SwiftTerm` resource bundle into `Contents/Resources`, re-signs the bundle, and launches the application.

> [!IMPORTANT]
> Swiftty runs unsandboxed by design in order to manage local interactive login shells, PTY sessions, and system processes without security-scoped bookmark restrictions.

---

## Key Shortcuts

| Shortcut | Description |
| --- | --- |
| `⌘T` | Open a new terminal tab |
| `⌘W` | Close current terminal tab |
| `⌘↑` / `⌘↓` | Navigate between command blocks |
| `⌘⇧C` | Copy selected command block output |
| `⌘K` | Clear block history |
| `⇧⌘E` | Manually trigger remote OSC 133 shell integration |

---

## Architecture & Shell Integration

Swiftty uses semantic prompt markers to demarcate command boundaries:

```
[OSC 133;A (Prompt)] -> [OSC 133;C (Pre-Execution)] -> [OSC 133;D (Execution Finish & Exit Code)]
```

- **Shell Bootstrapping**: `ShellIntegration` automatically injects a per-tab shell initialization layer via `ZDOTDIR` (for `zsh`) or `--rcfile` (for `bash`). Existing shell configurations, custom prompts, and aliases remain untouched.
- **Remote Adoption**: When an interactive SSH session is detected, Swiftty automatically transmits shell hook definitions into the session once a shell prompt is stabilized.
- **Alternate Screen Handling**: Full-screen terminal programs (e.g., `vim`, `htop`, `tmux`) switch to the alternate terminal buffer automatically, temporarily hiding block boundaries until exiting.

---

## Configuration

Access Swiftty Settings (`⌘,`) to configure:

- **General**: Window opacity, background blur effects, and compact block spacing mode.
- **Terminal**: Cursor blink behavior, font sizing, and scrollback settings.
- **Models & AI**: Select AI providers (OpenAI, Anthropic, Ollama, LM Studio), set custom API base URLs, and store API keys securely in the macOS Keychain.
