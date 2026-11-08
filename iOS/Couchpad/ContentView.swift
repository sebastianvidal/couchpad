import SwiftUI

struct ContentView: View {
    @StateObject private var client = Client()
    @StateObject private var settings = AppSettings()
    @StateObject private var inputState = InputState()
    @StateObject private var controller = ControllerBridge()
    @StateObject private var screen = ScreenReceiver()
    /// Size of the trackpad area in pixels, which is the picture size we ask the host for.
    @State private var trackpadPixels = CGSize.zero
    @State private var showSettings = false
    @State private var pairingCode = ""
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
    /// Half open upright while typing, the key row floats over the picture on the bar's ⌘
    /// button (the only place that button appears); gone again with the keyboard.
    @State private var showFloatingKeys = false
    /// A foldable held half open: the picture goes on the half that stands up, the controls
    /// on the half lying flat. Reported by the system; always false elsewhere.
    @State private var hingePartlyOpen = false
    /// How far the picture is pinched in and shifted; owned by the trackpad's gesture.
    @State private var screenZoom: CGFloat = 1
    @State private var screenPan = CGPoint.zero
    /// Waits for a pinch to settle before asking the host for a sharper (or coarser) stream.
    @State private var zoomSettle: Task<Void, Never>?
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
        // sideways and half open, nothing moves for the keyboard and every layout insets
        // itself by hand instead (`keyboardInset`). Half open the keyboard is ignored
        // whatever the state, so the switch is not made in the same instant the keyboard
        // appears (which SwiftUI did not always honour).
        .ignoresSafeArea(isLandscape || hingePartlyOpen ? .keyboard : [])
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
                Color.clear.onChange(of: geo.size, initial: true) { _, size in windowSize = size }
            }
            .ignoresSafeArea()
        )
        .onAppear {
            controller.client = client
            controller.settings = settings
            screen.client = client
            client.onScreenPacket = { [weak screen] packet in screen?.handle(packet) }
            client.onScreenStatus = { [weak screen] status in screen?.hostMessage = status }
            client.onScreenHealth = { [weak screen] health in
                if screen?.health != health { screen?.health = health }
            }
            client.onScreenLoss = { [weak screen] in screen?.markLost() }
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
            guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            NSLog("Keyboard frame %@ in window %@", NSCoder.string(for: frame), NSCoder.string(for: windowSize))
            // The frame is in screen coordinates; on a phone the window fills the screen.
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
                    inputState.keyboardShown = false
                }
            }
        }
        .onChange(of: isLandscape, initial: true) { _, _ in
            // The iOS keyboard starts hidden in every layout and comes up on demand (the bar's
            // keyboard button, or the key row's): sideways it would cover half the screen,
            // and upright the trackpad, the picture or the pad is the point.
            // `initial: true` covers launching already sideways, when onAppear sees no size class yet.
            inputState.keyboardShown = false
        }
        .onChange(of: inputState.keyboardShown) { _, shown in
            if !shown { showFloatingKeys = false }
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
        .onChange(of: trackpadPixels) { _, _ in syncScreen() }
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

    /// How far a layout ends above its bottom edge so its last row sits 8pt above the iOS
    /// keyboard. Only where the root ignores the keyboard (sideways, half open); elsewhere
    /// keyboard avoidance has already shrunk the layout. Half open upright, iOS reports the
    /// keyboard as the whole bottom segment (the keys sit inside it), so avoidance would
    /// leave a blank band above the keys: the inset goes to where the keys were measured
    /// to start instead (`keyboardTops`).
    private func keyboardInset(_ geo: GeometryProxy) -> CGFloat {
        guard inputState.keyboardShown, isLandscape || hingePartlyOpen else { return 0 }
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
    /// only when the size actually changed.
    private func syncScreen() {
        guard client.isConnected else { screen.reset(); return }
        if screenOn, trackpadPixels.width > 0 {
            let share = [0.5, 2.0 / 3.0, 1.0][max(0, min(2, settings.screenQuality))]
            // 60 fps: a change waits half as long for the next capture, and the phone's
            // display shows it on the next refresh. Bandwidth roughly doubles; still a few Mbps.
            let pixels = share * Double(screenZoom)
            client.send("v 1 \(Int(trackpadPixels.width * pixels)) \(Int(trackpadPixels.height * pixels)) 60")
        } else {
            client.send("v 0")
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

    /// Same skeleton as the screen layout: the trackpad, the key row under it, the bar,
    /// 6pt apart, so toggling the picture moves nothing. With the pad on, the pad (with the
    /// key row at its top) takes the bottom half instead. Arrows and space come from the
    /// pad's bindings or the iOS keyboard.
    /// Half open (picture off), the root ignores the keyboard, so the layout ends above
    /// it by hand (`keyboardInset`); elsewhere keyboard avoidance shrinks the trackpad.
    private var portraitBody: some View {
        GeometryReader { geo in
            let inset = keyboardInset(geo)
            VStack(spacing: 6) {
                trackpad
                if settings.showController {
                    portraitPad(height: geo.size.height - inset - 36 - 6)
                } else {
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
                              rowHeight: typing ? portraitRowHeight : nil)
            .frame(height: typing ? nil : max(0, (available - 6) / 2))
    }

    /// The screen layout's skeleton without the picture: the trackpad full width, the key
    /// row under it, then the bar; with the pad on, a short band under the trackpad instead.
    /// Nothing here moves for the keyboard: the whole body ignores it, and instead everything
    /// is inset by the keyboard's height while it is up, so the trackpad shrinks and the row
    /// and the bar sit just above the keyboard (as in the screen layout).
    private var landscapeBody: some View {
        GeometryReader { geo in
            let inset = keyboardInset(geo)
            let above = geo.size.height - inset - 36 - 6   // what is left over the bar and its gap
            VStack(spacing: 6) {
                trackpad
                if settings.showController {
                    // Sideways the pad is a short band under the trackpad, thumbs at the
                    // bottom corners, rather than a column beside it.
                    ControllerView(controller: controller, client: client, state: inputState, rowHeight: wideRowHeight(above), wide: true)
                } else {
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
    /// heads it, above the keys; the key row floats over the picture on the bar's ⌘ button.
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
    /// the key row is a card over the picture, on demand (`showFloatingKeys`).
    private var hingeTypingUpright: Bool { hingeLayout && inputState.keyboardShown && !isLandscape }

    /// The half that stands up: the picture, with the floating key row over its bottom
    /// while typing upright, when the bar's ⌘ button asks for it.
    private var pictureHalf: some View {
        trackpad
            .overlay(alignment: .bottomTrailing) {
                if hingeTypingUpright, showFloatingKeys {
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
                ControllerView(controller: controller, client: client, state: inputState, rowHeight: portraitRowHeight)
            } else if settings.showController {
                // Picture on one half, pad on the other: a hand-held console. Upright the
                // flat half is wide and short; sideways it is a narrow column.
                ControllerView(controller: controller, client: client, state: inputState, wide: !isLandscape)
            } else {
                trackpadPane(picture: false)
                keyRow
            }
            bar(picture: true)
            if hingeTypingUpright { Spacer(minLength: 0) }
        }
        .padding(.bottom, inset)
    }

    // MARK: Screen layout

    /// With the Mac's picture on, the picture gets the whole window but the key row docked
    /// under it and one slim bar; the iOS keyboard is summoned from the bar. Sideways, the
    /// body ignores the keyboard (see `body`), so everything is inset by hand for the row
    /// and the bar to sit just above it; otherwise keyboard avoidance at the root shrinks
    /// the picture for us.
    private var screenBody: some View {
        GeometryReader { geo in
            let inset = keyboardInset(geo)
            let availableHeight = geo.size.height - inset - 36 - 6
            VStack(spacing: 6) {
                trackpad
                if settings.showController {
                    // The pad never floats over the picture: the picture gives up the room.
                    // Upright it takes the bottom half (a Game Boy); sideways, a short band under it.
                    if isLandscape {
                        ControllerView(controller: controller, client: client, state: inputState, rowHeight: wideRowHeight(availableHeight), wide: true)
                    } else {
                        portraitPad(height: availableHeight)
                    }
                } else {
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
    /// so every control keeps its place: the dot, the screen toggle, the keyboard toggle,
    /// the pad toggle, the mouse buttons, the controller mark, (picture and pad off,
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
                ForEach(client.services) { service in
                    Button(service.name) { client.connect(to: service) }
                }
                if client.services.isEmpty { Text("No Macs found yet") }
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
            // Half open upright while typing, the key row is not on screen: it floats over
            // the picture on demand.
            if hingeTypingUpright {
                barButton(showFloatingKeys ? "command.square.fill" : "command.square",
                          label: showFloatingKeys ? "Hide keys" : "Show keys") {
                    showFloatingKeys.toggle()
                }
            }
            // With the pad on, the iOS keyboard takes the pad's place (only its key row
            // stays) until it is dismissed.
            barButton(inputState.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard",
                      label: inputState.keyboardShown ? "Hide keyboard" : "Show keyboard") {
                inputState.keyboardShown.toggle()
            }
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
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 44)
                .frame(maxHeight: .infinity)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The key row (F bar over esc, tab, fn and the modifiers), always docked under the
    /// trackpad or picture when the pad is off (the pad has its own at its top). Upright it
    /// keeps the pad's row height; sideways, where height is short, it is a slimmer row.
    private var keyRow: some View {
        KeyStripView(client: client, state: inputState, rowHeight: isLandscape ? 36 : portraitRowHeight)
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
    /// asks for it (the half-open layout shows a second, plain trackpad).
    private func trackpadPane(picture: Bool) -> some View {
        let showPicture = picture && screenOn && client.isConnected
        return ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            if showPicture {
                ScreenView(receiver: screen, zoom: screenZoom, pan: screenPan)
                    .aspectRatio(screen.videoSize == .zero ? nil : screen.videoSize.width / screen.videoSize.height, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            TrackpadView(client: client, settings: settings, videoSize: showPicture && settings.tapToPoint ? screen.videoSize : .zero,
                         pictureSize: showPicture ? screen.videoSize : .zero,
                         onZoom: { zoom, pan in screenZoom = zoom; screenPan = pan })
                .background(
                    GeometryReader { geo in
                        Color.clear.onChange(of: geo.size, initial: true) { _, size in
                            guard picture else { return }   // the stream is sized to the picture's pane
                            trackpadPixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
                        }
                    }
                )
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
                    Text("Open Couchpad on your Mac or PC\n(same Wi-Fi)")
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

    /// What to say while the picture is wanted but not arriving.
    private var screenPlaceholder: some View {
        VStack(spacing: 8) {
            if screen.hostMessage == "denied" {
                Image(systemName: "rectangle.on.rectangle.slash").font(.title2)
                Text("Allow Screen Recording for Couchpad on \(client.macName)\n(System Settings → Privacy & Security), then try again.")
                    .multilineTextAlignment(.center)
                    .font(.footnote)
                Button("Try again") { client.send("v 0"); syncScreen() }
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
                }
                Section("Screen") {
                    Toggle("Show the Mac's screen on the trackpad", isOn: $settings.showScreen)
                    Text("The trackpad works as usual on top of the picture. Needs Screen Recording access for Couchpad on the Mac; the Mac asks the first time. Mac only for now.")
                        .font(.footnote).foregroundStyle(.secondary)
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
                    Text("Pinch the picture to zoom in, move the pinch to look around, pinch back out to reset.")
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
                    ForEach(client.services) { service in
                        Button(service.name) { client.connect(to: service); showSettings = false }
                    }
                    HStack {
                        TextField("Computer IP (if discovery fails)", text: $settings.manualHost)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                        Button("Connect") { client.connect(host: settings.manualHost); showSettings = false }
                            .disabled(settings.manualHost.isEmpty)
                    }
                    Text(client.status).font(.footnote).foregroundStyle(.secondary)
                    if client.isConnected {
                        Button("Forget \(client.macName)", role: .destructive) {
                            client.forgetMac()
                            showSettings = false
                        }
                    }
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
