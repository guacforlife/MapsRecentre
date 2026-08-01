// MapsRecentre — re-enable Google Maps' own auto-recentre during navigation.
//
// Google Maps already implements this feature end to end; it is simply gated
// off by a server-side client parameter. `-[AZNavGuidanceViewController
// initWithRouteState:directionsSearch:directionsResponse:options:services:]`
// reads `-[GMMCPNavigation2Parameters autoRecenterInactivityDelaySeconds]`
// once, when the navigation UI is built, and seeds its own
// `autoRecenterInactivityTimer` with it. On this account the server sends 0,
// which disables the timer.
//
// So the core of the tweak is: return a non-zero delay from that one getter.
// The app's own `startAutoRecenterTimer` / `handleAutoRecenterTimeout` /
// `recenterMap` chain then does the work, which means the camera animation,
// the Re-center button state and the analytics all behave natively — nothing
// is synthesised.
//
// The rest of this file is the in-app settings control: a gear button in the
// map's floating-button column, directly above the compass.
//
// NOTE: the delay is read once per navigation session, at nav-UI construction.
// A change takes effect on the NEXT navigation, not the current one.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>

static const int kDefaultDelaySeconds = 5;
static const int kDefaultAutoStartDelay = 5;
static const NSTimeInterval kExternalOpenWindow = 60.0;  // how long an external open counts as "this trip"
static const NSInteger kSettingsButtonTag = 0x4D52;      // 'MR'
static const CGFloat kColumnGap = 16.0;                  // observed FAB column pitch is 56 + 16

// Google Maps is sandboxed, so the log lands in the app container's tmp:
//   sudo cat /rootfs/private/var/mobile/Containers/Data/Application/<UUID>/tmp/.mapsrecentre.log
static void mrLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@".mapsrecentre.log"];
    NSString *line = [NSString stringWithFormat:@"%@: %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

#pragma mark - Config

// Where the config lives, and why it is not NSUserDefaults.
//
// A shared NSUserDefaults suite does NOT work: Google Maps is a sandboxed
// third-party app and cannot see `defaults write com.guacforlife.mapsrecentre` at all
// (verified on-device: the write succeeded, the tweak still read "no stored
// value").
//
// Two file paths are usable, and their roles are decided by what the app is
// allowed to do with each (both verified from inside the Google Maps sandbox):
//
//   container  READ + WRITE  -> authoritative, and what the in-app UI writes
//   jbroot     READ only     -> fallback seed, e.g. pushed from the Mac
//
// Container wins, so a value chosen in the app is never shadowed by a stale
// jbroot file.

static NSString *mrContainerConfigPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Preferences/com.guacforlife.mapsrecentre.plist"];
}

static NSString *mrJbrootConfigPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((const void *)&mrJbrootConfigPath, &info) && info.dli_fname) {
            NSString *p = @(info.dli_fname);
            NSRange marker = [p rangeOfString:@".jbroot-"];
            if (marker.location != NSNotFound) {
                NSRange tail = NSMakeRange(NSMaxRange(marker), p.length - NSMaxRange(marker));
                NSRange slash = [p rangeOfString:@"/" options:0 range:tail];
                if (slash.location != NSNotFound) {
                    path = [[p substringToIndex:slash.location] stringByAppendingPathComponent:
                            @"var/mobile/Library/Preferences/com.guacforlife.mapsrecentre.plist"];
                }
            }
        }
    });
    return path;
}

// Delay in seconds, or <= 0 to leave Google's value alone.
//
// Read fresh every time rather than cached: the getter fires once per navigation
// session, so an edited delay applies to the next navigation instead of needing
// a force-quit of Google Maps. One small plist read per navigation is free.
static int mrConfigInt(NSString *key, int fallback) {
    @try {
        NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:mrContainerConfigPath()];
        NSString *jbroot = mrJbrootConfigPath();
        if (jbroot) [paths addObject:jbroot];

        for (NSString *path in paths) {
            NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:path];
            id v = cfg[key];
            if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v intValue];
        }
    } @catch (id e) {
        mrLog(@"config: read of %@ failed (%@)", key, e);
    }
    return fallback;
}

