import SwiftUI

@main
struct PadClientApp: App {
    @StateObject private var client = ClientState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
        }
    }
}

/// Switches between the device picker and the full-screen stream.
struct RootView: View {
    @EnvironmentObject private var client: ClientState

    var body: some View {
        ZStack {
            switch client.phase {
            case .picking:
                DevicePickerView()
                    .transition(.opacity)
            case .streaming(let session):
                StreamView(session: session)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: client.phase)
    }
}
