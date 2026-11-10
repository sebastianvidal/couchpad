import SwiftUI

/// One saved computer's profile, from Settings → Connection: its name, the address to reach
/// it by when it isn't on the same network, whether it is found on the local network now,
/// and Connect / Forget. Edits are saved as they are made.
struct DeviceView: View {
    @ObservedObject var client: Client
    let id: UUID
    /// Connect closes Settings, so the trackpad (or the pairing prompt) is what comes next.
    var onConnect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false

    var body: some View {
        if let device = client.devices.first(where: { $0.id == id }) {
            form(device)
        } else {
            Text("This computer has been forgotten.")
                .foregroundStyle(.secondary)
        }
    }

    private func form(_ device: Device) -> some View {
        Form {
            Section("Name") {
                TextField(device.serviceName ?? "Name", text: Binding(
                    get: { device.name },
                    set: { client.rename(id, to: $0) }
                ))
            }
            Section {
                TextField("100.101.102.103", text: Binding(
                    get: { device.address },
                    set: { client.setAddress($0, for: id) }
                ))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                if !device.address.trimmingCharacters(in: .whitespaces).isEmpty, HostAddress(device.address) == nil {
                    Text("That isn't an address Couchpad can use. An IP address or a host name, with :port at the end if it isn't the usual one.")
                        .font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Address")
            } footer: {
                Text("For when this computer isn't on the same network: the address your VPN (Tailscale, WireGuard) gives it. Couchpad uses the local network when it finds the computer there and switches to this address when it doesn't. No need to pair again.")
            }
            Section {
                if client.isOnLocalNetwork(device) {
                    Label("On the local network now", systemImage: "wifi")
                } else if device.serviceName != nil {
                    Label("Not on the local network right now", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Reached by its address only", systemImage: "network")
                        .foregroundStyle(.secondary)
                }
                if let paired = device.pairedAddress, paired != device.address {
                    Text("Also tried: \(paired), from the pairing QR code.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if client.currentDeviceID == id {
                    Text(client.status).font(.footnote).foregroundStyle(.secondary)
                }
                Button(client.currentDeviceID == id && client.isConnected ? "Connected" : "Connect") {
                    client.select(id)
                    onConnect()
                }
                .disabled(client.currentDeviceID == id && client.isConnected)
            }
            Section {
                Button("Forget this computer", role: .destructive) { confirmForget = true }
                    .confirmationDialog("Forget \(device.displayName)?", isPresented: $confirmForget, titleVisibility: .visible) {
                        Button("Forget", role: .destructive) {
                            dismiss()
                            client.forget(id)
                        }
                    } message: {
                        Text("To use it again, this phone has to pair with it again.")
                    }
            }
        }
        .navigationTitle(device.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