// Only the container path is writable from inside the sandbox — the jbroot path
// is read-only here, verified on-device.
static BOOL mrSetConfigInt(NSString *key, int value) {
    @try {
        NSString *path = mrContainerConfigPath();
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
        cfg[key] = @(value);
        BOOL ok = [cfg writeToFile:path atomically:YES];
        mrLog(@"config: wrote %@=%d -> %@", key, value, ok ? @"ok" : @"FAILED");
        return ok;
    } @catch (id e) {
        mrLog(@"config: write failed (%@)", e);
        return NO;
    }
}

static NSString *mrConfigString(NSString *key, NSString *fallback) {
    @try {
        NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:mrContainerConfigPath()];
        NSString *jbroot = mrJbrootConfigPath();
        if (jbroot) [paths addObject:jbroot];
        for (NSString *path in paths) {
            NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:path];
            id v = cfg[key];
            if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
        }
    } @catch (id e) {}
    return fallback;
}

static BOOL mrSetConfigString(NSString *key, NSString *value) {
    @try {
        NSString *path = mrContainerConfigPath();
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
        if (value) cfg[key] = value; else [cfg removeObjectForKey:key];
        BOOL ok = [cfg writeToFile:path atomically:YES];
        mrLog(@"config: wrote %@=%@ -> %@", key, value ?: @"(cleared)", ok ? @"ok" : @"FAILED");
        return ok;
    } @catch (id e) {
        mrLog(@"config: write failed (%@)", e);
        return NO;
    }
}

static int mrDelaySeconds(void) { return mrConfigInt(@"delaySeconds", kDefaultDelaySeconds); }
static BOOL mrSetDelaySeconds(int d) { return mrSetConfigInt(@"delaySeconds", d); }

// Auto-Start: press the Start button on a directions preview automatically.
typedef NS_ENUM(int, MRAutoStartMode) {
    MRAutoStartOff = 0,
    MRAutoStartExternal = 1,   // only when the directions arrived from outside the app
    MRAutoStartAlways = 2,
};
static int mrAutoStartMode(void) { return mrConfigInt(@"autoStartMode", MRAutoStartExternal); }
static int mrAutoStartDelay(void) { return mrConfigInt(@"autoStartDelaySeconds", kDefaultAutoStartDelay); }
static BOOL mrAnnounceEnabled(void) { return mrConfigInt(@"announceDestination", 1) != 0; }

#pragma mark - Auto-Start

// Pressing Start automatically on a directions preview.
//
// Flow, captured on-device from a real Siri request:
//   Siri -> -[AZExternalURLController openURL:sourceApplication:]
//           with comgooglemaps://?directionsmode=driving&daddr=...
//        -> AZTripDetailsPageContentProvider / AZMotorableTripDetailsPresenter init
//        -> -[AZMotorableTripDetailsPresenter startUIUpdates]   (preview on screen)
//        -> user taps Start
//        -> -[AZMotorableTripDetailsPresenter didTapStartNavigationChip]
//
// So we note external opens, arm a timer when the preview starts, and then call
// the Start chip's own action. Same principle as the recentre hook: drive
// Google's real code path rather than synthesising a touch.

@interface AZPlacemark : NSObject
- (NSString *)listingName;
- (NSString *)computedAddressString;
@end

@interface RouteState : NSObject
- (NSArray *)remainingWaypoints;
@end

@interface AZMotorableTripDetailsPresenter : NSObject
- (RouteState *)routeState;
- (void)didTapStartNavigationChip;
@end

static NSDate *gExternalOpenAt = nil;
static NSString *gExternalSource = nil;
static NSUInteger gAutoStartGeneration = 0;

static BOOL mrExternalOpenIsFresh(void) {
    if (!gExternalOpenAt) return NO;
    return [[NSDate date] timeIntervalSinceDate:gExternalOpenAt] < kExternalOpenWindow;
}

