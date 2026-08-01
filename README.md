# MapsRecentre

Two things Google Maps should already do on iOS:

1. **Auto-recentre** — after you pan away during navigation the map recentres on
   you, instead of sitting where you dragged it until you tap **Re-center**.
2. **Auto-start** — a directions preview that arrived from Siri (or a link)
   presses **Start** for you after a few seconds, announcing the destination,
   the way Apple Maps does. No reaching for the phone mid-drive.

Both are configurable from a gear button in the map's floating-button column,
directly above the compass.

Built and tested against iOS 16.3.1 on Dopamine/Roothide with Google Maps 26.30.3.
ARM64e device (A12 or newer).

## Auto-recentre: how it works

Google Maps already implements auto-recentre, fully, in the shipping binary. It
is gated off by a server-side client parameter that arrives as 0.

`-[AZNavGuidanceViewController initWithRouteState:directionsSearch:directionsResponse:options:services:]`
reads `-[GMMCPNavigation2Parameters autoRecenterInactivityDelaySeconds]` exactly
once, when the navigation UI is constructed, and seeds its own inactivity timer
with it. The surrounding machinery is all there:

```
- startAutoRecenterTimer
- autoRecenterInactivityTimer
- cancelAutoRecenterTimer
- handleAutoRecenterTimeout
- recenterMap / handleRecenterMap
- isRecenterButtonVisible
- isFollowMode
```

So this tweak is one hook: return a non-zero delay from that getter. Google's own
code does the rest, which means the camera animation, the Re-center button state
and the analytics all behave natively. Nothing is synthesised, no touches are
injected, no view hierarchy is walked.

## Auto-start: how it works

Captured from a real Siri request on-device, the flow is:

```
Siri -> -[AZExternalURLController openURL:sourceApplication:]
        comgooglemaps://?directionsmode=driving&daddr=...
     -> AZMotorableTripDetailsPresenter init
     -> -[AZMotorableTripDetailsPresenter startUIUpdates]      preview on screen
     -> user taps Start
     -> -[AZMotorableTripDetailsPresenter didTapStartNavigationChip]
```

So the tweak notes external opens, arms a timer when the preview appears, and
then calls the Start chip's **own action**. Same principle as the recentre hook:
drive Google's real code path rather than synthesising a touch.

The destination for the announcement comes from
`routeState.remainingWaypoints.lastObject.listingName` (an `AZPlacemark`), e.g.
"Tesco Express", falling back to the address.

**Modes**: Off / Siri and links only (default) / Every directions preview. The
middle one is what makes this safe — a route you look up inside the app is left
alone, only externally-initiated ones self-start.

### The announcement, and why it is not Google's voice

Google's navigation voice is **not reachable** for this. It runs through
`GMSVoiceGuidance` (`- synthesizeAudio:timeout:completion:`), a network-TTS
pipeline that only exists while a navigation session is live — and the
announcement by definition happens *before* navigation starts. Driving it would
force the announcement to come after Start, which is exactly the collision we
are avoiding.

So it uses Apple TTS, chosen well: highest quality available for the device
language, preferring female. **Voice quality is set by what you have
downloaded** under Settings > Accessibility > Spoken Content > Voices — an
Enhanced or Premium voice sounds dramatically better than the Default one. The
voice picker in settings labels each with its quality, and speaks a sample when
you select it.

The announcement completes **before** Start is pressed, so it does not talk over
Google's first turn instruction. A 6s watchdog fires the start anyway if speech
stalls, so a TTS problem can never strand the auto-start.

## Discovery notes

Google Maps is FairPlay encrypted, so this was all Frida recon on-device. Useful
landmarks for future work:

- The app's own ObjC namespaces are `AZ*` (app/UI layer, ~3800 classes), `GMS*`
  (shared maps services) and `GMM*` (protobuf-generated client parameters).
- Client parameters live on `GMMCP*Parameters` proto objects; there is exactly
  one live `GMMCPNavigation2Parameters` instance.
