# App Store copy for Couchpad

Paste-ready. Character limits in brackets are App Store Connect's.

## Name [30]

Couchpad

## Subtitle [30]

Trackpad & keyboard for Mac/PC

## Promotional text [170]

Gaming on a Mac plugged into the TV? Leave the mouse and keyboard on the desk. Couchpad turns your iPhone into both, over Wi‑Fi, with nothing to sign up for.

## Description [4000]

Couchpad turns your iPhone into a trackpad, keyboard and game controller for your Mac or Windows PC.

It was made for one situation: the computer is plugged into the TV, you're on the couch across the room, and you don't want a mouse and keyboard on your lap. Open Couchpad, and your phone is both.

HOW IT WORKS
Install the free companion app on your computer (couchpad site, link below). Couchpad finds it on your Wi‑Fi by itself. Pair once by scanning the QR code it shows, and you're in. Everything stays on your local network: no account, no servers, no cloud.

TRACKPAD
• One finger moves the pointer, tap to click, two-finger tap to right-click
• Two fingers scroll, tap-then-hold to drag
• Three-finger swipes open Mission Control, App Exposé and switch Spaces
• Left and right mouse buttons you can hold while you move
• Pointer and scroll speed, natural scrolling and tap-to-drag are adjustable

KEYBOARD
• The regular iPhone keyboard, typing straight to the computer
• The keys a phone doesn't have, one tap away on the ⌘ button: esc, tab, fn, ⌘, ⌥, ⌃, ⇧ and F1–F12
• Modifiers toggle and stay held, so ⌘C, ⌥Tab and friends just work
• Keys stay down while your finger does, so holding works in games

ON-SCREEN CONTROLLER
Tap the d-pad button and the bottom of the phone becomes a gamepad, like a hand-held console under the trackpad:
• An 8-way stick on the left; diagonals press two keys at once
• A B X Y on the right, and seven programmable keys above them
• Every key shows what it does: any keyboard key, left click, right click, or nothing
• Presets for FPS games (WASD + mouse look), MapleStory and arrow-key games
• Haptics on every press, and a finger can slide from key to key
• Upright it takes the bottom half of the screen; sideways it is a short band under the picture
• The keyboard button swaps it for the iPhone keyboard and back

BUILT FOR GAMES
Pointer movement is sent as raw mouse motion, which is what games use for camera look, and keys are sent as real presses that stay held. Menus, strategy, shooters, platformers, launchers, Steam Big Picture: anything that takes keyboard and mouse, from the couch.

CONTROLLERS
Plug a Backbone into the phone, or pair a Bluetooth controller to it, and Couchpad forwards it to the computer as keys and mouse, with the same bindings as the on-screen controller. Every button and stick direction is bindable.

PRIVATE BY DESIGN
Couchpad collects no data. It asks for Local Network access to find your computer and for the camera only when you scan a pairing code. Only phones you've paired can send input, and you can forget a phone from the computer at any time.

OPEN SOURCE
The whole thing, including the Mac and Windows apps, is MIT-licensed on GitHub.

REQUIREMENTS
A Mac (macOS 13 or later) or a Windows 10/11 PC running the free Couchpad companion app, on the same Wi‑Fi network as your iPhone. Get it at https://sebastianvidal.github.io/couchpad/

## Keywords [100]

remote,mouse,touchpad,wireless,mac,pc,windows,tv,couch,controller,gamepad,cursor,wifi,gaming,steam

