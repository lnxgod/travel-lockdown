# Security model

Travel Lockdown is a local, source-built macOS utility. It has no network client, account system, telemetry, or cloud service. Its purpose is to reduce routine travel exposure while keeping Wi-Fi available for deliberate manual connections.

## Core invariants

- No setting changes during build, status, preflight, or dry-run.
- Live enable requires an inline plan review and a separate impact confirmation.
- Recovery state is captured before an apply attempt and retained until every registered control restores and verifies.
- The baseline is owner-only and contains declared non-credential state only. It never contains Wi-Fi passwords, Apple Account tokens, biometric data, recovery keys, or private keys.
- Wi-Fi restoration can require ordered SSID bytes/names and public profile flags. This privacy-sensitive network metadata is stored in the owner-only `baseline.json` (mode `0600`) beneath an owner-only directory and is redacted from normal UI and CLI output.
- Privileged execution accepts only a fixed enum of firewall and wake commands. It does not accept shell text, executable paths, or caller-provided arguments.
- Unknown command completion or missing readback fails closed; it is never reported as success.
- Touch ID, account passwords, Apple Account settings, Find My, and Apple's built-in Lockdown Mode are outside scope.

## Recovery boundary

Personal Hotspot auto-join, AirPlay Receiver, and Sharing services do not have a complete supported automation/readback boundary. They are stored as unresolved manual markers. The app keeps recovery visible and retains the baseline until the user completes and verifies those steps.

## Compatibility boundary

The current source uses public CoreWLAN configuration APIs and a narrowly allowlisted legacy Authorization Services mechanism for privileged firewall and wake commands. Handoff and AirDrop use explicit `defaults` mutations against Apple preference domains, which is a best-effort compatibility boundary rather than a stable public API. The authorization mechanism is unsupported by modern Apple SDK guidance and may become unavailable. The app treats unavailable or changed behavior as unverified and keeps recovery state; a future notarized distribution should replace privileged legacy execution with a signed helper.

## Non-goals

This is not an air-gap, anti-tracking guarantee, malware defense, VPN, firewall replacement, or substitute for operational security. macOS and hardware may expose radios or behaviors outside the supported controls this project can read and verify.
