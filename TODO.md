# Duvet mobile: TODO

Tasks to bring the mobile app to the desktop app's feature set, in milestone order. Each names the desktop component it follows, and the `duvet_client` calls or gateway events it needs. See `REPORT.md` for where things stand.

Every UI task follows the design system (tokens, glass rules, one accent per screen, circles only for people) and ships with widget tests and screen-reader labels.

---

## M1 · Layout to spec (no new API)

Make the existing screens match `wireframes.md` before adding more.

- [x] **Fira Sans:** bundle it (400/500/700) and map the type ramp (`large-title` … `tab-label`) into the forui theme. Remove ad-hoc `TextStyle` sizes.
- [x] **Tab bar:** glass material, 56pt, and an `accent-tint` 56×32 pill behind the active icon that springs between tabs (250ms).
- [x] **ChannelRow and ChatRow widgets:** 72pt rows, no dividers, 48pt avatar or rounded-square icon, unread = bold name + `ink` snippet, pressed = `base-sunken` highlight inset 8pt. Replace the `FTileGroup`s in Chats and the Space Directory.
- [x] **Chats rows:** "# room · Space name" on line 1 with the space part in `ink-secondary`.
- [x] **Space Directory:** last-message snippets per room. Fill them from recent chats and live `MESSAGE_CREATE`. `getMessages` always fetches 100, so a cheap "last message per room" call (or a `count` parameter) is needed in `duvet_client`/`api`. Drop the accent-blue `#` icons.
- [x] **Launchpad:** a 2-column SpaceCard grid (173×160, 48pt icon or monogram, "N online", press 0.98 with shadow-raised → shadow-rest).
- [x] **Glass top bar on scroll:** the large title scrolls away and a 52pt glass bar with the `nav-title` fades in (Chats, Spaces).
- [x] **Composer to spec:** one radius-20 field holding +, text, emoji and send; Send inert (`ink-secondary`) when empty and a 32pt accent square once there's text; a glass bar with its hairline only once messages scroll beneath.
- [x] **Messages:** time under the last bubble of a run; centered day separators ("Today", "Yesterday", dates).
- [x] **Glass:** add the 1.8× backdrop saturation to `GlassSurface` (a color matrix composed with the blur).
- [x] **Member rows:** 48pt avatars, with status as a caption line.

## M2 · Everyday messaging

Desktop: `MessageList`, `ChatInput`, `MessagePreview`.

