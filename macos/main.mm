// main.mm
// UnikeyAI - a macOS menu-bar Vietnamese input method built on top of
// the original x-unikey engine (src/ukengine, src/ukinterface, src/vnconv).
//
// How it works (see doc for the full explanation):
//   1. A CGEventTap intercepts every key-down system-wide.
//   2. Each printable key is fed into UnikeyFilter() (the same C function
//      the Linux XIM/GTK front-ends call) - this is the unmodified,
//      original Vietnamese-processing algorithm.
//   3. The engine tells us how many characters to erase (UnikeyBackspaces)
//      and what UTF-8 text to insert instead (UnikeyBuf/UnikeyBufChars).
//   4. We synthesize that as fake keystrokes back into the focused app.
//
// This file is the ONLY new platform-specific code; everything Vietnamese-
// specific still lives in the original, unmodified engine.

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ServiceManagement/ServiceManagement.h>
#include <unistd.h> // usleep

extern "C" {
#include "unikey.h"
}

// macOS virtual key code for the Backspace/Delete key (left of Return).
static const CGKeyCode kBackspaceKeyCode = 51;

// Marker stamped on every event WE synthesize (backspaces + unicode-insert),
// so the tap can recognize and ignore its own output instead of feeding it
// back into UnikeyFilter()/UnikeyBackspacePress() a second time. Without
// this, kCGHIDEventTap-posted events flow back up through our
// kCGSessionEventTap and get reprocessed, corrupting the engine's internal
// word state mid-word (this was the cause of "vừa"->"vưà", "lỗi"->"lôĩ" etc:
// the injected replacement text has length > 1, which our own filter
// mis-read as "not Vietnamese" and reacted to with UnikeyResetBuf()).
static const int64_t kSyntheticMarker = 0x556E694B; // 'UniK'

static CFMachPortRef gEventTap = NULL;
static BOOL gVietnameseEnabled = YES;

// Declared early (before the event tap callback below, which needs to call
// -toggleVietnamese: for the Cmd+Shift hotkey) so the compiler knows its
// methods' signatures; @implementation stays further down with the rest of
// the app delegate logic.
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(strong) NSStatusItem *statusItem;
@property(strong) NSWindow *panelWindow;
@property(strong) NSSwitch *vnSwitch;
@property(strong) NSSegmentedControl *methodControl;
@property(strong) NSSwitch *loginItemSwitch;
@property(strong) NSSwitch *showOnLaunchSwitch;
@property(strong) NSMenu *rightClickMenu;
- (void)toggleVietnamese:(id)sender;
@end

static AppDelegate *gAppDelegate = nil;

static bool IsSynthetic(CGEventRef event) {
    return CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kSyntheticMarker;
}

#pragma mark - Cmd+Shift hotkey (toggle Vietnamese on/off)

// Press Cmd+Shift together and release them, with nothing else in between,
// to toggle Vietnamese typing on/off - works even when typing is currently
// off, and works system-wide since it rides the same event tap (unlike an
// NSMenuItem key equivalent, which would only fire while this accessory
// app's own menu happens to be involved).
//
// Modeled as a small state machine over flagsChanged events: "armed" once
// Cmd+Shift are seen down together with nothing else; a real keypress or a
// third modifier while armed "breaks" it, so e.g. Cmd+Shift+Tab or
// Cmd+Shift+4 don't accidentally toggle; everything resets once all
// modifiers are released (regardless of the order the two keys go up in -
// they almost never release in exactly the same instant).
static const CGEventFlags kSwitchHotkeyCombo = kCGEventFlagMaskCommand | kCGEventFlagMaskShift;
static const CGEventFlags kTrackedModifierMask =
    kCGEventFlagMaskCommand | kCGEventFlagMaskShift | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate;

static BOOL gHotkeyArmed = NO;
static BOOL gHotkeyBroken = NO;

static void HandleFlagsChangedForSwitchHotkey(CGEventRef event) {
    CGEventFlags flags = CGEventGetFlags(event) & kTrackedModifierMask;

    if ((flags & ~kSwitchHotkeyCombo) != 0) {
        gHotkeyBroken = YES; // Control/Option joined in - some other shortcut
    }
    if ((flags & kSwitchHotkeyCombo) == kSwitchHotkeyCombo) {
        gHotkeyArmed = YES; // Cmd and Shift are both down right now
    }
    if (flags == 0) {
        if (gHotkeyArmed && !gHotkeyBroken) {
            [gAppDelegate toggleVietnamese:nil];
        }
        gHotkeyArmed = NO;
        gHotkeyBroken = NO;
    }
}

