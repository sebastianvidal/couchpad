# Couchpad — working notes for Claude

Three apps, one protocol: `iOS/` (SwiftUI), `Mac/` (SwiftPM menu-bar app), `Windows/` (.NET 8
tray app). `docs/` is the GitHub Pages site. README.md is the user-facing overview; keep it true.

## Releases

### Mac (direct download, notarized DMG)
1. Bump `CFBundleShortVersionString` in `Mac/Info.plist`.
2. `SIGN_IDENTITY="Developer ID Application: Sebastian Vidal (HQZM8YK4DC)" Mac/release.sh`
   — clean-builds, signs, packages `Mac/build/Couchpad-<version>.dmg`, notarizes (keychain
   profile `couchpad`, already stored), staples. ~5 minutes, mostly Apple's queue.
3. `gh release create v<version> Mac/build/Couchpad-<version>.dmg --title "Couchpad <version> — Mac companion" --notes "..."`
4. Update the DMG filename in `docs/index.html` (two links) and README.md, commit, push.
   Pages deploys in ~1 minute; verify with `curl -s https://sebastianvidal.github.io/couchpad/ | grep dmg`.
5. If the Mac app was running, relaunch it from `Mac/build/Couchpad.app` so the user runs the
   release build.

Never ship a build whose `swift build` errored; `build.sh` exits non-zero on failure for that reason.

### iPhone (App Store / TestFlight)
- Xcode: open `iOS/Couchpad.xcodeproj`, destination *Any iOS Device*, Product → Archive,
  Distribute → App Store Connect → Upload. The user does this; it needs their Apple ID session.
- The build number is stamped automatically (UTC `YYYYMMDDHHMM`) by a build phase; only
  `MARKETING_VERSION` in the pbxproj needs bumping for a new version.
- Team ID lives in `iOS/Config/Local.xcconfig` (git-ignored); never put `DEVELOPMENT_TEAM` in
  the pbxproj.
- Listing text and review notes: `docs/app-store-copy.md`.

### Windows
- `dotnet publish Windows -c Release -r win-x64 --self-contained -p:PublishSingleFile=true`,
  zip the `publish` folder, attach to the release. Compile-check on macOS with the SDK in the
  scratchpad (`dotnet build Windows`). Not yet run on a real Windows machine; say so.

## Facts that are easy to get wrong
- Bundle IDs: iOS `com.seb.Couchpad` (registered in App Store Connect), Mac `com.seb.Couchpad.mac`.
  Changing either resets pairing tokens and (Mac) Accessibility trust.
- Bonjour type `_couchpad._tcp`, port 48123, pairing URL scheme `couchpad://`.
- Local Mac builds sign with the Apple Development cert so Accessibility trust survives
  rebuilds; release builds use Developer ID.
- Arrow-key events must carry the Fn + keypad flags or macOS hotkeys (Mission Control) ignore them.
- Hosts must ignore lines that arrive before `hello`; answering `nope` makes the phone drop its token.
- Testing input against the real Mac moves the user's cursor; keep it to a single swipe. Never
  run a stand-in host on port 48123 while the user may be using the app — their phone will
  connect to it.
- The Mac app's pairing code is printed to stderr whenever it changes; run the binary directly
  with stderr captured to read it. Codes are only accepted while the pairing window is open
  (max 1 minute, one guess per connection, 3 misses rotate + 3 s lockout). Launch with
  `--pair` to open that window without clicking the menu, e.g. for protocol tests.
- Wire protocol is v2: P-256 ECDH + HKDF + AES-256-GCM frames, HMAC proofs over the
  transcript instead of sending tokens/codes. The Swift implementation is one file,
  `Shared/SecureChannel.swift`, symlinked into the Mac package and the iOS folder; the C# port
  is `Windows/SecureChannel.cs` and must stay byte-compatible (nonce layout, AAD, HKDF info).
  To watch the wire during tests, run a logging TCP proxy on another port and pair through it
  with a `couchpad://pair?...&port=<proxy>` URL; expect only the two `v2` lines in the clear.

## iPhone Duo (foldable)
- Needs the iOS 27.1+ SDK (we build with Xcode 27.2). Xcode 27 has no Simulator.app: simulators
  live in `Xcode.app/Contents/Applications/DeviceHub.app` (bundle `com.apple.dt.Devices`), whose
  bottom toolbar has Closed / Partially Open / Open posture buttons and Controls → Rotate.
