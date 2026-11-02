import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:duvet_client/duvet.dart' show maxBioLength;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:image_picker/image_picker.dart';

import 'data/appearance.dart';
import 'data/links.dart';
import 'data/models.dart';
import 'data/scope.dart';
import 'developer.dart' show DeveloperPage;
import 'login.dart';
import 'people.dart';
import 'space_admin.dart' show avatarSide, saveBannerImage, saveSquareImage;
import 'tabs.dart' show LiveIndicator;
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/ghost_art.dart';
import 'widgets/glass.dart';
import 'widgets/picture_edit.dart';
import 'widgets/rows.dart';
import 'widgets/unsaved_changes.dart';

void _toast(BuildContext context, String text) {
  if (context.mounted) showFToast(context: context, title: Text(text), duration: const Duration(seconds: 3));
}

/// A form screen: a back chevron (or none), the large title and its line,
/// the fields, then its one Primary action at the bottom.
class _FormPage extends StatelessWidget {
  final String title;
  final String? lead;
  final List<Widget> children;
  final Widget? action;
  final List<Widget> after;
  const _FormPage({required this.title, required this.children, this.lead, this.action, this.after = const []});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final padding = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.fromLTRB(24, padding.top + DuvetTokens.sizeTopBar, 24, padding.bottom + 24),
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: DuvetType.largeTitle.copyWith(color: colors.foreground)),
                ),
                if (lead != null) ...[
                  const SizedBox(height: 8),
                  Text(lead!, style: DuvetType.snippet.copyWith(color: colors.mutedForeground)),
                ],
                const SizedBox(height: 32),
                ...children,
                if (action != null) ...[const SizedBox(height: 32), action!],
                ...after,
              ],
            ),
          ),
          Positioned(
            top: padding.top + 6,
            left: 8,
            child: IconAction(
              icon: FLucideIcons.chevronLeft,
              label: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }
}

String? _error(Object e) => e.toString().contains('409')
    ? 'That username or email is taken'
    : e.toString().contains('400')
    ? 'Check what you typed'
    : 'Couldn’t reach Duvet. Check your connection.';

// -----------------------------------------------------------------------------
// Sign up
// -----------------------------------------------------------------------------

