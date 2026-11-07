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
    @State private var showSetup = false
    @State private var showScanner = false
    /// Screen layout: the floating key panel and where the user dragged it.
    @State private var showKeysPanel = false
    /// A foldable held half open: the picture goes on the half that stands up, the controls
    /// on the half lying flat. Reported by the system; always false elsewhere.
    @State private var hingePartlyOpen = false
    @State private var keysOffset = CGSize.zero
    @State private var keysOffsetBase = CGSize.zero
    /// Top edge of the iOS keyboard in landscape (window coordinates), measured the first
    /// time it appears and remembered per window size, so the key block can end exactly where
    /// it begins. Keyed by size because a foldable has two displays with different keyboards.
    @AppStorage("landscapeKeyboardTops") private var landscapeKeyboardTops = ""

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
        // sideways, nothing moves for the keyboard (the trackpad is inset by hand instead).
        .ignoresSafeArea(isLandscape || hingeLayout ? .keyboard : [])
        .background(Color(.systemBackground))
        .background(HingeObserver(partlyOpen: $hingePartlyOpen))
        // The picture is the point of screen mode: the clock and the signal bars can go.
        .statusBarHidden(screenOn && client.isConnected)
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
            // The frame is in screen coordinates; on a phone the window fills the screen.
            // Keyed by window size, so each orientation and posture learns its own.
            guard frame.minY > windowSize.height * 0.3, frame.minY < windowSize.height else { return }
            var tops = keyboardTops
            tops[sizeKey] = frame.minY
            if let data = try? JSONEncoder().encode(tops), let json = String(data: data, encoding: .utf8) {
                landscapeKeyboardTops = json
            }
        }
        .onChange(of: isLandscape, initial: true) { _, landscape in
            // Sideways (a Backbone, say) the iOS keyboard would cover half the screen: start hidden.
            // `initial: true` covers launching already sideways, when onAppear sees no size class yet.
            inputState.keyboardShown = !landscape && !screenOn
        }
        .onChange(of: screenOn) { _, on in
            // With the picture up, the picture is the point: keyboard down until asked for.
            inputState.keyboardShown = !on && !isLandscape
            showKeysPanel = false
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
    }

    /// The picture is only offered by Macs for now; the setting is remembered regardless.
    private var screenAvailable: Bool { client.hostPlatform == .mac }
    private var screenOn: Bool { settings.showScreen && screenAvailable }
    private var hingeLayout: Bool { screenOn && client.isConnected && hingePartlyOpen }

    /// Tells the host whether we want its screen and at what size. Called whenever the
    /// connection, the setting or the trackpad's size changes; the host restarts the stream
    /// only when the size actually changed.
    private func syncScreen() {
        guard client.isConnected else { screen.reset(); return }
        if screenOn, trackpadPixels.width > 0 {
            let share = [0.5, 2.0 / 3.0, 1.0][max(0, min(2, settings.screenQuality))]
            // 60 fps: a change waits half as long for the next capture, and the phone's
            // display shows it on the next refresh. Bandwidth roughly doubles; still a few Mbps.
            client.send("v 1 \(Int(trackpadPixels.width * share)) \(Int(trackpadPixels.height * share)) 60")
        } else {
            client.send("v 0")
            screen.reset()
        }
    }

    private var keyboardTops: [String: Double] {
        guard let data = landscapeKeyboardTops.data(using: .utf8),
              let tops = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return tops
    }

    private var sizeKey: String { "\(Int(windowSize.width))x\(Int(windowSize.height))" }

    /// Taller keys on a wide portrait window (an unfolded iPhone Duo), so they keep roughly
    /// the proportions they have on a phone instead of turning into flat bars.
    private var portraitRowHeight: CGFloat {
        let unit = (windowSize.width - 16 - 6 * 4) / 7
        return min(58, max(42, unit * 0.65))
    }

    private var portraitBody: some View {
        VStack(spacing: 8) {
            topBar
            trackpad
            if !inputState.keyboardShown {
                mouseButtons.frame(height: 44)
            }
            KeyStripView(client: client, state: inputState, rowHeight: portraitRowHeight)
                .background(keyInput)   // zero footprint: it must not add height below the keys
        }
    }

    /// Trackpad on one side (your choice), everything else in a column on the other. The key
    /// rows stretch to use the column's full height, so with the iOS keyboard hidden the keys
    /// are large.
    /// Nothing here moves for the keyboard: the whole body ignores it, and instead the
    /// trackpad is inset by the keyboard's height while it is up. The key block is sized to
    /// end on that same line, so block bottom, trackpad bottom and keyboard top coincide.
    private var landscapeBody: some View {
        VStack(spacing: 6) {
            topBar
            GeometryReader { geo in
                // Distance from our bottom edge up to the keyboard's top edge, in the same coordinates.
                let bottom = geo.frame(in: .global).maxY
                let keyboardTop = keyboardTops[sizeKey] ?? (bottom - geo.size.height * 0.40)
                let inset = max(0, bottom - keyboardTop + 8)   // 8pt of air above the keyboard, like every other gap
                HStack(spacing: 10) {
                    if settings.trackpadOnRight {
                        landscapeControls(width: max(300, geo.size.width * 0.42), above: geo.size.height - inset)
                        trackpad.padding(.bottom, inputState.keyboardShown ? inset : 0)
                    } else {
                        trackpad.padding(.bottom, inputState.keyboardShown ? inset : 0)
                        landscapeControls(width: max(300, geo.size.width * 0.42), above: geo.size.height - inset)
                    }
                }
            }
        }
    }

    /// The key block is anchored at the top with fixed row heights and the column ignores the
    /// keyboard, so the keys never move: the iOS keyboard simply covers the space below them.
    /// That space holds the mouse buttons while the keyboard is hidden.
    private func landscapeControls(width: CGFloat, above: CGFloat) -> some View {
        // Rows fill the space above the keyboard line exactly: bar + gap + 3 rows + 2 gaps = `above`.
        let rowHeight = min(80, max(36, (above - 28 - 3 * 4) / 3))
        // On a large display (an unfolded iPhone Duo) the rows hit their cap and leave room
        // above the keyboard line; the mouse buttons take it rather than leaving a hole.
        let spare = above - (28 + 4 + 3 * rowHeight + 2 * 4) - 6
        return VStack(spacing: 6) {
            KeyStripView(client: client, state: inputState, rowHeight: rowHeight,
                         replacesRowsWhenExpanded: inputState.keyboardShown)
                .background(keyInput)   // zero footprint: it must not add height below the keys
            if !inputState.keyboardShown {
                mouseButtons.frame(maxHeight: .infinity)
            } else {
                if spare >= 56 {
                    mouseButtons.frame(height: spare)
                }
                Spacer(minLength: 0)   // keeps the column pinned to the top; the keyboard covers this
            }
        }
        .frame(width: width)
    }

    // MARK: Half-open foldable

    /// Split at the hinge, which runs across the middle of the window's long side: the
    /// picture on one half, a plain trackpad with the keys and the bar on the other. Upright
    /// (hinge horizontal, laptop-style) the picture is the top half; sideways (hinge
    /// vertical, like a book) the picture is on the side opposite the trackpad.
    private var hingeBody: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let keyboardTop = keyboardTops[sizeKey] ?? (frame.maxY - geo.size.height * 0.40)
            let inset = inputState.keyboardShown ? max(0, frame.maxY - keyboardTop + 8) : 0
            let gap: CGFloat = 24   // keeps touches and the picture's edge off the crease
            if isLandscape {
                let hingeX = windowSize.width / 2 - frame.minX
                HStack(spacing: 0) {
                    if settings.trackpadOnRight {
                        trackpadPane(picture: true).frame(width: hingeX - gap / 2)
                        Spacer().frame(width: gap)
                        hingeControls(inset: inset)
                    } else {
                        hingeControls(inset: inset)
                        Spacer().frame(width: gap)
                        trackpadPane(picture: true).frame(width: geo.size.width - hingeX - gap / 2)
                    }
                }
            } else {
                let hingeY = windowSize.height / 2 - frame.minY
                VStack(spacing: 0) {
                    trackpadPane(picture: true).frame(height: hingeY - gap / 2)
                    Spacer().frame(height: gap)
                    hingeControls(inset: inset)
                }
            }
        }
        .padding(.top, 4)
    }

    /// The flat half: a big trackpad over the bar, with the keys floating over the trackpad
    /// on demand, the same as the sideways screen layout.
    private func hingeControls(inset: CGFloat) -> some View {
        VStack(spacing: 6) {
            trackpadPane(picture: false)
                .overlay(alignment: .bottomTrailing) {
                    if showKeysPanel { keysPanel }
                }
            screenBar(keysToggle: true)
        }
        .padding(.bottom, inset)
    }

    // MARK: Screen layout

    /// With the Mac's picture on, the picture gets the whole window but one slim bar: the
    /// keys the strip normally shows live in a panel that floats over the picture on demand,
    /// and the iOS keyboard is summoned from the bar. Sideways, the body ignores the keyboard
    /// (see `body`), so everything is inset by hand to sit above it; upright, keyboard
    /// avoidance at the root shrinks the picture for us.
    private var screenBody: some View {
        GeometryReader { geo in
            let bottom = geo.frame(in: .global).maxY
            let keyboardTop = keyboardTops[sizeKey] ?? (bottom - geo.size.height * 0.40)
            let inset = isLandscape && inputState.keyboardShown ? max(0, bottom - keyboardTop + 8) : 0
            // A wide picture in a tall window (an unfolded Duo held upright) leaves a band
            // under the picture: when it fits three rows of keys, the strip lives there instead
            // of floating. The picture fills the width and the strip takes what is left.
            let availableHeight = geo.size.height - inset - 36 - 6
            let pictureHeight = screen.videoSize == .zero ? availableHeight : geo.size.width * screen.videoSize.height / screen.videoSize.width
            let spare = availableHeight - pictureHeight - 6
            let docked = spare >= 40 + 3 * 36
            let dockedRow = min(portraitRowHeight, (spare - 40) / 3)
            VStack(spacing: 6) {
                trackpad
                    .overlay(alignment: .bottomTrailing) {
                        if showKeysPanel, !docked { keysPanel }
                    }
                if docked {
                    KeyStripView(client: client, state: inputState, rowHeight: dockedRow,
                                 replacesRowsWhenExpanded: spare < 40 + 5 * dockedRow + 8)
                }
                screenBar(keysToggle: !docked)
            }
            .padding(.bottom, inset)
        }
        .padding(.top, 4)
    }

    private func screenBar(keysToggle: Bool) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(client.services) { service in
                    Button(service.name) { client.connect(to: service) }
                }
                if client.services.isEmpty { Text("No Macs found yet") }
            } label: {
                Circle()
                    .fill(client.isConnected ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                    .padding(.horizontal, 6)
                    .frame(maxHeight: .infinity)
            }
            .accessibilityLabel(client.status)
            barButton("display.2", label: "Hide the computer's screen") { settings.showScreen = false }
            if keysToggle {
                barButton(showKeysPanel ? "command.square.fill" : "command.square", label: showKeysPanel ? "Hide keys" : "Show keys") {
                    showKeysPanel.toggle()
                }
            }
            barButton(inputState.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard",
                      label: inputState.keyboardShown ? "Hide keyboard" : "Show keyboard") {
                inputState.keyboardShown.toggle()
            }
            mouseButtons
            if controller.controllerName != nil {
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Controller connected")
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

    /// The key strip as a translucent card over the picture. Drag it by the handle; the
    /// F-key bar swaps rows rather than growing, so the card keeps its size.
    private var keysPanel: some View {
        VStack(spacing: 6) {
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            keysOffset = CGSize(width: keysOffsetBase.width + value.translation.width,
                                                height: keysOffsetBase.height + value.translation.height)
                        }
                        .onEnded { _ in keysOffsetBase = keysOffset }
                )
            KeyStripView(client: client, state: inputState, rowHeight: 38, replacesRowsWhenExpanded: true)
        }
        .padding(8)
        .frame(width: min(400, max(280, windowSize.width - 32)))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .padding(10)
        .offset(keysOffset)
    }

    private var keyInput: some View {
        KeyInputView(client: client, state: inputState)
            .frame(width: 1, height: 1)
            .opacity(0.01)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(client.isConnected ? Color.green : Color.orange)
                .frame(width: 9, height: 9)
            Menu {
                ForEach(client.services) { service in
                    Button(service.name) { client.connect(to: service) }
                }
                if client.services.isEmpty {
                    Text("No Macs found yet")
                }
            } label: {
                Text(client.status)
                    .font(.footnote)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.controllerName != nil {
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Controller connected")
            }
            if screenAvailable, client.isConnected {
                Button { settings.showScreen.toggle() } label: {
                    Image(systemName: settings.showScreen ? "display.2" : "display")
                }
                .accessibilityLabel(settings.showScreen ? "Hide the computer's screen" : "Show the computer's screen")
            }
            Button { showSetup = true } label: { Image(systemName: "questionmark.circle") }
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
        .padding(.top, 4)
    }

    private var trackpad: some View { trackpadPane(picture: true) }

    /// The trackpad, with the Mac's picture underneath when screen mode is on and `picture`
    /// asks for it (the half-open layout shows a second, plain trackpad).
    private func trackpadPane(picture: Bool) -> some View {
        let showPicture = picture && screenOn && client.isConnected
        // With the key panel out, the picture hugs the top-left corner so the panel sits in
        // the letterbox space instead of over the picture (which matters once the iOS
        // keyboard has squeezed it).
        return ZStack(alignment: showKeysPanel && showPicture ? .topLeading : .center) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            if showPicture {
                ScreenView(receiver: screen)
                    .aspectRatio(screen.videoSize == .zero ? nil : screen.videoSize.width / screen.videoSize.height, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            TrackpadView(client: client, settings: settings, videoSize: showPicture && settings.tapToPoint ? screen.videoSize : .zero,
                         videoTopLeading: showKeysPanel)
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
                    Toggle("Trackpad on the right (landscape)", isOn: $settings.trackpadOnRight)
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
                }
                Section("Controller") {
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
