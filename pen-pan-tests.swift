import AppKit
import CoreGraphics
import Darwin
import Carbon

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw Failure(message) }
}

private func mouse(_ type: CGEventType, _ x: Double = 100, _ y: Double = 100,
                   subtype: Int64 = 1, count: Int64 = 1, time: Double = 1,
                   flags: CGEventFlags = []) -> CGEvent {
    let event = CGEvent(mouseEventSource: nil, mouseType: type,
                        mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)!
    event.setIntegerValueField(.mouseEventSubtype, value: subtype)
    event.setIntegerValueField(.mouseEventClickState, value: count)
    event.timestamp = UInt64(time * 1e9)
    event.flags = flags
    return event
}

private final class Trace {
    let adapter: EventAdapter
    var output: [CGEvent] = []
    var reenables = 0
    init(settings: ScrollSettings = ScrollSettings(sensitivity: 1, threshold: 2)) {
        adapter = EventAdapter(gesture: Gesture(settings: settings, doubleClickInterval: 0.5))
    }
    func send(_ event: CGEvent, as type: CGEventType? = nil) {
        if let forwarded = adapter.handle(type ?? event.type, event, post: { self.output.append($0) },
                                          reenable: { self.reenables += 1 }) {
            output.append(forwarded)
        }
    }
    func tap(count: Int64 = 1, time: Double = 1, x: Double = 100) {
        send(mouse(.leftMouseDown, x, count: count, time: time))
        send(mouse(.leftMouseUp, x, count: count, time: time + 0.05))
    }
    var types: [CGEventType] { output.map(\.type) }
    var xs: [Int64] { output.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) } }
    var ys: [Int64] { output.map { $0.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) } }
    var counts: [Int64] { output.map { $0.getIntegerValueField(.mouseEventClickState) } }
}

private final class LifecycleTrace {
    let lifecycle: Lifecycle
    var adapter: EventAdapter { lifecycle.adapter }
    var output: [CGEvent] = []
    var reenables = 0

    init(enabled: Bool = true, held: Bool = false, settings: ScrollSettings = ScrollSettings(sensitivity: 1, threshold: 2)) {
        lifecycle = Lifecycle(adapter: EventAdapter(gesture: Gesture(settings: settings, doubleClickInterval: 0.5)))
        lifecycle.observationStarted(leftButtonHeld: held)
        lifecycle.setEnabled(enabled)
    }
    init(session: LiveSession, enabled: Bool = true) {
        lifecycle = session.lifecycle
        lifecycle.observationStarted(leftButtonHeld: false)
        lifecycle.setEnabled(enabled)
    }
    @discardableResult
    func send(_ event: CGEvent, as type: CGEventType? = nil) -> CGEvent? {
        let forwarded = lifecycle.handle(type ?? event.type, event, post: { self.output.append($0) },
                                         reenable: { self.reenables += 1 })
        if let forwarded { output.append(forwarded) }
        return forwarded
    }
    func tap(count: Int64 = 1, time: Double = 1) {
        send(mouse(.leftMouseDown, count: count, time: time))
        send(mouse(.leftMouseUp, count: count, time: time + 0.05))
    }
    var types: [CGEventType] { output.map(\.type) }
    var counts: [Int64] { output.map { $0.getIntegerValueField(.mouseEventClickState) } }
}

private final class FakeHotKeys {
    var checked: [Shortcut] = []
    var registered: [(Shortcut, UInt32)] = []
    var removed: [EventHotKeyRef] = []
    var operations: [String] = []
    var active: [EventHotKeyRef: Shortcut] = [:]
    var conflict: Set<UInt32> = []
    var failCheck = false
    var failRemoval: Set<EventHotKeyRef> = []
    var api: HotKeyAPI {
        HotKeyAPI(check: { shortcut in
            self.checked.append(shortcut)
            if self.failCheck { throw Failure("injected symbolic lookup failure") }
        }, register: { shortcut, id in
            self.registered.append((shortcut, id))
            self.operations.append("register \(id)")
            if self.conflict.contains(shortcut.keyCode) { throw Failure("injected exclusive conflict") }
            let ref = EventHotKeyRef(bitPattern: Int(id) + 1000)!
            self.active[ref] = shortcut
            return ref
        }, unregister: { ref in
            self.removed.append(ref)
            self.operations.append("remove")
            if self.failRemoval.contains(ref) { throw Failure("injected removal failure") }
            self.active.removeValue(forKey: ref)
        })
    }
}

@main
struct PenPanTests {
    private static var failures = 0
    private static var tests = 0

    private static func test(_ name: String, _ body: () throws -> Void) {
        tests += 1
        do { try body(); print("PASS \(name)") }
        catch { failures += 1; print("FAIL \(name): \(error)") }
    }

