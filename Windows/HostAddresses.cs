using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace Couchpad;

/// <summary>Every IPv4 address the phone might reach this PC on: the menu line, the pairing QR
/// and the <c>addrs</c> line after <c>ok</c> all use this list, so a phone away from home can try
/// the VPN ones.</summary>
static class HostAddresses
{
    /// <summary>Ethernet and Wi-Fi first, so the first entry is the home-network address, then
    /// everything else (VPN tunnels and the like); each group in enumeration order, at most 8.</summary>
    public static List<string> IPv4()
    {
        var primary = new List<string>();
        var rest = new List<string>();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            var group = nic.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.Wireless80211 ? primary : rest;
            foreach (var addr in nic.GetIPProperties().UnicastAddresses)
            {
                if (addr.Address.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(addr.Address)) continue;
                var text = addr.Address.ToString();
                if (text.StartsWith("169.254.") || primary.Contains(text) || rest.Contains(text)) continue;
                group.Add(text);
            }
        }
        return primary.Concat(rest).Take(8).ToList();
    }
}
