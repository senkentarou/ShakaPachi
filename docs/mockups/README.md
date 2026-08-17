# Design mockups

Self-contained HTML pages used to settle visual decisions before writing Swift.
Open them directly in a browser — no build step, no assets, no network.

They are kept in the repo because the *rejected* options and the reasons for
rejecting them are the expensive part; the accepted option is already in the
code.

## Files

### `iridescent-01-finishes.html`

Explores an iridescent ("玉虫色" / thin-film interference) finish for the
switcher panel. Compares the two shipped finishes against three new candidates.

Outcome:

- **Whole-panel iridescence — rejected.** It reads well in isolation but drops
  legibility of the tiles and the window title, which is the panel's whole job.
- **Selected-tile rim only — accepted.** Same effect, none of the legibility
  cost, and it touches one drawing site instead of the panel's layer stack.

The fake desktop backdrop deliberately contains window-shaped rectangles. A flat
backdrop flatters `.behindWindow` blur and leads to the wrong call.

### `iridescent-02-rim-and-palettes.html`

Narrows to the rim, and settles animation and palette.

Outcome:

- **Slow continuous rotation — accepted** (over a static rim, and over
  advancing the angle only on selection change).
- **Pastel iridescent palette — accepted**, over the AI-brand-adjacent
  palettes also mocked there. Those are included for comparison only: they
  approximate other vendors' brand families and would invite the association.
- Rim thickness stays the existing 1px hairline.

### `app-grouping-01-layouts.html`

Compares four layouts for expanding the selected app's windows below the app-tile
row: a drawer of small tiles (A), an inline-expanding tile (B), a live-preview
strip reusing the existing preview panes (C), and a vertical dropdown of titles (D).

Outcome:

- **Layout C (live-preview strip) — accepted.** Panes carry both an icon and
  window content, so identification doesn't depend on rereading text.
- **A (drawer) / B (inline expand) — rejected.** Their small tiles carry no
  title, so identification falls entirely on rereading the one title line
  each time the selection moves. B also breaks `tileRect`'s pure-geometry
  property (tile position starts depending on the selected app's window
  count) and has the highest implementation cost of the four.
- **D (vertical dropdown) — rejected.** Best title legibility of the four,
  but `panelSize` would have to depend on a measured string width, breaking
  `SwitcherLayout`'s "size is a function of item count alone" property.

### `app-grouping-02-scaling.html`

Compares four strategies for shrinking the live-preview panes as the selected
app's window count grows: uniform shrink with no floor (S1), uniform shrink
with a 180px pane-width floor that stretches the panel instead (S2), a fixed
4-pane paging strip (S3), and a focus pane + variable-size filmstrip (S4).

Outcome:

- **None of S1/S3/S4 shipped as designed here.** The eventual spec (settled
  after 04, below) caps live display at 3 panes and never shrinks them below
  native 320×200, trading window count for legibility rather than the other
  way around.
- **S2 (180px floor + panel stretch) is this mock's real payoff — it doesn't
  work.** Honoring the 180px floor at N=8 needs a panel ~1550px wide — 118px
  past the 1432px width budget this series uses for a centered panel (screen
  width 1512px minus 40px margins on each side), and 38px past the 1512px
  screen itself. A pane-width floor can't be honored on its own at this
  screen size.

### `app-grouping-03-title-and-aspect.html`

With the pane count fixed at 3 (457×286 each), compares where a window's
title goes (T1-T4) and how the 16:10 preview frame handles non-16:10 windows
(R1-R3).

Outcome:

- **T4 (per-pane title below, dimmed unless selected) — accepted**, over T1
  (a single title line stops scaling once more than one pane is on screen)
  and T3 (an overlay band collides with bright window content — contrast
  breaks down over light-colored apps).
- **R2 (letterbox inside the fixed 16:10 frame, dark-plate fill) —
  accepted**, over R1 (cropping to a fixed frame loses most of a portrait
  window's content) and R3 (variable pane width tied to each window's real
  aspect ratio, which pulls `WindowInfo.bounds` into `SwitcherLayout` and
  breaks its pure-geometry property).

### `app-grouping-04-overflow.html`

On top of layout C / T4 / R2, compares three ways to fold in windows beyond
N=5: keep shrinking all panes uniformly (X1), a focus pane + variable
thumbnails (X2), and fixing the first 5 panes at 270×169 with the rest folded
into a single "+K" aggregate tile (X3).

Outcome:

- **X1 was this mock's own pick at the time** — lowest implementation cost,
  panel width never leaves the 1432px budget. X2 was rejected here because
  the moment the selection moves past window 5, all five ⌘1-⌘5 panes resize
  into thumbnails, so the badges stop pointing at a stable size.
- **X3 is the mock that produced the finding that actually decided the final
  design.** Five fixed 270×169 panes alone already consume ~1430px, right at
  the 1432px budget — there's no room left for even one "+K" tile without
  pushing the panel to ~1540px, and opening that tile drives it to
  ~1710-1820px, well past the 1512px screen itself. **This is the arithmetic
  that ruled out "keep 5 panes at a fixed size" and led directly to the final
  call: cap live display at 3 panes instead of 5**, which is small enough to
  leave headroom for overflow chips inside the same width budget.

### `app-grouping-05-final.html`

Not a comparison. A keyboard-operable prototype of the confirmed spec —
layout C, title T4, aspect R2, a 3-pane cap with `+n` overflow chips, and
⌘1-⌘3 badges that track the visible slice as it slides. This was the spec
reference used while implementing.

## Animation feasibility (the correction this mockup produced)

An early assumption that "a flowing gradient needs macOS 14+/15+" was wrong,
and it would have killed the feature.

Core Animation covers rotation, colour cycling, and drift on this deployment
target: `CAGradientLayer`'s `colors`, `locations`, `startPoint` and `endPoint`
are animatable, as is `CALayer.transform`. Animations run on the render server,
so the main thread does no per-frame work — the `N1 <= 50ms` budget covers
*first paint* and is unrelated to an animation running afterwards.

What genuinely requires a newer deployment target is only organic,
domain-warped noise veining (`MeshGradient` is macOS 15+, SwiftUI's
`.colorEffect` / `ShaderLibrary` are macOS 14+). The second mockup shows that
several layers drifting on different periods approximates it closely enough
that the distinction stops mattering at this size.