(98 characters. Don't repeat the app name or words already in the subtitle; Apple indexes those separately.)

## What's New (1.2)

- On-screen controller: tap the d-pad button in the bar for a stick, A B X Y and seven programmable keys under the picture or trackpad, like a hand-held console. Upright it takes the bottom half of the screen, sideways a short band under the picture, and on a half-open iPhone Duo the flat half. Same bindings and presets as a physical controller (FPS, MapleStory, Arrows); every key shows what it does.
- The ⌘ button in the bar opens the key row (F1–F12, esc, tab, fn and the modifiers) above the controller, or under the picture or trackpad when the controller is off.
- The keyboard button swaps the controller for the iPhone keyboard and back.
- The old strip of arrow keys and space is gone: arrows come from the controller's bindings, space from the iPhone keyboard.
- Works with Mac and Windows. With the Mac's picture on, update the Mac companion to 1.5 for a smooth picture while a game is fullscreen.

## What's New (1.1)

- See your Mac's screen on the phone: tap the display icon and the picture fills the trackpad, which keeps working as a trackpad. A compact row of F keys, esc, tab and the modifiers docks under the picture, one tap away. Needs the Mac companion 1.2.
- iPhone Duo: layouts for folded, unfolded and half-open, with the picture on the upright half and the trackpad on the flat one.
- Keys roll under a sliding finger; hold one and slide to the next.
- Smoother streaming on Wi-Fi: lost packets cost a frame at most, never a freeze.

## What's New (1.0)

First release: trackpad, keyboard, three-finger gestures, QR pairing, Mac and Windows companions.

## Category

Primary: Utilities · Secondary: Productivity

## Support URL

https://sebastianvidal.github.io/couchpad/

## Privacy Policy URL

https://sebastianvidal.github.io/couchpad/privacy.html

## App Review notes

Couchpad is a trackpad/keyboard remote for the user's own computer on the local network, in the same category as Remote Mouse, Mobile Mouse and Unified Remote (App Store Review Guideline 4.2.7, remote desktop clients for user-owned computers on a local network).

Like those apps, it needs a free companion on the computer, because macOS requires Accessibility permission on the Mac itself to inject input; that cannot be done from an iPhone alone and the companion cannot be distributed through the Mac App Store (sandbox). The companion is free, open source and linked from the app's first-run screen: https://sebastianvidal.github.io/couchpad/

To test:
1. On a Mac on the same Wi‑Fi as the test iPhone, download and open the companion from the link above and grant Accessibility when asked.
2. Open Couchpad on the iPhone. It finds the Mac automatically and shows a pairing screen.
3. Click the cursor icon in the Mac's menu bar → "Pairing code" and scan the QR with the Scan button (or type the 6 digits).
4. Move a finger on the trackpad area: the Mac pointer moves. Type on the keyboard: text appears on the Mac.

Without a companion, the app still launches and offers the setup guide and gesture reference; it cannot do more by nature, as with the other apps in this category.

No account, no login, no data collection. The Local Network permission is used only for Bonjour discovery and the direct connection; the camera only for the pairing QR.

A demo video: <add link>

## TestFlight — Beta App Description

Couchpad turns your iPhone into a trackpad and keyboard for your Mac or Windows PC over Wi‑Fi — made for a computer plugged into the TV and you on the couch.

You'll need the free companion app on the computer, from https://sebastianvidal.github.io/couchpad/. Open it, grant Accessibility on the Mac (or allow it through the firewall on Windows), then open Couchpad on your phone: it finds the computer by itself. Pair once by scanning the QR code from the computer's menu-bar or tray icon.

Everything stays on your local network. No account, no data collected.

## TestFlight — What to Test (build 1)

• Pairing: does the phone find your computer without typing anything? Does the QR scan work first try?
• Trackpad feel: pointer speed, tap-to-click, two-finger scroll, tap-then-hold drag. Adjust in Settings (gear) if it's off and tell me what you changed.
• Keyboard: type a sentence into any app. Try ⌘ + letter shortcuts using the key row (⌘ button in the bar).
• Three-finger swipe up for Mission Control.
• Leave the app, come back: it should reconnect within a couple of seconds without asking for the code again.
• Games: turn on the on-screen controller (d-pad button in the bar), pick a preset in Settings → Controller → Bindings; tell me which games worked and which didn't.

Report problems at https://github.com/sebastianvidal/couchpad/issues or via the TestFlight feedback button.

## Screenshots

Two sets, same five images, in upload order:
- `docs/screenshots/01…05.png` — 1320×2868, for the **large display** (6.9") slot.
- `docs/screenshots/6.3/01…05.png` — 1206×2622, for the **medium display** (6.1"/6.3") slot,
  which is the tab App Store Connect shows first.

Regenerate with `python3 Tools/compose-screenshots.py <raw captures> <out dir> large|medium`
(raw captures: `xcrun simctl io 'iPhone 16 Pro Max' screenshot name.png`).

iPhone Duo set, `docs/screenshots/duo/`: outer display 1398×2034 (`duo-outer-*`, portrait
and landscape) and inner display 2007×2853 (`duo-inner-*`, portrait, landscape, landscape
with the keyboard up). Regenerate with `python3 Tools/compose-duo.py <raw captures> <out dir>`;
raw captures come from the Duo simulator, one display at a time:
`xcrun simctl io <duo udid> screenshot --display=1 outer.png` (`--display=3` for the inner one).

## Export compliance

`ITSAppUsesNonExemptEncryption = NO` and no App Encryption Documentation upload. Reason: all
cryptography is Apple's own (CryptoKit: P-256 key agreement, HKDF-SHA256, AES-256-GCM,
HMAC-SHA256), used to encrypt a local-network connection; no proprietary or third-party
cipher code ships in the app. That is the "encryption within Apple's operating system"
category, which is exempt. Revisit if a crypto library is ever vendored into the iOS app.
