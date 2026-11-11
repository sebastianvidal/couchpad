import CryptoKit
import Foundation
import Network
import Combine

/// Finds computers running Couchpad over Bonjour, keeps one TCP connection open, runs the
/// protocol v2 handshake (see SecureChannel.swift) so every line is encrypted, and handles
/// pairing: the phone proves it holds a token (or the pairing code) with an HMAC over the
/// handshake transcript, and the host proves the same back. Paired computers are saved as
/// devices (Devices.swift), each with its token, so the code is only needed once, however
/// the computer is reached.
///
/// Session rules:
/// - The app connects to the selected device and nothing else, whatever else is on the
///   network: by its Bonjour service when it is found there, else by its addresses, all
///   raced at once (`startRace`): the one typed into its profile, the ones the computer
///   announced last time (`addrs`, VPN tunnels included) and the QR pairing's (`pickRoute`).
/// - The local network wins whenever it is there: connected by address, Bonjour finding the
///   computer starts a probe of its service, and once that connects the session moves over
///   (`startProbe`). A move that then fails goes back to the address and holds off for 60 s.
/// - Leaving the app closes the connection cleanly (the host then releases any held keys).
/// - Returning reconnects at once with the stored token, on the service it was using if it
///   was on one (`resumeService`), else after a second's wait for Bonjour; discovery is
///   restarted too, since Bonjour results go stale while the app is suspended.
/// - Transient failures retry with backoff, on the next route, and never touch the token. The
///   pairing prompt only appears when the host explicitly refuses the token or there is none,
///   and a refused token is kept until a code pairing replaces it.
@MainActor
final class Client: ObservableObject {
    struct Service: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    enum Phase: Equatable {
        case searching, connecting, needsCode, wrongCode, paired, disconnected
    }

    /// How a connection reaches its computer (see `pickRoute` for the order).
    enum Route: Equatable {
        /// The Bonjour service it is found under on the local network.
        case service(String)
        /// One of its addresses (`Device.addressCandidates`).
        case address(String)
        /// All of its addresses, raced (`startRace`); the last route while no winner has
        /// been opened.
        case addresses

        var address: String? {
            if case .address(let a) = self { a } else { nil }
        }
    }

    /// What the app connects to: a saved device, or something not saved yet (a service
    /// nobody has paired with, a new address, a QR code from a new computer), which becomes a
    /// device on its first `ok`. Replaces keeping a name and a manual host apart.
    private enum Target: Equatable {
        case device(UUID)
        case new(Device)
    }

    @Published private(set) var services: [Service] = []
    @Published private(set) var status = "Looking for your computer…"
    @Published private(set) var phase: Phase = .searching
    /// The target's name, for UI text.
    @Published private(set) var macName = ""
    @Published private(set) var hostPlatform: HostPlatform = .mac
    @Published private(set) var devices: [Device] = []
    /// The device to connect to, saved across launches.
    @Published private(set) var selectedID: UUID?
    /// Why the pairing prompt is up although the device has a token: the host refused it.
    @Published private(set) var pairingNote: String?
    /// The computer can't be reached: the connection is waiting for a route, or has failed
    /// twice running. The pairing prompt, which stays up through reconnects, says so. A
    /// wrong code's single hang-up doesn't count (the reconnect right after succeeds).
    @Published private(set) var unreachable = false
    @Published private var target: Target?

    /// Binary messages from the host (the screen stream), delivered on the main actor.
    var onScreenPacket: ((Data) -> Void)?
    /// Text status about the screen stream from the host ("denied", "error …").
    var onScreenStatus: ((String) -> Void)?
    /// `screen health <ok> <ack ms> <lost/s> <skipped %> <phones>`, once a second from the host.
    var onScreenHealth: ((ScreenHealth) -> Void)?
    /// A frame was lost on the UDP path: the decoder must wait for the next keyframe.
    var onScreenLoss: (() -> Void)?
    /// The Mac's sound, with the picture (see AudioPacket). Packets go straight to it from
    /// whichever queue they arrive on.
    let audio = AudioPlayer()

    /// "Mac" or "PC", for UI text about the paired computer.
    var hostNoun: String { hostPlatform == .windows ? "PC" : "Mac" }
    var isConnected: Bool { phase == .paired }

    /// The saved device being connected to; nil while the target is something new.
    var currentDeviceID: UUID? {
        if case .device(let id)? = target { return id }
        return nil
    }

    /// Discovered services no saved device is found under: computers to pair with.
    var nearbyServices: [Service] {
        services.filter { service in !devices.contains { $0.serviceName == service.name } }
    }

    /// The route the session is on, while connected: what the profile screen checks.
    /// (`lastRoute` only changes along with `phase`, so this updates with it.)
    var activeRoute: Route? { isConnected ? lastRoute : nil }

