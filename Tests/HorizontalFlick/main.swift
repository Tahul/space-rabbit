import CoreGraphics
import Foundation

private var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1

    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// Previously saved ticks must retain their values and velocity mapping.
for (saved, velocity) in [(0.25, 50.0), (0.5, 60.0), (0.75, 70.0), (1.0, 400.0)] {
    gSwitchSpeed = normalizedSwitchSpeed(saved)
    check(gSwitchSpeed == saved, "preserve saved speed \(saved)")
    check(currentSwitchVelocity() == velocity, "preserve velocity for \(saved)")
}

gSwitchSpeed = normalizedSwitchSpeed(0)
check(isNativeSwitchSpeed(), "Normal retains native switching")
gSwitchSpeed = 1

// Construct real, augmented CGEvents without installing taps or posting them.
// Progress must remain near zero until release: reaching the boundary before
// Ended prevents the requested release velocity from driving the animation.
let phases = [kCGSGesturePhaseBegan, kCGSGesturePhaseChanged, kCGSGesturePhaseEnded]
var terminalSigns = [Int: Double]()

for direction in [-1, 1] {
    for velocity in [50.0, 60.0, 70.0, 400.0] {
        guard let events = prepareAugmentedHorizontalFlick(direction: direction, velocity: velocity) else {
            fatalError("Could not construct the augmented flick")
        }

        check(events.count == 3, "complete Began/Changed/Ended sequence")

        let firstProgress = events[0].getDoubleValueField(kCGEventGestureSwipeProgress)

        for (event, phase) in zip(events, phases) {
            let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)
            let release = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)

            check(event.getIntegerValueField(kCGEventGesturePhase) == phase, "ordered gesture phases")
            check(event.getIntegerValueField(kCGEventGesturePhase2) == phase, "mirrored macOS 27 phase")
            check(event.getIntegerValueField(kCGEventGestureSwipeMotion) == kGestureMotionHorizontal,
                  "horizontal motion")
            check(abs(progress) > 0 && abs(progress) <= 0.00011, "near-zero, non-zero travel")
            check(progress * firstProgress > 0, "consistent direction throughout the gesture")
            check(event.getIntegerValueField(.eventSourceUserData) != 0, "synthetic marker survives augmentation")

            if phase == kCGSGesturePhaseEnded {
                check(abs(release) == (velocity == 400 ? 9999 : velocity), "preserve animated release velocity")
                check(release * progress > 0, "release agrees with travel direction")
                terminalSigns[direction] = release > 0 ? 1 : -1
            } else {
                check(release == 0, "velocity is applied only at release")
            }
        }
    }
}

check(terminalSigns[-1] == -(terminalSigns[1] ?? 0), "opposite directions produce opposite signs")
check(prepareAugmentedHorizontalFlick(direction: 0, velocity: 50) == nil, "reject invalid direction")

for velocity in [0.0, -50, .nan, .infinity] {
    check(prepareAugmentedHorizontalFlick(direction: 1, velocity: velocity) == nil, "reject invalid velocity")
}

print("Horizontal flick: \(checks) checks passed")
