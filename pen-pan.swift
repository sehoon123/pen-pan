// Pen contacts are deferred until release or pan commitment. Mouse and keys pass through.
import AppKit
import CoreGraphics
import Darwin
import Carbon

struct ScrollSettings: Equatable {
    let sensitivity: Double
    let threshold: Double
    let reversed: Bool

    init(sensitivity: Double = 0.30, threshold: Double = 6, reversed: Bool = false) {
        self.sensitivity = sensitivity
        self.threshold = threshold
        self.reversed = reversed
    }

    static func environment(_ values: [String: String]) throws -> ScrollSettings {
        func positive(_ name: String, _ fallback: Double) throws -> Double {
            guard let text = values[name] else { return fallback }
            guard let value = Double(text), value.isFinite, value > 0 else {
                throw Failure("\(name) must be a finite positive number")
            }
            return value
        }
        let sensitivity = try positive("PENPAN_SENS", 0.30)
        guard (0.05...2).contains(sensitivity) else { throw Failure("PENPAN_SENS must be in 0.05...2") }
        return try ScrollSettings(sensitivity: sensitivity, threshold: positive("PENPAN_DEADZONE", 6))
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    struct Key {
        let label: String
        let allowsStandalone: Bool
        init(_ label: String, allowsStandalone: Bool = false) {
            self.label = label
            self.allowsStandalone = allowsStandalone
        }
    }
    // Labels name physical US-layout positions, not the current input source's characters.
    static let keys: [UInt32: Key] = {
        let modified: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
            22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
            32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 50: "`", 51: "Delete",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10",
            111: "F12", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End",
            120: "F2", 121: "Page Down", 122: "F1", 123: "Left", 124: "Right", 125: "Down", 126: "Up"
        ]
        var keys = modified.mapValues { Key($0) }
        for (code, label) in [(kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"), (kVK_F16, "F16"),
                              (kVK_F17, "F17"), (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20")] {
            keys[UInt32(code)] = Key(label, allowsStandalone: true)
        }
        return keys
    }()

    init(keyCode: UInt32, modifiers: UInt32) throws {
        guard let key = Self.keys[keyCode],
              modifiers & ~Self.modifierMask == 0,
              (key.allowsStandalone || modifiers & UInt32(cmdKey | optionKey | controlKey) != 0) else {
            throw Failure("Use Control, Option or Command with a supported key, or F13–F20 alone. Space and modifier-only keys are not supported.")
        }
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        for (flag, mask) in [(NSEvent.ModifierFlags.command, cmdKey), (.option, optionKey),
                             (.control, controlKey), (.shift, shiftKey)] where flags.contains(flag) {
            result |= UInt32(mask)
        }
        return result
    }

    var label: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map { $0.1 }.joined() + Self.keys[keyCode]!.label
    }
}

struct ApplicationID: Hashable {
    let rawValue: String
    // Bundle IDs use dot-separated ASCII alphanumeric/hyphen components, each starting alphanumeric.
    init?(_ value: String) {
        guard value.range(of: "\\A[A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9][A-Za-z0-9-]*)+\\z",
                          options: .regularExpression) != nil else { return nil }
        rawValue = value
    }
}

struct TargetApplication {
    let pid: pid_t
    let id: ApplicationID
}

struct PointerTargetResolver {
    private let windowInfo: (CGWindowID) -> [[String: Any]]?
    private let bundleIdentifier: (pid_t) -> String?

    init(windowInfo: @escaping (CGWindowID) -> [[String: Any]]? = {
        CGWindowListCopyWindowInfo(.optionIncludingWindow, $0) as? [[String: Any]]
    }, bundleIdentifier: @escaping (pid_t) -> String? = {
        NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
    }) {
        self.windowInfo = windowInfo
        self.bundleIdentifier = bundleIdentifier
    }

    func application(forWindow number: Int) -> TargetApplication? {
        func positiveInteger(_ value: Any?, maximum: Double) -> Double? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            return value.isFinite && value.rounded() == value && (1...maximum).contains(value) ? value : nil
        }
        guard number > 0, UInt64(number) <= UInt64(CGWindowID.max),
              let info = windowInfo(CGWindowID(number))?.first(where: {
                  positiveInteger($0[kCGWindowNumber as String], maximum: Double(CGWindowID.max)) == Double(number)
              }),
              let owner = positiveInteger(info[kCGWindowOwnerPID as String], maximum: Double(pid_t.max)),
              let identifier = bundleIdentifier(pid_t(owner)), let id = ApplicationID(identifier) else { return nil }
        return TargetApplication(pid: pid_t(owner), id: id)
    }
}

struct SelectedApplication {
    let id: ApplicationID
    let name: String

    init(url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let bundle = Bundle(url: url), bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let executable = bundle.executableURL,
              (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath: executable.path),
              let identifier = bundle.bundleIdentifier, let id = ApplicationID(identifier) else {
            throw Failure("Choose a local .app package with a valid bundle ID and executable. Nothing was changed.")
        }
        self.id = id
        name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
    }
}

struct Configuration: Equatable {
    let scroll: ScrollSettings
    let shortcut: Shortcut?
    let excludedApps: Set<ApplicationID>
    init(scroll: ScrollSettings = ScrollSettings(), shortcut: Shortcut? = nil, excludedApps: Set<ApplicationID> = []) {
        self.scroll = scroll
        self.shortcut = shortcut
        self.excludedApps = excludedApps
    }
}

