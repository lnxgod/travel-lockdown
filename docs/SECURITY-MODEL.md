# Security model

Travel Lockdown is a local, source-built macOS utility. It has no network client, account system, telemetry, or cloud service. Its purpose is to reduce routine travel exposure while keeping Wi-Fi available for deliberate manual connections.

## Core invariants

- No setting changes during build, status, preflight, or dry-run.
- Live enable requires an inline plan review and a separate impact confirmation.
- Live activation requires a separately reviewed prepared recovery snapshot. The coordinator refuses ordinary setup unless every registered control reports a complete, clearly unlocked posture, double-captures the automatic values, binds them to a fresh opaque 256-bit review token, and rechecks them after persistence.
- A prepared snapshot must exactly match current automatic settings before it is promoted to active recovery state. Promotion is persisted before the first apply attempt, and active recovery state is retained until every registered control restores and verifies. Only a complete verified restore may atomically return that exact snapshot to prepared state for reuse; partial recovery leaves it active, and the next activation still requires an exact current-state match.
- Rebuilding a drifted prepared snapshot retains the exact original throughout review and cancellation. The replacement token's owner-only verifier binds its purpose, the original, and a stable fresh capture; confirmation compare-and-replaces that original, verifies the persisted candidate without applying or restoring controls, and rolls back ordinary failures.
- Recovery state is published only after decoding, baseline-envelope validation, and exact registered-control-set validation. An existing invalid baseline is a runtime attention state, never active or restore-ready; automatic enable, restore, and overwrite paths remain disabled and the file is preserved for investigation and manual recovery.
- The baseline is owner-only and contains declared non-credential state only. It never contains Wi-Fi passwords, Apple Account tokens, biometric data, recovery keys, or private keys.
- Wi-Fi restoration can require ordered SSID bytes/names and public profile flags. This privacy-sensitive network metadata is stored in the owner-only `baseline.json` (mode `0600`) beneath an owner-only directory and is redacted from normal UI and CLI output.
- A successful recovery review replaces `recovery-review.json` in that owner-only directory. The file is mode `0600` and contains only the random token's SHA-256 hash, the exact review purpose, and a deterministic internal binding fingerprint—not the raw token or SSID metadata. Preparation requires all three values to match; a second review invalidates the first token, and successful preparation removes the verifier on a best-effort basis after the safe transition.
- Privileged execution accepts only a fixed enum of firewall and wake commands. It does not accept shell text, executable paths, or caller-provided arguments.
- Unknown command completion or missing readback fails closed; it is never reported as success.
- Touch ID, account passwords, Apple Account settings, Find My, and Apple's built-in Lockdown Mode are outside scope.

## Recovery boundary

Personal Hotspot auto-join, AirPlay Receiver, and Sharing services do not have a complete supported automation/readback boundary. New snapshots store the user's reviewed desired values, emit exact manual recovery instructions, and require a baseline-bound user attestation after automatic values re-verify. Legacy snapshots retain unresolved markers. They can be replaced only after every automatic value matches the active legacy baseline; replacement overlays newly reviewed manual values atomically, and any failure leaves the original active baseline unchanged.

## Compatibility boundary

The current source uses public CoreWLAN configuration APIs and a narrowly allowlisted legacy Authorization Services mechanism for privileged firewall and wake commands. Handoff and AirDrop use explicit `defaults` mutations against Apple preference domains, which is a best-effort compatibility boundary rather than a stable public API. The authorization mechanism is unsupported by modern Apple SDK guidance and may become unavailable. The app treats unavailable or changed behavior as unverified and keeps recovery state; a future notarized distribution should replace privileged legacy execution with a signed helper.

## Non-goals

This is not an air-gap, anti-tracking guarantee, malware defense, VPN, firewall replacement, or substitute for operational security. macOS and hardware may expose radios or behaviors outside the supported controls this project can read and verify.