static NSString *mrDestinationName(AZMotorableTripDetailsPresenter *presenter) {
    @try {
        RouteState *rs = [presenter routeState];
        NSArray *wps = [rs remainingWaypoints];
        id wp = wps.lastObject;
        if (![wp respondsToSelector:@selector(listingName)]) return nil;
        NSString *name = [wp listingName];
        if (name.length) return name;
        if ([wp respondsToSelector:@selector(computedAddressString)]) return [wp computedAddressString];
    } @catch (id e) {
        mrLog(@"destination lookup failed (%@)", e);
    }
    return nil;
}

// Voice selection.
//
// Google's own navigation voice is NOT reachable here. It runs through
// GMSVoiceGuidance, a network-TTS pipeline that only exists while a navigation
// session is live, and the announcement happens before navigation starts by
// definition. Using it would force the announcement to come after Start, which
// is the collision we are trying to remove.
//
// So this is Apple TTS, but chosen well: prefer the highest-quality voice
// available for the device's language, preferring female. Quality depends on
// what the user has downloaded under
// Settings > Accessibility > Spoken Content > Voices — an Enhanced or Premium
// voice sounds dramatically better than the default and is the real lever here.
static AVSpeechSynthesisVoice *mrPickVoice(void) {
    @try {
        NSString *stored = mrConfigString(@"voiceIdentifier", nil);
        if (stored.length) {
            AVSpeechSynthesisVoice *v = [AVSpeechSynthesisVoice voiceWithIdentifier:stored];
            if (v) return v;
        }

        NSString *lang = [AVSpeechSynthesisVoice currentLanguageCode];
        NSString *prefix = [lang componentsSeparatedByString:@"-"].firstObject;
        AVSpeechSynthesisVoice *best = nil;
        NSInteger bestScore = -1;
        for (AVSpeechSynthesisVoice *v in [AVSpeechSynthesisVoice speechVoices]) {
            if (![v.language hasPrefix:prefix]) continue;
            NSInteger score = 0;
            if ([v.language isEqualToString:lang]) score += 8;       // exact locale
            if (v.gender == AVSpeechSynthesisVoiceGenderFemale) score += 4;
            score += v.quality * 1;                                  // default < enhanced < premium
            if (score > bestScore) { bestScore = score; best = v; }
        }
        return best ?: [AVSpeechSynthesisVoice voiceWithLanguage:lang];
    } @catch (id e) {
        mrLog(@"voice pick failed (%@)", e);
        return nil;
    }
}

@interface MRSpeechDelegate : NSObject <AVSpeechSynthesizerDelegate>
@property (nonatomic, copy) void (^onDone)(void);
@end

@implementation MRSpeechDelegate
- (void)mrFinish {
    void (^b)(void) = self.onDone;
    self.onDone = nil;
    if (b) b();
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u { [self mrFinish]; }
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u { [self mrFinish]; }
@end

// Speaks, then calls `completion` once the utterance has actually finished.
//
// Sequencing matters: firing the announcement and Start together makes our voice
// collide with Google's first turn instruction. Waiting for the utterance means
// the two queue naturally. A watchdog fires the completion anyway if speech
// stalls, so a TTS problem can never strand the auto-start.
static void mrAnnounce(NSString *destination, void (^completion)(void)) {
    if (!mrAnnounceEnabled()) { if (completion) completion(); return; }

    static AVSpeechSynthesizer *synth = nil;
    static MRSpeechDelegate *delegate = nil;
    __block BOOL done = NO;
    void (^finish)(void) = ^{
        if (done) return;
        done = YES;
        @try {
            [[AVAudioSession sharedInstance] setActive:NO
                withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        } @catch (id e) {}
        if (completion) completion();
    };

    @try {
        NSString *text = destination.length
            ? [NSString stringWithFormat:@"Starting route to %@", destination]
            : @"Starting route";

        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback
                        mode:AVAudioSessionModeVoicePrompt
                     options:AVAudioSessionCategoryOptionDuckOthers
                       error:nil];
        [session setActive:YES error:nil];

        if (!synth) synth = [[AVSpeechSynthesizer alloc] init];
        if (!delegate) delegate = [MRSpeechDelegate new];
        delegate.onDone = finish;
        synth.delegate = delegate;

        AVSpeechUtterance *utt = [AVSpeechUtterance speechUtteranceWithString:text];
        AVSpeechSynthesisVoice *voice = mrPickVoice();
        if (voice) utt.voice = voice;
        [synth speakUtterance:utt];
        NSString *quality = voice.quality == AVSpeechSynthesisVoiceQualityDefault ? @"Default"
                          : (voice.quality == AVSpeechSynthesisVoiceQualityEnhanced ? @"Enhanced" : @"Premium");
        mrLog(@"announcing \"%@\" as %@ (%@, %@)", text,
              voice.name ?: @"default voice", voice.language ?: @"?", quality);

        // Watchdog: never let a stalled utterance block the start.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!done) mrLog(@"announce: watchdog fired, starting anyway");
            finish();
        });
    } @catch (id e) {
        mrLog(@"announce failed (%@)", e);
        finish();
    }
}