final class ConfigurationStore {
    private let defaults: UserDefaults
    private let suiteName: String
    init(suiteName: String) throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw Failure("cannot open helper settings suite") }
        self.defaults = defaults
        self.suiteName = suiteName
    }

    func load(environment: [String: String]) throws -> Configuration {
        let values = defaults.persistentDomain(forName: suiteName) ?? [:]
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        }
        let saved = number(values["sensitivity"])
        let sensitivity = saved.flatMap { $0.isFinite && (0.05...2).contains($0) ? $0 : nil }
        var seed = environment
        // Saved UI settings outrank even a stale or invalid launch sensitivity override.
        if sensitivity != nil { seed.removeValue(forKey: "PENPAN_SENS") }
        let fallback = try ScrollSettings.environment(seed)
        let reverseValue = values["reversed"] as? NSNumber
        let reversed = reverseValue.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil } ?? false
        var shortcut: Shortcut?
        if let data = values["shortcut"] as? [String: Any], data.count == 2,
           let code = number(data["keyCode"]), let modifiers = number(data["modifiers"]),
           code.isFinite, modifiers.isFinite, code.rounded() == code, modifiers.rounded() == modifiers,
           (0...Double(UInt32.max)).contains(code), (0...Double(UInt32.max)).contains(modifiers) {
            shortcut = try? Shortcut(keyCode: UInt32(code), modifiers: UInt32(modifiers))
        }
        return Configuration(scroll: ScrollSettings(sensitivity: sensitivity ?? fallback.sensitivity,
                                                     threshold: fallback.threshold, reversed: reversed), shortcut: shortcut,
                             excludedApps: Set((values["excludedApps"] as? [String] ?? []).compactMap(ApplicationID.init)))
    }

    func save(_ configuration: Configuration) {
        defaults.set(configuration.scroll.sensitivity, forKey: "sensitivity")
        defaults.set(configuration.scroll.reversed, forKey: "reversed")
        defaults.set(configuration.excludedApps.map(\.rawValue).sorted(), forKey: "excludedApps")
        if let shortcut = configuration.shortcut {
            defaults.set(["keyCode": shortcut.keyCode, "modifiers": shortcut.modifiers], forKey: "shortcut")
        } else {
            defaults.removeObject(forKey: "shortcut")
        }
    }
}

struct HotKeyAPI {
    var check: (Shortcut) throws -> Void
    var register: (Shortcut, UInt32) throws -> EventHotKeyRef
    var unregister: (EventHotKeyRef) throws -> Void
    static let signature: OSType = 0x50504E53

    static func isReserved(_ shortcut: Shortcut) -> Bool {
        (shortcut.modifiers == UInt32(cmdKey) && [12, 13, 4, 46, 48].contains(shortcut.keyCode))
            || (shortcut.modifiers == UInt32(cmdKey | shiftKey) && [12, 48].contains(shortcut.keyCode))
            || (shortcut.modifiers == UInt32(cmdKey | controlKey) && shortcut.keyCode == 12)
    }

    static var native: HotKeyAPI {
        HotKeyAPI(check: { shortcut in
            // Symbolic lookup omits application-specific commands. Do not claim full conflict detection.
            guard !isReserved(shortcut) else { throw Failure("That combination is reserved. Choose another shortcut.") }
            var values: Unmanaged<CFArray>?
            let status = CopySymbolicHotKeys(&values)
            guard status == noErr, let array = values?.takeRetainedValue() as? [[String: Any]] else {
                throw Failure("Cannot check system shortcuts (\(status)). Previous shortcut unchanged.")
            }
            for value in array {
                guard let enabled = value[kHISymbolicHotKeyEnabled as String] as? Bool,
                      let code = value[kHISymbolicHotKeyCode as String] as? NSNumber,
                      let modifiers = value[kHISymbolicHotKeyModifiers as String] as? NSNumber else {
                    throw Failure("Cannot decode system shortcuts. Previous shortcut unchanged.")
                }
                if enabled && code.uint32Value == shortcut.keyCode && modifiers.uint32Value == shortcut.modifiers {
                    throw Failure("That combination is a system shortcut. Choose another shortcut.")
                }
            }
        }, register: { shortcut, id in
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                             EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(),
                                             OptionBits(kEventHotKeyExclusive), &ref)
            guard status == noErr, let ref else { throw Failure("Shortcut unavailable (\(status)). Previous shortcut unchanged.") }
            return ref
        }, unregister: { ref in
            let status = UnregisterEventHotKey(ref)
            guard status == noErr else { throw Failure("Cannot remove shortcut (\(status)).") }
        })
    }
}

final class ShortcutRecording {
    enum State: Equatable { case idle, listening, held(Shortcut) }
    private(set) var state = State.idle
    var changed: () -> Void = {}
    var commit: (Shortcut) -> Void = { _ in }
    var error: (String) -> Void = { _ in }
    var active: Bool { state != .idle }
    func begin() { state = .listening; changed() }
    func cancel() { state = .idle; changed() }
    func press(_ shortcut: Shortcut, repeatKey: Bool = false) {
        guard state == .listening, !repeatKey else { return }
        state = .held(shortcut)
        changed()
    }
    func release(keyCode: UInt32) {
        guard case let .held(shortcut) = state, shortcut.keyCode == keyCode else { return }
        state = .idle
        commit(shortcut)
        changed()
    }
}

final class HotKeyRegistration {
    private final class HandlerContext {
        weak var owner: HotKeyRegistration?
        init(_ owner: HotKeyRegistration) { self.owner = owner }
    }
    private struct Binding {
        let shortcut: Shortcut
        let id: UInt32
        let ref: EventHotKeyRef
        var held = false
    }
    private let api: HotKeyAPI
    private var binding: Binding?
    private var cleanup: [EventHotKeyRef] = []
    private var nextID: UInt32 = 0
    private var handler: EventHandlerRef?
    private var handlerContext: UnsafeMutableRawPointer?
    let recording: ShortcutRecording
    var toggle: () -> Void = {}
    var report: (String) -> Void = { _ in }
    var shortcut: Shortcut? { binding?.shortcut }
    var cleanupPending: Bool { !cleanup.isEmpty }

    init(api: HotKeyAPI, recording: ShortcutRecording) { self.api = api; self.recording = recording }
    deinit { teardown() }

