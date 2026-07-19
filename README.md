# CmdTab

A fast, thumbnail-free window switcher for macOS.

macOS's built-in Cmd+Tab switches between *applications*. CmdTab replaces it
with *window*-level switching: hold the trigger modifier, cycle through a plain
text list of app icons and window titles, release to activate. No thumbnails,
no previews — response speed comes first.

## Features

- Window-level switching (multiple windows of the same app are listed individually)
- App icon + window title only — no thumbnail generation
- MRU (most recently used) ordering
- Menu bar resident, no Dock icon
- Emergency stop hotkey (Ctrl+Option+Cmd+Esc)

## Requirements

- macOS 13 Ventura or later
- Accessibility permission (event tap, window raising)
- Screen Recording permission (window titles)

## Build

```
make run
```

Builds the SPM executable, assembles `CmdTab.app`, codesigns it, and launches it.

## License

GPL-3.0. See [LICENSE](LICENSE).
