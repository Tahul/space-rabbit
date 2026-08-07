/*
 * PrivateAPI.swift — Undocumented CGEvent fields and private CGS functions
 *
 * macOS does not provide a public API for querying or switching Spaces
 * (virtual desktops). The constants and function pointers below are
 * resolved at runtime via dlsym and give us the ability to:
 *
 *   - Construct synthetic DockSwipe gesture events (the CGEvent field IDs)
 *   - Query the current space and enumerate all spaces per display (CGS functions)
 *   - Map window IDs to the space they belong to (SLSCopySpacesForWindows)
 *
 * These are the main fragility points of the app — they rely on
 * implementation details of macOS that may change in future releases.
 *
 * References:
 *   - https://github.com/jurplel/InstantSpaceSwitcher (original technique)
 *   - CGSInternal headers (community-maintained)
 */

import CoreGraphics
import Darwin

// MARK: - Undocumented CGEvent Field IDs
//
// These raw integer IDs identify private fields on CGEvent objects.
// They are used to construct the synthetic DockSwipe gesture events
// that trick the Dock into performing an instant (non-animated) space switch.
//
// To update these if Apple changes them, compare against the CGSInternal
// headers or reverse-engineer the Dock's event handling.

/// Internal event type discriminator.
/// Distinguishes gesture events, dock-control events, and normal input events.
let kCGSEventTypeField            = CGEventField(rawValue: 55)!

/// Identifies the HID gesture type.
/// For space switching, this is set to `kIOHIDEventTypeDockSwipe` (23).
let kCGEventGestureHIDType        = CGEventField(rawValue: 110)!

/// Vertical scroll component of the gesture.
/// Set to 0 for horizontal swipes (space switching is purely horizontal).
let kCGEventGestureScrollY        = CGEventField(rawValue: 119)!

/// Indicates whether the gesture involves a swipe motion.
/// Set to 1 (true) for all space-switch gestures.
let kCGEventGestureSwipeMotion    = CGEventField(rawValue: 123)!

/// How far the swipe has progressed.
/// Values of +-2.0 indicate a fully committed swipe that should switch immediately.
let kCGEventGestureSwipeProgress  = CGEventField(rawValue: 124)!

/// Horizontal velocity of the swipe.
/// Values of +-400 are well above the Dock's threshold for "instant" switching.
let kCGEventGestureSwipeVelocityX = CGEventField(rawValue: 129)!

/// Vertical velocity of the swipe.
/// Set to 0 for horizontal swipes.
let kCGEventGestureSwipeVelocityY = CGEventField(rawValue: 130)!

/// The phase of the gesture lifecycle.
/// Began (1) signals the start; Ended (4) signals completion with final velocity.
let kCGEventGesturePhase          = CGEventField(rawValue: 132)!

/// Bitfield encoding the swipe direction.
/// 0 = swipe left (move to previous space), 1 = swipe right (move to next space).
let kCGEventScrollGestureFlagBits = CGEventField(rawValue: 135)!

/// Zoom/delta field repurposed to carry a non-zero epsilon value.
/// The Dock checks this field and ignores the gesture if it's exactly zero.
/// Setting it to `Float.leastNonzeroMagnitude` satisfies the check.
let kCGEventGestureZoomDeltaX     = CGEventField(rawValue: 139)!

// MARK: - Undocumented CGEvent Field IDs (macOS 27 Augmented Gestures)
//
// Additional private fields required by macOS 27's Dock, which validates
// synthetic DockSwipe events much more strictly. Discovered by reverse
// engineering (see https://github.com/joshuarli/iss commit 09beeb6).

/// Bitmask describing which touches participate in the swipe.
/// Read back when serializing the IOHID payload (0 on our synthetic events).
let kCGEventGestureSwipeMask      = CGEventField(rawValue: 115)!

/// Horizontal gesture position. macOS 27's Dock discards gestures whose
/// position is exactly zero, so synthetic events carry a small epsilon.
let kCGEventGesturePositionX      = CGEventField(rawValue: 125)!

/// Vertical gesture position. Read back when serializing the IOHID payload.
let kCGEventGesturePositionY      = CGEventField(rawValue: 126)!

/// Duplicate of the gesture phase — exact meaning unknown, but macOS 27's
/// Dock expects it to mirror field 132 (`kCGEventGesturePhase`).
let kCGEventGesturePhase2         = CGEventField(rawValue: 134)!

/// Gesture flavor. Set to 3.0 (`kIOHIDGestureFlavorDockPrimary`) so the
/// Dock treats the event as a primary dock swipe.
let kCGEventGestureFlavor         = CGEventField(rawValue: 138)!

/// Event timestamp, carried as `mach_absolute_time()` cast to a double.
let kCGEventGestureTimestamp      = CGEventField(rawValue: 169)!

/// Field ID of the serialized IOHID queue payload that macOS 27 validates
/// synthetic dock swipes against. This field can NOT be set through
/// `CGEventSetIntegerValueField` — it is appended in raw serialized form
/// to the flattened event bytes (see `augmentDockSwipeEvent`).
let kCGEventIOHIDPayloadField: UInt16 = 4205

// MARK: - Undocumented Event Type Constants
//
// These integer values identify specific event subtypes used in the
// synthetic gesture events. They correspond to internal HID and CGS enums.