    private static func offline() {
        test("stationary tap defers down and delivers one ordinary pair at origin") {
            let trace = Trace()
            let down = mouse(.leftMouseDown, flags: .maskShift)
            trace.send(down)
            try require(trace.output.isEmpty, "early application mouseDown")
            trace.send(mouse(.leftMouseUp, flags: .maskCommand))
            try require(trace.types == [.leftMouseDown, .leftMouseUp], "not exactly one pair")
            try require(trace.output.allSatisfy { $0.location == down.location }, "wrong click target")
            try require(trace.output.allSatisfy { $0.getIntegerValueField(.mouseEventSubtype) == 0 }, "not ordinary mouse subtype")
            try require(trace.output[0].flags == .maskShift && trace.output[1].flags == .maskCommand, "flags lost")
        }
        test("jitter returns click to original target and owns its down snapshot") {
            let trace = Trace()
            let down = mouse(.leftMouseDown)
            trace.send(down)
            down.location = CGPoint(x: 900, y: 900)
            trace.send(mouse(.leftMouseDragged, 101, 100.5))
            trace.send(mouse(.leftMouseUp, 100.5, 101))
            try require(trace.types == [.leftMouseDown, .leftMouseUp], "jitter became pan")
            try require(trace.output.allSatisfy { $0.location == CGPoint(x: 100, y: 100) }, "borrowed or moved origin")
        }
        test("orphan pen events are suppressed and a fresh down replaces stale contact") {
            let trace = Trace()
            trace.send(mouse(.leftMouseDragged, 120))
            trace.send(mouse(.leftMouseUp, 120))
            try require(trace.output.isEmpty, "orphan pen event leaked")
            trace.send(mouse(.leftMouseDown))
            trace.send(mouse(.leftMouseDown, 200))
            trace.send(mouse(.leftMouseUp, 200))
            try require(trace.types == [.leftMouseDown, .leftMouseUp], "fresh boundary did not replace stale contact")
            try require(trace.output.allSatisfy { $0.location == CGPoint(x: 200, y: 100) }, "stale target used")
        }
        test("slow fractional threshold crossing conserves displacement") {
            let trace = Trace()
            trace.send(mouse(.leftMouseDown))
            for step in 1...15 { trace.send(mouse(.leftMouseDragged, 100 + Double(step) * 0.25)) }
            try require(trace.types == [.scrollWheel, .scrollWheel], "expected two integer emissions, got \(trace.types)")
            try require(trace.xs == [2, 1], "slow motion lost or repeated: \(trace.xs)")
            trace.send(mouse(.leftMouseUp, 104))
            try require(trace.types.allSatisfy { $0 == .scrollWheel } && trace.xs == [2, 1, 1], "fractional release lost: \(trace.xs)")
        }
        test("radial threshold and release position can commit pan") {
            let diagonal = Trace()
            diagonal.send(mouse(.leftMouseDown))
            diagonal.send(mouse(.leftMouseUp, 101.5, 101.5))
            try require(diagonal.types == [.scrollWheel] && diagonal.xs == [1] && diagonal.ys == [1], "not a radial threshold")
            let release = Trace()
            release.send(mouse(.leftMouseDown))
            release.send(mouse(.leftMouseUp, 100, 104))
            try require(release.types == [.scrollWheel] && release.ys == [4], "release displacement ignored")
        }
        test("pan latches, reverses by consecutive deltas, and never emits buttons") {
            let trace = Trace()
            trace.send(mouse(.leftMouseDown))
            trace.send(mouse(.leftMouseDragged, 104, 104))
            trace.send(mouse(.leftMouseDragged, 104, 104))
            trace.send(mouse(.leftMouseDragged, 98, 98))
            trace.send(mouse(.leftMouseUp, 100, 100))
            try require(trace.types == [.scrollWheel, .scrollWheel, .scrollWheel], "button output during pan")
            try require(trace.xs == [4, -6, 2] && trace.ys == [4, -6, 2], "anchor scrolling or wrong reversal: \(trace.xs), \(trace.ys)")
        }
        test("sensitivity retains fractions and emits continuous pixel scroll with flags") {
            let trace = Trace(settings: ScrollSettings(sensitivity: 0.25, threshold: 2))
            trace.send(mouse(.leftMouseDown))
            trace.send(mouse(.leftMouseDragged, 102))
            try require(trace.output.isEmpty, "fraction rounded early")
            trace.send(mouse(.leftMouseUp, 104, flags: .maskShift))
            try require(trace.xs == [1], "sensitivity did not conserve fraction")
            try require(trace.output[0].getIntegerValueField(.scrollWheelEventIsContinuous) == 1, "not pixel scroll")
            try require(trace.output[0].flags == .maskShift, "scroll modifier lost")
        }
        test("subtype-0 release ends tap or pan; subsequent real mouse passes") {
            for pan in [false, true] {
                let trace = Trace()
                trace.send(mouse(.leftMouseDown))
                if pan { trace.send(mouse(.leftMouseDragged, 104)) }
                trace.send(mouse(.leftMouseUp, pan ? 104 : 100, subtype: 0))
                try require(trace.types == (pan ? [.scrollWheel] : [.leftMouseDown, .leftMouseUp]), "fallback leaked or lost release")
                let raw = mouse(.leftMouseUp, subtype: 0)
                trace.send(raw)
                try require(trace.output.last === raw, "stale pen state swallowed real mouse after release")
            }
        }
        test("mouse, trackpad scroll, Space, ordinary keys pass identically") {
            for pending in [false, true] {
                let trace = Trace()
                if pending { trace.send(mouse(.leftMouseDown)) }
                var events = [CGEvent]()
                for type in [CGEventType.leftMouseDown, .leftMouseDragged] {
                    events.append(mouse(type, subtype: 0))
                }
                if !pending { events.append(mouse(.leftMouseUp, subtype: 0)) }
                events.append(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 3, wheel2: 1, wheel3: 0)!)
                for key: CGKeyCode in [49, 0] {
                    events.append(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!)
                    events.append(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)!)
                }
                for event in events { trace.send(event) }
                try require(trace.output.count == events.count && zip(trace.output, events).allSatisfy { $0 === $1 }, "raw input changed")
            }
            try require(penEventMask == (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue), "keyboard/trackpad added to tap mask")
        }
        test("documented mixed-device release ambiguity consumes first subtype-0 up") {
            let trace = Trace()
            trace.send(mouse(.leftMouseDown))
            trace.send(mouse(.leftMouseUp, subtype: 0))
            try require(trace.types == [.leftMouseDown, .leftMouseUp], "owned fallback policy changed")
        }
        test("both tap-disabled notifications cancel before subtype filtering and reenable") {
            for disabled in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
                for panning in [false, true] {
                    let trace = Trace()
                    trace.send(mouse(.leftMouseDown))
                    if panning { trace.send(mouse(.leftMouseDragged, 104)) }
                    trace.output.removeAll()
                    trace.send(mouse(.leftMouseUp, subtype: 0), as: disabled)
                    trace.send(mouse(.leftMouseDragged, 108))
                    trace.send(mouse(.leftMouseUp, 108, subtype: 0))
                    try require(trace.output.isEmpty && trace.reenables == 1, "stale output or missing reenable")
                    trace.tap(time: 2)
                    try require(trace.types == [.leftMouseDown, .leftMouseUp], "cannot recover after clean release")
                }
            }
        }
        test("idle tap-disable preserves ordinary mouse pairs and stops without a pen release") {
            for disabled in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
                let trace = Trace()
                trace.send(mouse(.leftMouseUp, subtype: 0), as: disabled)
                let rawEvents = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].map {
                    mouse($0, subtype: 0)
                }
                for event in rawEvents { trace.send(event) }
                try require(trace.output.count == rawEvents.count &&
                            zip(trace.output, rawEvents).allSatisfy { $0 === $1 }, "idle disable swallowed ordinary mouse input")
                let stopping = Trace()
                stopping.send(mouse(.leftMouseUp, subtype: 0), as: disabled)
                stopping.adapter.gesture.requestStop()
                try require(stopping.adapter.gesture.stopped, "idle disable waits for nonexistent pen release")
            }
        }
        test("clean pen down recovers when disabled interval hid the release") {
            let trace = Trace()
            trace.send(mouse(.leftMouseUp, subtype: 0), as: .tapDisabledByTimeout)
            trace.tap()
            try require(trace.types == [.leftMouseDown, .leftMouseUp], "clean boundary not recognized")
        }
        test("stop cancels pending and panning output and drains to release") {
            for pan in [false, true] {
                let trace = Trace()
                trace.send(mouse(.leftMouseDown))
                if pan { trace.send(mouse(.leftMouseDragged, 104)) }
                trace.output.removeAll()
                trace.adapter.gesture.requestStop()
                try require(!trace.adapter.gesture.stopped, "detached before draining")
                trace.send(mouse(.leftMouseDragged, 110))
                trace.send(mouse(.leftMouseUp, 110, subtype: 0))
                try require(trace.output.isEmpty && trace.adapter.gesture.stopped, "stop emitted click or did not drain")
            }
            let idle = Trace()
            idle.adapter.gesture.requestStop()
            try require(idle.adapter.gesture.stopped, "idle stop waits for nonexistent contact")
            idle.send(mouse(.leftMouseUp, subtype: 0), as: .tapDisabledByTimeout)
            try require(idle.reenables == 0, "stopped tap reenabled")
        }
        test("double-click metadata and original timestamps survive deferred delivery") {
            let trace = Trace()
            trace.tap(count: 1, time: 1)
            trace.tap(count: 2, time: 1.2, x: 103)
            try require(trace.counts == [1, 1, 2, 2], "double-click grouping lost: \(trace.counts)")
            try require(trace.output.map(\.timestamp) == [1_000_000_000, 1_050_000_000, 1_200_000_000, 1_250_000_000], "timestamps changed")
            trace.tap(count: 3, time: 3)
            try require(Array(trace.counts.suffix(2)) == [1, 1], "expired double click retained")
            trace.tap(count: 1, time: 3.2, x: 200)
            try require(Array(trace.counts.suffix(2)) == [1, 1], "native count reset ignored")
        }
        test("tap-pan-tap resets grouping without disabling the next double click") {
            let trace = Trace()
            trace.tap(count: 1, time: 1)
            trace.send(mouse(.leftMouseDown, count: 2, time: 1.1))
            trace.send(mouse(.leftMouseUp, 104, count: 2, time: 1.15))
            trace.output.removeAll()
            trace.tap(count: 3, time: 1.2)
            trace.tap(count: 4, time: 1.3)
            try require(trace.counts == [1, 1, 2, 2], "pan counted as delivered click: \(trace.counts)")
        }
        test("both click events must allocate before either can be posted") {
            let trace = Trace()
            var copies = 0
            trace.adapter.copyEvent = { event in copies += 1; return copies == 2 ? nil : event.copy() }
            trace.tap()
            try require(trace.output.isEmpty, "partial click left button pressed")
            trace.adapter.copyEvent = { $0.copy() }
            trace.tap(time: 2)
            try require(trace.types == [.leftMouseDown, .leftMouseUp], "allocation failure left stale contact")
        }
        test("scroll allocation failure cancels without a click") {
            let trace = Trace()
            trace.adapter.makeScroll = { _, _ in nil }
            trace.send(mouse(.leftMouseDown))
            trace.send(mouse(.leftMouseDragged, 104))
            trace.send(mouse(.leftMouseUp, 104))
            try require(trace.output.isEmpty, "failed scroll became click")
        }
        test("invalid environment is rejected before live setup") {
            for key in ["PENPAN_SENS", "PENPAN_DEADZONE"] {
                for value in ["0", "-1", "nan", "inf", "bad"] {
                    do { _ = try ScrollSettings.environment([key: value]); throw Failure("accepted \(key)=\(value)") }
                    catch let error as Failure { try require(error.description.contains("finite positive"), error.description) }
                }
            }
            let configured = try ScrollSettings.environment(["PENPAN_SENS": "0.5", "PENPAN_DEADZONE": "3"])
            try require(configured.sensitivity == 0.5 && configured.threshold == 3, "valid settings lost")
        }
        test("large finite motion clamps safely; nonfinite scroll arithmetic cancels") {
            let trace = Trace(settings: ScrollSettings(sensitivity: 1e20, threshold: 2))
            trace.send(mouse(.leftMouseDown))
            trace.send(mouse(.leftMouseUp, 104))
            try require(trace.xs == [Int64(Int32.max)], "unsafe integer conversion")
            let overflow = Trace(settings: ScrollSettings(sensitivity: Double.greatestFiniteMagnitude, threshold: 2))
            overflow.send(mouse(.leftMouseDown))
            overflow.send(mouse(.leftMouseUp, 104))
            try require(overflow.output.isEmpty, "nonfinite arithmetic emitted input")
            let rawDown = mouse(.leftMouseDown, subtype: 0)
            let rawUp = mouse(.leftMouseUp, subtype: 0)
            overflow.send(rawDown)
            overflow.send(rawUp)
            try require(overflow.output.count == 2 && overflow.output[0] === rawDown &&
                        overflow.output[1] === rawUp, "failed pen release swallowed the next ordinary mouse up")
            overflow.adapter.gesture.requestStop()
            try require(overflow.adapter.gesture.stopped, "failed release left a phantom contact")
        }
        test("kernel lock excludes another owner and releases with descriptor lifetime") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("instance.lock").path
            var first: InstanceLock? = try InstanceLock(path: path)
            try withExtendedLifetime(first) {
                do { _ = try InstanceLock(path: path); throw Failure("second owner acquired lock") }
                catch let error as Failure { try require(error.description.contains("another pen-pan"), error.description) }
            }
            first = nil
            let next = try InstanceLock(path: path)
            withExtendedLifetime(next) {}
            let link = directory.appendingPathComponent("link").path
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
            do { _ = try InstanceLock(path: link); throw Failure("followed symlink lock") }
            catch let error as Failure { try require(error.description.contains("cannot open"), error.description) }
        }
    }

    private static func lifecycleOffline() {
        test("lifecycle OFF forwards pen down/drag/up by identity and emits nothing") {
            let trace = LifecycleTrace(enabled: false)
            for type in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
                let event = mouse(type, 110)
                try require(trace.send(event) === event, "OFF changed original event")
            }
            try require(trace.output.count == 3 && trace.lifecycle.contact == .idle, "OFF synthesized output or retained contact")
        }
        test("lifecycle mouse, Space, ordinary keys and trackpad pass in every mode") {
            for mode in [Lifecycle.Mode.off, .on, .quitting] {
                let trace = LifecycleTrace(enabled: mode == .on)
                if mode == .quitting { trace.lifecycle.requestQuit() }
                var events = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].map { mouse($0, subtype: 0) }
                events.append(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 3, wheel2: 1, wheel3: 0)!)
                for key: CGKeyCode in [49, 0] {
                    for down in [true, false] {
                        events.append(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!)
                    }
                }
                for event in events { try require(trace.send(event) === event, "ordinary input changed in \(mode)") }
            }
        }
        test("lifecycle ON during passed contact preserves release and owns only next down") {
            for subtype: Int64 in [0, 1] {
                let trace = LifecycleTrace(enabled: false)
                let down = mouse(.leftMouseDown)
                try require(trace.send(down) === down, "OFF down not passed")
                trace.lifecycle.setEnabled(true)
                try require(trace.lifecycle.status == "ON, waiting for release", "waiting status missing")
                for type in [CGEventType.leftMouseDragged, .leftMouseUp] {
                    let event = mouse(type, 110, subtype: subtype)
                    try require(trace.send(event) === event, "passed contact stolen")
                }
                trace.output.removeAll()
                trace.tap(time: 2)
                try require(trace.types == [.leftMouseDown, .leftMouseUp], "next clean contact not owned")
                try require(trace.output.allSatisfy { $0.getIntegerValueField(.mouseEventSubtype) == 0 }, "tap not adapted")
            }
        }
        test("lifecycle OFF during pending or pan drains release, even after ON again") {
            for pan in [false, true] {
                for subtype: Int64 in [0, 1] {
                    for reenable in [false, true] {
                        let trace = LifecycleTrace()
                        trace.send(mouse(.leftMouseDown))
                        if pan { trace.send(mouse(.leftMouseDragged, 110)) }
                        trace.output.removeAll()
                        trace.lifecycle.setEnabled(false)
                        try require(trace.lifecycle.status == "OFF, draining", "not draining")
                        trace.lifecycle.setEnabled(false)
                        trace.lifecycle.setEnabled(reenable)
                        trace.lifecycle.setEnabled(reenable)
                        trace.send(mouse(.leftMouseDown, 120))
                        trace.send(mouse(.leftMouseDragged, 130))
                        trace.send(mouse(.leftMouseUp, 130, subtype: subtype))
                        try require(trace.output.isEmpty && trace.lifecycle.contact == .idle, "toggle revived cancelled contact")
                        let down = mouse(.leftMouseDown, time: 2)
                        try require((trace.send(down) === down) == !reenable, "next contact did not follow latest mode")
                        trace.send(mouse(.leftMouseUp, time: 2.05))
                        try require(trace.types == [.leftMouseDown, .leftMouseUp], "next contact did not recover")
                    }
                }
            }
        }
        test("lifecycle rapid toggles never steal passed ownership; latest mode wins") {
            let trace = LifecycleTrace(enabled: false)
            trace.send(mouse(.leftMouseDown))
            for enabled in [true, false, false, true] { trace.lifecycle.setEnabled(enabled) }
            for type in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
                let event = mouse(type)
                try require(trace.send(event) === event, "passed contact changed disposition")
            }
            try require(trace.lifecycle.mode == .on && trace.lifecycle.status == "ON", "latest intent lost")
            trace.lifecycle.setEnabled(false)
            let down = mouse(.leftMouseDown)
            try require(trace.send(down) === down, "latest OFF not respected")
        }
        test("lifecycle startup held button and unmatched events remain ordinary input") {
            let held = LifecycleTrace(held: true)
            for type in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
                let event = mouse(type)
                try require(held.send(event) === event, "startup held contact stolen")
            }
            let untracked = LifecycleTrace()
            for type in [CGEventType.leftMouseDragged, .leftMouseUp] {
                let event = mouse(type)
                try require(untracked.send(event) === event, "unmatched startup input suppressed")
            }
            untracked.output.removeAll()
            untracked.tap()
            try require(untracked.types == [.leftMouseDown, .leftMouseUp], "fresh startup down not owned")
        }
        test("lifecycle disable keeps idle idle, reenables OFF observation and permits immediate quit") {
            for enabled in [false, true] {
                for disabled in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
                    let trace = LifecycleTrace(enabled: enabled)
                    trace.send(mouse(.leftMouseUp, subtype: 0))
                    trace.send(mouse(.leftMouseUp, subtype: 0), as: disabled)
                    try require(trace.lifecycle.contact == .idle && trace.reenables == 1, "idle disable invented contact or failed recovery")
                    trace.lifecycle.requestQuit()
                    try require(trace.lifecycle.finished, "idle quit waiting for phantom release")
                    trace.send(mouse(.leftMouseUp), as: disabled)
                    try require(trace.reenables == 1, "terminal tap reenabled")
                }
            }
        }
        test("lifecycle disable cancels owned output, preserves passed releases, recovers at fresh down") {
            for disabled in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
                for owned in [false, true] {
                    let trace = LifecycleTrace(enabled: owned)
                    trace.send(mouse(.leftMouseDown))
                    trace.send(mouse(.leftMouseUp, subtype: 0), as: disabled)
                    trace.lifecycle.setEnabled(true)
                    let drag = mouse(.leftMouseDragged, 120)
                    let up = mouse(.leftMouseUp, 120, subtype: 0)
                    try require((trace.send(drag) === drag) == !owned, "disable changed contact ownership")
                    try require((trace.send(up) === up) == !owned, "disable lost matching release")
                    trace.output.removeAll()
                    trace.tap(time: 2)
                    try require(trace.types == [.leftMouseDown, .leftMouseUp], "next boundary failed")
                }
                let missed = LifecycleTrace()
                missed.send(mouse(.leftMouseDown))
                missed.send(mouse(.leftMouseUp), as: disabled)
                missed.tap(time: 2)
                try require(missed.types == [.leftMouseDown, .leftMouseUp], "hidden release prevented fresh-down recovery")
            }
        }
        test("lifecycle Quit is terminal and drains owned contact across disable") {
            for pan in [false, true] {
                let trace = LifecycleTrace()
                trace.send(mouse(.leftMouseDown))
                if pan { trace.send(mouse(.leftMouseDragged, 110)) }
                trace.output.removeAll()
                trace.lifecycle.requestQuit()
                trace.lifecycle.requestQuit()
                trace.lifecycle.setEnabled(true)
                trace.lifecycle.setEnabled(false)
                try require(!trace.lifecycle.finished && trace.lifecycle.mode == .quitting, "quit revived or detached contact")
                trace.send(mouse(.leftMouseUp), as: .tapDisabledByTimeout)
                try require(trace.reenables == 1, "quit drain observation not recovered")
                trace.send(mouse(.leftMouseDragged, 120))
                trace.send(mouse(.leftMouseUp, 120, subtype: 0))
                try require(trace.output.isEmpty && trace.lifecycle.finished, "quit emitted output or failed release")
            }
            let passed = LifecycleTrace(enabled: false)
            passed.send(mouse(.leftMouseDown))
            passed.lifecycle.requestQuit()
            try require(passed.lifecycle.finished, "passed contact unnecessarily drained")
            let untracked = LifecycleTrace()
            untracked.lifecycle.requestQuit()
            try require(untracked.lifecycle.finished, "untracked contact unnecessarily drained")
        }
        test("lifecycle quit resynchronizes after a disabled interval hid owned release") {
            let trace = LifecycleTrace()
            trace.send(mouse(.leftMouseDown))
            trace.lifecycle.requestQuit()
            trace.send(mouse(.leftMouseUp), as: .tapDisabledByUserInput)
            let down = mouse(.leftMouseDown, 200)
            try require(trace.send(down) === down && trace.lifecycle.finished, "quit claimed next contact or hung after hidden release")
        }
        test("lifecycle error release cleanup survives click/scroll allocation and arithmetic failure") {
            for failure in ["click", "scroll", "arithmetic"] {
                let trace = LifecycleTrace(settings: ScrollSettings(sensitivity: failure == "arithmetic" ? Double.greatestFiniteMagnitude : 1))
                if failure == "click" { trace.adapter.copyEvent = { _ in nil } }
                if failure == "scroll" { trace.adapter.makeScroll = { _, _ in nil } }
                trace.send(mouse(.leftMouseDown))
                trace.send(mouse(.leftMouseUp, failure == "click" ? 100 : 110))
                try require(trace.output.isEmpty && trace.lifecycle.contact == .idle, "failed release retained ownership")
                let raw = mouse(.leftMouseUp, subtype: 0)
                try require(trace.send(raw) === raw, "failed release swallowed next mouse release")
                trace.lifecycle.requestQuit()
                try require(trace.lifecycle.finished, "error left phantom quit drain")
            }
        }
        test("lifecycle OFF/ON resets click grouping without disturbing later double taps") {
            let trace = LifecycleTrace()
            trace.tap(count: 1)
            trace.lifecycle.setEnabled(false)
            trace.lifecycle.setEnabled(true)
            trace.tap(count: 2, time: 1.2)
            trace.tap(count: 3, time: 1.3)
            try require(trace.counts == [1, 1, 1, 1, 2, 2], "toggle retained cancelled click grouping")
        }
        test("lifecycle attachment failure is OFF, leaves input available and holds same kernel lock") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("instance.lock").path
            var lock: InstanceLock? = try InstanceLock(path: path)
            let session = LiveSession(configuration: Configuration(scroll: ScrollSettings(sensitivity: 1, threshold: 2)))
            session.createTap = { _, _ in nil }
            do { try session.attach(); throw Failure("attachment unexpectedly succeeded") }
            catch let error as Failure { try require(error.description.contains("could not create event tap"), error.description) }
            session.lifecycle.setEnabled(true)
            try require(session.lifecycle.mode == .off && !session.lifecycle.observing && session.tap == nil, "failure claimed ON")
            let down = mouse(.leftMouseDown)
            try require(session.lifecycle.handle(down.type, down, post: { _ in }) === down, "failure suppressed input")
            try withExtendedLifetime(lock) {
                do { _ = try InstanceLock(path: path); throw Failure("OFF menu released lock") }
                catch let error as Failure { try require(error.description.contains("another pen-pan"), error.description) }
            }
            session.requestQuit()
            session.teardown()
            session.teardown()
            lock = nil
            let next = try InstanceLock(path: path)
            withExtendedLifetime(next) {}
        }
    }

    private static func withStore(_ body: (ConfigurationStore, UserDefaults) throws -> Void) throws {
        let suite = "local.pen-pan.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(try ConfigurationStore(suiteName: suite), defaults)
    }

    private static func settingsOffline() {
        test("fresh settings are 0.30x, 6px, unreversed and unassigned without writing defaults") {
            try withStore { store, defaults in
                let config = try store.load(environment: [:])
                try require(config == Configuration(), "fresh configuration differs")
                try require(config.scroll.sensitivity == 0.30 && config.scroll.threshold == 6 &&
                            !config.scroll.reversed && config.shortcut == nil && config.excludedApps.isEmpty, "wrong fresh defaults")
                try require(defaults.object(forKey: "sensitivity") == nil, "loading wrote settings")
            }
        }
        test("named isolated store round-trips only configuration and UI wins over stale environment") {
            try withStore { store, defaults in
                let key = try Shortcut(keyCode: 35, modifiers: UInt32(controlKey | optionKey | shiftKey))
                let config = Configuration(scroll: ScrollSettings(sensitivity: 0.05, reversed: true), shortcut: key)
                store.save(config)
                try require(try store.load(environment: ["PENPAN_SENS": "bad"]) == config, "saved UI lost precedence")
                try require(defaults.object(forKey: "mode") == nil && defaults.object(forKey: "threshold") == nil,
                            "unrequested persistence")
                store.save(Configuration(scroll: ScrollSettings(sensitivity: 2)))
                try require(try store.load(environment: ["PENPAN_SENS": "1"]).scroll.sensitivity == 2 &&
                            defaults.object(forKey: "shortcut") == nil, "clear/bound not saved")
            }
        }
        test("store rejects wrong types, nonfinite bounds, fractional keycodes and unsafe modifiers") {
            try withStore { store, defaults in
                for value: Any in [true, "0.5", 0.0, -1.0, 2.01, Double.nan, Double.infinity] {
                    defaults.set(value, forKey: "sensitivity")
                    try require(try store.load(environment: [:]).scroll.sensitivity == 0.30, "accepted invalid sensitivity \(value)")
                }
                for value: Any in ["true", 1, 0.5] {
                    defaults.set(value, forKey: "reversed")
                    try require(try !store.load(environment: [:]).scroll.reversed, "accepted invalid reversal")
                }
                for data: [String: Any] in [
                    ["keyCode": true, "modifiers": controlKey], ["keyCode": 0.5, "modifiers": controlKey],
                    ["keyCode": 49, "modifiers": controlKey], ["keyCode": 0, "modifiers": shiftKey],
                    ["keyCode": 0, "modifiers": UInt32.max], ["keyCode": -1, "modifiers": controlKey],
                    ["keyCode": 0, "modifiers": 0], ["keyCode": 0, "modifiers": controlKey, "extra": 1]
                ] {
                    defaults.set(data, forKey: "shortcut")
                    try require(try store.load(environment: [:]).shortcut == nil, "accepted invalid shortcut \(data)")
                }
                defaults.removeObject(forKey: "sensitivity")
                let fallback = try store.load(environment: ["PENPAN_SENS": "0.15", "PENPAN_DEADZONE": "6"])
                try require(fallback.scroll.sensitivity == 0.15 && fallback.scroll.threshold == 6, "launch seed lost")
            }
        }
        test("sensitivity launch boundary rejects values outside the UI range") {
            for value in ["0.049", "2.001"] {
                do { _ = try ScrollSettings.environment(["PENPAN_SENS": value]); throw Failure("accepted range overflow") }
                catch let error as Failure { try require(error.description.contains("0.05...2"), error.description) }
            }
        }
        test("fresh threshold remains six and lower sensitivity conserves reversed fractional motion") {
            let threshold = Trace(settings: ScrollSettings())
            threshold.send(mouse(.leftMouseDown))
            threshold.send(mouse(.leftMouseDragged, 105.9))
            try require(threshold.output.isEmpty, "threshold changed below six")
            threshold.send(mouse(.leftMouseUp, 106))
            try require(threshold.xs == [1], "fresh scale not applied at six")
            let reverse = Trace(settings: ScrollSettings(sensitivity: 0.25, reversed: true))
            reverse.send(mouse(.leftMouseDown))
            reverse.send(mouse(.leftMouseDragged, 106, 106))
            reverse.send(mouse(.leftMouseDragged, 110, 110))
            reverse.send(mouse(.leftMouseUp, 100, 100))
            try require(reverse.xs == [-1, -1, 2] && reverse.ys == [-1, -1, 2], "reverse/fraction arithmetic differs: \(reverse.xs), \(reverse.ys)")
        }
        test("session scroll changes snapshot at down, including pending, panning and release") {
            for changeAfterPan in [false, true] {
                let session = LiveSession(configuration: Configuration(scroll: ScrollSettings(sensitivity: 1)))
                session.lifecycle.observationStarted(leftButtonHeld: false)
                session.lifecycle.setEnabled(true)
                var output: [CGEvent] = []
                func send(_ event: CGEvent) {
                    _ = session.lifecycle.handle(event.type, event, post: { output.append($0) })
                }
                send(mouse(.leftMouseDown))
                if changeAfterPan { send(mouse(.leftMouseDragged, 110, 110)) }
                session.setScroll(ScrollSettings(sensitivity: 0.5, reversed: true))
                send(mouse(.leftMouseUp, 120, 120))
                try require(output.reduce(0) { $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) } == 20,
                            "edited owned contact changed scale/direction")
                output = []
                send(mouse(.leftMouseDown))
                send(mouse(.leftMouseUp, 120, 120))
                try require(output.count == 1 && output[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -10 &&
                            output[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -10, "next contact missed settings")
            }
        }
        test("scroll edits do not steal OFF or already passed contacts or revive draining contacts") {
            let session = LiveSession()
            session.lifecycle.observationStarted(leftButtonHeld: false)
            let down = mouse(.leftMouseDown)
            try require(session.lifecycle.handle(down.type, down, post: { _ in }) === down, "OFF down changed")
            session.setScroll(ScrollSettings(sensitivity: 2, reversed: true))
            session.lifecycle.setEnabled(true)
            let up = mouse(.leftMouseUp, 120)
            try require(session.lifecycle.handle(up.type, up, post: { _ in }) === up, "edit stole passed release")
            _ = session.lifecycle.handle(down.type, down, post: { _ in })
            session.lifecycle.setEnabled(false)
            session.setScroll(ScrollSettings(sensitivity: 0.05))
            session.lifecycle.setEnabled(true)
            var posts = 0
            _ = session.lifecycle.handle(up.type, up, post: { _ in posts += 1 })
            try require(posts == 0 && session.lifecycle.contact == .idle, "edit revived cancelled contact")
        }
        test("settings target eligibility is window-specific and fixed through contact release") {
            try require(SettingsControl.targetsSettings(visible: true, settingsNumber: 42, targetNumber: 42), "own target rejected")
            for (visible, settings, target) in [(false, 42, 42), (true, 42, 7), (true, 0, 0)] {
                try require(!SettingsControl.targetsSettings(visible: visible, settingsNumber: settings, targetNumber: target),
                            "hidden/covered/invalid window exempted")
            }
            let trace = LifecycleTrace()
            var hits = 0
            var ownTarget = true
            trace.lifecycle.passesNewContact = { _ in hits += 1; return ownTarget }
            let down = mouse(.leftMouseDown)
            try require(trace.send(down) === down, "settings down not ordinary")
            ownTarget = false
            for type in [CGEventType.leftMouseDragged, .leftMouseUp] {
                let event = mouse(type, 300)
                try require(trace.send(event) === event, "slider drag outside settings stolen")
            }
            trace.output = []
            trace.send(mouse(.leftMouseDown))
            ownTarget = true
            trace.send(mouse(.leftMouseUp, 120))
            try require(trace.types == [.scrollWheel] && hits == 2, "owned pan re-evaluated or unrelated app exempted")
        }
        test("Shortcut rejects typing, Space, Shift-only, modifier keys and unsupported codes/bits") {
            for (code, flags): (UInt32, UInt32) in [(0, 0), (0, UInt32(shiftKey)), (49, UInt32(cmdKey)),
                                                   (56, UInt32(controlKey)), (255, UInt32(optionKey)),
                                                   (0, UInt32(controlKey) | 1)] {
                do { _ = try Shortcut(keyCode: code, modifiers: flags); throw Failure("accepted unsafe shortcut") }
                catch let error as Failure { try require(error.description.contains("Use Control"), error.description) }
            }
            try require(Shortcut.carbonModifiers([.command, .option, .control, .shift]) == Shortcut.modifierMask,
                        "AppKit flags were cast rather than mapped")
            try require(Shortcut.carbonModifiers([.capsLock, .numericPad, .function]) == 0, "incidental flags persisted")
            let key = try Shortcut(keyCode: 35, modifiers: UInt32(cmdKey | controlKey))
            try require(key.label == "⌃⌘P", "shortcut not readable")
        }
        test("exclusive conflict and symbolic lookup failure preserve registration, settings and saved values") {
            try withStore { store, _ in
                let fake = FakeHotKeys()
                let first = try Shortcut(keyCode: 35, modifiers: UInt32(controlKey))
                let second = try Shortcut(keyCode: 0, modifiers: UInt32(optionKey))
                let session = LiveSession(store: store, hotKeyAPI: fake.api)
                defer { session.teardown() }
                session.setShortcut(first)
                fake.conflict.insert(second.keyCode)
                session.setShortcut(second)
                try require(session.configuration.shortcut == first && session.hotKeys.shortcut == first &&
                            fake.active.count == 1 && fake.removed.isEmpty, "failed replacement dropped old binding")
                try require(try store.load(environment: [:]).shortcut == first, "failed replacement persisted")
                try require(session.settingsError?.contains("exclusive conflict") == true, "conflict not visible")
                fake.failCheck = true
                let before = fake.registered.count
                session.setShortcut(second)
                try require(fake.registered.count == before && session.configuration.shortcut == first &&
                            session.settingsError?.contains("lookup failure") == true, "lookup failure did not fail closed")
            }
        }
        test("replacement registers before old removal, keeps one binding, ignores stale IDs and clears transactionally") {
            let fake = FakeHotKeys()
            let recording = ShortcutRecording()
            let owner = HotKeyRegistration(api: fake.api, recording: recording)
            defer { owner.teardown() }
            let first = try Shortcut(keyCode: 35, modifiers: UInt32(controlKey))
            let second = try Shortcut(keyCode: 0, modifiers: UInt32(optionKey))
            try owner.replace(with: first)
            let oldID = fake.registered.last!.1
            try owner.replace(with: first)
            try require(fake.registered.count == 1, "identical shortcut re-registered")
            try owner.replace(with: second)
            let newID = fake.registered.last!.1
            try require(newID != oldID && fake.active.count == 1 && fake.removed.count == 1 &&
                        fake.operations == ["register 1", "register 2", "remove"], "replacement did not register before retiring old")
            var toggles = 0
            owner.toggle = { toggles += 1 }
            owner.receive(id: oldID, pressed: true)
            owner.receive(id: newID, pressed: true)
            owner.receive(id: newID, pressed: true)
            owner.receive(id: newID, pressed: false)
            owner.receive(id: newID, pressed: true)
            try require(toggles == 2, "stale/repeat event toggled")
            fake.failRemoval = Set(fake.active.keys)
            do { try owner.replace(with: nil); throw Failure("clear unexpectedly succeeded") }
            catch let error as Failure { try require(error.description.contains("removal failure"), error.description) }
            try require(owner.shortcut == second, "failed clear removed configuration")
            fake.failRemoval = []
            try owner.replace(with: nil)
            try require(owner.shortcut == nil && fake.active.isEmpty, "clear leaked registration")
            owner.receive(id: newID, pressed: true)
            try require(toggles == 2, "cleared binding still toggles")
        }
        test("failed old removal rolls candidate back and failed rollback is retained for cleanup") {
            let fake = FakeHotKeys()
            let owner = HotKeyRegistration(api: fake.api, recording: ShortcutRecording())
            let first = try Shortcut(keyCode: 35, modifiers: UInt32(controlKey))
            let second = try Shortcut(keyCode: 0, modifiers: UInt32(optionKey))
            try owner.replace(with: first)
            let old = fake.active.keys.first!
            fake.failRemoval.insert(old)
            do { try owner.replace(with: second); throw Failure("replacement unexpectedly succeeded") }
            catch let error as Failure { try require(error.description.contains("removal failure"), error.description) }
            try require(owner.shortcut == first && fake.active.count == 1, "candidate not rolled back")
            let nextRef = EventHotKeyRef(bitPattern: 1003)!
            fake.failRemoval.insert(nextRef)
            var errors: [String] = []
            owner.report = { errors.append($0) }
            do { try owner.replace(with: second); throw Failure("replacement unexpectedly succeeded") }
            catch let error as Failure { try require(error.description.contains("removal failure"), error.description) }
            try require(owner.cleanupPending && fake.active.count == 2 && !errors.isEmpty, "failed cleanup forgotten/silent")
            var toggles = 0
            owner.toggle = { toggles += 1 }
            owner.receive(id: 3, pressed: true)
            try require(toggles == 0, "rolled-back candidate toggled")
            owner.teardown()
            try require(owner.shortcut == nil && owner.cleanupPending, "failed teardown lost handles")
            fake.failRemoval = []
            owner.teardown()
            owner.teardown()
            try require(fake.active.isEmpty && !owner.cleanupPending, "retry cleanup leaked handles")
        }
        test("hotkey uses the session menu toggle lifecycle and suppresses repeats through recording cancellation") {
            let fake = FakeHotKeys()
            let session = LiveSession(hotKeyAPI: fake.api)
            defer { session.teardown() }
            session.createTap = { _, _ in nil }
            session.lifecycle.observationStarted(leftButtonHeld: false)
            let key = try Shortcut(keyCode: 35, modifiers: UInt32(controlKey))
            session.setShortcut(key)
            let id = fake.registered.last!.1
            session.hotKeys.receive(id: id, pressed: true)
            try require(session.lifecycle.mode == .on, "hotkey did not enable via session")
            _ = session.lifecycle.handle(.leftMouseDown, mouse(.leftMouseDown), post: { _ in })
            session.hotKeys.receive(id: id, pressed: true)
            try require(session.lifecycle.contact == .owned, "repeat toggled owned contact")
            session.hotKeys.receive(id: id, pressed: false)
            session.recording.begin()
            session.hotKeys.receive(id: id, pressed: true)
            try require(session.recording.state == .held(key) && session.lifecycle.mode == .on, "recording same key toggled")
            session.recording.cancel()
            session.hotKeys.receive(id: id, pressed: true)
            try require(session.lifecycle.mode == .on, "cancel reset held latch")
            session.hotKeys.receive(id: id, pressed: false)
            session.hotKeys.receive(id: id, pressed: true)
            try require(session.lifecycle.mode == .off && session.lifecycle.contact == .draining(interrupted: false),
                        "hotkey skipped cancellation lifecycle")
            session.requestQuit()
            session.hotKeys.receive(id: id, pressed: true)
            try require(session.lifecycle.mode == .quitting && fake.active.isEmpty, "quit retained/revived shortcut")
        }
        test("recorder commits only matching release and keeps old registration throughout recording") {
            let fake = FakeHotKeys()
            let session = LiveSession(hotKeyAPI: fake.api)
            defer { session.teardown() }
            let first = try Shortcut(keyCode: 35, modifiers: UInt32(controlKey))
            let second = try Shortcut(keyCode: 0, modifiers: UInt32(optionKey))
            session.setShortcut(first)
            session.recording.begin()
            session.recording.press(second, repeatKey: true)
            try require(session.recording.state == .listening, "repeat captured")
            session.recording.press(second)
            session.recording.release(keyCode: first.keyCode)
            try require(session.configuration.shortcut == first && fake.active.count == 1, "committed before recorded release")
            session.recording.release(keyCode: second.keyCode)
            try require(session.configuration.shortcut == second && fake.active.count == 1 && !session.recording.active,
                        "matching release did not commit")
            session.recording.begin()
            session.recording.press(first)
            session.recording.cancel()
            session.recording.release(keyCode: first.keyCode)
            try require(session.configuration.shortcut == second, "cancel committed")
        }
        test("native hotkey owner has no startup assignment and rejects known reserved combinations before registration") {
            let fake = FakeHotKeys()
            let session = LiveSession(hotKeyAPI: fake.api)
            defer { session.teardown() }
            session.startHotKeys()
            try require(fake.registered.isEmpty && fake.checked.isEmpty && session.configuration.shortcut == nil,
                        "startup registered a default binding")
            for (code, modifiers): (UInt32, UInt32) in [(48, UInt32(cmdKey)), (48, UInt32(cmdKey | shiftKey)),
                                                       (12, UInt32(cmdKey | controlKey)), (12, UInt32(cmdKey | shiftKey))] {
                try require(HotKeyAPI.isReserved(try Shortcut(keyCode: code, modifiers: modifiers)), "known reserved chord allowed")
            }
            try require(!HotKeyAPI.isReserved(try Shortcut(keyCode: 35, modifiers: UInt32(controlKey | optionKey))),
                        "ordinary modified key rejected")
        }
        test("unavailable saved shortcut stays saved but visibly inactive") {
            try withStore { store, _ in
                let key = try Shortcut(keyCode: 35, modifiers: UInt32(controlKey))
                let config = Configuration(shortcut: key)
                store.save(config)
                let fake = FakeHotKeys()
                fake.conflict.insert(key.keyCode)
                let session = LiveSession(configuration: try store.load(environment: [:]), store: store, hotKeyAPI: fake.api)
                defer { session.teardown() }
                session.startHotKeys()
                try require(session.configuration.shortcut == key && session.hotKeys.shortcut == nil &&
                            session.settingsError?.contains("inactive") == true, "saved conflict not visible/inactive")
                try require(try store.load(environment: [:]).shortcut == key, "unavailable binding erased saved choice")
            }
        }
    }

    private static func withApplicationFixture(identifier: Any = "org.penpan.Fixture", packageType: String = "APPL",
                                               executable: Bool = true, extension suffix: String = "app",
                                               _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("penpan-app-\(UUID().uuidString)")
        let url = root.appendingPathComponent("Fixture.\(suffix)")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": packageType,
                                   "CFBundleExecutable": "fixture", "CFBundleName": "Fixture application"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if executable {
            let path = contents.appendingPathComponent("MacOS/fixture")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        try body(url)
    }

    private static func exclusionsOffline() {
        test("ApplicationID accepts explicit bundle identities, not wildcards, whitespace or empty components") {
            for value in ["org.example.App", "com.vendor-1.Product2", "a.b"] {
                try require(ApplicationID(value)?.rawValue == value, "valid ID rejected: \(value)")
            }
            for value in ["", "*", "com.*", "com..app", ".app", "com.app.", "app", " com.app", "com.app\n",
                          "com.app ", "com.app/child", "com.app_name", "com.é", "com.-app"] {
                try require(ApplicationID(value) == nil, "unsafe ID accepted: \(value)")
            }
        }
        test("exclusion persistence validates the entire array type, filters IDs, deduplicates and sorts") {
            try withStore { store, defaults in
                let first = ApplicationID("org.example.First")!
                let second = ApplicationID("org.example.Second")!
                let shortcut = try Shortcut(keyCode: UInt32(kVK_F13), modifiers: 0)
                let config = Configuration(scroll: ScrollSettings(sensitivity: 0.15, reversed: true), shortcut: shortcut,
                                           excludedApps: [second, first])
                store.save(config)
                try require(defaults.object(forKey: "excludedApps") as? [String] == [first.rawValue, second.rawValue], "storage not deterministic")
                try require(try store.load(environment: [:]) == config, "exclusions did not round trip with siblings")
                for value: Any in ["org.example.First", ["org.example.First", 7], ["bad": "org.example.First"], true] {
                    defaults.set(value, forKey: "excludedApps")
                    let loaded = try store.load(environment: [:])
                    try require(loaded.excludedApps.isEmpty && loaded.scroll == config.scroll && loaded.shortcut == shortcut,
                                "wrong type accepted or sibling lost")
                }
                defaults.set([first.rawValue, "", "*", "com..app", first.rawValue, second.rawValue], forKey: "excludedApps")
                try require(try store.load(environment: [:]).excludedApps == [first, second], "invalid ID or duplicate loaded")
                defaults.set("broken", forKey: "shortcut")
                defaults.set("broken", forKey: "sensitivity")
                let loaded = try store.load(environment: [:])
                try require(loaded.excludedApps == [first, second] && loaded.scroll.sensitivity == 0.30 && loaded.shortcut == nil,
                            "invalid sibling erased valid exclusions")
                try require(defaults.object(forKey: "mode") == nil, "mode was persisted")
            }
        }
        test("every session setter preserves siblings and exclusion edits are non-destructive after Quit") {
            try withStore { store, _ in
                let fake = FakeHotKeys()
                let session = LiveSession(store: store, hotKeyAPI: fake.api)
                defer { session.teardown() }
                let app = ApplicationID("org.example.App")!
                let key = try Shortcut(keyCode: UInt32(kVK_F20), modifiers: UInt32(shiftKey))
                session.setScroll(ScrollSettings(sensitivity: 0.15, reversed: true))
                session.setShortcut(key)
                session.setExcludedApps([app])
                let expected = Configuration(scroll: ScrollSettings(sensitivity: 0.15, reversed: true), shortcut: key, excludedApps: [app])
                try require(session.configuration == expected && (try store.load(environment: [:])) == expected, "add lost siblings")
                session.setScroll(ScrollSettings(sensitivity: 2))
                session.setShortcut(nil)
                try require(session.configuration.excludedApps == [app] && session.configuration.scroll.sensitivity == 2,
                            "sibling edits erased exclusions")
                session.setExcludedApps([])
                try require(session.configuration.scroll.sensitivity == 2 && session.configuration.shortcut == nil &&
                            (try store.load(environment: [:])) == session.configuration, "remove reset siblings")
                session.requestQuit()
                session.setExcludedApps([app])
                try require(session.configuration.excludedApps.isEmpty && (try store.load(environment: [:])).excludedApps.isEmpty,
                            "Quit accepted late config")
            }
        }
        test("pointer resolver validates exact window metadata and owner PID before bundle lookup") {
            var metadata: [[String: Any]]? = [[kCGWindowNumber as String: 42, kCGWindowOwnerPID as String: 700]]
            var windows: [CGWindowID] = []
            var pids: [pid_t] = []
            var identifier: String? = "org.example.Target"
            let resolver = PointerTargetResolver(windowInfo: { windows.append($0); return metadata },
                                                 bundleIdentifier: { pids.append($0); return identifier })
            let app = resolver.application(forWindow: 42)
            try require(app?.pid == 700 && app?.id == ApplicationID("org.example.Target") && windows == [42] && pids == [700],
                        "exact pointer-window owner not used")
            for invalid: Any in [true, 0, -1, 1.5, Double.infinity, Double.nan, Double(pid_t.max) + 1, "700"] {
                metadata = [[kCGWindowNumber as String: 42, kCGWindowOwnerPID as String: invalid]]
                let count = pids.count
                try require(resolver.application(forWindow: 42) == nil && pids.count == count, "invalid owner looked up: \(invalid)")
            }
            for invalid: Any in [true, 0, -1, 42.5, 43, "42", Double(CGWindowID.max) + 1] {
                metadata = [[kCGWindowNumber as String: invalid, kCGWindowOwnerPID as String: 700]]
                let count = pids.count
                try require(resolver.application(forWindow: 42) == nil && pids.count == count, "wrong/malformed window accepted")
            }
            for missing in [nil, [], [[:]]] as [[[String: Any]]?] {
                metadata = missing
                try require(resolver.application(forWindow: 42) == nil, "missing metadata accepted")
            }
            metadata = [[kCGWindowNumber as String: 42, kCGWindowOwnerPID as String: 700]]
            for invalid in [nil, "", "*", "com..app"] as [String?] {
                identifier = invalid
                try require(resolver.application(forWindow: 42) == nil, "invalid/disappeared app accepted")
            }
            let count = windows.count
            for invalid in [0, -1, Int(CGWindowID.max) + 1] {
                try require(resolver.application(forWindow: invalid) == nil, "invalid window number accepted")
            }
            try require(windows.count == count, "invalid window reached OS boundary")
        }
        test("exclusions use the inactive pointer window owner, pass unknowns only when active, and skip empty-set lookups") {
            let app = ApplicationID("org.example.PointerTarget")!
            let session = LiveSession(configuration: Configuration(excludedApps: [app]))
            session.lifecycle.observationStarted(leftButtonHeld: false)
            session.lifecycle.setEnabled(true)
            var target = 42
            var hits = 0
            var lookups = 0
            var point: CGPoint?
            var id: String? = app.rawValue
            session.windowAtPoint = { hits += 1; point = $0; return target }
            session.targetResolver = PointerTargetResolver(windowInfo: {
                lookups += 1
                return [[kCGWindowNumber as String: $0, kCGWindowOwnerPID as String: 700]]
            }, bundleIdentifier: { _ in id })
            var output: [CGEvent] = []
            func send(_ event: CGEvent) -> CGEvent? { session.lifecycle.handle(event.type, event, post: { output.append($0) }) }
            let down = mouse(.leftMouseDown, 123, 234)
            try require(send(down) === down && point == down.unflippedLocation && hits == 1 && lookups == 1,
                        "pointer owner was replaced by focus or coordinates changed")
            target = 99
            id = "org.example.NotExcluded"
            session.setExcludedApps([])
            session.lifecycle.setEnabled(false)
            session.lifecycle.setEnabled(true)
            for event in [mouse(.leftMouseDragged, 800), mouse(.leftMouseUp, 800)] {
                try require(send(event) === event, "mid-contact edits stole original excluded object")
            }
            try require(hits == 1 && lookups == 1 && output.isEmpty, "passed contact re-resolved or emitted")
            session.setExcludedApps([app])
            try require(send(mouse(.leftMouseDown)) == nil, "different pointer app was excluded by focus")
            _ = send(mouse(.leftMouseUp, 120))
            try require(output.count == 1 && output[0].type == .scrollWheel, "nonexcluded inactive window did not pan")
            id = nil
            let unknown = mouse(.leftMouseDown)
            try require(send(unknown) === unknown, "unresolved active exclusion intercepted")
            let up = mouse(.leftMouseUp)
            try require(send(up) === up, "unresolved release changed")
            session.setExcludedApps([])
            let before = (hits, lookups)
            try require(send(mouse(.leftMouseDown)) == nil, "empty-set unknown changed baseline")
            _ = send(mouse(.leftMouseUp, 120))
            try require(hits == before.0 && lookups == before.1, "empty exclusions resolved window/app without helper UI")
        }
        test("exclusion edits preserve pending, panning and draining contact ownership") {
            for panning in [false, true] {
                let app = ApplicationID("org.example.App")!
                let session = LiveSession()
                session.lifecycle.observationStarted(leftButtonHeld: false)
                session.lifecycle.setEnabled(true)
                session.windowAtPoint = { _ in 42 }
                session.targetResolver = PointerTargetResolver(windowInfo: {
                    [[kCGWindowNumber as String: $0, kCGWindowOwnerPID as String: 700]]
                }, bundleIdentifier: { _ in app.rawValue })
                var output: [CGEvent] = []
                func send(_ event: CGEvent) -> CGEvent? { session.lifecycle.handle(event.type, event, post: { output.append($0) }) }
                _ = send(mouse(.leftMouseDown))
                if panning { _ = send(mouse(.leftMouseDragged, 110)) }
                session.setExcludedApps([app])
                _ = send(mouse(.leftMouseUp, 120))
                try require(!output.isEmpty && output.allSatisfy { $0.type == .scrollWheel }, "edit stole owned contact")
                let excluded = mouse(.leftMouseDown)
                try require(send(excluded) === excluded, "new exclusion did not apply")
                _ = send(mouse(.leftMouseUp))
                session.setExcludedApps([])
                _ = send(mouse(.leftMouseDown))
                session.lifecycle.setEnabled(false)
                session.setExcludedApps([app])
                session.lifecycle.setEnabled(true)
                let before = output.count
                try require(send(mouse(.leftMouseDragged, 140)) == nil && send(mouse(.leftMouseUp, 140)) == nil &&
                            output.count == before && session.lifecycle.contact == .idle, "exclusion edit revived draining contact")
            }
        }
        test("application package boundary validates local app identity, package type and executable") {
            try withApplicationFixture { url in
                let selected = try SelectedApplication(url: url)
                try require(selected.id == ApplicationID("org.penpan.Fixture") && selected.name == "Fixture application", "valid package not decoded")
            }
            func rejected(_ url: URL) throws {
                do { _ = try SelectedApplication(url: url); throw Failure("accepted malformed package") }
                catch let error as Failure { try require(error.description.contains("Choose a local .app"), error.description) }
            }
            try withApplicationFixture(identifier: "*") { try rejected($0) }
            try withApplicationFixture(identifier: 7) { try rejected($0) }
            try withApplicationFixture(packageType: "BNDL") { try rejected($0) }
            try withApplicationFixture(executable: false) { try rejected($0) }
            try withApplicationFixture(extension: "folder") { try rejected($0) }
            try withApplicationFixture { url in
                let executable = url.appendingPathComponent("Contents/MacOS/fixture")
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
                try rejected(url)
            }
            try rejected(URL(string: "https://example.invalid/Fixture.app")!)
            try rejected(FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).app"))
        }
        test("all eight explicit F13-F20 keys validate, label, conflict, repeat-latch and Clear through the session") {
            let codes = [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
            for (offset, code) in codes.enumerated() {
                let bare = try Shortcut(keyCode: UInt32(code), modifiers: 0)
                try require(bare.label == "F\(13 + offset)", "SDK key map label differs")
                for modifiers in [UInt32(shiftKey), UInt32(controlKey | optionKey | cmdKey | shiftKey)] {
                    _ = try Shortcut(keyCode: UInt32(code), modifiers: modifiers)
                }
                let fake = FakeHotKeys()
                let session = LiveSession(hotKeyAPI: fake.api)
                defer { session.teardown() }
                session.lifecycle.observationStarted(leftButtonHeld: false)
                let old = try Shortcut(keyCode: 35, modifiers: UInt32(controlKey))
                session.setShortcut(old)
                fake.conflict.insert(bare.keyCode)
                session.recording.begin()
                session.recording.press(bare)
                session.recording.release(keyCode: bare.keyCode)
                try require(session.configuration.shortcut == old && session.settingsError != nil, "Fn conflict replaced old binding")
                fake.conflict = []
                session.recording.begin()
                session.recording.press(bare)
                session.recording.cancel()
                session.recording.release(keyCode: bare.keyCode)
                try require(session.configuration.shortcut == old, "cancelled Fn recording committed")
                session.recording.begin()
                session.recording.press(bare)
                session.recording.release(keyCode: bare.keyCode)
                let id = fake.registered.last!.1
                session.hotKeys.receive(id: id, pressed: true)
                session.hotKeys.receive(id: id, pressed: true)
                try require(session.configuration.shortcut == bare && session.lifecycle.mode == .on, "Fn registration/repeat toggled incorrectly")
                session.hotKeys.receive(id: id, pressed: false)
                session.hotKeys.receive(id: id, pressed: true)
                try require(session.lifecycle.mode == .off, "Fn release did not rearm")
                session.setShortcut(nil)
                try require(fake.active.isEmpty && session.configuration.shortcut == nil, "Fn Clear retained binding")
            }
            for code in [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                         kVK_ANSI_A, kVK_ANSI_1, kVK_Space, kVK_Shift, kVK_Function, kVK_VolumeUp, kVK_VolumeDown, kVK_Mute] {
                for modifiers in [UInt32(0), UInt32(shiftKey)] {
                    do { _ = try Shortcut(keyCode: UInt32(code), modifiers: modifiers); throw Failure("accepted unsafe standalone key") }
                    catch let error as Failure { try require(error.description.contains("Use Control"), error.description) }
                }
            }
        }
    }

    private final class DownControl: NSView {
        var downs = 0
        var ups = 0
        var counts: [Int] = []
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { downs += 1; counts.append(event.clickCount) }
        override func mouseUp(with event: NSEvent) { ups += 1 }
    }
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private final class ButtonTarget: NSObject {
        var clicks = 0
        @objc func clicked(_ sender: NSButton) { clicks += 1 }
    }
    private final class ClickButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private static func native() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let control = DownControl(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let scroll = NSScrollView(frame: NSRect(x: 300, y: 0, width: 300, height: 300))
        window.contentView!.addSubview(control)
        window.contentView!.addSubview(scroll)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 1200, height: 1200))
        let target = ButtonTarget()
        let button = ClickButton(frame: NSRect(x: 20, y: 20, width: 200, height: 50))
        button.title = "Tap test"
        button.target = target
        button.action = #selector(ButtonTarget.clicked(_:))
        control.addSubview(button)
        window.orderBack(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        defer { window.orderOut(nil) }
        // The fixture never activates or posts globally. Only this window receives mouse events.
        func deliver(_ cg: CGEvent) {
            let ns = NSEvent(cgEvent: cg)!
            if cg.type == .scrollWheel {
                scroll.scrollWheel(with: ns)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            } else {
                let local = NSEvent.mouseEvent(with: ns.type, location: NSPoint(x: 100, y: 100),
                                               modifierFlags: ns.modifierFlags, timestamp: ns.timestamp,
                                               windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 0, clickCount: ns.clickCount, pressure: ns.pressure)!
                window.sendEvent(local)
            }
        }
        test("native down-sensitive control acts immediately on forwarded down (A premise)") {
            deliver(mouse(.leftMouseDown))
            try require(control.downs == 1 && control.ups == 0, "fixture did not observe down side effect")
            deliver(mouse(.leftMouseUp))
        }
        test("native B pan has zero button side effects; tap/double-click reach control") {
            let lifecycle = Lifecycle(adapter: EventAdapter(gesture: Gesture(settings: ScrollSettings(sensitivity: 1, threshold: 2), doubleClickInterval: 0.5)))
            lifecycle.observationStarted(leftButtonHeld: false)
            lifecycle.setEnabled(true)
            func send(_ event: CGEvent) {
                if let forwarded = lifecycle.handle(event.type, event, post: deliver) { deliver(forwarded) }
            }
            let before = control.downs
            send(mouse(.leftMouseDown))
            try require(control.downs == before, "early native side effect")
            send(mouse(.leftMouseDragged, 100, 120))
            send(mouse(.leftMouseUp, 100, 120))
            try require(control.downs == before && control.ups == before, "pan emitted buttons")
            send(mouse(.leftMouseDown, time: 2))
            send(mouse(.leftMouseUp, time: 2.05))
            send(mouse(.leftMouseDown, count: 2, time: 2.2))
            send(mouse(.leftMouseUp, count: 2, time: 2.25))
            try require(control.downs == before + 2 && control.ups == before + 2, "native click pair missing")
            try require(Array(control.counts.suffix(2)) == [1, 2], "native double-click metadata lost")
        }
        test("native NSScrollView content follows pen in both axes and opposite directions") {
            func pan(_ dx: Double, _ dy: Double) -> CGPoint {
                scroll.contentView.scroll(to: NSPoint(x: 400, y: 400))
                scroll.reflectScrolledClipView(scroll.contentView)
                let trace = LifecycleTrace()
                trace.send(mouse(.leftMouseDown))
                trace.send(mouse(.leftMouseDragged, 100 + dx, 100 + dy))
                trace.send(mouse(.leftMouseUp, 100 + dx, 100 + dy))
                for output in trace.output { deliver(output) }
                return scroll.contentView.bounds.origin
            }
            let downRight = pan(20, 20)
            let upLeft = pan(-20, -20)
            print("NATIVE pen(+20,+20) -> document origin \(downRight); pen(-20,-20) -> \(upLeft); start=(400,400)")
            try require(abs(downRight.x - 380) < 0.01 && abs(downRight.y - 380) < 0.01,
                        "content did not follow down/right drag: \(downRight)")
            try require(abs(upLeft.x - 420) < 0.01 && abs(upLeft.y - 420) < 0.01,
                        "content did not follow up/left drag: \(upLeft)")
        }
        test("native NSButton action fires for pen taps and mouse clicks, never for pen pans") {
            func clickPair(_ events: [CGEvent]) throws {
                let clicks = events.filter { $0.type == .leftMouseDown || $0.type == .leftMouseUp }
                try require(clicks.count.isMultiple(of: 2), "unpaired native click")
                for index in stride(from: 0, to: clicks.count, by: 2) {
                    let native = clicks[index...index + 1].map { cg -> NSEvent in
                        let ns = NSEvent(cgEvent: cg)!
                        return NSEvent.mouseEvent(with: ns.type, location: NSPoint(x: 80, y: 40),
                                                  modifierFlags: ns.modifierFlags, timestamp: ns.timestamp,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: ns.clickCount, pressure: ns.pressure)!
                    }
                    app.postEvent(native[1], atStart: true)
                    window.sendEvent(native[0])
                }
            }
            let before = target.clicks
            try clickPair([mouse(.leftMouseDown, subtype: 0), mouse(.leftMouseUp, subtype: 0)])
            try require(target.clicks == before + 1, "raw mouse positive control failed; native fixture is inconclusive")
            for (name, events, expected, enabled) in [
                ("stationary pen tap", [mouse(.leftMouseDown), mouse(.leftMouseUp)], 1, true),
                ("jitter pen tap", [mouse(.leftMouseDown), mouse(.leftMouseDragged, 101), mouse(.leftMouseUp, 101)], 1, true),
                ("pen pan", [mouse(.leftMouseDown), mouse(.leftMouseDragged, 120), mouse(.leftMouseUp, 120)], 0, true),
                ("ordinary mouse click", [mouse(.leftMouseDown, subtype: 0), mouse(.leftMouseUp, subtype: 0)], 1, true),
                ("OFF pen tap", [mouse(.leftMouseDown), mouse(.leftMouseUp)], 1, false)
            ] {
                let trace = LifecycleTrace(enabled: enabled)
                for event in events { trace.send(event) }
                let count = target.clicks
                try clickPair(trace.output)
                try require(target.clicks - count == expected,
                            "\(name) produced \(target.clicks - count) NSButton actions, expected \(expected)")
                print("NATIVE \(name): NSButton actions=\(expected)")
            }
        }
        test("native OFF restores immediate pen down and ON preserves the passed release") {
            let trace = LifecycleTrace(enabled: false)
            func send(_ event: CGEvent) {
                if let forwarded = trace.send(event) { deliver(forwarded) }
            }
            let beforeDowns = control.downs
            let beforeUps = control.ups
            send(mouse(.leftMouseDown))
            try require(control.downs == beforeDowns + 1 && control.ups == beforeUps, "OFF deferred ordinary pen down")
            trace.lifecycle.setEnabled(true)
            send(mouse(.leftMouseDragged, 110))
            send(mouse(.leftMouseUp, 110))
            try require(control.downs == beforeDowns + 1 && control.ups == beforeUps + 1, "ON lost passed release")
            send(mouse(.leftMouseDown))
            trace.lifecycle.setEnabled(false)
            send(mouse(.leftMouseUp))
            try require(control.downs == beforeDowns + 1 && control.ups == beforeUps + 1, "OFF cancellation clicked")
            send(mouse(.leftMouseDown))
            send(mouse(.leftMouseUp))
            try require(control.downs == beforeDowns + 2 && control.ups == beforeUps + 2, "OFF not restored after drain")
        }
        test("native menu actions and checkmark follow OFF/passed/ON/draining/quit lifecycle") {
            let session = LiveSession(configuration: Configuration(scroll: ScrollSettings(sensitivity: 1, threshold: 2)))
            session.createTap = { _, _ in nil }
            session.lifecycle.observationStarted(leftButtonHeld: false)
            let control = MenuControl(session: session)
            session.changed = { [weak control] in control?.refresh() }
            defer { session.changed = {} }
            func action(_ item: NSMenuItem) throws {
                try require(item.keyEquivalent.isEmpty && item.isEnabled, "unexpected shortcut or disabled action")
                try require(app.sendAction(item.action!, to: item.target, from: item), "private menu action not routed")
            }
            try require(control.toggle.state == .off && control.status.title == "OFF", "initial menu not OFF")
            let down = mouse(.leftMouseDown)
            try require(session.lifecycle.handle(down.type, down, post: { _ in }) === down, "OFF not ordinary")
            try action(control.toggle)
            try require(control.toggle.state == .on && control.toggle.title == "Turn OFF" &&
                        control.status.title == "ON, waiting for release", "ON passed status inaccurate")
            let up = mouse(.leftMouseUp)
            try require(session.lifecycle.handle(up.type, up, post: { _ in }) === up, "ON stole passed release")
            _ = session.lifecycle.handle(down.type, down, post: { _ in })
            try action(control.toggle)
            try require(control.toggle.state == .off && control.status.title == "OFF, draining", "OFF drain not visible")
            try action(control.toggle)
            try require(control.toggle.state == .on && control.status.title == "ON, waiting for release", "drain revived or status inaccurate")
            try action(control.quit)
            try require(!control.toggle.isEnabled && !control.quit.isEnabled &&
                        control.status.title == "Quitting, waiting for release", "quit not terminal/visible")
            var posted = 0
            _ = session.lifecycle.handle(up.type, up, post: { _ in posted += 1 })
            control.refresh()
            try require(session.lifecycle.finished && posted == 0 && control.toggle.state == .off, "quit failed to drain")
            control.remove()
        }
        test("native menu failed attachment stays OFF and Retry ON uses production failure path") {
            let session = LiveSession(configuration: Configuration(scroll: ScrollSettings(sensitivity: 1, threshold: 2)))
            var attempts = 0
            session.createTap = { _, _ in attempts += 1; return nil }
            let control = MenuControl(session: session)
            for _ in 0..<2 {
                try require(app.sendAction(control.toggle.action!, to: control.toggle.target, from: control.toggle), "retry action not routed")
                try require(control.toggle.state == .off && control.toggle.title == "Retry ON" &&
                            control.status.title.contains("OFF: could not create event tap") &&
                            !session.lifecycle.observing && session.tap == nil, "failure misrepresented as ON")
            }
            try require(attempts == 2, "retry did not attempt installation")
            try require(app.sendAction(control.quit.action!, to: control.quit.target, from: control.quit), "failed menu cannot quit")
            try require(session.lifecycle.finished && !control.toggle.isEnabled, "failed menu quit not terminal")
            try require(app.sendAction(control.toggle.action!, to: control.toggle.target, from: control.toggle), "fixture cannot probe terminal action")
            try require(attempts == 2, "terminal menu retried installation")
        }
        withExtendedLifetime(window) {}
    }

    // Only key-window status is simulated so the fixture never activates this application.
    private final class RecorderWindow: NSWindow {
        var recorderKey = true
        override var isKeyWindow: Bool { recorderKey }
        convenience init() {
            self.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
        }
    }

    private static func settingsNative() {
        let app = NSApplication.shared
        test("native Settings window reuses controls, labels and app-local actions persist configuration") {
            try withStore { store, _ in
                let fake = FakeHotKeys()
                let session = LiveSession(store: store, hotKeyAPI: fake.api)
                defer { session.teardown() }
                session.prepareSettings()
                let settings = session.settingsControl!
                session.prepareSettings()
                try require(session.settingsControl === settings, "settings recreated")
                settings.window.orderBack(nil)
                settings.window.contentView!.layoutSubtreeIfNeeded()
                try require(settings.window.accessibilityIdentifier() == "penpan.settings.window" &&
                            settings.sensitivity.accessibilityIdentifier() == "penpan.sensitivity.slider" &&
                            settings.value.accessibilityIdentifier() == "penpan.sensitivity.value" &&
                            settings.reverse.accessibilityIdentifier() == "penpan.reverse.checkbox" &&
                            settings.recorder.accessibilityIdentifier() == "penpan.shortcut.recorder" &&
                            settings.clear.accessibilityIdentifier() == "penpan.shortcut.clear", "identifiers missing")
                try require(settings.sensitivity.accessibilityLabel() == "Scroll sensitivity" &&
                            settings.recorder.accessibilityLabel() == "Toggle shortcut recorder", "labels missing")
                settings.sensitivity.doubleValue = 0.15
                try require(settings.sensitivity.sendAction(settings.sensitivity.action, to: settings.sensitivity.target), "slider action not routed")
                settings.reverse.performClick(nil)
                try require(session.configuration.scroll.sensitivity == 0.15 && session.configuration.scroll.reversed &&
                            settings.value.stringValue == "0.15x", "native controls not applied")
                try require(try store.load(environment: [:]) == session.configuration, "native UI settings not saved")
                let content = settings.window.contentView!
                for view in [settings.sensitivity, settings.value, settings.axes, settings.reverse, settings.optionNative,
                             settings.inputHint, settings.recorder, settings.clear, settings.message] {
                    let frame = view.convert(view.bounds, to: content)
                    try require(content.bounds.contains(frame), "control clipped: \(view) at \(frame)")
                }
                let menu = MenuControl(session: session)
                try require(menu.menu.items.count == 4 && menu.settings.title == "Settings..." && menu.settings.keyEquivalent.isEmpty &&
                            menu.settings.accessibilityIdentifier() == "penpan.settings.menu", "menu did not retain ON/OFF/Settings/Quit")
                session.requestQuit()
                menu.refresh()
                try require(!menu.settings.isEnabled, "quitting settings action enabled")
            }
        }
        test("native settings-target gate uses unflipped coordinates and passes pen drag through release only there") {
            let fake = FakeHotKeys()
            let session = LiveSession(hotKeyAPI: fake.api)
            defer { session.teardown() }
            session.prepareSettings()
            let settings = session.settingsControl!
            settings.window.orderBack(nil)
            session.lifecycle.observationStarted(leftButtonHeld: false)
            session.lifecycle.setEnabled(true)
            var point: CGPoint?
            var target = settings.window.windowNumber
            session.windowAtPoint = { point = $0; return target }
            let down = mouse(.leftMouseDown, 123, 234)
            try require(session.lifecycle.handle(down.type, down, post: { _ in }) === down &&
                        point == down.unflippedLocation, "native targeting coordinate boundary differs")
            target = settings.window.windowNumber + 123
            for type in [CGEventType.leftMouseDragged, .leftMouseUp] {
                let event = mouse(type, 800, 900)
                try require(session.lifecycle.handle(type, event, post: { _ in }) === event, "own slider drag lost outside window")
            }
            var output: [CGEvent] = []
            _ = session.lifecycle.handle(.leftMouseDown, mouse(.leftMouseDown), post: { output.append($0) })
            target = settings.window.windowNumber
            _ = session.lifecycle.handle(.leftMouseUp, mouse(.leftMouseUp, 120), post: { output.append($0) })
            try require(output.count == 1 && output[0].type == .scrollWheel, "open settings disabled another app/owned pan")
            settings.window.orderOut(nil)
            output = []
            _ = session.lifecycle.handle(.leftMouseDown, mouse(.leftMouseDown), post: { output.append($0) })
            _ = session.lifecycle.handle(.leftMouseUp, mouse(.leftMouseUp, 120), post: { output.append($0) })
            try require(output.count == 1 && output[0].type == .scrollWheel, "hidden window exempted stale target")
        }
        test("native focused shortcut recorder captures Command locally and commits only on release; Clear unregisters") {
            try withStore { store, _ in
                let fake = FakeHotKeys()
                let session = LiveSession(store: store, hotKeyAPI: fake.api)
                defer { session.teardown() }
                session.prepareSettings(window: RecorderWindow())
                let settings = session.settingsControl!
                settings.window.orderBack(nil)
                try require(settings.window.isKeyWindow, "private key-status seam failed")
                settings.recorder.performClick(nil)
                try require(session.recording.active && settings.window.firstResponder === settings.recorder, "recorder not focused")
                func key(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags,
                         repeatKey: Bool = false) -> NSEvent {
                    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 1,
                                     windowNumber: settings.window.windowNumber, context: nil, characters: "p",
                                     charactersIgnoringModifiers: "p", isARepeat: repeatKey, keyCode: code)!
                }
                let down = key(.keyDown, 35, [.command, .option])
                try require(settings.window.performKeyEquivalent(with: down), "Command equivalent escaped recorder")
                settings.recorder.keyDown(with: key(.keyDown, 35, [.command, .option], repeatKey: true))
                try require(fake.registered.isEmpty && session.configuration.shortcut == nil, "registered before release")
                settings.window.sendEvent(key(.keyUp, 35, [.command, .option]))
                try require(fake.active.count == 1 && session.configuration.shortcut?.modifiers == UInt32(cmdKey | optionKey) &&
                            settings.recorder.title == "⌥⌘P", "recorded release not committed/displayed")
                try require(try store.load(environment: [:]).shortcut == session.configuration.shortcut, "recorded binding not persisted")
                settings.clear.performClick(nil)
                try require(fake.active.isEmpty && session.configuration.shortcut == nil && !settings.clear.isEnabled,
                            "Clear failed to unregister/reset UI")
            }
        }
        test("native recorder cancels Escape, focus loss, close and deactivation without changing old binding") {
            let fake = FakeHotKeys()
            let session = LiveSession(hotKeyAPI: fake.api)
            defer { session.teardown() }
            let first = try Shortcut(keyCode: 35, modifiers: UInt32(controlKey))
            session.setShortcut(first)
            let privateWindow = RecorderWindow()
            session.prepareSettings(window: privateWindow)
            let settings = session.settingsControl!
            settings.window.orderBack(nil)
            func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                                 windowNumber: settings.window.windowNumber, context: nil, characters: "a",
                                 charactersIgnoringModifiers: "a", isARepeat: false, keyCode: code)!
            }
            settings.recorder.performClick(nil)
            settings.recorder.keyDown(with: key(0))
            try require(session.configuration.shortcut == first && session.recording.state == .listening &&
                        settings.message.stringValue.contains("Use Control"), "bare key accepted or failure hidden")
            settings.recorder.keyDown(with: key(53))
            try require(!session.recording.active && session.configuration.shortcut == first, "Escape changed old binding")
            settings.recorder.performClick(nil)
            _ = settings.window.makeFirstResponder(settings.sensitivity)
            try require(!session.recording.active, "focus loss not cancelled")
            try require(!settings.recorder.performKeyEquivalent(with: key(0, .command)), "unfocused recorder intercepted typing")
            settings.recorder.performClick(nil)
            privateWindow.recorderKey = false
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: privateWindow)
            try require(!session.recording.active, "key-window loss not cancelled")
            settings.recorder.performClick(nil)
            try require(!session.recording.active, "inactive window started recording")
            privateWindow.recorderKey = true
            settings.recorder.performClick(nil)
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
            try require(!session.recording.active, "deactivation not cancelled")
            settings.recorder.performClick(nil)
            settings.window.performClose(nil)
            try require(!session.recording.active && session.configuration.shortcut == first && fake.active.count == 1,
                        "window close committed/lost binding")
        }
        test("native Command release bridge commits only for the focused recorder and leaves other input unchanged") {
            let fake = FakeHotKeys()
            let session = LiveSession(hotKeyAPI: fake.api)
            defer { session.teardown() }
            session.prepareSettings(window: RecorderWindow())
            let settings = session.settingsControl!
            settings.window.orderBack(nil)
            func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags) -> NSEvent {
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 1,
                                 windowNumber: settings.window.windowNumber, context: nil, characters: "p",
                                 charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)!
            }
            let down = event(.keyDown, [.command, .option])
            let up = event(.keyUp, [.command, .option])
            try require(settings.recorder.routeCommandRelease(up) === up, "idle recorder consumed a key release")
            settings.recorder.performClick(nil)
            try require(settings.window.performKeyEquivalent(with: down), "Command down did not reach recorder")
            try require(fake.registered.isEmpty && session.recording.active, "committed before release")
            try require(settings.recorder.routeCommandRelease(down) === down, "release bridge consumed key down")
            let ordinary = event(.keyUp, .option)
            try require(settings.recorder.routeCommandRelease(ordinary) === ordinary, "release bridge consumed non-Command input")
            try require(settings.recorder.routeCommandRelease(up) == nil && fake.active.count == 1 &&
                        !session.recording.active && settings.recorder.title == "⌥⌘P", "focused Command release failed to commit")
            try require(settings.recorder.routeCommandRelease(up) === up && fake.registered.count == 1,
                        "release was delivered twice")
            _ = settings.window.makeFirstResponder(settings.sensitivity)
            session.recording.begin()
            try require(settings.recorder.routeCommandRelease(up) === up, "unfocused recorder consumed a key release")
            session.recording.cancel()
            settings.remove()
            settings.remove()
            try require(settings.recorder.routeCommandRelease(up) === up, "removed settings retained release capture")
        }
        test("native Carbon application-target handler dispatches injected press/release IDs without global registration") {
            let fake = FakeHotKeys()
            let session = LiveSession(hotKeyAPI: fake.api)
            defer { session.teardown() }
            session.lifecycle.observationStarted(leftButtonHeld: false)
            let shortcut = try Shortcut(keyCode: 35, modifiers: UInt32(controlKey | optionKey))
            session.setShortcut(shortcut)
            let id = fake.registered.last!.1
            func send(_ pressed: Bool, _ eventID: UInt32, signature: OSType = HotKeyAPI.signature) throws {
                var event: EventRef?
                try require(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(pressed ? kEventHotKeyPressed : kEventHotKeyReleased),
                                        0, EventAttributes(kEventAttributeUserEvent), &event) == noErr, "Carbon event allocation failed")
                defer { ReleaseEvent(event!) }
                var hotKeyID = EventHotKeyID(signature: signature, id: eventID)
                try require(SetEventParameter(event!, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                              MemoryLayout<EventHotKeyID>.size, &hotKeyID) == noErr, "Carbon event payload failed")
                _ = SendEventToEventTarget(event!, GetApplicationEventTarget())
            }
            try send(true, id + 1)
            try send(true, id, signature: 0)
            try require(session.lifecycle.mode == .off, "stale/foreign Carbon ID toggled")
            try send(true, id)
            try send(true, id)
            try require(session.lifecycle.mode == .on, "Carbon repeat toggled twice")
            try send(false, id)
            session.recording.begin()
            try send(true, id)
            try require(session.lifecycle.mode == .on && session.recording.state == .held(shortcut), "Carbon shortcut toggled during recording")
            try send(false, id)
            try require(session.lifecycle.mode == .on && !session.recording.active && fake.registered.count == 1,
                        "same shortcut release replaced/toggled")
            try send(true, id)
            try require(session.lifecycle.mode == .off, "Carbon release did not rearm")
            session.requestQuit()
            try send(true, id)
            try require(session.lifecycle.mode == .quitting && fake.active.isEmpty, "Carbon teardown did not release")
        }
        test("native NSScrollView applies fresh 0.30x and reversal in both axes") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
            scroll.hasHorizontalScroller = true
            scroll.hasVerticalScroller = true
            scroll.usesPredominantAxisScrolling = false
            scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 1200, height: 1200))
            window.contentView = scroll
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            for reversed in [false, true] {
                scroll.contentView.scroll(to: CGPoint(x: 400, y: 400))
                scroll.reflectScrolledClipView(scroll.contentView)
                let trace = LifecycleTrace(settings: ScrollSettings(reversed: reversed))
                trace.send(mouse(.leftMouseDown))
                trace.send(mouse(.leftMouseUp, 120, 120))
                for event in trace.output { scroll.scrollWheel(with: NSEvent(cgEvent: event)!) }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
                let expected = reversed ? 406.0 : 394.0
                let origin = scroll.contentView.bounds.origin
                print("NATIVE settings 0.30x reversed=\(reversed): document origin \(origin); start=(400,400)")
                try require(abs(origin.x - expected) < 0.01 && abs(origin.y - expected) < 0.01,
                            "native scale/reversal wrong: \(origin)")
            }
        }
    }

    private final class ApplicationRowsProbe: NSObject, NSTableViewDataSource {
        unowned let settings: SettingsControl
        var reads = 0
        init(_ settings: SettingsControl) { self.settings = settings }
        func numberOfRows(in tableView: NSTableView) -> Int { reads += 1; return settings.applicationRows.count }
    }

    private static func exclusionsNative() {
        let app = NSApplication.shared
        test("native grouped Settings live toggle follows retry, hotkey, input, drain and Quit without app-list reloads") {
            let fake = FakeHotKeys()
            let session = LiveSession(hotKeyAPI: fake.api)
            defer { session.teardown() }
            var attempts = 0
            session.createTap = { _, _ in attempts += 1; return nil }
            session.prepareSettings(window: RecorderWindow())
            let settings = session.settingsControl!
            settings.window.orderBack(nil)
            let menu = MenuControl(session: session)
            session.changed = { menu.refresh() }
            try require(settings.status.stringValue == "OFF, not observing" && settings.toggle.title == "Retry ON", "initial Settings status wrong")
            settings.toggle.performClick(nil)
            try require(attempts == 1 && settings.status.stringValue.contains("OFF: could not create event tap") &&
                        settings.toggle.title == "Retry ON" && menu.toggle.state == .off, "Settings retry diverged from menu")
            session.lifecycle.observationStarted(leftButtonHeld: false)
            session.notifyChanged()
            try require(settings.toggle.title == "Turn ON", "available OFF action wrong")
            let key = try Shortcut(keyCode: UInt32(kVK_F13), modifiers: 0)
            session.setShortcut(key)
            let identifier = ApplicationID("org.example.Target")!
            session.setExcludedApps([identifier])
            session.windowAtPoint = { _ in 42 }
            session.targetResolver = PointerTargetResolver(windowInfo: {
                [[kCGWindowNumber as String: $0, kCGWindowOwnerPID as String: 700]]
            }, bundleIdentifier: { _ in identifier.rawValue })
            let probe = ApplicationRowsProbe(settings)
            settings.applications.dataSource = probe
            settings.applications.reloadData()
            settings.window.contentView!.layoutSubtreeIfNeeded()
            let reads = probe.reads
            settings.toggle.performClick(nil)
            try require(settings.status.stringValue == "ON" && settings.toggle.title == "Turn OFF" && menu.toggle.state == .on,
                        "Settings toggle did not use session lifecycle")
            var output: [CGEvent] = []
            func send(_ event: CGEvent) -> CGEvent? {
                let result = session.lifecycle.handle(event.type, event, post: { output.append($0) })
                session.notifyChanged()
                return result
            }
            let down = mouse(.leftMouseDown)
            try require(send(down) === down && settings.status.stringValue == "ON, waiting for release", "input status not live")
            for _ in 0..<100 { let drag = mouse(.leftMouseDragged, 130); try require(send(drag) === drag, "passed drag changed") }
            _ = send(mouse(.leftMouseUp))
            try require(settings.status.stringValue == "ON" && probe.reads == reads && output.isEmpty,
                        "drag notifications reloaded app rows or status did not clear")
            let id = fake.registered.last!.1
            session.hotKeys.receive(id: id, pressed: true)
            try require(settings.status.stringValue == "OFF" && settings.toggle.title == "Turn ON" && menu.toggle.state == .off,
                        "hotkey status not reflected in Settings")
            session.hotKeys.receive(id: id, pressed: false)
            session.setExcludedApps([])
            try require(probe.reads > reads, "configuration change did not reload app rows")
            settings.toggle.performClick(nil)
            _ = send(mouse(.leftMouseDown))
            settings.toggle.performClick(nil)
            try require(settings.status.stringValue == "OFF, draining", "Settings omitted drain")
            settings.toggle.performClick(nil)
            try require(settings.status.stringValue == "ON, waiting for release", "Settings revived drain")
            session.requestQuit()
            try require(settings.status.stringValue == "Quitting, waiting for release" && !settings.toggle.isEnabled, "Settings omitted terminal wait")
            _ = send(mouse(.leftMouseUp))
            try require(settings.status.stringValue == "Quitting" && session.lifecycle.finished && output.isEmpty, "Quit status did not finish")
        }
        test("native picker Add, duplicate, invalid, cancel and Remove preserve sibling settings and selection") {
            try withStore { store, _ in
                try withApplicationFixture { url in
                    let fake = FakeHotKeys()
                    let key = try Shortcut(keyCode: UInt32(kVK_F20), modifiers: UInt32(shiftKey))
                    let session = LiveSession(configuration: Configuration(scroll: ScrollSettings(sensitivity: 0.15, reversed: true, axes: .vertical),
                                                                         optionNativeInput: true),
                                              store: store, hotKeyAPI: fake.api)
                    defer { session.teardown() }
                    session.setShortcut(key)
                    session.prepareSettings(window: RecorderWindow())
                    let settings = session.settingsControl!
                    settings.window.orderBack(nil)
                    var completions: [(NSApplication.ModalResponse) -> Void] = []
                    settings.presentApplicationPanel = { _, _, completion in completions.append(completion) }
                    var selection = url
                    settings.selectedApplicationURL = { _ in selection }
                    try require(!settings.removeSelected.isEnabled && settings.applicationMessage.stringValue.contains("No excluded apps"), "empty state wrong")
                    settings.recorder.performClick(nil)
                    settings.add.performClick(nil)
                    let panel = settings.applicationPanel!
                    try require(!session.recording.active && !settings.add.isEnabled && !panel.canChooseDirectories &&
                                !panel.allowsMultipleSelection && panel.allowedContentTypes == [.applicationBundle], "picker not app-only or recorder stayed active")
                    _ = app.sendAction(settings.add.action!, to: settings.add.target, from: settings.add)
                    try require(completions.count == 1 && settings.applicationPanel === panel, "picker presented twice")
                    completions[0](.OK)
                    let identifier = ApplicationID("org.penpan.Fixture")!
                    try require(session.configuration.excludedApps == [identifier] && settings.applicationRows == [identifier] &&
                                settings.applications.selectedRow == 0 && settings.removeSelected.isEnabled && settings.add.isEnabled,
                                "Add did not select saved row")
                    try require(session.configuration.scroll == ScrollSettings(sensitivity: 0.15, reversed: true, axes: .vertical) &&
                                session.configuration.optionNativeInput && session.configuration.shortcut == key && (try store.load(environment: [:])) == session.configuration,
                                "Add lost siblings or did not save")
                    settings.add.performClick(nil)
                    completions.last!(.OK)
                    try require(session.configuration.excludedApps == [identifier] && settings.applicationRows.count == 1 &&
                                settings.applications.selectedRow == 0 && settings.applicationMessage.stringValue.contains("already excluded"), "duplicate mutated config")
                    let cell = settings.applications.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView
                    try require(cell.textField?.stringValue == "Fixture application" && cell.toolTip?.contains(identifier.rawValue) == true,
                                "friendly name or visible bundle identity missing")
                    let expected = session.configuration
                    selection = url.deletingLastPathComponent().appendingPathComponent("missing.app")
                    settings.add.performClick(nil)
                    completions.last!(.OK)
                    try require(session.configuration == expected && settings.applicationMessage.stringValue.contains("Choose a local .app"), "invalid package mutated config or error hidden")
                    settings.add.performClick(nil)
                    completions.last!(.cancel)
                    try require(session.configuration == expected && settings.applicationMessage.stringValue.contains("Cancelled"), "cancel mutated config or missing feedback")
                    settings.applications.deselectAll(nil)
                    try require(!settings.removeSelected.isEnabled, "Remove enabled without selection")
                    _ = app.sendAction(settings.removeSelected.action!, to: settings.removeSelected.target, from: settings.removeSelected)
                    try require(session.configuration == expected, "unselected Remove changed config")
                    settings.applications.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    settings.removeSelected.performClick(nil)
                    try require(session.configuration.excludedApps.isEmpty && session.configuration.shortcut == key &&
                                session.configuration.scroll == expected.scroll && !settings.removeSelected.isEnabled &&
                                settings.applicationMessage.stringValue.contains("No excluded apps"), "Remove lost sibling/empty state")
                }
            }
        }
        test("native duplicate Add refreshes a materialized fallback-name row without changing membership or siblings") {
            try withStore { store, _ in
                let identifier = ApplicationID("org.penpan.Duplicate-\(UUID().uuidString)")!
                let key = try Shortcut(keyCode: UInt32(kVK_F20), modifiers: UInt32(shiftKey))
                let expected = Configuration(scroll: ScrollSettings(sensitivity: 0.15, reversed: true, axes: .horizontal),
                                             shortcut: key, excludedApps: [identifier], optionNativeInput: true)
                store.save(expected)
                let session = LiveSession(configuration: expected, store: store, hotKeyAPI: FakeHotKeys().api)
                defer { session.teardown() }
                session.prepareSettings(window: RecorderWindow())
                let settings = session.settingsControl!
                settings.window.orderBack(nil)
                settings.window.contentView!.layoutSubtreeIfNeeded()
                settings.applications.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                let fallback = settings.applications.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView
                try require(fallback.textField?.stringValue == identifier.rawValue &&
                            fallback.toolTip == "\(identifier.rawValue)\n\(identifier.rawValue)" &&
                            fallback.accessibilityLabel() == "\(identifier.rawValue), \(identifier.rawValue)",
                            "fixture did not materialize fallback metadata")
                try withApplicationFixture(identifier: identifier.rawValue) { url in
                    var completion: ((NSApplication.ModalResponse) -> Void)?
                    settings.presentApplicationPanel = { _, _, callback in completion = callback }
                    settings.selectedApplicationURL = { _ in url }
                    settings.add.performClick(nil)
                    completion!(.OK)
                    settings.window.contentView!.layoutSubtreeIfNeeded()
                    try require(session.configuration == expected && (try store.load(environment: [:])) == expected &&
                                settings.applicationRows == [identifier] && settings.applications.selectedRow == 0 &&
                                settings.removeSelected.isEnabled && settings.applicationMessage.stringValue.contains("already excluded"),
                                "duplicate Add changed membership, siblings or selection")
                    let cell = settings.applications.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView
                    try require(cell.textField?.stringValue == "Fixture application", "duplicate Add left the displayed title stale")
                    try require(cell.toolTip == "Fixture application\n\(identifier.rawValue)", "duplicate Add left the tooltip stale")
                    try require(cell.accessibilityLabel() == "Fixture application, \(identifier.rawValue)",
                                "duplicate Add left the accessibility label stale")
                }
            }
        }
        test("native retained picker and related windows pass pen input, not overlapping unrelated or hidden windows") {
            let fake = FakeHotKeys()
            let session = LiveSession(hotKeyAPI: fake.api)
            defer { session.teardown() }
            session.prepareSettings(window: RecorderWindow())
            let settings = session.settingsControl!
            settings.window.orderBack(nil)
            settings.presentApplicationPanel = { panel, _, _ in panel.orderBack(nil) }
            settings.add.performClick(nil)
            let panel = settings.applicationPanel!
            let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            let unrelated = NSWindow(contentRect: settings.window.frame, styleMask: [.titled], backing: .buffered, defer: false)
            defer { child.orderOut(nil); unrelated.orderOut(nil) }
            settings.window.addChildWindow(child, ordered: .above)
            child.orderBack(nil)
            unrelated.orderBack(nil)
            session.lifecycle.observationStarted(leftButtonHeld: false)
            session.lifecycle.setEnabled(true)
            var target = panel.windowNumber
            var hitCount = 0
            var metadataCount = 0
            session.windowAtPoint = { _ in hitCount += 1; return target }
            session.targetResolver = PointerTargetResolver(windowInfo: { _ in metadataCount += 1; return nil }, bundleIdentifier: { _ in nil })
            var output: [CGEvent] = []
            func send(_ event: CGEvent) -> CGEvent? { session.lifecycle.handle(event.type, event, post: { output.append($0) }) }
            for number in [settings.window.windowNumber, panel.windowNumber, child.windowNumber] {
                target = number
                let down = mouse(.leftMouseDown)
                try require(send(down) === down, "owned UI intercepted: \(number)")
                target = unrelated.windowNumber
                for event in [mouse(.leftMouseDragged, 140), mouse(.leftMouseUp, 140)] {
                    try require(send(event) === event, "owned UI contact stolen outside window")
                }
            }
            try require(hitCount == 3 && metadataCount == 0 && output.isEmpty, "own UI resolved app or re-hit drag")
            target = unrelated.windowNumber
            try require(send(mouse(.leftMouseDown)) == nil, "arbitrary process/overlapping window exempted")
            _ = send(mouse(.leftMouseUp, 120))
            try require(output.count == 1 && output[0].type == .scrollWheel, "unrelated target did not pan")
            session.setExcludedApps([ApplicationID("org.example.App")!])
            target = panel.windowNumber
            let own = mouse(.leftMouseDown)
            try require(send(own) === own && metadataCount == 0, "own panel lookup did not short-circuit active exclusions")
            _ = send(mouse(.leftMouseUp))
            panel.orderOut(nil)
            child.orderOut(nil)
            try require(!settings.ownedWindowNumbers.contains(panel.windowNumber) && !settings.ownedWindowNumbers.contains(child.windowNumber),
                        "hidden UI numbers retained")
        }
        test("native Settings close and Quit invalidate picker before cancellation and ignore stale completions") {
            try withStore { store, _ in
                try withApplicationFixture { url in
                    let fake = FakeHotKeys()
                    let session = LiveSession(store: store, hotKeyAPI: fake.api)
                    defer { session.teardown() }
                    session.prepareSettings(window: RecorderWindow())
                    let settings = session.settingsControl!
                    settings.window.orderBack(nil)
                    var completions: [(NSApplication.ModalResponse) -> Void] = []
                    settings.presentApplicationPanel = { panel, _, completion in panel.orderBack(nil); completions.append(completion) }
                    settings.selectedApplicationURL = { _ in url }
                    settings.add.performClick(nil)
                    let first = settings.applicationPanel!
                    settings.window.performClose(nil)
                    try require(settings.applicationPanel == nil && !first.isVisible, "close retained visible picker")
                    settings.window.orderBack(nil)
                    settings.add.performClick(nil)
                    let second = settings.applicationPanel!
                    completions[0](.OK)
                    try require(settings.applicationPanel === second && session.configuration.excludedApps.isEmpty,
                                "stale picker completion saved or stole current picker")
                    session.requestQuit()
                    try require(settings.applicationPanel == nil && !second.isVisible && settings.ownedWindowNumbers.isEmpty, "Quit did not dismiss owned picker/UI")
                    completions[1](.OK)
                    try require(session.configuration.excludedApps.isEmpty && (try store.load(environment: [:])).excludedApps.isEmpty,
                                "late completion saved after Quit")
                    _ = app.sendAction(settings.add.action!, to: settings.add.target, from: settings.add)
                    try require(settings.applicationPanel == nil && completions.count == 2, "Quit allowed picker reopening")
                }
            }
        }
        test("native all eight standalone F13-F20 recorder events require matching release, reject repeats and Clear safely") {
            let fake = FakeHotKeys()
            let session = LiveSession(hotKeyAPI: fake.api)
            defer { session.teardown() }
            session.prepareSettings(window: RecorderWindow())
            let settings = session.settingsControl!
            settings.window.orderBack(nil)
            func event(_ type: NSEvent.EventType, _ code: Int, flags: NSEvent.ModifierFlags = [.function], repeatKey: Bool = false) -> NSEvent {
                NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 1,
                                 windowNumber: settings.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                 isARepeat: repeatKey, keyCode: UInt16(code))!
            }
            for (index, code) in [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20].enumerated() {
                fake.conflict.insert(UInt32(code))
                settings.recorder.performClick(nil)
                settings.recorder.keyDown(with: event(.keyDown, code))
                settings.recorder.keyUp(with: event(.keyUp, code))
                try require(session.configuration.shortcut == nil && fake.active.isEmpty && settings.message.stringValue.contains("conflict"),
                            "Fn recorder conflict was not inline/non-destructive")
                fake.conflict = []
                settings.recorder.performClick(nil)
                settings.recorder.keyDown(with: event(.keyDown, code, repeatKey: true))
                try require(session.recording.state == .listening, "repeat captured Fn")
                settings.recorder.keyDown(with: event(.keyDown, code))
                settings.recorder.keyUp(with: event(.keyUp, kVK_ANSI_A))
                try require(session.configuration.shortcut == nil && session.recording.active && fake.active.isEmpty, "Fn committed early")
                settings.recorder.keyUp(with: event(.keyUp, code))
                try require(session.configuration.shortcut?.keyCode == UInt32(code) && session.configuration.shortcut?.modifiers == 0 &&
                            settings.recorder.title == "F\(13 + index)" && fake.active.count == 1, "Fn native recorder failed")
                settings.clear.performClick(nil)
                try require(session.configuration.shortcut == nil && fake.active.isEmpty && !settings.clear.isEnabled, "Fn Clear did not remove")
                settings.recorder.performClick(nil)
                settings.recorder.keyDown(with: event(.keyDown, code, flags: [.shift, .function]))
                settings.recorder.keyUp(with: event(.keyUp, code, flags: [.shift, .function]))
                try require(session.configuration.shortcut?.modifiers == UInt32(shiftKey), "Shift+Fn rejected or incidental Fn stored")
                settings.clear.performClick(nil)
            }
            settings.recorder.performClick(nil)
            for code in [kVK_ANSI_A, kVK_Space, kVK_F1, kVK_F12, kVK_VolumeUp, kVK_Function] {
                settings.recorder.keyDown(with: event(.keyDown, code))
                try require(session.recording.state == .listening && session.configuration.shortcut == nil &&
                            !settings.message.stringValue.isEmpty, "incidental function flag authorized typing/media key")
            }
            settings.recorder.keyDown(with: event(.keyDown, kVK_Escape))
            try require(!session.recording.active, "Fn recorder Esc failed")
        }
        test("native grouped Settings render controls, long messages and app identities within bounds with accessible key order") {
            let fake = FakeHotKeys()
            let session = LiveSession(hotKeyAPI: fake.api)
            defer { session.teardown() }
            session.prepareSettings(window: RecorderWindow())
            let settings = session.settingsControl!
            settings.window.orderBack(nil)
            session.setScroll(ScrollSettings(axes: .horizontal))
            session.setOptionNativeInput(true)
            let longID = ApplicationID("org.example." + String(repeating: "VeryLongApplicationIdentifier", count: 8))!
            session.setExcludedApps([longID])
            settings.applications.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            session.recording.error("Candidate cleanup failed: Cannot remove shortcut (-2147483648). Quit to release remaining reservation. A failed shortcut reservation still needs cleanup. Quit to release it.")
            settings.applicationMessage.stringValue = "Choose a local .app package with a valid bundle ID and executable. Nothing was changed."
            settings.window.appearance = NSAppearance(named: .aqua)
            let content = settings.window.contentView!
            content.wantsLayer = true
            settings.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                content.layer!.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            content.layoutSubtreeIfNeeded()
            func withinBounds(_ view: NSView) throws {
                let frame = view.convert(view.bounds, to: content)
                try require(frame.width > 0 && frame.height > 0 && content.bounds.contains(frame), "rendered control clipped: \(view) \(frame)")
            }
            for view in [settings.status, settings.toggle, settings.sensitivity, settings.value, settings.axes, settings.reverse,
                         settings.optionNative, settings.inputHint, settings.recorder, settings.clear, settings.message, settings.applicationScroll,
                         settings.add, settings.removeSelected, settings.applicationMessage] {
                try withinBounds(view)
            }
            for label in [settings.status, settings.inputHint, settings.message, settings.applicationMessage] {
                let required = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1000)).height
                try require(required <= label.bounds.height, "wrapping message clipped: \(required) > \(label.bounds.height)")
            }
            try require(settings.toggle.accessibilityIdentifier() == "penpan.toggle" &&
                        settings.status.accessibilityIdentifier() == "penpan.status" &&
                        settings.applications.accessibilityIdentifier() == "penpan.exclusions.list" &&
                        settings.applications.accessibilityLabel()?.contains("Excluded applications") == true &&
                        settings.add.accessibilityIdentifier() == "penpan.exclusions.add" &&
                        settings.removeSelected.accessibilityIdentifier() == "penpan.exclusions.remove", "new accessibility IDs/labels missing")
            let keyViews: [NSView] = [settings.toggle, settings.sensitivity, settings.axes, settings.reverse, settings.optionNative,
                                    settings.recorder, settings.clear, settings.applications, settings.add, settings.removeSelected]
            for index in keyViews.indices {
                try require(keyViews[index].nextKeyView === keyViews[(index + 1) % keyViews.count], "keyboard order broken")
            }
            let row = settings.applications.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView
            row.layoutSubtreeIfNeeded()
            try require(row.toolTip?.contains(longID.rawValue) == true && row.accessibilityLabel()?.contains(longID.rawValue) == true,
                        "truncated ID not discoverable via tooltip/accessibility")
            for label in row.subviews.compactMap({ $0 as? NSTextField }) {
                try require(row.bounds.contains(label.convert(label.bounds, to: row)), "long app row clipped")
            }
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw Failure("cannot render Settings fixture") }
            settings.window.effectiveAppearance.performAsCurrentDrawingAppearance {
                content.cacheDisplay(in: content.bounds, to: bitmap)
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure("cannot encode Settings fixture") }
            try png.write(to: URL(fileURLWithPath: ".build/settings-fixture.png"))
            print("NATIVE grouped Settings rendered \(content.bounds.size), saved .build/settings-fixture.png")
        }
    }

    private static func inputControlsOffline() {
        test("axes preserve signs, reversal and allowed fractions through release for every mode") {
            for axes in ScrollAxes.allCases {
                for reversed in [false, true] {
                    for sx in [-1.0, 1.0] {
                        for sy in [-1.0, 1.0] {
                            let trace = Trace(settings: ScrollSettings(sensitivity: 0.25, reversed: reversed, axes: axes))
                            trace.send(mouse(.leftMouseDown))
                            for distance in [6.5, 10.5] {
                                trace.send(mouse(.leftMouseDragged, 100 + sx * distance, 100 + sy * distance))
                            }
                            trace.send(mouse(.leftMouseUp, 100 + sx * 14, 100 + sy * 14, subtype: 0))
                            let direction = reversed ? -1.0 : 1.0
                            let x = axes == .vertical ? 0 : Int64(sx * direction)
                            let y = axes == .horizontal ? 0 : Int64(sy * direction)
                            try require(trace.types == [.scrollWheel, .scrollWheel, .scrollWheel] &&
                                        trace.xs == [x, x, x] && trace.ys == [y, y, y],
                                        "axis/fraction mismatch \(axes) \(reversed) \(sx),\(sy): \(trace.xs),\(trace.ys)")
                        }
                    }
                }
            }
        }
        test("every axis retains six-pixel radial intent including diagonal and release crossing") {
            for axes in ScrollAxes.allCases {
                let trace = Trace(settings: ScrollSettings(sensitivity: 1, axes: axes))
                trace.send(mouse(.leftMouseDown))
                trace.send(mouse(.leftMouseDragged, 104, 104))
                try require(trace.output.isEmpty, "intent committed below six")
                trace.send(mouse(.leftMouseUp, 104.5, 104.5))
                try require(trace.types == [.scrollWheel] && trace.xs == [axes == .vertical ? 0 : 4] &&
                            trace.ys == [axes == .horizontal ? 0 : 4], "diagonal release ignored radial intent")
                let release = Trace(settings: ScrollSettings(sensitivity: 1, axes: axes))
                release.send(mouse(.leftMouseDown))
                release.send(mouse(.leftMouseUp, 106, 106))
                try require(release.types == [.scrollWheel] && release.xs == [axes == .vertical ? 0 : 6] &&
                            release.ys == [axes == .horizontal ? 0 : 6], "release crossing lost")
            }
        }
        test("suppressed-only out-and-back drags commit a pan without buttons or remainder catch-up") {
            for axes in [ScrollAxes.vertical, .horizontal] {
                let trace = Trace(settings: ScrollSettings(sensitivity: 0.25, axes: axes))
                trace.tap(count: 1, time: 1)
                trace.output = []
                trace.send(mouse(.leftMouseDown, count: 2, time: 1.1))
                trace.send(mouse(.leftMouseDragged, axes == .vertical ? 108 : 100, axes == .horizontal ? 108 : 100))
                trace.send(mouse(.leftMouseDragged, 100, 100))
                trace.send(mouse(.leftMouseUp, count: 2, time: 1.15))
                try require(trace.output.isEmpty, "suppressed pan became a click or scroll")
                trace.tap(count: 3, time: 1.2)
                try require(trace.counts == [1, 1], "suppressed pan retained click grouping")
                trace.output = []
                trace.adapter.gesture.settings = ScrollSettings(sensitivity: 0.25)
                trace.send(mouse(.leftMouseDown, time: 2))
                trace.send(mouse(.leftMouseUp, 108, 108, time: 2.05))
                try require(trace.types == [.scrollWheel] && trace.xs == [2] && trace.ys == [2], "blocked remainder escaped into next contact")
            }
        }
        test("axis changes snapshot pending and panning contacts and advance both coordinates") {
            for first in ScrollAxes.allCases {
                for next in ScrollAxes.allCases {
                    for panning in [false, true] {
                        let session = LiveSession(configuration: Configuration(scroll: ScrollSettings(sensitivity: 0.25, axes: first)))
                        let trace = LifecycleTrace(session: session)
                        trace.send(mouse(.leftMouseDown))
                        if panning { trace.send(mouse(.leftMouseDragged, 106, 110)) }
                        session.setScroll(ScrollSettings(sensitivity: 0.5, reversed: true, axes: next))
                        trace.send(mouse(.leftMouseDragged, 110, 114))
                        trace.send(mouse(.leftMouseUp, 114, 118))
                        let sumX = trace.output.reduce(0) { $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) }
                        let sumY = trace.output.reduce(0) { $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) }
                        try require(trace.types.allSatisfy { $0 == .scrollWheel } && sumX == (first == .vertical ? 0 : 3) &&
                                    sumY == (first == .horizontal ? 0 : 4), "contact settings or consecutive coordinates changed")
                        trace.output = []
                        trace.send(mouse(.leftMouseDown))
                        trace.send(mouse(.leftMouseUp, 114, 118))
                        try require(trace.types == [.scrollWheel] &&
                                    trace.output[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == (next == .vertical ? 0 : -7) &&
                                    trace.output[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == (next == .horizontal ? 0 : -9),
                                    "new contact missed axis edit or caught up blocked motion")
                    }
                }
            }
        }
        test("axes validate raw, scaled and accumulated arithmetic before suppression and drain failures") {
            for axes in ScrollAxes.allCases {
                let trace = LifecycleTrace(settings: ScrollSettings(sensitivity: Double.greatestFiniteMagnitude, axes: axes))
                trace.send(mouse(.leftMouseDown))
                trace.send(mouse(.leftMouseDragged, axes == .horizontal ? 100 : 110, axes == .vertical ? 100 : 110))
                trace.send(mouse(.leftMouseUp))
                try require(trace.output.isEmpty && trace.lifecycle.contact == .idle, "suppression concealed scaled overflow")
                let raw = Trace(settings: ScrollSettings(sensitivity: 0.05, axes: axes))
                raw.send(mouse(.leftMouseDown, -1e308, -1e308))
                raw.send(mouse(.leftMouseUp, 1e308, 1e308))
                try require(raw.output.isEmpty, "raw subtraction overflow emitted scroll")
                let accumulation = Trace(settings: ScrollSettings(sensitivity: 1e306, axes: axes))
                accumulation.send(mouse(.leftMouseDown, 0, 0))
                accumulation.send(mouse(.leftMouseDragged, 100, 100))
                try require(accumulation.types == [.scrollWheel], "finite large delta did not clamp")
                accumulation.output = []
                accumulation.send(mouse(.leftMouseDragged, 200, 200))
                accumulation.send(mouse(.leftMouseUp, 200, 200))
                try require(accumulation.output.isEmpty, "accumulation overflow emitted or clicked")
                if axes != .both {
                    let blocked = Trace(settings: ScrollSettings(sensitivity: 1e306, axes: axes))
                    blocked.send(mouse(.leftMouseDown, 0, 0))
                    for distance in [100.0, 200.0, 300.0] {
                        blocked.send(mouse(.leftMouseDragged, axes == .vertical ? distance : 0, axes == .horizontal ? distance : 0))
                    }
                    try require(blocked.output.isEmpty, "blocked axis emitted output")
                    blocked.send(mouse(.leftMouseDragged, axes == .vertical ? 300 : 1, axes == .horizontal ? 300 : 1))
                    try require(blocked.types == [.scrollWheel] && blocked.xs == [axes == .vertical ? 0 : Int64(Int32.max)] &&
                                blocked.ys == [axes == .horizontal ? 0 : Int64(Int32.max)], "blocked accumulation overflow cancelled later allowed motion")
                    blocked.adapter.gesture.requestStop()
                    blocked.send(mouse(.leftMouseUp))
                }
            }
        }
        test("legacy and fresh stores default to Both and Option OFF without migration writes") {
            try withStore { store, defaults in
                let fresh = try store.load(environment: [:])
                try require(fresh.scroll.axes == .both && !fresh.optionNativeInput &&
                            defaults.object(forKey: "axes") == nil && defaults.object(forKey: "optionNativeInput") == nil,
                            "fresh load wrote new preferences")
                defaults.set(0.15, forKey: "sensitivity")
                defaults.set(true, forKey: "reversed")
                defaults.set(["org.example.App"], forKey: "excludedApps")
                let before = defaults.dictionaryRepresentation() as NSDictionary
                let legacy = try store.load(environment: [:])
                try require(legacy.scroll == ScrollSettings(sensitivity: 0.15, reversed: true) &&
                            legacy.excludedApps == [ApplicationID("org.example.App")!] && !legacy.optionNativeInput &&
                            before.isEqual(to: defaults.dictionaryRepresentation()), "legacy load changed siblings or wrote migration")
            }
        }
        test("new storage fields parse independently with strict Boolean and exact enum strings") {
            try withStore { store, defaults in
                let key = try Shortcut(keyCode: UInt32(kVK_F13), modifiers: 0)
                let original = Configuration(scroll: ScrollSettings(sensitivity: 0.15, reversed: true, axes: .horizontal),
                                             shortcut: key, excludedApps: [ApplicationID("org.example.App")!], optionNativeInput: true)
                for axes in ScrollAxes.allCases {
                    store.save(Configuration(scroll: ScrollSettings(axes: axes), optionNativeInput: true))
                    try require(defaults.string(forKey: "axes") == axes.rawValue &&
                                (try store.load(environment: [:])).scroll.axes == axes &&
                                (try store.load(environment: [:])).optionNativeInput, "new schema failed round trip")
                }
                for invalid: Any in [1, 0, 0.5, "true", "false", [true], ["enabled": true]] {
                    store.save(original)
                    // UserDefaults can retain an equal Boolean when overwriting it with numeric 1 or 0.
                    defaults.removeObject(forKey: "optionNativeInput")
                    defaults.set(invalid, forKey: "optionNativeInput")
                    let before = defaults.dictionaryRepresentation() as NSDictionary
                    let loaded = try store.load(environment: [:])
                    try require(!loaded.optionNativeInput && loaded.scroll == original.scroll && loaded.shortcut == key &&
                                loaded.excludedApps == original.excludedApps && before.isEqual(to: defaults.dictionaryRepresentation()),
                                "Boolean impostor \(invalid) accepted, siblings lost, or load wrote")
                }
                for invalid: Any in [true, 1, "Both", "vertical-only", "", ["vertical"], ["axes": "vertical"]] {
                    store.save(original)
                    defaults.set(invalid, forKey: "axes")
                    let before = defaults.dictionaryRepresentation() as NSDictionary
                    let loaded = try store.load(environment: [:])
                    try require(loaded.scroll.axes == .both && loaded.scroll.sensitivity == 0.15 && loaded.scroll.reversed &&
                                loaded.optionNativeInput && loaded.shortcut == key && loaded.excludedApps == original.excludedApps &&
                                before.isEqual(to: defaults.dictionaryRepresentation()), "axis impostor accepted or valid siblings lost")
                }
                defaults.set("broken", forKey: "sensitivity")
                defaults.set("broken", forKey: "reversed")
                defaults.set("broken", forKey: "shortcut")
                defaults.set("broken", forKey: "excludedApps")
                defaults.set("vertical", forKey: "axes")
                let loaded = try store.load(environment: [:])
                try require(loaded.scroll == ScrollSettings(axes: .vertical) && loaded.optionNativeInput, "invalid old fields erased new fields")
            }
        }
        test("all four setters and failed shortcut transactions preserve old and new siblings and ignore Quit edits") {
            try withStore { store, _ in
                let fake = FakeHotKeys()
                let session = LiveSession(store: store, hotKeyAPI: fake.api)
                defer { session.teardown() }
                let key = try Shortcut(keyCode: UInt32(kVK_F13), modifiers: 0)
                let candidate = try Shortcut(keyCode: UInt32(kVK_F14), modifiers: 0)
                let apps: Set<ApplicationID> = [ApplicationID("org.example.App")!]
                let scroll = ScrollSettings(sensitivity: 0.15, reversed: true, axes: .vertical)
                session.setOptionNativeInput(true)
                session.setScroll(scroll)
                session.setShortcut(key)
                session.setExcludedApps(apps)
                let expected = Configuration(scroll: scroll, shortcut: key, excludedApps: apps, optionNativeInput: true)
                try require(session.configuration == expected && (try store.load(environment: [:])) == expected, "setter lost siblings")
                fake.conflict.insert(candidate.keyCode)
                session.setShortcut(candidate)
                fake.failCheck = true
                session.setShortcut(candidate)
                fake.failCheck = false
                fake.failRemoval = Set(fake.active.keys)
                session.setShortcut(nil)
                try require(session.configuration == expected && (try store.load(environment: [:])) == expected, "failed transaction changed configuration")
                fake.failRemoval = []
                session.setOptionNativeInput(false)
                try require(session.configuration == Configuration(scroll: scroll, shortcut: key, excludedApps: apps), "Option setter reset siblings")
                session.setOptionNativeInput(true)
                session.requestQuit()
                session.setScroll(ScrollSettings())
                session.setShortcut(nil)
                session.setExcludedApps([])
                session.setOptionNativeInput(false)
                try require(session.configuration == expected && (try store.load(environment: [:])) == expected, "terminal setter saved")
            }
        }
        test("Option-native passes original flagged objects through subtype-0 release with zero target lookups") {
            for releaseSubtype: Int64 in [0, 1] {
                let app = ApplicationID("org.example.App")!
                let session = LiveSession(configuration: Configuration(scroll: ScrollSettings(axes: .vertical), excludedApps: [app], optionNativeInput: true))
                let trace = LifecycleTrace(session: session)
                var hits = 0
                var owners = 0
                var bundles = 0
                session.windowAtPoint = { _ in hits += 1; return 42 }
                session.targetResolver = PointerTargetResolver(windowInfo: {
                    owners += 1; return [[kCGWindowNumber as String: $0, kCGWindowOwnerPID as String: 700]]
                }, bundleIdentifier: { _ in bundles += 1; return "org.example.Other" })
                let down = mouse(.leftMouseDown, flags: [.maskAlternate, .maskShift])
                try require(trace.send(down) === down && down.flags == [.maskAlternate, .maskShift], "Option down changed")
                session.setOptionNativeInput(false)
                session.setScroll(ScrollSettings(axes: .horizontal))
                for event in [mouse(.leftMouseDragged, 120, flags: .maskCommand), mouse(.leftMouseUp, 120, subtype: releaseSubtype)] {
                    let flags = event.flags
                    try require(trace.send(event) === event && event.flags == flags, "passed object or flags changed after edit/release")
                }
                try require(hits == 0 && owners == 0 && bundles == 0 && trace.output.count == 3, "bypass resolved target or synthesized output")
                trace.output = []
                trace.send(mouse(.leftMouseDown))
                trace.send(mouse(.leftMouseUp, 120, 120))
                try require(trace.types == [.scrollWheel] && hits == 1 && owners == 1 && bundles == 1 &&
                            trace.output[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 0, "next non-Option contact failed")
            }
        }
        test("Option released early stays native while the next non-Option contact scrolls with preference still enabled") {
            let session = LiveSession(configuration: Configuration(scroll: ScrollSettings(sensitivity: 1), optionNativeInput: true))
            let trace = LifecycleTrace(session: session)
            let down = mouse(.leftMouseDown, flags: .maskAlternate)
            try require(trace.send(down) === down, "Option down consumed")
            for event in [mouse(.leftMouseDragged, 120), mouse(.leftMouseUp, 120, subtype: 0)] {
                try require(trace.send(event) === event && event.flags.isEmpty, "early modifier release stole contact or rewrote flags")
            }
            trace.output = []
            trace.send(mouse(.leftMouseDown))
            trace.send(mouse(.leftMouseUp, 120))
            try require(trace.types == [.scrollWheel] && session.configuration.optionNativeInput, "lift did not resume scrolling with preference enabled")
        }
        test("Option eligibility runs only at eligible down and respects default target policy and fresh-down recovery") {
            let session = LiveSession(configuration: Configuration(excludedApps: [ApplicationID("org.example.Excluded")!]))
            let trace = LifecycleTrace(session: session, enabled: false)
            var hits = 0
            var owners = 0
            session.windowAtPoint = { _ in hits += 1; return 42 }
            session.targetResolver = PointerTargetResolver(windowInfo: {
                owners += 1; return [[kCGWindowNumber as String: $0, kCGWindowOwnerPID as String: 700]]
            }, bundleIdentifier: { _ in "org.example.Other" })
            let down = mouse(.leftMouseDown, flags: .maskAlternate)
            try require(trace.send(down) === down && hits == 0 && owners == 0, "OFF performed eligibility lookup")
            session.setOptionNativeInput(true)
            session.lifecycle.setEnabled(true)
            let up = mouse(.leftMouseUp, subtype: 0)
            try require(trace.send(up) === up && hits == 0, "preference stole OFF contact")
            session.setOptionNativeInput(false)
            trace.output = []
            trace.send(down)
            try require(hits == 1 && owners == 1 && trace.lifecycle.contact == .owned, "default OFF bypassed Option or skipped original target policy")
            trace.send(mouse(.leftMouseUp), as: .tapDisabledByTimeout)
            session.setOptionNativeInput(true)
            try require(trace.send(down) === down && hits == 1 && owners == 1 && trace.lifecycle.contact == .passed,
                        "fresh down after missed release failed existing recovery/bypass")
            try require(trace.send(up) === up, "recovered native release lost")
        }
        test("Option at down is opt-in and later modifier or preference edits cannot steal pending or pan") {
            for enabled in [false, true] {
                for panning in [false, true] {
                    let session = LiveSession(configuration: Configuration(scroll: ScrollSettings(sensitivity: 1), optionNativeInput: enabled))
                    let trace = LifecycleTrace(session: session)
                    trace.send(mouse(.leftMouseDown, flags: enabled ? [] : .maskAlternate))
                    if panning { trace.send(mouse(.leftMouseDragged, 110, flags: .maskAlternate)) }
                    session.setOptionNativeInput(!enabled)
                    trace.send(mouse(.leftMouseDragged, 120, flags: .maskAlternate))
                    trace.send(mouse(.leftMouseUp, 130, subtype: 0, flags: .maskAlternate))
                    try require(trace.types.allSatisfy { $0 == .scrollWheel } &&
                                trace.output.reduce(0) { $0 + $1.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) } == 30 &&
                                trace.lifecycle.contact == .idle, "late Option/preference cancelled or stole owned contact")
                }
            }
        }
        test("Option preferences cannot revive drains and preserve OFF, Quit and tap-disabled ownership") {
            for action in ["off", "quit", "timeout", "userDisable"] {
                for passed in [false, true] {
                    let session = LiveSession(configuration: Configuration(optionNativeInput: true))
                    let trace = LifecycleTrace(session: session)
                    let down = mouse(.leftMouseDown, flags: passed ? .maskAlternate : [])
                    try require((trace.send(down) === down) == passed, "wrong initial ownership")
                    trace.output = []
                    switch action {
                    case "off": session.lifecycle.setEnabled(false); session.lifecycle.setEnabled(true)
                    case "quit": session.requestQuit()
                    default: trace.send(mouse(.leftMouseUp), as: action == "timeout" ? .tapDisabledByTimeout : .tapDisabledByUserInput)
                    }
                    session.setOptionNativeInput(false)
                    session.setOptionNativeInput(true)
                    for event in [mouse(.leftMouseDragged, 140, flags: .maskAlternate), mouse(.leftMouseUp, 140, subtype: 0)] {
                        try require((trace.send(event) === event) == passed, "recovery/preference changed ownership")
                    }
                    try require(trace.output.count == (passed ? 2 : 0) && trace.lifecycle.contact == .idle, "drain revived output")
                    if action == "quit" { try require(session.lifecycle.finished, "Quit did not finish") }
                }
            }
            let session = LiveSession(configuration: Configuration(optionNativeInput: true))
            let trace = LifecycleTrace(session: session, enabled: false)
            let down = mouse(.leftMouseDown)
            try require(trace.send(down) === down, "OFF changed down")
            session.setOptionNativeInput(false)
            session.lifecycle.setEnabled(true)
            let up = mouse(.leftMouseUp, flags: .maskAlternate)
            try require(trace.send(up) === up, "ON stole OFF contact after preference edit")
        }
        test("Option-native keeps mouse, Space, ordinary keys and trackpad input unchanged in every mode") {
            for mode in [Lifecycle.Mode.off, .on, .quitting] {
                let session = LiveSession(configuration: Configuration(optionNativeInput: true))
                let trace = LifecycleTrace(session: session, enabled: mode == .on)
                if mode == .quitting { session.requestQuit() }
                var events = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].map { mouse($0, subtype: 0, flags: .maskAlternate) }
                events.append(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 3, wheel2: 1, wheel3: 0)!)
                for key: CGKeyCode in [49, 0] {
                    for down in [true, false] { events.append(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!) }
                }
                for event in events { try require(trace.send(event) === event, "ordinary input changed") }
            }
        }
    }

    private static func inputControlsNative() {
        test("native axes popup and Option checkbox actions preserve siblings, labels and terminal state") {
            try withStore { store, _ in
                let fake = FakeHotKeys()
                let key = try Shortcut(keyCode: UInt32(kVK_F13), modifiers: 0)
                let app = ApplicationID("org.example.App")!
                let session = LiveSession(configuration: Configuration(excludedApps: [app]), store: store, hotKeyAPI: fake.api)
                defer { session.teardown() }
                session.setShortcut(key)
                session.prepareSettings(window: RecorderWindow())
                let settings = session.settingsControl!
                settings.window.orderBack(nil)
                try require(settings.axes.itemTitles == ScrollAxes.allCases.map(\.title) && settings.axes.indexOfSelectedItem == 0 &&
                            settings.optionNative.state == .off, "native defaults/order differ from model")
                try require(settings.axes.accessibilityIdentifier() == "penpan.axes.popup" &&
                            settings.axes.accessibilityLabel() == "Scrolling axes" &&
                            settings.optionNative.accessibilityIdentifier() == "penpan.option-native.checkbox" &&
                            settings.optionNative.accessibilityLabel() == "Hold Option for native pen input" &&
                            settings.inputHint.stringValue.contains("Hold before contact") &&
                            settings.inputHint.stringValue.contains("Option's normal app behavior remains") &&
                            settings.inputHint.stringValue.contains("Changes affect new contacts"), "native labels/hints missing")
                let probe = ApplicationRowsProbe(settings)
                settings.applications.dataSource = probe
                settings.applications.reloadData()
                settings.window.contentView!.layoutSubtreeIfNeeded()
                let reads = probe.reads
                settings.optionNative.performClick(nil)
                for (index, axes) in ScrollAxes.allCases.enumerated() {
                    settings.axes.selectItem(at: index)
                    try require(settings.axes.sendAction(settings.axes.action, to: settings.axes.target), "popup action not routed")
                    settings.sensitivity.doubleValue = 0.15
                    try require(settings.sensitivity.sendAction(settings.sensitivity.action, to: settings.sensitivity.target), "slider action not routed")
                    settings.reverse.performClick(nil)
                    try require(session.configuration.scroll.axes == axes && session.configuration.scroll.sensitivity == 0.15 &&
                                session.configuration.optionNativeInput && session.configuration.shortcut == key &&
                                session.configuration.excludedApps == [app] && (try store.load(environment: [:])) == session.configuration,
                                "native scrolling action lost siblings or did not save")
                }
                settings.optionNative.performClick(nil)
                try require(!session.configuration.optionNativeInput && session.configuration.scroll.axes == .horizontal &&
                            session.configuration.shortcut == key && session.configuration.excludedApps == [app], "Option action reset siblings")
                try require(probe.reads == reads, "new control actions reloaded unchanged app list")
                let expected = session.configuration
                session.requestQuit()
                try require(!settings.axes.isEnabled && !settings.optionNative.isEnabled, "new controls enabled during Quit")
                _ = settings.axes.sendAction(settings.axes.action, to: settings.axes.target)
                _ = settings.optionNative.sendAction(settings.optionNative.action, to: settings.optionNative.target)
                try require(session.configuration == expected && (try store.load(environment: [:])) == expected, "terminal native action saved")
            }
        }
        test("native Option contact reaches down-sensitive control immediately and bypasses visible Settings lookups") {
            let session = LiveSession(configuration: Configuration(excludedApps: [ApplicationID("org.example.App")!], optionNativeInput: true))
            defer { session.teardown() }
            session.prepareSettings(window: RecorderWindow())
            let settings = session.settingsControl!
            settings.window.orderBack(nil)
            let trace = LifecycleTrace(session: session)
            var hits = 0
            var owners = 0
            session.windowAtPoint = { _ in hits += 1; return 42 }
            session.targetResolver = PointerTargetResolver(windowInfo: { _ in owners += 1; return nil }, bundleIdentifier: { _ in nil })
            let control = DownControl(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            let down = mouse(.leftMouseDown, flags: .maskAlternate)
            let forwarded = trace.send(down)
            try require(forwarded === down, "Option down deferred")
            let native = NSEvent(cgEvent: forwarded!)!
            control.mouseDown(with: native)
            try require(control.downs == 1 && control.ups == 0 && native.modifierFlags.contains(.option), "native Option down not immediate/flagged")
            settings.optionNative.performClick(nil)
            let up = mouse(.leftMouseUp, subtype: 0)
            try require(trace.send(up) === up, "native preference stole passed release")
            control.mouseUp(with: NSEvent(cgEvent: up)!)
            try require(control.ups == 1 && hits == 0 && owners == 0 && trace.output.count == 2, "bypass queried target or generated events")
        }
        test("native NSScrollView observes explicit axes in both directions with reversal and no blocked motion") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
            scroll.hasHorizontalScroller = true
            scroll.hasVerticalScroller = true
            scroll.usesPredominantAxisScrolling = false
            scroll.documentView = Document(frame: NSRect(x: 0, y: 0, width: 1200, height: 1200))
            window.contentView = scroll
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            let session = LiveSession()
            defer { session.teardown() }
            session.prepareSettings(window: RecorderWindow())
            let settings = session.settingsControl!
            let trace = LifecycleTrace(session: session)
            for (index, axes) in ScrollAxes.allCases.enumerated() {
                settings.axes.selectItem(at: index)
                try require(settings.axes.sendAction(settings.axes.action, to: settings.axes.target), "axes action failed")
                for reversed in [false, true] {
                    settings.reverse.state = reversed ? .on : .off
                    try require(settings.reverse.sendAction(settings.reverse.action, to: settings.reverse.target), "reverse action failed")
                    for sign in [-1.0, 1.0] {
                        scroll.layoutSubtreeIfNeeded()
                        try require(scroll.window === window && window.isVisible && !scroll.needsLayout &&
                                    scroll.contentView.bounds.width > 0 && scroll.contentView.bounds.height > 0,
                                    "native scroll fixture not ready: clip=\(scroll.contentView.bounds), document=\(scroll.contentView.documentRect)")
                        scroll.contentView.scroll(to: CGPoint(x: 400, y: 400))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        try require(scroll.contentView.bounds.origin == CGPoint(x: 400, y: 400), "native scroll fixture did not reset")
                        try require(session.configuration.scroll == ScrollSettings(reversed: reversed, axes: axes) &&
                                    trace.adapter.gesture.settings == session.configuration.scroll, "native action changed sensitivity or routing settings")
                        trace.output = []
                        trace.send(mouse(.leftMouseDown))
                        trace.send(mouse(.leftMouseUp, 100 + sign * 20, 100 + sign * 20))
                        let delta = sign * (reversed ? -6.0 : 6.0)
                        let x = axes == .vertical ? 0 : delta
                        let y = axes == .horizontal ? 0 : delta
                        try require(trace.types == [.scrollWheel], "native pan did not emit exactly one wheel: \(trace.types)")
                        let event = trace.output[0]
                        let native = NSEvent(cgEvent: event)!
                        print("NATIVE emitted axes=\(axes.rawValue) reversed=\(reversed) sign=\(sign) sensitivity=\(session.configuration.scroll.sensitivity) CG=(\(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),\(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))) NS=(\(native.scrollingDeltaX),\(native.scrollingDeltaY)) clip=\(scroll.contentView.bounds) document=\(scroll.contentView.documentRect)")
                        try require(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == Int64(x) &&
                                    event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == Int64(y) &&
                                    event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1 && native.type == .scrollWheel &&
                                    native.hasPreciseScrollingDeltas && native.scrollingDeltaX == x && native.scrollingDeltaY == y,
                                    "emitted native wheel differs from exact expected pixels (\(x),\(y))")
                        let expected = CGPoint(x: 400 - x, y: 400 - y)
                        func atExpectedOrigin() -> Bool {
                            let origin = scroll.contentView.bounds.origin
                            return abs(origin.x - expected.x) < 0.01 && abs(origin.y - expected.y) < 0.01
                        }
                        scroll.scrollWheel(with: native)
                        // AppKit applies precise scrolling asynchronously; observe the single wheel, never resend it.
                        let deadline = ProcessInfo.processInfo.systemUptime + 1
                        while !atExpectedOrigin() && ProcessInfo.processInfo.systemUptime < deadline {
                            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                        }
                        let origin = scroll.contentView.bounds.origin
                        print("NATIVE axes=\(axes.rawValue) reversed=\(reversed) sign=\(sign) origin=\(origin)")
                        try require(abs(origin.x - expected.x) < 0.01 && abs(origin.y - expected.y) < 0.01,
                                    "native axis output differs: \(origin), expected \(expected)")
                    }
                }
            }
        }
    }

    static func main() {
        switch CommandLine.arguments.dropFirst().first {
        case "--offline": offline(); lifecycleOffline(); settingsOffline(); exclusionsOffline(); inputControlsOffline()
        case "--native": native(); settingsNative(); exclusionsNative(); inputControlsNative()
        default:
            print("Usage: pen-pan-tests --offline | --native\nNeither mode creates an event tap or posts global input. Native uses a temporary nonactivating app-local fixture.")
            return
        }
        print("\(tests - failures)/\(tests) checks passed. No event taps, global posting, or helper processes.")
        exit(failures == 0 ? 0 : 1)
    }
}
