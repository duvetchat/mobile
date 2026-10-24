# Duvet mobile: status report

_23 October 2026 · Flutter app in `mobile/`, against `duvet_client` 1.0.1 (local, unpublished) and the Duvet design system (`L1t5M8Kr96KAEGfwD1pjEQ`) with the Feature Layouts canvas (`UYB8DxdUxBCcgauVFZshq2`)._

**In short:** every milestone is built. Messaging, media, navigation and search, people, Spaces and invites, account (now with the status, online or do not disturb, and the bio), bots, Space administration, and voice rooms and calls work, laid out to the design system and covered by widget tests. **M8 (voice and calls) is written and tested against fakes, but hasn't run on a device**: WebRTC can't run here. The status, bio editing and Delete Space need the server's 23 October round deployed. Three platform tasks remain: push notifications (which calls need to ring in the background), an accessibility pass, Spanish. A debug build runs on the phone against the live server with no crashes. `TODO.md` has the task list; its **Needs you** section lists what needs a server change, a credential, a Mac or the phone.

| | |
|---|---|
| Code | 25,749 lines in `lib/` (51 files), 6,491 in `test/` |
| Tests | 196 widget, unit and golden tests; `flutter analyze` clean. On Windows the 4 goldens fail (glyph edges); the `chat` ones need regenerating on Linux for M8's Call button |
| Client | `duvet_client`: 401 tests passing (the live ones left out), `dart analyze` clean |
| TODO | 85 of 89 tasks done (4 open) |
| Verified on | an Android 15 phone, debug build, signed in to the live server (before M8) |

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
| M7 · Account | ✅ | sign up, verify email, forgot and reset password, change email, edit profile (crop, bio), my files, appearance, status (online or do not disturb). **Status** and **bio editing** work once the server's 23 October round is deployed |
| M8 · Voice & calls | 🟡 | voice rooms (who's in, join, mute, deafen, faces talking, sound output), DM and group calls (incoming screen, call screen, Calls tab from this phone's history; no buzz in do not disturb), rejoining after a gateway restart, Android foreground service, iOS background audio. **Tested against fakes only: not yet on a device** |
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

The app handles **all 59 event types** the client parses. M8 added the nine voice and call events (`VOICE_STATE_UPDATE`, `VOICE_JOINED`, `CALL_INCOMING`/`ACCEPTED`/`DECLINED`/`ENDED`, the three `WEBRTC_*`) and `VOICE_SESSION_REPLACED`. It sends `VOICE_JOIN`, `VOICE_LEAVE`, `VOICE_SYNC`, `WEBRTC_ICE_CANDIDATE`, `WEBRTC_ANSWER` and the five `CALL_*` messages; never `WEBRTC_RENEGOTIATE_OFFER` (the phone adds no tracks mid-call). `VOICE_VIDEO_REFUSED` stays unparsed: the phone sends no video.

### Changes to `duvet_client` (1.0.1, in its CHANGELOG)

- **Parsing and requests:** `member_statuses` parsed (presence at connect); `count` on message history; `m4a` voice notes and a `format` parameter; `getConversationMessageThread`.
- **Gateway:** a connection-state stream; the token no longer logged; no reconnect after `destroy()`; `DM_MENTION_CREATE` handled, and mention events carry message and author IDs.
- **Uploads and interactions:** upload progress and cancel; `useComponent`, `useCommand` and `submitModal`, which keep the bot's reply.
- **Voice and calls:** `WebRTCController` rewritten to the gateway's real messages (it sent `join_voice`, `call_accept` and other names the gateway ignores), with `VoiceStates` (who's in voice, in version order); the WebRTC events' data as the gateway sends it (the ICE candidate is a JSON string); READY's ICE servers; `VOICE_SESSION_REPLACED`; `connection` (the open socket's number) and `silenceBeforeReady` on the gateway client.
- **Breaking:** `createSpace` now returns a `CreatedSpace`: the new Space and its rooms, which the app shows before the gateway's SPACE_CREATE. The voice API changed too (see the CHANGELOG).

Unreleased, after 1.0.1 (for the server's 23 October round): the bio (`updateUser(custom:)`, `maxBioLength`, USER_UPDATE's `custom`) and the status (`setStatus`, `UserMeResult.status`, READY's `GatewayUser.status`).

## 3. Design system

All screens and components in the wireframes and the 37 feature layouts are built:
- **Foundations:** tokens in both themes, Fira Sans and Fira Mono, the shadows including inset ones, and glass with blur and saturation.
- **Rules:** one accent per screen, and circles only for people (Spaces and bots are rounded squares).
- **Exceptions:**
  - M8's voice room, incoming call and call screens follow the tokens and components (glass bars, rounded-square controls, faces in circles, one accent: Join voice, the speaking ring, or Accept). The Feature Layouts canvas couldn't be opened in that session: check them against its voice room, incoming-call and in-call layouts.
  - Role colors are adjusted until they read at 4.5:1 on both themes (tested), so a few swatches render darker or lighter than picked.

## 4. Accessibility

- Every control has a screen-reader label and its own tap action. Each message is one stop, with its actions as custom actions. Live regions announce suggestions, typing, uploads and failures.
- Touch targets are 44 to 48 pt. Presence and selection are told apart by shape, not color alone. Reduce motion makes springs plain and pauses GIFs; high contrast makes glass opaque.
- Voice: each tile reads its person and state ("Maya, muted, speaking"); mute and deafen are switches; the incoming call announces its caller, and Accept and Decline say what they do.
- **Not done:** a TalkBack or VoiceOver pass on a device, 200% text size checks, and contrast checks beyond role colors.

## 5. On the device (23 Oct 2026)

- **Build and setup:** a debug build (arm64, `chat.duvet`) on an Android 15 phone, signed in to the live server.
- **Checked:** sign in, Chats, Spaces, Duvet Official's rooms, #github-logs and #general. There were no crashes or Flutter errors, the gateway heartbeat stayed steady, and the debug build used about 460 MB.
- **What worked:** presence, room snippets, replies, mentions, stickers, custom-emoji reactions and webhook bots all displayed correctly.
- **Issues found (fixed since, not checked on the phone yet):**
  - Link and webhook card titles stopped at two lines, hiding GitHub's success or failure. They take four now.
  - Stickers and custom-emoji reactions were blank until they loaded; avatars showed their Facehash. A sticker now shows a `base-sunken` square, a reaction the emoji's name, and an avatar a `base-sunken` circle.
- **Not reached:** the You tab. Nothing was posted to the server.


## 6. Not verified

- **Voice and calls (M8):** written against the gateway's code and tested with a fake gateway and a fake WebRTC; nothing has carried audio yet. `TODO.md`'s **Needs you** lists the pass to make on the phone. Calls ring only while the app is open (no push yet), and not on a locked screen.
- **Release build:** not built yet; the release keystore is yours to make (see `TODO.md`).
- **iOS:** configured, never built (needs a Mac).
- **Sending from the device:** messages, files, voice notes, bot commands and admin changes are tested against the fake repository only.
- **Status, bio and Delete Space against a server:** they need the API's and the gateway's unmerged branches (`dnd-status`, `space-delete-bio`). They're tested against fakes and mocks of those contracts, which `duvet_client`'s fixtures take from the branches.
- **CI:** the workflow is written but has never run, since there's no remote here.
