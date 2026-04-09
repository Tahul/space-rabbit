/*
 * noswoop — Disable macOS space-switching animation
 *
 * Two features:
 *   1. Ctrl+Arrow instant space switch via synthetic DockSwipe gestures
 *   2. Auto-follow on Cmd+Tab: when an activated app's windows are on
 *      a different space, instantly switch there
 *
 * Requires Accessibility permissions (System Settings → Privacy → Accessibility).
 */

#import <AppKit/AppKit.h>
#include <stdio.h>
#include <stdbool.h>
#include <float.h>
#include <signal.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ApplicationServices/ApplicationServices.h>

/* ── Private CGEvent fields for gesture synthesis ───────────────────── */

static const CGEventField kCGSEventTypeField           = 55;
static const CGEventField kCGEventGestureHIDType        = 110;
static const CGEventField kCGEventGestureScrollY        = 119;
static const CGEventField kCGEventGestureSwipeMotion    = 123;
static const CGEventField kCGEventGestureSwipeProgress  = 124;
static const CGEventField kCGEventGestureSwipeVelocityX = 129;
static const CGEventField kCGEventGestureSwipeVelocityY = 130;
static const CGEventField kCGEventGesturePhase          = 132;
static const CGEventField kCGEventScrollGestureFlagBits = 135;
static const CGEventField kCGEventGestureZoomDeltaX     = 139;

static const uint32_t kIOHIDEventTypeDockSwipe = 23;

enum {
    kCGSEventGesture     = 29,
    kCGSEventDockControl = 30,
};

enum {
    kCGSGesturePhaseBegan = 1,
    kCGSGesturePhaseEnded = 4,
};

/* ── Private CGS API declarations ───────────────────────────────────── */

typedef int CGSConnectionID;
typedef uint64_t CGSSpaceID;

extern CGSConnectionID CGSMainConnectionID(void) __attribute__((weak_import));
extern CGSSpaceID CGSGetActiveSpace(CGSConnectionID cid) __attribute__((weak_import));
extern CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID cid, CFStringRef display) __attribute__((weak_import));
extern CFArrayRef SLSCopySpacesForWindows(CGSConnectionID cid, int selector, CFArrayRef windowIDs) __attribute__((weak_import));

static CFMachPortRef g_tap;

/* Space-switch shortcut config (read from macOS preferences) */
static int64_t g_key_left = 123;             /* keycode for "Move left a space" */
static int64_t g_key_right = 124;            /* keycode for "Move right a space" */
static CGEventFlags g_mod_mask = kCGEventFlagMaskControl;  /* modifier for space switch */

/*
 * Read "Move left/right a space" shortcuts from macOS preferences.
 *
 * Stored in com.apple.symbolichotkeys → AppleSymbolicHotKeys:
 *   ID 79 = Move left a space
 *   ID 81 = Move right a space
 * Each has: parameters = (charCode, keycode, modifierFlags)
 *
 * Modifier flags (Carbon-style):
 *   Ctrl  = 0x040000 (262144)   → kCGEventFlagMaskControl
 *   Shift = 0x020000 (131072)   → kCGEventFlagMaskShift
 *   Opt   = 0x080000 (524288)   → kCGEventFlagMaskAlternate
 *   Cmd   = 0x100000 (1048576)  → kCGEventFlagMaskCommand
 */
static CGEventFlags carbon_to_cg_flags(int64_t carbon) {
    CGEventFlags flags = 0;
    if (carbon & 0x040000) flags |= kCGEventFlagMaskControl;
    if (carbon & 0x020000) flags |= kCGEventFlagMaskShift;
    if (carbon & 0x080000) flags |= kCGEventFlagMaskAlternate;
    if (carbon & 0x100000) flags |= kCGEventFlagMaskCommand;
    return flags;
}

