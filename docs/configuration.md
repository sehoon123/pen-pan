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

The menu's status row can show **ON, waiting for release**, **OFF, draining**, or **Quitting, waiting for release**. A contact that started as ordinary input stays ordinary through release. Turning OFF and back ON does not revive a cancelled contact.

## Scroll settings

| Setting | Range or behavior | Fresh default |
| --- | --- | --- |
| **Sensitivity** | 0.05x to 2.00x, inclusive. Lower values produce less scrolling for the same movement. | 0.30x |
| **Reverse scroll direction** | Reverses horizontal and vertical scrolling together. | Unchecked |

Sensitivity and reversal are saved automatically. Each adapted contact captures its settings at pen down, so a change does not alter an in-progress tap or pan.

The default click-to-pan threshold is six screen-coordinate pixels, measured as distance from pen down. A stationary tap produces a deferred click pair at the original position on release. Once a contact becomes a pan, it stays a pan until release.

A pen contact that starts on the visible Settings window remains ordinary input through release, even if it leaves the window. This exception uses the window at the pen-down position. It does not exempt a covered window, another app, or an already-captured pan. These settings are not physical-tablet calibration.

## Toggle shortcut

**Toggle shortcut** has no default binding. Its recorder shows **Record shortcut…** when unassigned and **Press a shortcut…** while listening. While the recorded key is held, it shows **Release** followed by the shortcut label and an ellipsis. A saved binding appears as its key label.

A valid binding contains Control, Option, or Command with a supported key. Shift can be added. Bare typing, Space, Shift-only combinations, modifier-only combinations, and unsupported key codes are rejected.

Supported keys include letters, digits, US punctuation positions, Return, Tab, Delete, Forward Delete, F1 through F12, Home, End, Page Up, Page Down, and arrow keys. Labels name physical US key positions, not characters from the active input source. Escape cancels recording rather than becoming a binding.

The recorder commits on release of the recorded key. Escape, focus loss, window close, and application deactivation cancel recording without replacing the previous binding. **Clear** cancels recording and removes the binding if native unregistration succeeds.

The shortcut is a discrete toggle, not a hold-to-scroll modifier. Each press toggles once until release. Recording the current binding does not toggle the mode. Registration uses exclusive native Carbon hotkeys and remains active while the helper runs, including while OFF.

Known reserved combinations and enabled symbolic system shortcuts are rejected. Failed replacement preserves the previous registration and saved configuration. Application-local commands in other apps are not fully detectable. An unavailable saved binding remains saved but appears inactive. Pen Pan does not change system shortcut preferences.

Keyboard events are not part of the pen event tap. A focused, application-local key-up monitor handles Command-modified releases during recording because AppKit can omit them during window dispatch. It acts only for the active recorder in the key window. Other event types, non-Command releases, and releases outside that focused recorder pass through unchanged. There is no global keyboard monitor.

## Saved configuration

The named UserDefaults suite is `local.pen-pan`. Only these values are saved:

| Key | Value |
| --- | --- |
| `sensitivity` | A finite number from 0.05 to 2. |
| `reversed` | A Boolean for both-axis reversal. |
| `shortcut` | An optional dictionary containing `keyCode` and `modifiers`. **Clear** removes it. |

ON or OFF mode and the threshold are not saved. Invalid saved fields fall back independently to defaults or a valid launch seed. Loading configuration alone does not write settings.

## Environment variables

| Variable | Accepted value | Default and precedence |
| --- | --- | --- |
| `PENPAN_SENS` | A finite number from 0.05 to 2, inclusive. | Valid saved sensitivity takes priority, then this launch seed, then 0.30. |
| `PENPAN_DEADZONE` | A finite positive number of screen-coordinate pixels. | This launch seed takes priority over six. There is no saved threshold. |

A valid saved sensitivity overrides even an invalid `PENPAN_SENS`. Otherwise, an invalid launch value stops startup before the event tap is installed. `PENPAN_DEADZONE` is always validated for live modes. No environment variable controls reversal or the shortcut.

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