static void mrMaybeArmAutoStart(AZMotorableTripDetailsPresenter *presenter) {
    @try {
        int mode = mrAutoStartMode();
        if (mode == MRAutoStartOff) return;
        if (mode == MRAutoStartExternal && !mrExternalOpenIsFresh()) {
            mrLog(@"auto-start: skipped, preview was not externally initiated");
            return;
        }

        int delay = mrAutoStartDelay();
        if (delay < 0) delay = 0;
        NSUInteger generation = ++gAutoStartGeneration;
        NSString *destination = mrDestinationName(presenter);
        mrLog(@"auto-start: armed for %ds (mode=%d source=%@ destination=%@)",
              delay, mode, gExternalSource ?: @"-", destination ?: @"?");

        // Weak, so a preview the user dismisses cannot be started after the fact.
        __weak AZMotorableTripDetailsPresenter *weakPresenter = presenter;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                AZMotorableTripDetailsPresenter *p = weakPresenter;
                if (!p) { mrLog(@"auto-start: cancelled, preview went away"); return; }
                if (generation != gAutoStartGeneration) { mrLog(@"auto-start: superseded"); return; }
                if (![p respondsToSelector:@selector(didTapStartNavigationChip)]) {
                    mrLog(@"auto-start: presenter has no start action");
                    return;
                }
                // Announce first, start only once the utterance has finished, so
                // our voice does not talk over Google's first instruction.
                __weak AZMotorableTripDetailsPresenter *stillWeak = p;
                mrAnnounce(destination, ^{
                    @try {
                        AZMotorableTripDetailsPresenter *sp = stillWeak;
                        if (!sp) { mrLog(@"auto-start: preview went away during announcement"); return; }
                        if (generation != gAutoStartGeneration) { mrLog(@"auto-start: superseded during announcement"); return; }
                        mrLog(@"auto-start: firing didTapStartNavigationChip");
                        [sp didTapStartNavigationChip];
                    } @catch (id e) {
                        mrLog(@"auto-start: fire failed (%@)", e);
                    }
                });
            } @catch (id e) {
                mrLog(@"auto-start: fire failed (%@)", e);
            }
        });
    } @catch (id e) {
        mrLog(@"auto-start: arm failed (%@)", e);
    }
}

#pragma mark - Settings UI

static NSString *mrLabelForDelay(int d) {
    if (d <= 0) return @"Off";
    return [NSString stringWithFormat:@"%d seconds", d];
}

// Topmost presented view controller, so the sheet is not swallowed by whatever
// Google Maps already has on screen.
static UIViewController *mrTopViewController(UIView *anchor) {
    UIViewController *vc = anchor.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void mrPresent(UIAlertController *sheet, UIView *sender) {
    UIViewController *host = mrTopViewController(sender);
    if (!host) { mrLog(@"settings: no host view controller"); return; }
    // Harmless on iPhone, required on iPad.
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [host presentViewController:sheet animated:YES completion:nil];
}

// Private KVC, stable on iOS 13-16 action sheets. Guarded because an uncaught
// NSUnknownKeyException here would abort the app.
static void mrMarkChecked(UIAlertAction *action) {
    @try { [action setValue:@YES forKey:@"checked"]; } @catch (id e) {}
}

static void mrShowChoiceSheet(UIView *sender, NSString *title, NSString *message,
                              NSArray<NSNumber *> *values, NSString *(^label)(int),
                              int current, void (^apply)(int)) {
    @try {
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                      message:message
                                                               preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSNumber *v in values) {
            int value = [v intValue];
            UIAlertAction *a = [UIAlertAction actionWithTitle:label(value)
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction *x) { apply(value); }];
            if (value == current) mrMarkChecked(a);
            [sheet addAction:a];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel handler:nil]];
        mrPresent(sheet, sender);
    } @catch (id e) {
        mrLog(@"settings: choice sheet failed (%@)", e);
    }
}