#pragma mark - Chrome/Chromium address-bar autocomplete fix

// Chrome's (and other Chromium browsers') address bar shows its inline
// autocomplete suggestion as *selected* text sitting right after the caret.
// A single Backspace there deletes that whole selection (standard
// "backspace with an active selection" behavior in every text widget) and
// stops, so our own Backspace never reaches the character before the caret:
// typing Telex "o","o" for "ô" only ate the ghost suggestion, leaving the
// real "o" behind, and the fix landed as "o" + "ô" = "oô".
//
// The correct fix is not to dodge the selection but to spend one extra
// Backspace consuming it first: whatever the suggestion's length, a single
// Backspace clears it in one shot (it's a delete-selection, not
// delete-one-char), collapsing to right after our real text - exactly
// where the following Backspace(s) need to land.
//
// This only fires when a selection actually exists, found via the
// Accessibility API (the same permission the event tap already needs) -
// everywhere else (no selection: the overwhelmingly common case) this is a
// no-op check, so normal typing elsewhere is unaffected.
static bool FocusedFieldHasSelection(void) {
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    if (!systemWide) return false;

    CFTypeRef focusedRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute, &focusedRef);
    CFRelease(systemWide);
    if (err != kAXErrorSuccess || !focusedRef) return false;

    AXUIElementRef focused = (AXUIElementRef)focusedRef;
    CFTypeRef rangeValue = NULL;
    err = AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute, &rangeValue);
    CFRelease(focused);
    if (err != kAXErrorSuccess || !rangeValue) return false;

    CFRange range = {0, 0};
    bool ok = AXValueGetValue((AXValueRef)rangeValue, (AXValueType)kAXValueCFRangeType, &range);
    CFRelease(rangeValue);
    return ok && range.length > 0;
}

#pragma mark - Accessibility-based correction (Spotlight fallback attempt)

// TryReplaceViaAccessibility bypasses the normal keystroke path entirely,
// including the FocusedFieldHasSelection fix above - so it must never run
// against a field that can hold an inline autocomplete suggestion (Chrome's
// address bar being the known case). Reading kAXValueAttribute there returns
// the suggestion text glued onto what the user actually typed, and writing
// a "corrected" value back makes Chrome treat that suggestion as real,
// committed user text instead of a live, still-editable suggestion - e.g.
// undoing Telex "w" ("w","w" -> literal "w") landed as the full suggested
// URL instead of "w". Restrict this path to the one app it was actually
// built and verified for.
//
// Deliberately checked via the PID that owns the focused AX element (the
// same element TryReplaceViaAccessibility itself is about to read/write),
// NOT via [NSWorkspace frontmostApplication]: Spotlight's search field is a
// non-activating overlay panel, so invoking it never makes "Spotlight" the
// frontmost application - the app that was active before Cmd+Space stays
// frontmost the whole time. Gating on frontmostApplication therefore never
// matched, silently forcing every Spotlight correction through the
// keystroke path and reintroducing the exact timing bug ("ter" -> "teẻ")
// this function exists to avoid there.
static bool FocusedElementBelongsToSpotlight(void) {
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    if (!systemWide) return false;

    CFTypeRef focusedRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute, &focusedRef);
    CFRelease(systemWide);
    if (err != kAXErrorSuccess || !focusedRef) return false;
    AXUIElementRef focused = (AXUIElementRef)focusedRef;

    pid_t pid = 0;
    AXError pidErr = AXUIElementGetPid(focused, &pid);
    CFRelease(focused);
    if (pidErr != kAXErrorSuccess || pid <= 0) return false;

    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return [app.bundleIdentifier isEqualToString:@"com.apple.Spotlight"];
}

