import Foundation
import Network

/// The port hosts listen on, and the one an address without `:port` means.
let servicePort: UInt16 = 48123

enum HostPlatform: String, Codable { case mac, windows }

/// A computer this phone has paired with, and every way to reach it. One pairing (one token)
/// serves all of them: hosts accept their tokens from any address, so the same Mac found on
/// the local network and reached over a VPN is one device, not two.
///
/// Routes (see `Client.pickRoute`): the Bonjour service called `serviceName`, when it is
/// being found right now; else every address it is known by at once (`addressCandidates`).
struct Device: Codable, Identifiable, Hashable {
    var id = UUID()
    /// The label in the menus. Starts as the service name (or the address), editable.
    var name: String
    /// The Bonjour name it is found under on the local network; nil for a computer only ever
    /// reached by address.
    var serviceName: String?
    /// Typed into its profile, an override for what Couchpad can't learn (a host name, a
    /// forwarded port). `host` or `host:port`; "" for none.
    var address = ""
    /// The address a QR pairing carried (the computer's home address).
    var pairedAddress: String?
    /// What the computer said it has, the last time it connected (`addrs`), VPN tunnels
    /// included: how it is found away from home without anything typed. Written like
    /// `HostAddress.string(host:port:)`.
    var knownAddresses: [String] = []
    var token: String?
    /// From the last `ok`, so the pairing prompt names the right menu before it connects.
    var platform = HostPlatform.mac

    init(name: String, serviceName: String? = nil, address: String = "", pairedAddress: String? = nil,
         knownAddresses: [String] = [], token: String? = nil, platform: HostPlatform = .mac) {
        self.name = name
        self.serviceName = serviceName
        self.address = address
        self.pairedAddress = pairedAddress
        self.knownAddresses = knownAddresses
        self.token = token
        self.platform = platform
    }

    /// Lenient, so a profile saved by an older or newer build still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName)
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        pairedAddress = try c.decodeIfPresent(String.self, forKey: .pairedAddress)
        knownAddresses = (try? c.decodeIfPresent([String].self, forKey: .knownAddresses)) ?? []
        token = try c.decodeIfPresent(String.self, forKey: .token)
        platform = (try? c.decodeIfPresent(HostPlatform.self, forKey: .platform)) ?? .mac
    }

    /// Every address to try when the service isn't found, the typed one first, each once.
    var addressCandidates: [String] {
        Self.unique([address.trimmingCharacters(in: .whitespaces)] + learnedAddresses)
    }

    /// The ones nobody typed: what the computer reported, and its pairing QR code's.
    var learnedAddresses: [String] {
        Self.unique(knownAddresses + [pairedAddress].compactMap { $0 })
    }

    /// Valid addresses only, each once (`1.2.3.4` and `1.2.3.4:48123` are the same one).
    private static func unique(_ texts: [String]) -> [String] {
        var out: [String] = [], seen: [HostAddress] = []
        for text in texts {
            guard let parsed = HostAddress(text), !seen.contains(parsed) else { continue }
            seen.append(parsed)
            out.append(text)
        }
        return out
    }

    /// The name, or (emptied in its profile) what it is found by.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return serviceName ?? (address.isEmpty ? (pairedAddress ?? "Computer") : address)
    }
}

/// `host`, `host:port`, `[v6]:port`, or a bare IPv6 literal (several colons, so taken whole).
/// Without a port it is `servicePort`.
struct HostAddress: Equatable {
    var host: String
    var port: UInt16

    init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard !host.isEmpty else { return nil }
            if rest.isEmpty {
                self.init(host: host, port: servicePort)
            } else {
                guard rest.first == ":", let port = Self.port(rest.dropFirst()) else { return nil }
                self.init(host: host, port: port)
            }
            return
        }
        let colons = s.filter { $0 == ":" }.count
        if colons == 1 {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard !parts[0].isEmpty, let port = Self.port(parts[1]) else { return nil }
            self.init(host: String(parts[0]), port: port)
        } else {
            self.init(host: s, port: servicePort)
        }
    }

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// How a host and port are written back: the port only when it isn't the usual one,
    /// an IPv6 literal in brackets when it has one.
    static func string(host: String, port: UInt16) -> String {
        guard port != servicePort else { return host }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// The addresses a host announced (the `addrs` line, a pairing URL's `addrs`), as
    /// `knownAddresses` keeps them. Strict, since they come off the wire: numeric IPv4
    /// only (a name could resolve anywhere), no loopback, link-local, unspecified,
    /// multicast or broadcast, no duplicates, at most 8.
    static func announced(_ items: [String], port: UInt16) -> [String] {
        guard port > 0 else { return [] }
        var out: [String] = []
        for item in items {
            let octets = item.split(separator: ".", omittingEmptySubsequences: false)
            // Plain dotted quads: no leading zeros (octal to some parsers), no short forms.
            let plain = octets.allSatisfy { o in
                (1...3).contains(o.count) && o.allSatisfy { ("0"..."9").contains($0) } && (o.count == 1 || o.first != "0")
            }
            guard octets.count == 4, plain, let ip = IPv4Address(item), !ip.isLoopback, !ip.isLinkLocal, !ip.isMulticast,
                  ip != .any, ip != .broadcast else { continue }
            let text = string(host: item, port: port)
            if !out.contains(text) { out.append(text) }
            if out.count == 8 { break }
        }
        return out
    }

    private static func port(_ text: Substring) -> UInt16? {
        guard let port = UInt16(text), port > 0 else { return nil }
        return port
    }
}

