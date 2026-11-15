import 'package:flutter/widgets.dart';
import 'package:forui/forui.dart';

import '../data/models.dart';
import '../data/scope.dart';
import '../space_admin.dart';
import 'glass.dart';

/// The levels by name, as the desktop's menus have them.
const levelNames = {
  NotificationLevel.all: 'All messages',
  NotificationLevel.mentions: 'Only mentions',
  NotificationLevel.nothing: 'Nothing',
};

/// A place's Notifications menu, under [anchor]: every message, only mentions or nothing, and for a Space or a room its
/// default, which clears the user's own level: a Space's is what its owner chose, a room's its Space's level ([spaceId],
/// the room's Space). A chat's default is every message, chosen as such. The level shows once the server's
/// NOTIFICATION_SETTINGS_UPDATE comes back; a failure says so.
Future<void> showNotificationMenu(
  BuildContext anchor, {
  required String targetId,
  required NotificationTarget target,
  String? spaceId,
}) async {
  final repository = anchor.repository;
  final own = repository.notificationLevels.value[targetId];
  final inherited = switch (target) {
    NotificationTarget.space => repository.spaceDefault(targetId),
    NotificationTarget.room => repository.spaceLevel(spaceId!),
    NotificationTarget.conversation => null,
  };
  final chosen = inherited == null ? own ?? NotificationLevel.all : own;
  GlassMenuItem<({NotificationLevel? level})> item(IconData icon, String label, NotificationLevel? level) =>
      GlassMenuItem(
        icon: level == chosen ? FLucideIcons.check : icon,
        label: label,
        value: (level: level),
        hint: level == chosen ? 'Selected' : null,
      );
  final picked = await showGlassMenu(
    anchor,
    label: 'Notifications',
    items: [
      if (inherited != null) item(FLucideIcons.rotateCcw, 'Default (${levelNames[inherited]})', null),
      item(FLucideIcons.bell, levelNames[NotificationLevel.all]!, NotificationLevel.all),
      item(FLucideIcons.atSign, levelNames[NotificationLevel.mentions]!, NotificationLevel.mentions),
      item(FLucideIcons.bellOff, levelNames[NotificationLevel.nothing]!, NotificationLevel.nothing),
    ],
  );
  // The pick goes though its anchor went meanwhile (a Chats row moved by a message elsewhere); a failure says so while
  // the anchor is there.
  if (picked == null || picked.level == chosen) return;
  try {
    await repository.setNotificationLevel(targetId, target, picked.level);
  } catch (e) {
    debugPrint('notification level: $e');
    if (anchor.mounted) adminToast(anchor, e is ActionFailed ? e.message : 'Couldn’t change the notifications');
  }
}
