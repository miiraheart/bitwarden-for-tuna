# Bitwarden for Tuna

A [Tuna](https://tunaformac.com) extension for [Bitwarden](https://bitwarden.com). Search and browse
your vault inside the launcher, copy a password, username, TOTP code or note without leaving the
keyboard, and generate new passwords and passphrases. Reads go through the official Bitwarden CLI
running as a private local service on this Mac; nothing is written back to the vault.

Requires Tuna 0.96 or later (TunaKit 1.22.0), macOS 15 and the Bitwarden CLI
(`brew install bitwarden-cli`, tested with 2026.5.0).

## What it adds

**Sources (Settings → Sources → Bitwarden)**

| Catalog | ID | What it does |
| --- | --- | --- |
| Bitwarden | `bitwarden` | Live-search root. Open it while a browser tab is in front and the logins for that site come first (any browser; the site is read from the frontmost window's web view through macOS Accessibility at that moment only, matched on the base domain, never stored). Type to search logins, secure notes and identities by name, username, identity email, website host and folder name. The entry's own rows match too (`lock` reaches Lock Vault, `gen` the generators); logins rank ahead of identities and notes on ties; `l:`, `n:` or `i:` restrict the search to one kind (`l:` alone lists every login). Press → to browse **Favorites**, **Logins**, **Secure Notes**, **Identities**, **Folders** and **Collections**, then **Generate Password**, **Generate Passphrase**, **Sync Vault** and **Lock Vault**. Identities open into their fields and Return on a field copies it. While browsing a group, typing matches name, username, website host and folder as separate keys, and Tuna's sort control offers **Vault order** (default), **Name**, **Recently changed** and **Favorites first**. Vault items never enter global search and are never indexed on disk. |

**Actions (`bitwarden.actions`)**

| Action | Applies to | Effect |
| --- | --- | --- |
| Copy Password | a login | Default action (Return). Fetches the password from the CLI at that moment and copies it, marked as concealed for clipboard managers and cleared after 30 seconds. |
| Copy Username | a login with a username | Copies the username. |
| Copy TOTP | a login with a TOTP seed | Copies the current code (the CLI needs Bitwarden Premium). |
| Copy URL, Open Website | a login with a website | Copies the website address, or opens it in the default browser. |
| Copy Note | a secure note | Default action. Fetches and copies the note body, concealed and cleared like a password. |
| Open in Bitwarden | a login, note or identity | Opens the Bitwarden desktop app; hidden when the app is not installed. |
| Run | Sync Vault, Lock Vault, Unlock Vault, Generate Password, Generate Passphrase, Try Again | Default action on the entry's command rows. |
| Copy, Regenerate | a generated password or passphrase | Copies the value (concealed, cleared after 30 seconds) or makes another. Tuna's own Copy and Paste actions on a generated value keep the concealed marker too. |
| Lock Vault, Sync Vault | the Bitwarden app entry in Tuna | Offered on the app through app enrichment; browsing the app entry opens the vault. |
| Search Bitwarden | text | Opens the vault already searching the text. With `l:`, `n:` or `i:` it searches one kind, which makes a good Combo Mode target. |

Items flagged in Bitwarden with *master password re-prompt* only offer Copy Username, Copy URL, Open
Website and Open in Bitwarden. Tuna cannot ask for the master password inline, so the secret copies
are hidden.

The copy actions are headless-safe: a global hotkey, a Combo Mode key or `tuna run --silent` runs
them without showing Tuna. Touch ID still asks when the vault is locked, and cancelling it ends the
command quietly. Settings → Sources → Bitwarden reports the vault state, item, folder and
collection counts and the last sync.

## Setup

1. Install the Bitwarden CLI: `brew install bitwarden-cli`.
2. In the Bitwarden web vault, open Settings → Security → Keys → **View API key** and copy
   `client_id` and `client_secret`.
3. Install the extension: from the Tuna Extension Store once published, or download the
   `com.brnbw.tuna.plugins.bitwarden-<version>.tunaextension` from Releases and use Tuna Settings →
   Extension Store → Add from File (relaunch Tuna afterwards), or `make package` from this
   repository.
4. In Tuna Settings → Extensions → Bitwarden fill in **API key client ID**, **API key client
   secret** and **Master password**. Set **Server URL (optional)** only for the EU cloud
   (`https://vault.bitwarden.eu`) or a self-hosted server. **Lock after idle minutes** (default 15,
   0 disables), **Clear clipboard after seconds** (default 30, 0 keeps) and **Bitwarden CLI path
   (optional)** are optional.
5. Open Bitwarden in Tuna. The first open logs the CLI in with the API key (a few seconds), asks for
   Touch ID or your Mac password, unlocks and syncs.

The API key login bypasses two-step login by design; it cannot open the vault without the master
password. Both stay in Settings so the extension can log in again if the CLI state is ever reset.

## Locking

The vault locks after the idle delay, when the Mac sleeps, when the screen locks, when Tuna quits,
and with Lock Vault. Opening Bitwarden again asks for Touch ID or your Mac password before the
master password is used; Tuna's panel comes back by itself once the prompt closes.

The Touch ID or password prompt confirms your presence before the extension reads the master
password from the Keychain; it does not itself protect the Keychain item, which Tuna's process can
read without it. A stronger variant, a Keychain item owned by the extension with a user-presence
access control, is a possible follow-up.

## Privacy

- The client secret and master password live in your Mac Keychain (Tuna's secret settings). The
  client ID and server URL are ordinary settings.
- The extension keeps only item metadata in memory while unlocked: names, usernames, website hosts,
  folder, collection and organization ids, favorite and re-prompt flags, whether a TOTP exists, and
  the identity fields it lists. Passwords, codes and note bodies are fetched from the CLI at the
  moment you copy them and are not retained.
- The master password and the client secret are read from the Keychain only while an unlock is in
  flight. The vault keeps neither of them afterwards.
- Copied secrets are marked as concealed for clipboard managers (so they stay out of Tuna's
  clipboard history) and removed from the clipboard after the configured delay if you copied
  nothing else in between.
- The extension itself makes no network requests. The Bitwarden CLI syncs with the configured
  server on unlock when the last sync is older than 5 minutes, every 30 minutes while unlocked, and
  when you choose Sync Vault.
- The CLI runs with its own state directory,
  `~/Library/Application Support/Tuna/BitwardenExtension/cli-state`, so it never interferes with a
  `bw` login in your terminal. Its local service listens on a Unix socket in your temporary
  directory (`tuna-bitwarden/bw.sock`), readable only by your user.
- Nothing about your items is logged.
- The current site is read only when you open the Bitwarden entry, from the frontmost window through
  macOS Accessibility (Tuna already holds that permission); the address never leaves memory.

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
- **Login failed**: check the client ID and secret; regenerate the API key in the web vault if
  needed.
- **Unlock failed**: the master password in Settings is wrong.
- **Keychain access denied**: allow Tuna when macOS asks, or open Keychain Access and grant it.
- **A copied password seems missing**: it was pasted from the clipboard but hidden from clipboard
  history on purpose, or the clear delay already ran; raise **Clear clipboard after seconds**.
- Logs: Tuna Settings → Runtime Logs (`open "tuna://settings/runtime-logs"`). Failures are
  prefixed `[Bitwarden]`; nothing about items is logged.

## Development

```bash
make build            # Debug build
make test             # unit tests (no code signing, fakes for the CLI, the service and the Keychain)
make install-restart  # install into ~/Library/Application Support/Tuna/ExtensionsDev and restart Tuna
make logs             # unified log; Tuna 0.98 and later keep extension logs in Settings → Runtime Logs
make package          # Release build + dist/store/*.tunaextension
```

Or call `./scripts/tuna-extension <build|install|logs|package>` directly. Ad hoc signing is enough
for a dev install because Tuna disables library validation:
`TUNA_CODE_SIGN_IDENTITY=- DEV_BUNDLE_SIGN_IDENTITY=- make install-restart`.
`./scripts/screenshot-tuna NAME [DELAY]` captures Tuna's launcher window into
`media/screenshots/NAME.png` after a delay, so you can summon Tuna first (needs Screen Recording
permission for your terminal).

The `bw serve` transport is a Unix socket with a short path under your temporary directory because
the CLI refuses socket paths over about 100 bytes; the service only starts once the CLI state is
logged in, and it is stopped when the vault shuts down.

## Releasing to the Tuna store

Store extensions ship from the [TunaExtensions](https://github.com/tunaformac/TunaExtensions)
repository, so this repo is the upstream and `BitwardenExtension/` is copied over for each release:

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `BitwardenExtension/Info.plist` and
   update `BitwardenExtension/CHANGELOG.md`.
2. Copy the folder into a clone of your TunaExtensions fork on a feature branch:
   `rsync -a --delete --exclude logs --exclude '*.xcuserdatad' BitwardenExtension/ ../TunaExtensions/BitwardenExtension/`
3. In that checkout: `./scripts/tuna-extension build --scheme BitwardenExtension --release`,
   `make test`, commit, push, and open or update the pull request.

The scripts under `scripts/` are copied from
[tunaformac/TunaExtensions](https://github.com/tunaformac/TunaExtensions) (MIT, see
`scripts/LICENSE-TunaExtensions`). Building needs Xcode 16+, `rg`, and network access for the
TunaKit binary package. For non-interactive signing pass `TUNA_DEVELOPMENT_TEAM` and
`TUNA_CODE_SIGN_IDENTITY` (see `security find-identity -v -p codesigning`).

### Packaging

`make package` builds Release, verifies the code signature, asks the installed Tuna binary to dump
the declaration, and writes `dist/store/com.brnbw.tuna.plugins.bitwarden-<version>.tunaextension`.
Store signing happens during Tuna's review; to sign locally set `SIGNING_KEY` to an ed25519 PEM
file. Compatibility floors come from the Swift declaration (`minTuna` 0.96, `minTunaKit` 1.22.0).

## Stable identifiers

Catalog, action, item, type and setting IDs are public API (they end up in hotkeys, rankings,
combos and `tuna://` URLs). Do not rename: catalogs `bitwarden`, `bitwarden.actions`; actions
`copy-password`, `copy-username`, `copy-totp`, `copy-url`, `open-website`, `open-in-bitwarden`,
`copy-note`, `run-command`, `copy-generated`, `regenerate`, `lock-vault-app`, `sync-vault-app`,
`search-bitwarden`; items `bitwarden` (the root), `bitwarden.group.favorites`,
`bitwarden.group.logins`, `bitwarden.group.notes`, `bitwarden.group.identities`,
`bitwarden.group.folders`, `bitwarden.group.collections`, `bitwarden.folder.<id>`,
`bitwarden.folder.none`, `bitwarden.collection.<id>`, `bitwarden.org.<id>`,
`bitwarden.command.<sync|lock|unlock|generate-password|generate-passphrase|retry>`, and vault
items under their Bitwarden id; types `com.tuna.type.bitwarden-item`, `-login`, `-note`,
`-identity`, `-identity-field`, `-generated-secret`, `-folder`, `-collection`, `-group`,
`-command`; settings `ClientID`, `ClientSecret`, `MasterPassword`, `ServerURL`, `IdleLockMinutes`,
`ClipboardClearSeconds`, `CLIPath`.

## License

MIT. See `LICENSE`.