/// How strong a password is, 0 to 4, and what would make it stronger.
({int score, String hint}) passwordStrength(String p) {
  if (p.isEmpty) return (score: 0, hint: 'At least 8 characters');
  var score = 0;
  if (p.length >= 8) score++;
  if (p.length >= 12) score++;
  if (RegExp(r'[a-z]').hasMatch(p) && RegExp(r'[A-Z]').hasMatch(p) || RegExp(r'\d').hasMatch(p)) score++;
  if (RegExp(r'[^A-Za-z0-9]').hasMatch(p)) score++;
  score = math.min(score, 4);
  final hint = switch (score) {
    _ when p.length < 8 => 'Too short: at least 8 characters',
    4 => 'Strong',
    3 => 'Good. Make it longer to make it strong.',
    _ => 'Fair. Add a number or a symbol.',
  };
  return (score: score, hint: hint);
}

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _show = false;
  bool _busy = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    for (final c in [_username, _email, _password]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  String get _name => _username.text.trim().replaceFirst('@', '');
  bool get _validName => RegExp(r'^[a-zA-Z0-9_.]{2,32}$').hasMatch(_name);
  bool get _validEmail => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim());

  Future<void> _create() async {
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await context.repository.signUp(username: _name, email: _email.text.trim(), password: _password.text);
      // Signed in: the app shows; the verify screen goes over it.
      navigator.popUntil((r) => r.isFirst);
      unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => VerifyEmailPage(email: _email.text.trim()))));
    } catch (e) {
      if (mounted) setState(() => _failure = _error(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final strength = passwordStrength(_password.text);
    final ready = _validName && _validEmail && _password.text.length >= 8;
    return _FormPage(
      title: 'Create your account',
      lead: 'One account for every Space you join.',
      action: DuvetButton(
        label: 'Create account',
        variant: ButtonVariant.primary,
        expand: true,
        busy: _busy,
        onPressed: ready ? _create : null,
      ),
      after: [
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Already have an account?', style: DuvetType.snippet.copyWith(color: colors.mutedForeground)),
            TextAction(
              label: 'Sign in',
              onPressed: () =>
                  Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => const LoginScreen())),
            ),
          ],
        ),
      ],
      children: [
        DuvetTextField(
          label: 'Username',
          controller: _username,
          autofocus: true,
          autofillHints: const [AutofillHints.newUsername],
          textInputAction: TextInputAction.next,
          error: _username.text.isNotEmpty && !_validName ? 'Letters, numbers, dots and _, 2 to 32' : null,
        ),
        const SizedBox(height: 16),
        DuvetTextField(
          label: 'Email',
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.next,
          error: _email.text.isNotEmpty && !_validEmail ? 'That doesn’t look like an email' : null,
        ),
        const SizedBox(height: 16),
        DuvetTextField(
          label: 'Password',
          controller: _password,
          obscure: !_show,
          autofillHints: const [AutofillHints.newPassword],
          trailing: IconAction(
            icon: _show ? FLucideIcons.eyeOff : FLucideIcons.eye,
            label: _show ? 'Hide password' : 'Show password',
            color: colors.mutedForeground,
            onPressed: () => setState(() => _show = !_show),
          ),
        ),
        const SizedBox(height: 8),
        // Strength in four segments, `ink` filled: never red or green.
        Semantics(
          label: 'Password strength: ${strength.score} of 4',
          excludeSemantics: true,
          child: Row(
            children: [
              for (var i = 0; i < 4; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: i < strength.score ? colors.foreground : colors.secondary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(strength.hint, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
        if (_failure != null) ...[
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(_failure!, style: DuvetType.caption.copyWith(color: colors.destructive)),
          ),
        ],
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// Verify email
// -----------------------------------------------------------------------------

/// Verifies with a link's token: from a tapped link, or pasted.
Future<void> verifyFromLink(BuildContext context, String token) async {
  try {
    await context.repository.verifyEmail(token);
    if (context.mounted) _toast(context, 'Your email is verified');
  } catch (_) {
    if (context.mounted) _toast(context, 'That link has expired. Ask for a new one.');
  }
}

/// Check your email: the link goes to [email]; resend it after a minute, or
/// paste the link here.
class VerifyEmailPage extends StatefulWidget {
  final String? email;
  const VerifyEmailPage({this.email, super.key});

  @override
  State<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends State<VerifyEmailPage> {
  static const _wait = 60;
  final _link = TextEditingController();
  Timer? _timer;
  int _left = _wait;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _tick();
  }

  void _tick() {
    _timer?.cancel();
    _left = _wait;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _left--);
      if (_left <= 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _link.dispose();
    super.dispose();
  }

  Future<void> _resend() async {
    try {
      await context.repository.sendVerificationEmail();
      setState(_tick);
      if (mounted) _toast(context, 'Sent again');
    } catch (_) {
      if (mounted) _toast(context, 'Couldn’t send it');
    }
  }

  Future<void> _verify() async {
    final token = switch (parseDeepLink(_link.text.trim())) {
      OpenVerify(:final token) => token,
      _ => _link.text.trim().contains('/') ? null : _link.text.trim(),
    };
    if (token == null || token.isEmpty) {
      setState(() => _failure = 'That isn’t a verification link');
      return;
    }
    final navigator = Navigator.of(context);
    try {
      await context.repository.verifyEmail(token);
      navigator.pop();
    } catch (_) {
      if (mounted) setState(() => _failure = 'That link has expired. Ask for a new one.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return ValueListenableBuilder(
      valueListenable: context.repository.profile,
      builder: (context, profile, _) {
        if (profile?.emailVerified == true) {
          return _FormPage(
            title: 'Email verified',
            lead: 'You’re all set.',
            action: DuvetButton(
              label: 'Done',
              variant: ButtonVariant.primary,
              expand: true,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            children: const [],
          );
        }
        return _FormPage(
          title: 'Check your email',
          lead: widget.email == null
              ? 'We sent you a link. Tap it on this phone to verify your address.'
              : 'We sent a link to ${widget.email}. Tap it on this phone to verify your address.',
          action: DuvetButton(
            label: _left > 0 ? 'Resend link in 0:${_left.toString().padLeft(2, '0')}' : 'Resend link',
            expand: true,
            onPressed: _left > 0 ? null : _resend,
          ),
          after: [
            const SizedBox(height: 8),
            Center(
              child: TextAction(label: 'Later', onPressed: () => Navigator.of(context).maybePop()),
            ),
          ],
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: colors.card,
                borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
                boxShadow: tokens.shadowRaised,
              ),
              child: Icon(FLucideIcons.mail, size: 28, color: colors.foreground),
            ),
            const SizedBox(height: 24),
            DuvetTextField(
              label: 'Or paste the link',
              controller: _link,
              keyboardType: TextInputType.url,
              error: _failure,
              onSubmitted: (_) => _verify(),
              trailing: TextAction(label: 'Verify', onPressed: _verify),
            ),
          ],
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Passwords and email
// -----------------------------------------------------------------------------

/// Reset your password: an email gets a link.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _email = TextEditingController();
  bool _busy = false;
  String? _sent;
  String? _failure;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _email.text.trim();
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await context.repository.forgotPassword(email);
      if (mounted) setState(() => _sent = email);
    } catch (_) {
      if (mounted) setState(() => _failure = 'Couldn’t send a link to that email');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return _FormPage(
      title: 'Reset your password',
      lead: 'Enter your email and we’ll send you a link. It works for 30 minutes.',
      action: _sent != null
          ? null
          : DuvetButton(
              label: 'Send reset link',
              variant: ButtonVariant.primary,
              expand: true,
              busy: _busy,
              onPressed: _send,
            ),
      children: [
        DuvetTextField(
          label: 'Email',
          controller: _email,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          error: _failure,
          onSubmitted: (_) => _send(),
        ),
        if (_sent case final email?) ...[
          const SizedBox(height: 32),
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.card,
                borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
                boxShadow: tokens.shadowRest,
              ),
              child: Row(
                children: [
                  Icon(FLucideIcons.mailCheck, color: colors.foreground),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Link sent', style: DuvetType.rowTitle.copyWith(color: colors.foreground)),
                        Text(
                          'Check $email. You can close this screen.',
                          style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A new password, from the emailed link.
class ResetPasswordPage extends StatefulWidget {
  final String token;
  const ResetPasswordPage({required this.token, super.key});

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _password.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await context.repository.resetPassword(widget.token, _password.text);
      if (mounted) _toast(context, 'Password changed. Sign in with it.');
      navigator.pop();
    } catch (_) {
      if (mounted) setState(() => _failure = 'That link has expired. Ask for a new one.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strength = passwordStrength(_password.text);
    return _FormPage(
      title: 'Choose a new password',
      action: DuvetButton(
        label: 'Save password',
        variant: ButtonVariant.primary,
        expand: true,
        busy: _busy,
        onPressed: _password.text.length >= 8 ? _save : null,
      ),
      children: [
        DuvetTextField(
          label: 'New password',
          controller: _password,
          obscure: true,
          autofocus: true,
          autofillHints: const [AutofillHints.newPassword],
          helper: strength.hint,
          error: _failure,
        ),
      ],
    );
  }
}

/// Moves the account to the address in the emailed link.
Future<void> changeEmailFromLink(BuildContext context, String token, String email) async {
  try {
    await context.repository.changeEmail(token, email);
    if (context.mounted) _toast(context, 'Your email is now $email');
  } catch (_) {
    if (context.mounted) _toast(context, 'That link has expired. Ask for a new one.');
  }
}

class ChangeEmailPage extends StatefulWidget {
  const ChangeEmailPage({super.key});

  @override
  State<ChangeEmailPage> createState() => _ChangeEmailPageState();
}

class _ChangeEmailPageState extends State<ChangeEmailPage> {
  final _email = TextEditingController();
  bool _busy = false;
  String? _sent;
  String? _failure;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      await context.repository.sendChangeEmail(_email.text.trim());
      if (mounted) setState(() => _sent = _email.text.trim());
    } catch (_) {
      if (mounted) setState(() => _failure = 'Couldn’t send a link to that email');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _FormPage(
    title: 'Change email',
    lead: _sent == null
        ? 'We’ll send a link to the new address. The change happens when you tap it.'
        : 'Check $_sent and tap the link on this phone.',
    action: _sent != null
        ? null
        : DuvetButton(label: 'Send link', variant: ButtonVariant.primary, expand: true, busy: _busy, onPressed: _send),
    children: [
      if (_sent == null)
        DuvetTextField(
          label: 'New email',
          controller: _email,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          error: _failure,
        ),
    ],
  );
}

// -----------------------------------------------------------------------------
// Edit profile
// -----------------------------------------------------------------------------

/// Picks a picture for the profile as it is: recompressed, Android's picker
/// would make a GIF a still image. Tests swap in their own.
Future<String?> Function() pickProfilePicture = () async =>
    (await ImagePicker().pickImage(source: ImageSource.gallery))?.path;

class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

/// The longest display name the API takes, in characters.
const maxDisplayNameLength = 32;

class _EditProfilePageState extends State<EditProfilePage> {
  late final TextEditingController _alias;
  late final TextEditingController _bio;
  bool _fieldsMade = false;
  bool _saving = false;

  // The pictures picked and cropped, in files: they go up on Save, and
  // Cancel drops them. Or [_removeAvatar] and [_removeBanner] to take the
  // ones there away.
  String? _avatar;
  String? _banner;
  bool _removeAvatar = false, _removeBanner = false;
  final _upload = ValueNotifier<double?>(null);

  /// The bio's length as the API counts it: code points, so an emoji is one.
  int get _bioLength => _bio.text.trim().runes.length;
  bool get _bioTooLong => _bioLength > maxBioLength;

  /// The display name's, counted the same way.
  int get _aliasLength => _alias.text.trim().runes.length;
  bool get _aliasTooLong => _aliasLength > maxDisplayNameLength;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Once: this runs again whenever the padding the page reads changes, as
    // when the keyboard opens.
    if (_fieldsMade) return;
    _fieldsMade = true;
    final profile = context.repository.profile.value;
    _alias = TextEditingController(text: profile?.alias ?? '')..addListener(() => setState(() {}));
    _bio = TextEditingController(text: profile?.bio ?? '')..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _alias.dispose();
    _bio.dispose();
    _upload.dispose();
    super.dispose();
  }

  // Left mid-upload, the page is gone, and its note with it.
  void _progress(double p) {
    if (mounted) _upload.value = p;
  }

  /// The photo's or the banner's sheet: a new one, or none.
  Future<void> _edit(ProfileImage kind, {required bool has}) async {
    final avatar = kind == ProfileImage.avatar;
    final choice = await showPictureSheet(
      context,
      title: avatar ? 'Profile photo' : 'Banner',
      remove: has ? (avatar ? 'Remove profile photo' : 'Remove banner') : null,
    );
    if (choice == null || !mounted) return;
    if (choice != PictureChoice.remove) return _change(kind, camera: choice == PictureChoice.take);
    final profile = context.repository.profile.value;
    setState(() {
      if (avatar) {
        _avatar = null;
        _removeAvatar = profile?.avatarUrl != null;
      } else {
        _banner = null;
        _removeBanner = profile?.bannerUrl != null;
      }
    });
  }

  Future<void> _change(ProfileImage kind, {bool camera = false}) async {
    final path = await (camera ? takePhoto() : pickProfilePicture());
    if (path == null || !mounted) return;
    final crop = await Navigator.of(context).push<CropRect>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CropPage(path: path, aspect: kind == ProfileImage.avatar ? 1 : bannerAspect),
      ),
    );
    if (crop == null || !mounted) return;
    // Cropped here: the API stores what it's sent, whole.
    final String cropped;
    try {
      cropped = kind == ProfileImage.avatar
          ? await saveSquareImage(path, crop, avatarSide)
          : await saveBannerImage(path, crop);
    } catch (e) {
      debugPrint('profile picture: $e');
      if (mounted) _toast(context, 'Couldn’t read this picture');
      return;
    }
    if (!mounted) return;
    setState(() {
      if (kind == ProfileImage.avatar) {
        _avatar = cropped;
        _removeAvatar = false;
      } else {
        _banner = cropped;
        _removeBanner = false;
      }
    });
  }

  Future<void> _save() async {
    final navigator = Navigator.of(context);
    final repository = context.repository;
    // The bio goes only when it changed: left out, it stays.
    final bio = _bio.text.trim();
    final changed = bio != (repository.profile.value?.bio ?? '').trim();
    setState(() => _saving = true);
    var failure = 'Couldn’t save your profile';
    try {
      // The pictures first, removals then uploads. Each one done is done
      // with, should what follows fail and Save be pressed again.
      if (_removeAvatar) {
        failure = 'Couldn’t remove the photo';
        await repository.removeProfileImage(ProfileImage.avatar);
        _removeAvatar = false;
      }
      if (_removeBanner) {
        failure = 'Couldn’t remove the banner';
        await repository.removeProfileImage(ProfileImage.banner);
        _removeBanner = false;
      }
      if (_avatar case final path?) {
        failure = 'Couldn’t change the photo';
        await repository.uploadProfileImage(ProfileImage.avatar, path, onProgress: _progress);
        _avatar = null;
      }
      if (_banner case final path?) {
        failure = 'Couldn’t change the banner';
        await repository.uploadProfileImage(ProfileImage.banner, path, onProgress: _progress);
        _banner = null;
      }
      failure = 'Couldn’t save your profile';
      await repository.updateProfile(alias: _alias.text, bio: changed ? bio : null);
      // Cancelled meanwhile: the page is gone, and the route under it stays.
      if (mounted) navigator.pop();
    } catch (e) {
      if (mounted) _toast(context, e is ActionFailed ? e.message : failure);
    } finally {
      if (mounted) {
        _upload.value = null;
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.repository.profile.value;
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final padding = MediaQuery.paddingOf(context);
    if (profile == null) return const SizedBox.shrink();
    // The design's 120: a 5:2 banner shows by its middle.
    const bannerHeight = 120.0;
    // What the pictures will be once saved: the new ones, none, or as they are.
    final avatarNow = _removeAvatar ? null : profile.avatarUrl;
    final bannerNow = _removeBanner ? null : profile.bannerUrl;
    final banner = _banner ?? bannerNow;
    final hasAvatar = _avatar != null || avatarNow != null;
    final alias = _alias.text.trim();
    final dirty =
        _avatar != null ||
        _banner != null ||
        _removeAvatar ||
        _removeBanner ||
        alias != (profile.alias ?? '').trim() ||
        _bio.text.trim() != (profile.bio ?? '').trim();
    return UnsavedChanges(
      dirty: dirty,
      child: Scaffold(
        backgroundColor: colors.background,
        body: Stack(
          children: [
            Positioned.fill(
              child: ListView(
                padding: EdgeInsets.fromLTRB(16, GlassTopBar.heightOf(context) + 8, 16, padding.bottom + 24),
                children: [
                  // The profile as it will show: banner, photo and names.
                  Container(
                    height: bannerHeight + 64,
                    decoration: BoxDecoration(
                      color: colors.card,
                      borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
                      boxShadow: tokens.shadowRest,
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: bannerHeight,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.secondary,
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(DuvetTokens.radiusCard)),
                              image: switch (banner) {
                                final b? => DecorationImage(
                                  image: b.startsWith('http') ? NetworkImage(b) : FileImage(File(b)) as ImageProvider,
                                  fit: BoxFit.cover,
                                ),
                                null => null,
                              },
                            ),
                          ),
                        ),
                        Positioned(
                          right: 12,
                          top: bannerHeight - 12 - 44,
                          child: Semantics(
                            container: true,
                            button: true,
                            label: 'Change banner',
                            excludeSemantics: true,
                            onTap: () => _edit(ProfileImage.banner, has: banner != null),
                            child: GestureDetector(
                              onTap: () => _edit(ProfileImage.banner, has: banner != null),
                              child: GlassSurface(
                                borderRadius: BorderRadius.circular(DuvetTokens.radiusButton),
                                child: SizedBox(
                                  height: 44,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(12, 0, 16, 0),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(FLucideIcons.image, size: 24, color: colors.foreground),
                                        const SizedBox(width: 8),
                                        Text('Banner', style: DuvetType.label.copyWith(color: colors.foreground)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 16,
                          top: bannerHeight - 48,
                          child: Semantics(
                            container: true,
                            button: true,
                            label: 'Change profile photo',
                            excludeSemantics: true,
                            onTap: () => _edit(ProfileImage.avatar, has: hasAvatar),
                            child: GestureDetector(
                              onTap: () => _edit(ProfileImage.avatar, has: hasAvatar),
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(color: colors.card, width: 4),
                                    ),
                                    child: _avatar != null
                                        ? ClipOval(
                                            child: Image.file(File(_avatar!), width: 88, height: 88, fit: BoxFit.cover),
                                          )
                                        : UserAvatar(name: profile.displayName, url: avatarNow, size: 88),
                                  ),
                                  Positioned(
                                    right: -8,
                                    bottom: -8,
                                    child: Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: colors.card,
                                        borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                                        boxShadow: tokens.shadowControl,
                                      ),
                                      child: Icon(FLucideIcons.camera, size: 24, color: colors.foreground),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 128,
                          right: 16,
                          top: bannerHeight + 8,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                alias.isEmpty ? profile.username : alias,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: DuvetType.label.copyWith(color: colors.foreground),
                              ),
                              Text(
                                '@${profile.username}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      'Your photo and banner show on your profile.',
                      style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                    ),
                  ),
                  UploadNote(_upload),
                  const SizedBox(height: 24),
                  // At most 32 characters, as the API takes; empty, the username shows.
                  DuvetTextField(
                    label: 'Display name',
                    controller: _alias,
                    hint: profile.username,
                    error: _aliasTooLong ? 'Too long: $_aliasLength of $maxDisplayNameLength characters' : null,
                  ),
                  const SizedBox(height: 16),
                  // As the desktop's About Me: up to 190 characters, an emoji
                  // counting as one; empty clears it.
                  DuvetTextField(
                    label: 'About me',
                    controller: _bio,
                    hint: 'A few words about you',
                    maxLines: 4,
                    helper: '$_bioLength of $maxBioLength characters',
                    error: _bioTooLong ? 'Too long: $_bioLength of $maxBioLength characters' : null,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Username',
                    style: DuvetType.caption.copyWith(color: colors.foreground, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 48,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(
                      color: colors.secondary,
                      borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                    ),
                    child: Text('@${profile.username}', style: DuvetType.body.copyWith(color: colors.mutedForeground)),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                title: const Text('Edit profile'),
                leading: TextAction(label: 'Cancel', onPressed: () => Navigator.of(context).maybePop()),
                actions: [
                  TextAction(
                    label: 'Save',
                    onPressed: _saving || !dirty || _bioTooLong || _aliasTooLong ? null : _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cropping, before an upload: pan and pinch the picture inside the frame;
/// the caller makes the frame's part into the picture that goes up.
class CropPage extends StatefulWidget {
  final String path;

  /// Width over height: 1 for an avatar, [bannerAspect] for a banner.
  final double aspect;

  /// A square frame drawn round, as an avatar shows; an emoji's isn't.
  final bool round;

  /// Said under the frame while the picture is cropped.
  final String? note;
  const CropPage({required this.path, required this.aspect, this.round = true, this.note, super.key});

  @override
  State<CropPage> createState() => _CropPageState();
}

class _CropPageState extends State<CropPage> {
  final _transform = TransformationController();
  Size? _image;
  bool _centered = false;

  @override
  void initState() {
    super.initState();
    File(widget.path)
        .readAsBytes()
        .then(ui.instantiateImageCodec)
        .then((codec) => codec.getNextFrame())
        .then(
          (frame) {
            if (mounted) setState(() => _image = Size(frame.image.width.toDouble(), frame.image.height.toDouble()));
          },
          onError: (Object e) {
            if (mounted) Navigator.of(context).pop();
          },
        );
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// The frame, in the picture's pixels.
  CropRect _crop(Size frame, double scale) {
    final inverse = Matrix4.inverted(_transform.value);
    final topLeft = MatrixUtils.transformPoint(inverse, Offset.zero) / scale;
    final bottomRight = MatrixUtils.transformPoint(inverse, Offset(frame.width, frame.height)) / scale;
    final image = _image!;
    final x = topLeft.dx.clamp(0.0, image.width);
    final y = topLeft.dy.clamp(0.0, image.height);
    return (
      x: x,
      y: y,
      w: (bottomRight.dx.clamp(0.0, image.width) - x),
      h: (bottomRight.dy.clamp(0.0, image.height) - y),
    );
  }

  @override
  Widget build(BuildContext context) {
    const ink = DuvetTokens.mediaInk;
    final padding = MediaQuery.paddingOf(context);
    final image = _image;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0B),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth - 32;
          final frame = Size(width, width / widget.aspect);
          // The picture covers the frame at scale 1.
          final scale = image == null ? 1.0 : math.max(frame.width / image.width, frame.height / image.height);
          if (image != null && !_centered) {
            // From its middle, as the desktop's editor starts: set before the
            // viewer that reads it is first built.
            _centered = true;
            _transform.value = Matrix4.translationValues(
              -(image.width * scale - frame.width) / 2,
              -(image.height * scale - frame.height) / 2,
              0,
            );
          }
          return Stack(
            children: [
              Center(
                child: SizedBox.fromSize(
                  size: frame,
                  child: image == null
                      ? const Center(child: CircularProgressIndicator(color: ink))
                      : Semantics(
                          image: true,
                          label: 'Picture to crop. Pinch to zoom, drag to move',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              widget.aspect == 1 && widget.round ? frame.width / 2 : DuvetTokens.radiusCard,
                            ),
                            child: InteractiveViewer(
                              transformationController: _transform,
                              constrained: false,
                              minScale: 1,
                              maxScale: 6,
                              child: Image.file(
                                File(widget.path),
                                width: image.width * scale,
                                height: image.height * scale,
                                fit: BoxFit.fill,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                top: padding.top + 6,
                child: Row(
                  children: [
                    TextAction(label: 'Cancel', color: ink, onPressed: () => Navigator.of(context).pop()),
                    const Spacer(),
                    TextAction(
                      label: 'Use',
                      color: ink,
                      onPressed: image == null ? null : () => Navigator.of(context).pop(_crop(frame, scale)),
                    ),
                  ],
                ),
              ),
              if (widget.note case final note?)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: padding.bottom + 32,
                  child: Text(
                    note,
                    textAlign: TextAlign.center,
                    style: DuvetType.snippet.copyWith(color: ink),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// My files
// -----------------------------------------------------------------------------

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

enum _FileFilter { all, largest, images, voice }

/// My files: the storage used, by kind, and every file, to delete.
class MyFilesPage extends StatefulWidget {
  const MyFilesPage({super.key});

  @override
  State<MyFilesPage> createState() => _MyFilesPageState();
}

class _MyFilesPageState extends State<MyFilesPage> {
  List<MyFile>? _files;
  StorageInfo? _storage;
  _FileFilter _filter = _FileFilter.all;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_files == null) _load();
  }

  Future<void> _load() async {
    final repository = context.repository;
    try {
      final (files, storage) = await (repository.myFiles(), repository.storage()).wait;
      if (mounted) {
        setState(() {
          _files = files;
          _storage = storage;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _files = const []);
    }
  }

  Future<void> _delete(MyFile f) async {
    final sure = await showGlassDialogSheet<bool>(
      context,
      label: 'Delete ${f.name}?',
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Delete ${f.name}?', style: DuvetType.titleSans.copyWith(color: context.theme.colors.foreground)),
            const SizedBox(height: 12),
            Text(
              'It goes from every message it’s in. This can’t be undone.',
              style: DuvetType.snippet.copyWith(color: context.theme.colors.mutedForeground),
            ),
            const SizedBox(height: 24),
            DuvetButton(
              label: 'Delete file',
              variant: ButtonVariant.destructive,
              expand: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 12),
            DuvetButton(label: 'Cancel', expand: true, onPressed: () => Navigator.of(context).pop(false)),
          ],
        ),
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await context.repository.deleteMyFile(f.id);
      await _load();
    } catch (_) {
      if (mounted) _toast(context, 'Couldn’t delete the file');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final padding = MediaQuery.paddingOf(context);
    final files = _files;
    final storage = _storage;
    int sum(bool Function(MyFile f) test) => (files ?? const <MyFile>[]).where(test).fold(0, (a, f) => a + f.sizeBytes);
    final images = sum((f) => f.isImage);
    final voice = sum((f) => f.isAudio);
    final other = sum((f) => !f.isImage && !f.isAudio);
    final shown = switch (_filter) {
      _FileFilter.all => [...?files]..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
      _FileFilter.largest => [...?files]..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes)),
      _FileFilter.images => [...?files?.where((f) => f.isImage)],
      _FileFilter.voice => [...?files?.where((f) => f.isAudio)],
    };
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              padding: EdgeInsets.only(top: GlassTopBar.heightOf(context) + 8, bottom: padding.bottom + 24),
              children: [
                if (storage != null) ...[
                  // As the desktop: the active bucket first, which keeps the uploads, then the default
                  // storage and every bucket. The files list doesn't say where each file is, so with buckets
                  // the default storage's meter shows what it holds, not its kinds.
                  if (storage.activeBucket case final active?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: BucketMeter(bucket: active, big: true),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: storage.buckets.isEmpty
                        ? StorageMeter(storage: storage, images: images, files: other, voice: voice, big: true)
                        : StorageMeter(
                            storage: storage,
                            images: 0,
                            files: storage.used,
                            voice: 0,
                            big: storage.activeBucket == null,
                            title: 'Default storage',
                          ),
                  ),
                  if (storage.buckets.isNotEmpty) ...[
                    const Overline('Your buckets'),
                    for (final b in storage.buckets)
                      ListRow(
                        title: b.name,
                        snippet: [
                          b.max == null
                              ? '${formatBytes(b.used)} used'
                              : '${formatBytes(b.used)} of ${formatBytes(b.max!)}',
                          b.active ? 'Active' : 'Off',
                        ].join(' · '),
                      ),
                  ],
                ],
                // Edge to edge: the filters scroll to the screen's edge, 16 in at rest.
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        for (final (f, label) in const [
                          (_FileFilter.all, 'All'),
                          (_FileFilter.largest, 'Largest'),
                          (_FileFilter.images, 'Images'),
                          (_FileFilter.voice, 'Voice'),
                        ]) ...[
                          if (f != _FileFilter.all) const SizedBox(width: 24),
                          Semantics(
                            button: true,
                            selected: _filter == f,
                            label: label,
                            excludeSemantics: true,
                            onTap: () => setState(() => _filter = f),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => setState(() => _filter = f),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                child: Text(
                                  label,
                                  style: DuvetType.label.copyWith(
                                    color: _filter == f ? tokens.accentText : colors.mutedForeground,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (files == null)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: FCircularProgress()),
                  )
                else if (shown.isEmpty)
                  const ListNote('No files')
                else
                  for (final f in shown)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                            child: Container(
                              width: 48,
                              height: 48,
                              color: colors.secondary,
                              child: f.isImage
                                  ? Image.network(
                                      f.url,
                                      fit: BoxFit.cover,
                                      cacheWidth: (48 * MediaQuery.devicePixelRatioOf(context)).round(),
                                      errorBuilder: (_, _, _) => Icon(FLucideIcons.image, color: colors.foreground),
                                    )
                                  : Icon(
                                      f.isAudio ? FLucideIcons.mic : FLucideIcons.fileText,
                                      color: colors.foreground,
                                    ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  f.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: DuvetType.rowTitle.copyWith(fontSize: 15, color: colors.foreground),
                                ),
                                Text(
                                  '${formatBytes(f.sizeBytes)} · ${shortTime(f.createdAt)}',
                                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                                ),
                              ],
                            ),
                          ),
                          IconAction(
                            icon: FLucideIcons.trash2,
                            label: 'Delete ${f.name}',
                            color: colors.mutedForeground,
                            onPressed: () => _delete(f),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(title: const Text('My files'), onBack: () => Navigator.of(context).maybePop()),
          ),
        ],
      ),
    );
  }
}

/// Storage used: a meter in three shades of `ink`, never hues to tell apart.
class StorageMeter extends StatelessWidget {
  final StorageInfo storage;
  final int images;
  final int files;
  final int voice;
  final bool big;

  /// Above it: which storage it is, when there are others.
  final String? title;
  const StorageMeter({
    required this.storage,
    required this.images,
    required this.files,
    required this.voice,
    this.big = false,
    this.title,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final max = storage.max <= 0 ? 1 : storage.max;
    final parts = [
      (images, colors.foreground, 'Images'),
      (files, colors.mutedForeground, 'Files'),
      (voice, tokens.grabber, 'Voice'),
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
        boxShadow: big ? tokens.shadowRaised : tokens.shadowRest,
      ),
      child: Semantics(
        container: true,
        label:
            '${title == null ? '' : '$title: '}${formatBytes(storage.used)} of ${formatBytes(storage.max)} used: '
            'images ${formatBytes(images)}, files ${formatBytes(files)}, voice ${formatBytes(voice)}',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title case final title?) ...[
              Text(title, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
              const SizedBox(height: 4),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  formatBytes(storage.used),
                  style: (big ? DuvetType.titleSans : DuvetType.rowTitle).copyWith(color: colors.foreground),
                ),
                const SizedBox(width: 8),
                Text(
                  'of ${formatBytes(storage.max)} used',
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              height: 8,
              decoration: BoxDecoration(
                color: colors.secondary,
                borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
              ),
              clipBehavior: Clip.antiAlias,
              child: Row(
                children: [
                  for (final (bytes, color, _) in parts)
                    Flexible(
                      flex: math.max(0, (bytes / max * 1000).round()),
                      child: Container(color: color),
                    ),
                  Flexible(
                    flex: math.max(1, ((max - images - files - voice) / max * 1000).round()),
                    child: const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              children: [
                for (final (bytes, color, label) in parts)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '$label ${formatBytes(bytes)}',
                        style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A bucket of the user's own: what it holds, against its own limit when it
/// has one, else no quota, as the desktop shows the active one.
class BucketMeter extends StatelessWidget {
  final BucketUsage bucket;
  final bool big;
  const BucketMeter({required this.bucket, this.big = false, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final max = bucket.max;
    final of = max == null ? 'used · no quota' : 'of ${formatBytes(max)} used';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
        boxShadow: big ? tokens.shadowRaised : tokens.shadowRest,
      ),
      child: Semantics(
        container: true,
        label: 'Your own storage, ${bucket.name}: ${formatBytes(bucket.used)} $of',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your own storage · ${bucket.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DuvetType.caption.copyWith(color: colors.mutedForeground),
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  formatBytes(bucket.used),
                  style: (big ? DuvetType.titleSans : DuvetType.rowTitle).copyWith(color: colors.foreground),
                ),
                const SizedBox(width: 8),
                // "used · no quota" is longer than a quota's line: it wraps when the space runs out.
                Flexible(
                  child: Text(of, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
                ),
              ],
            ),
            if (max != null && max > 0) ...[
              const SizedBox(height: 10),
              Container(
                height: 8,
                decoration: BoxDecoration(
                  color: colors.secondary,
                  borderRadius: BorderRadius.circular(DuvetTokens.radiusChip),
                ),
                clipBehavior: Clip.antiAlias,
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: (bucket.used / max).clamp(0.0, 1.0),
                  child: Container(color: colors.foreground),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// You
// -----------------------------------------------------------------------------

/// You: the profile card (Edit), friends, appearance, storage, account.
class YouTab extends StatefulWidget {
  const YouTab({super.key});

  @override
  State<YouTab> createState() => _YouTabState();
}

class _YouTabState extends State<YouTab> {
  StorageInfo? _storage;

  // The status chosen while the server takes it: shown meanwhile.
  Presence? _choosing;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.repository.storage().then((s) {
      if (mounted) setState(() => _storage = s);
    }, onError: (Object e) => debugPrint('storage: $e'));
  }

  void _push(Widget page) =>
      Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => page));

  /// Online or do not disturb; one change at a time.
  Future<void> _setStatus(Presence status) async {
    final repository = context.repository;
    if (_choosing != null || status == repository.profile.value?.status) return;
    setState(() => _choosing = status);
    try {
      await repository.setStatus(status);
    } catch (e) {
      if (mounted) _toast(context, e is ActionFailed ? e.message : 'Couldn’t change your status');
    } finally {
      if (mounted) setState(() => _choosing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = context.repository;
    final appearance = AppearanceScope.of(context);
    final colors = context.theme.colors;
    final tokens = context.duvet;
    return ListenableBuilder(
      listenable: Listenable.merge([repository.profile, repository.friends, repository.teamInvites]),
      builder: (context, _) {
        final profile = repository.profile.value;
        if (profile == null) return const SizedBox.shrink();
        Widget panel(List<Widget> rows) => Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
            boxShadow: tokens.shadowRest,
          ),
          child: Column(children: rows),
        );
        Widget row(String label, VoidCallback onTap, {String? value, bool warn = false}) =>
            GlassRow(label: label, detail: value, destructive: warn, onPressed: onTap);
        return LargeTitlePage(
          title: 'You',
          titleLeading: const AppIcon(size: 32),
          titleTrailing: const LiveIndicator(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              sliver: SliverList.list(
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colors.card,
                      borderRadius: BorderRadius.circular(DuvetTokens.radiusCard),
                      boxShadow: tokens.shadowRaised,
                    ),
                    child: Row(
                      children: [
                        ExcludeSemantics(
                          child: UserAvatar(name: profile.displayName, url: profile.avatarUrl, size: 56),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                profile.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: DuvetType.rowTitleUnread.copyWith(fontSize: 17, color: colors.foreground),
                              ),
                              Text(
                                '@${profile.username}',
                                style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                              ),
                            ],
                          ),
                        ),
                        DuvetButton(label: 'Edit', onPressed: () => _push(const EditProfilePage())),
                      ],
                    ),
                  ),
                  if (!profile.emailVerified) ...[
                    const SizedBox(height: 16),
                    panel([row('Verify your email', () => _push(const VerifyEmailPage()), value: 'Not verified yet')]),
                  ],
                  const SizedBox(height: 16),
                  panel([
                    row(
                      'Friends',
                      () => _push(const FriendsPage()),
                      value: repository.friends.value.incoming.isEmpty
                          ? null
                          : '${repository.friends.value.incoming.length} waiting',
                    ),
                  ]),
                  // What others see while you're connected.
                  const Overline('Status'),
                  Segmented<Presence>(
                    label: 'Status',
                    value: _choosing ?? profile.status,
                    options: const {Presence.online: 'Online', Presence.doNotDisturb: 'Do not disturb'},
                    onChanged: _setStatus,
                  ),
                  const Overline('Appearance'),
                  Segmented<ThemeMode>(
                    label: 'Appearance',
                    value: appearance.value,
                    options: const {ThemeMode.system: 'System', ThemeMode.light: 'Light', ThemeMode.dark: 'Dark'},
                    onChanged: appearance.set,
                  ),
                  const Overline('Reply to a message'),
                  _ReplyGesturePicker(value: appearance.replyGesture, onChanged: appearance.setReplyGesture),
                  const Overline('Storage'),
                  Semantics(
                    container: true,
                    button: true,
                    label: 'My files',
                    onTap: () => _push(const MyFilesPage()),
                    child: GestureDetector(
                      onTap: () => _push(const MyFilesPage()),
                      // Where the uploads go: the user's own bucket while one is active.
                      child: switch (_storage) {
                        null => panel([row('My files', () => _push(const MyFilesPage()))]),
                        StorageInfo(:final activeBucket?) => BucketMeter(bucket: activeBucket),
                        final storage => StorageMeter(storage: storage, images: 0, files: storage.used, voice: 0),
                      },
                    ),
                  ),
                  const Overline('Developer'),
                  panel([
                    row(
                      'Developer portal',
                      () => _push(const DeveloperPage()),
                      value: switch (repository.teamInvites.value.length) {
                        0 => null,
                        1 => '1 invite',
                        final n => '$n invites',
                      },
                    ),
                  ]),
                  const Overline('Account'),
                  panel([
                    row('Change email', () => _push(const ChangeEmailPage())),
                    row('Sign out', repository.logOut, warn: true),
                  ]),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A segmented control: the chosen option raised out of a recess.
/// The gesture that replies to a message, each option acted out on a tiny
/// bubble: the one picked plays twice, then all hold mid-gesture.
class _ReplyGesturePicker extends StatefulWidget {
  final ReplyGesture value;
  final ValueChanged<ReplyGesture> onChanged;
  const _ReplyGesturePicker({required this.value, required this.onChanged});

  @override
  State<_ReplyGesturePicker> createState() => _ReplyGesturePickerState();
}

class _ReplyGesturePickerState extends State<_ReplyGesturePicker> with SingleTickerProviderStateMixin {
  static const _options = {
    ReplyGesture.swipeLeft: 'Swipe left',
    ReplyGesture.swipeRight: 'Swipe right',
    ReplyGesture.doubleTap: 'Double tap',
  };

  // A moment of each gesture that reads at a glance, for those held still.
  static const _pose = 0.3;

  late final _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800), value: _pose);
  bool _played = false;

  // Twice through, then on to the pose: the loop's start and end are both at rest.
  void _play() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _loop.value = _pose;
      return;
    }
    _loop.repeat(count: 2).whenComplete(() {
      if (mounted) {
        _loop
          ..value = 0
          ..animateTo(_pose);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_played) return;
    _played = true;
    _play();
  }

  @override
  void didUpdateWidget(_ReplyGesturePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) _play();
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final still = MediaQuery.disableAnimationsOf(context);
    const radius = BorderRadius.all(Radius.circular(DuvetTokens.radiusButton));
    return Semantics(
      label: 'Reply to a message',
      explicitChildNodes: true,
      child: Row(
        children: [
          for (final (i, MapEntry(key: gesture, value: text)) in _options.entries.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Semantics(
                container: true,
                button: true,
                inMutuallyExclusiveGroup: true,
                checked: gesture == widget.value,
                label: text,
                excludeSemantics: true,
                onTap: () => widget.onChanged(gesture),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    widget.onChanged(gesture);
                  },
                  child: AnimatedContainer(
                    duration: still ? Duration.zero : DuvetTokens.pressOut,
                    height: 104,
                    padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
                    decoration: BoxDecoration(
                      color: gesture == widget.value ? tokens.selectedFill : colors.secondary,
                      borderRadius: radius,
                      boxShadow: gesture == widget.value ? tokens.shadowControl : null,
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: gesture == widget.value
                              ? AnimatedBuilder(
                                  animation: _loop,
                                  builder: (context, _) =>
                                      _ReplyGestureDemo(gesture: gesture, t: _loop.value, picked: true),
                                )
                              : _ReplyGestureDemo(gesture: gesture, t: _pose, picked: false),
                        ),
                        const SizedBox(height: 8),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            text,
                            maxLines: 1,
                            style: DuvetType.label.copyWith(
                              fontSize: 14,
                              color: gesture == widget.value ? colors.foreground : colors.mutedForeground,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One reply gesture on a tiny bubble at [t] through its loop: slid off its
/// reply icon and back, or tapped twice with a ring for each tap.
class _ReplyGestureDemo extends StatelessWidget {
  final ReplyGesture gesture;
  final double t;
  final bool picked;
  const _ReplyGestureDemo({required this.gesture, required this.t, required this.picked});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final ink = picked ? context.duvet.accentText : colors.mutedForeground;
    final bubble = Container(
      width: 44,
      height: 22,
      decoration: BoxDecoration(
        color: picked ? Duvet.accent : colors.mutedForeground.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(11),
      ),
    );
    if (gesture == ReplyGesture.doubleTap) {
      // Two taps in the loop's first half, then a rest.
      final tap = t < 0.5 ? (t % 0.25) / 0.25 : null;
      return Stack(
        alignment: Alignment.center,
        children: [
          bubble,
          if (tap != null)
            Transform.scale(
              scale: 0.6 + tap * 0.9,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: ink.withValues(alpha: 1 - tap), width: 2),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(12, 14 - (tap == null ? 0 : 3 * (1 - tap))),
            child: Icon(FLucideIcons.pointer, size: 18, color: ink),
          ),
        ],
      );
    }
    final left = gesture == ReplyGesture.swipeLeft;
    // Out to the reply icon, held, then home.
    final out = t < 0.4
        ? Curves.easeOut.transform(t / 0.4)
        : t < 0.6
        ? 1.0
        : 1 - Curves.easeInOut.transform((t - 0.6) / 0.4);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 84,
          height: 22,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: left ? Alignment.centerRight : Alignment.centerLeft,
                child: Opacity(
                  opacity: out,
                  child: Icon(FLucideIcons.reply, size: 16, color: ink),
                ),
              ),
              Transform.translate(offset: Offset((left ? -18 : 18) * out, 0), child: bubble),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Icon(left ? FLucideIcons.arrowLeft : FLucideIcons.arrowRight, size: 14, color: ink),
      ],
    );
  }
}