/// Where the device list lives: JSON under `devices`, the selection as a UUID string under
/// `selectedDevice`. Also turns the old per-name keys into devices, once.
enum DeviceStore {
    static let devicesKey = "devices"
    static let selectedKey = "selectedDevice"

    static func load(from defaults: UserDefaults) -> (devices: [Device], selected: UUID?) {
        let devices = defaults.data(forKey: devicesKey).flatMap { try? JSONDecoder().decode([Device].self, from: $0) } ?? []
        let selected = defaults.string(forKey: selectedKey).flatMap(UUID.init(uuidString:))
        return (devices, selected.flatMap { id in devices.contains { $0.id == id } ? id : nil })
    }

    static func save(_ devices: [Device], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(devices) { defaults.set(data, forKey: devicesKey) }
    }

    static func saveSelection(_ id: UUID?, to defaults: UserDefaults) {
        if let id { defaults.set(id.uuidString, forKey: selectedKey) } else { defaults.removeObject(forKey: selectedKey) }
    }

    /// Before device profiles, tokens were kept per name (`token.<name>`, with `addr.<name>`
    /// from a QR pairing and `preferredHost` for the last one used), and a typed IP was a host
    /// of its own, named by the IP, with its own token (`manualHost` was the Settings field).
    /// Runs once: the first time there is no `devices` key.
    static func migrateIfNeeded(_ defaults: UserDefaults) {
        guard defaults.object(forKey: devicesKey) == nil else { return }
        let result = migrate(legacy: defaults.dictionaryRepresentation())
        save(result.devices, to: defaults)
        saveSelection(result.selected, to: defaults)
        for key in result.obsoleteKeys { defaults.removeObject(forKey: key) }
    }

    /// The migration itself, over the old keys (a defaults dictionary):
    /// - every `token.<name>` becomes a device; one whose name is the old `manualHost` was
    ///   reached by address (name = address = it, no service name), the others are Bonjour
    ///   names (name = service name, `pairedAddress` from `addr.<name>`);
    /// - with exactly one Bonjour-named device, a `manualHost` is that computer's VPN
    ///   address: it goes into that device's `address`, and the address's own token is
    ///   dropped (the host accepts the other one just as well). With several, which one it
    ///   belongs to is anyone's guess, so it stays a device of its own (if it was paired);
    /// - `preferredHost` becomes the selection.
    /// Returns the keys to delete as well.
    static func migrate(legacy: [String: Any]) -> (devices: [Device], selected: UUID?, obsoleteKeys: [String]) {
        let tokenPrefix = "token.", addressPrefix = "addr."
        var tokens: [(name: String, token: String)] = []
        var obsolete: [String] = []
        for (key, value) in legacy {
            if key.hasPrefix(tokenPrefix) {
                obsolete.append(key)
                if let token = value as? String, !token.isEmpty {
                    tokens.append((String(key.dropFirst(tokenPrefix.count)), token))
                }
            } else if key.hasPrefix(addressPrefix) {
                obsolete.append(key)
            }
        }
        for key in ["preferredHost", "manualHost"] where legacy[key] != nil { obsolete.append(key) }
        tokens.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let manualHost = (legacy["manualHost"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        var named = tokens.filter { manualHost.isEmpty || $0.name != manualHost }.map {
            Device(name: $0.name, serviceName: $0.name,
                   pairedAddress: (legacy[addressPrefix + $0.name] as? String).flatMap { $0.isEmpty ? nil : $0 },
                   token: $0.token)
        }
        var devices: [Device]
        if !manualHost.isEmpty, named.count == 1 {
            named[0].address = manualHost
            devices = named
        } else {
            devices = named
            if !manualHost.isEmpty, let entry = tokens.first(where: { $0.name == manualHost }) {
                devices.append(Device(name: manualHost, address: manualHost, token: entry.token))
            }
        }

        let preferred = legacy["preferredHost"] as? String
        let selected = preferred.flatMap { p in
            devices.first { $0.serviceName == p }?.id ?? devices.first { $0.address == p || $0.name == p }?.id
        }
        return (devices, selected, obsolete.sorted())
    }
}