    func installHandler() throws {
        precondition(Thread.isMainThread)
        guard handler == nil else { return }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let context = Unmanaged.passRetained(HandlerContext(self)).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let box = Unmanaged<HandlerContext>.fromOpaque(context).takeUnretainedValue()
            return box.owner?.dispatch(event) ?? OSStatus(eventNotHandledErr)
        }, types.count, &types, context, &handler)
        guard status == noErr else {
            Unmanaged<HandlerContext>.fromOpaque(context).release()
            throw Failure("Cannot install shortcut handler (\(status)).")
        }
        handlerContext = context
    }

    func dispatch(_ event: EventRef) -> OSStatus {
        precondition(Thread.isMainThread)
        guard GetEventClass(event) == OSType(kEventClassKeyboard),
              [UInt32(kEventHotKeyPressed), UInt32(kEventHotKeyReleased)].contains(GetEventKind(event)) else {
            return OSStatus(eventNotHandledErr)
        }
        var id = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == HotKeyAPI.signature, id.id == binding?.id else {
            return OSStatus(eventNotHandledErr)
        }
        receive(id: id.id, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
        return noErr
    }

    func replace(with candidate: Shortcut?) throws {
        precondition(Thread.isMainThread)
        guard candidate != binding?.shortcut else { return }
        var replacement: Binding?
        if let candidate {
            try api.check(candidate)
            guard nextID < UInt32.max else { throw Failure("Shortcut IDs exhausted. Restart the helper.") }
            nextID += 1
            replacement = try Binding(shortcut: candidate, id: nextID, ref: api.register(candidate, nextID))
        }
        do {
            if let binding { try api.unregister(binding.ref) }
        } catch {
            if let replacement {
                do { try api.unregister(replacement.ref) }
                catch {
                    cleanup.append(replacement.ref)
                    report("Candidate cleanup failed: \(error). Quit to release remaining reservation.")
                }
            }
            throw error
        }
        binding = replacement
    }

    func receive(id: UInt32, pressed: Bool) {
        precondition(Thread.isMainThread)
        guard var current = binding, current.id == id else { return }
        if pressed {
            guard !current.held else { return }
            current.held = true
            binding = current
            if recording.active { recording.press(current.shortcut) } else { toggle() }
        } else {
            current.held = false
            binding = current
            if recording.active { recording.release(keyCode: current.shortcut.keyCode) }
        }
    }

    func teardown() {
        precondition(Thread.isMainThread)
        var remaining = cleanup
        if let binding { remaining.append(binding.ref) }
        binding = nil
        cleanup = []
        for ref in remaining {
            do { try api.unregister(ref) }
            catch { cleanup.append(ref); report("Shortcut cleanup failed: \(error). Process exit releases it.") }
        }
        if let handler {
            let status = RemoveEventHandler(handler)
            if status == noErr {
                self.handler = nil
                if let handlerContext { Unmanaged<HandlerContext>.fromOpaque(handlerContext).release() }
                handlerContext = nil
            } else {
                // A failed removal keeps its weak context alive, never a dangling owner pointer.
                report("Cannot remove shortcut handler (\(status)).")
            }
        }
    }
}

final class ShortcutRecorder: NSButton {
    let recording: ShortcutRecording
    override var acceptsFirstResponder: Bool { true }
    init(recording: ShortcutRecording) {
        self.recording = recording
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording(_:))
        setAccessibilityIdentifier("penpan.shortcut.recorder")
        setAccessibilityLabel("Toggle shortcut recorder")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func startRecording(_ sender: Any?) {
        guard window?.isKeyWindow == true, window?.makeFirstResponder(self) == true else { return }
        recording.begin()
    }
    override func resignFirstResponder() -> Bool { recording.cancel(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording.active, window?.isKeyWindow == true, window?.firstResponder === self else { return false }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording.active, window?.isKeyWindow == true, window?.firstResponder === self else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { recording.cancel(); return }
        guard !event.isARepeat else { return }
        do {
            let shortcut = try Shortcut(keyCode: UInt32(event.keyCode), modifiers: Shortcut.carbonModifiers(event.modifierFlags))
            recording.press(shortcut)
        } catch { recording.error(String(describing: error)) }
    }
    override func keyUp(with event: NSEvent) {
        guard recording.active, window?.isKeyWindow == true, window?.firstResponder === self else {
            super.keyUp(with: event)
            return
        }
        recording.release(keyCode: UInt32(event.keyCode))
    }
    func routeCommandRelease(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyUp, event.modifierFlags.contains(.command), recording.active,
              window?.isKeyWindow == true, window?.firstResponder === self else { return event }
        keyUp(with: event)
        return nil
    }
}

final class SettingsControl: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    let status = NSTextField(wrappingLabelWithString: "")
    let toggle = NSButton(title: "", target: nil, action: nil)
    let sensitivity: NSSlider
    let value = NSTextField(labelWithString: "")
    let reverse = NSButton(checkboxWithTitle: "Reverse scroll direction", target: nil, action: nil)
    let recorder: ShortcutRecorder
    let clear = NSButton(title: "Clear", target: nil, action: nil)
    let message = NSTextField(wrappingLabelWithString: "")
    let applications = NSTableView()
    let applicationScroll = NSScrollView()
    let add = NSButton(title: "Add application…", target: nil, action: nil)
    let removeSelected = NSButton(title: "Remove selected", target: nil, action: nil)
    let applicationMessage = NSTextField(wrappingLabelWithString: "")
    private(set) var applicationRows: [ApplicationID] = []
    private var applicationNames: [ApplicationID: String] = [:]
    private(set) var applicationPanel: NSOpenPanel?
    var presentApplicationPanel: (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
        $0.beginSheetModal(for: $1, completionHandler: $2)
    }
    var selectedApplicationURL: (NSOpenPanel) -> URL? = { $0.url }
    private unowned let session: LiveSession
    private var deactivateObserver: NSObjectProtocol?
    private var commandReleaseMonitor: Any?

