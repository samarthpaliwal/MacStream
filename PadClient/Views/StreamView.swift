import SwiftUI
import StreamCore

/// Full-screen stream surface with auto-hiding controls. The video layer is
/// added in Milestone 4; until then the centre shows the connection test.
struct StreamView: View {
    @EnvironmentObject private var client: ClientState
    @ObservedObject var session: ClientSession

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var failure: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoDisplayView(renderer: session.renderer)
                .ignoresSafeArea()

            InputCaptureView(
                videoRect: { session.renderer.videoRect },
                softwareKeyboard: session.softwareKeyboardVisible,
                onEvent: { event in session.sendInput(event) },
                onToggleControls: { toggleControls() }
            )
            .ignoresSafeArea()

            if !session.hasVideo {
                ConnectionTestCard(session: session)
                    .allowsHitTesting(false)
            }

            if !controlsVisible {
                controlsHandle
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }

            if client.showDebugOverlay {
                DebugOverlay(stats: session.videoStats, hostStats: session.hostStats, rttMillis: session.rttMillis)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding()
            }

            FloatingToolbar(session: session, onDisconnect: client.disconnect)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 24)
                .opacity(controlsVisible ? 1 : 0)
                .offset(y: controlsVisible ? 0 : 20)
                .allowsHitTesting(controlsVisible)
                .animation(.spring(duration: 0.3), value: controlsVisible)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
        .onChange(of: session.status) { _, status in
            if case .failed(let reason) = status {
                failure = reason
            } else if status == .closed {
                client.disconnect()
            }
        }
        .onChange(of: client.quality) { _, quality in
            session.send(.setQuality(quality))
        }
        .alert("Could not connect", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            if session.usesStoredKey {
                Button("Forget pairing", role: .destructive) {
                    client.forgetPairing(session.host)
                    client.disconnect()
                }
            }
            Button("Back", role: .cancel) { client.disconnect() }
        } message: {
            Text(session.usesStoredKey ? "\(failure ?? "")\n\nIf the Mac reset its pairings, forget this one and enter a new code." : (failure ?? ""))
        }
    }

    /// Small always-available handle for bringing the toolbar back when a
    /// three finger tap is awkward (for example with a Pencil in hand).
    private var controlsHandle: some View {
        Button {
            toggleControls()
        } label: {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 44, height: 5)
                .padding(.horizontal, 30)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show controls")
    }

    private func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }
}

/// Milestone 2 connectivity test: status, RTT, display info, message log.
struct ConnectionTestCard: View {
    @ObservedObject var session: ClientSession

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                statusIcon
                Text(session.host.name).font(.headline)
            }
            Text(session.status.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if session.status == .connected {
                HStack(spacing: 24) {
                    stat("Round trip", session.rttMillis.map { String(format: "%.1f ms", $0) } ?? "—")
                    if let d = session.display {
                        stat("Mac display", "\(d.pixelWidth)×\(d.pixelHeight) @ \(Int(d.refreshRate)) Hz")
                    }
                }
                Button("Send test message") {
                    session.sendTestMessage()
                }
                .buttonStyle(.borderedProminent)
            } else if session.status == .connecting || session.status == .handshaking {
                ProgressView()
            }

            if !session.log.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(session.log.suffix(6)) { entry in
                        Text(entry.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var statusIcon: some View {
        Image(systemName: session.status == .connected ? "checkmark.circle.fill" : "laptopcomputer")
            .foregroundStyle(session.status == .connected ? Color.green : Color.accentColor)
            .accessibilityHidden(true)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.body, design: .monospaced))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Keyboard toggle, quality picker, debug overlay toggle and disconnect.
struct FloatingToolbar: View {
    @EnvironmentObject private var client: ClientState
    @ObservedObject var session: ClientSession
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Button {
                session.softwareKeyboardVisible.toggle()
            } label: {
                Image(systemName: session.softwareKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
            }
            .accessibilityLabel(session.softwareKeyboardVisible ? "Hide keyboard" : "Show keyboard")

            Menu {
                Picker("Quality", selection: $client.quality) {
                    ForEach(StreamQuality.allCases) { preset in
                        Label(preset.title, systemImage: preset.systemImage).tag(preset)
                    }
                }
            } label: {
                Image(systemName: client.quality.systemImage)
            }
            .accessibilityLabel("Quality: \(client.quality.title)")

            Button {
                session.audioMuted.toggle()
            } label: {
                Image(systemName: session.audioMuted ? "speaker.slash" : "speaker.wave.2")
            }
            .accessibilityLabel(session.audioMuted ? "Unmute Mac audio" : "Mute Mac audio")

            Button {
                client.showDebugOverlay.toggle()
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .accessibilityLabel("Toggle debug overlay")

            Divider().frame(height: 20)

            Button(role: .destructive, action: onDisconnect) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Disconnect")
        }
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

/// Live pipeline stats: end-to-end latency with its breakdown, then link
/// and decoder numbers. Host figures arrive once a second over control.
struct DebugOverlay: View {
    var stats: VideoStats
    var hostStats: HostStats?
    var rttMillis: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            stat("End to end", stats.endToEndMs.map { String(format: "%.0f ms", $0) } ?? "syncing…")
                .fontWeight(.semibold)
            stat("  Mac capture", hostStats.map { String(format: "%.1f ms", $0.captureDelayMs) } ?? "—")
            stat("  Mac encode", hostStats.map { String(format: "%.1f ms", $0.encodeMs) } ?? "—")
            stat("  Network+queue", networkMs.map { String(format: "%.1f ms", $0) } ?? "—")
            stat("  iPad decode", String(format: "%.1f ms", stats.decodeMs))
            Divider().frame(width: 190)
            stat("FPS", String(format: "%.0f ⇠ %.0f", stats.framesPerSecond, hostStats?.framesPerSecond ?? 0))
            stat("Bitrate", String(format: "%.1f ⇠ %.1f Mb/s", stats.megabitsPerSecond, hostStats?.encoderBitrateMbps ?? 0))
            stat("Loss", String(format: "%.2f%% (%d, %d back)", stats.lossPercent, stats.packetsLost, stats.packetsRecovered))
            stat("RTT", rttMillis.map { String(format: "%.1f ms", $0) } ?? "—")
            stat("Frames", "\(stats.framesDecoded) / \(stats.framesDropped) drop")
            stat("Queue", hostStats.map { "\($0.pendingPackets) pkts" } ?? "—")
            stat("Size", "\(stats.width)×\(stats.height)")
        }
        .font(.system(.caption, design: .monospaced))
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    /// Capture→arrival minus the host's own capture delay and encode time.
    private var networkMs: Double? {
        guard let arrival = stats.captureToArrivalMs, let host = hostStats else { return nil }
        return max(arrival - host.captureDelayMs - host.encodeMs, 0)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
        }
        .frame(width: 210)
    }
}
