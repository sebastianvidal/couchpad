import SwiftUI

struct ContentView: View {
    @StateObject private var client = Client()
    @StateObject private var settings = AppSettings()
    @StateObject private var inputState = InputState()
    @StateObject private var controller = ControllerBridge()
    @StateObject private var screen = ScreenReceiver()
    /// Size of the trackpad area in pixels, which is the picture size we ask the host for.
    /// With the picture on and the keyboard up it is the pane's size with the keyboard down
    /// (see `screenBody`), so the stream keeps its size.
    @State private var trackpadPixels = CGSize.zero
    /// The picture's pane's height with the keyboard down, and the window it was measured
    /// in: the keyboard pushes the picture up rather than shrinking it, and this is the size
    /// it keeps (`ScreenGeometry.KeyboardPush`). Measured rather than worked out from the
    /// keyboard's height, because rows come and go with the keyboard too (the key row docks
    /// above it in the overlay layout, the pad band goes, upright the pad gives way to it).
    @State private var restingPaneHeight: CGFloat = 0
    @State private var restingPaneWindow = CGSize.zero
    /// The last `v 1` actually sent (width and height in pixels) and the window it was sent
    /// in, so that a resize that needs no bigger picture asks for nothing (`syncScreen`).
    /// In a box, like `resizeSettle`, so that remembering it is no state change.
    @State private var lastScreenRequest = RequestBox()
    /// The picture's pane's last measured size (`measurePane`).
    @State private var paneSize = SizeBox()

    @State private var showSettings = false
    @State private var pairingCode = ""
    /// Settings → Connection → "Add a computer by address…".
    @State private var showAddAddress = false
    @State private var newAddress = ""
    @AppStorage("hasSeenSetup") private var hasSeenSetup = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    /// The window's full size (safe areas and keyboard included), measured from the root.
    /// Layout follows its shape, not the size class: on an unfolded iPhone Duo the vertical
    /// size class stays regular sideways, yet the space is wide and wants the sideways layout.
    @State private var windowSize = CGSize.zero
    private var isLandscape: Bool { windowSize.width > windowSize.height }
    /// The window's safe-area insets, as the system reports them (before `panelEdges` is applied).
    @State private var safeInsets = EdgeInsets()
    @State private var showSetup = false
    @State private var showScanner = false
    /// A foldable held half open: the picture goes on the half that stands up, the controls
    /// on the half lying flat. Reported by the system; always false elsewhere.
    @State private var hingePartlyOpen = false
    /// How far the picture is pinched in and shifted; owned by the trackpad's gesture.
    @State private var screenZoom: CGFloat = 1
    @State private var screenPan = CGPoint.zero
    /// Waits for a pinch to settle before asking the host for a sharper (or coarser) stream.
    @State private var zoomSettle: Task<Void, Never>?
    /// Waits for the picture's pane to stop changing size before asking for a stream of it.
    /// In a box, not state of its own: the pane reports its size while the picture view is
    /// being put in, and a state change at that moment made SwiftUI build the picture view
    /// a second time and throw one of the two away.
    @State private var resizeSettle = TaskBox()
    /// When the keyboard was last asked up or down: a window that changes height just after
    /// is iOS making room for it (split view), and the layout follows with the keyboard.
    @State private var keyboardToggledAt = Date.distantPast
    /// Top edge of the iOS keyboard in landscape (window coordinates), measured the first
    /// time it appears and remembered per window size, so the layout can end exactly where
    /// it begins. Keyed by size because a foldable has two displays with different keyboards.
    @AppStorage("landscapeKeyboardTops") private var landscapeKeyboardTops = ""
    /// The smallest keyboard height iOS has reported per window size: half open, it first
    /// announces the keyboard at its real height, then re-reports it as the whole bottom
    /// segment with the keys drawn somewhere inside. The real height places the keys.
    /// Remembered across launches: the first announcement does not always come (seen on the
    /// simulator when the keyboard was asked for in the same instant the layout changed).
    @AppStorage("keyboardHeights") private var keyboardHeightsJSON = ""

