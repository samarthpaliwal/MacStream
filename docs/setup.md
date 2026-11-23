# Setup

Everything needed to build, sign and run MacStream on your own Mac and iPad.

## Requirements

- macOS 14 or later on the Mac, iPadOS 17 or later on the iPad
- Xcode 16 or later (built with Xcode 27.2)
- XcodeGen for regenerating the project: `brew install xcodegen`
- Both devices on the same Wi-Fi network

## First-time setup

1. **Add your Apple ID to Xcode.** Xcode → Settings → Accounts → "+" → Apple ID.
   This creates a free "Personal Team". No paid developer account is needed.
2. **Put your Team ID in `project.yml`.** In Accounts, select your Apple ID, then
   your Personal Team; the ID is shown on the right (10 characters). Set
   `DEVELOPMENT_TEAM` to it, then run `xcodegen generate`. Alternatively pick the
   team under Signing & Capabilities for each target; XcodeGen will overwrite
   that on the next generate, so the `project.yml` route is more durable.
3. **Enable Developer Mode on the iPad.** Settings → Privacy & Security →
   Developer Mode. The toggle appears only after the iPad has been connected to
   a Mac running Xcode at least once.
4. **Pair the iPad with Xcode** once over USB (Window → Devices and Simulators).
   Tick "Connect via network" so later installs can go over Wi-Fi.
5. **Trust the developer profile on the iPad** after the first install:
   Settings → General → VPN & Device Management → your Apple ID → Trust.

## Build and run

Open `MacStream.xcworkspace`. Choose the **MacHost** scheme with "My Mac" as the
destination and press Run. The app appears in the menu bar (no Dock icon) and
opens its setup window until both permissions are granted.

Choose the **PadClient** scheme with your iPad (or an iPad simulator) and Run.

From the command line, if you prefer:

```bash
xcodebuild -workspace MacStream.xcworkspace -scheme MacHost -configuration Debug build
```

```bash
xcodebuild -workspace MacStream.xcworkspace -scheme PadClient -destination 'generic/platform=iOS' build
```

Do not pass `CODE_SIGNING_ALLOWED=NO` for the iPad target, even on the
simulator: an unsigned app has no application identifier, so the Keychain
refuses to store the pairing key. Xcode's "Sign to Run Locally" is enough.

Shared package tests:

```bash
cd Packages/StreamCore && swift test
```

## Permissions the Mac host needs

| Permission | Why | Where |
|---|---|---|
| Screen Recording | ScreenCaptureKit returns nothing without it | System Settings → Privacy & Security → Screen & System Audio Recording |
| Accessibility | Required to post CGEvents for mouse and keyboard injection | System Settings → Privacy & Security → Accessibility |

The setup window requests each one and deep-links to the pane. Notes:

- Permission is tied to the app's code signature. Each time Xcode re-signs a
  Debug build with a changed identity, macOS may ask again. Granting once per
  signing identity is normal.
- After granting Screen Recording, macOS often requires the app to relaunch.
- On macOS 15 and later, non-App-Store apps get a periodic "is still allowed
  to record your screen" reminder. This is expected.

## Info.plist keys and entitlements

**MacHost**
- `LSUIElement = true` so it runs as a menu bar app with no Dock icon.
- `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_macstream._tcp`).
- Entitlements: App Sandbox off. No hardened runtime (not needed for local use).

**PadClient**
- `NSLocalNetworkUsageDescription`: iPadOS shows a local-network prompt the
  first time the app browses Bonjour. Without this key browsing silently fails.
- `NSBonjourServices`: must list every service type browsed (`_macstream._tcp`).
- `UIRequiresFullScreen = false` so the iPad keeps multitasking.
- No special entitlements. Bonjour browsing via Network framework does not
  need the multicast entitlement.

All of these are declared in `project.yml` and written into the generated
Info.plist files, so edit the YAML rather than the plists.

## Free Apple ID signing: what to expect

- **Seven-day expiry.** Apps signed with a free Personal Team stop launching
  seven days after installation. Reinstall from Xcode (Run again) to reset the
  clock. Your data and pairing on the iPad are kept because the bundle ID does
  not change.
- **Three apps at a time** can be installed on a device with a free team, and
  at most **ten App IDs per week** can be created. This project uses two.
- **No iCloud, push notifications, or App Groups** on free teams. MacStream
  does not use any of these.
- The Mac host is also signed with the Personal Team. Mac apps signed this way
  run indefinitely on your own Mac; the seven-day limit applies to iOS only.
- Refreshing the iPad install automatically is not implemented.