    init(session: LiveSession, window: NSWindow? = nil) {
        self.session = session
        self.window = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sensitivity = NSSlider(value: session.configuration.scroll.sensitivity, minValue: 0.05, maxValue: 2,
                               target: nil, action: nil)
        recorder = ShortcutRecorder(recording: session.recording)
        super.init()
        self.window.title = "Pen Pan Settings"
        self.window.isReleasedWhenClosed = false
        self.window.identifier = NSUserInterfaceItemIdentifier("penpan.settings.window")
        self.window.setAccessibilityIdentifier("penpan.settings.window")
        self.window.delegate = self
        status.setAccessibilityIdentifier("penpan.status")
        toggle.target = self
        toggle.action = #selector(toggleEnabled(_:))
        toggle.setAccessibilityIdentifier("penpan.toggle")
        toggle.setAccessibilityLabel("Toggle pen scrolling")
        sensitivity.isContinuous = true
        sensitivity.target = self
        sensitivity.action = #selector(scrollChanged(_:))
        sensitivity.setAccessibilityIdentifier("penpan.sensitivity.slider")
        sensitivity.setAccessibilityLabel("Scroll sensitivity")
        value.setAccessibilityIdentifier("penpan.sensitivity.value")
        reverse.target = self
        reverse.action = #selector(scrollChanged(_:))
        reverse.setAccessibilityIdentifier("penpan.reverse.checkbox")
        clear.target = self
        clear.action = #selector(clearShortcut(_:))
        clear.setAccessibilityIdentifier("penpan.shortcut.clear")
        message.setAccessibilityIdentifier("penpan.settings.message")
        applications.setAccessibilityIdentifier("penpan.exclusions.list")
        applications.setAccessibilityLabel("Excluded applications, native input while ON")
        applications.headerView = nil
        applications.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("application")))
        applications.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        applications.rowHeight = 44
        applications.allowsMultipleSelection = false
        applications.allowsEmptySelection = true
        applications.dataSource = self
        applications.delegate = self
        applicationScroll.documentView = applications
        applicationScroll.hasVerticalScroller = true
        applicationScroll.borderType = .bezelBorder
        for (button, identifier, action) in [
            (add, "penpan.exclusions.add", #selector(addApplication(_:))),
            (removeSelected, "penpan.exclusions.remove", #selector(removeApplication(_:)))
        ] {
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(identifier)
        }
        applicationMessage.setAccessibilityIdentifier("penpan.exclusions.message")
        func heading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            return label
        }
        let statusRow = NSStackView(views: [status, toggle])
        statusRow.distribution = .fill
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sensitivityRow = NSStackView(views: [NSTextField(labelWithString: "Sensitivity"), sensitivity, value])
        let scrollHint = NSTextField(labelWithString: "Changes apply after pen release.")
        scrollHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scrollHint.textColor = .secondaryLabelColor
        let reverseRow = NSStackView(views: [reverse, scrollHint])
        let shortcutRow = NSStackView(views: [recorder, clear])
        let hint = NSTextField(wrappingLabelWithString: "Press and release Control, Option or Command + key, or F13–F20 alone. Esc cancels. Physical US key names; other apps' commands may conflict.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let exclusionHint = NSTextField(labelWithString: "Keep handwriting and native drags in these apps while ON.")
        exclusionHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let applicationActions = NSStackView(views: [add, removeSelected])
        let stack = NSStackView(views: [statusRow, heading("Scrolling"), sensitivityRow, reverseRow,
                                        heading("Toggle shortcut"), shortcutRow, hint, message,
                                        heading("Excluded apps"), exclusionHint, applicationScroll,
                                        applicationActions, applicationMessage])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: self.window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: self.window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: self.window.contentView!.bottomAnchor, constant: -20),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.heightAnchor.constraint(equalToConstant: 36),
            toggle.widthAnchor.constraint(equalToConstant: 110),
            sensitivity.widthAnchor.constraint(equalToConstant: 280),
            value.widthAnchor.constraint(equalToConstant: 56),
            recorder.widthAnchor.constraint(equalToConstant: 220),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.heightAnchor.constraint(equalToConstant: 34),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.heightAnchor.constraint(equalToConstant: 64),
            applicationScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            applicationScroll.heightAnchor.constraint(equalToConstant: 104),
            applicationMessage.widthAnchor.constraint(equalTo: stack.widthAnchor),
            applicationMessage.heightAnchor.constraint(equalToConstant: 34)
        ])
        let keyViews: [NSView] = [toggle, sensitivity, reverse, recorder, clear, applications, add, removeSelected]
        self.window.autorecalculatesKeyViewLoop = false
        for index in keyViews.indices { keyViews[index].nextKeyView = keyViews[(index + 1) % keyViews.count] }
        self.window.initialFirstResponder = toggle
        session.recording.changed = { [weak self] in self?.refresh() }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                    object: NSApplication.shared, queue: .main) { [weak session] _ in
            session?.recording.cancel()
        }
        // AppKit can drop Command-key releases before dispatching them to a window.
        commandReleaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self else { return event }
            return self.recorder.routeCommandRelease(event)
        }
        applicationMessage.stringValue = "No excluded apps. Add an application to keep its native pen input."
        refresh()
    }

    deinit {
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        if let commandReleaseMonitor { NSEvent.removeMonitor(commandReleaseMonitor) }
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        refresh()
    }
    func refreshStatus() {
        let lifecycle = session.lifecycle
        guard status.stringValue != lifecycle.status else { return }
        status.stringValue = lifecycle.status
        toggle.title = lifecycle.mode == .on ? "Turn OFF" : (lifecycle.observing ? "Turn ON" : "Retry ON")
        toggle.isEnabled = lifecycle.mode != .quitting
    }
    func refresh() {
        refreshStatus()
        let scroll = session.configuration.scroll
        sensitivity.doubleValue = scroll.sensitivity
        value.stringValue = String(format: "%.2fx", scroll.sensitivity)
        reverse.state = scroll.reversed ? .on : .off
        switch session.recording.state {
        case .idle: recorder.title = session.configuration.shortcut?.label ?? "Record shortcut…"
        case .listening: recorder.title = "Press a shortcut…"
        case let .held(shortcut): recorder.title = "Release \(shortcut.label)…"
        }
        let inactive = session.configuration.shortcut != nil && session.hotKeys.shortcut == nil
        let cleanup = session.hotKeys.cleanupPending ? "A failed shortcut reservation still needs cleanup. Quit to release it." : nil
        message.stringValue = [session.settingsError ?? (inactive ? "Saved shortcut is inactive." : nil), cleanup]
            .compactMap { $0 }.joined(separator: "\n")
        clear.isEnabled = session.configuration.shortcut != nil
        if Set(applicationRows) != session.configuration.excludedApps {
            let selected = selectedApplication
            applicationRows = session.configuration.excludedApps.sorted { $0.rawValue < $1.rawValue }
            for id in applicationRows where applicationNames[id] == nil {
                let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id.rawValue).flatMap(Bundle.init(url:))
                applicationNames[id] = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? id.rawValue
            }
            applications.reloadData()
            if let selected, let index = applicationRows.firstIndex(of: selected) {
                applications.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else { applications.deselectAll(nil) }
            applicationMessage.stringValue = applicationRows.isEmpty
                ? "No excluded apps. Add an application to keep its native pen input."
                : "Exclusions apply to new pen contacts, not the app with keyboard focus."
        }
        removeSelected.isEnabled = selectedApplication != nil
    }
    private var selectedApplication: ApplicationID? {
        applicationRows.indices.contains(applications.selectedRow) ? applicationRows[applications.selectedRow] : nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int { applicationRows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { removeSelected.isEnabled = selectedApplication != nil }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = applicationRows[row]
        let name = applicationNames[id] ?? id.rawValue
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: name)
        let identifier = NSTextField(labelWithString: id.rawValue)
        identifier.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        identifier.textColor = .secondaryLabelColor
        for label in [title, identifier] {
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6)
            ])
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            identifier.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            identifier.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -2)
        ])
        cell.textField = title
        cell.toolTip = "\(name)\n\(id.rawValue)"
        cell.setAccessibilityLabel("\(name), \(id.rawValue)")
        return cell
    }
    @objc private func toggleEnabled(_ sender: Any?) { session.toggleEnabled() }
    @objc private func scrollChanged(_ sender: Any?) {
        session.setScroll(ScrollSettings(sensitivity: sensitivity.doubleValue,
                                        threshold: session.configuration.scroll.threshold, reversed: reverse.state == .on))
    }
    @objc private func clearShortcut(_ sender: Any?) { session.recording.cancel(); session.setShortcut(nil) }
    @objc private func addApplication(_ sender: Any?) {
        guard applicationPanel == nil, session.lifecycle.mode != .quitting else { return }
        session.recording.cancel()
        let panel = NSOpenPanel()
        panel.title = "Exclude an application"
        panel.prompt = "Add application"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        applicationPanel = panel
        add.isEnabled = false
        presentApplicationPanel(panel, window) { [weak self, weak panel] response in
            guard let self, let panel, self.applicationPanel === panel, self.session.lifecycle.mode != .quitting else { return }
            self.applicationPanel = nil
            self.add.isEnabled = true
            guard response == .OK else {
                self.applicationMessage.stringValue = "Cancelled. No application added."
                return
            }
            do {
                guard let url = self.selectedApplicationURL(panel) else { throw Failure("No application selected. Nothing was changed.") }
                let app = try SelectedApplication(url: url)
                let duplicate = self.session.configuration.excludedApps.contains(app.id)
                self.applicationNames[app.id] = app.name
                if !duplicate { self.session.setExcludedApps(self.session.configuration.excludedApps.union([app.id])) }
                if let row = self.applicationRows.firstIndex(of: app.id) {
                    if duplicate {
                        self.applications.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                    }
                    self.applications.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    self.applications.scrollRowToVisible(row)
                }
                self.applicationMessage.stringValue = duplicate ? "That application is already excluded." : "Added. New contacts in this app keep native pen input."
            } catch { self.applicationMessage.stringValue = String(describing: error) }
        }
    }
    @objc private func removeApplication(_ sender: Any?) {
        guard let id = selectedApplication else { return }
        session.setExcludedApps(session.configuration.excludedApps.subtracting([id]))
    }
    func cancelApplicationPicker() {
        guard let panel = applicationPanel else { return }
        applicationPanel = nil
        add.isEnabled = true
        if panel.sheetParent != nil { window.endSheet(panel, returnCode: .cancel) }
        panel.cancel(nil)
        panel.orderOut(nil)
    }
    func windowDidResignKey(_ notification: Notification) { session.recording.cancel() }
    func windowWillClose(_ notification: Notification) { session.recording.cancel(); cancelApplicationPicker() }
    var ownedWindowNumbers: Set<Int> {
        var numbers: Set<Int> = []
        func collect(_ window: NSWindow) {
            if Self.targetsSettings(visible: window.isVisible, settingsNumber: window.windowNumber, targetNumber: window.windowNumber) {
                numbers.insert(window.windowNumber)
            }
            for child in window.childWindows ?? [] { collect(child) }
            if let sheet = window.attachedSheet, !(window.childWindows ?? []).contains(sheet) { collect(sheet) }
        }
        collect(window)
        if let applicationPanel { collect(applicationPanel) }
        return numbers
    }
    static func targetsSettings(visible: Bool, settingsNumber: Int, targetNumber: Int) -> Bool {
        visible && settingsNumber > 0 && settingsNumber == targetNumber
    }
    func remove() {
        session.recording.cancel()
        session.recording.changed = {}
        cancelApplicationPicker()
        window.orderOut(nil)
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        deactivateObserver = nil
        if let commandReleaseMonitor { NSEvent.removeMonitor(commandReleaseMonitor) }
        commandReleaseMonitor = nil
    }
}

