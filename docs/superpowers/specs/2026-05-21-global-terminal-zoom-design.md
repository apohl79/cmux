# Global Terminal Zoom — Design

Status: implemented
Branch: `feat/global-terminal-zoom`
Date: 2026-05-21

## Goal

A single zoom level that applies to **every terminal pane in every workspace
simultaneously**, controlled by dedicated keybindings and persisted across
restarts.

## Why now

Per-surface font sizing already exists in Ghostty (`set_font_size`,
`increase_font_size`, `decrease_font_size`, `reset_font_size` binding actions),
and cmux already preserves font size when a surface is inherited
(`Sources/GhosttyTerminalView.swift`). However there is no app-level shortcut
that adjusts all terminals at once — users today would have to navigate to each
terminal and adjust it individually.

## Scope

- Affects: every live `TerminalSurface` registered in
  `TerminalSurfaceRegistry.shared`, regardless of workspace.
- Does **not** affect: browser panes (the existing `browserZoom*` shortcuts
  cover them and are scoped to the focused browser), file preview panels,
  sidebar font sizes, or chrome.
- Persists across app restarts via `UserDefaults` under the key
  `cmux.globalTerminalZoomDelta`.

## Model

- One scalar `delta: Double` in points, persisted via `UserDefaults`.
- Target font size = `GhosttyConfig.fontSize + delta`, clamped to
  `[4.0, 72.0]` points.
- Step = 1.0 point per shortcut invocation (matches Ghostty's default
  `increase_font_size:1` / `decrease_font_size:1` bindings).
- Reset returns `delta` to `0.0` and re-applies the base size.

## Components

| File | Purpose |
|------|---------|
| `Sources/GlobalTerminalZoom.swift` | New `GlobalTerminalZoomController` singleton, `@MainActor`. Owns the persisted delta, broadcasts via `TerminalSurfaceRegistry.shared.allSurfaces()`, observes `.terminalSurfaceDidBecomeReady` to apply zoom to newly-created surfaces. |
| `Sources/KeyboardShortcutSettings.swift` | New `Action` cases `globalTerminalZoomIn`, `globalTerminalZoomOut`, `globalTerminalZoomReset` with default shortcuts `⌥⌘=`, `⌥⌘-`, `⌥⌘0` and Settings-visible labels. |
| `Sources/AppDelegate.swift` | Dispatch in `handleCustomShortcut`; calls `GlobalTerminalZoomController.shared.zoomIn/Out/Reset()`. `applicationDidFinishLaunching` invokes `start()` so the new-surface observer is installed once. |
| `Sources/TerminalController.swift` | New v1 socket commands `global_zoom_in`, `global_zoom_out`, `global_zoom_reset`, `global_zoom_status` for autonomous testing and external automation. |
| `Resources/Localizable.xcstrings` | Localized labels (en/ja). |
| `web/data/cmux.schema.json` | New shortcut IDs added to the `cmux.json` enum. |
| `web/data/cmux-shortcuts.ts` | New entries in the user-facing shortcut catalog. |
| `cmuxTests/GlobalTerminalZoomTests.swift` | Unit tests for the controller (delta math, clamping, persistence, notification, default shortcut shape). |

## Broadcast mechanics

Existing infrastructure does most of the work:

- `TerminalSurfaceRegistry.shared.allSurfaces()` returns every live terminal
  surface across every workspace and every window.
- `TerminalSurface.performBindingAction("set_font_size:N")` issues the same
  Ghostty action the existing inheritance code uses
  (`Sources/GhosttyTerminalView.swift:5421`).
- `.terminalSurfaceDidBecomeReady` is posted by every surface as soon as its
  runtime is created; the controller listens for it and applies the current
  delta so new splits, new workspaces, and new windows inherit the zoom.

## Keybindings

Defaults:

| Shortcut | Action |
|---|---|
| `⌥⌘=` | Zoom in all terminals |
| `⌥⌘-` | Zoom out all terminals |
| `⌥⌘0` | Reset terminal zoom |

`⌥` (Option) is intentionally part of the modifier set so the new shortcuts do
not clash with the existing browser-scoped `⌘=/⌘-/⌘0`. All three actions are in
the `.application` shortcut context, so they fire regardless of whether a
browser, terminal, or sidebar pane is focused.

Per project shortcut policy:

- They are added to `KeyboardShortcutSettings.Action` and are therefore
  visible and editable in Settings.
- They are added to `cmux.json` schema enum, so users can override via
  `~/.config/cmux/cmux.json`.
- They are added to `cmux-shortcuts.ts`, the user-facing shortcut catalog
  rendered in the docs and command palette.

## Persistence

The delta is persisted in `UserDefaults.standard` under
`cmux.globalTerminalZoomDelta`. On controller init the value is read; on every
mutation the value is written and a `didChangeNotification` is posted (useful
for tests and any future UI that wants to mirror the current zoom state).

## Testability (autonomous)

Two layers:

1. **`cmuxTests/GlobalTerminalZoomTests.swift`** — pure unit tests that exercise
   delta math, clamping, persistence, change notification, and default shortcut
   shape. These run as part of the `cmux-unit` scheme on CI (already wired in
   `.github/workflows/ci.yml`), so they are fully autonomous.
2. **v1 socket commands** (`global_zoom_in`, `global_zoom_out`,
   `global_zoom_reset`, `global_zoom_status`) — enable end-to-end verification
   from `tests_v2/*.py` or any external automation against a running cmux. The
   `_status` command returns a JSON payload with per-surface font sizes so a
   test can confirm every surface converged to the same target font size.

## Risks / non-goals

- The controller does not currently expose a menu item under View; the
  shortcuts are discoverable via Settings and the documented shortcut catalog.
  Adding a menu item is a trivial follow-up if desired.
- Per-surface zoom (Ghostty's built-in `cmd+=`/`cmd+-` bindings inside a single
  terminal) is unchanged. The global controller overrides them only when the
  user triggers the new global shortcuts, otherwise per-surface adjustments
  remain possible.
- Browser zoom is intentionally untouched.
