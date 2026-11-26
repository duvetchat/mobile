import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../data/models.dart';
import '../e2e/notices.dart';

/// Tells the person, wherever they are in the app, of each edit or deletion of theirs in an encrypted conversation
/// that the server refused for good: their device shows it done, and the others never got it (M3 of task 17's review,
/// in the desktop's words); and of a share of a conversation's history they were told went, which ended for good.
/// Under the app's [FToaster], over every screen.
class ChangeRefusals extends StatefulWidget {
  const ChangeRefusals({required this.refusals, required this.child, super.key});

  final Stream<ChangeRefused> refusals;
  final Widget child;

  @override
  State<ChangeRefusals> createState() => _ChangeRefusalsState();
}

class _ChangeRefusalsState extends State<ChangeRefusals> {
  late StreamSubscription<ChangeRefused> _heard;

  @override
  void initState() {
    super.initState();
    _heard = widget.refusals.listen(_tell);
  }

  @override
  void didUpdateWidget(ChangeRefusals old) {
    super.didUpdateWidget(old);
    if (identical(old.refusals, widget.refusals)) return;
    unawaited(_heard.cancel());
    _heard = widget.refusals.listen(_tell);
  }

  void _tell(ChangeRefused refused) {
    if (!mounted) return;
    final words = refused.share
        ? Notice.shareHistoryFailed
        : refused.deletion
        ? Notice.deleteRefused
        : Notice.editRefused;
    showFToast(context: context, title: Text(words.text), duration: const Duration(seconds: 3));
  }

  @override
  void dispose() {
    unawaited(_heard.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
