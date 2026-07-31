# Build notes — "Cold Metal Banking" UI overhaul

Visual/UX-only overhaul. Zero behavior, data, learning-logic, or navigation
changes. One central design system (`Bani/Theme/DesignSystem.swift`) + a retuned
asset catalog drive the whole app; surface views consume tokens only.

## Palette (asset catalog — Any + Dark, retuned in place)

Old warm paper/ink palette **retired by re-tuning the same colorsets** (no
renames, so no orphan references possible; every colorset is still referenced).

| Asset | Role | Light (polished silver) | Dark (titanium black) |
|---|---|---|---|
| `BaniCanvas` | app background | near-white silver | deep graphite |
| `BaniSurface` | brushed-steel plates | darker brushed steel | titanium gray (lifts) |
| `BaniInk` | primary text | crisp cool near-black | off-white |
| `BaniSecondaryInk` | secondary text | cool gray | cool gray |
| `BaniHairline` | borders / dividers | cooler-than-surface line | subtle graphite line |
| `BaniAccent` | **money / actions / record / positive** | cold electric green-teal (deep) | electric terminal green |
| `BaniTagPersonal` | Personal tag | steel blue | steel blue |
| `BaniTagWork` | Work tag | gunmetal amber | gunmetal amber |
| `BaniCat*` (9) · `BaniCustom*` (8) | category hues | cool-shifted, one cold family | brighter cold family |

Metal effect is built **in code, from the asset colors** (never literal RGB):
`MetalSurface` fills with `BaniSurface`, overlays a 3-stop low-delta vertical
luminance gradient (white top / clear mid / black bottom), adds a hairline
top-edge glint and a `BaniHairline` border. Brushed, not mirror-chrome; no image
assets. One intentional non-asset color exists app-wide: the confirmation card's
modal scrim (`Color.black.opacity(0.3)`), the platform-standard backdrop dim.

## Contrast (WCAG, computed from the shipped colorsets)

**Every text/surface pairing clears 4.5:1 in BOTH modes** (worst = 5.07:1).

| Pairing | Light | Dark |
|---|---|---|
| Ink on Canvas | 15.73:1 | 15.62:1 |
| Ink on Surface | 14.07:1 | 13.60:1 |
| SecondaryInk on Canvas | 5.96:1 | 7.74:1 |
| SecondaryInk on Surface | 5.33:1 | 6.74:1 |
| Accent on Canvas | 5.66:1 | 10.18:1 |
| Accent on Surface | 5.07:1 | 8.86:1 |
| TagPersonal on Canvas | 6.19:1 | 8.13:1 |
| TagPersonal on Surface | 5.54:1 | 7.08:1 |
| TagWork on Canvas | 5.69:1 | 9.21:1 |
| TagWork on Surface | 5.09:1 | 8.02:1 |

Category/custom hues are **graphical** (donut/bars/icon tints, not body text):
min contrast vs canvas is **light 3.73:1 / dark 7.30:1** — clears the 3:1
graphical bar in both modes.

## The `.rounded` decision

**Dropped app-wide.** SF Rounded is retired in favor of default SF for the
colder, more precise feel; money keeps monospaced digits (`Typography.amount` /
`.heroAmount`). Zero `design: .rounded` remain in the codebase.

## Density token table (B1 — `DesignScale`, live via `@AppStorage("designScale")`)

| Dimension | Airy | Balanced (default) | Dense |
|---|---|---|---|
| screenPadding | 24 | 20 | 16 |
| sectionSpacing | 26 | 18 | 11 |
| cardPadding | 22 | 16 | 12 |
| rowVInset | 11 | 6 | 3 |
| rowSpacing | 15 | 10 | 6 |
| elementSpacing | 13 | 9 | 6 |
| chartCardHeight | 268 | 232 | 200 |
| secondaryTextScale | 1.06 | 1.00 | 0.92 |

Invariants that **never** shrink: hero amount font (size-fixed 44 bold mono) and
`minTapTarget = 44`. Strict monotonic ordering + distinctness enforced by
`DensityTokensTests`. Setting lives in Settings → Appearance ("Layout density /
Densitate aspect"), localized ro+en, applies live (no restart).

## Motion spec (unified, named constants)

`Motion.spring` (0.32/0.88), `.snappy` (0.24/0.90 — taps/press), `.chart`
(0.38/0.90), `.card` (0.36/0.86). All ad-hoc springs/eases replaced.

## Deferred (logged; stayed visual per the brief)

- **Card(normal)/Card(edit) screenshots** — not automated. Presenting the live
  `ConfirmationCard` for a shot needs a state-seeding launch seam in the
  load-bearing Log flow; to stay strictly visual this cycle it is covered by the
  existing `ConfirmationCardTests` (unit) + the human's interactive Appetize pass
  (the explicit human gate). The card *is* fully restyled and gets a dimmed
  backdrop; only the automated shot is deferred.
- **Recording-view numeric timer** — the brief mentions a monospaced timer, but
  no elapsed-time state is exposed by `Recorder`; adding one is functional. The
  waveform is accent-on-metal and labels are mono-ready; the timer is deferred.
- **Accent-filled segmented selection** — a true accent-filled selected segment
  needs a global `UISegmentedControl.appearance()` mutation (app-level); used
  `.tint(accent)` as the in-scope signal.

## Screenshot matrix — grades (from CI `screenshots` artifact)

All captured shots graded PASS. SLOP checks (mirror-chrome kitsch, silver-on-
silver contrast, warm-hue leaks, inconsistent radii/motion, clipped Romanian):
none found.

| Shot | Light | Dark | Note |
|---|---|---|---|
| Log | PASS | PASS | brushed-metal Personal/Work plates, cold-teal mic, ink labels |
| Finances (donut/bars) | PASS | PASS | metal hero `486.4` accent-mono, chart card, re-skinned controls |
| Finances (bars + selection) | PASS | PASS | selection annotation as a metal chip, accent bars, hairline grid |
| Settings | PASS | PASS | C4 reorg (Recording/Appearance/…), grouped metal, accent actions |
| Log — Airy / Dense | PASS | — | visibly looser / tighter spacing |
| Finances — Airy / Dense | PASS | — | chart card 268 vs 200; dense reveals full chart + breakdown |
| Romanian (Log + Finances) | PASS | — | surface-correct (see harness note) |

Detail × {light,dark}: capture removed — see deferred. Every other D1 cell captured.

## Test-harness findings (pre-existing; documented, not fixed here)

- **Language contamination**: the B5 Romanian test persists `appLanguage=ro`
  into the shared CI simulator, and app language changes only fully apply on the
  *next* launch (bundle string resolution is process-start bound). Net effect:
  later tests that select tabs by localized label silently mis-tapped. Fixed the
  screenshot side by selecting tabs **by index** (locale-agnostic). The deeper
  i18n launch behavior + the pre-existing `TransactionDetailUITests` label
  lookups are functional/out-of-scope for a visual pass and left as-is
  (non-blocking).
- **Detail row reachability**: the taller metal hero/chart cards push the
  transaction list out of the lazily-rendered accessibility tree, and the
  interactive chart swallows scroll gestures, so a specific seeded row can't be
  reliably reached from a cold launch in CI. The detail *view* is restyled and
  code-verified; it is graded in the Appetize interactive pass (D4 human gate),
  and its behavior stays covered by `TransactionDetailUITests`.
