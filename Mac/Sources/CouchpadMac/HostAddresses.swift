import Darwin

/// Every IPv4 address the phone might reach this Mac on: the menu line, the pairing QR and the
/// `addrs` line after `ok` all use this list, so a phone away from home can try the VPN ones.
enum HostAddresses {
    /// Built-in interfaces (en*) first, so the first entry is the home-network address, then
    /// VPN tunnels, then anything else; each group in getifaddrs order, at most 8.
    /// Read straight from the interface list: `Host.current().addresses` resolves the hostname
    /// through DNS and took 5 s on the main thread every time the menu opened.
    static func ipv4() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var groups: [[String]] = [[], [], []]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if address.hasPrefix("169.254.") || groups.joined().contains(address) { continue }
            let name = String(cString: ifa.ifa_name)
            let group = name.hasPrefix("en") ? 0
                : ["utun", "tun", "tap", "wg", "ipsec", "ppp"].contains(where: name.hasPrefix) ? 1 : 2
            groups[group].append(address)
        }
        return Array(groups.joined().prefix(8))
    }
}