enum Route {
    case pass, consume
    case click(down: CGEvent, up: CGEvent, count: Int64)
    case scroll(x: Int32, y: Int32)
}

struct Gesture {
    private struct Contact {
        let down: CGEvent
        let origin: CGPoint
        let settings: ScrollSettings
        var last: CGPoint
        var remainder = CGVector.zero
    }
    private enum State {
        case idle, pending(Contact), panning(Contact), cancelledUntilRelease
    }
    private struct Tap {
        let timestamp: CGEventTimestamp
        let sourceCount: Int64
        let count: Int64
    }
    private var state = State.idle
    private var lastTap: Tap?
    private(set) var stopRequested = false
    var settings: ScrollSettings
    let doubleClickInterval: Double

    init(settings: ScrollSettings = ScrollSettings(), doubleClickInterval: Double = NSEvent.doubleClickInterval) {
        self.settings = settings
        self.doubleClickInterval = doubleClickInterval
    }

    var stopped: Bool {
        if case .idle = state { return stopRequested }
        return false
    }

    mutating func cancel() {
        lastTap = nil
        switch state {
        case .idle:
            break
        default:
            state = stopRequested ? .idle : .cancelledUntilRelease
        }
    }

    mutating func requestStop() {
        stopRequested = true
        lastTap = nil
        if case .idle = state { return }
        state = .cancelledUntilRelease
    }

