# Duvet mobile: status report

_23 October 2026 · Flutter app in `mobile/`, against `duvet_client` 1.0.1 (local, unpublished) and the Duvet design system (`L1t5M8Kr96KAEGfwD1pjEQ`) with the Feature Layouts canvas (`UYB8DxdUxBCcgauVFZshq2`)._

**In short:** every milestone but voice is done. Messaging, media, navigation and search, people, Spaces and invites, account, bots, and Space administration all work, laid out to the design system and covered by widget tests. **M8 (voice and calls) hasn't started**, and three platform tasks remain: push notifications, an accessibility pass, Spanish. A debug build runs on the phone against the live server with no crashes. `TODO.md` has the task list; its **Needs you** section lists what needs a server change, a credential or a Mac.

| | |
|---|---|
| Code | 21,879 lines in `lib/` (44 files), 4,351 in `test/` |
| Tests | 129 widget, unit and golden tests, all passing; `flutter analyze` clean |
| Client | `duvet_client`: 343 tests passing (one skipped), `dart analyze` clean |
| TODO | 71 of 82 tasks done (11 open, 3 of them from the device test) |
| Verified on | an Android 15 phone, debug build, signed in to the live server |

---

## 1. Milestones

| Milestone | Status | Notes |
|---|---|---|
| M1 · Layout to spec | ✅ | Fira Sans and the type ramp, tab bar, list rows, Launchpad grid, Space Directory, glass bars, composer, bubbles, glass with 1.8× saturation |
| M2 · Everyday messaging | ✅ | reply, edit, delete, reactions, Markdown, spoilers, catch-up after reconnect, jump to first unread, mentions, drafts, failed sends |
| M3 · Media | ✅ | video, voice notes (record and play), audio and any file, GIF picker, image viewer (save, share), upload progress and cancel, link previews |
| M4 · Navigation & search | ✅ | Channel Switcher, global and in-chat search, pins, threads, deep links (`duvet://`; `https://duvet.chat` needs server files) |
| M5 · People | ✅ | profile sheet, friends, new conversation, group DMs, presence from the start |
| M6 · Spaces & invites | ✅ | join by link or code, invite people, create and leave, unread per Space |
| M7 · Account | 🟡 | sign up, verify email, forgot and reset password, change email, edit profile (crop), my files, appearance. **Status** and **bio editing** wait on the server |
| M8 · Voice & calls | ❌ | not started |
| M9 · Bots | ✅ | message buttons and selects, slash commands with options, bot modals, bot invite cards; bots drawn as rounded squares with a BOT tag |
| M10 · Space administration | ✅ | overview, rooms (with per-role overwrites), roles (colors, members, permissions), emojis and stickers, invites, webhooks (URL shown once), storage (view only) |
| Platform | 🟡 | done: offline cache, connection state, token safety, iOS config, golden tests, CI, release signing config, build settings. Open: push, accessibility pass, Spanish |

## 2. API coverage

### REST (`RestMethods`)

The app calls about **100 of 138 methods (~72%)**. What's left is outside a phone's scope or not yet needed:

- teams (8 methods) and applications and bots management (7): developer features;
- storage bucket management (11): storage is view-only on mobile;
- bulk attachment deletion (3), `removeBotFromSpace`, renaming a webhook (`updateWebhook`).

`sendComponentInteraction` and `sendCommandInteraction` aren't called because the app uses the new `useComponent` and `useCommand`, which also return the bot's modal.

### Gateway (`GatewayManager`)

The app handles **49 of 58 event types (84%)**. The nine left are all voice and calls (M8): `VOICE_STATE_UPDATE`, `VOICE_JOINED`, `CALL_INCOMING`/`ACCEPTED`/`DECLINED`/`ENDED`, and the three `WEBRTC_*` events.

### Changes to `duvet_client` (1.0.1, in its CHANGELOG)

- **Parsing and requests:** `member_statuses` parsed (presence at connect); `count` on message history; `m4a` voice notes and a `format` parameter; `getConversationMessageThread`.
- **Gateway:** a connection-state stream; the token no longer logged; no reconnect after `destroy()`; `DM_MENTION_CREATE` handled, and mention events carry message and author IDs.
- **Uploads and interactions:** upload progress and cancel; `useComponent`, `useCommand` and `submitModal`, which keep the bot's reply.
- **Breaking:** `createSpace` now returns the new Space's ID.

## 3. Design system

All screens and components in the wireframes and the 37 feature layouts are built:
- **Foundations:** tokens in both themes, Fira Sans and Fira Mono, the shadows including inset ones, and glass with blur and saturation.
- **Rules:** one accent per screen, and circles only for people (Spaces and bots are rounded squares).
- **Exceptions:**
  - The voice room, incoming-call and in-call layouts wait on M8.
  - Role colors are adjusted until they read at 4.5:1 on both themes (tested), so a few swatches render darker or lighter than picked.

## 4. Accessibility

- Every control has a screen-reader label and its own tap action. Each message is one stop, with its actions as custom actions. Live regions announce suggestions, typing, uploads and failures.
- Touch targets are 44 to 48 pt. Presence and selection are told apart by shape, not color alone. Reduce motion makes springs plain and pauses GIFs; high contrast makes glass opaque.
- **Not done:** a TalkBack or VoiceOver pass on a device, 200% text size checks, and contrast checks beyond role colors.

## 5. On the device (23 Oct 2026)

- **Build and setup:** a debug build (arm64, `chat.duvet`) on an Android 15 phone, signed in to the live server.
- **Checked:** sign in, Chats, Spaces, Duvet Official's rooms, #github-logs and #general. There were no crashes or Flutter errors, the gateway heartbeat stayed steady, and the debug build used about 460 MB.
- **What worked:** presence, room snippets, replies, mentions, stickers, custom-emoji reactions and webhook bots all displayed correctly.
- **Issues found (open in `TODO.md`):**
  - Link and webhook card titles stop at two lines, hiding GitHub's success or failure.
  - Stickers, custom-emoji reactions and avatars are blank until they load, with no placeholder.
- **Not reached:** the You tab. Nothing was posted to the server.


## 6. Not verified

- **Release build:** not built yet; the release keystore is yours to make (see `TODO.md`).
- **iOS:** configured, never built (needs a Mac).
- **Sending from the device:** messages, files, voice notes, bot commands and admin changes are tested against the fake repository only.
- **CI:** the workflow is written but has never run, since there's no remote here.
