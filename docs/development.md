# Build, test, and contribute

## Build from source

Use macOS with Apple's command-line developer tools. If needed, install them with `xcode-select --install`.

From the repository root, run:

```sh
make build
.build/pen-pan --help
```

The default `make` target is also `build`. Both commands compile `.build/pen-pan` without launching it or overwriting a root executable.

The build uses `xcrun swiftc -O -warnings-as-errors -parse-as-library`. Tests add `-D TESTING` and compile both Swift files into `.build/pen-pan-tests`. AppKit, CoreGraphics, Carbon, and Darwin come with macOS. No external packages are required.

The local build and both suites are verified with Apple Swift 6.4 on macOS 26.6.2, arm64. Intel and older macOS versions are not independently verified. This is a verification scope, not a minimum supported version.

## Run the safe checks

```sh
make check
.build/pen-pan --help
.build/pen-pan
```

`make check` builds the helper and runs both suites. Neither suite installs a global event tap, registers a real global shortcut, posts global input, or starts a helper process.

To run the suites separately:

```sh
make test
make test-native
```

- `make test` runs 50 offline checks for gestures, contact lifecycle, configuration, shortcut validation, and registration failure handling.
- `make test-native` runs 14 app-local AppKit and Carbon checks. These use temporary nonactivating windows, private controls, and injected shortcut registration, focus, and window-hit state.

The native suite sends events only to its own application. Its temporary windows do not require global input access. Preference tests use isolated `local.pen-pan.tests.<UUID>` suites and remove them afterward. Lock tests use temporary paths, not the live instance lock.

No arguments and `--help` return before opening the live settings suite, acquiring the lock, installing a tap, or registering a shortcut. Do not use `--menu` or `--run` as automated test commands: those modes enable live observation and can intercept pen input.

The macOS GitHub Actions workflow runs `make check` with read-only repository access. It has no release or binary-upload step. A local pass is not evidence that a remote CI run has passed.

To remove build outputs:

```sh
make clean
```

`clean` removes only `.build`.

## Find the relevant code

| File or symbol | Responsibility |
| --- | --- |
| [`pen-pan.swift`](../pen-pan.swift): `ScrollSettings`, `ConfigurationStore` | Launch validation and saved configuration. |
| `Shortcut`, `ShortcutRecording`, `ShortcutRecorder` | Key validation, labels, recording, and focused Command-release handling. |
| `HotKeyAPI`, `HotKeyRegistration` | Native shortcut checks, exclusive registration, dispatch, and cleanup. |
| `SettingsControl` | Settings actions, accessibility labels, and the helper-window exception. |
| `Gesture`, `EventAdapter` | Tap deferral, distance-based scrolling, and event conversion. |
| `Lifecycle`, `LiveSession`, `InstanceLock` | Contact ownership, ON and OFF transitions, tap lifetime, shutdown, and single-instance locking. |
| `MenuControl`, `PenPan` | Menu actions and command-line entry point. |
| [`pen-pan-tests.swift`](../pen-pan-tests.swift) | Offline traces and app-local native checks. |
| [`Makefile`](../Makefile), [`ci.yml`](../.github/workflows/ci.yml) | Local build targets and macOS CI. |

## Verify input changes before contributing

1. Reproduce the issue with the smallest relevant trace or app-local control.
2. Add a regression check in `pen-pan-tests.swift` without global posting or real shortcut registration.
3. Run `make check` and both safe usage commands.
4. If the change affects live input, verify it manually in a controlled session with a known way to quit.

For live-input changes, check pen taps and pans, both axes, OFF passthrough, mid-contact toggles, and quit while a contact is held. Verify that ordinary mouse and keyboard input remain unchanged. Check Settings-window tracking and per-contact sensitivity and reversal. For shortcut changes, check physical recognition, recording cancellation, Command-modified release, conflicts, Clear, and persistence after restart.

The automated suites inject tap failure, shortcut registration, focus, and window-hit results. They do not prove real global-tap delivery, physical pen calibration, physical keyboard recognition, multi-display coordinates, or compatibility with other apps. Record the hardware, driver, apps, and macOS version used for manual checks. Keep those limits explicit in a contribution.

Keep changes focused and update the relevant public guide when behavior changes. Do not commit binaries, preferences, input traces, private logs, or credentials.