static void load_hotkey(CFDictionaryRef hotkeys, CFStringRef keyID,
                        int64_t *outKeycode, CGEventFlags *outMods) {
    CFDictionaryRef entry = NULL;
    if (!CFDictionaryGetValueIfPresent(hotkeys, keyID, (const void **)&entry)) return;
    if (!entry || CFGetTypeID(entry) != CFDictionaryGetTypeID()) return;

    /* Check if enabled (stored as CFNumber 0/1 or CFBoolean) */
    CFTypeRef enabled = CFDictionaryGetValue(entry, CFSTR("enabled"));
    if (enabled) {
        if (CFGetTypeID(enabled) == CFBooleanGetTypeID()) {
            if (!CFBooleanGetValue((CFBooleanRef)enabled)) return;
        } else if (CFGetTypeID(enabled) == CFNumberGetTypeID()) {
            int val = 0;
            CFNumberGetValue((CFNumberRef)enabled, kCFNumberIntType, &val);
            if (!val) return;
        }
    }

    CFDictionaryRef value = CFDictionaryGetValue(entry, CFSTR("value"));
    if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) return;

    CFArrayRef params = CFDictionaryGetValue(value, CFSTR("parameters"));
    if (!params || CFArrayGetCount(params) < 3) return;

    /* parameters = (charCode, keycode, modifierFlags) */
    CFNumberRef keycodeNum = CFArrayGetValueAtIndex(params, 1);
    CFNumberRef modsNum = CFArrayGetValueAtIndex(params, 2);

    int64_t keycode = 0, mods = 0;
    CFNumberGetValue(keycodeNum, kCFNumberSInt64Type, &keycode);
    CFNumberGetValue(modsNum, kCFNumberSInt64Type, &mods);

    if (keycode != 65535) /* 65535 = unset */
        *outKeycode = keycode;
    if (mods != 0)
        *outMods = carbon_to_cg_flags(mods);
}

static void load_space_switch_shortcuts(void) {
    CFDictionaryRef prefs = CFPreferencesCopyAppValue(
        CFSTR("AppleSymbolicHotKeys"),
        CFSTR("com.apple.symbolichotkeys")
    );
    if (!prefs) return;

    CGEventFlags leftMods = 0, rightMods = 0;
    int64_t leftKey = g_key_left, rightKey = g_key_right;

    load_hotkey(prefs, CFSTR("79"), &leftKey, &leftMods);   /* Move left a space */
    load_hotkey(prefs, CFSTR("81"), &rightKey, &rightMods);  /* Move right a space */

    CFRelease(prefs);

    g_key_left = leftKey;
    g_key_right = rightKey;

    /* Use the modifier from either shortcut (they're normally the same) */
    if (leftMods) g_mod_mask = leftMods;
    else if (rightMods) g_mod_mask = rightMods;

    printf("noswoop: shortcuts loaded — left=keycode %lld, right=keycode %lld, mod=0x%llx\n",
           g_key_left, g_key_right, (unsigned long long)g_mod_mask);
}

/* ── Space list helpers ─────────────────────────────────────────────── */

/*
 * Build the ordered list of space IDs for the display containing the
 * active space. Returns the count and fills outIDs (caller provides buffer).
 * Sets *outCurrentIdx to the index of the active space, or -1.
 */