- [x] **Reply:** double-tap a bubble to open the reply strip (spec in Composer README). Send `messageReference`; render the quoted message above the bubble, and tap it to jump to the original (`getMessageById` / `getDirectMessageById` when it isn't loaded).
- [x] **Edit own messages:** a long-press menu item opens edit mode in the composer, saving with `updateMessage` / `updateDirectMessage`; show "edited".
- [x] **Delete own messages:** a destructive menu item with a confirm sheet, calling `deleteMessage` / `deleteDirectMessage`.
- [x] **Reactions:** a row of reaction chips under the bubble (`ReactionCount`); long-press → a glass quick-reaction bar plus the emoji picker. Calls `addRoomReaction` / `removeRoomReaction` and the conversation equivalents; events `REACTION_ADD/REMOVE` and `DM_REACTION_*`. Screen readers read "👍 3, you reacted".
- [x] **Markdown:** bold, italic, underline, strike, `code`, code blocks, `||spoilers||`, block quotes, lists and links, as desktop's `markdown.ts` does. Make links tappable (add `url_launcher`); use a mono font for code.
- [x] **Spoiler files:** files whose names mark them as spoilers stay blurred until tapped (`SpoilerCover`, `lib/spoilers`).
- [x] **Catch-up after reconnect:** `getMessagesAfter` / `getDirectMessagesAfter` from the newest known message when the gateway resumes.
- [x] **Jump to the first unread:** with a "New messages" divider; unread counts from `READY` and `getMentionCounts`.
- [x] **Mention notifications:** handle `MENTION_CREATE`; show a mention count on the Chats row (weight and count only, never a blue dot).
- [x] **Draft per chat:** keep the unsent text, files and reply target when leaving a chat.
- [x] **Failed send:** keep the files with a retry action (done); add "Delete" for a failed message.

## M3 · Media

Desktop: `MessageAttachments`, `ImagePreview`, `VoiceNotePlayer`, `AudioFilePlayer`, `GifPicker`.

- [x] **Video:** inline poster with a play button and full-screen playback (add `video_player`).
- [x] **Voice notes, playing:** waveform player for `MessageType.voice` (`VoiceNotePlayer`).
- [x] **Voice notes, recording:** hold-to-record in the composer, sent with `sendVoiceNote` / `sendDMVoiceNote` (WebM/Opus); `sendRecordingIndicator`. Mind the Composer README's "no fifth control" rule: record from the + menu or by holding Send.
  _Android records Ogg/Opus (AAC before Android 10), so `duvet-client` 1.0.1 lets `sendVoiceNote` name the format. Waveforms use desktop's seeded fallback bars; nothing decodes the audio for real peaks yet._
- [x] **Audio files:** inline player.
- [x] **Any file:** a "File" item in the + menu (`file_picker`); open or download received files (`url_launcher` / share sheet).
- [x] **GIF picker:** a tab in the picker sheet, following desktop's `GifPicker` provider.
- [x] **Image viewer:** save to gallery, share, swipe down to dismiss.
- [x] **Upload progress:** show progress per file; an upload that's too large gets a clear error (check desktop's limits).
- [x] **Link previews:** `MessageLinkEmbed` (a Duvet message link shows the quoted message) and `InviteEmbed` (an invite link shows a Join card).

## M4 · Navigation & search

Desktop: `ChannelsSidebar`, `MessageSearch`, `PinnedMessages`.

- [x] **Channel Switcher sheet:** tap the chat title (with ⌄) to see the space's directory in a glass sheet, the current room selected; picking one swaps the chat.
- [x] **Global Search dropdown:** the search field on Chats, filters "All · Messages · People · Spaces", match highlight in bold `accent-text`. Uses `searchSpaceMessages`, `searchConversationMessages` and the members and spaces caches.
- [x] **In-chat search:** the search button in the chat top bar.
- [x] **Pinned messages:** a sheet from the chat menu, using `getRoomPins` / `getConversationPins` and pin/unpin.
- [x] **Threads:** open a thread from a message (`getMessageThread`).
- [x] **Deep links:** `duvet://` and `https://duvet.chat/invite/...` open the right chat or the join flow.
  _`duvet://` works as is. For `https://duvet.chat` links to open the app without asking, duvet.chat must serve `/.well-known/assetlinks.json` (Android) and an `apple-app-site-association` (iOS); neither exists yet. The app's side is in: Android's verified intent filter, and iOS's Associated Domains entitlement (`ios/Runner/Runner.entitlements`, `applinks:duvet.chat`)._

## M5 · People & conversations

Desktop: `FriendsView`, `MemberProfileCard`, `MemberProfilePopover`, `DMSidebar`.

- [x] **Profile sheet:** tap an avatar or name to see a glass sheet with avatar, banner, bio (`custom`), presence and roles, and the actions Message, Mention, Add friend.
  _The API has no user lookup, so a profile shows what the Space's member list carries (bio, banner) and the Space's roles from SPACE_CREATE; "Member since" isn't sent and isn't shown._
- [x] **Friends:** list, pending and sent requests, accept and reject, unfriend. Calls `getFriends`, `getPendingRequests`, `getSentRequests`, `sendFriendRequest`, `acceptFriendRequest`, `rejectFriendRequest`, `unfriend`; events `FRIEND_*`. Probably a section of the You tab or a header button on Chats.
  _Adding by username searches the people the user shares a Space or chat with: the API takes a user ID, with no username lookup._