    mutating func step(_ type: CGEventType, _ event: CGEvent) -> Route {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancel()
            return .consume
        }
        guard type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp else {
            return .pass
        }
        let subtype = event.getIntegerValueField(.mouseEventSubtype)
        let isPen = subtype == 1
        if type == .leftMouseDown && isPen {
            guard !stopRequested else { return .consume }
            if case .idle = state {} else { lastTap = nil }
            guard event.location.x.isFinite, event.location.y.isFinite,
                  let down = event.copy() else {
                cancel()
                return .consume
            }
            state = .pending(Contact(down: down, origin: down.location, settings: settings, last: down.location))
            return .consume
        }
        switch state {
        case .idle:
            return isPen ? .consume : .pass
        case .cancelledUntilRelease:
            // No device identity is available. A subtype-0 up may be a real mouse release.
            if type == .leftMouseUp && (isPen || subtype == 0) {
                state = .idle
                return .consume
            }
            return isPen ? .consume : .pass
        case .pending(var contact), .panning(var contact):
            let release = type == .leftMouseUp && (isPen || subtype == 0)
            guard isPen || release else { return .pass }
            defer { if release { state = .idle } }
            let point = event.location
            guard point.x.isFinite, point.y.isFinite else {
                cancel()
                return .consume
            }
            let wasPanning: Bool
            if case .panning = state { wasPanning = true } else { wasPanning = false }
            let panning = wasPanning || hypot(point.x - contact.origin.x,
                                              point.y - contact.origin.y) >= contact.settings.threshold
            if !panning {
                if release {
                    // Native source counts encode spatial grouping; cancelled contacts never count as clicks.
                    let sourceCount = contact.down.getIntegerValueField(.mouseEventClickState)
                    var count: Int64 = 1
                    if let previous = lastTap, sourceCount > 1,
                       previous.sourceCount < Int64.max, sourceCount == previous.sourceCount + 1,
                       contact.down.timestamp >= previous.timestamp,
                       Double(contact.down.timestamp - previous.timestamp) / 1e9 <= doubleClickInterval {
                        count = previous.count + 1
                    }
                    lastTap = Tap(timestamp: contact.down.timestamp, sourceCount: sourceCount, count: count)
                    return .click(down: contact.down, up: event, count: count)
                }
                return .consume
            }
            lastTap = nil
            // Pending motion is emitted once in full; later deltas use consecutive points.
            let anchor = wasPanning ? contact.last : contact.origin
            let scale = contact.settings.sensitivity * (contact.settings.reversed ? -1 : 1)
            contact.remainder.dx += (point.x - anchor.x) * scale
            contact.remainder.dy += (point.y - anchor.y) * scale
            guard contact.remainder.dx.isFinite, contact.remainder.dy.isFinite else {
                cancel()
                return .consume
            }
            func pixels(_ value: Double) -> Int32 {
                Int32(min(Double(Int32.max), max(Double(Int32.min), value.rounded(.towardZero))))
            }
            let x = pixels(contact.remainder.dx)
            let y = pixels(contact.remainder.dy)
            contact.remainder.dx -= Double(x)
            contact.remainder.dy -= Double(y)
            contact.last = point
            state = .panning(contact)
            return x == 0 && y == 0 ? .consume : .scroll(x: x, y: y)
        }
    }
}

final class EventAdapter {
    var gesture: Gesture
    // Injection covers allocation failure without ever posting globally in tests.
    var copyEvent: (CGEvent) -> CGEvent? = { $0.copy() }
    var makeScroll: (Int32, Int32) -> CGEvent? = { x, y in
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: y, wheel2: x, wheel3: 0)
    }

    init(gesture: Gesture = Gesture()) { self.gesture = gesture }

    func handle(_ type: CGEventType, _ event: CGEvent,
                post: (CGEvent) -> Void, reenable: () -> Void = {}) -> CGEvent? {
        let route = gesture.step(type, event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if !gesture.stopRequested { reenable() }
        }
        switch route {
        case .pass:
            return event
        case .consume:
            return nil
        case let .click(down, up, count):
            // Prepare the whole pair first so allocation failure cannot leave a pressed button.
            guard let clickDown = copyEvent(down), let clickUp = copyEvent(up) else {
                gesture.cancel()
                return nil
            }
            for (click, type) in [(clickDown, CGEventType.leftMouseDown), (clickUp, .leftMouseUp)] {
                click.type = type
                click.location = down.location
                click.setIntegerValueField(.mouseEventSubtype, value: 0)
                click.setIntegerValueField(.mouseEventClickState, value: count)
            }
            post(clickDown)
            post(clickUp)
            return nil
        case let .scroll(x, y):
            guard let scroll = makeScroll(x, y) else {
                gesture.cancel()
                return nil
            }
            scroll.location = event.location
            scroll.flags = event.flags
            post(scroll)
            return nil
        }
    }
}

final class InstanceLock {
    private var descriptor: Int32 = -1

    init(path: String) throws {
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure("cannot open instance lock: \(String(cString: strerror(errno)))") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            close(descriptor)
            descriptor = -1
            throw Failure("unsafe instance lock file")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            throw Failure("another pen-pan instance holds the lock")
        }
        // Keep the inode in place. Unlinking it would let another process lock a different inode.
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}

let penEventMask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
    | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)

// Contact disposition stays fixed across toggles, until release or an observed post-disable down.
final class Lifecycle {
    enum Mode { case off, on, quitting }
    enum Contact: Equatable {
        case untracked, idle, passed, owned
        case draining(interrupted: Bool)
    }
    enum Observation {
        case unavailable(String?), active
    }
    private(set) var mode = Mode.off
    private(set) var contact = Contact.untracked
    private(set) var observation = Observation.unavailable(nil)
    let adapter: EventAdapter
    var passesNewContact: (CGEvent) -> Bool = { _ in false }

    init(adapter: EventAdapter = EventAdapter()) { self.adapter = adapter }

    var observing: Bool {
        if case .active = observation { return true }
        return false
    }
    var finished: Bool {
        guard mode == .quitting else { return false }
        switch contact {
        case .owned, .draining: return false
        default: return true
        }
    }
    var status: String {
        if mode == .quitting { return finished ? "Quitting" : "Quitting, waiting for release" }
        if case let .unavailable(error) = observation {
            return error.map { "OFF: \($0)" } ?? "OFF, not observing"
        }
        switch contact {
        case .draining: return mode == .on ? "ON, waiting for release" : "OFF, draining"
        case .passed where mode == .on: return "ON, waiting for release"
        default: return mode == .on ? "ON" : "OFF"
        }
    }

    func observationStarted(leftButtonHeld: Bool) {
        observation = .active
        contact = leftButtonHeld ? .passed : .untracked
    }

