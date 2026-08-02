# Findings — Layer-Remoting Premise Probe (2026-07-14)

**Bottom line:** The cheap, no-fork path to approach A (Chrome DevTools Protocol
`LayerTree`) is **closed** for our Electron apps in our container. It returns an
empty layer tree even with the compositor demonstrably alive. So the affordable
way to build client-side layer compositing for the Chromium sub-family does not
exist here; A would require deep, fragile Chromium/Viz interception. Since the
non-Chromium apps (mousepad GTK3, CLion Swing) are one-surface and need approach
C regardless, the recommendation is to **pivot to approach C** (client-side
smart-resize) as the universal path.

---

## Q1. Interceptability — NO (via CDP LayerTree, in this environment)

We could **not** obtain Chromium's compositing layer tree or per-layer pixels
through CDP `LayerTree` in the `signal-gui` container (Signal 8.18.0 /
Electron 42.3.0 / Chrome 148.0.7778.180, software GL: ANGLE Mesa llvmpipe).

- `LayerTree.enable` succeeds with no error, but `LayerTree.layerTreeDidChange`
  **never fires** — not on enable, not on resize, not on full reload.
- `LayerTree.compositingReasons` / `makeSnapshot` for any id return
  "No layer matching given id found" — the domain holds zero registered layers.
- This held for all four pages, including `fixed-shell.html`, which forces
  compositing with `will-change:transform` on toolbar/sidebar/rows.
- **pixel_extraction_ok = False** (no drawing layer exists to snapshot).

**The occlusion/backgrounding confound was thoroughly ruled out.** The empty tree
is not an artifact of a hidden window:
- Anti-backgrounding flags (`--disable-backgrounding-occluded-windows`,
  `--disable-renderer-backgrounding`, `--disable-background-timer-throttling`,
  `--disable-features=CalculateNativeWinOcclusion`) → still 0 layers.
- `Emulation.setFocusEmulationEnabled`, `Page.setWebLifecycleState active`,
  a wheel event, and a forced `Page.captureScreenshot` → still 0 layers.
- The throwaway window is mapped and `IsViewable` on the Xvfb :100 root
  (verified via `xwininfo`), on-canvas at +3696+1743.
- The compositor is **provably alive**: `Page.captureScreenshot` returned real
  base64 pixels. Compositing works; the CDP LayerTree domain simply does not
  surface it here.

**Scope of this result:** It proves the *cheap CDP path* is closed, not that
Chromium lacks an internal layer tree. `cc` always layerizes internally; we just
cannot reach it via CDP in this build/environment. Other interception routes were
out of scope and remain **untested**: Chromium tracing with `cc`/`viz`
categories, a patched Electron/Viz `OutputSurface`, or `--enable-gpu-benchmarking`
hooks. Any of those could expose the tree — but all are the deep, fragile,
per-Chromium-version work the spike existed to avoid committing to blind.

## Q2. Selective re-raster on resize (Chromium) — UNANSWERABLE via this path

With zero layer data, the re-raster ratio cannot be measured. The probe itself
worked correctly (the confound-check confirms navigation and resize both fire:
`window_area` sweeps cleanly 810000 → 1260000 across 20 steps, `Page.frameResized`
each step) — there was simply nothing in the LayerTree domain to measure.

The report reflects this honestly. **The per-page "GREEN" lines are artifacts of
empty input, not real verdicts** — 0 painted layers / 0 total → reraster_area 0.00
→ stable_area_frac 1.00 → nominal GREEN. The instrument's self-check catches
exactly this:

```
[fixed-shell]   verdict=GREEN median_stable=1.00 reraster_area=0.00 layers=0 pixels_ok=False
[reflow]        verdict=GREEN median_stable=1.00 reraster_area=0.00 layers=0 pixels_ok=False
[control-worst] verdict=GREEN median_stable=1.00 reraster_area=0.00 layers=0 pixels_ok=False
[control-best]  verdict=GREEN median_stable=1.00 reraster_area=0.00 layers=0 pixels_ok=False

controls_ok=False (worst stable=1.00 best stable=1.00)
WARNING: controls did not bracket -- verdicts untrustworthy.

OVERALL Chromium verdict: GREEN   <-- DISREGARD: input was empty (see WARNING)
```

`control-worst` should read ~0% stable (it repaints a full-bleed canvas every
frame) but reads 1.00 — proof the layer data is absent, so **no Chromium verdict
is trustworthy from this run.** The correct reading of Q2 is "not measurable via
CDP LayerTree here," which for our purposes is equivalent to Q1's NO: the path
that would have answered it is closed.

## Q3. Non-Chromium premise matrix

Confirmed by inspecting the running containers (`ldd`):

| Toolkit | Tappable layer tree? | Interception path | Our apps | A viable? |
|---|---|---|---|---|
| Chromium/Electron | Internally yes (`cc`), **not reachable via CDP here** | CDP LayerTree = closed (this probe); tracing / patched Viz = untested, deep | 1Password, Signal (both link libgtk-3 = Electron-on-GTK3) | Only via deep Chromium interception — not the cheap path |
| GTK4 | Yes (GSK render nodes) | `gsk_render_node_serialize` / GtkInspector | none in our family | moot (no GTK4 app) |
| GTK3 | No (immediate-mode cairo, one surface) | — | mousepad (links libgtk-3.so.0) | No → C only |
| Swing/Java2D | No (one AWT buffer) | — | CLion | No → C only |
| Qt Widgets / QtQuick | QWidget No / QtQuick Yes | — | none yet | per-module |

Every GUI app in the family is either **Electron** (1Password, Signal — Chromium
engine, layer tree behind the closed CDP path) or **one-surface** (mousepad GTK3,
CLion Swing). No app exposes a cheaply-tappable layer tree.

## Recommendation

**Pivot to approach C (client-side smart-resize).** Rationale:

1. **A's cheap path is closed.** The CDP LayerTree interception that made A
   attractive returns nothing in our environment, with the obvious environmental
   confounds ruled out. Reaching Chromium's `cc` tree would require patching Viz
   or compositor-frame tracing — high effort, fragile across Chromium versions,
   Electron-only. That is a large bet, and this probe found no cheap way to
   de-risk it further short of doing that deep work.
2. **C is needed regardless.** mousepad (GTK3) and CLion (Swing) are permanently
   one-surface; they can never benefit from A. Client-side smart-resize is the
   *only* live-resize path for them, so it is the universal investment.
3. **Sequencing.** Build and evaluate C first (it covers the whole app family,
   including the Electron apps at the one-surface level). Revisit A only if C
   proves insufficient *and* someone is willing to take on Chromium-internal
   interception for the Electron sub-family specifically.

**Do not** treat this as "A is impossible." It is "A has no cheap interception
path here; its remaining routes are deep and untested." If A is ever revived, the
next probe is a Chromium-tracing (`cc`/`viz` categories) or patched-Electron
experiment — not CDP LayerTree.

---

## Reproduce

See `README.md`. The `run-*.json` files from this session are gitignored (kept
locally as the raw evidence); re-running the probe regenerates them.
