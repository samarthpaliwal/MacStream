import SwiftUI
import StreamCore

/// Popover section for Milestone 3: codec and source choice, a short test
/// recording, live pipeline stats, and a shortcut to the saved file.
struct CaptureSectionView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var capture = CaptureController.shared

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Source", selection: $capture.sourceKind) {
                        ForEach(CaptureController.SourceKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .disabled(capture.isRunning)
                }

                HStack {
                    if capture.isRunning {
                        if capture.isRecording {
                            Button("Stop") {
                                Task { await capture.stop() }
                            }
                        } else {
                            Text("Streaming").font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Record 5 s test clip") {
                            capture.recordTestClip(seconds: 5)
                        }
                    }
                    Spacer()
                    if capture.lastRecordingURL != nil {
                        Button("Show in Finder") { capture.revealLastRecording() }
                    }
                }
                .controlSize(.small)

                if capture.isRunning || capture.stats.totalFrames > 0 {
                    Text(capture.stats.summary)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(capture.stats.width)×\(capture.stats.height) · \(capture.stats.totalFrames) frames · \(capture.stats.keyframes) key · \(capture.stats.dropped) dropped")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let error = capture.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Capture")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