// Last-resort alternative to synthetic keystrokes: read the focused
// field's text directly via Accessibility, edit the string ourselves, and
// write it straight back - no fake Backspace/insert keys at all. Tried
// after diagnostic logging showed the engine computes the right correction
// every time, but no synthetic deletion (real Backspace key, or a Unicode
// Backspace character through the same channel that successfully inserts
// text) ever takes effect in Spotlight's search field specifically -
// suggesting Spotlight deliberately ignores synthetic deletion input.
// This has a real chance of being blocked the same way, but it is a
// genuinely different mechanism, so it's worth one try.
//
// Callers must only reach this when FrontmostAppIsSpotlight() is true (see
// above) - everywhere else, the proven keystroke-based path must be used.
//
// Returns YES if this fully applied the correction (caller must NOT also
// send synthetic keystrokes - that would double-apply it); NO if anything
// about the read-modify-write looked uncertain, so the caller should fall
// back to the proven keystroke-based path used everywhere else.
static BOOL TryReplaceViaAccessibility(int backspaceCount, const unsigned char *utf8, int len) {
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    if (!systemWide) return NO;

    CFTypeRef focusedRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute, &focusedRef);
    CFRelease(systemWide);
    if (err != kAXErrorSuccess || !focusedRef) return NO;
    AXUIElementRef focused = (AXUIElementRef)focusedRef;

    CFTypeRef valueRef = NULL;
    err = AXUIElementCopyAttributeValue(focused, kAXValueAttribute, &valueRef);
    if (err != kAXErrorSuccess || !valueRef || CFGetTypeID(valueRef) != CFStringGetTypeID()) {
        if (valueRef) CFRelease(valueRef);
        CFRelease(focused);
        return NO;
    }
    NSString *currentValue = (__bridge_transfer NSString *)valueRef;

    CFTypeRef rangeRef = NULL;
    err = AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute, &rangeRef);
    CFRange range = {0, 0};
    BOOL haveRange = (err == kAXErrorSuccess && rangeRef != NULL &&
                       AXValueGetValue((AXValueRef)rangeRef, (AXValueType)kAXValueCFRangeType, &range));
    if (rangeRef) CFRelease(rangeRef);
    if (!haveRange) {
        CFRelease(focused);
        return NO;
    }

    // range.location is the caret (or the start of a selection - e.g.
    // Chrome's inline autocomplete ghost text; range.length covers that
    // ghost text). Either way, everything from (caret - backspaceCount) to
    // (caret + range.length) needs to become the replacement text.
    NSInteger caret = range.location;
    if (caret < backspaceCount) {
        CFRelease(focused);
        return NO; // less text before the caret than expected - don't guess
    }

    NSString *replacement = [[NSString alloc] initWithBytes:utf8 length:(NSUInteger)len encoding:NSUTF8StringEncoding];
    if (len > 0 && replacement.length == 0) {
        CFRelease(focused);
        return NO;
    }

    NSUInteger replaceStart = (NSUInteger)(caret - backspaceCount);
    NSUInteger replaceLength = (NSUInteger)backspaceCount + range.length;
    if (replaceStart + replaceLength > currentValue.length) {
        CFRelease(focused);
        return NO; // field's reported value doesn't match what we expect - bail out rather than corrupt it
    }

    NSString *newValue = [currentValue stringByReplacingCharactersInRange:NSMakeRange(replaceStart, replaceLength)
                                                                 withString:replacement];

    err = AXUIElementSetAttributeValue(focused, kAXValueAttribute, (__bridge CFTypeRef)newValue);
    if (err != kAXErrorSuccess) {
        CFRelease(focused);
        return NO;
    }

    CFRange newCaretRange = CFRangeMake((CFIndex)(replaceStart + replacement.length), 0);
    CFTypeRef newRangeValue = AXValueCreate((AXValueType)kAXValueCFRangeType, &newCaretRange);
    if (newRangeValue) {
        AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute, newRangeValue);
        CFRelease(newRangeValue);
    }

    CFRelease(focused);
    return YES;
}

#pragma mark - Synthesizing keystrokes

// A handful of system UI surfaces (Spotlight's search field is the known
// case) seem to drop a synthetic key-down/up pair posted back-to-back with
// zero time between them - as if a press held for ~0 seconds reads as
// spurious/bounce noise and gets filtered out, rather than registering as a
// real backspace. A tiny, human-imperceptible hold time avoids that.
static const useconds_t kSyntheticKeyHoldMicros = 2000;    // down -> up
static const useconds_t kBetweenKeystrokeMicros = 4000;    // one key -> the next

// Send one Backspace the same way PostUnicodeUTF8 sends replacement text:
// as a keycode-0 event carrying a Unicode payload (here, the single
// character U+0008 BACKSPACE) instead of the real Backspace virtual key
// (51). We switched to this after the real-keycode version kept getting
// silently dropped in Spotlight's search field specifically - insertion
// via this "fake key, real Unicode payload" channel was already proven to
// work there (that's how the replacement text itself gets typed), so
// routing the deletion through the same channel sidesteps whatever makes
// Spotlight ignore a synthetic keycode-51 press.
static void PostBackspaceChar(void) {
    UniChar bs = 0x08; // ASCII/Unicode Backspace
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);

    CGEventRef down = CGEventCreateKeyboardEvent(src, 0, true);
    CGEventKeyboardSetUnicodeString(down, 1, &bs);
    CGEventSetIntegerValueField(down, kCGEventSourceUserData, kSyntheticMarker);
    CGEventPost(kCGHIDEventTap, down);
    CFRelease(down);
    usleep(kSyntheticKeyHoldMicros);

    CGEventRef up = CGEventCreateKeyboardEvent(src, 0, false);
    CGEventKeyboardSetUnicodeString(up, 1, &bs);
    CGEventSetIntegerValueField(up, kCGEventSourceUserData, kSyntheticMarker);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(up);

    if (src) CFRelease(src);
}

