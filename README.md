# Couchpad

Your iPhone as a trackpad and keyboard for your Mac or Windows PC, with the Mac's screen on
the phone. Made for gaming on a computer plugged into the TV without a mouse and keyboard on
the couch; works from anywhere once both devices are on a VPN (see [Away from home](#away-from-home)).

No accounts, no cloud: the phone finds the computer with Bonjour, pairs once with a 6-digit
code or QR, and talks to it directly over one encrypted connection. There is no server in
between, on your Wi-Fi or through your VPN.

**Status (November 2026)**
- **iPhone:** public **TestFlight beta** — https://testflight.apple.com/join/kY67K51G — ahead
  of a free App Store release. Supports iPhone Duo, folded or unfolded, in both orientations.
- **Mac:** **1.6 released**, signed and notarized —
  [download](https://github.com/sebastianvidal/couchpad/releases/latest). 1.6 sends the Mac's
  sound to the phone with the picture (see [What's new in Mac 1.6](#whats-new-in-mac-16));
  1.5 keeps the picture smooth when a game goes fullscreen;
  1.4 keeps it smooth when a phone's connection drops and comes back, and brings it back
  after the display sleeps; 1.3 wakes a sleeping display on input from the phone and opens its
  menu instantly; 1.2 streams the
  Mac's screen to the phone over encrypted UDP (below) on top of 1.1's encrypted sessions and
  hardened pairing; it needs the current iPhone build.
- **Windows:** compiles, not yet run on a real Windows machine (see the appendix).
- **New:** an [on-screen controller](#on-screen-controller): a stick, A B X Y and seven
  programmable keys under the picture or trackpad, like a hand-held console. Turn it on with
  the d-pad button in the bar. Works with Mac and Windows hosts.
- **Also new:** the Mac's screen on the phone. Turn it on with the display icon next to the gear;
  the picture fills the trackpad, which keeps working as a trackpad (or, as an option, the
  pointer jumps to where you touch), with the compact key row (F keys, esc, tab, fn, the
  modifiers) under the picture, on by default (the ⌘ button in the bar hides and shows it). Hardware HEVC at
  up to 60 frames a second, sent as encrypted UDP datagrams with parity and retransmission so
  a lost Wi-Fi packet costs a frame at most, never a stall; the host paces itself by the
  phone's acknowledgements so lag can't build up. Half-open Duo: picture on the upright half,
  trackpad and keys on the flat one. Needs Screen Recording access for Couchpad on the Mac (it
  asks the first time). Fine for desktop use on a decent Wi-Fi; on a lossy mesh link it still
  hiccups more than a game wants. Mac only so far.
- **New:** the Mac's sound with the picture (Mac 1.6 and iPhone 1.3). It plays on the phone
  about 90 ms after the Mac makes it, some 70 ms behind the picture. On a mesh Wi-Fi it has a
  10–30 ms gap every few seconds when the network hiccups; nothing else is lost. It plays in
  silent mode and mixes with whatever else the phone plays. It is on whenever the picture is;
  Settings → Screen or the dot's menu in the bar turns it off. The Mac keeps playing its own
  sound as well.
- **Next Mac release:** the picture keeps going with a MacBook's **lid closed**, on the
  charger. Closed, macOS used to switch the display off ten seconds after every touch, and the
  picture restarted each time. Now Couchpad attaches a virtual display, which macOS treats
  like a monitor, so the closed Mac stays awake with its screen on. Just after closing you
  keep seeing your own desktop (the virtual display mirrors it, out of sight). Once macOS
  lets the built-in display go, the virtual one becomes the screen, 16:10 like a 13-inch
  MacBook. It goes away when the lid opens, or five minutes after the last phone stops
  watching. On battery macOS sleeps a closed Mac no matter what, so the phone says to plug it in.
- **New on iPhone 1.3:** sideways, the pad and the key row can float over the picture
  (Settings → Pad over the picture), with their opacity set in Settings → Overlay opacity.
- **Also:** confirmed working **over cellular through Tailscale**, screen included, with
  no code changes: the phone just needs a route to the Mac. Setup below.

Site: https://sebastianvidal.github.io/couchpad/

## What's new in Mac 1.6

The Mac's sound plays on the phone with the picture. The Mac captures its audio along with
the screen (with the same Screen Recording permission) and encodes it as Opus in 10 ms
packets. It sends them encrypted, over UDP like the picture, and each datagram also carries
the two packets before it, so a lost one usually costs nothing. The phone plays them from a
small buffer that adapts to the Wi-Fi, holding the sound back only if it would get ahead of
the picture. It needs iPhone 1.3; an older phone never asks for sound and works as before.
Nothing to set up; install 1.6 over 1.5.

## What's new in Mac 1.5

The picture stays smooth when a game goes fullscreen. macOS Game Mode, which turns on with
a fullscreen game, bunches a background app's timers onto a 30 Hz grid; the host's packet
pacer was one of them, so the stream broke up into resend storms and second-long stalls the
moment a game took the screen. The pacer now runs on a real-time thread and catches up on
its own when its timers come late. Also: after a loss the bitrate climbs quickly back to just
under where it last broke, then creeps up, instead of running straight back into the same
wall; and the host opts out of App Nap.
Nothing to set up; install 1.5 over 1.4.

## Get started

1. **iPhone:** install [TestFlight](https://apps.apple.com/app/testflight/id899247664), then
   open https://testflight.apple.com/join/kY67K51G on the phone and tap Install. Allow
   **Local Network** when asked, otherwise the app can't find your computer.
2. **Mac:** download `Couchpad-1.6.dmg` from
   [Releases](https://github.com/sebastianvidal/couchpad/releases/latest), drag Couchpad to
   Applications, open it. A cursor icon appears in the menu bar. Grant **Accessibility** when
   macOS asks (System Settings → Privacy & Security → Accessibility); that permission is what
   lets it move the pointer and type.
3. **Pair:** on the same Wi-Fi, open Couchpad on the phone. It finds the Mac; click the
   menu-bar icon → "Pair an iPhone…" and scan the QR (or type the 6 digits). Done — the phone
   keeps a token and never asks again.

Mac menu: connection status · Pair an iPhone… · address · Accessibility state · Launch at
Login · Forget Paired iPhones. If Bonjour is blocked on your network, the QR pairing also
carries the Mac's address, or type it into Settings → Connection on the phone.

## Gestures

| Phone                      | Computer                                 |
| -------------------------- | ---------------------------------------- |
| One finger                 | Move pointer                             |
| Tap                        | Left click                               |
| Two-finger tap             | Right click                              |
| Two fingers                | Scroll                                   |
| Tap, then touch and hold   | Drag (release to drop)                   |
| Three-finger swipe         | Up: Mission Control · Down: App Exposé · Left/right: switch Spaces (Windows: Task View / desktop / virtual desktops) |
| Left / Right buttons       | Hold the mouse button                    |
| iOS keyboard               | Typing, backspace, return as real key presses |
| Key row                    | An F1–F12 bar, then esc, tab, fn, ⇧ ⌃ ⌥ ⌘, on by default; the ⌘ button in the bar hides and shows it. Keys go down while touched and up on release. Above the on-screen controller when it is on (over the picture with it when the pad floats over the picture, in the same translucent style, at the same adjustable opacity), under the picture or trackpad when it is off. The F1–F12 bar swaps the row for two rows of function keys; while a modifier is held it also shows Release. Half open on an iPhone Duo while typing, the keyboard takes the flat half and the row floats over the picture while it is on |
| ⇧ ⌃ ⌥ ⌘ fn                 | Toggle: held until tapped again; typed letters become shortcuts (⌘C etc.) |
| On a Windows host          | The same keys show as Ctrl / Alt / Win; fn is hidden |
| Keyboard button (bar)      | Show / hide the iOS keyboard. Space and typing come from it. With the on-screen controller on, the keyboard takes the pad's place (the key row, when on, stays above it) until you put it away |
| Backbone / Bluetooth controller | Forwarded as keys and mouse. Every button and stick direction is bindable in Settings → Controller → Bindings; presets: FPS (WASD + mouse look), MapleStory (arrows, alt jump, ctrl attack), Arrows |
| On-screen controller (d-pad button in the bar) | A stick, A B X Y and seven programmable keys, under the picture or trackpad. See [On-screen controller](#on-screen-controller) |

Pointer speed, scroll speed, natural scrolling, tap-to-drag, three-finger swipes and
controller look speed are in the gear menu.

A controller attached to the iPhone, or the on-screen one, works with any game that
accepts keyboard and mouse, which is nearly all of them on a Mac. The computer does not see a gamepad: macOS has no
public API for a virtual one.

## On-screen controller

Tap the d-pad button in the bar (or Settings → Controller → On-screen controller) and the
phone becomes a hand-held console. Pictures and details:
https://sebastianvidal.github.io/couchpad/controller.html

- **Layout.** An 8-way stick on the left (diagonals press two keys at once; drag it like a
  controller's stick, with a dead zone, or touch and hold a direction like a d-pad), A B X Y in a
  diamond on the right, and seven programmable keys above them: the pad's L1, L2, L3, menu,
  options, R1 and R2. Every key shows what it is bound to. Each press gives a light tap of
  haptics, and a finger can slide from key to key without lifting.
- **Upright** the pad takes the bottom half of the screen, under the picture or trackpad.
  **Sideways** it is a short band under the picture: stick, keys, diamond; or, with Settings →
  Pad over the picture, it floats translucent over the picture, the key row with it, and the
  picture keeps the whole height, like touch controls over a game. Settings → Overlay opacity
  sets how solid its keys are, from faint labels only to solid keys (half by default); the
  labels stay a little stronger than the keys, so they never disappear. **Half open
  on an iPhone Duo** it fills the flat half and the picture sits on the upright one.
- **Aim** with the picture or trackpad above it: it still moves the mouse, sent as raw
  motion, which is what games use for camera look.
- **Bindings** are the same as a physical controller's, in Settings → Controller → Bindings.
  Presets: FPS (stick is WASD, A space, B ctrl, R2/L2 left/right click), MapleStory (arrows,
  alt jump, ctrl attack), Arrows (menus, launchers, 2D games). Any key can be a keyboard key,
  left click, right click, or nothing.
- **Other keys.** The key row (F1–F12, esc, tab, fn and the modifiers) sits above the pad
  (over the picture with it, when the pad floats there), on by default; the ⌘ button in the bar hides and shows it. Arrows come from the bindings, space and typing from the iOS
  keyboard: the bar's keyboard button swaps the pad for the keyboard and back.
- Works with Mac and Windows hosts; it only sends keys and mouse. A Backbone or Bluetooth
  controller attached to the phone uses the same bindings.

## Pairing

The first time a phone connects, it asks for a 6-digit code. "Pair an iPhone…" in the
host's menu-bar or tray icon opens a window with a **QR code** and the digits: scan it with
the Scan button in the app (or with the iPhone's Camera app, which opens Couchpad), or type
the digits. The host then gives the phone a token it keeps, so the code is never needed again
for that phone. Only phones with a token can send input.

The code is only live while that window is open, for at most one minute, and for one pairing.
Each connection gets a single guess; three wrong guesses rotate the code and pause pairing for
a few seconds. Pairing is the only way in: without a token, the host ignores everything.

The QR carries the host's address (`couchpad://pair?name=…&addr=…&port=…&code=…`), so a QR
pairing also works on networks that block Bonjour; the phone remembers the address and falls
back to it when discovery finds nothing.

## Away from home

Couchpad needs nothing from the network except a route from the phone to the computer, so a
VPN that puts both devices on one network makes it work from anywhere: cellular, hotel Wi-Fi,
the office. [Tailscale](https://tailscale.com) is the easy choice (free for personal use); any
WireGuard-style VPN or your router's own works the same way. There is still no Couchpad server
and the session is still encrypted end to end inside the tunnel.

1. Install Tailscale on the computer and the iPhone, same account. Each gets a stable
   `100.x.y.z` address.
2. Pair at home over Wi-Fi as usual. Pairing is keyed by the computer's name, not its address,
   so one pairing serves both networks.
3. Away: with Tailscale connected on the phone, open Couchpad, then gear → **Connection** →
   type the computer's Tailscale address → Connect. Bonjour doesn't cross a VPN, so the phone
   won't list the computer, but it remembers the address and uses it whenever discovery
   comes up empty.

Expect input to feel local and the picture to lag a little more than at home: the stream is
tuned for a ~10 ms Wi-Fi round trip and backs off on a slower or lossier link, so it sends
fewer frames over cellular. Fine for desktop work, not yet a remote gaming link; that is
tuning, and it's next. The computer has to be awake (System Settings → Energy, or Displays →
Advanced → prevent sleep on power), and Couchpad can't wake it.

Known rough edges: the QR carries the computer's home address, not the VPN one, so pair at
home or type the address; the phone waits a few seconds for Bonjour before trying the stored
address. Don't port-forward 48123 instead of a VPN: pairing would hold, but a VPN keeps the
port off the internet entirely. Full walkthrough: https://sebastianvidal.github.io/couchpad/remote.html

## Security

Everything goes directly between the phone and the computer, on your local network or
through a VPN you run; the design assumes other people may be on that network too.

- **Encrypted sessions.** Every connection starts with an ephemeral P-256 key exchange; the
  session key comes from HKDF and every line after that is AES-256-GCM. An eavesdropper sees
  two public keys and a nonce, then ciphertext.
- **Nothing secret is ever sent.** The phone proves it holds its token (or the pairing code)
  with an HMAC over the handshake transcript, and the host proves it holds the same token
  back. Captured traffic can't be replayed (fresh keys each time) and an impostor advertising
  your computer's name can neither learn the token nor relay, because the transcript binds
  both sides' keys.
- **Pairing codes are hard to guess.** Live only while the pairing window is open (at most a
  minute, one pairing), one guess per connection, three misses rotate the code and pause
  pairing. Because a new token travels inside the encrypted channel, recording a pairing and
  cracking the 6-digit code afterwards yields nothing; only an attacker active during that
  minute who already knows the code could interpose.
- **What's left:** a paired phone or host that is itself compromised. "Forget Paired
  iPhones" on the host and "Forget this computer" on the phone revoke access.

## License

MIT. See `LICENSE`.

---

## Appendix A: Build from source

```
iOS/       Xcode project (SwiftUI). Trackpad or the Mac's picture, the on-screen controller, the keys the iOS keyboard lacks.
Mac/       SwiftPM menu-bar app. Advertises _couchpad._tcp on port 48123, injects CGEvents.
Windows/   .NET 8 tray app. Same protocol and port, injects via SendInput.
Shared/    SecureChannel.swift, the wire protocol, symlinked into the Mac and iOS trees.
Tools/     make-icons.swift renders the app icons.
docs/      The GitHub Pages site and App Store copy.
```

### iPhone

The happy path is TestFlight (above). To run your own build:

1. `cp iOS/Config/Local.xcconfig.example iOS/Config/Local.xcconfig` and put your Team ID in it.
2. Open `iOS/Couchpad.xcodeproj`, pick your iPhone, Run. The build number stamps itself from
   the UTC time of the build.
3. Allow **Local Network** when asked.

### Mac

```bash
Mac/build.sh
open "Mac/build/Couchpad.app"
```

Local builds sign with your Apple Development certificate when one is in the keychain
(so the Accessibility grant survives rebuilds), ad-hoc otherwise.

### Windows

Needs the [.NET 8 SDK](https://dotnet.microsoft.com/download). On Windows:

```bash
dotnet publish Windows -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
```

Run `Windows/bin/Release/net8.0-windows/win-x64/publish/Couchpad.exe`. It lives in the
system tray; right-click for "Pair an iPhone…", the address and "Start with Windows". The
first run asks to allow it through Windows Firewall — allow it on **private** networks, or the
phone can't reach it. No other permission is needed: `SendInput` works for any app, including
games that read raw input (DirectInput / XInput games see the scan codes it sends).

The project also compiles on macOS/Linux (`dotnet build Windows`) for checking changes, but
only runs on Windows.

**Honest note:** the Windows app was written and compile-checked on a Mac, not yet run on a
real Windows machine. If something misbehaves, open an issue.

## Appendix B: Protocol

Protocol v2 (see `Shared/SecureChannel.swift` and `Windows/SecureChannel.cs`):

```
phone → host   v2 <P-256 public key, base64>                      (plain text line)
host  → phone  v2 <P-256 public key, base64> <16-byte nonce, base64>
                → both derive sessionKey = HKDF-SHA256(ECDH, salt: nonce, info: "couchpad v2 session")
                → every message from here is a frame: 4-byte length ‖ AES-256-GCM(line)
phone → host   auth token|code <HMAC-SHA256(secret, transcript ‖ "client")>
host  → phone  ok <token> mac|windows <HMAC-SHA256(token, transcript ‖ "host")>   or   nope (then hangs up)
```

Inside the channel, one command per line:

```
m dx dy      move (dx/dy also sent as raw mouse deltas, which is what games read)
s dx dy      scroll in pixels
b l|r 1|0    mouse button down / up
c l|r        click
k code 1|0   key down / up, macOS virtual keycode
g up|down|left|right   three-finger swipe; the host maps it to its own shortcut
t text       type text (each character is pressed as its key; shift added as needed)
r            release everything
M fx fy      put the pointer at a point on the streamed display (fractions 0…1 of its size)
v 1 w h fps  start streaming the screen, scaled to fit w×h pixels   ·   v 0 stop   ·   v k send a keyframe
v a pts      the phone got the frame with that timestamp (the host paces capture by these)
v l n c      the phone gave up on n frames over UDP, c of their chunks never arrived
v t          the phone stopped getting UDP datagrams: send frames over TCP again
v s 1|0      send the Mac's sound with the picture, or stop (off until the phone asks)
v s r …      the phone's sound report, once a second: received, late, lost, buffer depth…
```

The host releases every held key and button when a phone disconnects.

Screen frames travel the other way as binary messages inside the same channel: a plaintext
whose first byte is 0x00 (a text line never starts with one) carries one HEVC or H.264 frame
with its size, timestamp and, on keyframes, the codec's parameter sets (`ScreenPacket` in
`SecureChannel.swift`). A host that can't stream answers with a text line `screen denied`
(Screen Recording not allowed) or `screen error <why>`. The phone acknowledges every frame;
when the oldest unacknowledged frame is more than 80 ms old the host skips capturing until
it clears, which costs no keyframe. Frames already encoded are dropped only as a last resort,
followed by a keyframe to resync.

**Frames over UDP.** TCP waits for every lost packet, so one lost packet on Wi-Fi freezes the
picture until the retransmit lands. Once paired, the phone also opens a UDP flow to the host's
port and sends it a `hello`; from then on frames go out as datagrams of at most 1200 bytes,
each frame split into chunks with one XOR parity chunk per group (5 data chunks per parity
normally, down to 2 while the phone reports losses), so a single lost packet per group costs
nothing and a worse loss costs one frame, never a stall. Datagrams are sealed with AES-256-GCM
under a key derived from the session key (`HKDF(sessionKey, "couchpad v2 video")`), carry an
8-byte stream id (`HKDF(sessionKey, "couchpad v2 video id")`) in the clear so the host knows
which session they belong to, use the sequence number as the nonce, and are only accepted from
the address the TCP session came from; receivers keep a 64-wide replay window. The phone
acknowledges over UDP too, reports frames it had to give up on (`v l`), on which the host
sends a keyframe, adds parity and lowers the bitrate for a while, and asks for TCP again
(`v t`) if datagrams stop for two seconds (the host pings while the screen is still). Before
giving a frame up, the phone asks for its missing chunks by number (a `nack` datagram) and
holds the frames behind it for up to 100 ms; the host re-sends them from a short history,
re-sealed with fresh sequence numbers, ahead of new frames. The host also paces datagrams at
a few times the bitrate rather than firing a frame as one burst, which Wi-Fi tends to drop
whole. Where UDP is blocked, nothing changes: frames simply stay on TCP. The exact layout is
documented at the bottom of `Shared/SecureChannel.swift`. Windows ignores all of this for
now.

**Sound.** While a phone has the picture and asks for sound (`v s 1`), the host captures the
Mac's audio along with the screen (ScreenCaptureKit, Couchpad's own sound left out). It
encodes the audio as Opus, 48 kHz stereo at 128 kbps, in 10 ms packets, and sends each packet
the moment it is made.
- **Over UDP**, sound is a stream of its own. It has its own key and stream id
  (`HKDF(sessionKey, "couchpad v2 audio")` and `"couchpad v2 audio id"`), its own sequence
  numbers and its own replay window. Its datagrams go straight out instead of waiting behind
  a keyframe's paced ones. Each datagram also carries the two packets before it, so a lost
  datagram costs nothing as long as the next one arrives.
- **Over TCP**, each packet is a binary message whose second byte is 0x02 (picture frames are
  0x01).

Sound is never re-sent. The phone plays it from a small buffer that grows and shrinks with
how unevenly packets arrive. It covers a lost packet with Opus' own concealment and drops a
packet that comes too late. It holds the sound back if the sound would play ahead of the
picture. Once a second the phone reports what it got (`v s r`); the host adds that, with its
estimate of the latency, to its stats line. The wire layout is next to the picture's in
`SecureChannel.swift` (`AudioPacket`).

## Appendix C: Releasing

- **iPhone → TestFlight / App Store.** Xcode: Any iOS Device → Product → Archive → Distribute
  → App Store Connect → Upload. The build number is automatic. Listing text and App Review
  notes live in `docs/app-store-copy.md`; the privacy policy URL is the site's
  `privacy.html`. In App Review notes, explain that the Mac app is a free direct download
  (the Mac App Store sandbox forbids input injection) and cite Guideline 4.2.7 and the
  existing apps in this category.
- **Mac → direct download.** Bump `CFBundleShortVersionString` in `Mac/Info.plist`, then
  `SIGN_IDENTITY="Developer ID Application: …" Mac/release.sh` (see the script for the
  one-time `notarytool` credential setup) and `gh release create v<version> Mac/build/Couchpad-<version>.dmg`.
- **Windows → direct download.** Zip the `publish` folder from the command above and attach
  it to the same release. Unsigned builds trigger SmartScreen's "unknown publisher" warning;
  an Authenticode certificate removes it but isn't required.
