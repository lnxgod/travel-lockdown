<p align="center">
  <img src="Assets/gamechangers-ai.png" width="112" alt="GameChangers AI logo">
</p>

# Travel Lockdown

**A free, open-source GameChangers AI menu-bar tool for a quieter Mac while traveling.**

Travel Lockdown keeps Wi-Fi available for deliberate manual connections while reducing routine radio, discovery, auto-join, inbound-network, sharing, and wake exposure. It captures an owner-only, non-credential recovery baseline before applying anything and keeps recovery inside the same menu-bar switch.

> [!IMPORTANT]
> This project is not Apple's Lockdown Mode, is not affiliated with Apple, and is not an anonymity or air-gap guarantee. It changes an explicit set of local controls; hardware, macOS, and third-party software can have behavior outside that boundary.

## What it manages

- Opens Bluetooth Settings and requires a visible user action to turn Bluetooth off. The source also contains an opt-in Shortcuts provider; the shipped runtime uses the Settings path.
- Turns Handoff and AirDrop receiving off where supported; directs the user to AirPlay Receiver when macOS requires a manual step.
- Keeps Wi-Fi powered on and does not intentionally disconnect the current connection.
- Clears remembered auto-join profiles and disables remembering newly joined networks so future connections are manual.
- Directs the user to Personal Hotspot auto-join when macOS cannot verify it programmatically.
- Enables the application firewall, stealth mode, and block-all mode when privileged execution and exact readback are available.
- Directs the user through Sharing services that require manual verification.
- Disables wake-for-network-access when privileged execution and readback are available.
- Reads FileVault status during preflight and reports guidance/unavailable for USB accessory approval and Private Wi-Fi Address, which are not currently read programmatically.

Touch ID, passwords, Apple Account settings, Find My, location services, credentials, and Apple's built-in Lockdown Mode are never changed.

## Requirements

- macOS 15 or newer
- Apple Silicon or Intel Mac with Xcode Command Line Tools / Swift 6
- An administrator account for controls that macOS protects

The project is currently distributed as **source only**. Local builds are ad-hoc signed. A notarized downloadable binary is not provided yet.

## Build

```zsh
git clone https://github.com/lnxgod/travel-lockdown.git
cd travel-lockdown
./scripts/build-app.sh
codesign --verify --deep --strict build/TravelLockdown.app
```

The build script publishes versioned app bundles to the owner-only directory `~/Library/Application Support/TravelLockdown/Release/versions/`. `Release/current` selects the verified version and the local `build` symlink points to it. A failed candidate never replaces the last verified recovery executable.

Before opening the app, you can run the read-only status path:

```zsh
swift run TravelLockdown --status --dry-run
```

Then launch the app:

```zsh
open build/TravelLockdown.app
```

## Use the switch

Click the GameChangers logo in the menu bar.

1. Turn **Lockdown Mode** on.
2. Review the in-panel dry-run plan. Nothing has changed at this point.
3. Continue to the separate impact confirmation.
4. Choose **Enable Lockdown** only when you are ready.

The switch stays left when off, moves right and green only when every registered control verifies, and rests in the center with an orange warning when recovery state exists but verification is incomplete.

To recover, turn the same switch off and confirm **Restore Normal State**. If recovery is partial, keep the app and its baseline installed and complete the listed System Settings steps. Dismissing a manual instruction never marks it restored.

## Emergency recovery

If the menu UI is unavailable, the adjacent wrapper invokes the same confirmed recovery path:

```zsh
./scripts/recover-travel-lockdown.sh --confirm
```

Cancellation, an error, a changed baseline, a partial result, or failed verification exits nonzero and preserves the baseline for another attempt.

## Known limitations

- Personal Hotspot auto-join, AirPlay Receiver, and Sharing services remain manual/unresolved where macOS provides no complete supported readback. Recovery can remain incomplete until those steps are handled.
- The allowlisted firewall and wake path currently uses a legacy Authorization Services mechanism. If macOS does not support it, the app reports the control as unverified instead of claiming success.
- Removing remembered Wi-Fi profiles does not export or recreate passwords. Restoration rebuilds only the public profile metadata and relies on identities already present in the user's Keychain.
- Turning Bluetooth off affects Bluetooth accessories and Apple Watch Auto Unlock.
- The optional source-level Shortcuts provider recognizes only **Travel Lockdown Bluetooth Off** and **Travel Lockdown Bluetooth On**; the default build does not select it.

## Remove the app

First turn Lockdown Mode off and finish every recovery item. Only after the app no longer offers recovery should you quit it and remove the checkout and `~/Library/Application Support/TravelLockdown/Release`. Do not delete `baseline.json` while recovery is incomplete.

## Development and security

Tests use injected fakes and must never change the host. Run:

```zsh
swift test
```

See [the security model](docs/SECURITY-MODEL.md), [security reporting](SECURITY.md), and [contribution rules](CONTRIBUTING.md).

## License

MIT © 2026 GameChangers AI. See [LICENSE](LICENSE).
