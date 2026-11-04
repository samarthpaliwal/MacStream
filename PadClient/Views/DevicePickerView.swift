import SwiftUI
import StreamCore

/// Lists Macs found on the local network and starts a connection.
struct DevicePickerView: View {
    @EnvironmentObject private var client: ClientState
    @State private var hostAwaitingCode: DiscoveredHost?

    var body: some View {
        NavigationStack {
            List {
                if let error = client.discoveryError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                if client.hosts.isEmpty {
                    searchingRow
                } else {
                    Section("Macs on this network") {
                        ForEach(client.hosts) { host in
                            hostRow(host)
                        }
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("Both devices must be on the same Wi‑Fi network. Open MacStream on your Mac and it will appear here. The first time, iPadOS asks to allow local network access.")
                }
            }
            .navigationTitle("MacStream")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "ipad")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("This device: \(client.identity.name)")
                }
            }
            .sheet(item: $hostAwaitingCode) { host in
                PairingCodeSheet(host: host) { code in
                    hostAwaitingCode = nil
                    client.connect(to: host, code: code)
                }
            }
        }
        .onAppear { client.startBrowsing() }
        .onDisappear { client.stopBrowsing() }
    }

    private var searchingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Looking for Macs…")
                Text("Make sure MacStream is running in the Mac's menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func hostRow(_ host: DiscoveredHost) -> some View {
        let paired = client.isPaired(host)
        return Button {
            if paired {
                client.connectPaired(to: host)
            } else {
                hostAwaitingCode = host
            }
        } label: {
            HStack {
                Image(systemName: paired ? "laptopcomputer" : "lock.laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(host.name)
                    Text(subtitle(for: host, paired: paired))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if paired {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Paired")
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .tint(.primary)
        .swipeActions {
            if paired {
                Button("Forget", role: .destructive) { client.forgetPairing(host) }
            }
        }
    }

    private func subtitle(for host: DiscoveredHost, paired: Bool) -> String {
        if paired { return "Paired · tap to connect" }
        if host.isPairingMode { return "Ready to pair · tap to enter the code shown on the Mac" }
        return "Not paired · choose “Pair a new iPad” in the Mac's menu bar first"
    }
}

/// Six-digit code entry, matching the code in the Mac's menu bar popover.
struct PairingCodeSheet: View {
    let host: DiscoveredHost
    let onSubmit: (PairingCode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var digits = ""
    @FocusState private var focused: Bool

    private var code: PairingCode? { PairingCode(digits: digits) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "lock.laptopcomputer")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("Connect to \(host.name)")
                        .font(.title2.weight(.semibold))
                    Text("Click the MacStream icon in the Mac's menu bar and enter the six-digit code shown there.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("000000", text: $digits)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 36, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onChange(of: digits) { _, new in
                        digits = String(new.filter(\.isNumber).prefix(6))
                    }
                    .onSubmit(submit)
                    .accessibilityLabel("Pairing code")

                Button(action: submit) {
                    Text("Connect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(code == nil)
            }
            .padding(32)
            .frame(maxWidth: 420)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        if let code { onSubmit(code) }
    }
}

#Preview {
    DevicePickerView().environmentObject(ClientState())
}