static CFIndex get_space_list(CGSSpaceID *outIDs, CFIndex maxIDs, CFIndex *outCurrentIdx) {
    *outCurrentIdx = -1;

    if (&CGSMainConnectionID == NULL || &CGSGetActiveSpace == NULL ||
        &CGSCopyManagedDisplaySpaces == NULL)
        return 0;

    CGSConnectionID cid = CGSMainConnectionID();
    if (cid == 0) return 0;

    CGSSpaceID active = CGSGetActiveSpace(cid);
    if (active == 0) return 0;

    CFArrayRef displays = CGSCopyManagedDisplaySpaces(cid, NULL);
    if (!displays) return 0;

    CFIndex count = 0;

    for (CFIndex d = 0; d < CFArrayGetCount(displays); d++) {
        CFDictionaryRef dd = CFArrayGetValueAtIndex(displays, d);
        if (!dd || CFGetTypeID(dd) != CFDictionaryGetTypeID()) continue;

        CFDictionaryRef curSD = CFDictionaryGetValue(dd, CFSTR("Current Space"));
        if (!curSD) continue;

        CFNumberRef idNum = CFDictionaryGetValue(curSD, CFSTR("id64"));
        if (!idNum) continue;

        CGSSpaceID curSID = 0;
        CFNumberGetValue(idNum, kCFNumberSInt64Type, &curSID);
        if (curSID != active) continue;

        CFArrayRef spaces = CFDictionaryGetValue(dd, CFSTR("Spaces"));
        if (!spaces) break;

        CFIndex spaceCount = CFArrayGetCount(spaces);
        for (CFIndex i = 0; i < spaceCount && count < maxIDs; i++) {
            CFDictionaryRef sp = CFArrayGetValueAtIndex(spaces, i);
            if (!sp || CFGetTypeID(sp) != CFDictionaryGetTypeID()) continue;

            CFNumberRef sid = CFDictionaryGetValue(sp, CFSTR("id64"));
            if (!sid) continue;

            CGSSpaceID val = 0;
            CFNumberGetValue(sid, kCFNumberSInt64Type, &val);
            outIDs[count] = val;
            if (val == active) *outCurrentIdx = count;
            count++;
        }
        break;
    }

    CFRelease(displays);
    return count;
}

/* ── Gesture posting ────────────────────────────────────────────────── */

static bool post_gesture_pair(int32_t flagDirection, uint8_t phase,
                              double progress, double velocity) {
    CGEventRef gestureEv = CGEventCreate(NULL);
    CGEventRef dockEv = CGEventCreate(NULL);
    if (!gestureEv || !dockEv) {
        if (gestureEv) CFRelease(gestureEv);
        if (dockEv) CFRelease(dockEv);
        return false;
    }

    CGEventSetIntegerValueField(gestureEv, kCGSEventTypeField, kCGSEventGesture);

    CGEventSetIntegerValueField(dockEv, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(dockEv, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(dockEv, kCGEventGesturePhase, phase);
    CGEventSetIntegerValueField(dockEv, kCGEventScrollGestureFlagBits, flagDirection);
    CGEventSetIntegerValueField(dockEv, kCGEventGestureSwipeMotion, 1);
    CGEventSetDoubleValueField(dockEv, kCGEventGestureScrollY, 0);
    CGEventSetDoubleValueField(dockEv, kCGEventGestureZoomDeltaX, FLT_TRUE_MIN);

    if (phase == kCGSGesturePhaseEnded) {
        CGEventSetDoubleValueField(dockEv, kCGEventGestureSwipeProgress, progress);
        CGEventSetDoubleValueField(dockEv, kCGEventGestureSwipeVelocityX, velocity);
        CGEventSetDoubleValueField(dockEv, kCGEventGestureSwipeVelocityY, 0);
    }

    CGEventPost(kCGSessionEventTap, dockEv);
    CGEventPost(kCGSessionEventTap, gestureEv);

    CFRelease(gestureEv);
    CFRelease(dockEv);
    return true;
}

static bool post_switch_gesture(int direction) {
    bool isRight = (direction > 0);
    int32_t flagDirection = isRight ? 1 : 0;
    double progress = isRight ? 2.0 : -2.0;
    double velocity = isRight ? 400.0 : -400.0;

    if (!post_gesture_pair(flagDirection, kCGSGesturePhaseBegan, 0, 0))
        return false;
    if (!post_gesture_pair(flagDirection, kCGSGesturePhaseEnded, progress, velocity))
        return false;

    return true;
}

static void switch_n_spaces(int direction, int steps) {
    for (int i = 0; i < steps; i++) {
        if (!post_switch_gesture(direction)) {
            fprintf(stderr, "noswoop: gesture failed at step %d/%d\n", i + 1, steps);
            break;
        }
    }
}

/* Forward declarations */
static CGSSpaceID find_space_for_pid(pid_t pid);
static void switch_to_space(CGSSpaceID targetSpace);

/* ── Feature 1: Ctrl+Arrow instant switch ───────────────────────────── */

static CGEventRef event_tap_callback(
    CGEventTapProxy proxy __attribute__((unused)),
    CGEventType type,
    CGEventRef event,
    void *userInfo __attribute__((unused))
) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_tap) CGEventTapEnable(g_tap, true);
        return event;
    }

    if (type != kCGEventKeyDown) return event;

    CGEventFlags flags = CGEventGetFlags(event);
    int64_t keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);

    /* Match against the configured space-switch modifier */
    CGEventFlags relevantMods = kCGEventFlagMaskControl | kCGEventFlagMaskCommand |
                                kCGEventFlagMaskAlternate | kCGEventFlagMaskShift;
    if ((flags & relevantMods) != g_mod_mask) return event;

    int direction = 0;
    if (keycode == g_key_left)  direction = -1;
    else if (keycode == g_key_right) direction = +1;
    else return event;

    CGSSpaceID spaceIDs[64];
    CFIndex currentIdx = -1;
    CFIndex count = get_space_list(spaceIDs, 64, &currentIdx);

    if (currentIdx >= 0) {
        CFIndex targetIdx = currentIdx + direction;
        if (targetIdx < 0 || targetIdx >= count)
            return NULL;
    }

    if (!post_switch_gesture(direction))
        fprintf(stderr, "noswoop: gesture post failed\n");

    return NULL;
}

