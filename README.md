<p align="center">
  <img src="Assets/gamechangers-ai.png" width="112" alt="GameChangers AI logo">
</p>

# Travel Lockdown

**A free, open-source GameChangers AI menu-bar tool for a quieter Mac while traveling.**

Travel Lockdown keeps Wi-Fi available for deliberate manual connections while reducing routine radio, discovery, auto-join, inbound-network, sharing, and wake exposure. Before Lockdown can turn on, it requires an owner-only, non-credential recovery snapshot that you review while the Mac is clearly in its normal posture. Recovery stays inside the same menu-bar switch.

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

You can also print a redacted, read-only recovery review. Saved Wi-Fi names are never printed:

```zsh
swift run TravelLockdown --review-recovery
```

Then launch the app:

```zsh
open build/TravelLockdown.app
```

## Use the switch

Click the GameChangers logo in the menu bar.

1. Choose **Set Up Recovery Snapshot** while the Mac is in its normal posture.
2. Review the redacted automatic settings and record the normal AirPlay Receiver, Personal Hotspot auto-join, and Sharing values that macOS requires you to manage manually.
3. Choose **Save Reviewed Snapshot**. This creates a verified, prepared snapshot without changing any setting.
4. Turn **Lockdown Mode** on and review the in-panel dry-run plan. Nothing has changed at this point.
5. Continue to the separate impact confirmation, then choose **Enable Lockdown** only when you are ready.

The coordinator checks for a complete, clearly unlocked status before review, before save, and after save. It refuses to create a new recovery target from settings that already appear locked or ambiguous. A prepared snapshot must still exactly match the Mac before activation; it is promoted to active recovery state before the first lockdown mutation.

The switch stays left when off, moves right and green only when every registered control verifies, and rests in the center with an orange warning when recovery state exists but verification is incomplete.

To recover, turn the same switch off and confirm **Restore Normal State**. If recovery is partial, keep the app and its baseline installed and complete the listed System Settings steps. Dismissing a manual instruction never marks it restored.

Older snapshots that did not record the manual settings are retained until all automatic values restore. The app then offers **Review Missing Recovery Settings** and atomically replaces the old active snapshot with a reviewed prepared snapshot; any failed check leaves the old snapshot unchanged.

## Emergency recovery

If the menu UI is unavailable, the adjacent wrapper invokes the same confirmed recovery path:

```zsh
./scripts/recover-travel-lockdown.sh --confirm
```

Cancellation, an error, a changed baseline, a partial result, or failed verification exits nonzero and preserves the baseline for another attempt.

For headless recovery setup, first run `--review-recovery`, then pass its fresh 64-character token and every visible manual choice:

```zsh
swift run TravelLockdown --prepare-recovery \
  --review-token TOKEN \
  --airplay on \
  --airplay-access current-user \
  --airplay-password required \
  --hotspot ask-to-join \
  --sharing all-off \
  --confirmed
```

The accepted alternatives are `on|off`, `current-user|same-network|everyone`, `required|not-required`, `never|ask-to-join|automatic`, and `all-off|all-on`. A stale token, an ambiguous posture, or any setting drift fails without creating a snapshot.

## Known limitations

- Personal Hotspot auto-join, AirPlay Receiver, and Sharing services require explicit user review and restoration where macOS provides no complete supported readback. New snapshots bind those chosen values to recovery and require explicit completion attestation. Older snapshots with unresolved values use the in-app legacy replacement flow and are never silently treated as complete.
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
