import StreamCore
import SwiftUI

/// Popover section: the one-time code while pairing, otherwise the list of
/// paired iPads with Forget, plus Pair a new iPad and Reset.
struct PairingSectionView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = PairingStore.shared
    @State private var confirmReset = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let code = appState.pairingCode {
                    HStack {
                        Text(code.formatted)
                            .font(.system(.title, design: .monospaced).weight(.medium))
                            .accessibilityLabel("Pairing code \(code.digits)")
                        Spacer()
                        Button("Cancel") { HostController.shared.cancelPairing() }
                            .controlSize(.small)
                    }
                    Text("Enter this code on the iPad within two minutes. It works once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Pair a new iPad…") { HostController.shared.enterPairingMode() }
                        .controlSize(.small)
                        .disabled(appState.connection.isConnected)
                }

                if !store.devices.isEmpty {
                    Divider()
                    ForEach(store.devices) { device in
                        HStack {
                            Image(systemName: "ipad")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(.callout)
                                Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if case .connected(let name) = appState.connection, name == device.name {
                                Circle().fill(.green).frame(width: 8, height: 8)
                                    .accessibilityLabel("Connected")
                            }
                            Button("Forget") { HostController.shared.forgetDevice(device.id) }
                                .controlSize(.mini)
                        }
                    }
                    Button("Reset all pairings…", role: .destructive) { confirmReset = true }
                        .controlSize(.mini)
                        .confirmationDialog("Reset all pairings?", isPresented: $confirmReset) {
                            Button("Reset", role: .destructive) { HostController.shared.resetAllPairings() }
                        } message: {
                            Text("Every iPad will need to enter a new code to connect again.")
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(appState.pairingCode == nil ? "Paired iPads" : "Pairing")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
