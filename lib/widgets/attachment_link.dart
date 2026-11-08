import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

import '../data/models.dart';
import '../data/scope.dart';

/// Answers a link to a file that works now; [refused]: the last one failed
/// to load, so a new one.
typedef LinkSource = Future<String> Function({bool refused});

/// Where [attachment]'s working link comes from
/// ([ChatRepository.attachmentLink]): the repository above [context], taken
/// now, so the source outlives the widget (a voice note playing on once its
/// bubble scrolled away). Its own link when there's none above (a widget on
/// its own) or the link doesn't expire.
LinkSource linkSource(BuildContext context, MessageAttachment attachment) {
  final repository = context.getInheritedWidgetOfExactType<RepositoryScope>()?.repository;
  if (repository == null || attachment.linkExpires == null) return ({refused = false}) async => attachment.url;
  return ({refused = false}) => repository.attachmentLink(attachment, refused: refused);
}

/// Builds [builder] with a link to [attachment] that works: a new one first
/// when its own is about to expire ([waiting] meanwhile), and once more when
/// the one given fails to load and [builder] calls its `refused` (#182).
class AttachmentLinkBuilder extends StatefulWidget {
  final MessageAttachment attachment;
  final Widget Function(BuildContext context, String url, VoidCallback refused) builder;
  final Widget waiting;
  const AttachmentLinkBuilder({
    required this.attachment,
    required this.builder,
    this.waiting = const SizedBox.expand(),
    super.key,
  });

  @override
  State<AttachmentLinkBuilder> createState() => _AttachmentLinkBuilderState();
}

class _AttachmentLinkBuilderState extends State<AttachmentLinkBuilder> {
  String? _url;
  bool _retried = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(AttachmentLinkBuilder old) {
    super.didUpdateWidget(old);
    // A new link came with the message (this one's renewal, often).
    if (widget.attachment.url != old.attachment.url || widget.attachment.id != old.attachment.id) {
      _retried = false;
      _start();
    }
  }

  void _start() {
    final a = widget.attachment;
    if (a.linkDueAt(clock.now())) {
      _url = null;
      _ask(refused: false);
    } else {
      _url = a.url;
    }
  }

  Future<void> _ask({required bool refused}) async {
    final asked = widget.attachment;
    final url = await linkSource(context, asked)(refused: refused);
    // Another file meanwhile, or the same one with a link newer than this.
    final current = widget.attachment;
    if (!mounted || current.id != asked.id || current.url != asked.url) return;
    if (url != _url) setState(() => _url = url);
  }

  void _refused() {
    if (_retried) return;
    _retried = true;
    _ask(refused: true);
  }

  @override
  Widget build(BuildContext context) => switch (_url) {
    final url? => widget.builder(context, url, _refused),
    null => widget.waiting,
  };
}