    /// Whether the device is being found on the local network right now.
    func isOnLocalNetwork(_ device: Device) -> Bool {
        guard let name = device.serviceName else { return false }
        return services.contains { $0.name == name }
    }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiving = false
    private var buffer = FrameBuffer()
    private var privateKey = P256.KeyAgreement.PrivateKey()
    private var transcript = Data()
    private var sendCipher: FrameCipher?
    private var recvCipher: FrameCipher?
    private var sessionKey: SymmetricKey?
    /// Frames over UDP once paired (see VideoLink); nil while the host's address is unknown.
    private var videoLink: VideoLink?
    private var screenWanted = false
    /// Sends the player's report once a second while it plays.
    private var audioReports: Task<Void, Never>?
    private var sentCredential: Credential?
    private var pendingCode: String?
    private var retryTask: Task<Void, Never>?
    /// When `retryTask` fires, so a later request can leave a sooner one be (`scheduleRetry`).
    private var retryDue: Date?
    /// Reconnects a moment after the target's address stops changing in its profile.
    private var addressEdit: Task<Void, Never>?
    private var failures = 0
    private var inBackground = false
    /// The route of the current (or last) connection, and whether a host answered the
    /// handshake on it: a route that worked is tried again first, one that didn't gives way
    /// to the next (`pickRoute`).
    private var lastRoute: Route?
    private var routeWorked = false
    /// A route the user picked on the profile screen (`connect(_:by:)`): its connection is
    /// left alone, no probe moving it to the service and Bonjour not pre-empting it. For
    /// that one connection only: it ends with it, or with its attempt failing, and then the
    /// usual rules pick again (a dead pick fails over like anything else).
    private var pinned: Route?
    /// Until then, a device expected on the local network waits for Bonjour before its
    /// address is tried: about a second, so someone on a VPN isn't kept waiting.
    private var bonjourGrace = Date.distantPast
    /// Devices whose token the host refused, with what to say about it. In memory only: the
    /// reconnect after the host hangs up shows the pairing prompt instead of trying the
    /// token again, while the token itself stays until a code pairing replaces it (an
    /// address typo that reaches some other Couchpad host must not wipe a good pairing).
    /// Cleared on pairing, on returning to the app, on selecting the device, and on editing
    /// its address.
    private var refusals: [UUID: String] = [:]
    /// The service the session was on when the app went to the background, if it had
    /// worked: returning tries it at once instead of waiting for Bonjour to find it again.
    /// The service endpoint is name-based and resolved afresh, never a cached IP, which on
    /// another network could be some other host.
    private var resumeService: Service?
    /// A throwaway TCP connection to the target's service while the session runs by
    /// address (`startProbe`), its retry, and the hold after a move that didn't work.
    private var probe: NWConnection?
    private var probeRetry: Task<Void, Never>?
    private var probeHoldUntil = Date.distantPast
    /// The current service connection is a probe's move, not yet proven by a handshake.
    private var movedByProbe = false
    /// The addresses being raced (`startRace`), and whether each has failed or is waiting
    /// for a route. A race is an attempt in flight, like `connection`.
    private var race: [Runner] = []
    private var raceTimeout: Task<Void, Never>?
    private var isRacing: Bool { !race.isEmpty }
    /// Addresses whose attempt ended before a host answered on them (a winner that accepted
    /// and never spoke, or dropped): left out of the next races, so the attempt after goes to
    /// another one, until there is none left (then all again). Cleared by a session, a new
    /// target and returning to the app.
    private var leftOut: Set<String> = []
    private let queue = DispatchQueue(label: "couchpad.client")
    private let defaults = UserDefaults.standard

    private enum Credential { case token(String), code(String) }

    private struct Runner {
        let address: String
        let connection: NWConnection
        var out = false
    }

    init() {
        DeviceStore.migrateIfNeeded(defaults)
        let saved = DeviceStore.load(from: defaults)
        devices = saved.devices
        selectedID = saved.selected
    }

    // MARK: Lifecycle

    func startBrowsing() {
        guard browser == nil else { return }
        bonjourGrace = Date().addingTimeInterval(1)
        restartBrowser()
        // A device reached only by address connects at once; one expected on the local
        // network waits out the grace (Bonjour only calls back when it finds something).
        autoConnect()
    }

    func appDidEnterBackground() {
        // Before anything resets: the service this session was on, if it had worked.
        if case .service(let name)? = lastRoute, routeWorked, let service = services.first(where: { $0.name == name }) {
            resumeService = service
        } else {
            resumeService = nil
        }
        inBackground = true
        pinned = nil
        cancelRetry()
        cancelProbe()
        cancelRace()
        addressEdit?.cancel()
        // A clean close: the host sees the FIN right away instead of a dead socket later.
        if let connection {
            connection.cancel()
            self.connection = nil
        }
        videoLink?.cancel()
        videoLink = nil
        stopSound()
        phase = .disconnected
        status = "Paused"
    }

    func appDidBecomeActive() {
        guard inBackground else { return }
        inBackground = false
        pinned = nil
        failures = 0
        unreachable = false
        refusals.removeAll()
        pairingNote = nil
        lastRoute = nil
        routeWorked = false
        leftOut.removeAll()
        // Results from before the suspension may be from another network (the phone left
        // home): start from none, and give Bonjour its moment again.
        services = []
        bonjourGrace = Date().addingTimeInterval(1)
        restartBrowser()
        // On the service before: straight back to it (at home that is where it will be,
        // without waiting on Bonjour). With an address to fall back on, the attempt gets a
        // second: not connected by then, the retry moves on (`pickRoute`: a service that
        // didn't work, and isn't listed, gives way to the address). With none, it is left
        // to the usual timeouts.
        if let service = resumeService, connection == nil, !isRacing, let device = targetDevice, device.serviceName == service.name {
            open(.service(service.name))
            if !device.addressCandidates.isEmpty { scheduleRetry(after: 1) }
            return
        }
        autoConnect()
    }

