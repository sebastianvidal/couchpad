import AppKit
import ApplicationServices
import ServiceManagement

let servicePort: UInt16 = 48123

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let codeLine = NSMenuItem(title: "Pair an iPhone…", action: #selector(showPairingCode), keyEquivalent: "")
    private let addressLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let axLine = NSMenuItem(title: "", action: #selector(requestAccessibility), keyEquivalent: "")
    private let screenLine = NSMenuItem(title: "", action: #selector(requestScreenRecording), keyEquivalent: "")
    private let loginLine = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let forgetLine = NSMenuItem(title: "Forget Paired iPhones…", action: #selector(forgetPhones), keyEquivalent: "")
    private var server: Server?
    private let pairingWindow = PairingWindow()

    /// Keeps the process out of App Nap and timer coalescing: a menu-bar app with no window
    /// looks idle to macOS, and a napping host paces its datagrams on a lazy clock.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Forwarding input and streaming the screen")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Couchpad")

        menu.delegate = self
        menu.addItem(statusLine)
        menu.addItem(codeLine)
        menu.addItem(addressLine)
        menu.addItem(axLine)
        menu.addItem(screenLine)
        menu.addItem(.separator())
        menu.addItem(loginLine)
        menu.addItem(forgetLine)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Couchpad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in [codeLine, axLine, screenLine, loginLine, forgetLine] { item.target = self }
        statusItem.menu = menu

        refreshAccessibility(prompt: true)
        refreshScreenRecording()

        pairingWindow.payloadProvider = { [weak self] in self?.pairingPayload() ?? "" }
        Pairing.shared.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.pairingWindow.handle(event)
                self?.refresh()
            }
        }

        do {
            let server = try Server(port: servicePort) { [weak self] in
                DispatchQueue.main.async { self?.refresh() }
            }
            server.start()
            self.server = server
        } catch {
            statusLine.title = "Could not start: \(error.localizedDescription)"
        }
        refresh()
        // `--pair` opens the pairing window at launch (used by automated tests of the pairing flow).
        if CommandLine.arguments.contains("--pair") { showPairingCode() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshAccessibility(prompt: false)
        refreshScreenRecording()
        refresh()
    }

    /// Screen Recording is only needed for the picture on the phone; the prompt appears the
    /// first time a phone asks for it, not at launch.
    private func refreshScreenRecording() {
        let granted = ScreenStreamer.hasPermission
        screenLine.title = granted ? "Screen Recording: granted" : "Screen Recording: not granted — needed to show the screen on the phone"
        screenLine.isEnabled = !granted
    }

    @objc private func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refresh() {
        statusLine.title = server?.status ?? statusLine.title
        // The icon itself says when the picture is struggling, so nobody has to open the menu.
        let struggling = server?.healthy == false
        statusItem.button?.image = NSImage(systemSymbolName: struggling ? "exclamationmark.triangle" : "cursorarrow.rays",
                                           accessibilityDescription: struggling ? "Couchpad — picture struggling" : "Couchpad")
        addressLine.title = "Address: \(localIPv4() ?? "?"):\(servicePort)"
        loginLine.state = SMAppService.mainApp.status == .enabled ? .on : .off
        forgetLine.isEnabled = Pairing.shared.pairedCount > 0
    }

    private func refreshAccessibility(prompt: Bool) {
        let trusted: Bool
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrusted()
        }
        axLine.title = trusted ? "Accessibility: granted" : "Accessibility: not granted — click to fix"
        axLine.isEnabled = !trusted
    }

    @objc private func showPairingCode() {
        pairingWindow.show()
    }

    private func pairingPayload() -> String {
        PairingURL.make(name: Host.current().localizedName ?? "Mac", address: localIPv4(),
                        port: servicePort, code: Pairing.shared.code)
    }

    @objc private func requestAccessibility() {
        refreshAccessibility(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
        refresh()
    }

    @objc private func forgetPhones() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Forget all paired iPhones?"
        alert.informativeText = "Every phone will need the pairing code again."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Pairing.shared.forgetAll()
        server?.disconnectAll()
        refresh()
    }

    /// First routable IPv4 address, preferring the built-in interfaces (en*) over VPN tunnels.
    /// Read straight from the interface list: `Host.current().addresses` resolves the hostname
    /// through DNS and took 5 s on the main thread every time the menu opened.
    private func localIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, address: String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if address.hasPrefix("169.254.") { continue }
            candidates.append((String(cString: ifa.ifa_name), address))
        }
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.address
    }
}
