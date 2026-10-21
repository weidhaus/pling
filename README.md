# Pling

A native macOS client for [ntfy](https://ntfy.sh). Lives in your menu bar, opens into a full window when you need it.

- **Menu bar inbox:** latest messages at a glance, with images, action buttons and snooze.
- **Window:** servers and topics in a sidebar, searchable timeline, compose with ⌘N.
- **Multiple servers:** ntfy.sh and self-hosted, with no auth, username and password, or access token. Secrets live in the Keychain.
- **Everything ntfy sends:** priorities, emoji tags, Markdown, click URLs, attachments with inline image previews and Quick Look, and `view` / `http` / `copy` action buttons, both in the app and in notifications.
- **Publish:** title, Markdown, priority, tags, link, delayed delivery, file attachments.
- **Reminders:**
  - High and urgent messages repeat until acknowledged. Repeats replace the previous banner instead of piling up.
  - Snooze any message for 15 minutes, 1 hour, or until tomorrow.
  - Add a message to Apple Reminders.
- **Per-topic mute and minimum priority**, plus a global Do Not Disturb.
- **End-to-end encryption** per topic (see below), with a CLI for scripts and Home Assistant.

Requires macOS 26 or later.

## Build

```sh
brew install xcodegen
xcodegen generate
open Pling.xcodeproj
```

The project signs with the maintainer's Developer ID. To build your own copy, set `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` in `project.yml` (or use "Sign to Run Locally").

Core logic lives in the `PlingCore` Swift package and is tested with `swift test`:

```sh
cd PlingCore && swift test
```

Integration tests run against a real server when `PLING_TEST_SERVER`, `PLING_TEST_USER` and `PLING_TEST_PASSWORD` are set. Keep them in `.env.local`, which git ignores:

```sh
set -a; . ../.env.local; set +a; swift test
```

## Why Pling has to keep running

ntfy's instant delivery to Apple devices relies on a push relay that only the official apps can use. Pling holds its own connection to each server, one HTTP stream per server, and reconnects after sleep or network changes. It catches up on missed messages with `since=`. It starts at login by default.

## End-to-end encryption

ntfy has no built-in end-to-end encryption, so Pling defines a small format. Give a topic a passphrase (Edit Topic › End-to-End Encryption) and everything Pling sends to it is encrypted. The server only ever stores ciphertext.

**Format v1**

| | |
|---|---|
| Key | PBKDF2-HMAC-SHA256(passphrase, salt = `"pling-e2e-v1:" + topic`, 600 000 iterations), 32 bytes |
| Cipher | AES-256-GCM, random 96-bit nonce |
| Plaintext | JSON `{title, message, tags, priority, click, actions, markdown, attachment: {name, type}}` |
| Body | `pling:e2e:v1:` + base64url(nonce ‖ ciphertext ‖ tag), unpadded, at most 3072 bytes |
| Outer fields | title `🔒 Encrypted message`. Priority stays in the clear so urgency still works. Nothing else is sent in the clear. |
| Attachments | file bytes sealed the same way, uploaded as `attachment.bin`. The real name and type are inside the encrypted body. |

Known-answer vector: passphrase `correct horse`, topic `alerts` → key `3f4eb1b83ee4637da1ef28b964e6bccd1623c37654f4421ad70dbad6a6c735d4`.

### `ntfy-e2e` CLI

```sh
cd PlingCore && swift build -c release
cp .build/release/ntfy-e2e /usr/local/bin/

export NTFY_USER=me NTFY_PASSWORD=… PLING_E2E_PASSPHRASE=…
ntfy-e2e send --server https://ntfy.example.com --topic alerts \
  --title "Door" --priority 4 --tags door "Front door opened"
ntfy-e2e decrypt --topic alerts 'pling:e2e:v1:…'
```

Home Assistant (`configuration.yaml`):

```yaml
shell_command:
  pling_secret: >-
    NTFY_TOKEN=!secret ntfy_token PLING_E2E_PASSPHRASE=!secret pling_pass
    /config/bin/ntfy-e2e send --server https://ntfy.example.com --topic alerts
    --title "{{ title }}" --priority {{ priority | default(3) }} "{{ message }}"
```

## Notes

- Priority 4 and 5 are requested as *time-sensitive*, so they can break through Focus. macOS only honours this with the Time Sensitive Notifications entitlement, which needs a provisioning profile. Without it they are delivered as normal notifications, and repeat alerts still apply.
- Emoji short codes come from [github/gemoji](https://github.com/github/gemoji) (MIT).

## License

MIT, see [LICENSE](LICENSE).