    var body: some View {
        Group {
            if hingeLayout {
                hingeBody
            } else if screenOn, client.isConnected {
                screenBody
            } else if isLandscape {
                landscapeBody
            } else {
                portraitBody
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        // Keyboard avoidance is applied at the root, so it has to be switched off here:
        // nothing moves for the keyboard and every layout insets itself by hand instead
        // (`keyboardInset`), inside the same animation as the rest of the layout, so the pad
        // giving way and the bar riding up are one motion. Avoidance did it in a step of its
        // own when the keyboard went: the layout dropped, then slid back as the pad grew.
        // The keyboard is ignored whatever the state, so the switch is not made in the same
        // instant the keyboard appears (which SwiftUI did not always honour); see
        // `ignoresKeyboard` for where avoidance stays.
        .ignoresSafeArea(ignoresKeyboard ? .keyboard : [])
        .ignoresSafeArea(.container, edges: panelEdges.union(isLandscape ? .bottom : []))
        // Sideways, the layout runs into the home indicator's strip rather than leaving a
        // blank band under it; the indicator fades out of the way (a swipe still brings it back).
        .persistentSystemOverlays(isLandscape ? .hidden : .automatic)
        .background(Color(.systemBackground))
        .background(
            // The safe-area insets as the system hands them down, to tell a hidden status
            // bar's panel from hardware (see `panelEdges`). Keyboard excluded: it is not an edge.
            GeometryReader { geo in
                Color.clear.onChange(of: geo.safeAreaInsets, initial: true) { _, insets in
                    safeInsets = insets
                }
            }
            .ignoresSafeArea(.keyboard)
        )
        .background(HingeObserver(partlyOpen: $hingePartlyOpen))
        // The picture is the point of screen mode: the clock and the signal bars can go.
        // The clock and the signal bars never earn their strip here: the same full window
        // whether the picture is on or off, so nothing moves when it is toggled.
        .statusBarHidden(true)
        .background(
            // Measures the whole window, ignoring the keyboard and the safe areas, so the
            // portrait/landscape decision never flips because a keyboard came up.
            GeometryReader { geo in
                Color.clear.onChange(of: geo.size, initial: true) { old, size in
                    // In split view iOS makes the window taller for the keyboard and shorter
                    // again after it: the layout that comes with it moves with the keyboard.
                    let forKeyboard = old.width == size.width && old.height > 0
                        && Date().timeIntervalSince(keyboardToggledAt) < 1
                    withAnimation(forKeyboard ? .keyboard : nil) { windowSize = size }
                }
            }
            .ignoresSafeArea()
        )
        .onAppear {
            controller.client = client
            controller.settings = settings
            screen.client = client
            // The receiver lives as long as the view; the client's callbacks hold it plainly
            // (a weak capture here was pointless, the enclosing closure already holds it).
            client.onScreenPacket = { packet in screen.handle(packet) }
            client.onScreenStatus = { status in screen.hostMessage = status }
            client.onScreenHealth = { health in
                if screen.health != health { screen.health = health }
            }
            client.onScreenLoss = { screen.markLost() }
            client.startBrowsing()
            UIApplication.shared.isIdleTimerDisabled = true
            if !hasSeenSetup {
                showSetup = true
                hasSeenSetup = true
                inputState.suspended = true
            }
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showSetup) { SetupView() }
        .sheet(isPresented: $showScanner) {
            ScannerView { url in
                showScanner = false
                client.pair(using: url)
            }
        }
        .onOpenURL { url in client.pair(using: url) }
        .onChange(of: showSetup) { _, _ in syncKeyboardSuspension() }
        .onChange(of: showSettings) { _, _ in syncKeyboardSuspension() }
        .onChange(of: showScanner) { _, _ in syncKeyboardSuspension() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            guard let screenFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            // The frame is in screen coordinates and the layout works in the window's: they
            // differ in split view, where the window is only part of the screen.
            let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
            let frame = window.map { $0.convert(screenFrame, from: $0.screen.coordinateSpace) } ?? screenFrame
            NSLog("Keyboard frame %@ (screen %@) in window %@", NSCoder.string(for: frame), NSCoder.string(for: screenFrame), NSCoder.string(for: windowSize))
            // Keyed by window size, so each orientation and posture learns its own.
            guard frame.minY > windowSize.height * 0.3, frame.minY < windowSize.height else { return }
            var heights = keyboardHeights
            // Under 150 pt it is a hardware keyboard's shortcut bar, not the keyboard.
            if frame.height > 150 {
                heights[sizeKey] = min(heights[sizeKey] ?? frame.height, frame.height)
                if heights != keyboardHeights, let data = try? JSONEncoder().encode(heights),
                   let json = String(data: data, encoding: .utf8) {
                    keyboardHeightsJSON = json
                }
            }
            // Half open, a frame far taller than the keyboard itself is the fold's bottom
            // segment: the keys sit centred in it (measured: 327 pt of keys in a 495 pt frame
            // on the device; 311 pt reported, keys drawn from about y 550, on the simulator).
            let real = heights[sizeKey] ?? frame.height
            let top = hingePartlyOpen && frame.height > real + 40 ? frame.minY + (frame.height - real) / 2 : frame.minY
            var tops = keyboardTops
            tops[sizeKey] = top
            if let data = try? JSONEncoder().encode(tops), let json = String(data: data, encoding: .utf8) {
                landscapeKeyboardTops = json
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            // iOS can put the keyboard away by itself (a posture change, the keyboard's own
            // dismiss key, another field taking over). Then nothing is typing any more, and
            // the typing layout (the key row where the pad was, the hand inset) must go too,
            // or the pad and the hinge split never come back. Checked a moment later: when a
            // layout change hands the keyboard from one bar's field to the next, the new
            // field takes it within a run-loop turn and nothing has gone away.
            guard inputState.keyboardShown, !inputState.suspended else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if inputState.keyboardShown, !inputState.suspended, !KeyInputUIView.ownsKeyboard {
                    withAnimation(.keyboard) { inputState.keyboardShown = false }
                }
            }
        }
        .onChange(of: windowSize, initial: true) { old, new in
            // The iOS keyboard starts hidden in every layout and comes up on demand (the bar's
            // keyboard button, or the key row's): sideways it would cover half the screen,
            // and upright the trackpad, the picture or the pad is the point. So a rotation
            // puts it away. `initial: true` covers launching already sideways.
            // A rotation swaps the width and the height. A window that only grew or shrank
            // in height did not turn: in split view (an app above, Couchpad below) iOS makes
            // the window taller to fit the keyboard under it, which turns the wide window
            // into a tall one and back again when the keyboard goes. Taken for a rotation,
            // that put the keyboard away the moment it came up, every time.
            let turned = (old.width > old.height) != (new.width > new.height) && old.width != new.width
            guard old == new || turned else { return }
            inputState.keyboardShown = false
        }
        .onChange(of: screenOn) { _, _ in
            inputState.keyboardShown = false
            resetZoom()
        }
        .onChange(of: settings.showController, initial: true) { _, on in
            // The pad's loop runs for as long as the setting is on, whichever layout is
            // showing it: tied to a view's appearance it died on every rotation.
            controller.setVirtualShown(on)
            // Thumbs on the controller: the iOS keyboard would only be in the way; without
            // it, the trackpad gets its full height until the keyboard is asked for.
            inputState.keyboardShown = false
        }
        .onChange(of: screen.videoSize) { _, size in
            if size == .zero { resetZoom() }   // the stream stopped; the next picture starts at 1×
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background: controller.releaseAll(); client.appDidEnterBackground(); screen.reset()
            case .active: client.appDidBecomeActive()
            default: break
            }
        }
        .onChange(of: client.phase) { _, _ in syncScreen() }
        .onChange(of: settings.showScreen) { _, _ in syncScreen() }
        .onChange(of: settings.screenSound) { _, on in
            // Sound only ever plays with the picture; without it, the next `v 1` brings it along.
            if client.isConnected, screenOn, trackpadPixels.width > 0 { client.setSound(on) }
        }
        .onChange(of: trackpadPixels) { old, new in
            // While the layout moves (the keyboard coming or going, the pad giving way) the
            // pane changes size in steps; the picture scales along, and the host is asked for
            // the new size once, when it has settled, rather than restarting its stream at
            // every step. The first size (the picture appearing) goes out at once.
            resizeSettle.task?.cancel()
            guard old.width > 0, new.width > 0 else { syncScreen(); return }
            resizeSettle.task = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                syncScreen(resized: true)
            }
        }
        .onChange(of: inputState.keyboardShown) { _, _ in keyboardToggledAt = Date() }
        .onChange(of: settings.screenQuality) { _, _ in syncScreen() }
        .onChange(of: screenZoom) { _, _ in
            // Zoomed in, the pane's pixels are spread thin: once the fingers settle, ask for
            // a stream with that many more pixels (the host caps it at the display's own).
            zoomSettle?.cancel()
            zoomSettle = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                syncScreen()
            }
        }
    }

    /// The picture is only offered by Macs for now; the setting is remembered regardless.
    private var screenAvailable: Bool { client.hostPlatform == .mac }
    private var screenOn: Bool { settings.showScreen && screenAvailable }
    /// Half open with the picture on, split at the hinge (typing too, see `hingeBody`).
    private var hingeLayout: Bool {
        screenOn && client.isConnected && hingePartlyOpen
    }

    /// Whether the root ignores the keyboard and the layouts inset themselves for it
    /// (`keyboardInset`). Always sideways and half open. Upright too, except in two cases
    /// where keyboard avoidance stays, as it was before upright went by hand:
    /// - the pairing prompt is showing: its code field brings up a number pad of its own,
    ///   which `keyboardShown` knows nothing about, and avoidance keeps the field above it
    ///   (the phase is entered long before that keyboard appears, so the switch is never
    ///   made while a keyboard comes up);
    /// - split view: iOS resizes the window around the keyboard (see the `windowSize`
    ///   onChange), and avoidance inside the resized window is what was tested there.
    /// Whether the window is the whole screen. In split view (another app above or below)
    /// iOS resizes the window around the keyboard, and the layout leaves that to keyboard
    /// avoidance upright, as it always has (`ignoresKeyboard`). Worked out when asked, not
    /// kept as state: one more state change in the middle of a rotation is one more chance
    /// for a stale layout step.
    private var windowFillsScreen: Bool {
        guard let screen = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.screen.bounds.size,
              windowSize != .zero else { return true }
        // Either way round: the screen's bounds turn with the interface, a moment apart.
        let same = abs(screen.width - windowSize.width) < 1 && abs(screen.height - windowSize.height) < 1
        let turned = abs(screen.width - windowSize.height) < 1 && abs(screen.height - windowSize.width) < 1
        return same || turned
    }

    private var ignoresKeyboard: Bool {
        if isLandscape || hingePartlyOpen { return true }
        let pairing = client.phase == .needsCode || client.phase == .wrongCode
        return windowFillsScreen && !pairing
    }

    /// How far a layout ends above its bottom edge so its last row sits 8pt above the iOS
    /// keyboard. Only where the root ignores the keyboard (`ignoresKeyboard`); elsewhere
    /// keyboard avoidance has already shrunk the layout. Half open upright, iOS reports the
    /// keyboard as the whole bottom segment (the keys sit inside it), so avoidance would
    /// leave a blank band above the keys: the inset goes to where the keys were measured
    /// to start instead (`keyboardTops`). Before the first measurement for a window size the
    /// keyboard is taken to be 40% of the layout's height (about what it is upright and
    /// sideways on the Duo), corrected as soon as iOS announces it.
    private func keyboardInset(_ geo: GeometryProxy) -> CGFloat {
        guard inputState.keyboardShown, ignoresKeyboard else { return 0 }
        let bottom = geo.frame(in: .global).maxY
        let keyboardTop = keyboardTops[sizeKey] ?? (bottom - geo.size.height * 0.40)
        return max(0, bottom - keyboardTop + 8)   // 8pt of air above the keyboard, like every other gap
    }

    /// Safe-area edges the layout takes for itself. The iPhone Duo keeps its status bar in a
    /// panel along one long edge (84pt on the folded display), and that panel stays reserved
    /// after `statusBarHidden` empties it, leaving a black band beside the trackpad. An inset
    /// on one horizontal edge with none on the other is that panel: nothing is in it any
    /// more, so the layout spreads into it. A notch or Dynamic Island insets both sides alike
    /// and is never touched; so is the top edge (the bottom one is taken sideways, see `body`).
    private var panelEdges: Edge.Set {
        if safeInsets.leading > 0, safeInsets.trailing == 0 { return .leading }
        if safeInsets.trailing > 0, safeInsets.leading == 0 { return .trailing }
        return []
    }

    /// Tells the host whether we want its screen and at what size. Called whenever the
    /// connection, the setting or the trackpad's size changes; the host restarts the stream
    /// only when the size actually changed. The sound goes with the picture: every `v 1` is
    /// followed by the sound setting, and `v 0` (or no connection) stops it too.
    /// `resized`: the pane settled at a new size in the same window (the pad, the key row
    /// or the keyboard coming or going). Then nothing is sent unless the picture needs more
    /// pixels than the last request gives, by more than 1%: the host fits its display into
    /// the size asked for, and every new size is a stream restart (the picture stops, the
    /// Mac's screen-sharing icon flickers). A pane that shrank keeps the bigger stream,
    /// scaled down on the phone, until the next rotation, fold or reconnect asks for its
    /// exact size; a new window always sends.
    private func syncScreen(resized: Bool = false) {
        guard client.isConnected else {
            lastScreenRequest.size = nil
            screen.reset()
            client.setSound(false)
            return
        }
        if screenOn, trackpadPixels.width > 0 {
            let share = [0.5, 2.0 / 3.0, 1.0][max(0, min(2, settings.screenQuality))]
            // 60 fps: a change waits half as long for the next capture, and the phone's
            // display shows it on the next refresh. Bandwidth roughly doubles; still a few Mbps.
            let pixels = share * Double(screenZoom)
            let request = CGSize(width: Int(trackpadPixels.width * pixels), height: Int(trackpadPixels.height * pixels))
            // Compared with the last request sent, not the last one skipped, so small
            // steps cannot add up to a picture that no longer fits.
            if resized, let last = lastScreenRequest.size, lastScreenRequest.window == windowSize,
               ScreenGeometry.needsNoMore(screen.videoSize, in: request, than: last) {
                return
            }
            lastScreenRequest.size = request
            lastScreenRequest.window = windowSize
            client.send("v 1 \(Int(request.width)) \(Int(request.height)) 60")
            client.setSound(settings.screenSound)
        } else {
            lastScreenRequest.size = nil
            client.send("v 0")
            client.setSound(false)
            screen.reset()
        }
    }

    /// The trackpad forgets its pinch on its own when the picture goes (TrackpadUIView.resetZoom).
    private func resetZoom() {
        screenZoom = 1
        screenPan = .zero
    }

    private var keyboardTops: [String: Double] {
        guard let data = landscapeKeyboardTops.data(using: .utf8),
              let tops = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return tops
    }

    private var keyboardHeights: [String: CGFloat] {
        guard let data = keyboardHeightsJSON.data(using: .utf8),
              let heights = try? JSONDecoder().decode([String: CGFloat].self, from: data) else { return [:] }
        return heights
    }

    private var sizeKey: String { "\(Int(windowSize.width))x\(Int(windowSize.height))" }

    /// Taller keys on a wide portrait window (an unfolded iPhone Duo), so they keep roughly
    /// the proportions they have on a phone instead of turning into flat bars.
    private var portraitRowHeight: CGFloat {
        let unit = (windowSize.width - 16 - 6 * 4) / 7
        return min(58, max(42, unit * 0.65))
    }

    /// Same skeleton as the screen layout: the trackpad, the key row under it (while the
    /// bar's ⌘ button has it on), the bar, 6pt apart, so toggling the picture moves nothing.
    /// With the pad on, the pad (with the key row at its top) takes the bottom half instead.
    /// Arrows and space come from the pad's bindings or the iOS keyboard.
    /// The root ignores the keyboard (`ignoresKeyboard`), so the layout ends above it by
    /// hand (`keyboardInset`) and the trackpad gives up the room; in split view and with the
    /// pairing prompt up, keyboard avoidance shrinks it instead and the inset is zero.
    private var portraitBody: some View {
        GeometryReader { geo in
            let inset = keyboardInset(geo)
            VStack(spacing: 6) {
                trackpad
                if padOnScreen {
                    portraitPad(height: geo.size.height - inset - 36 - 6)
                } else if keyRowDocked {
                    keyRow
                }
                bar(picture: false)
            }
            .padding(.bottom, inset)
        }
        .padding(.top, 4)
    }

    /// Upright, the pad gets the bottom half of what is above the bar (`available`) and
    /// fills it like the flat half of a half-open Duo: keys key-shaped, the room left over
    /// going to the stick and the air around it; the picture or trackpad gets the top half.
    /// While the iOS keyboard is up the pad is only the key row, sized as it always was.
    private func portraitPad(height available: CGFloat) -> some View {
        let typing = inputState.keyboardShown
        return ControllerView(controller: controller, client: client, state: inputState,
                              rowHeight: typing ? portraitRowHeight : nil, showKeys: settings.showKeyRow)
            .frame(height: typing ? nil : max(0, (available - 6) / 2))
    }

    /// The screen layout's skeleton without the picture: the trackpad full width, the key
    /// row under it (when on), then the bar; with the pad on, a short band under the
    /// trackpad instead, or (`padOverlaid`) the pad over the trackpad, the key row with it,
    /// so the trackpad keeps the whole height above the bar.
    /// Nothing here moves for the keyboard: the whole body ignores it, and instead everything
    /// is inset by the keyboard's height while it is up, so the trackpad shrinks and the row
    /// and the bar sit just above the keyboard (as in the screen layout).
    private var landscapeBody: some View {
        GeometryReader { geo in
            let inset = keyboardInset(geo)
            let above = geo.size.height - inset - 36 - 6   // what is left over the bar and its gap
            VStack(spacing: 6) {
                trackpad.overlay { overlaidPad }
                if padOnScreen {
                    // Sideways the pad is a short band under the trackpad, thumbs at the
                    // bottom corners, rather than a column beside it.
                    ControllerView(controller: controller, client: client, state: inputState, rowHeight: wideRowHeight(above), wide: true, showKeys: settings.showKeyRow)
                } else if keyRowDocked {
                    keyRow
                }
                bar(picture: false)
            }
            .padding(.bottom, inset)
        }
        .padding(.top, 4)
    }

    // MARK: Half-open foldable

    /// Split at the hinge, which runs across the middle of the window's long side: the
    /// picture on one half, the controls (a plain trackpad with the key row, or the pad)
    /// and the bar on the other. Upright (hinge horizontal, laptop-style) the picture is the
    /// top half; sideways (hinge vertical, like a book) the picture is on the side opposite
    /// the trackpad. Upright while typing, the iOS keyboard takes the flat half and the bar
    /// heads it, above the keys; the key row (when on) floats over the picture instead.
    private var hingeBody: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let gap: CGFloat = 24   // keeps touches and the picture's edge off the crease
            if isLandscape {
                let inset = keyboardInset(geo)
                let hingeX = windowSize.width / 2 - frame.minX
                HStack(spacing: 0) {
                    if settings.trackpadOnRight {
                        pictureHalf.frame(width: hingeX - gap / 2)
                        Spacer().frame(width: gap)
                        hingeControls(inset: inset)
                    } else {
                        hingeControls(inset: inset)
                        Spacer().frame(width: gap)
                        pictureHalf.frame(width: geo.size.width - hingeX - gap / 2)
                    }
                }
            } else {
                let hingeY = windowSize.height / 2 - frame.minY
                VStack(spacing: 0) {
                    pictureHalf.frame(height: hingeY - gap / 2)
                    Spacer().frame(height: gap)
                    // The root ignores the keyboard half open and nothing here insets for
                    // it: typing, the bar is pinned to the top of the flat half and iOS
                    // draws the keys in the lower part of that segment, below it.
                    hingeControls(inset: 0)
                }
            }
        }
        .padding(.top, 4)
    }

    /// Typing upright half open: the keyboard has the flat half, which keeps only the bar;
    /// the key row is a card over the picture while the bar's ⌘ button has it on.
    private var hingeTypingUpright: Bool { hingeLayout && inputState.keyboardShown && !isLandscape }

    /// The half that stands up: the picture, with the floating key row over its bottom
    /// while typing upright, when the bar's ⌘ button has the row on.
    private var pictureHalf: some View {
        trackpad
            .overlay(alignment: .bottomTrailing) {
                if hingeTypingUpright, settings.showKeyRow {
                    KeyStripView(client: client, state: inputState, rowHeight: portraitRowHeight)
                        .padding(8)
                        .frame(width: min(420, windowSize.width - 48))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                        .padding(10)
                }
            }
    }

    /// The flat half: a big trackpad with the key row under it, or the pad, then the bar.
    /// Typing upright, only the bar, at the top. The bar keeps its place in the stack
    /// either way, so its keyboard field is not swapped for another.
    private func hingeControls(inset: CGFloat) -> some View {
        VStack(spacing: 6) {
            if hingeTypingUpright {
                EmptyView()
            } else if settings.showController, inputState.keyboardShown {
                // Sideways while typing: the same fixed-height key row as upright, pushed
                // down to sit just above the keyboard with the bar. Filling what the
                // keyboard leaves would centre the row in the column instead.
                Spacer(minLength: 0)
                if padOnScreen {
                    ControllerView(controller: controller, client: client, state: inputState, rowHeight: portraitRowHeight, showKeys: settings.showKeyRow)
                }
            } else if settings.showController {
                // Picture on one half, pad on the other: a hand-held console. Upright the
                // flat half is wide and short; sideways it is a narrow column.
                ControllerView(controller: controller, client: client, state: inputState, wide: !isLandscape, showKeys: settings.showKeyRow)
            } else {
                trackpadPane(picture: false)
                if keyRowDocked { keyRow }
            }
            bar(picture: true)
            if hingeTypingUpright { Spacer(minLength: 0) }
        }
        .padding(.bottom, inset)
    }

    // MARK: Screen layout

    /// With the Mac's picture on, the picture gets the whole window but the key row docked
    /// under it (when on) and one slim bar; the iOS keyboard is summoned from the bar. The
    /// root ignores the keyboard upright too (`ignoresKeyboard`), so everything is inset by
    /// hand for the row and the bar to sit just above it; in split view and while pairing,
    /// keyboard avoidance at the root shrinks the layout instead. Either way the pane gets
    /// shorter, but the picture does not shrink with it: it keeps its keyboard-down size and
    /// is pushed up (`keyboardPushes`), its bottom just above the key row or bar and its top
    /// cut off once the pane is shorter than it, and moving a pinch looks at the rest. Shrunk
    /// into the strip above the keyboard it was too small to read, and every keyboard toggle
    /// restarted the stream at a new size.
    private var screenBody: some View {
        GeometryReader { geo in
            let inset = keyboardInset(geo)
            let availableHeight = geo.size.height - inset - 36 - 6
            VStack(spacing: 6) {
                // Sideways with "Pad over the picture" on, the pad (and the key row with it)
                // floats over the picture, which keeps the whole height (`padOverlaid`).
                trackpadPane(picture: true, keyboardPushes: true, keyboardInset: inset).overlay { overlaidPad }
                if padOnScreen {
                    // Otherwise the pad never floats over the picture: the picture gives up the
                    // room. Upright it takes the bottom half (a Game Boy); sideways, a short band under it.
                    if isLandscape {
                        ControllerView(controller: controller, client: client, state: inputState, rowHeight: wideRowHeight(availableHeight), wide: true, showKeys: settings.showKeyRow)
                    } else {
                        portraitPad(height: availableHeight)
                    }
                } else if keyRowDocked {
                    keyRow
                }
                bar(picture: true)
            }
            .padding(.bottom, inset)
        }
        .padding(.top, 4)
    }

    /// The dot in the bar: green while connected (and, with the picture on, while the host
    /// says the stream is healthy), yellow while the stream is struggling (late acks, frames
    /// lost, captures skipped), orange when not connected. Status text, stream numbers and
    /// the list of Macs are in the dot's menu.
    private var streamDotColor: Color {
        guard client.isConnected else { return .orange }
        return screen.health?.ok == false ? .yellow : .green
    }

    /// The one bar every layout ends with (half open, on the flat half), picture on or off,
    /// so every control keeps its place: the dot, the screen toggle, the key row (⌘) and
    /// keyboard toggles, the pad toggle, the mouse buttons, the controller mark, (picture and pad off,
    /// sideways or not connected) the setup guide, and settings.
    private func bar(picture: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                Section {
                    Text(client.status)
                    if let health = screen.health {
                        Text(health.summary)
                        if health.phones > 1 {
                            Label("\(health.phones) phones connected", systemImage: "exclamationmark.triangle")
                        }
                    }
                }
                // In the menu rather than the bar: the bar has no room, and sound is set once
                // and left, unlike the picture.
                if picture, screenAvailable, client.isConnected {
                    Button {
                        settings.screenSound.toggle()
                    } label: {
                        Label(settings.screenSound ? "Mute the Mac's sound" : "Play the Mac's sound",
                              systemImage: settings.screenSound ? "speaker.slash" : "speaker.wave.2")
                    }
                }
                // The drop-down of saved computers: picking one connects to it, and only to it.
                if !client.devices.isEmpty {
                    Picker("Computer", selection: Binding(
                        get: { client.currentDeviceID },
                        set: { if let id = $0 { client.select(id) } }
                    )) {
                        ForEach(client.devices) { device in
                            Text(device.displayName).tag(Optional(device.id))
                        }
                    }
                    .pickerStyle(.inline)
                }
                // Computers on the network this phone hasn't paired with: one tap to pair.
                let nearby = client.nearbyServices
                if !nearby.isEmpty {
                    Section("Nearby") {
                        ForEach(nearby) { service in
                            Button(service.name) { client.connect(to: service) }
                        }
                    }
                }
                if client.devices.isEmpty, nearby.isEmpty { Text("No computers found yet") }
                if let name = controller.controllerName {
                    Label(name, systemImage: "gamecontroller.fill")
                }
            } label: {
                Circle()
                    .fill(streamDotColor)
                    .frame(width: 9, height: 9)
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity)
            }
            .accessibilityLabel(screen.health.map { "\(client.status). Stream \($0.ok ? "healthy" : "struggling"): \($0.summary)" } ?? client.status)
            if screenAvailable, client.isConnected {
                barButton(picture ? "display.2" : "display",
                          label: picture ? "Hide the computer's screen" : "Show the computer's screen") {
                    settings.showScreen.toggle()
                }
            }
            // The key row, everywhere at once: docked under the trackpad or picture, at the
            // top of the pad, over the picture with the overlaid pad, or (half open upright
            // while typing) floating over the picture on a card.
            barButton(settings.showKeyRow ? "command.square.fill" : "command.square",
                      label: settings.showKeyRow ? "Hide key row" : "Show key row") {
                settings.showKeyRow.toggle()
            }
            // With the pad on, the iOS keyboard takes the pad's place (only its key row
            // stays, when on) until it is dismissed.
            // Both symbols are always there and only their opacity changes: the bar slides
            // with the keyboard, and a swapped symbol is a new view, drawn at once where the
            // button ends up, ahead of its button.
            Button {
                withAnimation(.keyboard) { inputState.keyboardShown.toggle() }
            } label: {
                barIcon(ZStack {
                    Image(systemName: "keyboard").opacity(inputState.keyboardShown ? 0 : 1)
                    Image(systemName: "keyboard.chevron.compact.down").opacity(inputState.keyboardShown ? 1 : 0)
                })
            }
            .buttonStyle(.plain)
            .accessibilityLabel(inputState.keyboardShown ? "Hide keyboard" : "Show keyboard")
            if client.isConnected {
                barButton(settings.showController ? "dpad.fill" : "dpad",
                          label: settings.showController ? "Hide the on-screen controller" : "Show the on-screen controller") {
                    settings.showController.toggle()
                }
            }
            mouseButtons
            // On a phone-wide window the mark would squeeze the mouse buttons to "L…" and
            // "Ri…"; the dot's menu names the controller instead.
            if controller.controllerName != nil, windowSize.width >= 500 {
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Controller connected")
            }
            // Upright and connected, the keyboard and display buttons take its room (it is in
            // Settings, and on the trackpad while not connected); it stays sideways.
            if !picture, !settings.showController, !(client.isConnected && !isLandscape) {
                barButton("questionmark.circle", label: "Setup guide") { showSetup = true }
            }
            barButton("gearshape", label: "Settings") { showSettings = true }
        }
        .frame(height: 36)
        .background(keyInput)   // zero footprint: the iOS keyboard still needs its owner on screen
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { barIcon(Image(systemName: symbol)) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func barIcon(_ icon: some View) -> some View {
        icon
            .frame(width: 44)
            .frame(maxHeight: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The key row (F bar over esc, tab, fn and the modifiers), docked under the trackpad
    /// or picture when the pad is off, or overlaid but put away by the iOS keyboard (a pad
    /// on screen has its own), and the bar's ⌘ button has it on. Upright it keeps the pad's
    /// row height; sideways, where height is short, it is a slimmer row.
    private var keyRow: some View {
        KeyStripView(client: client, state: inputState, rowHeight: isLandscape ? 36 : portraitRowHeight)
    }

    /// Sideways with "Pad over the picture" on (`AppSettings.padOverlay`), the pad and the
    /// key row are drawn over the trackpad or picture instead of in the stack under it, the
    /// key row over the pad's keys: the pane keeps the whole height above the bar. With the
    /// pad off the key row stays over the picture, where it sits with the pad. Not upright,
    /// not half open.
    private var overlayMode: Bool { settings.padOverlay && isLandscape && !hingePartlyOpen }

    private var padOverlaid: Bool { settings.showController && overlayMode }

    /// The overlay (the pad, or the key row alone) is drawn while the iOS keyboard is down.
    /// With the keyboard up it goes away entirely and the key row (when on) docks above the
    /// keyboard.
    private var overlayShown: Bool {
        overlayMode && (settings.showController || settings.showKeyRow) && !inputState.keyboardShown
    }

    /// The pad in the stack, under the trackpad or picture (or on the flat half), unless it
    /// is overlaid, or the iOS keyboard has taken its place with the key row off: then
    /// nothing is left of it, and the keyboard sits right under the bar.
    private var padOnScreen: Bool {
        settings.showController && !padOverlaid && (settings.showKeyRow || !inputState.keyboardShown)
    }

    /// The key row docked on its own, under the trackpad or picture: with the pad off, or
    /// in the overlay layout while the iOS keyboard has put the overlay away (a pad in the
    /// stack has its own row, and so does the overlay).
    private var keyRowDocked: Bool {
        settings.showKeyRow && (overlayMode ? inputState.keyboardShown : !settings.showController)
    }

    /// The pad over the trackpad or picture, filling its pane, while `overlayShown`. Outside
    /// the pane's ZStack, so pinching the picture neither moves nor scales it.
    @ViewBuilder private var overlaidPad: some View {
        if overlayShown {
            ControllerView(controller: controller, client: client, state: inputState, overlay: true,
                           overlayOpacity: settings.overlayOpacity, padHidden: !settings.showController,
                           showKeys: settings.showKeyRow)
        }
    }

    /// Row height for the wide pad band: short, so the picture keeps most of the height.
    private func wideRowHeight(_ available: CGFloat) -> CGFloat {
        min(44, max(32, available * 0.1))
    }

    private var keyInput: some View {
        KeyInputView(client: client, state: inputState)
            .frame(width: 1, height: 1)
            .opacity(0.01)
    }

    private var trackpad: some View { trackpadPane(picture: true) }

    /// The trackpad, with the Mac's picture underneath when screen mode is on and `picture`
    /// asks for it (the half-open layout shows a second, plain trackpad). The picture fills
    /// the pane and places itself (`ScreenGeometry`): letterboxed at 1×, growing into the
    /// pane as it is zoomed, so the pane's rounded shape is its outer clip. With
    /// `keyboardPushes` (only `screenBody`) the pane's keyboard-down height is measured
    /// (`restingPaneHeight`) and the picture keeps that size while the keyboard is up.
    /// `keyboardInset` is what the layout takes off for the keyboard, for when there is no
    /// measurement yet (see below).
    private func trackpadPane(picture: Bool, keyboardPushes: Bool = false, keyboardInset: CGFloat = 0) -> some View {
        let showPicture = picture && screenOn && client.isConnected
        let resting = keyboardPushes && showPicture && restingPaneWindow == windowSize ? restingPaneHeight : 0
        let keyboardDown = !inputState.keyboardShown
        return ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            if showPicture {
                ScreenView(receiver: screen, zoom: screenZoom, pan: screenPan, restingHeight: resting, keyboardUp: !keyboardDown)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            TrackpadView(client: client, settings: settings, videoSize: showPicture && settings.tapToPoint ? screen.videoSize : .zero,
                         pictureSize: showPicture ? screen.videoSize : .zero, restingHeight: resting, keyboardUp: !keyboardDown,
                         onZoom: { zoom, pan in screenZoom = zoom; screenPan = pan })
                // The pane's size from `onGeometryChange`, which reports every change with
                // the final value: an onChange on a GeometryReader's size was once handed a
                // stale step of a rotation (366 pt wide, from before the status-bar panel was
                // taken back) after the final one, and the stream was sized to it.
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    guard picture else { return }   // the stream is sized to the picture's pane
                    paneSize.size = size
                    measurePane(size, keyboardPushes: keyboardPushes, keyboardInset: keyboardInset)
                }
                // The window and the keyboard too: rotated, the pane can report its size
                // before `windowSize` has caught up.
                .onChange(of: PaneMeasure(window: windowSize, keyboardPushes: keyboardPushes, keyboardDown: keyboardDown)) { _, _ in
                    guard picture, paneSize.size != .zero else { return }
                    measurePane(paneSize.size, keyboardPushes: keyboardPushes, keyboardInset: keyboardInset)
                }
            switch client.phase {
            case .paired where showPicture && screen.videoSize == .zero:
                screenPlaceholder
            case .paired:
                EmptyView()
            case .needsCode, .wrongCode:
                pairingPrompt
            case .connecting where !client.macName.isEmpty:
                ProgressView(client.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            default:
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark").font(.title2)
                    // With a saved computer selected, the question is where it is: not on
                    // this network, and (if it has no address) nothing else to try.
                    Text(client.currentDeviceID == nil || client.macName.isEmpty
                         ? "Open Couchpad on your Mac or PC\n(same Wi-Fi)"
                         : "Can't find \(client.macName). Is Couchpad open on it?\nAway from home, give it its VPN address in Settings → Connection.")
                        .multilineTextAlignment(.center)
                        .font(.footnote)
                    // Side by side where they fit (portrait), stacked on a narrow trackpad
                    // (a folded iPhone Duo held sideways).
                    ViewThatFits(in: .horizontal) {
                        HStack { setupButtons }.fixedSize()   // report the real width, so "fits" means fits
                        VStack { setupButtons }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)   // the buttons stack rather than touch the edges
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Takes the picture's pane's size: the stream is sized to it (`trackpadPixels`), and with
    /// `keyboardPushes` its keyboard-down height is remembered for the window
    /// (`restingPaneHeight`) so the keyboard pushes the picture rather than shrinking it.
    private func measurePane(_ size: CGSize, keyboardPushes: Bool, keyboardInset: CGFloat) {
        var height = size.height
        if keyboardPushes, !inputState.keyboardShown {
            if restingPaneHeight != size.height { restingPaneHeight = size.height }
            if restingPaneWindow != windowSize { restingPaneWindow = windowSize }
        } else if keyboardPushes {
            // The keyboard is up and this window has no keyboard-down measurement (the
            // keyboard was up when the picture appeared, or came up again right after a
            // rotation): the pane plus what the layout took off for the keyboard stands in for
            // it. Off by whatever rows come and go with the keyboard, and replaced by the real
            // thing when the keyboard next goes down; without it the picture would shrink above
            // the keyboard and a keyboard-sized stream would be asked for.
            if restingPaneWindow != windowSize {
                restingPaneHeight = size.height + keyboardInset
                restingPaneWindow = windowSize
            }
            // The pane as it is without the keyboard, so the keyboard coming up asks the host
            // for nothing new.
            height = max(height, restingPaneHeight)
        }
        let pixels = CGSize(width: size.width * displayScale, height: height * displayScale)
        if trackpadPixels != pixels { trackpadPixels = pixels }
    }

    /// What to say while the picture is wanted but not arriving.
    private var screenPlaceholder: some View {
        VStack(spacing: 8) {
            if screen.hostMessage == "denied" {
                Image(systemName: "rectangle.on.rectangle.slash").font(.title2)
                Text("Allow Screen Recording for Couchpad on \(client.macName)\n(System Settings → Privacy & Security), then try again.")
                    .multilineTextAlignment(.center)
                    .font(.footnote)
                Button("Try again") { lastScreenRequest.size = nil; client.send("v 0"); syncScreen() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if let message = screen.hostMessage, message.hasPrefix("error") {
                Image(systemName: "exclamationmark.triangle").font(.title2)
                Text("\(client.macName) couldn't stream its screen: \(message.dropFirst(6))")
                    .multilineTextAlignment(.center)
                    .font(.footnote)
            } else {
                ProgressView("Waiting for \(client.macName)'s screen…").font(.footnote)
            }
        }
        .foregroundStyle(.secondary)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(screen.hostMessage == "denied")
    }

    @ViewBuilder private var setupButtons: some View {
        Button("How to set up") { showSetup = true }
        Button("Scan QR code", systemImage: "qrcode.viewfinder") { showScanner = true }
    }

    private var pairingPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(.secondary)
            Text("Pair with \(client.macName)")
                .font(.headline)
            Text(client.hostPlatform == .windows
                 ? "Choose \"Pair an iPhone…\" from the Couchpad icon in the Windows system tray, then scan the QR code or type the 6 digits."
                 : "Choose \"Pair an iPhone…\" from the cursor icon in the Mac's menu bar, then scan the QR code or type the 6 digits.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("000000", text: $pairingCode)
                .keyboardType(.numberPad)
                .font(.system(.title, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .onChange(of: pairingCode) { _, value in
                    if value.count >= 6 { submitPairingCode() }
                }
                .onSubmit(submitPairingCode)
            Button("Pair") { submitPairingCode() }
                .buttonStyle(.borderedProminent)
                .disabled(pairingCode.count < 6)
            Button("Scan QR code instead", systemImage: "qrcode.viewfinder") { showScanner = true }
                .font(.footnote)
            // The prompt stays up through reconnects; this says when the computer has gone
            // (quit, asleep, off the network) and a code typed now would go nowhere.
            if client.unreachable {
                Text(client.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if client.phase == .needsCode, let note = client.pairingNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            if client.phase == .wrongCode {
                Text("That code didn't match or has expired. Open the pairing window on the computer for a fresh one.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(20)
    }

    /// The iOS keyboard would otherwise sit on top of any sheet we present.
    private func syncKeyboardSuspension() {
        inputState.suspended = showSetup || showSettings || showScanner
    }

    private func submitPairingCode() {
        guard pairingCode.count >= 6 else { return }
        client.submitCode(String(pairingCode.prefix(6)))
        pairingCode = ""
    }

    private var mouseButtons: some View {
        HStack(spacing: 8) {
            HoldButton(label: "Left") { client.send("b l 1") } onUp: { client.send("b l 0") }
            HoldButton(label: "Right") { client.send("b r 1") } onUp: { client.send("b r 0") }
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Trackpad") {
                    VStack(alignment: .leading) {
                        Text("Pointer speed: \(settings.sensitivity, specifier: "%.1f")×")
                        Slider(value: $settings.sensitivity, in: 0.5...6, step: 0.1)
                    }
                    VStack(alignment: .leading) {
                        Text("Scroll speed: \(settings.scrollSpeed, specifier: "%.1f")×")
                        Slider(value: $settings.scrollSpeed, in: 0.5...5, step: 0.1)
                    }
                    Toggle("Natural scrolling", isOn: $settings.naturalScroll)
                    Toggle("Tap, then touch-and-hold to drag", isOn: $settings.tapToDrag)
                    Toggle("Three-finger swipes (Mission Control, Spaces)", isOn: $settings.threeFingerSwipes)
                    Toggle("Trackpad on the right (half open, sideways)", isOn: $settings.trackpadOnRight)
                    Toggle("Pad over the picture (sideways)", isOn: $settings.padOverlay)
                    if settings.padOverlay {
                        VStack(alignment: .leading) {
                            Text("Overlay opacity: \(Int((settings.overlayOpacity * 100).rounded()))%")
                            Slider(value: $settings.overlayOpacity, in: 0...1, step: 0.05)
                        }
                    }
                }
                Section("Keys") {
                    Toggle("Key row", isOn: $settings.showKeyRow)
                    Text("F1–F12, esc, tab, fn and the modifiers: under the picture or trackpad, at the top of the controller, or, sideways with Pad over the picture on, over the picture, with or without the controller. The ⌘ button in the bar hides and shows it too.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Screen") {
                    Toggle("Show the Mac's screen on the trackpad", isOn: $settings.showScreen)
                    Text("The trackpad works as usual on top of the picture. Needs Screen Recording access for Couchpad on the Mac; the Mac asks the first time. Mac only for now.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if screenAvailable {
                        Toggle("Play the Mac's sound", isOn: $settings.screenSound)
                        Text("Plays on the iPhone along with the picture, in silent mode too. Music or anything else playing on the iPhone keeps playing. The dot's menu in the bar turns it off and on.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker("Picture", selection: $settings.screenQuality) {
                        Text("Smooth").tag(0)
                        Text("Balanced").tag(1)
                        Text("Sharp").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Text("Sharper means bigger frames and more lag on a busy Wi-Fi.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Touch the picture to point there", isOn: $settings.tapToPoint)
                    Text("The pointer jumps to where your finger is, so a tap clicks what is under it. Off, a swipe moves the pointer and a tap clicks where it is.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Pinch the picture to zoom in (it fills the trackpad first), move the pinch to look around, pinch back out to reset. The keyboard pushes the picture up rather than shrinking it: move a pinch down to see its top.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Controller") {
                    Toggle("On-screen controller", isOn: $settings.showController)
                    Text("A stick and buttons under the picture or trackpad. Every button shows what it does; change them in Bindings below.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let name = controller.controllerName {
                        Label(name, systemImage: "gamecontroller.fill").foregroundStyle(.green)
                    } else {
                        Text("None connected. A Backbone or Bluetooth controller is forwarded to the computer as keys and mouse.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text("Look speed (right stick): \(settings.controllerLookSpeed, specifier: "%.0f")")
                        Slider(value: $settings.controllerLookSpeed, in: 2...30, step: 1)
                    }
                    Toggle("Invert look Y", isOn: $settings.controllerInvertY)
                    NavigationLink {
                        ControllerBindingsView(controller: controller)
                    } label: {
                        HStack {
                            Text("Bindings")
                            Spacer()
                            Text(controller.profile.name).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Connection") {
                    // Saved computers, each with its profile (name, VPN address, forget).
                    ForEach(client.devices) { device in
                        NavigationLink {
                            DeviceView(client: client, id: device.id) { showSettings = false }
                        } label: {
                            HStack {
                                Text(device.displayName)
                                Spacer()
                                if device.id == client.currentDeviceID {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                        .accessibilityLabel("Selected")
                                }
                            }
                        }
                    }
                    ForEach(client.nearbyServices) { service in
                        Button { client.connect(to: service); showSettings = false } label: {
                            HStack {
                                Text(service.name)
                                Spacer()
                                Text("Nearby, pair").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Add a computer by address…") {
                        newAddress = ""
                        showAddAddress = true
                    }
                    Text(client.status).font(.footnote).foregroundStyle(.secondary)
                }
                Section("About") {
                    Button("Setup guide & gestures") { showSettings = false; showSetup = true }
                    Link("Get the free Mac / Windows app", destination: Links.macDownload)
                    Link("Privacy policy", destination: Links.privacy)
                    Text("Couchpad \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { showSettings = false } }
            // On the form, not the section: a section hands its modifiers to every row.
            .alert("Add a computer by address", isPresented: $showAddAddress) {
                TextField("100.101.102.103", text: $newAddress)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Connect") {
                    if client.connect(address: newAddress) { showSettings = false }
                }
                .disabled(HostAddress(newAddress) == nil)
            } message: {
                Text("Its IP address or host name, with :port at the end if it isn't the usual one. For a computer on a VPN (Tailscale, WireGuard) or where the local network doesn't find it. If it's already paired, add the address to its profile above instead.")
            }
        }
    }
}

struct HoldButton: View {
    let label: String
    let onDown: () -> Void
    let onUp: () -> Void
    @State private var pressed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(pressed ? Color.accentColor : Color(.secondarySystemBackground))
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(pressed ? Color.white : Color.primary)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed { pressed = true; onDown() }
                }
                .onEnded { _ in
                    pressed = false
                    onUp()
                }
        )
    }
}

/// What the picture's pane measures itself for (see `trackpadPane`).
private struct PaneMeasure: Equatable {
    var window: CGSize
    var keyboardPushes: Bool
    var keyboardDown: Bool
}

/// The picture's pane's last size, held by reference like `TaskBox`.
private final class SizeBox {
    var size = CGSize.zero
}

/// The last stream size asked for, held by reference like `TaskBox`.
private final class RequestBox {
    var size: CGSize?
    var window = CGSize.zero
}

/// A pending task held by reference, so replacing it does not count as a state change.
private final class TaskBox {
    var task: Task<Void, Never>?
}
