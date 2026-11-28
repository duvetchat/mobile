import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../data/models.dart';
import '../data/repository.dart';
import '../e2e/engine.dart' show HistoryOffer, SharedHistory, shareRanges;
import '../e2e/notices.dart';
import '../theme.dart';
import '../widgets/chrome.dart';
import '../widgets/depth.dart';
import '../widgets/glass.dart';
import '../widgets/rows.dart';

/// The person shares an encrypted conversation's history with [member], another of its members (PLAN-E2E-CLIENTES.md,
/// Task 31; decision 26): how far back, then Share, on their tap alone. While the server takes it the sheet stays; once
/// it did, the sheet closes, answering what to tell the person ([sharedSaid]; null when closed before), and the rest
/// goes by itself. A refusal stays in it, in the app's words, for another try. The desktop's ShareHistoryDialog.svelte.
Future<String?> showShareHistorySheet(
  BuildContext context, {
  required ChatRepository repository,
  required String conversationId,
  required Member member,
}) => showGlassDialogSheet<String>(
  context,
  label: Notice.shareHistory.text,
  builder: (context) => _ShareHistorySheet(repository: repository, conversationId: conversationId, member: member),
);

/// A range in the sheet's words: its notice's, from a capital.
String _rangeLabel(String range) {
  final text = rangeText(range);
  return '${text[0].toUpperCase()}${text.substring(1)}';
}

class _ShareHistorySheet extends StatefulWidget {
  const _ShareHistorySheet({required this.repository, required this.conversationId, required this.member});

  final ChatRepository repository;
  final String conversationId;
  final Member member;

  @override
  State<_ShareHistorySheet> createState() => _ShareHistorySheetState();
}

class _ShareHistorySheetState extends State<_ShareHistorySheet> {
  var _range = 'week';
  var _sharing = false;
  String? _refused;

  Future<void> _share() async {
    setState(() {
      _sharing = true;
      _refused = null;
    });
    try {
      final shared = await widget.repository.shareHistory(widget.conversationId, widget.member.userId, _range);
      if (mounted) Navigator.of(context).pop(sharedSaid(shared, widget.member.displayName, _range));
    } catch (e) {
      if (mounted) setState(() => _refused = e is ActionFailed ? e.message : Notice.shareHistoryFailed.text);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final name = widget.member.displayName;
    // While the server takes the share the sheet doesn't close: its answer says how it went.
    return PopScope(
      canPop: !_sharing,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                Notice.shareHistoryWith.fill({'name': name}),
                style: DuvetType.title.copyWith(color: colors.foreground),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              Notice.shareHistoryLine.fill({'name': name}),
              style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
            ),
            const SizedBox(height: 16),
            for (final range in shareRanges)
              Semantics(
                inMutuallyExclusiveGroup: true,
                checked: range == _range,
                child: GlassRow(
                  label: _rangeLabel(range),
                  icon: range == _range ? FLucideIcons.circleCheck : FLucideIcons.circle,
                  selected: range == _range,
                  onPressed: () {
                    if (!_sharing) setState(() => _range = range);
                  },
                ),
              ),
            if (_refused case final refused?) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(refused, style: DuvetType.caption.copyWith(color: colors.destructive)),
              ),
            ],
            const SizedBox(height: 24),
            DuvetButton(
              label: _sharing ? Notice.shareHistorySharing.text : Notice.shareHistorySend.text,
              icon: FLucideIcons.history,
              variant: ButtonVariant.primary,
              expand: true,
              onPressed: _sharing ? null : _share,
            ),
            const SizedBox(height: 12),
            DuvetButton(label: 'Cancel', expand: true, onPressed: _sharing ? null : () => Navigator.of(context).pop()),
          ],
        ),
      ),
    );
  }
}

/// What the person is told once the server took their share of [range] for [name]: that they shared it, as its notice
/// says it in the chat once its keys went; or that it was cut to its newest messages, from when they get every one.
String sharedSaid(SharedHistory shared, String name, String range) => shared.truncated
    ? Notice.shareHistoryTruncated.fill({'name': name, 'date': fullDate(shared.start.toLocal())})
    : Notice.shared.fill({'a': 'You', 'range': rangeText(range), 'b': name});

/// A share of the conversation's history that another member made for this device, over its message box until the
/// person adds it or dismisses it (PLAN-E2E-CLIENTES.md, Task 31; R2 of the core's review): who shared how far back,
/// Add to this device, and Dismiss. A yes that fails says so here, and the offer stays for another. The desktop's
/// SharedHistoryOffer.svelte, in the encryption banner's look.
class SharedHistoryOfferBar extends StatefulWidget {
  const SharedHistoryOfferBar({
    super.key,
    required this.offer,
    required this.nameOf,
    required this.onAdd,
    required this.onDismiss,
  });

  /// An offer of the conversation, or null for none.
  final HistoryOffer? offer;

  /// A member of the conversation, by the name the app shows them.
  final String Function(String userId) nameOf;
  final Future<void> Function(HistoryOffer offer) onAdd;

  /// The person's no: the server is told this device is done with it.
  final Future<void> Function(HistoryOffer offer) onDismiss;

  @override
  State<SharedHistoryOfferBar> createState() => _SharedHistoryOfferBarState();
}

class _SharedHistoryOfferBarState extends State<SharedHistoryOfferBar> {
  var _adding = false;
  String? _failed;

  @override
  void didUpdateWidget(SharedHistoryOfferBar old) {
    super.didUpdateWidget(old);
    if (old.offer != widget.offer) _failed = null;
  }

  Future<void> _add(HistoryOffer offer) async {
    setState(() {
      _adding = true;
      _failed = null;
    });
    try {
      await widget.onAdd(offer);
    } catch (e) {
      if (mounted) setState(() => _failed = e is ActionFailed ? e.message : Notice.sharedAddFailed.text);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer;
    if (offer == null) return const SizedBox.shrink();
    final colors = context.theme.colors;
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusField));
    final said = Notice.sharedWithYou.fill({'a': widget.nameOf(offer.fromUserId), 'range': rangeText(offer.range)});
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: DecoratedBox(
          decoration: BoxDecoration(color: colors.secondary, borderRadius: radius),
          child: InsetShadow(
            shadows: context.duvet.shadowWell,
            borderRadius: radius,
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                ExcludeSemantics(child: Icon(FLucideIcons.history, size: 16, color: colors.foreground)),
                const SizedBox(width: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      [said, ?_failed].join('\n'),
                      style: DuvetType.caption.copyWith(color: colors.foreground),
                    ),
                  ),
                ),
                TextAction(label: Notice.sharedAdd.text, onPressed: _adding ? null : () => _add(offer)),
                IconAction(
                  icon: FLucideIcons.x,
                  label: 'Dismiss',
                  onPressed: _adding ? null : () => unawaited(widget.onDismiss(offer)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