static NSString *mrAutoStartModeLabel(int mode) {
    switch (mode) {
        case MRAutoStartOff:      return @"Off";
        case MRAutoStartExternal: return @"Siri and links only";
        default:                  return @"Every directions preview";
    }
}

// Voices for the device's language, best first, each labelled with its quality
// so it is obvious which ones are the good downloadable ones. Selecting a voice
// speaks a sample immediately so it can be judged without starting a trip.
static void mrShowVoiceSheet(UIView *sender) {
    @try {
        NSString *lang = [AVSpeechSynthesisVoice currentLanguageCode];
        NSString *prefix = [lang componentsSeparatedByString:@"-"].firstObject;
        NSMutableArray<AVSpeechSynthesisVoice *> *voices = [NSMutableArray array];
        for (AVSpeechSynthesisVoice *v in [AVSpeechSynthesisVoice speechVoices]) {
            if ([v.language hasPrefix:prefix]) [voices addObject:v];
        }
        [voices sortUsingComparator:^NSComparisonResult(AVSpeechSynthesisVoice *a, AVSpeechSynthesisVoice *b) {
            if (a.quality != b.quality) return a.quality > b.quality ? NSOrderedAscending : NSOrderedDescending;
            if (a.gender != b.gender) return a.gender == AVSpeechSynthesisVoiceGenderFemale ? NSOrderedAscending : NSOrderedDescending;
            return [a.name compare:b.name];
        }];

        UIAlertController *sheet = [UIAlertController
            alertControllerWithTitle:@"Announcement voice"
                             message:@"Enhanced and Premium voices sound far more natural. "
                                     @"Download more under Settings > Accessibility > "
                                     @"Spoken Content > Voices."
                      preferredStyle:UIAlertControllerStyleActionSheet];

        NSString *currentID = mrPickVoice().identifier;
        for (AVSpeechSynthesisVoice *v in voices) {
            NSString *quality = v.quality == AVSpeechSynthesisVoiceQualityDefault ? @"Default"
                              : (v.quality == AVSpeechSynthesisVoiceQualityEnhanced ? @"Enhanced" : @"Premium");
            NSString *gender = v.gender == AVSpeechSynthesisVoiceGenderFemale ? @"female"
                             : (v.gender == AVSpeechSynthesisVoiceGenderMale ? @"male" : @"neutral");
            NSString *title = [NSString stringWithFormat:@"%@ — %@, %@, %@", v.name, quality, gender, v.language];
            UIAlertAction *a = [UIAlertAction actionWithTitle:title
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction *x) {
                mrSetConfigString(@"voiceIdentifier", v.identifier);
                mrAnnounce(@"Tesco Express", nil);   // sample it right away
            }];
            if ([v.identifier isEqualToString:currentID]) mrMarkChecked(a);
            [sheet addAction:a];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel handler:nil]];
        mrPresent(sheet, sender);
    } @catch (id e) {
        mrLog(@"voice sheet failed (%@)", e);
    }
}

