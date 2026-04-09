/*
 * noswoop — Disable macOS space-switching animation
 *
 * Features:
 *   1. Instant space switch via synthetic DockSwipe gestures
 *   2. Auto-follow on Cmd+Tab to app's space
 *   3. Menu bar icon with toggles and usage stats
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

/* ── Global state ───────────────────────────────────────────────────── */

static CFMachPortRef g_tap;

/* Feature toggles */
static bool g_instant_switch_enabled = true;
static bool g_auto_follow_enabled = true;

/* Stats */
static NSInteger g_switch_count = 0;

/* Shortcut config (read from macOS preferences) */
static int64_t g_key_left = 123;
static int64_t g_key_right = 124;
static CGEventFlags g_mod_mask = kCGEventFlagMaskControl;

/* Forward declarations */
@class NSSwoopMenu;
static NSSwoopMenu *g_menu;

/* ── Menu bar UI ────────────────────────────────────────────────────── */

static NSString *format_time_saved(NSInteger seconds) {
    if (seconds < 60)
        return [NSString stringWithFormat:@"%ld sec", (long)seconds];
    if (seconds < 3600)
        return [NSString stringWithFormat:@"%ld min", (long)(seconds / 60)];
    if (seconds < 86400) {
        NSInteger hr = seconds / 3600;
        NSInteger min = (seconds % 3600) / 60;
        return min > 0
            ? [NSString stringWithFormat:@"%ld hr %ld min", (long)hr, (long)min]
            : [NSString stringWithFormat:@"%ld hr", (long)hr];
    }
    NSInteger days = seconds / 86400;
    NSInteger hr = (seconds % 86400) / 3600;
    return hr > 0
        ? [NSString stringWithFormat:@"%ld days %ld hr", (long)days, (long)hr]
        : [NSString stringWithFormat:@"%ld days", (long)days];
}

@interface NSSwoopMenu : NSObject
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem *instantSwitchItem;
@property (nonatomic, strong) NSMenuItem *autoFollowItem;
@property (nonatomic, strong) NSMenuItem *statsItem;
- (void)recordSwitch;
@end

@implementation NSSwoopMenu

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    /* Load persisted state */
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud registerDefaults:@{
        @"noswoop.instantSwitch": @YES,
        @"noswoop.autoFollow": @YES,
        @"noswoop.switchCount": @0,
    }];
    g_instant_switch_enabled = [ud boolForKey:@"noswoop.instantSwitch"];
    g_auto_follow_enabled = [ud boolForKey:@"noswoop.autoFollow"];
    g_switch_count = [ud integerForKey:@"noswoop.switchCount"];

    /* Status item with SF Symbol */
    _statusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSVariableStatusItemLength];
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"hare.fill"
                               accessibilityDescription:@"noswoop"];
    icon.template = YES;
    _statusItem.button.image = icon;

    /* Build menu */
    NSMenu *menu = [[NSMenu alloc] init];

    _instantSwitchItem = [[NSMenuItem alloc]
        initWithTitle:@"Instant space switch"
        action:@selector(toggleInstantSwitch:)
        keyEquivalent:@""];
    _instantSwitchItem.target = self;
    _instantSwitchItem.state = g_instant_switch_enabled
        ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:_instantSwitchItem];

    _autoFollowItem = [[NSMenuItem alloc]
        initWithTitle:@"Auto-follow on \u2318\u21E5"
        action:@selector(toggleAutoFollow:)
        keyEquivalent:@""];
    _autoFollowItem.target = self;
    _autoFollowItem.state = g_auto_follow_enabled
        ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:_autoFollowItem];

    [menu addItem:[NSMenuItem separatorItem]];

    _statsItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    _statsItem.enabled = NO;
    [self updateStatsDisplay];
    [menu addItem:_statsItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc]
        initWithTitle:@"Quit"
        action:@selector(terminate:)
        keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];

    _statusItem.menu = menu;
    return self;
}

- (void)toggleInstantSwitch:(NSMenuItem *)sender {
    g_instant_switch_enabled = !g_instant_switch_enabled;
    sender.state = g_instant_switch_enabled
        ? NSControlStateValueOn : NSControlStateValueOff;
    [[NSUserDefaults standardUserDefaults]
        setBool:g_instant_switch_enabled forKey:@"noswoop.instantSwitch"];
}

