# Freeskate

A custom Garmin Connect IQ watch-app for the Enduro 3 that records freeskating
(JMKRIDE-style, independent pivoting footplates) as its own "Freeskate"
activity: GPS-based distance/speed (not step-based, which is why the built-in
Walk profile doesn't work for this), time-in-HR-zone using your Garmin-configured
zones, and a lap button.

Built and tested with Connect IQ SDK 9.2.0, compiler API level 5.0.1, targeting
`enduro3`, using the CLI tools directly (no VS Code required).

## One-time setup

1. Install the **Connect IQ SDK Manager** (developer.garmin.com/connect-iq/sdk/)
   and, through it, download the SDK and the `enduro3` device. This installs
   to `~/Library/Application Support/Garmin/ConnectIQ/` on macOS; the SDK's
   `bin/` directory (referred to as `$SDK_BIN` below) has `monkeyc`, `monkeydo`,
   `mdd`, and the `ConnectIQ.app` simulator.
2. Generate a developer key (one-time, signs all your builds):
   ```
   openssl genrsa -out developer_key.pem 4096
   openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key.der -nocrypt
   ```
   Keep `developer_key.der`/`.pem` private and out of any shared repo.

## Working from a fresh clone (new machine / Linux)

`developer_key.der`/`.pem` and `bin/` are gitignored (private key, regenerable
build output). After cloning on any machine (macOS, Windows, or Linux -- the
Connect IQ SDK Manager supports all three):

1. Install the SDK Manager and the `enduro3` device, same as above.
2. Re-run the `openssl` commands above to generate a developer key. It doesn't
   need to be the same key as any other machine -- it only needs to exist to
   sign local builds and sideloads. Store/beta uploads go through Garmin's own
   portal separately and aren't tied to this local key.
3. Rebuild with the `monkeyc`/`monkeydo` commands below.

## Build & test in the simulator

```
open "$SDK_BIN/ConnectIQ.app"                                    # start the simulator once
"$SDK_BIN/monkeyc" -o bin/Freeskate.prg -f monkey.jungle \
    -y developer_key.der -d enduro3                              # compile
"$SDK_BIN/monkeydo" bin/Freeskate.prg enduro3                    # load into the running simulator
```

Re-run the `monkeyc`/`monkeydo` pair after every change. Use the simulator's
Simulation menu to feed simulated GPS/HR data so you can exercise
start/pause/resume/lap/stop without going outside.

If something misbehaves and `println()` debugging is needed, add
`System.println(...)` calls and read `monkeydo`'s stdout — it prints cleanly
there. The GUI simulator itself doesn't expose a console/log panel in this
SDK version, and the command-line debugger (`mdd`) is workable but only
reliably pauses/steps when its breakpoints are set *before* `r` (run) rather
than on an already-running app.

## Sideload to your physical Enduro 3

1. Connect the watch via USB (it mounts as a drive).
2. Copy `bin/Freeskate.prg` into `GARMIN/APPS/` on the watch.
3. Eject/disconnect — the app should appear in the watch's app list.
4. Run one short real freeskating session, then confirm in Garmin Connect that
   the activity is named "Freeskate", distance/pace look GPS-based (not
   near-zero or step-derived garbage), and HR zone time looks plausible for
   the effort.

## Icon attribution

`resources/drawables/launcher_icon.png` and `store_cover_500x500.png` are
generated (see `resources/drawables/source/regenerate_icons.sh`) from
`resources/drawables/source/noun-freeskate-5427020.svg`, a Noun Project icon
credited to Marcel. No no-attribution license was purchased for it, so any
public listing (store description, app page, etc.) using this icon must
carry the credit "Freeskate icon by Marcel from the Noun Project."

## Publishing to the Connect IQ Store

The portal upload is a separate build artifact from the sideload
`.prg` -- `bin/Freeskate.prg` (built with `-d enduro3`, see above) only
targets one device and isn't what the portal accepts. Build the
submission package with:

```
"$SDK_BIN/monkeyc" -e -o bin/Freeskate.iq -f monkey.jungle \
    -y developer_key.der -r
```

(`-e`/`--package-app` produces the `.iq` package; `-r` strips debug info,
appropriate for a submission build.) Re-run this after every change meant
for the store, the same way `bin/Freeskate.prg` needs re-running after
every change meant for sideload -- neither regenerates the other.

The `id` in `manifest.xml` is permanent once uploaded to Garmin's developer
portal — Garmin's own upload confirmation says as much: an app uploaded
under one `id` stays a private beta forever (visible only to you, under
"Beta Apps" in the developer dashboard); making it publicly installable
requires uploading again under a *different* `id`. There's no portal
setting that flips a private beta to public.

Practically, this means the `id` currently in `manifest.xml` is the one
intended for public submission — if you need another private beta upload
later (e.g. to test independently of what's live in the store), generate a
fresh UUID for that build rather than reusing this one.

**Deleting an app from the dashboard does not free its `id` for reuse.**
Confirmed by hitting "The manifest app ID is already in use by another
app" on a fresh submission after deleting the prior beta upload that had
used that `id` -- the block persisted regardless. Treat every `id` as
burned the moment it's ever uploaded, beta or not, deleted or not: don't
test-upload a build as a beta under the `id` you intend to eventually
submit for public review. If you want to sanity-check that a build
installs before committing to the real public submission, generate a
disposable UUID for that test and a separate fresh one for the actual
submission.

## Manifest permissions (confirmed by compiler)

`Positioning`, `Fit` (gates `ActivityRecording`), `FitContributor` (gates the
custom HR-zone-time field), `UserProfile` (gates `getHeartRateZones`), and
`Sensor` (gates `registerSensorDataListener`, used by `PumpCadenceDetector`
for the wrist accelerometer) are all required — the compiler errors
precisely by symbol if any is missing.

## Button mapping (source/FreeskateDelegate.mc)

- **Select**: start → pause → resume (mirrors native Garmin activity apps)
- **Back**: **lap** while recording; **stop + save** while paused; no-op when
  ready/stopped. On this device/simulator, the physical down button was found
  to trigger `onBack()`, not `onNextPage()` as the generic API docs suggest —
  confirmed empirically, not assumed. `onNextPage()` is still wired to
  `addLap()` in case a different input reaches it on other devices.
- Stopping requires pausing first (Select, then Back) — a deliberate two-step
  to avoid ending a recording with one accidental press, matching how native
  Garmin run/bike apps behave.

### Known issue: don't let `onBack()` return `false`

Returning `false` from `onBack()` (i.e. falling through to the platform's
default "exit app" behavior at the root view) reproducibly crashes this SDK
9.2.0 / `enduro3` simulator combination — confirmed via a minimal repro
(pressing Back once from a freshly-launched app, before ever starting a
recording, with no `ActivityRecording`/`Position`/`FitContributor` code ever
invoked, still crashed). All app-level `println` tracing showed the crash
happens strictly *after* `onStop()` completes cleanly, i.e. in native
framework teardown code with no Monkey C stack to break on — `mdd` couldn't
step into it either. The workaround, applied here, is for `onBack()` to
always return `true` so that path is never hit. Long-pressing Back is a
firmware-level force-quit on real Garmin watches (not routed through the
app's `BehaviorDelegate`), so the app doesn't need to implement exit-on-
single-press itself. If you ever refactor this delegate, preserve
"`onBack()` always returns `true`" or this crash will resurface.

## Deliberately out of scope for v1

Jump/trick detection and left-right carve-balance metrics (via raw
accelerometer) were discussed as possible directions but are not implemented
— v1 is GPS distance/speed + HR zones + laps only, per the original scoping
decision, so it can be validated on real sessions before adding motion-based
features.

A GPS-speed-threshold-based walk/skate classifier (skate_seconds/
other_seconds FIT fields, per-second skate/walk speed split, and an
on-screen skating-status dot) was implemented and then dropped after real
sessions showed it wasn't reliable enough to be useful — speed alone can't
distinguish gait-based movement from skating. May be worth reintroducing
once additional sensor data (e.g. accelerometer) is available to classify
on.
