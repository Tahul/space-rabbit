import CoreGraphics
import Foundation

private let eventTypeField = CGEventField(rawValue: 55)!
private let hidTypeField = CGEventField(rawValue: 110)!
private let swipeMaskField = CGEventField(rawValue: 115)!
private let motionField = CGEventField(rawValue: 123)!
private let progressField = CGEventField(rawValue: 124)!
private let positionXField = CGEventField(rawValue: 125)!
private let positionYField = CGEventField(rawValue: 126)!
private let velocityXField = CGEventField(rawValue: 129)!
private let velocityYField = CGEventField(rawValue: 130)!
private let phaseField = CGEventField(rawValue: 132)!
private let phase2Field = CGEventField(rawValue: 134)!
private let flavorField = CGEventField(rawValue: 138)!
private let syntheticMarker: Int64 = 0x5350_4152

private var eventNumber = 0

private func overviewState() -> String {
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] else { return "unknown" }

    let active = windows.contains { window in
        (window[kCGWindowOwnerName as String] as? String) == "Dock"
            && (window[kCGWindowLayer as String] as? NSNumber)?.int32Value == 18
    }
    return active ? "overview" : "desktop"
}

private func phaseName(_ phase: Int64) -> String {
    switch phase {
    case 1: return "began"
    case 2: return "changed"
    case 4: return "ended"
    case 8: return "cancelled"
    default: return String(phase)
    }
}

private func probeCallback(proxy: CGEventTapProxy,
                           type: CGEventType,
                           event: CGEvent,
                           userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let passthrough = Unmanaged.passUnretained(event)
    guard type.rawValue == 30 else { return passthrough }
    guard event.getIntegerValueField(.eventSourceUserData) != syntheticMarker else {
        return passthrough
    }

    let subtype = event.getIntegerValueField(eventTypeField)
    let hidType = event.getIntegerValueField(hidTypeField)
    let motion = event.getIntegerValueField(motionField)

    // DockSwipe motion 2 is the Mission Control/App Expose vertical stream.
    guard subtype == 30 && hidType == 23 && motion == 2 else {
        return passthrough
    }

    eventNumber += 1
    let phase = event.getIntegerValueField(phaseField)
    let state = phase == 1 ? overviewState() : "-"
    let line = String(
        format: "%03d type=%lld phase=%@(%lld) phase2=%lld hid=%lld motion=%lld progress=%+.6f velocity=(%+.3f,%+.3f) position=(%+.3f,%+.3f) mask=%lld flavor=%.1f state=%@\n",
        eventNumber,
        subtype,
        phaseName(phase),
        phase,
        event.getIntegerValueField(phase2Field),
        hidType,
        motion,
        event.getDoubleValueField(progressField),
        event.getDoubleValueField(velocityXField),
        event.getDoubleValueField(velocityYField),
        event.getDoubleValueField(positionXField),
        event.getDoubleValueField(positionYField),
        event.getIntegerValueField(swipeMaskField),
        event.getDoubleValueField(flavorField),
        state
    )
    fputs(line, stdout)
    fflush(stdout)
    return passthrough
}

let mask = CGEventMask(1 << UInt64(30))
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: probeCallback,
    userInfo: nil
), let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
    fputs("ERROR: could not create the passive event tap\n", stderr)
    exit(1)
}

CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("READY: swipe up into Mission Control, wait, then swipe down to leave")
fflush(stdout)
CFRunLoopRun()