static void mrShowSettings(UIButton *sender) {
    @try {
        UIAlertController *menu = [UIAlertController
            alertControllerWithTitle:@"MapsRecentre"
                             message:nil
                      preferredStyle:UIAlertControllerStyleActionSheet];

        [menu addAction:[UIAlertAction
            actionWithTitle:[NSString stringWithFormat:@"Auto-recentre: %@", mrLabelForDelay(mrDelaySeconds())]
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
            mrShowChoiceSheet(sender, @"Auto-recentre",
                @"How long after you stop panning the map before it recentres on you. "
                @"Applies to the next navigation.",
                @[@0, @3, @5, @8, @10, @15], ^NSString *(int d){ return mrLabelForDelay(d); },
                mrDelaySeconds(), ^(int d){ mrSetDelaySeconds(d); });
        }]];

        [menu addAction:[UIAlertAction
            actionWithTitle:[NSString stringWithFormat:@"Auto-start: %@", mrAutoStartModeLabel(mrAutoStartMode())]
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
            mrShowChoiceSheet(sender, @"Auto-start",
                @"Press Start for you on a directions preview. \"Siri and links only\" "
                @"leaves routes you look up inside the app alone.",
                @[@(MRAutoStartOff), @(MRAutoStartExternal), @(MRAutoStartAlways)],
                ^NSString *(int m){ return mrAutoStartModeLabel(m); },
                mrAutoStartMode(), ^(int m){ mrSetConfigInt(@"autoStartMode", m); });
        }]];

        [menu addAction:[UIAlertAction
            actionWithTitle:[NSString stringWithFormat:@"Auto-start delay: %@", mrLabelForDelay(mrAutoStartDelay())]
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
            mrShowChoiceSheet(sender, @"Auto-start delay",
                @"How long the preview stays up before Start is pressed.",
                @[@0, @3, @5, @8, @10, @15], ^NSString *(int d){ return mrLabelForDelay(d); },
                mrAutoStartDelay(), ^(int d){ mrSetConfigInt(@"autoStartDelaySeconds", d); });
        }]];

        [menu addAction:[UIAlertAction
            actionWithTitle:[NSString stringWithFormat:@"Announce destination: %@",
                             mrAnnounceEnabled() ? @"On" : @"Off"]
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) {
            mrSetConfigInt(@"announceDestination", mrAnnounceEnabled() ? 0 : 1);
        }]];

        AVSpeechSynthesisVoice *currentVoice = mrPickVoice();
        [menu addAction:[UIAlertAction
            actionWithTitle:[NSString stringWithFormat:@"Voice: %@", currentVoice.name ?: @"Default"]
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *a) { mrShowVoiceSheet(sender); }]];

        [menu addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                 style:UIAlertActionStyleCancel handler:nil]];
        mrPresent(menu, sender);
    } @catch (id e) {
        mrLog(@"settings: present failed (%@)", e);
    }
}

@interface MRSettingsButton : UIButton
@end

@implementation MRSettingsButton
- (void)mrTapped { mrShowSettings(self); }
@end