- (void)toggleAutoFollow:(NSMenuItem *)sender {
    g_auto_follow_enabled = !g_auto_follow_enabled;
    sender.state = g_auto_follow_enabled
        ? NSControlStateValueOn : NSControlStateValueOff;
    [[NSUserDefaults standardUserDefaults]
        setBool:g_auto_follow_enabled forKey:@"noswoop.autoFollow"];
}

- (void)updateStatsDisplay {
    NSNumberFormatter *fmt = [[NSNumberFormatter alloc] init];
    fmt.numberStyle = NSNumberFormatterDecimalStyle;
    NSString *countStr = [fmt stringFromNumber:@(g_switch_count)];
    NSString *timeStr = format_time_saved(g_switch_count); /* 1 sec per switch */
    _statsItem.title = [NSString stringWithFormat:@"%@ switches  ·  %@ saved",
                        countStr, timeStr];
}

- (void)recordSwitch {
    g_switch_count++;
    [[NSUserDefaults standardUserDefaults]
        setInteger:g_switch_count forKey:@"noswoop.switchCount"];
    [self updateStatsDisplay];
}

@end

/* ── Shortcut loading ───────────────────────────────────────────────── */

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

    CFNumberRef keycodeNum = CFArrayGetValueAtIndex(params, 1);
    CFNumberRef modsNum = CFArrayGetValueAtIndex(params, 2);

    int64_t keycode = 0, mods = 0;
    CFNumberGetValue(keycodeNum, kCFNumberSInt64Type, &keycode);
    CFNumberGetValue(modsNum, kCFNumberSInt64Type, &mods);

    if (keycode != 65535)
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

    load_hotkey(prefs, CFSTR("79"), &leftKey, &leftMods);
    load_hotkey(prefs, CFSTR("81"), &rightKey, &rightMods);

    CFRelease(prefs);

    g_key_left = leftKey;
    g_key_right = rightKey;

    if (leftMods) g_mod_mask = leftMods;
    else if (rightMods) g_mod_mask = rightMods;
}

/* ── Space list helpers ─────────────────────────────────────────────── */

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

/* ── Feature 1: Instant space switch ────────────────────────────────── */

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
    if (!g_instant_switch_enabled) return event;

    CGEventFlags flags = CGEventGetFlags(event);
    int64_t keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);

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

    if (post_switch_gesture(direction))
        [g_menu recordSwitch];

    return NULL;
}

/* ── Feature 2: Auto-follow on app activation ───────────────────────── */

/*
 * Collect the "current space" for every display into a set,
 * so we can check if a window's space is already visible on ANY display.
 */
static CFIndex get_all_current_spaces(CGSSpaceID *outIDs, CFIndex maxIDs) {
    if (&CGSMainConnectionID == NULL || &CGSCopyManagedDisplaySpaces == NULL)
        return 0;

    CGSConnectionID cid = CGSMainConnectionID();
    if (cid == 0) return 0;

    CFArrayRef displays = CGSCopyManagedDisplaySpaces(cid, NULL);
    if (!displays) return 0;

    CFIndex count = 0;
    for (CFIndex d = 0; d < CFArrayGetCount(displays) && count < maxIDs; d++) {
        CFDictionaryRef dd = CFArrayGetValueAtIndex(displays, d);
        if (!dd || CFGetTypeID(dd) != CFDictionaryGetTypeID()) continue;

        CFDictionaryRef curSD = CFDictionaryGetValue(dd, CFSTR("Current Space"));
        if (!curSD) continue;

        CFNumberRef idNum = CFDictionaryGetValue(curSD, CFSTR("id64"));
        if (!idNum) continue;

        CGSSpaceID sid = 0;
        CFNumberGetValue(idNum, kCFNumberSInt64Type, &sid);
        if (sid != 0) outIDs[count++] = sid;
    }

    CFRelease(displays);
    return count;
}

static bool is_space_currently_visible(CGSSpaceID sid,
                                       CGSSpaceID *currentSpaces, CFIndex currentCount) {
    for (CFIndex i = 0; i < currentCount; i++) {
        if (currentSpaces[i] == sid) return true;
    }
    return false;
}

/*
 * Find which space a given PID's windows are on.
 * Returns the space ID, or 0 if the app is already visible on any display.
 */
