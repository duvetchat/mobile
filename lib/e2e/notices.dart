/// What the app says about encrypted conversations, word for word as the desktop says it (PLAN-E2E-CLIENTES.md, its
/// notices): test/e2e/notices_test.dart holds both to the table in test/e2e/e2e-conventions.json, which the desktop's
/// test reads too.
enum Notice {
  recoveryTitle('Save your recovery key'),
  recoverySaved('I saved it'),
  waiting('Waiting for this message'),
  waitingDetail("It will show up when the sender's device delivers it."),
  noDevice("{name} can't receive encrypted messages yet. Your device will pass them on when they can."),
  keyChanged("{name}'s security key changed."),
  keyChangedVerified('You had verified {name}. Check their security number before you send.'),
  // A contact's security number, the mark of one the person verified, and the yes a verified one's changed key asks
  // for before anything more goes to them (Tasks 28 and 29).
  verifyNumber('Verify security number'),
  markVerified('Mark as verified'),
  verified('Verified'),
  sendAnyway('Send anyway'),
  cutover('Messages from before end-to-end encryption were deleted on {date}'),
  update('Update Duvet'),
  noE2eHere("Direct messages aren't available in this app yet. Use Duvet on the web."),
  paused("Encrypted conversations are paused. Your message will be sent when they're back."),
  unsupportedBrowser("This browser can't open encrypted conversations."),
  beforeJoining("Messages from before you joined aren't on this device. Any member can share them."),
  shared('{a} shared {range} with {b}'),
  sharedBy('shared by {name}'),
  rangeDay('the last 24 hours'),
  rangeWeek('the last 7 days'),
  rangeMonth('the last 30 days'),
  rangeAll("the conversation's history"),
  inactiveDevice('Not seen in 45 days'),
  inactiveWarning("{device} hasn't connected in over 45 days. Remove it if you don't use it."),
  blocked("This conversation can't go on securely."),
  blockedOwner('Restart encryption'),
  blockedWait('Waiting for {owner} to restart it.'),
  restartLeavesOut('Restarting leaves out {names}, who are no longer in this conversation.'),
  restartRefused("Encryption can't restart here yet."),
  groupFull('A group can have 20 members at most.'),
  membersNow('Members now: {names}'),
  changeUnanswered('No answer came yet: Duvet tries again on its own.'),

  /// A conversation's history shared with a member, and the offer of what another member shared (Tasks 30 and 31).
  shareHistory('Share history'),
  shareHistoryWith('Share history with {name}'),
  shareHistoryLine('{name} gets the messages this device holds from the time you pick, marked as shared by you.'),
  shareHistorySend('Share'),
  shareHistorySharing('Sharing…'),
  shareHistoryTruncated('Not all of it fit: {name} gets the messages from {date} on.'),
  shareHistoryLimit('You can share history 10 times an hour. Try again {when}.'),
  shareHistoryFailed("Couldn't share the history. Try again."),
  shareHistoryNoDevice('{name} has no device that can receive it yet.'),
  sharedWithYou('{a} shared {range} with you'),
  sharedAdd('Add to this device'),
  sharedAddFailed("Couldn't add the shared messages. Try again."),
  removedDevice('This device was removed from your account.'),
  locked('Encrypted conversations are open in another Duvet window.'),

  /// The same on a phone, which has no windows: a push's engine holds the database as the app opens it (Android's).
  lockedPhone('Encrypted conversations are busy on this phone. Duvet tries again on its own.'),
  // The API serves another external sender than the one this device pinned (Ruling 32).
  serverKeyChanged(
    "Duvet's server key isn't the one this device first saw. This device keeps the first one, so a conversation that "
    "uses the new one won't open here.",
  ),
  waitOwner('Waiting for {owner} to open this group'),
  waitRejoin("You'll be back in this conversation when another member opens it."),
  membersChanged("This conversation's members changed since you last saw it."),
  membersAccept('Open with these members'),
  backupPaused('Your encrypted backup is paused: your storage is full.'),

