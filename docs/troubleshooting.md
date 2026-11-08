# Troubleshooting

## Handle a downloaded binary warning

The experimental v0.1.0 ZIP contains a standalone Apple Silicon (`arm64`) executable for macOS 26.0 or later, tested on macOS 26.6.2. It is ad-hoc signed, not Developer ID signed or notarized. It is not an app bundle or an Intel build.

If macOS blocks the downloaded executable or warns that Apple cannot verify it, treat that as a Gatekeeper launch decision. First verify the archive against the separate `SHA256SUMS` asset as described in [Quick start](../README.md#use-the-experimental-v010-binary).

Proceed only if you trust the download and choose to run it. Use macOS's normal per-item approval controls in **System Settings > Privacy & Security** when offered. You can decline and [build from source](../README.md#build-from-source) instead. Do not disable Gatekeeper or SIP, or edit the TCC permission database.

Gatekeeper approval does not grant Accessibility access. Accessibility access cannot resolve a Gatekeeper launch block. Once the executable starts, follow the event-tap steps below if the menu reports an unavailable tap.

## Restore event-tap access

If the menu stays **Pen Pan: OFF** and reports that it could not create an event tap:

1. Open **System Settings > Privacy & Security > Accessibility**.
2. Check access for the executable or launching application identity that macOS shows. The identity can depend on how you launch Pen Pan.
3. If you change access, restart the helper when macOS requires it.
4. Choose **Retry ON** from the menu.

Pen Pan does not request or grant permission itself. A failed menu-mode attachment leaves input unchanged and keeps the menu available for retry or **Quit**. In headless mode, an attachment failure exits with an error.

If access is already enabled, quit and relaunch Pen Pan from the same location and launch method. Keep the terminal's error message when you report the failure. Do not disable macOS security protections to make the helper run.

## Resolve an unavailable shortcut

If Settings reports a reserved, system, or unavailable shortcut:

1. Open **Settings...**.
2. Click the shortcut recorder.
3. Press and release a different combination that includes Control, Option, or Command, or choose F13 through F20 alone.

Bare typing, Space, bare F1 through F12, Shift-only typing combinations, media keys, and modifier-only combinations are unsupported. Escape cancels recording. Keep the Settings window active until you release the recorded key.

A failed replacement keeps the previous binding. If a saved binding is unavailable at startup, it stays saved but inactive. Re-record the binding after resolving the conflict, or choose **Clear** to remove it.

Check **System Settings > Keyboard > Keyboard Shortcuts** and the target app's commands for conflicts. Pen Pan rejects known reserved and enabled symbolic system shortcuts, but cannot detect every app-local command. A binding stays reserved even while Pen Pan is OFF. Choose **Clear** or quit the helper to release it. If cleanup fails, quit to release any remaining reservation.

If the displayed key differs from the character on your keyboard, use its physical US position. Key labels do not follow the active input source. Physical global-shortcut recognition has not been independently verified.

## Reduce scrolling or reverse its direction

1. Open **Settings...**.
2. Lower **Sensitivity** if a small pen movement scrolls too far. The range is 0.05x to 2.00x, with a fresh default of 0.30x.
3. Change **Reverse scroll direction** if scrolling moves the wrong way. The checkbox reverses both axes.
4. Lift the pen, then start a new contact to test the change.

An in-progress contact keeps its original settings. Saved sensitivity takes priority over `PENPAN_SENS`, so an environment override does not replace an existing saved value. See [Environment variables](configuration.md#environment-variables).

If a tap becomes a pan too readily, check whether your launch environment sets `PENPAN_DEADZONE`. Its default is six screen-coordinate pixels. Sensitivity and threshold do not calibrate physical pen tracking.

## Restore writing, selection, or object dragging

Choose **Turn OFF** in the menu or Settings, then lift the pen before starting another contact. To keep native pen input in one app while Pen Pan stays ON, open **Settings... > Excluded apps**, choose **Add application…**, and select the app.

The exclusion follows the bundle ID of the window under the pen at contact start, not keyboard focus. A different app with the same display name does not match. The row shows the bundle ID for confirmation. A missing or invalid application package does not change the list. Use **Remove selected** to restore scrolling in the app for new contacts.

If the menu shows **OFF, draining**, the helper is discarding the rest of a contact it already captured. Turning ON again does not revive that contact. Release it before you continue.

If scrolling unexpectedly passes through while exclusions are active, the target application may be unresolved. Pen Pan prefers native input over accidental interception in that case. Remove exclusions to return to the baseline policy, or report the target app and display arrangement without private window content.

If scrolling changes targets, keep the pen inside the intended scrollable area. Scroll events target the current pen position, not the original pen-down position.

## Stop a duplicate-instance error

If startup reports `another pen-pan instance holds the lock`:

1. Find the existing Pen Pan menu and choose **Quit**. OFF still holds the lock.
2. If the existing helper is headless, press Control-C in its launching terminal.
3. Lift the pen if shutdown is waiting for release.
4. Start one instance after the previous process exits.

Use Activity Monitor to identify an existing helper if its terminal is unavailable. Do not delete `/tmp/pen-pan-<uid>.lock`. The kernel lock releases when the owning process exits, even though the file remains.

## Recover from a stalled contact or shutdown

Choose **Turn OFF** or **Quit**, then lift the pen. Control-C or SIGTERM to the helper's exact process ID also requests graceful shutdown. Avoid overlapping pen and mouse contacts: some drivers send subtype-0 pen releases that cannot be distinguished from a simultaneous mouse release.

If the event tap was disabled while a contact was active, the helper cancels output and retries observation. A release or a fresh pen down after the disabled interval can restore the contact boundary. Events missed while the tap was disabled cannot be suppressed retroactively.

If graceful shutdown remains stuck after release, use Activity Monitor to force quit the identified Pen Pan process. Force quit bypasses contact draining. Restart only after the old process exits.

## Report a compatibility problem

Include your macOS version, Swift version, processor architecture, tablet model and driver, target app, and steps to reproduce. State whether the problem occurs while ON or OFF. Omit private paths and unrelated input from reports.

Physical pen tracking, calibration, multi-display behavior, and every-app compatibility remain unverified. Passing the app-local tests does not establish hardware support.