/* ── Feature 2: Auto-follow on app activation ───────────────────────── */

/*
 * Find which space a given PID's windows are on.
 * Returns the space ID, or 0 if not found or already on current space.
 */
static CGSSpaceID find_space_for_pid(pid_t pid) {
    if (&CGSMainConnectionID == NULL || &SLSCopySpacesForWindows == NULL)
        return 0;

    CGSConnectionID cid = CGSMainConnectionID();
    if (cid == 0) return 0;

    CGSSpaceID active = CGSGetActiveSpace(cid);

    CFArrayRef winList = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, 0);
    if (!winList) return 0;

    CGSSpaceID targetSpace = 0;

    for (CFIndex i = 0; i < CFArrayGetCount(winList); i++) {
        CFDictionaryRef win = CFArrayGetValueAtIndex(winList, i);

        CFNumberRef pidNum = CFDictionaryGetValue(win, CFSTR("kCGWindowOwnerPID"));
        if (!pidNum) continue;
        int32_t winPid = 0;
        CFNumberGetValue(pidNum, kCFNumberSInt32Type, &winPid);
        if (winPid != pid) continue;

        /* Only consider normal windows (layer 0) */
        CFNumberRef layerNum = CFDictionaryGetValue(win, CFSTR("kCGWindowLayer"));
        if (layerNum) {
            int32_t layer = 0;
            CFNumberGetValue(layerNum, kCFNumberSInt32Type, &layer);
            if (layer != 0) continue;
        }

        CFNumberRef widNum = CFDictionaryGetValue(win, kCGWindowNumber);
        if (!widNum) continue;

        uint32_t wid = 0;
        CFNumberGetValue(widNum, kCFNumberSInt32Type, &wid);

        CFNumberRef widCF = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
        CFArrayRef widArr = CFArrayCreate(NULL, (const void **)&widCF, 1, &kCFTypeArrayCallBacks);

        CFArrayRef spaces = SLSCopySpacesForWindows(cid, 7, widArr);
        CFRelease(widCF);
        CFRelease(widArr);

        if (spaces && CFArrayGetCount(spaces) > 0) {
            CFNumberRef spaceNum = CFArrayGetValueAtIndex(spaces, 0);
            CGSSpaceID sid = 0;
            CFNumberGetValue(spaceNum, kCFNumberSInt64Type, &sid);
            if (sid != 0 && sid != active) {
                targetSpace = sid;
                CFRelease(spaces);
                break;
            }
        }
        if (spaces) CFRelease(spaces);
    }

    CFRelease(winList);
    return targetSpace;
}

