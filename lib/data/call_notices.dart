import 'models.dart';

/// Which of its sentences a call notice says to whoever reads it, as the
/// desktop has them:
/// - [joined]: others got into the call, and so did the reader, or it was
///   theirs: "Alice started a call that lasted 5 minutes.";
/// - [missed]: others got into it, but not the reader (a group's call): "You
///   missed a call from Alice that lasted 12 minutes.";
/// - [unanswered]: nobody but its caller got in, and the reader is the
///   caller: "You started a call. No one answered.";
/// - [missedUnanswered]: nobody but its caller got in, and the reader is
///   someone it rang: "You missed a call from Alice.".
enum CallNoticeCase { joined, missed, unanswered, missedUnanswered }

/// The case of [call], placed by [callerId], for the reader [me] (null:
/// nobody it knows).
CallNoticeCase callNoticeCase(CallNotice call, String callerId, String? me) {
  final mine = me != null && me == callerId;
  if (!call.participants.any((id) => id != callerId)) {
    return mine ? CallNoticeCase.unanswered : CallNoticeCase.missedUnanswered;
  }
  return mine || (me != null && call.participants.contains(me)) ? CallNoticeCase.joined : CallNoticeCase.missed;
}

/// How long a call lasted, ringing included: "a few seconds" under a minute,
/// then in whole minutes, and from an hour in hours and minutes.
String callDuration(Duration d) {
  final minutes = d.inMinutes;
  if (minutes < 1) return 'a few seconds';
  String count(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';
  if (minutes < 60) return count(minutes, 'minute');
  final hours = count(minutes ~/ 60, 'hour');
  return minutes % 60 == 0 ? hours : '$hours ${count(minutes % 60, 'minute')}';
}

/// A call notice's sentence for its reader: [before], then the caller's
/// [name], which stands out as the pin notice's names do (empty when the
/// sentence says "You" for them), then [after]. [missed]: the reader missed
/// the call, and its phone is red.
typedef CallNoticeLine = ({bool missed, String before, String name, String after});

/// What [m]'s call notice says to the reader [me]; null for any other
/// message.
CallNoticeLine? callNoticeLine(ChatMessage m, String? me) {
  final call = m.call;
  final callerId = m.authorId;
  if (call == null || callerId == null) return null;
  final name = m.authorName;
  final lasted = callDuration(call.duration);
  return switch (callNoticeCase(call, callerId, me)) {
    CallNoticeCase.joined when callerId == me => (
      missed: false,
      before: 'You started a call that lasted $lasted.',
      name: '',
      after: '',
    ),
    CallNoticeCase.joined => (missed: false, before: '', name: name, after: ' started a call that lasted $lasted.'),
    CallNoticeCase.missed => (
      missed: true,
      before: 'You missed a call from ',
      name: name,
      after: ' that lasted $lasted.',
    ),
    CallNoticeCase.unanswered => (missed: false, before: 'You started a call. No one answered.', name: '', after: ''),
    CallNoticeCase.missedUnanswered => (missed: true, before: 'You missed a call from ', name: name, after: '.'),
  };
}

/// Whether [me] saw the call, as the API counts it for its notice: they were
/// in it, or [answered] it from one of their devices, accepting or declining
/// it. The API leaves the conversation read for them up to the notice; it's
/// unread only for those the call rang who never answered.
bool callNoticeSeen(CallNotice call, String me, {required bool answered}) => answered || call.participants.contains(me);
