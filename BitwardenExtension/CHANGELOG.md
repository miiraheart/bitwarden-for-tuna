# Changelog

## 0.1.0

- Initial release.
- One Bitwarden entry: type to search logins, secure notes and identities, or browse Favorites,
  Logins, Secure Notes, Identities, Folders and Collections. Enter on a login copies its password;
  username, TOTP, URL, Open Website and Open in Bitwarden are one action away.
- Generate Password and Generate Passphrase entries.
- Logins for the site open in the frontmost browser come first when the entry opens (any browser,
  read through macOS Accessibility at that moment only).
- Copy actions are headless-safe for hotkeys, Combo Mode and the tuna CLI; a cancelled Touch ID
  ends the command quietly. Sort choices (Vault order, Name, Recently changed, Favorites first),
  keyed matching while browsing groups, and vault diagnostics in Settings → Sources.
- Touch ID (or Mac password) unlock with the master password kept in the macOS Keychain; the vault
  locks after idle time, on sleep, on screen lock and with Lock Vault. Copied secrets leave the
  clipboard after 30 seconds. Items never enter global search.
- Runs the official Bitwarden CLI as a private local service with its own state directory.
  Requires Tuna 0.96 / TunaKit 1.22.0 and bw 2026.5.0 or later.
