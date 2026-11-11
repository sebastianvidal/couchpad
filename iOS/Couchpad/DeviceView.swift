import SwiftUI

/// One saved computer's profile, from Settings → Connection: its name, the ways to reach it
/// (the local network and every address it is known by) with the one in use checked, tap one
/// to use it now, and Connect / Forget. What the ways mean is behind the info button, out of
/// the way. Edits are saved as they are made.
struct DeviceView: View {
    @ObservedObject var client: Client
    let id: UUID
    /// Connect closes Settings, so the trackpad (or the pairing prompt) is what comes next.
    var onConnect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false
    @State private var showHelp = false
    @State private var editingAddress = false
    @State private var addressText = ""

    var body: some View {
        if let device = client.devices.first(where: { $0.id == id }) {
            form(device)
        } else {
            Text("This computer has been forgotten.")
                .foregroundStyle(.secondary)
        }
    }

    private func form(_ device: Device) -> some View {
        let typed = device.address.trimmingCharacters(in: .whitespaces)
        let current = client.currentDeviceID == id
        let active = current ? client.activeRoute : nil
        return Form {
            Section("Name") {
                TextField(device.serviceName ?? "Name", text: Binding(
                    get: { device.name },
                    set: { client.rename(id, to: $0) }
                ))
            }
            Section {
                if let name = device.serviceName {
                    let found = client.isOnLocalNetwork(device)
                    route("Local network", icon: "wifi", caption: found ? "Found" : "Not found right now",
                          active: active == .service(name), enabled: found) {
                        client.connect(id, by: .service(name))
                    }
                }
                ForEach(device.addressCandidates, id: \.self) { address in
                    route(address, icon: "network", caption: address == typed ? "Added by you" : nil,
                          active: active == .address(address), enabled: true) {
                        client.connect(id, by: .address(address))
                    }
                }
                // Connected, the checkmark says so; otherwise what it is doing about it.
                if current, !client.isConnected {
                    Text(client.status).font(.footnote).foregroundStyle(.secondary)
                }
                Button(typed.isEmpty ? "Add an address…" : "Edit added address…") {
                    addressText = typed
                    editingAddress = true
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Connections")
                    Button {
                        withAnimation { showHelp.toggle() }
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("About connections")
                }
            } footer: {
                if showHelp {
                    Text("Couchpad uses the local network when it finds this computer there. Otherwise it tries all of these addresses at once and uses the first one that answers. It learns them from the computer each time it connects, VPN ones (Tailscale, WireGuard) included. Tap one to use it now; when that connection ends, Couchpad goes back to choosing by itself. Add an address only for something it can't learn, like a host name or a forwarded port.")
                }
            }
            if !current || !client.isConnected {
                Section {
                    Button("Connect") {
                        client.select(id)
                        onConnect()
                    }
                }
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
        .alert(typed.isEmpty ? "Add an address" : "Edit added address", isPresented: $editingAddress) {
            TextField("100.101.102.103", text: $addressText)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Save") { client.setAddress(trimmedAddressText, for: id) }
                .disabled(!trimmedAddressText.isEmpty && HostAddress(trimmedAddressText) == nil)
        } message: {
            Text("An IP address or host name, with :port at the end if it isn't the usual one. Leave it empty to remove it.")
        }
    }

    private var trimmedAddressText: String { addressText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// One way to reach the computer. The one in use is checked and does nothing when
    /// tapped; one that can't be used right now is greyed.
    private func route(_ title: String, icon: String, caption: String?, active: Bool, enabled: Bool,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        if let caption {
                            Text(caption).font(.footnote).foregroundStyle(Color.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: icon)
                }
                // Colors, not the hierarchical styles: inside a button those resolve
                // against its tint, and the rows came out in the accent color.
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("In use")
                }
            }
        }
        .disabled(!enabled || active)
    }
}
