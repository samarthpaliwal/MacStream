# Changelog

## 0.8.2 — Magic Keyboard
- PadClient: hidden iPad pointer over the stream, dedicated trackpad scroll
  recognizer, pointer drag threshold, hardware key auto-repeat, ⌥Tab/⌥Space
  remap for iPadOS-reserved shortcuts, shortcut bar suppressed.

## 0.8.1 — Full control without a hardware keyboard
- PadClient: modifier strip with latch and lock, three finger swipes for
  Spaces and Mission Control, edge swipes for Back/Forward, invert scroll
  option, character-to-key mapping for shortcuts from the on-screen keyboard.

## 0.8.0 — Milestone 8: polish and extras
- MacHost: `HostSettings` + Settings window, popover redesign, launch at
  login, display picker, frame rate and cursor options, system audio
  capture, `ClipboardSync`, `VirtualDisplay` extended mode.
- PadClient: `AudioPlayer`, `ClientClipboard`, mute button, screen info in
  `hello` so the extended display matches the iPad.
- StreamCore: PCM audio packet tag, `clipboard` message, `ScreenInfo`,
  protocol version 4.

## 0.7.0 — Milestone 7: latency tuning
- StreamCore: `ClockSync`, `BitrateController`, `hostStats`/`clientStats`/
  `nack` messages, assembler gap reporting, protocol version 3, tests.
- MacHost: pong carries host time; per-second host stats; adaptive bitrate;
  selective retransmission from an eight-frame history; send-queue
  backpressure; keyframe throttle; loss simulator; link stats in popover.
- PadClient: clock sync, end-to-end latency per frame, NACK on gaps,
  recovered-packet counting, per-second client reports, latency breakdown
  overlay.

## 0.6.0 — Milestone 6: pairing and security
- StreamCore: `KeychainStore`, long-term key derivation, `pairingComplete`,
  `pairing` TXT flag, protocol version 2.
- MacHost: `PairingStore` (Keychain secret + device list), pairing/paired
  listener modes with a two-minute one-time code, paired-device allowlist at
  handshake, popover section with Forget and Reset.
- PadClient: Keychain-backed `ClientPairingStore`, one-tap reconnect,
  "Ready to pair" / "Paired" states, swipe to forget, re-pair alert.

## 0.5.0 — Milestone 5: input control
- PadClient: `InputCaptureUIView` (touch, Pencil, hover, trackpad, hardware
  keyboard, on-screen keyboard), toolbar keyboard toggle, controls handle.
- MacHost: `InputInjector` (CGEvent mouse, drag, scroll, keys, Unicode text,
  double-click detection, modifier tracking, dry-run mode); handshake now
  reports the captured display's geometry.
- StreamCore: `typeText` event, `KeyCodeMap` with tests.

## 0.4.0 — Milestone 4: stream and render
- StreamCore: `VideoCrypto`, `FrameChunker`/`FrameAssembler`, `AnnexBParser`,
  `EncodedFrame`, with tests.
- MacHost: `VideoSender` UDP channel; capture starts/stops with the client;
  keyframe requests and quality changes handled over the control channel.
- PadClient: `VideoReceiver`, `VideoDecoder`, `VideoRenderer`, live debug
  overlay, graceful disconnect, `MACSTREAM_AUTOCONNECT` / `MACSTREAM_DEBUG_OVERLAY`.

## 0.3.0 — Milestone 3: capture and encode
- MacHost: ScreenCaptureKit capture, VideoToolbox HEVC/H.264 encoder,
  Annex-B conversion, passthrough `.mov` recorder, per-stage latency stats,
  synthetic test source, popover Capture section, `MACSTREAM_AUTOTEST`.
- StreamCore: `EncodedFrame` model with capture/delivered/encoded timestamps.

## 0.2.0 — Milestone 2: discovery and connection
- StreamCore: `ControlTransport` (TLS-PSK over TCP), `ControlChannel`
  (framed, typed messages over NWConnection), `HostBrowser` (Bonjour).
- MacHost: `HostController` advertises, accepts one client, completes the
  hello handshake, answers pings, echoes test messages, rotates the code
  after repeated failures. Popover shows the live code, a test-message
  button and a log.
- PadClient: live device list, pairing code sheet, `ClientSession` with
  handshake timeout, RTT measurement and message log in the stream view.

## 0.1.0 — Milestone 1: project setup
- XcodeGen-managed workspace with MacHost, PadClient and the StreamCore package.
- StreamCore: control message protocol with length-prefixed framing, input
  event model, video packet header, pairing code and PSK derivation, monotonic
  stage clock, unit tests.
- MacHost: menu bar popover (status, pairing code placeholder, quality preset,
  disconnect, quit) and first-run permissions window with System Settings
  deep links.
- PadClient: device picker with searching state, full-screen stream view with
  auto-hiding floating toolbar and debug overlay placeholder.