- [x] **New conversation:** pick people, then `createDM` / `createGroup`.
- [x] **Group DMs:** rename (`updateConversation`), add and remove members, leave.
- [x] **Presence from the start:** parse `SPACE_CREATE.member_statuses` in `duvet-client`, publish 1.0.1, then seed `presence` from it. Space cards then show "N online".
  _Done in `duvet-client` 1.0.1 (also a `count` on `getMessages`), used through a `dependency_overrides` path. Publishing 1.0.1 to pub.dev and dropping the override is left to you._

## M6 · Spaces & invites

Desktop: `JoinInviteModal`, `InviteModal`, `SpaceInviteModal`.

- [x] **Join by invite:** paste or open a link, see a preview (`getInvite`), then join (`joinInvite`).
- [x] **Invite people:** `createRoomInvite`, then share the link through the share sheet.
  _The API takes an expiry but no use limit, so the layout's "Max uses" isn't offered._
- [x] **Create a space; leave a space:** `createSpace`, `leaveSpace`.
- [x] **Unread state per space:** bold card name when any room is unread, from `READY` and the live events.

## M7 · Account

Desktop: `UserSettings`, the `(auth)` routes, `UserStatusBar`.

- [x] **Sign up:** `signIn` (registration), then verify email (`verifyEmail`, `sendVerificationEmail`).
  _The API emails links, not the 6-digit codes the layout draws: the links (`/verify`, `/reset-password`, `/change-email`) open the app, and can be pasted._
- [x] **Password:** forgot and reset (`forgotPassword`, `resetPassword`).
- [x] **Edit profile:** alias and bio (`updateUser`); avatar and banner with a cropper (`uploadProfileImage`, as `ImageCropModal`).
  _Alias, avatar and banner are done (a pure-Dart cropper; the server crops). The bio is an "About me" field with a counter, as desktop's `UserSettings`: 190 characters counted as code points, so an emoji is one, trimmed, and empty clears it. It goes only when changed (`updateUser(custom:)`, duvet-client). The page no longer breaks when the keyboard opens (its fields were made again on every padding change: a `LateInitializationError`)._
- [x] **Status:** online or do not disturb. `updateUser` has no status field, so check how desktop's `UserStatusBar` sets it and add the call to `duvet_client` if it's missing.
  _A Status control on the You tab, Online or Do not disturb (`setStatus`, duvet-client: `PUT /api/users/@me/status`). The user's own status comes from READY and from USER_STATUS_UPDATE about them, so a change on another device shows. Do not disturb was already drawn wherever presence shows (the dot with a bar, "Do not disturb"). The app makes no sounds or alerts of its own for messages and mentions yet, so there's nothing to silence. M8's incoming call must show without ringing in do not disturb (`Profile.status`), as desktop's `callRings` does._
- [x] **Change email:** `changeEmail` / `sendChangeEmail`.
- [x] **My files:** list and delete my attachments and see storage use (`getMyAttachments`, `deleteMyAttachment`, `getMyStorageStatus`).
- [x] **Appearance:** system, light or dark.

## M8 · Voice & calls

Desktop: `VoiceChat`, `VoiceChannelView`, `CallModal`, `webrtc_controller.dart`.

- [x] **WebRTC on mobile:** add `flutter_webrtc`; port the client's `WebRTCController`. Handle `VOICE_STATE_UPDATE`, `VOICE_JOINED`, `WEBRTC_*` and ICE through the TURN server (`gateway/compose.turn.yml`).
  _`VoiceController` (`lib/data/voice.dart`) ports desktop's `VoiceChat`: every VOICE_SYNC carries the whole state (`video_off` on, no camera or screen: the phone gets no video), READY joins again (but leaves after more than 3 minutes of gateway silence), a join made offline waits for the next session (3 minutes at most), one unanswered for 15 s leaves with a notice, and a call READY doesn't list ends. Peer connections use READY's STUN and TURN servers (the user's own TURN credentials). flutter_webrtc sits behind `VoiceEngine` (`webrtc_engine.dart`), the gateway behind `VoiceSignaling`. In `duvet-client`, `WebRTCController` was rewritten: it sent names the gateway ignores (`join_voice`, `call_accept`…) and read its events wrongly. **Not run on a device yet.**_
