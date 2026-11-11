import AppKit
import CoreImage

/// Pairing payload shared by every host: the phone scans it, or opens it as a URL.
///   couchpad://pair?name=<host name>&addr=<ip>&port=48123&code=<6 digits>[&addrs=<ip>,<ip>…]
/// `addr` is the primary address; `addrs` lists the others (VPN tunnels and the like), and
/// is left out when there are none. Phones that predate it ignore it.
enum PairingURL {
    static func make(name: String, addresses: [String], port: UInt16, code: String) -> String {
        var components = URLComponents()
        components.scheme = "couchpad"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "addr", value: addresses.first),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "code", value: code),
        ]
        if addresses.count > 1 {
            components.queryItems!.append(URLQueryItem(name: "addrs", value: addresses.dropFirst().joined(separator: ",")))
        }
        return components.string ?? ""
    }
}

/// Floating window with the QR code and digits. The code is live only while this window is
/// open and for at most a minute; the window shows the countdown, an expired state with a
/// "New code" button, and a "Paired" state that closes itself.
final class PairingWindow: NSObject, NSWindowDelegate {
    /// Builds the QR payload for the current code (needs the host's address).
    var payloadProvider: (() -> String)?

    private let window: NSWindow
    private let imageView = NSImageView()
    private let codeLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let newCodeButton = NSButton(title: "New code", target: nil, action: nil)
    private var tick: Timer?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 430),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Pair with Couchpad"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.center()

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: 30, y: 170, width: 240, height: 240)

        codeLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        codeLabel.alignment = .center
        codeLabel.frame = NSRect(x: 20, y: 118, width: 260, height: 44)

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        countdownLabel.textColor = .secondaryLabelColor
        countdownLabel.alignment = .center
        countdownLabel.frame = NSRect(x: 20, y: 96, width: 260, height: 18)

        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.frame = NSRect(x: 24, y: 40, width: 252, height: 50)

        newCodeButton.target = self
        newCodeButton.action = #selector(newCode)
        newCodeButton.bezelStyle = .rounded
        newCodeButton.frame = NSRect(x: 100, y: 10, width: 100, height: 30)

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        for view in [imageView, codeLabel, countdownLabel, hintLabel, newCodeButton] { content.addSubview(view) }
        window.contentView = content
    }

    var isVisible: Bool { window.isVisible }

    /// Opens the window and starts a fresh one-minute code.
    func show() {
        Pairing.shared.beginPairing()
        showActive()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func handle(_ event: Pairing.Event) {
        guard window.isVisible else { return }
        switch event {
        case .codeChanged: showActive()
        case .expired: showExpired()
        case .paired: showPaired()
        }
    }

    private func showActive() {
        let code = Pairing.shared.code
        codeLabel.stringValue = code
        imageView.image = PairingWindow.qrImage(for: payloadProvider?() ?? "", size: 240)
        imageView.isHidden = false
        hintLabel.stringValue = "Scan with Couchpad on your iPhone (or with the Camera app), or type the code. One pairing per code."
        newCodeButton.isHidden = true
        updateCountdown()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateCountdown() }
    }

    private func updateCountdown() {
        let s = Pairing.shared.secondsRemaining
        countdownLabel.stringValue = s > 0 ? String(format: "Expires in 0:%02d", s) : ""
    }

    private func showExpired() {
        tick?.invalidate()
        imageView.isHidden = true
        codeLabel.stringValue = "Code expired"
        countdownLabel.stringValue = ""
        hintLabel.stringValue = "Codes only work for a minute. Get a new one to pair."
        newCodeButton.isHidden = false
    }

    private func showPaired() {
        tick?.invalidate()
        imageView.isHidden = true
        codeLabel.stringValue = "Paired ✓"
        countdownLabel.stringValue = ""
        hintLabel.stringValue = "Your iPhone is connected. You can close this window."
        newCodeButton.isHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.window.close() }
    }

    @objc private func newCode() {
        Pairing.shared.beginPairing()
        showActive()
    }

    func windowWillClose(_ notification: Notification) {
        tick?.invalidate()
        Pairing.shared.endPairing()
    }

    private static func qrImage(for text: String, size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
