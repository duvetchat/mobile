import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'account.dart' show CropPage, maxDisplayNameLength, pickProfilePicture;
import 'app_commands.dart';
import 'data/links.dart' show botInviteLink;
import 'data/models.dart';
import 'data/scope.dart';
import 'space_admin.dart';
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/glass.dart';
import 'widgets/picture_edit.dart';
import 'widgets/rows.dart';
import 'widgets/sheets.dart' show LoadingSkeleton, placeholderNames, placeholderRows;
import 'widgets/skeleton.dart' show Bone;

// The developer portal, as the desktop's Settings → Developer: teams, their
// members and invites, their applications and the applications' bots. Only a
// team's owner is its admin, and only an admin may change anything in it, so
// the rest see it read-only.

/// Copies the link that adds the bot to a Space.
void copyBotInvite(BuildContext context, String botUserId) {
  Clipboard.setData(ClipboardData(text: botInviteLink(botUserId)));
  adminToast(context, 'Invite link copied');
}

/// The user's teams, and the invites to others waiting on them.
class DeveloperPage extends StatefulWidget {
  const DeveloperPage({super.key});

  @override
  State<DeveloperPage> createState() => _DeveloperPageState();
}

class _DeveloperPageState extends State<DeveloperPage> {
  late Future<List<DevTeam>> _teams;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _teams = context.repository.teams();
  }

  void _reload() => setState(() {
    _teams = context.repository.teams();
  });

  Future<void> _open(DevTeam team) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TeamPage(team: team)));
    if (mounted) _reload();
  }

  Future<void> _new() async {
    final got = await askName<void>(context, title: 'New team', action: 'Create');
    if (got == null || !mounted) return;
    final repository = context.repository;
    try {
      final team = await repository.createTeam(got.$1);
      if (mounted) await _open(team);
    } catch (e) {
      if (mounted) adminToast(context, e is ActionFailed ? e.message : 'Couldn’t create the team');
    }
  }

  Future<void> _answer(TeamInvite invite, {required bool accept}) async {
    final repository = context.repository;
    final done = await adminTry(
      context,
      accept ? 'Couldn’t join ${invite.teamName}' : 'Couldn’t decline the invite',
      () => accept ? repository.acceptTeamInvite(invite.id) : repository.declineTeamInvite(invite.id),
    );
    if (done && accept && mounted) {
      adminToast(context, 'You joined ${invite.teamName}');
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final me = repository.profile.value?.id;
    final colors = context.theme.colors;
    return ListenableBuilder(
      listenable: repository.teamInvites,
      builder: (context, _) => FutureBuilder(
        future: _teams,
        builder: (context, snapshot) {
          final invites = repository.teamInvites.value;
          final teams = snapshot.data;
          return AdminPage(
            title: 'Developer',
            actions: [IconAction(icon: FLucideIcons.plus, label: 'New team', onPressed: _new)],
            children: [
              if (invites.isNotEmpty) ...[
                const Overline('Team invites'),
                AdminPanel(
                  children: [
                    for (final invite in invites)
                      Semantics(
                        container: true,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(invite.teamName, style: DuvetType.rowTitle.copyWith(color: colors.foreground)),
                                    Text(
                                      'Invited by ${invite.invitedBy}',
                                      style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              DuvetButton(label: 'Decline', onPressed: () => _answer(invite, accept: false)),
                              const SizedBox(width: 8),
                              DuvetButton(
                                label: 'Accept',
                                variant: ButtonVariant.primary,
                                onPressed: () => _answer(invite, accept: true),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const Overline('Teams'),
              if (snapshot.hasError)
                const ListNote('Couldn’t load your teams')
              else if (teams == null)
                LoadingSkeleton(
                  label: 'Loading teams',
                  children: [
                    AdminPanel(
                      children: [
                        for (final name in placeholderNames.take(2))
                          GlassRow(icon: FLucideIcons.users, label: name, onPressed: () {}),
                      ],
                    ),
                  ],
                )
              else if (teams.isEmpty)
                const ListNote('No teams yet. Make one to build applications and bots.')
              else
                AdminPanel(
                  children: [
                    for (final team in teams)
                      GlassRow(
                        icon: FLucideIcons.users,
                        label: team.name,
                        detail: team.ownerId == me ? 'Owner' : null,
                        onPressed: () => _open(team),
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A team's members and applications; its owner manages both.
class TeamPage extends StatefulWidget {
  final DevTeam team;
  const TeamPage({required this.team, super.key});

  @override
  State<TeamPage> createState() => _TeamPageState();
}

class _TeamPageState extends State<TeamPage> {
  late String _name = widget.team.name;
  late Future<(List<Member>, List<DevApp>)> _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _data = _load();
  }

  Future<(List<Member>, List<DevApp>)> _load() {
    final repository = context.repository;
    return (repository.teamMembers(widget.team.id), repository.applications(widget.team.id)).wait;
  }

  void _reload() => setState(() {
    _data = _load();
  });

  bool get _owner => widget.team.ownerId == context.repository.profile.value?.id;

  Future<void> _options() async {
    final picked = await showGlassSheet<String>(
      context,
      label: _name,
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          SheetTitle(title: _name),
          GlassRow(icon: FLucideIcons.pencil, label: 'Rename', onPressed: () => Navigator.of(context).pop('rename')),
          GlassRow(
            icon: FLucideIcons.trash2,
            label: 'Delete team',
            destructive: true,
            onPressed: () => Navigator.of(context).pop('delete'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    final repository = context.repository;
    switch (picked) {
      case 'rename':
        final got = await askName<void>(context, title: 'Rename $_name', initial: _name);
        if (got == null || !mounted) return;
        if (await adminTry(context, 'Couldn’t rename the team', () => repository.renameTeam(widget.team.id, got.$1))) {
          setState(() => _name = got.$1);
        }
      case 'delete':
        final sure = await confirmDestructive(
          context,
          title: 'Delete $_name?',
          body: 'All its applications will be deleted, and their bots with them.',
          action: 'Delete team',
        );
        if (!sure || !mounted) return;
        if (await adminTry(context, 'Couldn’t delete the team', () => repository.deleteTeam(widget.team.id)) &&
            mounted) {
          Navigator.of(context).pop();
        }
    }
  }

  Future<void> _invite() async {
    final got = await askName<void>(context, title: 'Invite to $_name', label: 'Email', action: 'Invite');
    if (got == null || !mounted) return;
    final repository = context.repository;
    if (await adminTry(context, 'Couldn’t invite them', () => repository.inviteToTeam(widget.team.id, got.$1)) &&
        mounted) {
      adminToast(context, 'Invite sent');
    }
  }

  Future<void> _remove(Member m) async {
    final sure = await confirmDestructive(
      context,
      title: 'Remove ${m.displayName}?',
      body: 'They lose access to $_name and its applications.',
      action: 'Remove',
    );
    if (!sure || !mounted) return;
    final repository = context.repository;
    await adminTry(context, 'Couldn’t remove them', () => repository.removeTeamMember(widget.team.id, m.userId));
    if (mounted) _reload();
  }

  Future<void> _newApp() async {
    final got = await askName<void>(context, title: 'New application', action: 'Create');
    if (got == null || !mounted) return;
    final repository = context.repository;
    try {
      final app = await repository.createApplication(widget.team.id, got.$1);
      if (mounted) await _openApp(app);
    } catch (e) {
      if (mounted) adminToast(context, e is ActionFailed ? e.message : 'Couldn’t create the application');
    }
    if (mounted) _reload();
  }

  Future<void> _openApp(DevApp app) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ApplicationPage(app: app)));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final owner = _owner;
    return FutureBuilder(
      future: _data,
      builder: (context, snapshot) {
        final data = snapshot.data;
        return AdminPage(
          title: _name,
          actions: [if (owner) IconAction(icon: FLucideIcons.ellipsis, label: 'Team options', onPressed: _options)],
          children: [
            if (snapshot.hasError)
              const ListNote('Couldn’t load the team')
            else if (data == null)
              LoadingSkeleton(
                label: 'Loading the team',
                children: [
                  const Overline('Members'),
                  AdminPanel(children: placeholderRows(avatar: 40).take(2).toList()),
                ],
              )
            else ...[
              const Overline('Members'),
              AdminPanel(
                children: [
                  for (final m in data.$1)
                    ListRow(
                      leading: ExcludeSemantics(
                        child: UserAvatar(name: m.displayName, url: m.avatarUrl, size: 40),
                      ),
                      title: m.displayName,
                      snippet: m.userId == widget.team.ownerId ? 'Admin' : '@${m.username}',
                      detail: owner && m.userId != widget.team.ownerId ? 'Double tap to remove' : null,
                      onTap: owner && m.userId != widget.team.ownerId ? () => _remove(m) : null,
                    ),
                ],
              ),
              // A panel of its own: a GlassRow among ListRows takes the panel's semantics node.
              if (owner) ...[
                const SizedBox(height: 8),
                AdminPanel(
                  children: [GlassRow(icon: FLucideIcons.mail, label: 'Invite by email', onPressed: _invite)],
                ),
              ],
              const Overline('Applications'),
              if (data.$2.isEmpty && !owner)
                const ListNote('No applications yet.')
              else
                AdminPanel(
                  children: [
                    for (final app in data.$2)
                      owner
                          ? GlassRow(
                              icon: app.botUserId == null ? FLucideIcons.appWindow : FLucideIcons.bot,
                              label: app.name,
                              detail: app.botUserId == null ? null : 'Bot',
                              onPressed: () => _openApp(app),
                            )
                          // Members can't change it, but may add a private app's bot: its link to copy.
                          : ListRow(
                              title: app.name,
                              snippet: app.description,
                              detail: app.botUserId == null ? null : 'Double tap to copy its bot’s invite link',
                              onTap: switch (app.botUserId) {
                                final id? => () => copyBotInvite(context, id),
                                null => null,
                              },
                            ),
                    if (owner) GlassRow(icon: FLucideIcons.plus, label: 'New application', onPressed: _newApp),
                  ],
                ),
            ],
          ],
        );
      },
    );
  }
}

/// An application, and its bot: for the team's owner alone.
class ApplicationPage extends StatefulWidget {
  final DevApp app;
  const ApplicationPage({required this.app, super.key});

  @override
  State<ApplicationPage> createState() => _ApplicationPageState();
}

class _ApplicationPageState extends State<ApplicationPage> {
  late DevApp _app = widget.app;
  Future<Member>? _bot;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadBot();
  }

  void _loadBot() {
    _bot = switch (_app.botUserId) {
      final id? => context.repository.botProfile(id),
      null => null,
    };
  }

  /// The app again, as the server has it: its bot made or deleted.
  Future<void> _refresh() async {
    final repository = context.repository;
    try {
      final apps = await repository.applications(_app.teamId);
      if (!mounted) return;
      setState(() {
        _app = apps.firstWhere((a) => a.id == _app.id, orElse: () => _app);
        _loadBot();
      });
    } catch (e) {
      debugPrint('application: $e');
    }
  }

  Future<void> _update({String? name, String? description, bool? public}) async {
    final repository = context.repository;
    try {
      final app = await repository.updateApplication(_app, name: name, description: description, public: public);
      if (mounted) setState(() => _app = app);
    } catch (e) {
      if (mounted) adminToast(context, e is ActionFailed ? e.message : 'Couldn’t change the application');
    }
  }

  Future<void> _rename() async {
    final got = await askName<void>(context, title: 'Rename ${_app.name}', initial: _app.name);
    if (got != null && mounted) await _update(name: got.$1);
  }

  Future<void> _describe() async {
    final got = await askDescription(context, title: 'Description', initial: _app.description ?? '');
    if (got != null && mounted) await _update(description: got);
  }

  Future<void> _delete() async {
    final sure = await confirmDestructive(
      context,
      title: 'Delete ${_app.name}?',
      body: 'Its bot is deleted with it, and removed from every Space.',
      action: 'Delete application',
    );
    if (!sure || !mounted) return;
    final repository = context.repository;
    if (await adminTry(context, 'Couldn’t delete the application', () => repository.deleteApplication(_app)) &&
        mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _showToken(String token) => showSecretOnce(
    context,
    title: 'Bot token',
    body: 'Copy it now: it won’t be shown again. Anyone with it can act as the bot.',
    secret: token,
    copyLabel: 'Copy token',
  );

  Future<void> _createBot() async {
    final repository = context.repository;
    try {
      final token = await repository.createBot(_app);
      if (mounted) await _showToken(token);
    } catch (e) {
      if (mounted) adminToast(context, e is ActionFailed ? e.message : 'Couldn’t create the bot');
    }
    if (mounted) await _refresh();
  }

  Future<void> _resetToken() async {
    final sure = await confirmDestructive(
      context,
      title: 'Reset the token?',
      body: 'The old token stops working at once.',
      action: 'Reset token',
    );
    if (!sure || !mounted) return;
    final repository = context.repository;
    try {
      final token = await repository.resetBotToken(_app);
      if (mounted) await _showToken(token);
    } catch (e) {
      if (mounted) adminToast(context, e is ActionFailed ? e.message : 'Couldn’t reset the token');
    }
  }

  Future<void> _deleteBot() async {
    final sure = await confirmDestructive(
      context,
      title: 'Delete the bot?',
      body: 'It will be removed from every Space it is in.',
      action: 'Delete bot',
    );
    if (!sure || !mounted) return;
    final repository = context.repository;
    await adminTry(context, 'Couldn’t delete the bot', () => repository.deleteBot(_app));
    if (mounted) await _refresh();
  }

  /// Changes the bot, then shows it as it is now.
  Future<void> _updateBot(
    String failure, {
    String? username,
    String? alias,
    bool clearAlias = false,
    String? avatarPath,
    String? bannerPath,
    bool removeAvatar = false,
    bool removeBanner = false,
  }) async {
    final repository = context.repository;
    await adminTry(
      context,
      failure,
      () => repository.updateBot(
        _app,
        username: username,
        alias: alias,
        clearAlias: clearAlias,
        avatarPath: avatarPath,
        bannerPath: bannerPath,
        removeAvatar: removeAvatar,
        removeBanner: removeBanner,
      ),
    );
    if (mounted) setState(_loadBot);
  }

  /// The picture's or the banner's sheet: a new one goes at once, as the
  /// bot's other changes do; or the one there goes.
  Future<void> _editPicture(Member bot, {required bool banner}) async {
    final has = (banner ? bot.bannerUrl : bot.avatarUrl) != null;
    final choice = await showPictureSheet(
      context,
      title: banner ? 'Banner' : 'Picture',
      remove: has ? (banner ? 'Remove banner' : 'Remove picture') : null,
    );
    if (choice == null || !mounted) return;
    if (choice != PictureChoice.remove) return _picture(banner: banner, camera: choice == PictureChoice.take);
    await (banner
        ? _updateBot('Couldn’t remove its banner', removeBanner: true)
        : _updateBot('Couldn’t remove its picture', removeAvatar: true));
  }

  /// A new picture or banner, cropped here: the API stores what it's sent, whole.
  Future<void> _picture({required bool banner, bool camera = false}) async {
    final path = await (camera ? takePhoto() : pickProfilePicture());
    if (path == null || !mounted) return;
    final crop = await Navigator.of(context).push<CropRect>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CropPage(path: path, aspect: banner ? bannerAspect : 1),
      ),
    );
    if (crop == null || !mounted) return;
    final String cropped;
    try {
      cropped = banner ? await saveBannerImage(path, crop) : await saveSquareImage(path, crop, avatarSide);
    } catch (e) {
      debugPrint('bot picture: $e');
      if (mounted) adminToast(context, 'Couldn’t read this picture');
      return;
    }
    if (!mounted) return;
    try {
      await (banner
          ? _updateBot('Couldn’t change its banner', bannerPath: cropped)
          : _updateBot('Couldn’t change its picture', avatarPath: cropped));
    } finally {
      // Best effort: the page needn't wait for it.
      unawaited(File(cropped).delete().then((_) {}, onError: (Object e) => debugPrint('bot picture: $e')));
    }
  }

  Future<void> _username(Member bot) async {
    final got = await askName<void>(context, title: 'Username', label: 'Username', initial: bot.username);
    if (got != null && mounted) await _updateBot('Couldn’t change its username', username: got.$1);
  }

  Future<void> _alias(Member bot) async {
    final got = await askName<void>(
      context,
      title: 'Display name',
      label: 'Display name',
      initial: bot.alias ?? '',
      maxLength: maxDisplayNameLength,
    );
    if (got != null && mounted) await _updateBot('Couldn’t change its display name', alias: got.$1);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return AdminPage(
      title: _app.name,
      children: [
        const Overline('Application'),
        AdminPanel(
          children: [
            GlassRow(icon: FLucideIcons.pencil, label: 'Name', detail: _app.name, onPressed: _rename),
            GlassRow(
              icon: FLucideIcons.fileText,
              label: 'Description',
              detail: _app.description?.isNotEmpty == true ? _app.description : 'None',
              onPressed: _describe,
            ),
            Semantics(
              container: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Public', style: DuvetType.rowTitle.copyWith(color: colors.foreground)),
                          Text(
                            _app.public ? 'Anyone can add its bot' : 'Only the team’s members can add its bot',
                            style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    DuvetSwitch(
                      label: 'Public',
                      value: _app.public,
                      onChanged: (on) => _update(public: on),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const Overline('Commands'),
        AdminPanel(
          children: [
            GlassRow(
              icon: FLucideIcons.squareSlash,
              label: 'Commands',
              detail: 'What people type / to use',
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CommandsPage(app: _app))),
            ),
          ],
        ),
        const Overline('Bot'),
        if (_bot == null)
          AdminPanel(
            children: [GlassRow(icon: FLucideIcons.bot, label: 'Create bot', onPressed: _createBot)],
          )
        else
          FutureBuilder(
            future: _bot,
            builder: (context, snapshot) {
              final bot = snapshot.data;
              if (snapshot.hasError) return const ListNote('Couldn’t load the bot');
              if (bot == null) {
                return LoadingSkeleton(
                  label: 'Loading the bot',
                  children: [
                    AdminPanel(
                      children: [
                        for (final name in placeholderNames)
                          GlassRow(leading: const Bone.circle(size: 48), label: name, onPressed: () {}),
                      ],
                    ),
                  ],
                );
              }
              final rows = [
                GlassRow(
                  icon: FLucideIcons.atSign,
                  label: 'Username',
                  detail: bot.username,
                  onPressed: () => _username(bot),
                ),
                GlassRow(
                  icon: FLucideIcons.pencil,
                  label: 'Display name',
                  detail: bot.alias ?? 'None',
                  onPressed: () => _alias(bot),
                ),
                if (bot.alias != null)
                  GlassRow(
                    icon: FLucideIcons.eraser,
                    label: 'Remove display name',
                    onPressed: () => _updateBot('Couldn’t remove its display name', clearAlias: true),
                  ),
                GlassRow(
                  icon: FLucideIcons.link,
                  label: 'Copy invite link',
                  detail: 'Adds the bot to a Space',
                  onPressed: () => copyBotInvite(context, bot.userId),
                ),
                GlassRow(
                  icon: FLucideIcons.refreshCw,
                  label: 'Reset token',
                  detail: 'The old one stops working',
                  onPressed: _resetToken,
                ),
                GlassRow(icon: FLucideIcons.trash2, label: 'Delete bot', destructive: true, onPressed: _deleteBot),
              ];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AdminPanel(
                    children: [
                      PictureRow(
                        label: 'Picture',
                        set: bot.avatarUrl != null,
                        onPressed: () => _editPicture(bot, banner: false),
                        thumb: ExcludeSemantics(
                          child: UserAvatar(name: bot.displayName, url: bot.avatarUrl, size: 48),
                        ),
                      ),
                      PictureRow(
                        label: 'Banner',
                        set: bot.bannerUrl != null,
                        onPressed: () => _editPicture(bot, banner: true),
                        thumb: PictureThumb(
                          picture: bot.bannerUrl,
                          width: 144,
                          height: 48,
                          radius: BorderRadius.circular(8),
                          empty: Icon(FLucideIcons.image, size: 24, color: colors.mutedForeground),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Text(
                      'Shown wherever the bot is added to a Space.',
                      style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                    ),
                  ),
                  AdminPanel(children: rows),
                ],
              );
            },
          ),
        const SizedBox(height: 16),
        AdminPanel(
          children: [
            GlassRow(icon: FLucideIcons.trash2, label: 'Delete application', destructive: true, onPressed: _delete),
          ],
        ),
      ],
    );
  }
}