    func observationFailed(_ error: Error) {
        observation = .unavailable(String(describing: error))
        setEnabled(false)
    }

    func setEnabled(_ enabled: Bool) {
        guard mode != .quitting, !enabled || observing else { return }
        let next: Mode = enabled ? .on : .off
        guard mode != next else { return }
        mode = next
        if !enabled { cancelOwnedContact() }
    }

    func requestQuit() {
        guard mode != .quitting else { return }
        mode = .quitting
        cancelOwnedContact()
    }

    private func cancelOwnedContact() {
        adapter.gesture.cancel()
        if contact == .owned { contact = .draining(interrupted: false) }
    }

    private func resetGesture() {
        adapter.gesture = Gesture(settings: adapter.gesture.settings,
                                  doubleClickInterval: adapter.gesture.doubleClickInterval)
    }

    func handle(_ type: CGEventType, _ event: CGEvent,
                post: (CGEvent) -> Void, reenable: () -> Void = {}) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            adapter.gesture.cancel()
            switch contact {
            case .owned, .draining: contact = .draining(interrupted: true)
            case .passed: contact = .untracked
            default: break
            }
            if !finished { reenable() }
            return nil
        }
        guard type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp else {
            return event
        }
        let subtype = event.getIntegerValueField(.mouseEventSubtype)
        let isPen = subtype == 1
        guard isPen || subtype == 0 else { return event }
        let release = type == .leftMouseUp
        if case let .draining(interrupted) = contact {
            if interrupted && type == .leftMouseDown && isPen {
                // A fresh down is the only recovery boundary when a disabled interval hid release.
                resetGesture()
                contact = .idle
            } else {
                if release { resetGesture(); contact = .idle }
                return isPen || release ? nil : event
            }
        }
        if contact == .passed {
            if release { contact = .idle }
            return event
        }
        if contact == .owned {
            defer { if release { contact = .idle } }
            return adapter.handle(type, event, post: post)
        }
        if type == .leftMouseDown {
            if isPen && mode == .on && observing && !passesNewContact(event) {
                contact = .owned
                return adapter.handle(type, event, post: post)
            }
            contact = .passed
        } else if release {
            contact = .idle
        }
        // Startup drags/releases were never ours. Preserve their original objects.
        return event
    }
}

final class LiveSession {
    let lifecycle: Lifecycle
    private(set) var configuration: Configuration
    private let store: ConfigurationStore?
    let recording: ShortcutRecording
    let hotKeys: HotKeyRegistration
    private(set) var settingsControl: SettingsControl?
    private(set) var settingsError: String?
    private(set) var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let runLoop = CFRunLoopGetCurrent()
    var changed: () -> Void = {}
    var windowAtPoint: (CGPoint) -> Int = { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) }
    var targetResolver = PointerTargetResolver()

    func notifyChanged() {
        settingsControl?.refreshStatus()
        changed()
    }

    private func passesNewContact(_ event: CGEvent) -> Bool {
        let windows = settingsControl?.ownedWindowNumbers ?? []
        let exclusions = configuration.excludedApps
        guard !windows.isEmpty || !exclusions.isEmpty else { return false }
        let window = windowAtPoint(event.unflippedLocation)
        if windows.contains(window) { return true }
        guard !exclusions.isEmpty else { return false }
        guard let application = targetResolver.application(forWindow: window) else { return true }
        return exclusions.contains(application.id)
    }
    // The failure seam lets tests exercise installation errors without installing a global tap.
    var createTap: (CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort? = { callback, context in
        CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                          options: .defaultTap, eventsOfInterest: penEventMask,
                          callback: callback, userInfo: context)
    }

    init(configuration: Configuration = Configuration(), store: ConfigurationStore? = nil, hotKeyAPI: HotKeyAPI = .native) {
        self.configuration = configuration
        self.store = store
        recording = ShortcutRecording()
        hotKeys = HotKeyRegistration(api: hotKeyAPI, recording: recording)
        lifecycle = Lifecycle(adapter: EventAdapter(gesture: Gesture(settings: configuration.scroll)))
        lifecycle.passesNewContact = { [weak self] in self?.passesNewContact($0) ?? false }
        recording.commit = { [weak self] in self?.setShortcut($0) }
        recording.error = { [weak self] in self?.reportSettingsError($0) }
        hotKeys.toggle = { [weak self] in self?.toggleEnabled() }
        hotKeys.report = { [weak self] in self?.reportSettingsError($0) }
    }

    private func reportSettingsError(_ message: String) {
        FileHandle.standardError.write(Data("pen-pan settings: \(message)\n".utf8))
        settingsError = message
        settingsControl?.refresh()
        notifyChanged()
    }

    func setScroll(_ scroll: ScrollSettings) {
        guard lifecycle.mode != .quitting, scroll.sensitivity.isFinite,
              (0.05...2).contains(scroll.sensitivity) else { return }
        configuration = Configuration(scroll: scroll, shortcut: configuration.shortcut, excludedApps: configuration.excludedApps)
        lifecycle.adapter.gesture.settings = scroll
        store?.save(configuration)
        settingsControl?.refresh()
        notifyChanged()
    }

    func setShortcut(_ shortcut: Shortcut?) {
        guard lifecycle.mode != .quitting else { return }
        settingsError = nil
        do {
            try hotKeys.installHandler()
            try hotKeys.replace(with: shortcut)
            configuration = Configuration(scroll: configuration.scroll, shortcut: shortcut, excludedApps: configuration.excludedApps)
            store?.save(configuration)
            if hotKeys.cleanupPending { reportSettingsError("A failed shortcut reservation still needs cleanup. Quit to release it.") }
        } catch { reportSettingsError(String(describing: error)) }
        settingsControl?.refresh()
        notifyChanged()
    }

    func setExcludedApps(_ applications: Set<ApplicationID>) {
        guard lifecycle.mode != .quitting, applications != configuration.excludedApps else { return }
        configuration = Configuration(scroll: configuration.scroll, shortcut: configuration.shortcut, excludedApps: applications)
        store?.save(configuration)
        settingsControl?.refresh()
        notifyChanged()
    }

    func startHotKeys() {
        do {
            try hotKeys.installHandler()
            try hotKeys.replace(with: configuration.shortcut)
        } catch { reportSettingsError("Saved shortcut inactive: \(error)") }
    }

    func prepareSettings(window: NSWindow? = nil) {
        if settingsControl == nil { settingsControl = SettingsControl(session: self, window: window) }
    }

    func showSettings() {
        guard lifecycle.mode != .quitting else { return }
        prepareSettings()
        settingsControl?.show()
    }

    func toggleEnabled() {
        guard lifecycle.mode != .quitting else { return }
        defer { notifyChanged() }
        if lifecycle.mode == .on {
            lifecycle.setEnabled(false)
        } else {
            do {
                if !lifecycle.observing { try attach() }
                lifecycle.setEnabled(true)
            } catch { return }
        }
    }

    func attach() throws {
        guard tap == nil else { return }
        let callback: CGEventTapCallBack = { proxy, type, event, context in
            let session = Unmanaged<LiveSession>.fromOpaque(context!).takeUnretainedValue()
            let result = session.lifecycle.handle(type, event, post: { $0.tapPostEvent(proxy) }, reenable: {
                if let tap = session.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            })
            session.notifyChanged()
            return result.map { Unmanaged.passUnretained($0) }
        }
        do {
            guard let tap = createTap(callback, Unmanaged.passUnretained(self).toOpaque()) else {
                throw Failure("could not create event tap; no permission changes were requested")
            }
            self.tap = tap
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                teardown()
                throw Failure("could not create event-tap run-loop source")
            }
            self.source = source
            lifecycle.observationStarted(leftButtonHeld: CGEventSource.buttonState(.combinedSessionState, button: .left))
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } catch {
            lifecycle.observationFailed(error)
            notifyChanged()
            throw error
        }
        notifyChanged()
    }

    func requestQuit() {
        lifecycle.requestQuit()
        recording.cancel()
        hotKeys.teardown()
        settingsControl?.remove()
        notifyChanged()
    }

    func teardown() {
        recording.cancel()
        hotKeys.teardown()
        settingsControl?.remove()
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        source = nil
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
    }

    func run(menu: Bool = false) throws {
        // AppKit dispatches Carbon hotkey events in both menu and headless modes.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let control = menu ? MenuControl(session: self,
                                        statusItem: NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)) : nil
        defer { teardown(); control?.remove(); changed = {} }
        changed = { [weak self, weak control] in
            control?.refresh()
            guard self?.lifecycle.finished == true else { return }
            app.stop(nil)
            // Wake AppKit's next-event wait using only an application-local event.
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                            modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, subtype: 0, data1: 0, data2: 0) {
                app.postEvent(wake, atStart: true)
            }
        }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                    self?.requestQuit()
                }
                CFRunLoopWakeUp(runLoop)
            }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        startHotKeys()
        if menu {
            do { try attach() } catch { /* The menu exposes the error and retries on ON. */ }
            control?.refresh()
        } else {
            try attach()
            lifecycle.setEnabled(true)
            print("pen-pan running. Ctrl-C or SIGTERM cancels output and exits after pen release.")
        }
        app.run()
    }
}