// Build a button matching Google's floating buttons: 56pt circle, white, 24pt
// glyph, systemBlue tint. Plain UIKit rather than instantiating the private
// AZFloatingButton — the styling is trivial to match and this cannot throw.
//
// Deliberately alloc/init rather than +buttonWithType:. For non-custom types
// UIKit may hand back a plain UIButton instead of an instance of the receiving
// subclass, which would make `mrTapped` an unrecognised selector and abort the
// app on the first tap.
static MRSettingsButton *mrMakeSettingsButton(CGRect frame) {
    MRSettingsButton *b = [[MRSettingsButton alloc] initWithFrame:frame];
    b.tag = kSettingsButtonTag;
    b.backgroundColor = [UIColor systemBackgroundColor];
    b.tintColor = [UIColor systemBlueColor];
    b.layer.cornerRadius = frame.size.height / 2.0;
    b.layer.shadowColor = [UIColor blackColor].CGColor;
    b.layer.shadowOpacity = 0.25;
    b.layer.shadowRadius = 3.0;
    b.layer.shadowOffset = CGSizeMake(0, 1);
    b.accessibilityLabel = @"Auto-recentre settings";

    UIImage *glyph = nil;
    @try {
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:20
                                                            weight:UIImageSymbolWeightMedium];
        glyph = [UIImage systemImageNamed:@"gearshape.fill" withConfiguration:cfg];
    } @catch (id e) {}
    if (glyph) [b setImage:glyph forState:UIControlStateNormal];

    [b addTarget:b action:@selector(mrTapped) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

// Keep exactly one settings button sitting one slot above the map's
// floating-button column.
//
// Getting this right took three attempts, and the failures are worth recording
// because they are all invisible without a hit-test:
//
//  1. Anchoring to the compass alone fails. Outside navigation there is a single
//     AZCompassButton, hidden with a zero frame, so the button only ever existed
//     mid-drive.
//  2. Anchoring to "whichever column button called us" fails. The same 56pt
//     column x-position is also used by the assistant microphone inside
//     GMSNavHeaderView, and that view sits BELOW the map's gesture handler, so a
//     button placed there is visible but every tap is swallowed by
//     GMSGestureHandlerView. It looks like a dead button, not a misplacement.
//  3. Placing per-host lets several buttons exist at once, one per host, and the
//     one you can see is not necessarily the one that works.
//
// So: collect every plausible column button across the window, keep only those
// that are genuinely hit-testable, group them by superview, and trust the host
// holding the most of them. During navigation that is
// AZUINavigationAccessibilityView (compass 523, FABs 595/667/739); on the plain
// map it is AZTouchForwarderView. Then place our single button one pitch above
// that group's topmost member and bring it to the front.

static __weak MRSettingsButton *gSettingsButton = nil;

// A view counts as a column button if it is a visible, circular, button-sized
// view that actually receives touches. Tested structurally rather than by class
// so this does not need updating when Google renames a button class.
static BOOL mrIsColumnButton(UIView *v, UIWindow *win) {
    if (v.tag == kSettingsButtonTag) return NO;
    if (v.hidden || v.alpha < 0.1 || !v.userInteractionEnabled) return NO;
    CGRect f = v.frame;
    if (f.size.width < 48.0 || fabs(f.size.width - f.size.height) > 1.0) return NO;
    if (f.origin.y <= 0.0) return NO;
    @try {
        CGPoint pt = [v.superview convertPoint:v.center toView:win];
        UIView *hit = [win hitTest:pt withEvent:nil];
        // The topmost hit may be a subview of the button, so walk up.
        while (hit && hit != v) hit = hit.superview;
        return hit == v;
    } @catch (id e) { return NO; }
}

static void mrCollectColumnButtons(UIView *root, UIWindow *win, NSMutableArray<UIView *> *out, int depth) {
    if (depth > 12) return;
    for (UIView *v in root.subviews) {
        if (mrIsColumnButton(v, win)) [out addObject:v];
        mrCollectColumnButtons(v, win, out, depth + 1);
    }
}

// Earlier builds could leave a settings button behind in a host we have since
// moved away from, and a stray in the wrong host is exactly the dead-looking
// button described above.
static void mrCollectStraySettingsButtons(UIView *root, UIView *keep, NSMutableArray<UIView *> *out, int depth) {
    if (depth > 12) return;
    for (UIView *v in root.subviews) {
        if (v.tag == kSettingsButtonTag && v != keep) [out addObject:v];
        mrCollectStraySettingsButtons(v, keep, out, depth + 1);
    }
}

static void mrPlaceSettingsButton(UIWindow *win) {
    @try {
        if (!win) return;
        NSMutableArray<UIView *> *candidates = [NSMutableArray array];
        mrCollectColumnButtons(win, win, candidates, 0);
        if (candidates.count == 0) return;

        // Group by superview and trust the host holding the most column buttons.
        NSMutableDictionary<NSValue *, NSMutableArray<UIView *> *> *groups = [NSMutableDictionary dictionary];
        for (UIView *v in candidates) {
            NSValue *key = [NSValue valueWithNonretainedObject:v.superview];
            NSMutableArray *g = groups[key] ?: (groups[key] = [NSMutableArray array]);
            [g addObject:v];
        }
        NSMutableArray<UIView *> *best = nil;
        for (NSMutableArray<UIView *> *g in groups.allValues) {
            if (!best || g.count > best.count ||
                (g.count == best.count && [g.firstObject frame].origin.y > [best.firstObject frame].origin.y)) {
                best = g;
            }
        }
        if (!best.count) return;

        CGRect top = [best.firstObject frame];
        for (UIView *v in best) if (v.frame.origin.y < top.origin.y) top = v.frame;

        CGRect target = CGRectMake(top.origin.x,
                                   top.origin.y - (top.size.height + kColumnGap),
                                   top.size.width, top.size.height);
        if (target.origin.y < 0) return;  // no room above the column

        UIView *host = [best.firstObject superview];
        MRSettingsButton *btn = gSettingsButton;
        if (btn && btn.superview != host) { [btn removeFromSuperview]; btn = nil; }
        if (!btn) {
            btn = mrMakeSettingsButton(target);
            gSettingsButton = btn;
            [host addSubview:btn];
            mrLog(@"settings button placed at %@ in %@", NSStringFromCGRect(target), host.class);
        } else if (!CGRectEqualToRect(btn.frame, target)) {
            btn.frame = target;
        }
        [host bringSubviewToFront:btn];

        // Prune any strays left by an earlier host, so there is only ever one.
        NSMutableArray<UIView *> *strays = [NSMutableArray array];
        mrCollectStraySettingsButtons(win, btn, strays, 0);
        for (UIView *s in strays) [s removeFromSuperview];
    } @catch (id e) {
        mrLog(@"settings button placement failed (%@)", e);
    }
}

// Coalesced: the hooks below fire on every layout pass of every column button,
// and the scan walks the view tree.
static void mrSyncSettingsButton(UIView *anchor) {
    static BOOL pending = NO;
    if (pending) return;
    UIWindow *win = anchor.window;
    if (!win) return;
    pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        pending = NO;
        mrPlaceSettingsButton(win);
    });
}