- [x] **Voice rooms:** join and leave, see who's in, mute and deafen; participants' Facehash mouths driven by `mouthOpen` from their audio level (already supported by the widget).
  _A voice room's screen (`voice_room.dart`) from the Space Directory, whose voice rows say who's in; Join voice, then tiles with each face's mouth on their level (WebRTC's audio level, read five times a second) and a speaking ring, and the controls (mute, deafen, sound output, leave). A bar over the tab bar leads back. The mouth's thresholds (`speakingLevel`, `mouthRange`) want tuning on real voices._
- [x] **DM calls:** incoming call screen (`CALL_INCOMING` → accept or decline), in-call controls, end. Fill the Calls tab with history. In do not disturb (`Profile.status`) an incoming call shows without buzzing, as desktop's `callRings`.
  _A Call button and a "Call in progress · Join" banner in DMs and groups; a full-screen incoming call (Accept or Decline, the phone buzzing); the call screen (calling, then the clock and the controls). Neither the API nor the gateway keeps call history (the gateway forgets a call when it ends), so the Calls tab lists the calls this phone saw, kept in the keystore per account and deleted at sign-out (or when a saved session is refused at launch); the tab says so. A call that comes during another one is kept as missed, and the user told; one whose voice never connected shows as "Couldn't connect". A call rings only while the app is open: in the background or killed it needs push (see **Push notifications**)._
- [x] **Background audio and audio routing:** speaker, earpiece and Bluetooth; a foreground service on Android while in a call.
  _Rooms start on the loudspeaker, calls on the earpiece, a headset first either way; the output button switches (flutter_webrtc's AudioSwitch on Android). Android: a microphone-type foreground service (flutter_background) while in voice, started once the microphone is granted, with its permissions in the manifest (and `BLUETOOTH_CONNECT`, asked for once, before the first call, without which Android 12+ can't route to a headset); its notification names nobody. Voice without the microphone (refused, or no Speak permission) gets no service, as Android starts a microphone service only with the microphone: the app says listening goes on only while it's open. A call placed asks for the microphone before it rings anyone and opens it then, as Android won't open it nor start the service from the background once it's answered. Voice notes can't be recorded while in voice. iOS: the `audio` background mode. **Not run on a device yet.**_

## M9 · Bots & interactions

Desktop: `MessageComponents`, `ComponentSelect`, `InteractionModal`, `CommandOptions`.

- [x] **Message components:** render buttons and selects; `sendComponentInteraction`. _Buttons in Duvet's three variants (link buttons open), selects in a glass sheet (options, members, roles, rooms), texts, sections and containers; bots get a rounded-square avatar and a BOT tag. The client's new `useComponent` keeps the bot's modal._
- [x] **Slash commands:** `/` suggestions in the composer from `getSpaceCommands` (as a glass dropdown, like `@`); option entry; `sendCommandInteraction`. _Options in a glass sheet (text, numbers with bounds, choices, yes/no, members, rooms, roles); `/name` + Send runs a command without options._
- [x] **Modals from interactions:** shown as glass sheets. _Text inputs, checkboxes, radio and checkbox groups, selects; checked as the API does before `submitModal` (type 5, new in the client)._
- [x] **Bot invite embeds:** `BotInviteEmbed`. _`duvet.chat/invite?bot=<id>` links are cards: the bot, and Add to a Space._

## M10 · Space administration (lower priority on mobile)

Desktop: `ServerSettings`, `ChannelSettings`, `BucketFilesDialog`, `StorageTransferCard`.

