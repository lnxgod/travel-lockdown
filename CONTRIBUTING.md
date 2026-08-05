# Contributing

Contributions are welcome. Travel Lockdown has an unusually strict safety boundary: tests and builds must never activate a live lockdown, accept a confirmation, or restore a real host.

1. Create a topic branch.
2. Add or update tests using injected fake controls and command runners.
3. Run `swift test`, `zsh -n scripts/build-app.sh`, and `zsh -n scripts/recover-travel-lockdown.sh`.
4. Explain any user-visible security or recovery impact in the pull request.

Do not add shell interpolation, arbitrary privileged commands, Keychain exports, Wi-Fi credential handling, private preference-file writes, or an unverified success state. New controls must capture a non-credential baseline, apply through a documented compatibility boundary, positively read back their state, and fail closed when verification is unavailable.

Please report security-sensitive defects using the private process in [SECURITY.md](SECURITY.md).