/// HID event type for a Dock swipe gesture.
let kIOHIDEventTypeDockSwipe: Int64 = 23

/// CGS event subtype: generic gesture (acts as the envelope event).
let kCGSEventGesture:         Int64 = 29

/// CGS event subtype: Dock control gesture (carries the actual swipe payload).
let kCGSEventDockControl:     Int64 = 30

/// Gesture phase: the swipe has just started (no velocity yet).
let kCGSGesturePhaseBegan:    Int64 = 1

/// Gesture phase: the swipe is in progress (macOS 27's Dock requires a
/// Changed phase between Began and Ended for synthetic swipes).
let kCGSGesturePhaseChanged:  Int64 = 2

/// Gesture phase: the swipe has ended (velocity and progress are evaluated).
let kCGSGesturePhaseEnded:    Int64 = 4

/// Gesture phase: the swipe was cancelled by the system (e.g. more fingers
/// landed, or the gesture was reinterpreted). Only ever observed by the
/// swipe-intercept tap — synthetic gestures never post this phase.
let kCGSGesturePhaseCancelled: Int64 = 8

// MARK: - IOHID Payload Constants (macOS 27 Augmented Gestures)
//
// macOS 27 validates synthetic dock swipes against a serialized IOHID
// queue payload attached to the event (field 4205). These constants
// describe the packed structures inside that payload.

/// IOHID event type: velocity data attached to a gesture.
let kIOHIDEventTypeVelocity:          UInt32 = 9

/// IOHID event type: fluid touch gesture (carries the swipe itself).
let kIOHIDEventTypeFluidTouchGesture: UInt32 = 23

/// Gesture flavor identifying a primary dock swipe.
let kIOHIDGestureFlavorDockPrimary:   UInt16 = 3

// MARK: - CGS Type Aliases

/// Opaque connection handle returned by `CGSMainConnectionID`.
/// Represents the current login session's connection to the window server.
typealias CGSConnectionID = Int32

/// 64-bit identifier for a single Space (virtual desktop).
/// Each space on each display has a unique ID assigned by the window server.
typealias CGSSpaceID      = UInt64

// MARK: - Private CGS Function Signatures
//
// These are the C calling-convention signatures of the private functions
// we resolve at runtime. Each typedef matches the actual symbol's ABI
// so that `unsafeBitCast` produces a callable function pointer.

/// `CGSMainConnectionID() -> CGSConnectionID`
/// Returns the connection ID for the current login session.
typealias FnMainConnection   = @convention(c) () -> CGSConnectionID

/// `CGSGetActiveSpace(cid) -> CGSSpaceID`
/// Returns the ID of the currently active space on the main display.
typealias FnActiveSpace      = @convention(c) (CGSConnectionID) -> CGSSpaceID

/// `CGSCopyManagedDisplaySpaces(cid, displayUUID?) -> CFArray?`
/// Returns an array of dictionaries describing every display and its spaces.
/// Pass `nil` for the display UUID to get all displays.
typealias FnDisplaySpaces    = @convention(c) (CGSConnectionID, CFString?) -> Unmanaged<CFArray>?

/// `SLSCopySpacesForWindows(cid, spaceType, windowIDs) -> CFArray?`
/// Maps an array of window IDs to the space IDs they belong to.
/// `spaceType` is a bitmask (7 = all space types).
typealias FnSpacesForWindows = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?

// MARK: - Runtime Symbol Resolution
//
// We load private symbols from the WindowServer framework using dlsym
// at process startup. If any symbol is missing (e.g. Apple renamed it
// in a future macOS version), the corresponding variable will be nil
// and the features that depend on it will gracefully no-op.

/// `RTLD_DEFAULT` — search all loaded images for the symbol.
/// This is the macOS equivalent of `(void *)-2`, which tells dlsym
/// to search every loaded dynamic library in the process.
private let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2 as Int)

/// Resolves a C symbol by name and casts it to the requested function type.
///
/// - Parameter name: The mangled symbol name (e.g. "CGSMainConnectionID").
/// - Returns: A callable function pointer, or `nil` if the symbol was not found.
private func loadSymbol<T>(_ name: String) -> T? {
    guard let ptr = dlsym(rtldDefault, name) else { return nil }
    return unsafeBitCast(ptr, to: T.self)
}

/// Returns the CGS connection ID for the current session.
let cgsMainConnection:       FnMainConnection?   = loadSymbol("CGSMainConnectionID")

/// Returns the active space ID on the main display.
let cgsGetActiveSpace:       FnActiveSpace?       = loadSymbol("CGSGetActiveSpace")

/// Lists all displays and their associated spaces.
let cgsCopyDisplaySpaces:    FnDisplaySpaces?     = loadSymbol("CGSCopyManagedDisplaySpaces")

/// Maps window IDs to the spaces they live on.
let slsCopySpacesForWindows: FnSpacesForWindows?  = loadSymbol("SLSCopySpacesForWindows")

// NOTE: CGSManagedDisplaySetCurrentSpace was tried for cross-display
// switching and removed — it desyncs window-server state (see the
// cross-display comment in SpaceSwitching.switchToSpace). Don't re-add.
