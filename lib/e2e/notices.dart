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
  removedDevice('This device was removed from your account.'),
  locked('Encrypted conversations are open in another Duvet window.'),
  waitOwner('Waiting for {owner} to open this group'),
  waitRejoin("You'll be back in this conversation when another member opens it."),
  membersChanged("This conversation's members changed since you last saw it."),
  membersAccept('Open with these members'),
  backupPaused('Your encrypted backup is paused: your storage is full.'),
  deviceAdded('A new device was added to your account: {name}.'),
  deleteDevice('Remove this device and delete its data'),
  tooLong('Message too long'),
  editRefused("Your edit couldn't be saved for everyone."),
  deleteRefused("Your message couldn't be deleted for everyone."),
  loadingMessage('Loading message'),
  filesWait("Files and voice messages can't be sent in encrypted conversations yet"),
  notReady("Encrypted conversations aren't ready on this device"),
  tooManyWaiting('Too many messages wait to be sent here: send or dismiss them first'),
  searchSplit(
    "In an encrypted conversation, pinned: and has:sticker can't be combined with words or with has:image, video or sound.",
  ),

  /// A push's notification of a message this device couldn't open in its time (Ruling 18): Android's alone.
  newMessage('New message');

  const Notice(this.text);

  /// The notice's text, its {names} as they are.
  final String text;

  /// Its name in both apps' table: `recovery_title`.
  String get key => name.replaceAllMapped(RegExp('[A-Z]'), (match) => '_${match[0]!.toLowerCase()}');

  /// Its text with its {names} filled from [values] in one pass: what a value holds is never read as a name.
  String fill([Map<String, String> values = const {}]) =>
      text.replaceAllMapped(RegExp(r'\{(\w+)\}'), (match) => values[match[1]] ?? match[0]!);
}
