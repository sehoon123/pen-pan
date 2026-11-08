# Pen Pan

Pen Pan is an experimental macOS helper that turns pen drags into two-axis scrolling. While ON, a stationary pen tap becomes a click on release. Exclude an application to keep its native pen input while ON, or turn Pen Pan OFF to write, select text, or drag objects everywhere.

Pen Pan is available as source and an experimental standalone binary. It is not a touchscreen driver and does not add multitouch or zoom gestures.

## Quick start

### Use the experimental v0.1.0 binary

The standalone ZIP requires Apple Silicon (`arm64`) and macOS 26.0 or later. It was tested on macOS 26.6.2. It contains a command-line/menu helper, not an app bundle or Intel build. The executable is ad-hoc signed, not Developer ID signed or notarized.

1. Open the repository's [Releases page](https://github.com/sehoon123/pen-pan/releases) and select the experimental **v0.1.0** prerelease. Download `pen-pan-v0.1.0-macos-arm64.zip` and the separate `SHA256SUMS` asset into the same directory.
2. In Terminal, change to that directory and verify the archive before extraction:

   ```sh
   shasum -a 256 -c SHA256SUMS
   ```

   Continue only if the output reports `pen-pan-v0.1.0-macos-arm64.zip: OK`. If verification fails, stop and download both assets again.
3. Extract the archive and check usage:

   ```sh
   unzip pen-pan-v0.1.0-macos-arm64.zip -d pen-pan-v0.1.0-macos-arm64 &&
   cd pen-pan-v0.1.0-macos-arm64 &&
   ./pen-pan --help
   ```

4. From the extracted directory, start menu mode:

   ```sh
   ./pen-pan --menu
   ```

macOS may block this unnotarized download. Decide whether to allow it through normal per-item macOS security controls, or use the source build below. See [Handle a downloaded binary warning](docs/troubleshooting.md#handle-a-downloaded-binary-warning) before proceeding.

### Build from source

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
3. Outside excluded apps, choose **Turn OFF** before handwriting, long-press actions, text selection, or object dragging.
4. Open **Settings...** for the live ON/OFF control and the **Scrolling**, **Toggle shortcut**, and **Excluded apps** groups.
5. Choose **Quit** to stop the helper. If it is waiting for a captured contact, lift the pen.

Fresh sensitivity is **0.30x**, adjustable from **0.05x** to **2.00x**. Direction reversal affects both axes. Changes apply to the next pen contact. Contacts that start on the helper's own Settings window or application picker remain ordinary input, even while ON.

To keep handwriting or native drags in an app, choose **Add application…** in **Excluded apps** and select its `.app` package. Rows show the local name and bundle ID. **Remove selected** restores scrolling for new contacts in that app. The application under the pen at contact start determines the exclusion, not the app with keyboard focus. The list starts empty.

To assign a toggle shortcut, click **Record shortcut…**, then press and release a supported key with Control, Option, or Command, or explicitly choose **F13 through F20** alone. **Clear** removes the binding. No shortcut is assigned by default. A chosen shortcut stays reserved while Pen Pan runs, even while OFF. A tablet driver may map a pen button or ExpressKey to F13 through F20. Pen Pan does not configure the driver, and support varies.

Sensitivity, direction reversal, the shortcut, and excluded bundle IDs are saved locally. Menu mode always restarts OFF. Pen Pan installs no autostart item. See the [configuration reference](docs/configuration.md) for shortcut rules, launch settings, and headless mode.

## Limits

- While ON, ordinary pen long-press, writing, selection, and object drags become scrolling outside excluded apps and the helper's own UI.
- With exclusions active, an unresolved pen-down application passes through conservatively. Empty exclusions preserve the normal scrolling behavior. Exclusions apply to entire bundle IDs, not individual documents or windows.
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
