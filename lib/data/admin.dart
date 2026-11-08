/// Running a Space: its permissions, roles, rooms' overwrites, invites,
/// emojis and stickers, webhooks and storage.
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

/// The permission bits, as the API's Go constants (`1 << iota`).
abstract final class Perm {
  static const administrator = 1 << 0;
  static const viewChannels = 1 << 1;
  static const sendMessages = 1 << 2;
  static const manageMessages = 1 << 3;
  static const manageChannels = 1 << 4;
  static const changeNickname = 1 << 5;
  static const joinVoice = 1 << 6;
  static const speakInVoice = 1 << 7;
  static const manageRoles = 1 << 8;
  static const manageInvites = 1 << 9;
  static const createInvites = 1 << 10;
  static const manageEmojis = 1 << 11;
  static const manageBuckets = 1 << 12;
  static const manageStickers = 1 << 13;
  static const manageBots = 1 << 14;
  static const manageAttachments = 1 << 15;
  static const manageWebhooks = 1 << 16;
  static const pinMessages = 1 << 17;
  static const video = 1 << 18;

  /// Every bit: the owner, or an administrator.
  static const all = (1 << 19) - 1;

  /// Any of these opens Space settings.
  static const anyAdmin =
      administrator |
      manageChannels |
      manageRoles |
      manageInvites |
      manageEmojis |
      manageStickers |
      manageWebhooks |
      manageAttachments |
      manageBuckets |
      manageBots;

  static bool has(int perms, int bit) => perms & administrator != 0 || perms & bit == bit;
}

/// A permission as people read it, grouped as the role editor shows them.
typedef PermissionInfo = ({int bit, String label, String description});

const permissionGroups = <(String, List<PermissionInfo>)>[
  (
    'Messages',
    [
      (bit: Perm.viewChannels, label: 'See rooms', description: 'Read the rooms they’re let into'),
      (bit: Perm.sendMessages, label: 'Send messages', description: 'Write in text rooms'),
      (bit: Perm.manageMessages, label: 'Delete others’ messages', description: 'In every room they can see'),
      (bit: Perm.pinMessages, label: 'Pin messages', description: 'Keep things findable'),
    ],
  ),
  (
    'Voice',
    [
      (bit: Perm.joinVoice, label: 'Join voice', description: 'Come into voice rooms'),
      (bit: Perm.speakInVoice, label: 'Speak', description: 'Be heard in voice rooms'),
      (bit: Perm.video, label: 'Camera and screen', description: 'Turn on a camera, share the screen'),
    ],
  ),
  (
    'Members',
    [
      (bit: Perm.changeNickname, label: 'Change nickname', description: 'Their own name in this Space'),
      (bit: Perm.createInvites, label: 'Invite people', description: 'Make invite links'),
      (bit: Perm.manageInvites, label: 'Manage invites', description: 'See and revoke every link'),
      (bit: Perm.manageRoles, label: 'Manage roles', description: 'Make roles and give them out'),
    ],
  ),
  (
    'Space',
    [
      (bit: Perm.manageChannels, label: 'Manage rooms', description: 'Create, rename, move, delete'),
      (bit: Perm.manageEmojis, label: 'Manage emojis', description: 'Upload, rename, delete'),
      (bit: Perm.manageStickers, label: 'Manage stickers', description: 'Upload, rename, delete'),
      (bit: Perm.manageWebhooks, label: 'Manage webhooks', description: 'Let other apps post'),
      (bit: Perm.manageBots, label: 'Manage bots', description: 'Add and remove bots'),
      (bit: Perm.manageAttachments, label: 'Manage files', description: 'Delete anyone’s uploads'),
      (bit: Perm.manageBuckets, label: 'Manage storage', description: 'Where the Space’s files are kept'),
      (bit: Perm.administrator, label: 'Administrator', description: 'Every permission, in every room'),
    ],
  ),
];

/// A Space as its settings show it.
class SpaceProfile {
  final String id;
  final String name;
  final String? description;
  final String? iconUrl;
  final String? bannerUrl;

  /// The language the Space mostly speaks, as free text (e.g. "en").
  final String? locale;
  final int memberCount;
  final bool owner;

  /// The user's permissions in the Space (every bit for its owner).
  final int perms;

  /// May manage some room the user sees: ManageChannels there, which the API
  /// checks room by room, overwrites included. Making a room takes it in the
  /// Space ([can]).
  final bool managesRooms;
  const SpaceProfile({
    required this.id,
    required this.name,
    this.description,
    this.iconUrl,
    this.bannerUrl,
    this.locale,
    this.memberCount = 0,
    this.owner = false,
    this.perms = 0,
    this.managesRooms = false,
  });

  bool can(int bit) => owner || Perm.has(perms, bit);

  /// May change anything in Space settings.
  bool get helpsRun => owner || perms & Perm.anyAdmin != 0 || managesRooms;

  /// What the header says about the user.
  String get standing => owner
      ? 'you own it'
      : Perm.has(perms, Perm.administrator)
      ? 'you are an admin'
      : 'you help run it';
}

/// A role, highest first in a list.
class SpaceRole {
  final String id;
  final String name;

  /// RGB, or null for the default ink: a solid color, or a gradient's
  /// start.
  final int? color;

