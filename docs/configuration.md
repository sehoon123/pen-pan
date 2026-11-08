# Configuration reference

## Menu and modes

| Control | Behavior |
| --- | --- |
| **Pen Pan: OFF** | Menu-bar title when scrolling is disabled or the event tap is unavailable. |
| **Pen Pan: ON** | Menu-bar title when scrolling is enabled and the event tap is available. |
| **Turn ON** | Enables scrolling for the next eligible pen contact. |
| **Retry ON** | Retries event-tap installation after a failure, then enables scrolling if installation succeeds. |
| **Turn OFF** | Cancels captured output and disables scrolling. An owned contact drains through release. |
| **Settings...** | Opens or reuses the **Pen Pan Settings** window. |
| **Quit** | Releases shortcut reservations and exits after any owned contact drains. |

Settings has the same live status and **Turn ON**, **Turn OFF**, or **Retry ON** action above the grouped controls. Mode is not a saved setting. The status can show **ON, waiting for release**, **OFF, draining**, or **Quitting, waiting for release**. A contact that started as ordinary input stays ordinary through release. Turning OFF and back ON does not revive a cancelled contact.

## Scroll settings

| Setting | Range or behavior | Fresh default |
| --- | --- | --- |
| **Sensitivity** | 0.05x to 2.00x, inclusive. Lower values produce less scrolling for the same movement. | 0.30x |
| **Reverse scroll direction** | Reverses horizontal and vertical scrolling together. | Unchecked |

Sensitivity and reversal are saved automatically. Each adapted contact captures its settings at pen down, so a change does not alter an in-progress tap or pan.

The default click-to-pan threshold is six screen-coordinate pixels, measured as distance from pen down. A stationary tap produces a deferred click pair at the original position on release. Once a contact becomes a pan, it stays a pan until release.

A pen contact that starts on the visible Settings window, its application picker, or an owned sheet or child window remains ordinary input through release, even if it leaves the window. This exception uses the window at the pen-down position. It does not exempt a covered window, another app, or an already-captured pan. These settings are not physical-tablet calibration.

## Toggle shortcut

**Toggle shortcut** has no default binding. Its recorder shows **Record shortcut…** when unassigned and **Press a shortcut…** while listening. While the recorded key is held, it shows **Release** followed by the shortcut label and an ellipsis. A saved binding appears as its key label.

A valid binding contains Control, Option, or Command with a supported key, or an explicit F13 through F20 key alone. Shift can be added, including Shift with F13 through F20. Bare typing, Space, bare F1 through F12, Shift-only typing combinations, modifier-only combinations, media keys, and unsupported key codes are rejected. The incidental Fn event flag neither authorizes other keys nor becomes a saved modifier.

Supported keys include letters, digits, US punctuation positions, Return, Tab, Delete, Forward Delete, F1 through F20, Home, End, Page Up, Page Down, and arrow keys. Labels name physical US key positions, not characters from the active input source. Escape cancels recording rather than becoming a binding.

The recorder commits on release of the recorded key. Escape, focus loss, window close, and application deactivation cancel recording without replacing the previous binding. **Clear** cancels recording and removes the binding if native unregistration succeeds.

The shortcut is a discrete toggle, not a hold-to-scroll modifier. Each press toggles once until release. Recording the current binding does not toggle the mode. Registration uses exclusive native Carbon hotkeys and remains active while the helper runs, including while OFF.

Known reserved combinations and enabled symbolic system shortcuts are rejected. Failed replacement preserves the previous registration and saved configuration. Application-local commands in other apps are not fully detectable. An unavailable saved binding remains saved but appears inactive. Pen Pan does not change system shortcut preferences.

Keyboard events are not part of the pen event tap. A focused, application-local key-up monitor handles Command-modified releases during recording because AppKit can omit them during window dispatch. It acts only for the active recorder in the key window. Other event types, non-Command releases, and releases outside that focused recorder pass through unchanged. There is no global keyboard monitor.

A tablet driver may map a pen button or ExpressKey to F13 through F20. Pen Pan does not configure that mapping or guarantee that a particular driver can emit those keys. No shortcut is assigned automatically.

## Excluded apps

