# ShakaPachi

A fast, thumbnail-free window switcher for macOS.

macOS's built-in Cmd+Tab switches between *applications*. ShakaPachi replaces it
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

Builds the SPM executable, assembles `ShakaPachi.app`, codesigns it, and launches it.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for a full system overview, component map, and sequence/state diagrams. New to the codebase? Start with its "Start here — reading order" section.

## License

ShakaPachi is free software licensed under the **GNU General Public License v3.0**
(GPL-3.0). You are free to use, study, share, and modify it under those terms;
any distributed derivative work must also be released under the GPL. See
[LICENSE](LICENSE) for the full text.

Copyright (C) 2026 Masahiro Senda