static void PostBackspaces(int count) {
    for (int i = 0; i < count; i++) {
        PostBackspaceChar();
        if (i + 1 < count) usleep(kBetweenKeystrokeMicros);
    }
}

// Insert an arbitrary UTF-8 string by posting a "keystroke" whose virtual
// key is 0 but whose Unicode payload is overridden - the standard macOS
// technique for typing text that has no physical key (accented letters,
// multi-char replacements, etc).
static void PostUnicodeUTF8(const unsigned char *utf8, int len) {
    if (len <= 0) return;
    NSString *s = [[NSString alloc] initWithBytes:utf8 length:(NSUInteger)len encoding:NSUTF8StringEncoding];
    if (s.length == 0) return;

    NSUInteger ulen = s.length;
    UniChar *buf = (UniChar *)malloc(sizeof(UniChar) * ulen);
    [s getCharacters:buf range:NSMakeRange(0, ulen)];

    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CGEventRef down = CGEventCreateKeyboardEvent(src, 0, true);
    CGEventKeyboardSetUnicodeString(down, ulen, buf);
    CGEventSetIntegerValueField(down, kCGEventSourceUserData, kSyntheticMarker);
    CGEventPost(kCGHIDEventTap, down);
    CFRelease(down);
    usleep(kSyntheticKeyHoldMicros);

    CGEventRef up = CGEventCreateKeyboardEvent(src, 0, false);
    CGEventKeyboardSetUnicodeString(up, ulen, buf);
    CGEventSetIntegerValueField(up, kCGEventSourceUserData, kSyntheticMarker);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(up);

    if (src) CFRelease(src);
    free(buf);
}

#pragma mark - Event tap callback

static CGEventRef EventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        // macOS disables a tap that is too slow or after "Input Monitoring"
        // is toggled - just turn it back on.
        if (gEventTap) CGEventTapEnable(gEventTap, true);
        return event;
    }

    if (IsSynthetic(event)) {
        return event; // one of our own injected events looping back - ignore
    }

    if (type == kCGEventFlagsChanged) {
        HandleFlagsChangedForSwitchHotkey(event);
        return event;
    }

    if (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown || type == kCGEventOtherMouseDown) {
        // A click almost always moves the caret/selection to wherever was
        // clicked - possibly a totally different text field (classic case:
        // click Chrome's address bar, then click back into the page).
        // Keyboard-driven focus changes already reset the buffer (Cmd/Ctrl
        // shortcuts below; Tab/Enter/other control characters are
        // classified ukcReset by the engine itself and call reset()), but a
        // mouse click produces no key event at all - without this, the
        // engine kept building on whatever word it was mid-typing in the
        // PREVIOUS field. E.g. typing something non-Vietnamese in the
        // address bar leaves the buffer in a "not Vietnamese" state; that
        // state doesn't clear on its own, so it silently carried over and
        // blocked every diacritic in the next field clicked into, until
        // enough real Backspaces walked the buffer back to empty.
        UnikeyResetBuf();
        return event;
    }

    if (type == kCGEventKeyDown && gHotkeyArmed) {
        gHotkeyBroken = YES; // a real keypress while Cmd+Shift are held: not our hotkey
    }

    if (!gVietnameseEnabled || type != kCGEventKeyDown) {
        return event;
    }

    CGEventFlags flags = CGEventGetFlags(event);
    CGKeyCode keycode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);

    // Backspace: let the engine know a character was deleted so its
    // internal word buffer stays in sync, then let the real key through.
    if (keycode == kBackspaceKeyCode) {
        UnikeyBackspacePress();
        return event;
    }

    // Cmd / Ctrl combos are shortcuts (Cmd+C, Ctrl+A...), never Vietnamese
    // text - reset the engine's word buffer and let them pass untouched.
    if (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl)) {
        UnikeyResetBuf();
        return event;
    }

    BOOL shiftDown = (flags & kCGEventFlagMaskShift) != 0;
    BOOL capsOn    = (flags & kCGEventFlagMaskAlphaShift) != 0;
    UnikeySetCapsState(shiftDown, capsOn);

    UniChar chars[4];
    UniCharCount actualLen = 0;
    CGEventKeyboardGetUnicodeString(event, 4, &actualLen, chars);

    // Arrows, Home/End, function keys, etc. produce no Unicode text -
    // treat them as "leaving the word", same as the original X11 code does.
    if (actualLen != 1 || chars[0] > 127) {
        UnikeyResetBuf();
        return event;
    }

    UnikeyFilter((unsigned int)chars[0]);

