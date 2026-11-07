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
- Latency: the phone acks each frame (`v a <pts>`); the host logs "Screen: ack delay … backlog …"
  to stderr every 5 s while streaming. Healthy on good Wi-Fi is under ~40 ms and a backlog of
  0–1 frames. Capture is skipped (not frames dropped) while the backlog exceeds ~3 frames.
- Windows ignores `v`/`M`; the phone hides the toggle for Windows hosts.

## Commits
Attribution trailer per the session's reminder. Push to `main` directly; no PRs needed for now.