static CGSSpaceID find_space_for_pid(pid_t pid) {
    if (&CGSMainConnectionID == NULL || &SLSCopySpacesForWindows == NULL)
        return 0;

    CGSConnectionID cid = CGSMainConnectionID();
    if (cid == 0) return 0;

    /* Get the current space for ALL displays */
    CGSSpaceID currentSpaces[16];
    CFIndex currentCount = get_all_current_spaces(currentSpaces, 16);

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
            /* Only switch if this space isn't already visible on any display */
            if (sid != 0 && !is_space_currently_visible(sid, currentSpaces, currentCount)) {
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

/*
 * Switch to the space containing targetSpace.
 * Searches ALL displays — not just the focused one — so it works
 * when the target app's window is on a different monitor.
 */
static void switch_to_space(CGSSpaceID targetSpace) {
    if (&CGSMainConnectionID == NULL || &CGSCopyManagedDisplaySpaces == NULL)
        return;

    CGSConnectionID cid = CGSMainConnectionID();
    if (cid == 0) return;

    CFArrayRef displays = CGSCopyManagedDisplaySpaces(cid, NULL);
    if (!displays) return;

    for (CFIndex d = 0; d < CFArrayGetCount(displays); d++) {
        CFDictionaryRef dd = CFArrayGetValueAtIndex(displays, d);
        if (!dd || CFGetTypeID(dd) != CFDictionaryGetTypeID()) continue;

        /* Get this display's current space */
        CFDictionaryRef curSD = CFDictionaryGetValue(dd, CFSTR("Current Space"));
        if (!curSD) continue;
        CFNumberRef curIDNum = CFDictionaryGetValue(curSD, CFSTR("id64"));
        if (!curIDNum) continue;
        CGSSpaceID displayCurrentSpace = 0;
        CFNumberGetValue(curIDNum, kCFNumberSInt64Type, &displayCurrentSpace);

        /* Build space list for this display */
        CFArrayRef spaces = CFDictionaryGetValue(dd, CFSTR("Spaces"));
        if (!spaces) continue;

        CFIndex count = CFArrayGetCount(spaces);
        CGSSpaceID sids[64];
        CFIndex spaceCount = 0;
        CFIndex currentIdx = -1;
        CFIndex targetIdx = -1;

        for (CFIndex i = 0; i < count && spaceCount < 64; i++) {
            CFDictionaryRef sp = CFArrayGetValueAtIndex(spaces, i);
            if (!sp || CFGetTypeID(sp) != CFDictionaryGetTypeID()) continue;

            CFNumberRef sid = CFDictionaryGetValue(sp, CFSTR("id64"));
            if (!sid) continue;

            CGSSpaceID val = 0;
            CFNumberGetValue(sid, kCFNumberSInt64Type, &val);
            sids[spaceCount] = val;
            if (val == displayCurrentSpace) currentIdx = spaceCount;
            if (val == targetSpace) targetIdx = spaceCount;
            spaceCount++;
        }

        /* Target not on this display — try next */
        if (targetIdx < 0) continue;

        /* Already on the target space */
        if (targetIdx == currentIdx) break;

        if (currentIdx < 0 || spaceCount < 2) break;

        int direction = (targetIdx > currentIdx) ? +1 : -1;
        int steps = (int)(targetIdx > currentIdx
            ? targetIdx - currentIdx
            : currentIdx - targetIdx);

        switch_n_spaces(direction, steps);
        break;
    }

    CFRelease(displays);
}

@interface NSSwoopObserver : NSObject
- (void)appActivated:(NSNotification *)note;
@end

@implementation NSSwoopObserver
- (void)appActivated:(NSNotification *)note {
    if (!g_auto_follow_enabled) return;

    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (!app) return;

    CGSSpaceID targetSpace = find_space_for_pid(app.processIdentifier);
    if (targetSpace == 0) return;

    switch_to_space(targetSpace);
    [g_menu recordSwitch];

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
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}

int main(void) {
    @autoreleasepool {
        /* Hide from Dock */
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

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

        /* Load shortcuts from macOS preferences */
        load_space_switch_shortcuts();

        /* Menu bar */
        g_menu = [[NSSwoopMenu alloc] init];

        /* Event tap for instant space switch */
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

        /* Auto-follow observer */
        NSSwoopObserver *observer = [[NSSwoopObserver alloc] init];
        [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserver:observer
            selector:@selector(appActivated:)
            name:NSWorkspaceDidActivateApplicationNotification
            object:nil];

        signal(SIGINT, on_signal);
        signal(SIGTERM, on_signal);

        printf("noswoop: running\n");
        [NSApp run];

        /* Cleanup */
        [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:observer];
        CGEventTapEnable(g_tap, false);
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
        CFRelease(source);
        CFRelease(g_tap);
    }
    return 0;
}