#pragma mark - Hooks

// Declared so the hook arguments type as views. Without this Logos synthesises a
// bare NSObject-derived interface and passing self as a UIView * fails to build.
@interface AZCompassButton : UIView
@end
@interface AZFloatingButton : UIView
@end

%hook GMMCPNavigation2Parameters

- (int)autoRecenterInactivityDelaySeconds {
    int orig = %orig;
    int want = mrDelaySeconds();
    if (want > 0) {
        mrLog(@"autoRecenterInactivityDelaySeconds: %d -> %d", orig, want);
        return want;
    }
    mrLog(@"autoRecenterInactivityDelaySeconds: passthrough %d (off)", orig);
    return orig;
}

%end

// Both column members are tracked, because which one is present depends on
// whether navigation is running.
%hook AZCompassButton
- (void)didMoveToSuperview { %orig; mrSyncSettingsButton(self); }
- (void)setFrame:(CGRect)frame { %orig; mrSyncSettingsButton(self); }
%end

%hook AZFloatingButton
- (void)didMoveToSuperview { %orig; mrSyncSettingsButton(self); }
- (void)setFrame:(CGRect)frame { %orig; mrSyncSettingsButton(self); }
%end

// Siri hands directions over as an external URL open. Recording it is what lets
// "Siri and links only" mean something, rather than auto-starting every route
// the user browses inside the app. The source app is logged so the rule can be
// narrowed later if it turns out to be too broad.
%hook AZExternalURLController

- (BOOL)openURL:(NSURL *)url sourceApplication:(NSString *)source {
    @try {
        gExternalOpenAt = [NSDate date];
        gExternalSource = [source copy];
        mrLog(@"external open from %@: %@", source ?: @"(nil)", url.absoluteString);
    } @catch (id e) {}
    return %orig;
}

%end

%hook AZMotorableTripDetailsPresenter

// Fires once the directions preview is actually on screen.
- (void)startUIUpdates {
    %orig;
    mrMaybeArmAutoStart((AZMotorableTripDetailsPresenter *)self);
}

// A manual tap supersedes any pending auto-start, so it cannot fire twice.
- (void)didTapStartNavigationChip {
    gAutoStartGeneration++;
    %orig;
}

%end

%ctor {
    mrLog(@"MapsRecentre loaded — delay %ds", mrDelaySeconds());
}