- Duo device type `com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`, runtime
  `iOS-27-2-iPhone19-4`. Two displays: outer 1398×2034 (`simctl io … --display=1`), inner
  2007×2853 (`--display=3`); `screenshot` needs `--display` on this device. Don't toggle
  `screenConfig power` to fake a posture: it blanks both displays until a reboot.
- Layout keys off the window's shape (`windowSize` in ContentView), not the vertical size
  class: unfolded and sideways the size class stays regular. `UIScreen.main` is gone; the
  landscape keyboard-top measurement is stored per window size (`landscapeKeyboardTops`).
- The system puts a vertical status bar on one long edge; it arrives as a safe-area inset,
  so nothing in the app should assume insets are symmetric or orientation-bound.
- Posture comes from iOS 27.1's `UIHingeInteraction` (`HingeObserver.swift`): closed /
  partiallyOpen / fullyOpen. Half open with the picture on, ContentView splits at the hinge
  (assumed at the middle of the window's long side). Device Hub's "Partially Open" button
  drives it on the simulator.

## Screen streaming (Mac → phone)
- `Mac/Sources/CouchpadMac/ScreenStreamer.swift`: ScreenCaptureKit → VideoToolbox (HEVC,
  H.264 fallback, real-time, no reordering). Frames go out through `Server.broadcast`, which
  drops frames past ~600 KB in flight per phone and then forces a keyframe. Phone side is
  `iOS/Couchpad/ScreenView.swift` (AVSampleBufferDisplayLayer, display-immediately).
- Needs the Screen Recording TCC grant for the running binary. After granting, macOS may
  relaunch `/Applications/Couchpad.app` instead of the dev build; make sure only one is
  running (`pgrep -fl Couchpad.app/Contents/MacOS/Couchpad`) or they fight over the port.
- The Mac app logs a pairing code at launch and another when `--pair` opens the window;
  the second one is the live code.
- To test the picture on a simulator: `defaults write com.seb.Couchpad showScreen -bool true`
  via `simctl spawn`, pair with `simctl openurl couchpad://pair?...` (an "Open in Couchpad?"
  prompt must be tapped in Device Hub), then watch `log show --predicate 'process == "Couchpad"'`
  for `FigVideoQueue … frames enqueued`. Testing the absolute pointer moves the user's cursor.
- Latency: the phone acks each frame (`v a <pts>`); the host logs a stats line to stderr every
  5 s while streaming: ack delay (smoothed and worst in the window), backlog, capture age
  (how stale ScreenCaptureKit's frame is), encode time, frames skipped. Healthy: ack ~10 ms,
  capture age ~0, encode ~5 ms, skipped 0. Capture is skipped (never frames dropped) while
  the oldest unacked frame is older than 80 ms. A high "max" with a tiny backlog is the Wi-Fi
  stalling, not the pipeline: check retransmits with
  `nettop -p <mac pid> -l 1 -J bytes_out,re-tx,rtt_avg` (12% re-tx seen on the user's mesh)
  and ping the phone with `--apple-time` to catch the gaps. ICMP at low rates misses them.
- Frames go over UDP (same port) once the phone's `hello` datagram reaches the host; the stats
  line says `(udp)` or `(tcp)`, how many frames the phone gave up on (`lost`), how many chunks
  were missing, and the current parity ratio. Layout and keys: bottom of
  `Shared/SecureChannel.swift`; chunking, parity repair and the replay window have a quick
  standalone check: compile `Shared/SecureChannel.swift` with a `main.swift` that round-trips
  `VideoDatagram.chunks` through `DatagramCipher` and `FrameAssembler` with chunks removed.
  A still screen sends pings every 0.5 s so the phone doesn't fall back to TCP (`v t`).
  Missing chunks are nacked by index and re-sent from an 8-frame history (`resent` in the
  stats line); frames behind wait up to 100 ms. Only frames given up on count as `lost`:
  every `v l` shrinks the parity group (to 1/3 at worst); three lost frames within 2 s cut
  the encoder bitrate 25% (floor 25%). Both recover over quiet seconds; `rate` in the stats
  line is the current share. Datagrams are paced at 3× the bitrate (min 1 MB/s): fired as
  one burst, a keyframe's 50 datagrams were lost whole on the user's Wi-Fi, every time.
  The user's Duo on the Google Wifi mesh loses bursts of 6+ packets a few times a minute at
  any rate; ICMP sees 1% random loss. Parity groups are interleaved (chunk i in group i mod
  G) so a burst spreads across groups.
- Windows ignores `v`/`M`; the phone hides the toggle for Windows hosts.

## Commits
Attribution trailer per the session's reminder. Push to `main` directly; no PRs needed for now.
