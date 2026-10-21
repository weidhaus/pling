# Pling — native macOS client for ntfy

Date: 2026-10-21 · Status: draft for review

## Goal

A beautiful, native macOS 26+ app that receives, shows, and sends ntfy
messages from one or more ntfy servers, with reminders and optional
end-to-end encryption. Open source (MIT) on GitHub.

## Non-goals

- iOS/iPadOS version.
- APNs/push relay (ntfy.sh's relay is only for the official apps). Pling keeps
  its own connection and runs as a login item.
- Account/tier management, user administration, web push.

## Platform & stack

- macOS 26+, Swift 6 (strict concurrency), SwiftUI, Liquid Glass, SwiftData.
- No third-party runtime dependencies. Frameworks: Foundation (URLSession),
  CryptoKit + CommonCrypto (PBKDF2), UserNotifications, EventKit,
  ServiceManagement, Security (Keychain).
- Repo layout:
  - `PlingCore/` — Swift package: models, ntfy client, E2E crypto. No UI.
  - `ntfy-e2e/` — CLI executable target in the same package (shares crypto).
  - `Pling/` — the app (Xcode project generated from `project.yml` via XcodeGen).
- Signed with Developer ID "Justus-Constantin Weidhaus (5SB3S8ESR3)" only.
  Releases: notarized `.zip`/`.dmg` on GitHub Releases.

## Features

1. **Multiple servers.** Each server has a URL and auth: none, Basic
   (user + password), or Bearer token. Secrets live in the Keychain, keyed by
   server URL + user. ntfy.sh is just another server.
2. **Subscriptions.** Topics per server: display name, icon/emoji, muted,
   minimum priority shown, optional E2E passphrase.
3. **Receiving.** One long-lived `GET /<t1>,<t2>,…/json` stream per server via
   `URLSession.bytes`, decoded line by line. Reconnect with exponential
   backoff (1s → 60s) and `since=<last message id>`, so no messages are lost.
   Pause on sleep, resume on wake and on network change (`NWPathMonitor`).
   Restart the stream when that server's topic set changes.
4. **Message rendering.** Priority 1–5 (color + SF Symbol), tags → emoji
   (ntfy's emoji short-code table) and plain chips, Markdown bodies
   (`X-Markdown`), click URL, icon URL, attachments.
5. **Attachments.** Inline image previews (async loaded, cached in memory,
   Quick Look on click), other files shown as a chip with a Save/Open button.
   Expired attachments show as "expired".
6. **Action buttons.** `view` (open URL), `http` (perform request with
   method/headers/body, show success/failure), `broadcast` is ignored (it's
   Android-only). Shown in the app and as notification actions (category per
   action set, max 3, same as ntfy).
7. **Publish.** Compose sheet (⌘N, and from the menu bar): server, topic, title,
   message (Markdown), priority, tags, click URL, delay, attach file,
   encrypt toggle (if the topic has a passphrase).
8. **Notifications.** `UNUserNotificationCenter`. Priority 4–5 →
   `.timeSensitive`. Priority 5 → distinct sound. Priority 1 → no sound. Muted
   topics and topics below their min priority are stored but don't notify.
   Clicking a notification opens the message in the window (or the click URL
   if set).
9. **Reminders.**
   - *Re-alert*: unacknowledged messages with priority ≥ 4 re-notify every N
     minutes (default 5, configurable, max 12 times). Acknowledging (opening,
     marking read, or the "Acknowledge" notification action) stops it.
   - *Snooze*: "Remind me in 15 min / 1 hour / tomorrow 9:00" from the
     notification and from the app. Implemented as scheduled local
     notifications.
   - *Add to Reminders*: EventKit, adds the message as a reminder to the default
     list (configurable), with the click URL as reminder URL.
10. **E2E encryption (Pling format v1, opt-in per topic).**
    - Key: PBKDF2-HMAC-SHA256(passphrase, salt = `"pling-e2e-v1:" + topic`,
      600 000 iterations) → 256-bit key. Cached per subscription.
    - Message: JSON `{title, message, tags, priority, click, actions,
      attachment?}` sealed with AES-GCM (CryptoKit, random 96-bit nonce).
      Published as body `pling:e2e:v1:<base64url(nonce‖ciphertext‖tag)>` with
      outer title "🔒 Encrypted message", no outer tags. The outer priority
      header is kept, so the server and other clients still see urgency.
    - Encrypted attachments: the file is sealed with the same key and uploaded
      as `.bin`. Its real name/type are stored inside the encrypted envelope.
    - Wrong or missing passphrase → message shown as "🔒 Can't decrypt" (stored
      raw, decrypted later if the passphrase is added).
    - `ntfy-e2e` CLI: `ntfy-e2e send --server URL --topic T [--user U]
      [--title …] [--priority …] [--tags …] [--file …] MESSAGE`. Passphrase from
      `$PLING_E2E_PASSPHRASE` or stdin prompt. Password/token from env. Usable
      from Home Assistant `shell_command` and scripts.
    - Limit: ntfy turns bodies > 4096 bytes into attachments. Encrypted bodies
      over ~3 KB are rejected by the app and CLI with a clear error.
11. **Per-topic mute / DND**: mute toggle, mute-until (1h / 8h / until
    tomorrow), min priority. Independent of macOS Focus.
12. **Launch at login** (`SMAppService.mainApp`), on by default after first run.
13. **History**: SwiftData, 30 days (configurable), unread state, search
    (title/body/tags).

## UI

- **Menu bar** (`MenuBarExtra`, `.window` style): bell icon with unread dot.
  Popover shows latest messages across all topics (grouped by day), each row
  with priority accent, emoji tags, title/body (3 lines), image thumbnail,
  actions, and hover actions (snooze, add to Reminders, mark read). Footer:
  compose, open window, pause all.
- **Window** (`NavigationSplitView`): sidebar = servers → topics with unread
  badges, mute state, connection status dot. Detail = message timeline with
  search, filters (unread, min priority), and a message inspector for long
  bodies/attachments. Toolbar: compose, mark all read.
- **Settings** (`Settings` scene, tabs): Servers, Notifications & Reminders,
  Encryption, General (launch at login, history retention).
- Design goals: Liquid Glass on the menu bar panel, toolbars, and sidebar only
  (content stays plain and readable). Full keyboard support, VoiceOver
  labels, Dynamic Type-like scaling respected via system text styles, dark and
  light mode.

## Architecture

```
PlingCore
  NtfyMessage (Codable, mirrors ntfy JSON)   ─┐
  NtfyClient  (stream, publish, upload)       ├─ pure, unit-tested
  E2E         (derive key, seal, open)       ─┘
Pling app
  Server, Subscription, StoredMessage   (SwiftData @Model)
  ConnectionManager (@Observable, @MainActor) — one stream Task per server,
      writes into SwiftData, hands new messages to Notifier
  Notifier   — UNUserNotificationCenter, categories, delegate → actions
  ReminderScheduler — re-alert + snooze (local notifications), EventKit
  Keychain   — small wrapper over SecItem
  Views: MenuBarPanel, MainWindow (Sidebar, Timeline, MessageRow,
         Inspector), ComposeSheet, SettingsView
```

Data flow: stream line → `NtfyMessage` → (decrypt if `pling:e2e:v1:`) →
dedupe by id → SwiftData insert → if passes mute/priority → Notifier →
(priority ≥ 4) ReminderScheduler.

## Error handling

- Auth failure (401/403): server marked "auth failed" in sidebar, no retry
  storm. The user fixes credentials in Settings.
- Network/stream drop: backoff reconnect. Status shown per server.
- `http` action failure: inline error on the row + notification.
- Decrypt failure: see above. Never crashes and never drops the raw message.

## Testing

- `PlingCore` unit tests (swift test): JSON decoding of all event types and
  fields from fixtures, action parsing, stream line splitting + reconnect
  `since` logic against a local fixture stream, E2E round trip, known-answer
  test vector, tamper detection, CLI ↔ library compatibility.
- Integration test against a real server, skipped unless
  `PLING_TEST_SERVER`, `PLING_TEST_USER`, `PLING_TEST_PASSWORD` are set:
  publish → receive via stream, attachment upload, E2E publish via CLI →
  decrypt.
- Manual: `curl` publishing of priorities, tags, actions, Markdown, and image
  attachments. Check notifications, re-alert, snooze, Reminders.
- **No server URLs, usernames, or secrets in the repo.** Test env lives in an
  untracked `.env.local` (gitignored).