final class MenuControl: NSObject {
    let menu = NSMenu()
    let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let toggle = NSMenuItem(title: "", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
    let settings = NSMenuItem(title: "Settings...", action: #selector(openSettings(_:)), keyEquivalent: "")
    let quit = NSMenuItem(title: "Quit", action: #selector(quitSession(_:)), keyEquivalent: "")
    private let session: LiveSession
    private let statusItem: NSStatusItem?

    init(session: LiveSession, statusItem: NSStatusItem? = nil) {
        self.session = session
        self.statusItem = statusItem
        super.init()
        menu.autoenablesItems = false
        status.isEnabled = false
        toggle.target = self
        quit.target = self
        settings.target = self
        settings.setAccessibilityIdentifier("penpan.settings.menu")
        [status, toggle, settings, quit].forEach { menu.addItem($0) }
        statusItem?.menu = menu
        refresh()
    }

    func refresh() {
        let lifecycle = session.lifecycle
        let title = lifecycle.status
        guard status.title != title else { return }
        status.title = title
        statusItem?.button?.title = lifecycle.mode == .quitting ? "Pen Pan: Quitting"
            : (lifecycle.mode == .on && lifecycle.observing ? "Pen Pan: ON" : "Pen Pan: OFF")
        toggle.state = lifecycle.mode == .on && lifecycle.observing ? .on : .off
        toggle.title = toggle.state == .on ? "Turn OFF" : (lifecycle.observing ? "Turn ON" : "Retry ON")
        toggle.isEnabled = lifecycle.mode != .quitting
        quit.isEnabled = lifecycle.mode != .quitting
        settings.isEnabled = lifecycle.mode != .quitting
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) { session.toggleEnabled(); refresh() }
    @objc private func openSettings(_ sender: NSMenuItem) { session.showSettings() }

    @objc private func quitSession(_ sender: NSMenuItem) { session.requestQuit(); refresh() }

    func remove() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}

#if !TESTING
@main
struct PenPan {
    static func main() {
        guard CommandLine.arguments.count == 2,
              ["--run", "--menu"].contains(CommandLine.arguments[1]) else {
            print("Usage: pen-pan --menu | --run\nNo input tap is installed without --menu or --run.\n--menu starts OFF with a native ON/OFF menu and Quit.\n--run starts ON; stop with Ctrl-C or SIGTERM, then lift the pen.\nSettings... has live ON/OFF, scrolling, an optional toggle shortcut and excluded apps.\nFresh sensitivity is 0.30x; threshold is 6px. No default shortcut or excluded apps.\nRecord Control/Option/Command + key, or explicitly choose F13-F20 alone.\nSaved UI sensitivity outranks PENPAN_SENS; PENPAN_DEADZONE seeds the threshold.")
            return
        }
        do {
            let store = try ConfigurationStore(suiteName: "local.pen-pan")
            let configuration = try store.load(environment: ProcessInfo.processInfo.environment)
            let lock = try InstanceLock(path: "/tmp/pen-pan-\(getuid()).lock")
            try withExtendedLifetime(lock) {
                try LiveSession(configuration: configuration, store: store).run(menu: CommandLine.arguments[1] == "--menu")
            }
        } catch {
            FileHandle.standardError.write(Data("pen-pan: \(error)\n".utf8))
            exit(1)
        }
    }
}
#endif
