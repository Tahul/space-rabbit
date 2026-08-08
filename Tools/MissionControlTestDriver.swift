import CoreGraphics
import Foundation

private let eventTypeField = CGEventField(rawValue: 55)!
private let hidTypeField = CGEventField(rawValue: 110)!
private let motionField = CGEventField(rawValue: 123)!
private let progressField = CGEventField(rawValue: 124)!
private let velocityField = CGEventField(rawValue: 129)!
private let phaseField = CGEventField(rawValue: 132)!

private func post(phase: Int64, progress: Double, velocity: Double = 0) {
    guard let event = CGEvent(source: nil) else { exit(1) }
    event.setIntegerValueField(eventTypeField, value: 30)
    event.setIntegerValueField(hidTypeField, value: 23)
    event.setIntegerValueField(motionField, value: 2)
    event.setIntegerValueField(phaseField, value: phase)
    event.setDoubleValueField(progressField, value: progress)
    event.setDoubleValueField(velocityField, value: velocity)
    event.post(tap: .cgSessionEventTap)
}

// Captured macOS 26 physical convention: swipe-up is negative and
// swipe-down is positive. This deliberately differs from synthetic output.
let sign = CommandLine.arguments.dropFirst().first == "down" ? 1.0 : -1.0
post(phase: 1, progress: sign * 0.01)
Thread.sleep(forTimeInterval: 0.015)
post(phase: 2, progress: sign * 0.08)
Thread.sleep(forTimeInterval: 0.015)
post(phase: 4, progress: sign, velocity: sign * 5)