  /// The encrypted backup's state, as Settings → Devices shows it, and a new device's restore (Tasks 32 and 33).
  backup('Encrypted backup'),
  backupUpToDate('Up to date'),
  backupUploading('Backing up…'),
  backupRestoring('Restoring your messages: {done} of {total}'),
  backupTooLarge('Your encrypted backup is paused: a day of messages is too large to back up.'),
  deviceAdded('A new device was added to your account: {name}.'),
  deleteDevice('Remove this device and delete its data'),
  tooLong('Message too long'),
  editRefused("Your edit couldn't be saved for everyone."),
  deleteRefused("Your message couldn't be deleted for everyone."),
  loadingMessage('Loading message'),
  notReady("Encrypted conversations aren't ready on this device"),
  tooManyWaiting('Too many messages wait to be sent here: send or dismiss them first'),
  fileEncrypted('Encrypted file'),
  fileProgress('Downloading · {percent}%'),
  fileAltered("This file isn't the one its sender sent, so it isn't shown."),
  fileUnavailable("This file can't be shown."),
  fileDownloadFailed("Couldn't download this file. Try again."),
  filesGone("This message's files aren't on this device any more. Dismiss it, then send them again."),
  gifFailed("The GIF couldn't be sent."),
  fileSave('Save'),
  fileSaveNamed('Save {name}'),
  filePlay('Play video'),
  fileShow('Show picture'),
  fileNamed('{name}: {status}'),
  searchSplit(
    "In an encrypted conversation, pinned: and has:sticker can't be combined with words or with has:image, video or sound.",
  ),

  /// A push's notification of a message this device couldn't open in its time (Ruling 18): Android's alone.
  newMessage('New message'),

  // A new device's setup (Tasks 26 and 27): its approval by another device, and starting over.
  useCode('Use a code instead'),
  approvalCodeHint('Type the code your other device shows'),
  approvalAsk('Is this device yours?'),
  approvalConfirmAfter('Confirm only after your new device accepts it'),
  codeAccepted('Code accepted: confirm it on your other device.'),
  codeMismatch("That isn't the code your other device shows."),
  startOverWarning(
    "Starting over makes new security keys for your account. The history of your encrypted conversations can't be "
    'read any more, and your contacts will see that your keys changed.',
  );

  const Notice(this.text);

  /// The notice's text, its {names} as they are.
  final String text;

  /// Its name in both apps' table: `recovery_title`.
  String get key => name.replaceAllMapped(RegExp('[A-Z]'), (match) => '_${match[0]!.toLowerCase()}');

  /// Its text with its {names} filled from [values] in one pass: what a value holds is never read as a name.
  String fill([Map<String, String> values = const {}]) =>
      text.replaceAllMapped(RegExp(r'\{(\w+)\}'), (match) => values[match[1]] ?? match[0]!);

  /// Its text in parts, each {name} filled from [values] and marked with its name, the text between them with none: a
  /// row that draws its names apart.
  List<({String text, String? name})> parts([Map<String, String> values = const {}]) {
    final parts = <({String text, String? name})>[];
    var at = 0;
    for (final match in RegExp(r'\{(\w+)\}').allMatches(text)) {
      if (match.start > at) parts.add((text: text.substring(at, match.start), name: null));
      parts.add((text: values[match[1]] ?? match[0]!, name: match[1]));
      at = match.end;
    }
    if (at < text.length) parts.add((text: text.substring(at), name: null));
    return parts;
  }
}

/// A shared history's range as the core names it (day, week, month or all) in its notices' words: «the last 7 days».
/// One the app doesn't know reads as all of it, as the desktop's.
String rangeText(String range) => switch (range) {
  'day' => Notice.rangeDay.text,
  'week' => Notice.rangeWeek.text,
  'month' => Notice.rangeMonth.text,
  _ => Notice.rangeAll.text,
};
