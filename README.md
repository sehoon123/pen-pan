# Pen Pan

Pen Pan is an experimental macOS helper that turns pen drags into two-axis scrolling. While ON, a stationary pen tap becomes a click on release. Turn it OFF to write, select text, or drag objects normally.

This project distributes source, not a packaged or notarized app. It is not a touchscreen driver and does not add multitouch or zoom gestures.

## Quick start

You need macOS and Apple's command-line developer tools. If the tools are missing, run `xcode-select --install` first. Pen Pan uses the system AppKit, CoreGraphics, Carbon, and Darwin frameworks, with no external package dependencies.

```sh
git clone https://github.com/sehoon123/pen-pan.git
cd pen-pan
make
.build/pen-pan --help
.build/pen-pan --menu
```

`make` builds only into `.build` and does not start input interception. The local build and test suites are verified with Apple Swift 6.4 on macOS 26.6.2, arm64. Intel and older macOS versions are not independently verified.

Menu mode starts with **Pen Pan: OFF** in the menu bar. If the menu reports an unavailable event tap, follow [Restore event-tap access](docs/troubleshooting.md#restore-event-tap-access). Pen Pan does not request or grant Accessibility access itself.

## Use the controls

1. Choose **Turn ON** from the menu bar to enable pen scrolling.
2. Tap to click, or drag the pen to scroll horizontally and vertically. Scrolling follows the current pen position.
3. Choose **Turn OFF** before handwriting, long-press actions, text selection, or object dragging.
4. Open **Settings...** to adjust **Sensitivity**, **Reverse scroll direction**, or the optional **Toggle shortcut**.
5. Choose **Quit** to stop the helper. If it is waiting for a captured contact, lift the pen.

Fresh sensitivity is **0.30x**, adjustable from **0.05x** to **2.00x**. Direction reversal affects both axes. Changes apply to the next pen contact. Contacts that start on the helper's own Settings window remain ordinary input, even while ON.

To assign a toggle shortcut, click **Record shortcut…**, then press and release a supported key with Control, Option, or Command. **Clear** removes the binding. No shortcut is assigned by default. A chosen shortcut stays reserved while Pen Pan runs, even while OFF.

Sensitivity, direction reversal, and the shortcut are saved locally. Menu mode always restarts OFF. Pen Pan installs no autostart item. See the [configuration reference](docs/configuration.md) for shortcut rules, launch settings, and headless mode.

## Limits

- While ON, ordinary pen long-press, writing, selection, and object drags become scrolling outside the helper's Settings window.
- Only tablet subtype-1 pen events are adapted. Driver behavior varies. A subtype-0 release can be ambiguous during overlapping pen and mouse contacts.
- Turning OFF during a captured contact discards its remaining motion and release without clicking. Ordinary input resumes after that contact drains.
- Scrolling can change targets when the pen crosses into another scrollable area.
- Physical pen tracking and calibration, physical global-shortcut recognition, multi-display behavior, and compatibility with every app remain unverified.

The runtime contains no network client or telemetry code. Its event tap observes only left-button down, drag, and up events, not keyboard input.

## Documentation

- [Configuration reference](docs/configuration.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Build, test, and contribute](docs/development.md)

## License

[MIT](LICENSE). Copyright (c) 2026 sehoon123.
