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
    /// Top edge of the iOS keyboard in landscape (window coordinates), measured the first
    /// time it appears and remembered per window size, so the key block can end exactly where
    /// it begins. Keyed by size because a foldable has two displays with different keyboards.
    @AppStorage("landscapeKeyboardTops") private var landscapeKeyboardTops = ""

    var body: some View {
        Group {
            if isLandscape {
                landscapeBody
            } else {
                portraitBody
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        // Keyboard avoidance is applied at the root, so it has to be switched off here:
        // sideways, nothing moves for the keyboard (the trackpad is inset by hand instead).
        .ignoresSafeArea(isLandscape ? .keyboard : [])
        .background(Color(.systemBackground))
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
            guard isLandscape, frame.minY > windowSize.height * 0.3, frame.minY < windowSize.height else { return }
            var tops = keyboardTops
            tops[sizeKey] = frame.minY
            if let data = try? JSONEncoder().encode(tops), let json = String(data: data, encoding: .utf8) {
                landscapeKeyboardTops = json
            }
        }
        .onChange(of: isLandscape, initial: true) { _, landscape in
            // Sideways (a Backbone, say) the iOS keyboard would cover half the screen: start hidden.
            // `initial: true` covers launching already sideways, when onAppear sees no size class yet.
            inputState.keyboardShown = !landscape
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
    }

    /// The picture is only offered by Macs for now; the setting is remembered regardless.
    private var screenAvailable: Bool { client.hostPlatform == .mac }
    private var screenOn: Bool { settings.showScreen && screenAvailable }

    /// Tells the host whether we want its screen and at what size. Called whenever the
    /// connection, the setting or the trackpad's size changes; the host restarts the stream
    /// only when the size actually changed.
    private func syncScreen() {
        guard client.isConnected else { screen.reset(); return }
        if screenOn, trackpadPixels.width > 0 {
            client.send("v 1 \(Int(trackpadPixels.width)) \(Int(trackpadPixels.height)) 30")
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

    private var trackpad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            if screenOn, client.isConnected {
                ScreenView(receiver: screen)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            TrackpadView(client: client, settings: settings, videoSize: screenOn && settings.tapToPoint ? screen.videoSize : .zero)
                .background(
                    GeometryReader { geo in
                        Color.clear.onChange(of: geo.size, initial: true) { _, size in
                            trackpadPixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
                        }
                    }
                )
            switch client.phase {
            case .paired where screenOn && screen.videoSize == .zero:
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