#if UNIKEYAI_DEBUG_LOG
    NSLog(@"[UnikeyAI][dbg] key='%c' (0x%02x) -> backspaces=%d bufChars=%d buf=\"%.*s\"",
          (char)chars[0], chars[0], UnikeyBackspaces, UnikeyBufChars,
          UnikeyBufChars, (const char *)UnikeyBuf);
#endif

    if (UnikeyBackspaces > 0 || UnikeyBufChars > 0) {
        // Only Spotlight needs (and was verified against) the direct
        // Accessibility read-modify-write below - everywhere else, most
        // notably Chrome's address bar, it must be skipped so the proven
        // keystroke path (with its own inline-autocomplete fix) runs instead.
        BOOL handledViaAX = FocusedElementBelongsToSpotlight() &&
            TryReplaceViaAccessibility(UnikeyBackspaces, UnikeyBuf, UnikeyBufChars);
#if UNIKEYAI_DEBUG_LOG
        NSLog(@"[UnikeyAI][dbg] TryReplaceViaAccessibility -> %@", handledViaAX ? @"YES (handled)" : @"NO (falling back to keystrokes)");
#endif
        if (!handledViaAX) {
            int backspaceCount = UnikeyBackspaces;
            if (backspaceCount > 0 && FocusedFieldHasSelection()) {
                backspaceCount += 1; // one extra Backspace to consume the inline suggestion (see above)
            }
            PostBackspaces(backspaceCount);
            // Some system UI (Spotlight's search field is the known case: it
            // re-runs a live search on every keystroke) can be slow enough
            // processing the Backspace that our very next event - the
            // replacement text - arrives before the deletion actually took
            // effect, so the old letter is left behind and the new one just
            // gets appended next to it ("ter" -> "teẻ" instead of "tẻ"). A
            // short pause here gives it time to catch up; imperceptible to a
            // human typist, and this code path only runs once per syllable
            // correction, not on every keystroke.
            usleep(kBetweenKeystrokeMicros);
            PostUnicodeUTF8(UnikeyBuf, UnikeyBufChars);
        }
        return NULL; // we replaced this keystroke ourselves; swallow the original
    }

    return event; // engine made no change - let the original key through
}

#pragma mark - App delegate / menu bar / control panel

static UkInputMethod gCurrentIM = UkTelex;
static NSString *const kLoginItemDefaultsInitializedKey = @"UnikeyAI.loginItemInitialized";
static NSString *const kShowPanelOnLaunchDefaultsKey = @"UnikeyAI.showPanelOnLaunch";

