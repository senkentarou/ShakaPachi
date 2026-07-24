# Media capture guide

Shot list for the three README media assets. These three were chosen as the
slow-to-obsolete core of the app (the switching interaction, per-window listing,
and menu-bar residency). Avoid featuring themes, accent colors, stats, or the
Settings UI here — those churn between releases and would date the README.

Capture on a Retina display, crop tightly to the switcher panel (or the menu),
and keep the desktop background neutral so the panel stays the focus.

## 1. `demo.gif` — hero interaction

- **Shows:** the full switch cycle — hold the trigger modifier, cycle through the
  window list, release to activate the highlighted window.
- **Setup:** open several windows across a few apps so the list has enough rows
  to make the cycling visible. Leave Screen Recording permission granted so the
  live preview of the selected window is visible below the title line.
- **Framing:** center the switcher panel; include enough of one preview to show
  it updating as the selection moves. Keep it short (a few seconds), loop-clean.

## 2. `switcher-list.png` — per-window listing

- **Shows:** the switcher list with **multiple windows of the same app listed
  individually** — the thing Cmd+Tab cannot do.
- **Setup:** open two (or more) windows of the same app (e.g. two Finder windows
  or two browser windows with different titles) so the duplicate-app rows are
  obvious. Give the windows distinct titles.
- **Framing:** still frame of the panel with those same-app rows clearly visible;
  the app icon + window title per row should be legible.

## 3. `menu-bar.png` — menu-bar residency

- **Shows:** the menu bar icon and its open dropdown menu (menu-bar resident, no
  Dock icon; enable/disable and emergency stop reachable from the menu).
- **Setup:** click the menu bar icon so the dropdown is open.
- **Framing:** crop to the top-right menu bar area including the icon and the
  open menu; the menu items should be readable.
