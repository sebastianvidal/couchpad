import SwiftUI

struct ContentView: View {
    @StateObject private var client = Client()
    @StateObject private var settings = AppSettings()
    @StateObject private var inputState = InputState()
    @StateObject private var controller = ControllerBridge()
    @State private var showSettings = false
    @State private var pairingCode = ""
    @AppStorage("hasSeenSetup") private var hasSeenSetup = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }
    @State private var showSetup = false
    @State private var showScanner = false
    /// Top edge of the iOS keyboard in landscape (screen coordinates), measured the first
    /// time it appears and remembered, so the key block can end exactly where it begins.
    @AppStorage("landscapeKeyboardTop") private var landscapeKeyboardTop: Double = 0

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
        .onAppear {
            controller.client = client
            controller.settings = settings
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
            let screen = UIScreen.main.bounds
            guard isLandscape, frame.minY > screen.height * 0.3, frame.minY < screen.height else { return }
            landscapeKeyboardTop = frame.minY
        }
        .onChange(of: isLandscape, initial: true) { _, landscape in
            // Sideways (a Backbone, say) the iOS keyboard would cover half the screen: start hidden.
            // `initial: true` covers launching already sideways, when onAppear sees no size class yet.
            inputState.keyboardShown = !landscape
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background: controller.releaseAll(); client.appDidEnterBackground()
            case .active: client.appDidBecomeActive()
            default: break
            }
        }
    }

    private var portraitBody: some View {
        VStack(spacing: 8) {
            topBar
            trackpad
            if !inputState.keyboardShown {
                mouseButtons.frame(height: 44)
            }
            KeyStripView(client: client, state: inputState, rowHeight: 42)
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
                let keyboardTop = landscapeKeyboardTop > 0 ? landscapeKeyboardTop : bottom - geo.size.height * 0.40
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
        return VStack(spacing: 6) {
            KeyStripView(client: client, state: inputState, rowHeight: rowHeight,
                         replacesRowsWhenExpanded: inputState.keyboardShown)
                .background(keyInput)   // zero footprint: it must not add height below the keys
            if !inputState.keyboardShown {
                mouseButtons.frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
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
            Button { showSetup = true } label: { Image(systemName: "questionmark.circle") }
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
        .padding(.top, 4)
    }

    private var trackpad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            TrackpadView(client: client, settings: settings)
            switch client.phase {
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
                    HStack {
                        Button("How to set up") { showSetup = true }
                        Button("Scan QR code", systemImage: "qrcode.viewfinder") { showScanner = true }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity)
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