// (see the full @interface, declared early, near the top of this file)

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    gAppDelegate = self;

    NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};
    Boolean trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    if (!trusted) {
        NSLog(@"[UnikeyAI] Accessibility permission not granted yet. Enable it in "
              @"System Settings > Privacy & Security > Accessibility (and Input Monitoring), "
              @"then relaunch this app.");
    }

    UnikeySetup();
    UnikeySetInputMethod(UkTelex);

    // Default to "launch at login" ON, but only decide that once - after
    // that the switch in the panel is the only thing that changes it, even
    // if SMAppService reports it got disabled some other way (e.g. the user
    // removed it from System Settings > General > Login Items directly).
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:kLoginItemDefaultsInitializedKey]) {
        [defaults setBool:YES forKey:kLoginItemDefaultsInitializedKey];
        [self setLoginItemEnabled:YES];
    }
    // "Show the control panel on launch" defaults to checked (YES) for
    // anyone who never touched the setting - registerDefaults: only
    // supplies a fallback, it never overwrites a value the user picked.
    [defaults registerDefaults:@{kShowPanelOnLaunchDefaultsKey : @YES}];

    // Mouse-down events are watched too (though never modified/blocked -
    // see the early check in EventTapCallback) purely so a click can reset
    // the engine's word buffer: see the comment there for why this matters.
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventFlagsChanged) |
        CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventOtherMouseDown);
    gEventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                  kCGEventTapOptionDefault, mask,
                                  EventTapCallback, NULL);
    if (!gEventTap) {
        NSLog(@"[UnikeyAI] Failed to create event tap - check Accessibility / Input "
              @"Monitoring permission in System Settings, then relaunch.");
    } else {
        CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gEventTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, kCFRunLoopCommonModes);
        CFRelease(runLoopSource);
        CGEventTapEnable(gEventTap, true);
    }

    [self setupStatusItem];

    // Show the control panel on launch (unless the user turned that off in
    // the panel itself). The app has no Dock icon (menu-bar-only), so by
    // default this is the only obvious sign it's running at all - easy to
    // miss otherwise, which is exactly what happened during testing.
    if ([defaults boolForKey:kShowPanelOnLaunchDefaultsKey]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self togglePanel:nil];
        });
    }
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePanel:);
    [self updateStatusItemAppearance];

    NSMenu *menu = [[NSMenu alloc] init];

    NSMenuItem *panelItem = [[NSMenuItem alloc] initWithTitle:@"Bảng điều khiển..."
                                                        action:@selector(togglePanel:)
                                                 keyEquivalent:@""];
    panelItem.target = self;
    [menu addItem:panelItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *toggle = [[NSMenuItem alloc] initWithTitle:@"Bật/Tắt gõ tiếng Việt (⌘⇧)"
                                                     action:@selector(toggleVietnamese:)
                                              keyEquivalent:@""];
    toggle.target = self;
    [menu addItem:toggle];

    NSMenuItem *telex = [[NSMenuItem alloc] initWithTitle:@"Kiểu gõ Telex"
                                                    action:@selector(chooseTelex:)
                                             keyEquivalent:@""];
    telex.target = self;
    [menu addItem:telex];

    NSMenuItem *vni = [[NSMenuItem alloc] initWithTitle:@"Kiểu gõ VNI"
                                                  action:@selector(chooseVni:)
                                           keyEquivalent:@""];
    vni.target = self;
    [menu addItem:vni];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Thoát"
                                                   action:@selector(terminate:)
                                            keyEquivalent:@"q"];
    quit.target = self;
    [menu addItem:quit];

    // Left click shows the control panel (togglePanel:); right click / Ctrl-click
    // pops up this menu instead (see togglePanel: below, which inspects the
    // triggering event to tell the two apart).
    self.statusItem.menu = nil;
    [self.statusItem.button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];
    self.rightClickMenu = menu;
}

#pragma mark Launch at login

// SMAppService (macOS 13+) registers/unregisters this same .app as a login
// item - no separate helper-app bundle needed, unlike the older
// SMLoginItemSetEnabled API it replaces.
- (BOOL)isLoginItemEnabled {
    if (@available(macOS 13.0, *)) {
        return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    }
    return NO;
}

- (void)setLoginItemEnabled:(BOOL)enabled {
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        BOOL ok = enabled ? [SMAppService.mainAppService registerAndReturnError:&error]
                           : [SMAppService.mainAppService unregisterAndReturnError:&error];
        if (!ok) {
            NSLog(@"[UnikeyAI] Could not %@ as a login item: %@", enabled ? @"register" : @"unregister", error);
        }
    }
}

- (void)loginItemToggled:(id)sender {
    [self setLoginItemEnabled:(self.loginItemSwitch.state == NSControlStateValueOn)];
}

- (void)showOnLaunchToggled:(id)sender {
    BOOL enabled = (self.showOnLaunchSwitch.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kShowPanelOnLaunchDefaultsKey];
}

#pragma mark Control panel window