  /// A gradient's middle (optional) and end, left to right, in RGB; without
  /// [colorTo] the color is solid.
  final int? colorVia;
  final int? colorTo;
  final int perms;
  final int position;
  final int memberCount;

  /// The role everyone has: it shares the Space's ID.
  final bool everyone;

  /// Its members show apart in the member list, under its name.
  final bool hoisted;
  const SpaceRole({
    required this.id,
    required this.name,
    this.color,
    this.colorVia,
    this.colorTo,
    this.perms = 0,
    this.position = 0,
    this.memberCount = 0,
    this.everyone = false,
    this.hoisted = false,
  });

  /// Its colors as one value, to compare and to save.
  RoleColors get colors => (from: color, via: colorVia, to: colorTo);
}

/// A role's color: none (no [from]), solid ([from] alone), or a gradient
/// from [from] through [via] to [to], always left to right.
typedef RoleColors = ({int? from, int? via, int? to});

enum AdminRoomKind { text, voice, category }

/// A room, or a category of rooms, as settings list them.
class AdminRoom {
  final String id;
  final String name;
  final AdminRoomKind kind;
  final String? parentId;
  final int position;

  /// What the room is for, or null; a category has none.
  final String? description;
  const AdminRoom({
    required this.id,
    required this.name,
    required this.kind,
    this.parentId,
    this.position = 0,
    this.description,
  });
}

/// A role's or member's allows and denies in one room.
class RoomOverwrite {
  final String targetId;

  /// 0 a role, 1 a member.
  final int targetType;
  final int allow;
  final int deny;
  const RoomOverwrite({required this.targetId, this.targetType = 0, this.allow = 0, this.deny = 0});

  /// Allowed (true), denied (false) or as the role says (null).
  bool? stateOf(int bit) => allow & bit != 0
      ? true
      : deny & bit != 0
      ? false
      : null;

  RoomOverwrite withState(int bit, bool? state) => RoomOverwrite(
    targetId: targetId,
    targetType: targetType,
    allow: state == true ? allow | bit : allow & ~bit,
    deny: state == false ? deny | bit : deny & ~bit,
  );

  bool get isEmpty => allow == 0 && deny == 0;
}

class SpaceInvite {
  final String id;
  final String code;
  final String roomName;
  final String createdBy;
  final DateTime createdAt;
  final DateTime? expiresAt;
  const SpaceInvite({
    required this.id,
    required this.code,
    required this.roomName,
    required this.createdBy,
    required this.createdAt,
    this.expiresAt,
  });
}

enum AssetKind { emoji, sticker }

/// An emoji or sticker of the Space.
class SpaceAsset {
  final String id;
  final String name;
  final String url;
  const SpaceAsset({required this.id, required this.name, required this.url});
}

class SpaceWebhook {
  final String id;
  final String roomId;
  final String roomName;
  final String name;
  final String? avatarUrl;
  final DateTime createdAt;
  const SpaceWebhook({
    required this.id,
    required this.roomId,
    required this.roomName,
    required this.name,
    required this.createdAt,
    this.avatarUrl,
  });
}

/// A developer team. Its owner is its only admin: the API makes whoever accepts
/// an invite a member, and has no way to promote one.
class DevTeam {
  final String id;
  final String name;
  final String ownerId;
  const DevTeam({required this.id, required this.name, required this.ownerId});
}

/// An invite to join a team, waiting on the user.
class TeamInvite {
  final String id;
  final String teamName;
  final String invitedBy;
  const TeamInvite({required this.id, required this.teamName, required this.invitedBy});
}

/// A team's application, and its bot when it has one.
class DevApp {
  final String id;
  final String teamId;
  final String name;
  final String? description;
  final bool public;
  final String? botUserId;
  const DevApp({
    required this.id,
    required this.teamId,
    required this.name,
    this.description,
    this.public = false,
    this.botUserId,
  });
}

/// Where a Space's files are, and how much they take.
class SpaceStorage {
  final int used;
  final List<({String name, int used, int? max, bool active})> buckets;
  final List<({String name, String contentType, int size, DateTime createdAt})> files;
  const SpaceStorage({required this.used, this.buckets = const [], this.files = const []});
}

// -----------------------------------------------------------------------------
// Role colors
// -----------------------------------------------------------------------------

/// The swatches a role's name can take: checked against both themes by
/// [readableOn], which nudges them when they'd be too faint.
const roleSwatches = <int>[0xE5484D, 0xF76B15, 0xD6A400, 0x30A46C, 0x12A594, 0x0090FF, 0x3E63DD, 0x8E4EC6, 0xD6409F];

double _luminance(Color c) {
  double channel(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG's contrast ratio of two colors.
double contrastOf(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// [color], darkened on a light background or lightened on a dark one until
/// it reads at 4.5:1: role colors tint names, and names must stay legible.
Color readableOn(Color color, Color background) {
  final darken = _luminance(background) > 0.5;
  var c = color;
  for (var i = 0; i < 20 && contrastOf(c, background) < 4.5; i++) {
    c = Color.lerp(c, darken ? const Color(0xFF000000) : const Color(0xFFFFFFFF), 0.1)!;
  }
  return c;
}