static void switch_to_space(CGSSpaceID targetSpace) {
    CGSSpaceID spaceIDs[64];
    CFIndex currentIdx = -1;
    CFIndex count = get_space_list(spaceIDs, 64, &currentIdx);

    if (currentIdx < 0 || count < 2) return;

    CFIndex targetIdx = -1;
    for (CFIndex i = 0; i < count; i++) {
        if (spaceIDs[i] == targetSpace) {
            targetIdx = i;
            break;
        }
    }
    if (targetIdx < 0 || targetIdx == currentIdx) return;

    int direction = (targetIdx > currentIdx) ? +1 : -1;
    int steps = (int)(targetIdx > currentIdx ? targetIdx - currentIdx : currentIdx - targetIdx);

    switch_n_spaces(direction, steps);
}

@interface NSSwoopObserver : NSObject
- (void)appActivated:(NSNotification *)note;
@end

@implementation NSSwoopObserver
- (void)appActivated:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (!app) return;

    CGSSpaceID targetSpace = find_space_for_pid(app.processIdentifier);
    if (targetSpace == 0) return;

    /* Switch space instantly */
    switch_to_space(targetSpace);

    /*
     * Re-activate the app after a short delay. The Dock's own space
     * switch (animated) races with ours. By re-activating on the next
     * run loop cycle, we ensure the app's windows come to front on
     * the correct space after everything settles.
     */
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
        dispatch_get_main_queue(),
        ^{
            [app activateWithOptions:NSApplicationActivateAllWindows];
        }
    );
}
@end

/* ── Main ───────────────────────────────────────────────────────────── */

static void on_signal(int sig __attribute__((unused))) {
    CFRunLoopStop(CFRunLoopGetMain());
}

int main(void) {
    @autoreleasepool {
        /* Check Accessibility permissions */
        {
            const void *keys[] = { kAXTrustedCheckOptionPrompt };
            const void *vals[] = { kCFBooleanTrue };
            CFDictionaryRef opts = CFDictionaryCreate(
                NULL, keys, vals, 1,
                &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks
            );
            bool trusted = AXIsProcessTrustedWithOptions(opts);
            CFRelease(opts);
            if (!trusted) {
                fprintf(stderr, "noswoop: accessibility permission required\n");
                fprintf(stderr, "  Grant in: System Settings → Privacy & Security → Accessibility\n");
                return 1;
            }
        }

        /* Load space-switch shortcuts from macOS preferences */
        load_space_switch_shortcuts();

        /* Feature 1: keyboard space switch event tap */
        CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
        g_tap = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionDefault,
            mask,
            event_tap_callback,
            NULL
        );

        if (!g_tap) {
            fprintf(stderr, "noswoop: failed to create event tap\n");
            return 1;
        }

        CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, g_tap, 0);
        if (!source) {
            fprintf(stderr, "noswoop: failed to create run loop source\n");
            CFRelease(g_tap);
            return 1;
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
        CGEventTapEnable(g_tap, true);

        /* Feature 2: auto-follow on Cmd+Tab */
        NSSwoopObserver *observer = [[NSSwoopObserver alloc] init];
        [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserver:observer
            selector:@selector(appActivated:)
            name:NSWorkspaceDidActivateApplicationNotification
            object:nil];

        signal(SIGINT, on_signal);
        signal(SIGTERM, on_signal);

        printf("noswoop: running\n");
        printf("  space switch → instant (no animation)\n");
        printf("  app activate → auto-follow to app's space\n");

        CFRunLoopRun();

        /* Cleanup */
        [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:observer];
        CGEventTapEnable(g_tap, false);
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
        CFRelease(source);
        CFRelease(g_tap);

        printf("noswoop: stopped\n");
    }
    return 0;
}