// A small helper to keep the section-caption style (bold, small, secondary
// color, uppercase) consistent without repeating four lines per label.
static NSTextField *MakeSectionCaption(NSString *text, NSRect frameRect) {
    NSTextField *label = [NSTextField labelWithString:[text uppercaseString]];
    label.frame = frameRect;
    label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

static NSBox *MakeDivider(NSRect frameRect) {
    NSBox *box = [[NSBox alloc] initWithFrame:frameRect];
    box.boxType = NSBoxSeparator;
    return box;
}

- (void)buildPanelIfNeeded {
    if (self.panelWindow) return;

    NSRect frame = NSMakeRect(0, 0, 300, 420);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                 styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    win.title = @"UnikeyAI";
    win.titleVisibility = NSWindowTitleHidden; // the header row below shows the name instead
    win.titlebarAppearsTransparent = YES;
    win.level = NSFloatingWindowLevel;
    win.releasedWhenClosed = NO;

    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:frame];
    background.material = NSVisualEffectMaterialPopover;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.state = NSVisualEffectStateActive;
    win.contentView = background;
    NSView *content = background;

    // --- Header: app icon + name + version ---------------------------------
    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(20, 364, 36, 36)];
    iconView.image = [NSApp applicationIconImage];
    [content addSubview:iconView];

    NSTextField *titleLabel = [NSTextField labelWithString:@"UnikeyAI"];
    titleLabel.frame = NSMakeRect(64, 380, 200, 20);
    titleLabel.font = [NSFont systemFontOfSize:16 weight:NSFontWeightBold];
    [content addSubview:titleLabel];

    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSTextField *versionLabel = [NSTextField labelWithString:
        [NSString stringWithFormat:@"v%@ · Bộ gõ tiếng Việt", version ?: @"0.1"]];
    versionLabel.frame = NSMakeRect(64, 362, 220, 16);
    versionLabel.font = [NSFont systemFontOfSize:11];
    versionLabel.textColor = [NSColor secondaryLabelColor];
    [content addSubview:versionLabel];

    [content addSubview:MakeDivider(NSMakeRect(20, 348, 260, 1))];

    // --- Section: Bộ gõ ------------------------------------------------------
    [content addSubview:MakeSectionCaption(@"Bộ gõ", NSMakeRect(20, 324, 200, 16))];

    NSTextField *vnLabel = [NSTextField labelWithString:@"Gõ tiếng Việt"];
    vnLabel.frame = NSMakeRect(20, 292, 180, 20);
    [content addSubview:vnLabel];

    self.vnSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(240, 290, 40, 24)];
    self.vnSwitch.target = self;
    self.vnSwitch.action = @selector(switchToggled:);
    self.vnSwitch.state = gVietnameseEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [content addSubview:self.vnSwitch];

    NSTextField *imLabel = [NSTextField labelWithString:@"Kiểu gõ"];
    imLabel.frame = NSMakeRect(20, 256, 140, 20);
    [content addSubview:imLabel];

    self.methodControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(180, 253, 100, 28)];
    self.methodControl.segmentCount = 2;
    [self.methodControl setLabel:@"Telex" forSegment:0];
    [self.methodControl setLabel:@"VNI" forSegment:1];
    self.methodControl.selectedSegment = (gCurrentIM == UkVni) ? 1 : 0;
    self.methodControl.target = self;
    self.methodControl.action = @selector(methodChanged:);
    [content addSubview:self.methodControl];

    NSTextField *hintLabel = [NSTextField labelWithString:@"Phím tắt bật/tắt: ⌘⇧ (Cmd+Shift)"];
    hintLabel.frame = NSMakeRect(20, 228, 260, 16);
    hintLabel.font = [NSFont systemFontOfSize:11];
    hintLabel.textColor = [NSColor secondaryLabelColor];
    [content addSubview:hintLabel];

    [content addSubview:MakeDivider(NSMakeRect(20, 212, 260, 1))];

    // --- Section: Hệ thống ---------------------------------------------------
    [content addSubview:MakeSectionCaption(@"Hệ thống", NSMakeRect(20, 188, 200, 16))];

    NSTextField *loginLabel = [NSTextField labelWithString:@"Khởi động cùng macOS"];
    loginLabel.frame = NSMakeRect(20, 156, 200, 20);
    [content addSubview:loginLabel];

    self.loginItemSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(240, 154, 40, 24)];
    self.loginItemSwitch.target = self;
    self.loginItemSwitch.action = @selector(loginItemToggled:);
    self.loginItemSwitch.state = [self isLoginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    [content addSubview:self.loginItemSwitch];

    NSTextField *showOnLaunchLabel = [NSTextField labelWithString:@"Hiện bảng này khi khởi động"];
    showOnLaunchLabel.frame = NSMakeRect(20, 120, 200, 20);
    [content addSubview:showOnLaunchLabel];

    self.showOnLaunchSwitch = [[NSSwitch alloc] initWithFrame:NSMakeRect(240, 118, 40, 24)];
    self.showOnLaunchSwitch.target = self;
    self.showOnLaunchSwitch.action = @selector(showOnLaunchToggled:);
    self.showOnLaunchSwitch.state = [[NSUserDefaults standardUserDefaults] boolForKey:kShowPanelOnLaunchDefaultsKey]
        ? NSControlStateValueOn : NSControlStateValueOff;
    [content addSubview:self.showOnLaunchSwitch];

    // --- Actions --------------------------------------------------------------
    NSButton *hideButton = [NSButton buttonWithTitle:@"Ẩn giao diện"
                                               target:self
                                               action:@selector(hidePanel:)];
    hideButton.frame = NSMakeRect(20, 56, 260, 28);
    hideButton.bezelStyle = NSBezelStyleRounded;
    hideButton.keyEquivalent = @"\r"; // Return, since this is the safe/expected default action
    [content addSubview:hideButton];

    NSButton *quitButton = [NSButton buttonWithTitle:@"Thoát ứng dụng"
                                               target:self
                                               action:@selector(terminate:)];
    quitButton.frame = NSMakeRect(20, 18, 260, 28);
    quitButton.bezelStyle = NSBezelStyleRounded;
    [content addSubview:quitButton];

    self.panelWindow = win;
}

