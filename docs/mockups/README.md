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