The **Excluded apps** group contains a bounded scrollable list, **Add application…**, **Remove selected**, and inline feedback. Each row shows a locally resolved application name and its bundle ID. Missing local names fall back to the ID. Long labels truncate in the row, with the complete name and ID in the tooltip and accessibility label.

**Add application…** opens a single-selection native application picker. A selection must be a local `.app` directory with package type `APPL`, a regular executable file, and a valid actual bundle ID. Pen Pan reads package metadata but does not launch the application. Cancel and invalid selections leave configuration unchanged. A duplicate selects its existing row without adding another entry. **Remove selected** is disabled without a selection. Closing Settings or quitting cancels the owned picker and ignores late completion.

Application identities are exact, case-preserving bundle IDs with at least two dot-separated components. Each component starts with an ASCII letter or digit and otherwise contains ASCII letters, digits, or hyphens. Empty components, whitespace, wildcards, paths, and process-name patterns are invalid.

For each new eligible pen down while ON, Pen Pan hit-tests the actual pointer window once, then resolves that exact window's owner PID and running application's bundle ID. Keyboard focus does not determine the target. A matching excluded app keeps the original down, drag, and release objects, with no generated scrolling. Unresolved targets pass through when any exclusions are active. With the list empty, there is no owner or bundle lookup, and pointer hit-testing is needed only while the helper's own UI is visible.

Exclusion changes apply only to new contacts. Editing the list, changing focus, or moving the pointer cannot steal a passed contact, cancel an owned pan, or revive a draining contact. Turning OFF still cancels captured output, while passed contacts remain ordinary through release. Exclusions cover every window with that bundle ID, not individual windows or documents. No names or application paths are saved.

## Saved configuration

The named UserDefaults suite is `local.pen-pan`. Only these values are saved:

| Key | Value |
| --- | --- |
| `sensitivity` | A finite number from 0.05 to 2. |
| `reversed` | A Boolean for both-axis reversal. |
| `shortcut` | An optional dictionary containing integral UInt32 `keyCode` and Carbon `modifiers`. Only Command, Option, Control, and Shift bits are supported. **Clear** removes it. |
| `excludedApps` | A sorted array of validated bundle-ID strings. The fresh default is empty. Duplicates collapse on load. |

ON or OFF mode and the threshold are not saved. Invalid saved fields fall back independently to defaults or a valid launch seed. A non-string-array `excludedApps` value is ignored as a whole. Invalid IDs inside a string array are discarded. Valid sibling preferences load independently. Every settings edit preserves the other configuration fields. Loading configuration alone does not write settings.

## Environment variables

| Variable | Accepted value | Default and precedence |
| --- | --- | --- |
| `PENPAN_SENS` | A finite number from 0.05 to 2, inclusive. | Valid saved sensitivity takes priority, then this launch seed, then 0.30. |
| `PENPAN_DEADZONE` | A finite positive number of screen-coordinate pixels. | This launch seed takes priority over six. There is no saved threshold. |

A valid saved sensitivity overrides even an invalid `PENPAN_SENS`. Otherwise, an invalid launch value stops startup before the event tap is installed. `PENPAN_DEADZONE` is always validated for live modes. No environment variable controls reversal, the shortcut, or exclusions.

## Command-line behavior

| Invocation | Behavior |
| --- | --- |
| `.build/pen-pan --menu` | Starts OFF with the menu and Settings window available. Attempts to attach the pen event tap. Attachment failure leaves a retryable OFF status. |
| `.build/pen-pan --run` | Starts ON without a menu or Settings window. Uses saved configuration and the same native shortcut dispatch. Attachment failure exits with an error. |
| `.build/pen-pan --help` | Prints usage without live setup. |
| `.build/pen-pan` | Prints the same usage without live setup. |

No arguments, `--help`, and other argument forms besides a single `--menu` or `--run` do not open the settings suite, acquire the lock, install a tap, or register a shortcut.

Menu and headless modes share a per-user kernel lock at `/tmp/pen-pan-<uid>.lock`. The lock remains held while OFF or after menu-mode attachment failure. Closing the process releases the lock. The lock file remains in place and must not be deleted to bypass a running instance.

Control-C and SIGTERM request the same graceful shutdown as **Quit**. Shutdown cancels output and waits for an owned contact's release. No login item or launch agent is installed.