- (void)togglePanel:(id)sender {
    NSEvent *currentEvent = [NSApp currentEvent];
    if (currentEvent.type == NSEventTypeRightMouseUp ||
        (currentEvent.type == NSEventTypeLeftMouseUp && (currentEvent.modifierFlags & NSEventModifierFlagControl))) {
        [self.rightClickMenu popUpMenuPositioningItem:nil atLocation:NSZeroPoint inView:self.statusItem.button];
        return;
    }

    [self buildPanelIfNeeded];

    if (self.panelWindow.isVisible) {
        [self.panelWindow orderOut:nil];
        return;
    }

    self.vnSwitch.state = gVietnameseEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.methodControl.selectedSegment = (gCurrentIM == UkVni) ? 1 : 0;
    self.loginItemSwitch.state = [self isLoginItemEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    self.showOnLaunchSwitch.state = [[NSUserDefaults standardUserDefaults] boolForKey:kShowPanelOnLaunchDefaultsKey]
        ? NSControlStateValueOn : NSControlStateValueOff;

    NSWindow *statusWindow = self.statusItem.button.window;
    NSRect buttonFrameInScreen = [statusWindow convertRectToScreen:self.statusItem.button.frame];
    NSPoint origin = NSMakePoint(NSMaxX(buttonFrameInScreen) - self.panelWindow.frame.size.width,
                                  NSMinY(buttonFrameInScreen) - self.panelWindow.frame.size.height - 4);
    [self.panelWindow setFrameOrigin:origin];

    [self.panelWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// Single bold letter ("V"/"E") reads far better in a crowded menu bar than
// "VN"/"EN" did, and matches the convention long-time Unikey/OpenKey users
// already recognize. The tooltip spells the state out in full.
- (void)updateStatusItemAppearance {
    NSString *letter = gVietnameseEnabled ? @"V" : @"E";
    NSFont *font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightBold];
    NSDictionary *attrs = @{NSFontAttributeName : font};
    self.statusItem.button.attributedTitle = [[NSAttributedString alloc] initWithString:letter attributes:attrs];

    NSString *methodName = (gCurrentIM == UkVni) ? @"VNI" : @"Telex";
    self.statusItem.button.toolTip = gVietnameseEnabled
        ? [NSString stringWithFormat:@"UnikeyAI: đang gõ tiếng Việt (%@)", methodName]
        : @"UnikeyAI: đang tắt, gõ tiếng Anh bình thường";
}

- (void)hidePanel:(id)sender {
    [self.panelWindow orderOut:nil];
}

- (void)switchToggled:(id)sender {
    gVietnameseEnabled = (self.vnSwitch.state == NSControlStateValueOn);
    UnikeyResetBuf();
    [self updateStatusItemAppearance];
}

- (void)methodChanged:(id)sender {
    if (self.methodControl.selectedSegment == 1) {
        [self chooseVni:sender];
    } else {
        [self chooseTelex:sender];
    }
}

- (void)toggleVietnamese:(id)sender {
    gVietnameseEnabled = !gVietnameseEnabled;
    UnikeyResetBuf();
    self.vnSwitch.state = gVietnameseEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateStatusItemAppearance];
}

- (void)chooseTelex:(id)sender {
    UnikeySetInputMethod(UkTelex);
    gCurrentIM = UkTelex;
    UnikeyResetBuf();
    [self updateStatusItemAppearance];
}

- (void)chooseVni:(id)sender {
    UnikeySetInputMethod(UkVni);
    gCurrentIM = UkVni;
    UnikeyResetBuf();
    [self updateStatusItemAppearance];
}

- (void)terminate:(id)sender {
    [NSApp terminate:nil];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; // menu-bar only, no Dock icon
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