- [x] **Space settings:** name, icon and banner (`updateSpace`). _In the Space menu for those who help run it; rows show only for what the user may change._
- [x] **Rooms:** create, rename, reorder, delete; permission overwrites. Events `ROOM_OVERWRITE_*`. _Reorder by dragging a room's ridged edge (or a long press); a category is one panel that drags with its rooms, and **Move to…** changes a room's category (first in one, as the desktop drops a room in; after the rooms outside any when it leaves). Only the rooms the user may manage (ManageChannels in the room, overwrites included) move or open their options, and Create room needs it in the Space. Moves send the API's insert-before position (`updateRoom`), show at once and follow `ROOM_REORDER`. Overwrites per role, and per member ([#20](https://github.com/duvetchat/mobile/issues/20)): a card each in a carousel (swipe, or tap a chip or a peeking card), every room permission (Video and Manage the room among them; ManageRoles has no say in a room), Deny, Role default (Their roles), Allow. Add member picks from the Space's members, searched on the device; Remove gives a member's back to their roles._
- [x] **Roles:** create, edit and assign. Events `ROLE_*`, `MEMBER_ROLE_*`; role colors on names in the member list. _Colors are adjusted to 4.5:1 on both themes (tested)._
- [x] **Role order, gradients ([#20](https://github.com/duvetchat/mobile/issues/20)):** _Drag a role by its ridged edge (or a long press), as rooms move; @everyone stays last, and roles at or above the user's highest are locked (the owner moves any). A move sends the position of the role it lands by (`updateRole(position:)`), shows at once and follows `ROLE_UPDATE`. **Admins first** puts Administrator roles on top, then those that manage part of the Space, each tier in its order. Names show in their color or gradient; the color sheet sets Default, Solid, or a Gradient from Start through an optional Middle to End (`color_from`/`color_via`/`color_to`), and saving a color sends all three so a gradient's stops clear. Names and webhook names stop at the API's 64._
- [x] **Emojis and stickers:** upload, rename, delete (`createEmoji` … `deleteSticker`). _Any member sees them, read-only, as on the desktop ([#20](https://github.com/duvetchat/mobile/issues/20)): from the Space menu when they run nothing, else a row in Space settings._
- [x] **Invites:** list and revoke (`listSpaceInvites`, `revokeInvite`).
- [x] **Webhooks:** list, create, reset the token, delete, rename, and a picture or none ([#20](https://github.com/duvetchat/mobile/issues/20)). _The URL is shown once, to copy. A picture is cropped round, 256 px; its past messages keep theirs. No gateway event says a webhook changed, so the list loads again after each change._
- [x] **Storage:** space attachments and buckets (view-only on mobile is probably enough). _View-only._

## Platform & quality

- [ ] **Push notifications:** [#53](https://github.com/duvetchat/mobile/issues/53)
- [x] **Offline cache:** last page per chat and the conversation and space lists (e.g. `drift` or `hive`), so the app opens instantly and shows "offline" honestly.
  _Plain JSON files in the app's support directory (`lib/data/cache.dart`), no native database. Unreachable at launch, a saved session opens from it with an "Offline · showing saved messages" banner and retries every 20 s; signing out deletes it._
- [x] **Connection state:** detect a dropped gateway socket (needs a `duvet_client` change), show the spinner again, and back off.
  _`GatewayManager.onConnectionState` (duvet-client 1.0.1); the tab titles show the spinner and the chat a "Reconnecting…" banner; chats catch up on READY._
- [x] **Token safety:** stop logging the gateway URL, which contains the token; drop the log hook in release.
- [x] **iOS:** build, `NSPhotoLibraryUsageDescription` / `NSCameraUsageDescription` / microphone strings, Keychain checks.
  _The usage strings (photos, saving photos, camera, microphone) and the `duvet://` URL scheme are in `Info.plist`. Building and checking the Keychain need a Mac: see **Needs you**._
- [ ] **App lock:** lock the app locally behind the phone's biometrics or a PIN of its own (e.g. `local_auth`), off by default and turned on from the You tab. Asks at launch and after the app has been in the background for a while (immediately, 1 minute, 5 minutes…). While locked, a glass lock screen hides every chat, notification previews included once push lands, and the app switcher shows a blank card (`FLAG_SECURE` on Android, a cover view on iOS). Too many wrong PINs: a cooldown, never a wipe. Forgetting the PIN means signing out and in again. Groundwork for end-to-end encryption: the lock's secret, kept in the keystore behind biometrics, is what will later protect the device's E2EE private keys, so design its storage with that in mind. Needs nothing from the API.
- [ ] **Accessibility pass:** [#54](https://github.com/duvetchat/mobile/issues/54)
- [ ] **Localization, Spanish first:** [#55](https://github.com/duvetchat/mobile/issues/55)
- [x] **Golden tests:** for the design-system components (rows, cards, glass, bubbles) in both themes.
  _`test/goldens_test.dart`, with Fira Sans, the Lucide icons and real soft shadows; update with `flutter test --update-goldens test/goldens_test.dart`._
- [x] **CI:** `flutter analyze` + `flutter test` + a release APK on each PR (desktop and api already have `.github/`).
  _`.github/workflows/ci.yml`: checks out `duvetchat/duvet-client` beside the app for the path override, and signs with the release key when the `ANDROID_KEYSTORE_BASE64` / `ANDROID_STORE_PASSWORD` / `ANDROID_KEY_PASSWORD` secrets are set. Not run yet: there's no remote here._
- [x] **Release signing:** a real keystore instead of the debug key; application ID `chat.duvet` instead of `com.example.duvet`.
  _Application ID and bundle IDs are `chat.duvet` (a new install: the old debug app's session doesn't carry over). Release builds sign with `android/key.properties` (template: `key.properties.example`), else the debug key. Making the keystore is yours: see **Needs you**. A debug build installs and runs on the phone as `chat.duvet` (23 Oct 2026); a release build hasn't been made yet._
- [x] **Build settings:** move this machine's Gradle tuning to `~/.gradle/gradle.properties` and restore the repository defaults.

## Found on the phone (23 Oct 2026)

A debug build on an Android 15 phone, signed in, against the live server: no crashes or Flutter errors, gateway steady.

- [x] **Embed titles cut short:** link and webhook cards cut titles at two lines, so GitHub's "Workflow run completed: Deploy (c…" hides whether it succeeded. Let titles run longer (or put the status first).
  _Four lines now, which hold about what desktop's `EmbedCard` shows in its two wider ones: a GitHub run's title, its result included, fits whole in Fira Sans (tested). Not checked on the phone yet._
- [x] **Image placeholders:** while stickers, custom-emoji reactions and avatars load, they're blank: a reaction pill shows only its count and a sticker leaves an empty gap. Show a neutral placeholder (`base-sunken`, the emoji's name in a reaction) until the image arrives.
  _A sticker is a `base-sunken` rounded square until it loads, and gone once it's there, since stickers are see-through. A custom emoji's reaction shows its name (`:party:`), as it did when the image failed. An avatar is a `base-sunken` circle while its picture loads, and keeps its Facehash when there's none or it fails (it used to show the Facehash while loading too). Tested with images that never arrive. Not checked on the phone yet._
- [ ] **The You tab on the device:** [#56](https://github.com/duvetchat/mobile/issues/56)
- [x] **Stuck reconnecting after a network change:** the app went silent, with no heartbeats or retries. _In `duvet-client`: the gateway waited for a `Connected` the socket never sends after its own retry (it sends `Reconnected`), with no timeout; a dropped socket could stay open beside the new one; REST requests had no timeout either. Fixed there (15 s to open a socket, 20 s per request, one socket at a time) with tests against local servers._
- [x] **The + menu stuck high:** opening it closed the keyboard and the composer dropped, but the menu stayed. _Menus now follow their trigger, and never open behind the keyboard. Checked on the phone._
- [x] **Member search:** _filtering works (tested, and checked on the phone); the list didn't load while requests hung after the network change._
- [x] **Invites:** _the Space menu invited to the first text room (#github-logs), where members may not invite. Invites now go to the first room the user may invite to, with room permissions computed as the server does (role grants, then the room's overwrites). In Duvet Official members may invite in no room at all, so Invite people now says so instead of failing; a refused invite says why and offers Try again._
- [x] **Opening a DM:** _from search, the chat never opened (the dropdown's context was gone by the time the server answered). And the server only opens DMs between friends: the app now says "You can only message friends. Send … a friend request first." wherever a DM starts._
- [x] **Creating a Space looked like it failed:** _it was made, but the app opened it before the gateway's SPACE_CREATE and said "This space is gone". `createSpace` (duvet-client) now answers the Space and its rooms, and the app shows it at once._
- [x] **Delete a Space:** _for its owner, from the Space menu (in place of Leave) or Space settings, after typing its name. A soft delete: the API's new `DELETE /api/spaces/{id}` sets `deleted_at` on the Space and its rooms and tells every member (SPACE_DELETE). Once it's deleted, here or on the server, its rooms leave the Chats list too, with their unread marks and mentions, and a Space the server says is gone already (its JSON 404) goes as well. A chat of the Space left open stays until it's left: sending there fails._

## From the review of PR #46 (25 Oct 2026)

What the review found and the PR left as it was. Its four bugs are fixed: a delete is asked for the moment it's confirmed, the dust can't stay drawn over the app, a refused move undoes only what it moved, and the fade under Create room lets taps through.

- [ ] **Dragging a room in a tall category doesn't scroll:** [#57](https://github.com/duvetchat/mobile/issues/57)
- [ ] **A drag held while the rooms change:** [#58](https://github.com/duvetchat/mobile/issues/58)
- [ ] **Equal positions:** [#59](https://github.com/duvetchat/mobile/issues/59)
- [ ] **Screen readers on the rooms page:** [#60](https://github.com/duvetchat/mobile/issues/60)
- [ ] **The dust of a big message:** [#61](https://github.com/duvetchat/mobile/issues/61)
- [ ] **The dust doesn't follow the list:** [#62](https://github.com/duvetchat/mobile/issues/62)
- [ ] **A failed or overtaken delete:** [#63](https://github.com/duvetchat/mobile/issues/63)
- [ ] **A `RepaintBoundary` per message:** [#64](https://github.com/duvetchat/mobile/issues/64)
- [ ] **`IntrinsicHeight` on the rooms page:** [#65](https://github.com/duvetchat/mobile/issues/65)
- [ ] **The test hook on the drag edges:** [#66](https://github.com/duvetchat/mobile/issues/66)

## Needs you

Things this machine or this repository can't finish: each needs a decision, a credential or a change outside `mobile/`.

- **Publish `duvet_client`:** [#67](https://github.com/duvetchat/mobile/issues/67)
- **App links for `https://duvet.chat`:** [#69](https://github.com/duvetchat/mobile/issues/69), with the web side in [desktop-electrobun#75](https://github.com/duvetchat/desktop-electrobun/issues/75)
- **Release keystore:** [#68](https://github.com/duvetchat/mobile/issues/68)
- **iOS:** [#70](https://github.com/duvetchat/mobile/issues/70)
- **A release build on a device:** [#71](https://github.com/duvetchat/mobile/issues/71)
- **Voice and calls on the phone (M8):** [#72](https://github.com/duvetchat/mobile/issues/72)
- **Role positions with gaps (API):** a deleted role's position stays empty, but a move is clamped to the number of roles less one, so a role can't be sent to a gapped position past it. Mobile lays the user's roles out again instead (each sent to the bottom, one request a role), which closes the gaps; compacting on delete, or clamping to the highest position, would make one request enough. A bulk reorder endpoint would make **Admins first** atomic.
- **Gradient names outside Space settings:** member lists and chat names show a gradient role's first color only (`RoleTag` carries one color). Desktop draws the gradient on names; mobile could with the same `RoleName`.
- **Member search (API):** the overwrite member picker filters the members the app has; a Space past one page of members needs `MembersQuery` to search.
- **Goldens:** recorded on Linux, where they pass: `538d2c1` re-recorded the `chat` ones (light and dark) with the Call button in a DM's top bar. On Windows the 4 goldens fail on glyph edges, so regenerate them on Linux only (`flutter test --update-goldens test/goldens_test.dart`).

