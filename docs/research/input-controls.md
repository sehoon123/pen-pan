# Research behind the input controls

Pen Pan needs native selection and dragging alongside direct-displacement scrolling, plus a deliberate way to restrict scroll output. The selected controls are opt-in Option-native contacts and an explicit axes popup. Both are included in this source and planned for the experimental v0.2.0 binary prerelease. The earlier v0.1.0 download does not include them.

## First-party observations

This scan records public vendor materials observed on November 8, 2026. Prices are snapshots, not guarantees. It is not a market-share study, demand survey, hands-on benchmark, or independent verification of compatibility claims. No competitor code was copied.

| Product and first-party sources | Observed availability or price | Relevant documented behavior |
| --- | --- | --- |
| [Scroll My Mac](https://scrollmymac.blakewatson.com/) and [documentation](https://scrollmymac.blakewatson.com/docs/) | Free forever, MIT, Apple Silicon download | Click-and-drag two-axis scrolling, optional inertia, app exclusions, and native dragging after a configurable hold delay, one second by default. |
| [Mos](https://mos.caldis.me/) and [English README](https://raw.githubusercontent.com/Caldis/Mos/master/README.enUS.md) | Described as free and open source | Independent vertical and horizontal smoothing and reversal, axis-conversion and temporary-smoothing-disable hotkeys, and per-app profiles. |
| [LinearMouse](https://linearmouse.app/), [configuration reference](https://raw.githubusercontent.com/linearmouse/linearmouse/main/Documentation/Configuration.md), and [README](https://raw.githubusercontent.com/linearmouse/linearmouse/main/README.md) | Public MIT download. No paid tier observed in these materials. | Per-app, device, and display profiles, independently tuned directions, modifier-scoped mappings, and pointer-to-scroll trigger configuration. |
| [Mac Mouse Fix](https://macmousefix.com/) | $2.99 plus applicable taxes, with 30 days of actual use free | Modifier-assisted precise scrolling and zoom, and adjustable smoothing. Smoothing Off still changes wheel increments to lines. |
| [Smart Scroll](https://www.marcmoini.com/sx_en.html) | $14 single-user license and a free trial | Grab Scroll advertises graphics-tablet use, a configurable hotkey trigger, and inertia. Its separate Vector Scroll uses an anchor and speed model. |

## What the observations support

Scroll My Mac documents a mixed scrolling and native-drag workflow, but its hold delay is not proof of modifier-held raw passthrough. Mos's smoothing-disable hotkey and Mac Mouse Fix's smoothing Off are not guarantees that original pen or button events pass unchanged. Independent-axis settings and modifier mappings are recurring product choices, not proof of demand for Pen Pan's exact policies. Vendor tablet claims do not establish support for a particular XP-Pen driver or Option-flag delivery.

Pen Pan therefore keeps its existing contact ownership and direct displacement model. **Hold Option for native pen input** defaults OFF. When enabled, Option on the original pen down passes that entire contact unchanged. Normal destination-app Option actions remain, so this is not neutral input. No timer, keyboard listener, or extra shortcut is needed.

The axes popup offers **Both axes**, **Vertical only**, and **Horizontal only**, defaulting to Both. Explicit modes avoid uncalibrated diagonal, tie, or relock heuristics. The six-pixel radial pan threshold stays unchanged. A drag on a suppressed axis remains a pan, never an accidental click. Settings snapshot at down.

Inertia is deferred because prior excessive-movement feedback provides no calibrated basis for a safe tail. Adaptive axis lock would introduce device heuristics. Long-press passthrough would require delayed replay and target lifetime handling. Per-app sensitivity, device profiles, and packaging changes are outside these two workflow gaps. Smart Scroll's Vector Scroll is not the desired displacement-following behavior.

See the [configuration reference](../configuration.md) for the controls and saved keys, and [development guide](../development.md) for the app-local checks and physical-input limits.
