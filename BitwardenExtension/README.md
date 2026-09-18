# Bitwarden

Bitwarden brings your vault into Tuna: find a login and copy its password without leaving the
keyboard, browse folders and collections, generate a new password. Reads go through the official
Bitwarden CLI running as a private local service on this Mac. Nothing is written back to the vault.

## Using it

Search for **Bitwarden** in Tuna and open it:

- Type to search. Names, usernames, identity emails, website hosts and folder names match, and so
  do the entry's own rows (type `lock` for Lock Vault, `gen` for the generators). Logins rank
  ahead of identities and notes when matches tie. Start with `l:`, `n:` or `i:` (or `login:`,
  `note:`, `identity:`) to search one kind only; `l:` alone lists every login. Enter on
  a login copies its password to the clipboard. The actions menu offers Copy Username, Copy TOTP,
  Copy URL, Open Website and Open in Bitwarden (the last one only when the desktop app is
  installed).
- Or browse: Favorites, Logins, Secure Notes, Identities, Folders, Collections. Identities open into
  their fields (full name, email, username, phone, company, address); Enter on a field copies it.
- **Generate Password** (20 characters, letters, numbers, symbols) and **Generate Passphrase** (4
  words) show the new value; Enter copies it, Regenerate makes another.
- **Sync Vault** pulls changes from the server. **Lock Vault** locks right away.
- Type text anywhere in Tuna and choose **Search Bitwarden** to open the vault already searching
  for what you typed.
- Combo Mode: bind a key to the **Search Bitwarden** action with the text `l:`, `n:` or `i:` to jump
  straight into logins, notes or identities.
- The copy actions run without showing Tuna when a global hotkey, a Combo Mode key or
  `tuna run --silent` triggers them. Touch ID still asks when the vault is locked; cancelling it
  ends the command quietly.
- Tuna's sort control offers **Vault order** (default), **Name**, **Recently changed** and
  **Favorites first** inside the entry and its groups. While browsing a group, typing matches the
  name, username, website host and folder as separate keys.
- Generated values keep the concealed clipboard marker even when Tuna's own Copy or Paste action
  handles them.

Items flagged in Bitwarden with *master password re-prompt* only offer Copy Username, Copy URL, Open
Website and Open in Bitwarden. Tuna cannot ask for the master password inline, so the flag is
honored by hiding the secret copies.

Vault items never appear in Tuna's main search list; they exist only inside the Bitwarden entry and
are never indexed on disk.

Search and Browse on the Bitwarden entry show the same rows until you type, because the vault only
narrows once there is a query.

## Setup

1. Install the Bitwarden CLI: `brew install bitwarden-cli` (tested with 2026.5.0).
2. In the Bitwarden web vault, open Settings > Security > Keys > **View API key**. Copy `client_id`
   and `client_secret`.
3. In Tuna Settings > Extensions > Bitwarden fill in **API key client ID**, **API key client
   secret** and **Master password**. Set **Server URL (optional)** only for the EU cloud
   (`https://vault.bitwarden.eu`) or a self-hosted server.
4. Open Bitwarden in Tuna. The first open logs the CLI in with the API key (a few seconds), asks for
   Touch ID or your Mac password, unlocks and syncs.

The API key login bypasses two-step login by design; it cannot open the vault without the master
password. Both stay in Settings so the extension can log in again if the CLI state is ever reset.

## Locking

The vault locks after 15 idle minutes (**Lock after idle minutes**, 0 disables), when the Mac
sleeps, when the screen locks, when Tuna quits, and with Lock Vault. Opening Bitwarden again asks
for Touch ID or your Mac password before the master password is used.

The Touch ID or password prompt confirms your presence before the extension reads the master
password from the Keychain; it does not itself protect the Keychain item, which Tuna's process can
read without it. A stronger variant, a Keychain item owned by the extension with a user-presence
access control, is a possible follow-up.

## Privacy

- The client secret and master password live in your Mac Keychain (Tuna's secret settings). The
  client ID and server URL are ordinary settings.
- The extension keeps only item metadata in memory while unlocked: names, usernames, website hosts,
  folder, collection and organization ids, favorite and re-prompt flags, whether a TOTP exists, and
  the identity fields it lists (full name, email, username, phone, company, address). Passwords,
  codes and note bodies are fetched from the CLI at the moment you copy them and are not retained.
- The master password and the client secret are read from the Keychain only while an unlock is in
  flight. The vault keeps neither of them afterwards, only the idle and clipboard timings.
- Copied passwords, codes, notes and generated values are marked as concealed for clipboard managers
  and removed from the clipboard after 30 seconds (**Clear clipboard after seconds**, 0 keeps them)
  if you copied nothing else in between.
- The extension itself makes no network requests. The Bitwarden CLI syncs with the configured
  Bitwarden server, on unlock when the last sync is older than 5 minutes, every 30 minutes while
  unlocked, and when you choose Sync Vault.
- The CLI runs with its own state directory, `~/Library/Application Support/Tuna/BitwardenExtension/cli-state`,
  so it never interferes with a `bw` login in your terminal. Its local service listens on a Unix
  socket in your temporary directory (`tuna-bitwarden/bw.sock`), readable only by your user.
- Nothing about your items is logged.

## Limitations

- Read only: no creating, editing, moving or deleting items.
- Logins, secure notes and identities only. Cards, SSH keys, attachments, Sends and custom fields
  are not shown.
- One Bitwarden account (the CLI supports one login at a time).
- Copy TOTP needs a Bitwarden Premium account (the CLI enforces it).
- Master password re-prompt items cannot reveal secrets from Tuna.

## Troubleshooting

- **Bitwarden CLI not found**: install it with Homebrew, or set the full path in **Bitwarden CLI
  path (optional)**.
- **Login failed**: check the client ID and secret; regenerate the API key in the web vault if needed.
- **Unlock failed**: the master password in Settings is wrong.
- **Keychain access denied**: allow Tuna when macOS asks, or open Keychain Access and grant it.
- Tuna Settings → Sources → Bitwarden shows the vault state, item, folder and collection counts
  and the last sync.
- Logs: Tuna Settings → Runtime Logs (`open "tuna://settings/runtime-logs"`). Failures are
  prefixed `[Bitwarden]`; nothing about items is logged.

## Development

Requires Tuna 0.96, TunaKit 1.22.0, macOS 15. Build, test and install from the repository root:

```bash
./scripts/tuna-extension build --scheme BitwardenExtension
./scripts/tuna-extension install --scheme BitwardenExtension --restart
make test
```