- `GMSDCameraCoordinator` is the camera entry point if you ever need the manual
  route: `- setMode:` / `- setMode:forceUpdate:` take a **struct wrapping a
  uint64**, not a plain enum, while `- mode` returns a plain uint64.
  `- mapViewGesturesWillStart` / `- mapViewGesturesDidEnd` bracket user pans.

### What was verified, and how

1. Forcing the getter to 5 under Frida put `autoRecenterInactivityDelaySeconds = 5`
   on the live nav view controller — the injected value reaches the consumer.
2. Calling `startAutoRecenterTimer` on that controller produced
   `handleAutoRecenterTimeout` exactly 5.000 s later — the real timer honours the
   injected delay.
3. With `isFollowMode` forced to NO (faking "panned away"), that same timeout ran
   straight through to `handleRecenterMap` → `recenterMap`. The full chain works.
   In the earlier run `recenterMap` was skipped only because `isFollowMode` was
   already true and there was nothing to recentre — correct behaviour, not a bug.
4. With the built tweak installed rather than Frida: the dylib injects into
   `com.google.Maps`, the log shows `autoRecenterInactivityDelaySeconds: 0 -> 5`
   (confirming Google's server value really is 0), and a fresh navigation session
   reports `autoRecenterInactivityDelaySeconds = 5` on its live nav controller.

The one link proven only by inference, not directly observed, is that a physical
pan clears follow mode and calls `startAutoRecenterTimer`. That needs a real pan
during navigation to confirm — everything downstream of it is verified.

## Configuration

Delay defaults to **5 seconds**. It is read once per navigation session, so a
change takes effect on the *next* navigation — no relaunch, no respring.

Everything is in the gear button above the compass:

| Setting | Default |
|---|---|
| Auto-recentre delay | 5 seconds |
| Auto-start | Siri and links only |
| Auto-start delay | 5 seconds |
| Announce destination | On |
| Voice | best available for your language, preferring female |

The recentre delay can also be set from the Mac without touching the phone:

```bash
./set-delay.sh 8        # recentre 8s after you stop panning
./set-delay.sh 0        # passthrough: leave Google's value, i.e. disable
./set-delay.sh reset    # remove config, use the built-in default
```

### Why not NSUserDefaults

The obvious approach — a shared `NSUserDefaults` suite, as used by the
SpringBoard tweaks in this collection — **does not work here**, and fails
silently. Google Maps is a sandboxed third-party app, so a
`defaults write com.guacforlife.mapsrecentre delaySeconds 8` on the device succeeds and is
still completely invisible to the tweak. Verified on-device: `defaults read` showed
the value while the tweak logged `no stored value` on the very next launch.

Two file paths are usable, and their roles come from what the app is actually
allowed to do with each — both verified from inside the Google Maps sandbox:

| Path | App can | Role |
|---|---|---|
| `<container>/Library/Preferences/com.guacforlife.mapsrecentre.plist` | read + write | authoritative, written by the in-app settings |
| `<jbroot>/var/mobile/Library/Preferences/com.guacforlife.mapsrecentre.plist` | read only | fallback seed, e.g. pushed from the Mac |

The container wins, so a value you pick in the app is never shadowed by a stale
jbroot file. The jbroot path is readable from inside the sandbox because the
tweak's own dylib is loaded from that same jbroot; it is discovered at runtime
with `dladdr()` rather than hardcoding the UUID, which changes on every
re-jailbreak. Writing it from inside the app is denied, which is exactly why the
container is the authoritative side.

## Build

```bash
export THEOS=~/theos
make clean && make package FINALPACKAGE=1
```

Produces a rootless `iphoneos-arm64` deb. The binary is built for
`arm64 arm64e` — the arm64e slice is required, since ElleKit silently skips
arm64-only dylibs on A12 and newer.

Install with Sileo/Zebra from the repo below, or patch the deb with Roothide
Patcher before `dpkg -i` if installing manually.

## Repo

    https://guacforlife.github.io/repo/

## Licence

MIT. See [LICENSE](LICENSE).
