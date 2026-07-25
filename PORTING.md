# Native terminal port

Swiftty is the native macOS replacement for the terminal surface currently in `terax-ai`.

## Current slice

- SwiftUI window and native AppKit terminal view
- SwiftTerm VT100/xterm engine with CoreText and Metal rendering
- Real Unix PTY-backed login shell
- Persistent terminal tabs with Cmd-T, Cmd-W, and native window controls
- OSC 7 working-directory updates and terminal title updates
- Process exit reporting
- Native text selection, clipboard, mouse reporting, hyperlinks, search, and ANSI color handling through SwiftTerm
- Warp-style command blocks driven by OSC 133 shell integration

## Port map

| Terax subsystem | Native replacement | State |
| --- | --- | --- |
| `TerminalStack` and tab visibility | `TerminalWorkspace` and `TerminalStore` | Started |
| `xterm.js` renderer | SwiftTerm AppKit renderer with Metal | Started |
| `portable-pty` session | `LocalProcessTerminalView` | Started |
| OSC 7 cwd tracking | `LocalProcessTerminalViewDelegate` | Started |
| `PaneTreeView` splits | `HSplitView` / `VSplitView` session tree | Next |
| shell integration scripts and OSC 133 | `ShellIntegration` zsh/bash bootstrapper | Done |
| command blocks and history | `BlockTracker` over the SwiftTerm buffer | Done |
| renderer pool and dormant ring | bounded native session registry | Next |
| agent signals and background jobs | native process services | Later |

## Build and run

```bash
swift build --disable-sandbox
./scripts/build-app.sh
open build/Swiftty.app
```

The app is deliberately unsandboxed while it owns local shells. A sandboxed target would need explicit security-scoped access and would not behave like the current terminal.

## Command blocks

The terminal surface is a stack of blocks, one per command, in the style of
Warp v1: a muted meta line (`~/Projects/Swiftty git:(main) (0.21s)`), the command
in bold beneath it, then its output. Blocks run the full width and are separated
by hairline rules. Only failures are tinted — a red wash plus a red bar down the
left edge — so a bad command is obvious while scrolling. Hovering reveals a `⋮`
menu; long output collapses to 24 lines behind a "show all" control. The live
command composer sits at the bottom: a floating card with context chips for the
shell, directory and branch, a real text editor for the command, and a hint row
for what Return does.

`⌘↑`/`⌘↓` step between blocks, `⌘⇧C` copies the selected block's output, and
`⌘K` — or running `clear` — wipes the history. `clear` is special-cased: the
terminal buffer it would normally wipe only holds the command in progress, so
against a screen made of frozen blocks the only useful reading of it is "clear
the history". Settings → General carries the appearance controls: window opacity, background blur, and a compact
mode that tightens the spacing between blocks.

Translucency needs three separate layers to opt out of being opaque — the
window, the terminal view's layer, and the `MTKView` SwiftTerm renders into —
plus an alpha on `nativeBackgroundColor`, which the Metal renderer reads
directly as its clear color. The `MTKView` only exists after `setUseMetal`, and
SwiftTerm rebuilds it whenever the window changes, so `applyBackground` runs
after Metal is enabled and again on every view update.

Boundaries come from OSC 133 semantic prompt markers, the same protocol iTerm2,
VS Code and Ghostty use. `ShellIntegration` writes a per-tab rc file that layers
hooks on top of the user's own shell config — for zsh via `ZDOTDIR`, for bash via
`--rcfile`. It never replaces the prompt or disables the line editor, so prompt
themes, completion, history and full-screen programs behave exactly as they do
in any other terminal. Shells other than zsh and bash run uninstrumented: the
terminal works, there are simply no blocks.

## Remote sessions

Blocks keep working over SSH and inside containers, without installing anything
on the far end. The remote shell config prints one line — a `133;S` marker
naming its shell — and Swiftty answers by typing the hook definitions into the
session that is already open. The remote shell then emits the same markers the
local one does, so its commands become blocks. Settings → General has the
snippet to copy.

Most hosts have no such line, so an interactive `ssh` is also detected
directly: Swiftty waits for the output to go quiet on something that looks like
a shell prompt, then types the hooks in. It checks for a prompt rather than a
question specifically so it can never type into a password or passphrase
prompt, and it ignores `ssh host -- command`, which never presents one. `⇧⌘E`
does it by hand for anything the watcher misses.

The command that opened the subshell (`ssh host`) never returns to a local
prompt, so adoption also closes out its block; otherwise it would sit "running"
for the whole session and keep the composer off screen.

Tab completion and the file explorer follow the session onto the remote host.
The bootstrap carries an `__swiftty_ls` helper that reports a directory as an
`L` marker; the far end's `precmd` calls it for `$PWD` on every prompt, so the
explorer always has the current directory without asking. Completion of other
paths asks on demand, and a lost query (sent before `__swiftty_ls` was defined
on a slow link) times out so a later request retries rather than the path
staying stuck. These queries are filtered out of the block stream by the same
preexec guard, so they never appear as commands. Command-name completion is
suppressed while remote, since the local `PATH` says nothing about what is
installed there. Tilde-relative completion (`~/…`) still resolves against the
local home and is a known gap.

`BlockTracker` captures a block's output as styled text when the command
finishes, then clears the terminal buffer at the *next* prompt marker rather
than at the finish marker — clearing at the finish would wipe the fresh prompt
the shell is about to draw. Each block therefore owns its text outright, and the
live terminal only ever holds the command in progress. A full-screen program
taking over the alternate screen hands it the whole view until it exits.

## Performance

Metal rendering runs in `.perRowPersistent` mode: only rows that changed are
rebuilt each frame, which is the cheaper mode for interactive use (typing,
scrolling output) where a handful of rows are dirty per frame. The MTKView is
on-demand (`isPaused`, `enableSetNeedsDisplay`), so an idle prompt uses no CPU.

The per-repaint path is kept minimal: the transparency heal is a single identity
check against the last-fixed Metal view rather than a subview scan, and the
command editor re-measures its height only when the font actually changes, not on
every SwiftUI update. A steady cursor (Settings → Terminal) stops the caret
redrawing twice a second, which otherwise wakes the GPU even at idle.