    private func restartBrowser() {
        browser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: "_couchpad._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { result -> Service? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return Service(id: name, name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in
                guard let self else { return }
                self.services = list
                self.servicesChanged()
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    // MARK: Devices

    /// Connects to a saved device from now on (and at launch). Selecting the one already
    /// connected changes nothing; selecting it again while it isn't connected starts over,
    /// token included.
    func select(_ id: UUID) {
        guard devices.contains(where: { $0.id == id }) else { return }
        refusals[id] = nil
        setSelection(id)
        if currentDeviceID == id, isConnected { return }
        retarget(.device(id))
    }

    /// A row tapped on the profile screen: this device, by exactly that route, now (the
    /// service only while Bonjour lists it). Pinned for the one connection (`pinned`).
    func connect(_ id: UUID, by route: Route) {
        guard route != .addresses, devices.contains(where: { $0.id == id }) else { return }
        if currentDeviceID == id, activeRoute == route { return }
        refusals[id] = nil
        setSelection(id)
        retarget(.device(id), prefer: route)
        // Not available after all (the service gone): the usual rules have picked instead.
        if lastRoute == route { pinned = route }
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }), devices[i].name != name else { return }
        devices[i].name = name
        saveDevices()
        if currentDeviceID == id { macName = devices[i].displayName }
    }

    /// Saved as it is typed. Clears a refusal (the refusal may have come from the wrong
    /// address), and if this device is the target and not connected, reconnects once the
    /// typing pauses.
    func setAddress(_ address: String, for id: UUID) {
        guard let i = devices.firstIndex(where: { $0.id == id }), devices[i].address != address else { return }
        devices[i].address = address
        saveDevices()
        refusals[id] = nil
        guard currentDeviceID == id, !isConnected else { return }
        pairingNote = nil
        addressEdit?.cancel()
        addressEdit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, !self.inBackground, self.currentDeviceID == id, !self.isConnected else { return }
            self.retarget(.device(id))
        }
    }

    /// Removes the profile, token and all. If it was the target, the connection goes and the
    /// app moves on to the next saved device (or, with none left, whatever it finds).
    func forget(_ id: UUID) {
        devices.removeAll { $0.id == id }
        refusals[id] = nil
        saveDevices()
        if selectedID == id { setSelection(devices.first?.id) }
        guard currentDeviceID == id else { return }
        closeConnection()
        target = nil
        lastRoute = nil
        leftOut.removeAll()
        failures = 0
        unreachable = false
        pairingNote = nil
        phase = .searching
        macName = ""
        status = "Looking for your computer…"
        autoConnect()
    }

    private func setSelection(_ id: UUID?) {
        guard selectedID != id else { return }
        selectedID = id
        DeviceStore.saveSelection(id, to: defaults)
    }

    private func saveDevices() {
        DeviceStore.save(devices, to: defaults)
    }

    private var targetDevice: Device? {
        switch target {
        case .device(let id)?: devices.first { $0.id == id }
        case .new(let device)?: device
        case nil: nil
        }
    }

    // MARK: Connecting

    /// With nothing connected: on to the target, picking one first if there is none (the
    /// selected device, or the first saved one, or on a first run whatever Bonjour finds,
    /// which leads to the pairing prompt).
    private func autoConnect() {
        guard connection == nil, !isRacing, !inBackground else { return }
        // An unpaired computer that has left the network: nothing ties the phone to it, so
        // pick again rather than wait for it while another one is there.
        if case .new(let device)? = target, routes(for: device).isEmpty {
            target = nil
            lastRoute = nil
            pairingNote = nil
            macName = ""
        }
        guard target != nil else {
            if let id = selectedID ?? devices.first?.id {
                setSelection(id)
                retarget(.device(id))
            } else if devices.isEmpty, let service = services.first {
                retarget(.new(Device(name: service.name, serviceName: service.name)))
            } else {
                phase = .searching
                status = "Looking for your computer…"
            }
            return
        }
        connectTarget()
    }

    /// Bonjour's results changed. A connection (or race) still trying the addresses gives
    /// way to the local network as soon as the target shows up there; a working one by
    /// address moves over once a probe shows the service answers (`startProbe`).
    private func servicesChanged() {
        if !inBackground, pinned == nil, let device = targetDevice, let name = device.serviceName,
           services.contains(where: { $0.name == name }), lastRoute != .service(name),
           connection != nil || isRacing {
            if let connection, connection.state == .ready {
                startProbe()
            } else {
                closeConnection()
                connectTarget(prefer: .service(name))
            }
            return
        }
        autoConnect()
    }

    // MARK: Moving to the local network

    /// The service to move to: the target is connected (or at the pairing prompt on a live
    /// connection) by address, and Bonjour lists its service.
    private var probeCandidate: (device: UUID, service: Service)? {
        guard !inBackground, pinned == nil, lastRoute?.address != nil, let connection, connection.state == .ready,
              let device = targetDevice, let name = device.serviceName,
              let service = services.first(where: { $0.name == name }) else { return nil }
        return (device.id, service)
    }

    /// Connected by address with the computer advertised on the local network: a plain TCP
    /// connection to the service, which says nothing (hosts ignore that), checks the
    /// advertisement is reachable before the working session is given up for it. Only once
    /// it connects does the session move; failing or waiting, it ends and is tried again
    /// 10 s later while all this still holds. One at a time.
    private func startProbe() {
        // (A pending retry is the next attempt: Bonjour churning doesn't bring it forward.)
        guard probe == nil, probeRetry == nil, let candidate = probeCandidate else { return }
        let hold = probeHoldUntil.timeIntervalSinceNow
        if hold > 0 {
            scheduleProbe(after: hold)
            return
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 3
        let probe = NWConnection(to: candidate.service.endpoint, using: NWParameters(tls: nil, tcp: tcp))
        probe.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.probe === probe else { return }
                switch state {
                case .ready:
                    self.cancelProbe()
                    // Still the same device, still by address, service still listed.
                    guard let now = self.probeCandidate, now.device == candidate.device,
                          now.service.name == candidate.service.name else { return }
                    self.closeConnection()
                    self.movedByProbe = true
                    self.connectTarget(prefer: .service(now.service.name))
                case .waiting, .failed:
                    self.cancelProbe()
                    self.scheduleProbe(after: 10)
                default:
                    break
                }
            }
        }
        self.probe = probe
        probe.start(queue: queue)
    }

    private func scheduleProbe(after seconds: Double) {
        probeRetry?.cancel()
        probeRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.probeRetry = nil
            self.startProbe()
        }
    }

    private func cancelProbe() {
        probe?.cancel()
        probe = nil
        probeRetry?.cancel()
        probeRetry = nil
    }

    /// A connection made by a probe's move that failed before a host answered: the
    /// advertisement isn't reachable after all (TCP accepted, no Couchpad there). The usual
    /// failover goes back to the address; no more probes for a minute, so it doesn't flap.
    private func noteMoveFailed() {
        guard movedByProbe else { return }
        movedByProbe = false
        if !routeWorked { probeHoldUntil = Date().addingTimeInterval(60) }
    }

    /// Discovered service a user tapped: a saved device's is that device; any other is a
    /// computer to pair with.
    func connect(to service: Service) {
        if let device = devices.first(where: { $0.serviceName == service.name }) {
            select(device.id)
        } else {
            retarget(.new(Device(name: service.name, serviceName: service.name)))
        }
    }

    /// "Add a computer by address": an address a saved device already has is that device;
    /// any other becomes a device of its own once it pairs. False if it isn't an address.
    @discardableResult
    func connect(address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HostAddress(trimmed) != nil else { return false }
        if let device = devices.first(where: { $0.address == trimmed || $0.pairedAddress == trimmed || $0.knownAddresses.contains(trimmed) }) {
            select(device.id)
        } else {
            retarget(.new(Device(name: trimmed, address: trimmed)))
        }
        return true
    }

    /// Switches to a new target: the current connection goes, the route choice and backoff
    /// start over.
    private func retarget(_ new: Target, code: String? = nil, prefer: Route? = nil) {
        closeConnection()
        target = new
        lastRoute = nil
        routeWorked = false
        leftOut.removeAll()
        failures = 0
        unreachable = false
        movedByProbe = false
        resumeService = nil
        pendingCode = code
        guard let device = targetDevice else { return }
        pairingNote = refusals[device.id]
        hostPlatform = device.platform
        macName = device.displayName
        phase = .connecting
        connectTarget(prefer: prefer)
    }

    /// The device's routes that can be tried right now, best first: the service while
    /// Bonjour finds it, then its addresses (together, `openAddresses`).
    private func routes(for device: Device) -> [Route] {
        var routes: [Route] = []
        if let name = device.serviceName, services.contains(where: { $0.name == name }) { routes.append(.service(name)) }
        if !device.addressCandidates.isEmpty { routes.append(.addresses) }
        return routes
    }

    /// The route for the next attempt. The first, unless there was a last one: a route a
    /// host answered on is tried again (the host hung up after a refusal, or the link
    /// blipped; an address, by racing them all again); one that failed gives way to the
    /// other, so a failing service alternates with the addresses.
    private func pickRoute(_ routes: [Route]) -> Route? {
        guard let last = lastRoute else { return routes.first }
        let kind: Route = if case .service = last { last } else { .addresses }
        guard let i = routes.firstIndex(of: kind) else { return routes.first }
        return routeWorked ? routes[i] : routes[(i + 1) % routes.count]
    }

    /// The address step: a single address is opened as it is (as before there were several);
    /// several are raced, less those left out (all of them, should that leave none).
    private func openAddresses(_ device: Device) {
        let all = device.addressCandidates
        var candidates = all.filter { !leftOut.contains($0) }
        if candidates.isEmpty {
            leftOut.removeAll()
            candidates = all
        }
        if candidates.count == 1 {
            open(.address(candidates[0]))
        } else if !candidates.isEmpty {
            startRace(candidates)
        }
    }

    private func attempt(_ route: Route, on device: Device) {
        if route == .addresses { openAddresses(device) } else { open(route) }
    }

    private func connectTarget(prefer: Route? = nil) {
        guard !inBackground, let device = targetDevice else { return }
        macName = device.displayName
        let routes = routes(for: device)
        // (A single address is preferred by a pairing URL without `addrs`.)
        if let prefer, routes.contains(prefer) || prefer.address.map({ device.addressCandidates.contains($0) }) == true {
            attempt(prefer, on: device)
            return
        }
        let local = device.serviceName.map { routes.contains(.service($0)) } ?? false
        if !local, device.serviceName != nil, lastRoute == nil, Date() < bonjourGrace {
            if phase != .needsCode && phase != .wrongCode { phase = .connecting }
            status = "Looking for \(macName)…"
            scheduleRetry(after: max(0.05, bonjourGrace.timeIntervalSinceNow))
            return
        }
        guard let route = pickRoute(routes) else {
            // Only ever found on the local network, and not there now: the browser calls
            // back when it is.
            if phase != .needsCode && phase != .wrongCode { phase = .searching }
            status = "Looking for \(macName) on the local network…"
            return
        }
        attempt(route, on: device)
    }

    private func endpoint(for route: Route) -> NWEndpoint? {
        switch route {
        case .service(let name):
            // Not listed (yet) on returning to the app: the service it was on before.
            return services.first { $0.name == name }?.endpoint
                ?? resumeService.flatMap { $0.name == name ? $0.endpoint : nil }
        case .address(let text):
            guard let address = HostAddress(text), let port = NWEndpoint.Port(rawValue: address.port) else { return nil }
            return .hostPort(host: NWEndpoint.Host(address.host), port: port)
        case .addresses:
            return nil
        }
    }

    /// The target's name, with the address when it is reached by one, so the status says
    /// which way it is connected ("Connected to Studio (100.64.0.2)").
    private var targetLabel: String {
        guard let address = lastRoute?.address, address != macName else { return macName }
        return "\(macName) (\(address))"
    }

    private func closeConnection() {
        pinned = nil
        cancelRetry()
        cancelProbe()
        cancelRace()
        addressEdit?.cancel()
        connection?.cancel()
        connection = nil
        receiving = false
        videoLink?.cancel()
        videoLink = nil
    }

    private func open(_ route: Route) {
        guard let endpoint = endpoint(for: route) else { return }
        if route != pinned { pinned = nil }
        cancelRetry()
        cancelProbe()
        cancelRace()
        connection?.cancel()
        videoLink?.cancel()
        videoLink = nil
        audio.reset()   // whatever is queued belongs to the old session
        receiving = false
        buffer = FrameBuffer()
        privateKey = P256.KeyAgreement.PrivateKey()
        sendCipher = nil
        recvCipher = nil
        sentCredential = nil
        lastRoute = route
        routeWorked = false
        // Reconnecting with the pairing prompt up (the host hangs up after a refusal or a
        // wrong code) keeps it up, rather than taking its field away for a moment.
        let pairing = phase == .needsCode || phase == .wrongCode
        if !pairing { phase = .connecting }
        let label = targetLabel
        // (At the prompt with the computer gone, its "Can't reach" line stays.)
        if !(pairing && unreachable) {
            status = failures == 0 ? "Connecting to \(label)…" : "Reconnecting to \(label)…"
        }

        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        // Voice class: the input lines are tiny and latency-critical, and an active
        // voice-class connection makes iOS hold off Wi-Fi roaming scans, which otherwise
        // black the radio out for most of a second at a time (and freeze the picture).
        params.serviceClass = .interactiveVoice
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.connectionTimeout = 5
        let connection = NWConnection(to: endpoint, using: params)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.failures = 0
                    guard !self.receiving else { return } // the path recovered; the session is already set up
                    self.receiving = true
                    self.receive(on: connection)
                    // Handshake: our ephemeral public key, in the clear. Secrets come later, encrypted.
                    let hello = "v2 \(self.privateKey.publicKey.rawRepresentation.base64EncodedString())\n"
                    connection.send(content: Data(hello.utf8), completion: .contentProcessed { _ in })
                case .waiting(let error):
                    // No route yet (Wi-Fi coming back, host restarting, left home). Give it a
                    // moment, then retry fresh, on the next route if this one never worked.
                    if self.phase != .needsCode && self.phase != .wrongCode {
                        self.phase = .connecting
                        self.status = "Can't reach \(label): \(error.localizedDescription)"
                    } else {
                        // On the pairing prompt, which shows it: the plain version.
                        self.status = "Can't reach \(label)"
                    }
                    self.unreachable = true
                    self.pinned = nil
                    self.noteMoveFailed()
                    self.noteAddressFailed()
                    // Called again each time the error changes: a sooner retry stays due.
                    self.scheduleRetry(after: 3, keepSooner: true)
                case .failed, .cancelled:
                    self.connection = nil
                    self.receiving = false
                    self.pinned = nil
                    if !self.inBackground {
                        self.noteMoveFailed()
                        self.noteAddressFailed()
                        if self.phase != .wrongCode && self.phase != .needsCode { self.phase = .disconnected }
                        self.failures += 1
                        // Twice running: gone, not a host hanging up after a refusal or a wrong code.
                        if self.failures >= 2 { self.unreachable = true }
                        if self.phase == .disconnected {
                            self.status = "Disconnected from \(label)"
                        } else if self.unreachable {
                            self.status = "Can't reach \(label)"
                        }
                        self.scheduleRetry(after: min(Double(self.failures), 5))
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        self.connection = connection
        // An attempt that neither connects nor fails is given up on, and the retry moves to
        // the next route: a service that has gone away can sit resolving indefinitely (seen:
        // host quit, the browser still listing it, the reconnect hanging for good). A
        // service with an address to fall back on gets 2 s, anything else outlasts TCP's 5 s.
        let fallback = targetDevice.map { !$0.addressCandidates.isEmpty } ?? false
        if case .service = route, fallback {
            scheduleRetry(after: 2)
        } else {
            scheduleRetry(after: 6)
        }
    }

    /// `keepSooner`: a retry already due sooner stays as it is, rather than being put back.
    private func scheduleRetry(after seconds: Double, keepSooner: Bool = false) {
        let due = Date().addingTimeInterval(seconds)
        if keepSooner, retryTask != nil, let pending = retryDue, pending <= due { return }
        retryTask?.cancel()
        retryDue = due
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.retryDue = nil
            guard !self.inBackground else { return }
            // Connected and answered: nothing to retry. Connected but silent counts as not
            // (something that accepts and never answers the handshake), or the attempt
            // would sit there for good, a probe's move having given up a working session for it.
            if let connection = self.connection, connection.state == .ready, self.recvCipher != nil { return }
            self.pinned = nil
            self.noteMoveFailed()
            if self.connection != nil { self.noteAddressFailed() }
            self.connection?.cancel()
            self.connection = nil
            self.autoConnect()
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryDue = nil
    }

    // MARK: Racing the addresses

    /// Several addresses, and no telling from here which of them works (at home, away, on
    /// the VPN or not): a plain TCP connection to each, saying nothing (hosts ignore that),
    /// and the first to connect gets the session (`open`). Among live addresses that costs
    /// one round trip; trying them in turn would wait out every dead one first, after any
    /// network change. No winner in 6 s, or every one failing or waiting for a route, is an
    /// attempt that can't reach the computer, like any other.
    private func startRace(_ candidates: [String]) {
        pinned = nil
        cancelRetry()
        cancelProbe()
        cancelRace()
        connection?.cancel()
        connection = nil
        receiving = false
        videoLink?.cancel()
        videoLink = nil
        lastRoute = .addresses
        routeWorked = false
        // As in `open`: the pairing prompt stays up, and so does its "Can't reach" line.
        let pairing = phase == .needsCode || phase == .wrongCode
        if !pairing { phase = .connecting }
        if !(pairing && unreachable) {
            status = failures == 0 ? "Connecting to \(macName)…" : "Reconnecting to \(macName)…"
        }
        for address in candidates {
            guard let endpoint = endpoint(for: .address(address)) else { continue }
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 5
            let runner = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
            runner.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let i = self.race.firstIndex(where: { $0.connection === runner }) else { return }
                    switch state {
                    case .ready:
                        self.cancelRace()
                        self.open(.address(address))
                    case .waiting, .failed:
                        self.race[i].out = true
                        if self.race.allSatisfy(\.out) { self.raceFailed() }
                    default:
                        break
                    }
                }
            }
            race.append(Runner(address: address, connection: runner))
            runner.start(queue: queue)
        }
        guard isRacing else { return raceFailed() }
        raceTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.isRacing else { return }
            self.raceFailed()
        }
    }

    /// No address connected: the "Can't reach" of an `open` that waits or fails. The retry
    /// starts from the service again if Bonjour lists it (`pickRoute`).
    private func raceFailed() {
        cancelRace()
        guard !inBackground else { return }
        if phase != .needsCode && phase != .wrongCode { phase = .connecting }
        status = "Can't reach \(macName)"
        unreachable = true
        failures += 1
        scheduleRetry(after: 3)
    }

    private func cancelRace() {
        for runner in race { runner.connection.cancel() }
        race = []
        raceTimeout?.cancel()
        raceTimeout = nil
    }

    /// The current attempt by address ended before a host answered on it: left out of the
    /// next races (`leftOut`).
    private func noteAddressFailed() {
        guard !routeWorked, case .address(let address)? = lastRoute else { return }
        leftOut.insert(address)
    }

    // MARK: Handshake and pairing

    /// The host answered our key with its own: derive the session and authenticate inside it.
    private func completeHandshake(_ line: String) throws {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "v2",
              let hostKey = Data(base64Encoded: String(parts[1])), hostKey.count == 64,
              let nonce = Data(base64Encoded: String(parts[2])), nonce.count == 16 else {
            throw CryptoKitError.incorrectParameterSize
        }
        let key = try SecureChannel.sessionKey(privateKey: privateKey, peerPublicKey: hostKey, nonce: nonce)
        transcript = SecureChannel.transcript(clientKey: privateKey.publicKey.rawRepresentation, hostKey: hostKey, nonce: nonce)
        sendCipher = FrameCipher(key: key, direction: 0)
        recvCipher = FrameCipher(key: key, direction: 1)
        sessionKey = key
        routeWorked = true   // a Couchpad host answers on this route
        movedByProbe = false
        unreachable = false

        let device = targetDevice
        if let code = pendingCode {
            pendingCode = nil
            authenticate(.code(code))
        } else if let device, let token = device.token, refusals[device.id] == nil {
            authenticate(.token(token))
        } else if phase != .wrongCode {
            // (After a wrong code the host hangs up and we reconnect; keep that message.)
            phase = .needsCode
            status = device.flatMap { refusals[$0.id] } ?? "Enter the code shown on \(macName)"
        } else {
            status = wrongCodeStatus
        }
    }

    private var wrongCodeStatus: String { "Wrong or expired code. Check the pairing window on \(macName)" }

    private func authenticate(_ credential: Credential) {
        sentCredential = credential
        let kind: String, secret: String
        switch credential {
        case .token(let t): kind = "token"; secret = t; status = "Connecting to \(targetLabel)…"
        case .code(let c): kind = "code"; secret = c; status = "Pairing with \(macName)…"
        }
        phase = .connecting
        let proof = SecureChannel.proof(secret: secret, transcript: transcript, side: SecureChannel.clientTag)
        sendLine("auth \(kind) \(proof.base64EncodedString())")
    }

    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if sendCipher != nil, connection != nil {
            authenticate(.code(trimmed))
        } else {
            // The host hung up after a wrong guess; pair on the next connection.
            pendingCode = trimmed
            phase = .connecting
            scheduleRetry(after: 0.1)
        }
    }

    /// Pairs from a scanned or opened `couchpad://pair?name=&addr=&port=&code=` URL, with
    /// `addrs=` (the computer's other IPv4 addresses, comma-separated) from newer hosts.
    /// Connects straight to the address, so this works even where Bonjour is blocked; the
    /// address is kept as the device's `pairedAddress` (with the port, if not the usual one),
    /// and the others as its `knownAddresses`, raced along with it. A saved device found
    /// under that name gets its token replaced; any other computer becomes a device once it
    /// pairs.
    @discardableResult
    func pair(using url: URL) -> Bool {
        guard url.scheme == "couchpad", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        guard let code = value("code") else { return false }
        let name = value("name")
        let existing = name.flatMap { name in devices.first { $0.serviceName == name } }
        if let addr = value("addr") {
            let port = UInt16(value("port") ?? "") ?? servicePort
            let paired = HostAddress.string(host: addr, port: port)
            let extras = value("addrs").map { list in
                HostAddress.announced(list.split(separator: ",").map(String.init), port: port).filter { $0 != paired }
            }
            // Without `addrs`, as before: the QR's address alone.
            let prefer: Route = extras == nil ? .address(paired) : .addresses
            if let existing, let i = devices.firstIndex(of: existing) {
                devices[i].pairedAddress = paired
                if let extras { devices[i].knownAddresses = extras }
                saveDevices()
                setSelection(existing.id)
                retarget(.device(existing.id), code: code, prefer: prefer)
            } else {
                let device = Device(name: name ?? addr, serviceName: name, pairedAddress: paired, knownAddresses: extras ?? [])
                retarget(.new(device), code: code, prefer: prefer)
            }
            return true
        }
        if let name, let service = services.first(where: { $0.name == name }) {
            if let existing {
                setSelection(existing.id)
                retarget(.device(existing.id), code: code, prefer: .service(service.name))
            } else {
                retarget(.new(Device(name: name, serviceName: name)), code: code)
            }
            return true
        }
        return false
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ")
        if parts.first == "screen", parts.count >= 7, parts[1] == "health",
           let ack = Int(parts[3]), let lost = Int(parts[4]), let skipped = Int(parts[5]), let phones = Int(parts[6]) {
            onScreenHealth?(ScreenHealth(ok: parts[2] == "1", ackMs: ack, lostPerSecond: lost, skippedPercent: skipped, phones: phones))
        } else if parts.first == "screen", parts.count >= 2 {
            onScreenStatus?(String(line.dropFirst(7)))
        } else if parts.first == "ok", parts.count >= 4, let hostProof = Data(base64Encoded: String(parts[3])) {
            let token = String(parts[1])
            // The host must prove it knows the token too; an impostor can't.
            guard SecureChannel.proofMatches(hostProof, secret: token, transcript: transcript, side: SecureChannel.hostTag) else {
                status = "\(macName) failed to prove itself; not connecting"
                connection?.cancel()
                return
            }
            guard var device = targetDevice else { return }
            device.token = token
            device.platform = parts[2] == "windows" ? .windows : .mac
            if case .new = target {
                // Paired with something new: it is a device from now on (or, should the
                // service already have one, that device gets the new token).
                if let i = devices.firstIndex(where: { $0.serviceName != nil && $0.serviceName == device.serviceName }) {
                    devices[i].token = token
                    devices[i].platform = device.platform
                    if devices[i].pairedAddress == nil { devices[i].pairedAddress = device.pairedAddress }
                    if !device.knownAddresses.isEmpty { devices[i].knownAddresses = device.knownAddresses }
                    device = devices[i]
                } else {
                    devices.append(device)
                }
                target = .device(device.id)
            } else if let i = devices.firstIndex(where: { $0.id == device.id }) {
                devices[i] = device
            }
            saveDevices()
            setSelection(device.id)
            refusals[device.id] = nil
            leftOut.removeAll()
            pairingNote = nil
            hostPlatform = device.platform
            phase = .paired
            status = "Connected to \(targetLabel)"
            if hostPlatform == .mac { startVideoLink() }
            // Connected by address while Bonjour already lists the computer: move over.
            if lastRoute?.address != nil { startProbe() }
        } else if parts.first == "addrs" {
            // `addrs <port> <ip> …`: every address the computer has, VPN tunnels included,
            // sent after `ok`. Only from a host that has proven itself on this connection;
            // kept for when it isn't on the local network (`Device.knownAddresses`).
            guard phase == .paired, parts.count >= 2, let port = UInt16(parts[1]),
                  let id = currentDeviceID, let i = devices.firstIndex(where: { $0.id == id }) else { return }
            let known = HostAddress.announced(parts.dropFirst(2).map(String.init), port: port)
            guard devices[i].knownAddresses != known else { return }
            devices[i].knownAddresses = known
            saveDevices()
        } else if line == "nope" {
            switch sentCredential {
            case .token:
                // The token stays: it may be good and this the wrong host (a typo in the
                // address can reach some other Couchpad host). The prompt comes up instead,
                // and a code pairing replaces the token.
                // Only a typed address can be a typo worth checking.
                let typed = targetDevice?.address.trimmingCharacters(in: .whitespaces)
                let note = lastRoute?.address.map {
                    $0 == typed ? "\($0) didn't recognize this phone: check the address, or pair again"
                        : "\(macName) at \($0) didn't recognize this phone. Pair again to use it"
                } ?? "\(macName) no longer recognizes this phone"
                if let id = targetDevice?.id { refusals[id] = note }
                pairingNote = note
                phase = .needsCode
                status = note
            case .code:
                phase = .wrongCode
                status = wrongCodeStatus
            case nil:
                break
            }
            sentCredential = nil
        }
    }

    // MARK: I/O

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                if let data { self.buffer.append(data) }
                do {
                    if self.recvCipher == nil, let line = self.buffer.nextLine() {
                        try self.completeHandshake(line)
                    }
                    if let cipher = self.recvCipher {
                        while let body = try self.buffer.next() {
                            let plain = try cipher.openData(body)
                            if plain.first == ScreenPacket.marker {
                                guard self.isConnected else { continue }
                                if plain.count >= 2, plain[plain.startIndex + 1] == AudioPacket.messageType {
                                    if let packet = AudioPacket.decode(plain) { self.audio.receive(packet) }
                                } else {
                                    self.onScreenPacket?(plain)
                                }
                            } else {
                                self.handle(String(decoding: plain, as: UTF8.self))
                            }
                        }
                    }
                } catch {
                    self.status = "\(self.macName) isn't speaking Couchpad's protocol"
                    connection.cancel()
                    return
                }
                if isComplete || error != nil {
                    // The host closed the socket; treat it like a failure so we reconnect.
                    connection.cancel()
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    /// Input commands; dropped until pairing has succeeded.
    func send(_ line: String) {
        guard isConnected, let connection, connection.state == .ready else { return }
        if line.hasPrefix("v 1 ") { screenWanted = true; videoLink?.setWanted(true) }
        if line == "v 0" { screenWanted = false; videoLink?.setWanted(false) }
        sendLine(line)
    }

    /// Tells the host a frame arrived, over UDP when that is what carries the picture.
    func ackFrame(_ pts: UInt64) {
        if let videoLink, videoLink.isLive { videoLink.ack(pts) } else { send("v a \(pts)") }
    }

    /// Sound with the picture: tells the host (it only sends sound to a phone that has the
    /// picture on and asked for it) and starts or stops the player. Sent right after every
    /// `v 1 …` and whenever the setting changes.
    func setSound(_ on: Bool) {
        send(on ? "v s 1" : "v s 0")
        guard on, isConnected else {
            stopSound()
            return
        }
        audio.start()
        guard audioReports == nil else { return }
        // The host's stats line: what arrived, what was lost, how deep the buffer is.
        audioReports = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if let report = self.audio.takeReport() { self.send(AudioPacket.reportLine(report)) }
            }
        }
    }

    private func stopSound() {
        audio.stop()
        audioReports?.cancel()
        audioReports = nil
    }

    /// Opens the UDP sideband to the host's resolved address: the host starts sending frames
    /// as datagrams once a hello reaches it. Without one (UDP blocked, address unknown) the
    /// picture simply stays on TCP.
    private func startVideoLink() {
        videoLink?.cancel()
        videoLink = nil
        guard let connection, let key = sessionKey,
              case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint else { return }
        let link = VideoLink(host: host, port: port, sessionKey: key)
        link.onFrame = { [weak self] frame in
            Task { @MainActor in
                guard let self, self.isConnected, self.videoLink === link else { return }
                self.onScreenPacket?(frame)
            }
        }
        link.onLoss = { [weak self] frames, chunks in
            Task { @MainActor in
                guard let self, self.videoLink === link else { return }
                self.onScreenLoss?()
                self.send("v l \(frames) \(chunks)")
            }
        }
        link.onStall = { [weak self] in
            Task { @MainActor in
                guard let self, self.videoLink === link, self.screenWanted else { return }
                self.send("v t")
            }
        }
        // Straight from the link's queue: a hop through the main actor would add its layout
        // work's jitter to every packet.
        link.onAudio = { [audio] packet in audio.receive(packet) }
        link.start()
        if screenWanted { link.setWanted(true) }
        videoLink = link
    }

    private func sendLine(_ line: String) {
        guard let connection, let cipher = sendCipher, let frame = try? cipher.seal(line) else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }
}
