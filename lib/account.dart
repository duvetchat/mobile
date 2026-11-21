import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:duvet_client/duvet.dart' show maxBioLength;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:forui/forui.dart';
import 'package:image_picker/image_picker.dart';

import 'data/appearance.dart';
import 'data/images.dart';
import 'data/launcher_icon.dart';
import 'data/links.dart';
import 'data/models.dart';
import 'data/scope.dart';
import 'developer.dart' show DeveloperPage;
import 'login.dart';
import 'people.dart';
import 'sounds_settings.dart';
import 'space_admin.dart' show AdminPage, AdminPanel, avatarSide, confirmDestructive, saveBannerImage, saveSquareImage;
import 'tabs.dart' show LiveIndicator;
import 'shell.dart';
import 'theme.dart';
import 'widgets/avatar.dart';
import 'widgets/chrome.dart';
import 'widgets/code_highlight.dart';
import 'widgets/ghost_art.dart';
import 'widgets/glass.dart';
import 'widgets/picture_edit.dart';
import 'widgets/rows.dart';
import 'widgets/sheets.dart' show LoadingSkeleton, placeholderNames;
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
    ).readable;
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
  final _alias = TextEditingController();
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _show = false;
  bool _terms = false;
  bool _busy = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    for (final c in [_alias, _username, _email, _password, _confirm]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_alias, _username, _email, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  // The API's rules: a username trimmed, not empty, of 32 characters at most
  // (code points, as its column counts them), as the display name; a
  // password of 8 to 72 bytes, as bcrypt takes it.
  String get _name => _username.text.trim();
  int get _nameLength => _name.runes.length;
  int get _aliasLength => _alias.text.trim().runes.length;
  int get _passwordBytes => utf8.encode(_password.text).length;
  bool get _validEmail => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim());
  bool get _matches => _confirm.text == _password.text;

  Future<void> _create() async {
    final navigator = Navigator.of(context);
    final alias = _alias.text.trim();
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await context.repository.signUp(
        username: _name,
        email: _email.text.trim(),
        password: _password.text,
        alias: alias.isEmpty ? null : alias,
      );
      // Signed in: the app shows; the verify screen goes over it.
      navigator.popUntil((r) => r.isFirst);
      unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => VerifyEmailPage(email: _email.text.trim()))));
    } catch (e) {
      if (mounted) setState(() => _failure = e is ActionFailed ? e.message : _error(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // As the desktop's.
  void _showTerms() => showGlassDialogSheet<void>(
    context,
    label: 'Terms of use',
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Terms of use', style: DuvetType.title.copyWith(color: context.theme.colors.foreground)),
          const SizedBox(height: 12),
          Text(
            'By creating an account, you agree to follow community guidelines and use Duvet respectfully.',
            style: DuvetType.snippet.copyWith(color: context.theme.colors.mutedForeground),
          ),
          const SizedBox(height: 24),
          DuvetButton(label: 'Close', expand: true, onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final strength = passwordStrength(_password.text);
    final ready =
        _name.isNotEmpty &&
        _nameLength <= maxUsernameLength &&
        _aliasLength <= maxDisplayNameLength &&
        _validEmail &&
        _password.text.length >= 8 &&
        _passwordBytes <= 72 &&
        _matches &&
        _terms;
    void toggleTerms() => setState(() => _terms = !_terms);
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
          label: 'Display name (optional)',
          controller: _alias,
          autofocus: true,
          autofillHints: const [AutofillHints.name],
          textInputAction: TextInputAction.next,
          error: _aliasLength > maxDisplayNameLength
              ? 'Too long: $_aliasLength of $maxDisplayNameLength characters'
              : null,
        ),
        const SizedBox(height: 16),
        DuvetTextField(
          label: 'Username',
          controller: _username,
          autofillHints: const [AutofillHints.newUsername],
          textInputAction: TextInputAction.next,
          helper: 'It’s how people mention you.',
          error: _nameLength > maxUsernameLength ? 'Too long: $_nameLength of $maxUsernameLength characters' : null,
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
          textInputAction: TextInputAction.next,
          error: _passwordBytes > 72 ? 'Too long: 72 characters at most, fewer with accents or emoji' : null,
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
        const SizedBox(height: 16),
        DuvetTextField(
          label: 'Confirm password',
          controller: _confirm,
          obscure: !_show,
          autofillHints: const [AutofillHints.newPassword],
          error: _confirm.text.isNotEmpty && !_matches ? 'Passwords don’t match' : null,
        ),
        const SizedBox(height: 16),
        // Wraps on a narrow screen or at a large text size: the link goes under the box.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(
              container: true,
              checked: _terms,
              label: 'I agree to the Terms of use',
              excludeSemantics: true,
              onTap: toggleTerms,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: toggleTerms,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SquareCheck(checked: _terms),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text('I agree to the', style: DuvetType.body.copyWith(color: colors.foreground)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            TextAction(label: 'Terms of use', onPressed: _showTerms),
          ],
        ),
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

/// My account, as the desktop's section: the profile as others see it, then
/// its fields.
class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

/// The longest display name the API takes, in characters.
const maxDisplayNameLength = 32;

/// The longest username the API takes, counted the same way.
const maxUsernameLength = 32;

class _EditProfilePageState extends State<EditProfilePage> {
  late final TextEditingController _alias;
  late final TextEditingController _bio;
  late final TextEditingController _username;
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

  /// The username as the API takes it: trimmed; empty keeps the one there.
  String get _name => _username.text.trim();
  int get _nameLength => _name.runes.length;
  bool get _nameTooLong => _nameLength > maxUsernameLength;
  bool _renamed(Profile profile) => _name.isNotEmpty && _name != profile.username;

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
    _username = TextEditingController(text: profile?.username ?? '')..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _alias.dispose();
    _bio.dispose();
    _username.dispose();
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
    final renamed = _renamed(repository.profile.value!);
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
      await repository.updateProfile(alias: _alias.text, bio: changed ? bio : null, username: renamed ? _name : null);
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
    final username = _name.isEmpty ? profile.username : _name;
    final dirty =
        _renamed(profile) ||
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
                                  image: b.startsWith('http') ? cachedImage(b) : FileImage(File(b)),
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
                                alias.isEmpty ? username : alias,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: DuvetType.label.copyWith(color: colors.foreground),
                              ),
                              Text(
                                '@$username',
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
                  // The desktop's group, under the card.
                  const Overline('Profile'),
                  // At most 32 characters, as the API takes; empty, the username shows.
                  DuvetTextField(
                    label: 'Display name',
                    controller: _alias,
                    hint: username,
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
                  // As the API takes it, and only that: 32 characters at most,
                  // trimmed; empty keeps the one there.
                  DuvetTextField(
                    label: 'Username',
                    controller: _username,
                    hint: profile.username,
                    autofillHints: const [AutofillHints.newUsername],
                    helper: 'It’s how people mention you.',
                    error: _nameTooLong ? 'Too long: $_nameLength of $maxUsernameLength characters' : null,
                  ),
                ],
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                title: const Text('My account'),
                leading: TextAction(label: 'Cancel', onPressed: () => Navigator.of(context).maybePop()),
                actions: [
                  TextAction(
                    label: 'Save',
                    onPressed: _saving || !dirty || _bioTooLong || _aliasTooLong || _nameTooLong ? null : _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ).readable,
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
    // Its size from its header: decoding a frame isn't needed, and a moving
    // GIF's first frame sometimes never came in tests.
    File(widget.path)
        .readAsBytes()
        .then(ui.ImmutableBuffer.fromUint8List)
        .then((buffer) async {
          try {
            final descriptor = await ui.ImageDescriptor.encoded(buffer);
            final size = Size(descriptor.width.toDouble(), descriptor.height.toDouble());
            descriptor.dispose();
            return size;
          } finally {
            buffer.dispose();
          }
        })
        .then(
          (size) {
            if (mounted) setState(() => _image = size);
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
    ).readable;
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

/// Attachments, as the desktop's section: the storage used, by kind, and
/// every file, to delete.
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
    final sure = await confirmFileDelete(context, 'Delete ${f.name}?');
    if (!sure || !mounted) return;
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
                if (files == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: LoadingSkeleton(
                      label: 'Loading storage',
                      children: [
                        StorageMeter(
                          storage: const StorageInfo(used: 0, max: 1),
                          images: 0,
                          files: 0,
                          voice: 0,
                          big: true,
                        ),
                      ],
                    ),
                  ),
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
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: LoadingSkeleton(
                      label: 'Loading files',
                      children: [for (final f in placeholderFiles) FileRow(file: f)],
                    ),
                  )
                else if (shown.isEmpty)
                  const ListNote('No files')
                else
                  for (final f in shown)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: FileRow(file: f, onDelete: () => _delete(f)),
                    ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(title: const Text('Attachments'), onBack: () => Navigator.of(context).maybePop()),
          ),
        ],
      ),
    ).readable;
  }
}

/// Asks before deleting files for good: one of the user's, by default.
Future<bool> confirmFileDelete(
  BuildContext context,
  String title, {
  String body = 'It goes from every message it’s in. This can’t be undone.',
  String action = 'Delete file',
}) async =>
    await showGlassDialogSheet<bool>(
      context,
      label: title,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: DuvetType.titleSans.copyWith(color: context.theme.colors.foreground)),
            const SizedBox(height: 12),
            Text(body, style: DuvetType.snippet.copyWith(color: context.theme.colors.mutedForeground)),
            const SizedBox(height: 24),
            DuvetButton(
              label: action,
              variant: ButtonVariant.destructive,
              expand: true,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 12),
            DuvetButton(label: 'Cancel', expand: true, onPressed: () => Navigator.of(context).pop(false)),
          ],
        ),
      ),
    ) ==
    true;

/// Files for [FileRow]s while a list of them loads.
final placeholderFiles = [
  for (final (i, name) in placeholderNames.indexed)
    MyFile(id: 'placeholder-$i', name: name, contentType: '', sizeBytes: 0, createdAt: DateTime(2026), url: ''),
];

/// An uploaded file: its picture or kind, name, size and date, and a trash
/// button when it can be deleted alone.
class FileRow extends StatelessWidget {
  final MyFile file;
  final VoidCallback? onDelete;

  /// After the size and date, e.g. why it can't be deleted alone.
  final String? note;
  const FileRow({required this.file, this.onDelete, this.note, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final f = file;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
            child: Container(
              width: 48,
              height: 48,
              color: colors.secondary,
              child: f.isImage
                  ? Image(
                      image: cachedImage(f.url, cacheWidth: (48 * MediaQuery.devicePixelRatioOf(context)).round()),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Icon(FLucideIcons.image, color: colors.foreground),
                    )
                  : Icon(f.isAudio ? FLucideIcons.mic : FLucideIcons.fileText, color: colors.foreground),
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
                  [formatBytes(f.sizeBytes), shortTime(f.createdAt), ?note].join(' · '),
                  style: DuvetType.caption.copyWith(color: colors.mutedForeground),
                ),
              ],
            ),
          ),
          if (onDelete != null)
            IconAction(
              icon: FLucideIcons.trash2,
              label: 'Delete ${f.name}',
              color: colors.mutedForeground,
              onPressed: onDelete,
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

  /// Before the bucket's name: whose storage it is.
  final String title;
  const BucketMeter({required this.bucket, this.big = false, this.title = 'Your own storage', super.key});

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
        label: '$title, ${bucket.name}: ${formatBytes(bucket.used)} $of',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$title · ${bucket.name}',
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

/// You: the profile card (Edit), friends and status, then the settings in
/// the desktop's sections (#284, SettingsScreen.svelte), each a page of its
/// own: My account, Attachments, Security, Audio, Appearance, then Developer
/// apart, and Sign out. The desktop's Activity privacy (its app's alone) and
/// S3 buckets (added and edited there) have nothing here to hold.
class YouTab extends StatefulWidget {
  const YouTab({super.key});

  @override
  State<YouTab> createState() => _YouTabState();
}

class _YouTabState extends State<YouTab> {
  // The status chosen while the server takes it: shown meanwhile.
  Presence? _choosing;

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
    // Null where the app doesn't hand them down (a test's bare app): no Audio section without either.
    final voicePrefs = VoicePrefsScope.maybeOf(context);
    final sounds = SoundsScope.maybeOf(context);
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
        // A section, its icon on its colour as the desktop lists them.
        Widget section(String label, IconData icon, Color tile, Widget page, {String? detail}) => GlassRow(
          label: label,
          detail: detail,
          leading: _SectionTile(icon: icon, color: tile),
          onPressed: () => _push(page),
        );
        return LargeTitlePage(
          title: 'You',
          titleLeading: const AppIcon(size: 32),
          titleTrailing: const LiveIndicator(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              // Built whole, not lazily: a short page, and every row (Sign
              // out last) exists for finders and screen readers alike.
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
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
                          // My account, as the desktop's head opens it.
                          DuvetButton(label: 'Edit', onPressed: () => _push(const EditProfilePage())),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    panel([
                      GlassRow(
                        label: 'Friends',
                        detail: repository.friends.value.incoming.isEmpty
                            ? null
                            : '${repository.friends.value.incoming.length} waiting',
                        onPressed: () => _push(const FriendsPage()),
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
                    const Overline('Settings'),
                    panel([
                      section('My account', FLucideIcons.user, const Color(0xFF5E6380), const EditProfilePage()),
                      section('Attachments', FLucideIcons.paperclip, const Color(0xFF0B6FE8), const MyFilesPage()),
                      section(
                        'Security',
                        FLucideIcons.shield,
                        const Color(0xFF2F9E62),
                        const SecurityPage(),
                        detail: profile.emailVerified ? null : 'Email not verified',
                      ),
                      if (sounds != null || voicePrefs != null)
                        section(
                          'Audio',
                          FLucideIcons.volume2,
                          const Color(0xFFF97316),
                          AudioPage(sounds: sounds, prefs: voicePrefs),
                        ),
                      section('Appearance', FLucideIcons.palette, const Color(0xFF2F4CFF), const AppearancePage()),
                    ]),
                    // Apart, as the desktop's.
                    const SizedBox(height: 16),
                    panel([
                      section(
                        'Developer',
                        FLucideIcons.code,
                        const Color(0xFF5F45B5),
                        const DeveloperPage(),
                        detail: switch (repository.teamInvites.value.length) {
                          0 => null,
                          1 => '1 invite',
                          final n => '$n invites',
                        },
                      ),
                    ]),
                    const SizedBox(height: 16),
                    panel([GlassRow(label: 'Sign out', destructive: true, onPressed: repository.logOut)]),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A section's icon on its colour, white, as the desktop's settings list has
/// them.
class _SectionTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _SectionTile({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(9)),
      child: Icon(icon, size: 18, color: const Color(0xFFFFFFFF)),
    ),
  );
}

/// Security, as the desktop's section: whether the email is verified, then
/// signing in: the password, and the email.
class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key});

  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  // A reset link on its way: a second tap doesn't send another.
  bool _sendingReset = false;

  void _push(Widget page) =>
      Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => page));

  // The emailed link opens the reset page, as Forgot password's does.
  Future<void> _sendResetPassword() async {
    if (_sendingReset) return;
    final sure = await confirmDestructive(
      context,
      title: 'Reset your password?',
      body: 'We’ll email you a link to set a new one. Your password stays as it is until you do.',
      action: 'Send link',
      destructive: false,
    );
    if (!sure || !mounted) return;
    setState(() => _sendingReset = true);
    try {
      await context.repository.sendResetPasswordEmail();
      if (mounted) _toast(context, 'We emailed you a link to set a new password');
    } catch (e) {
      if (mounted) _toast(context, e is ActionFailed ? e.message : 'Couldn’t send the link');
    } finally {
      if (mounted) setState(() => _sendingReset = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return ValueListenableBuilder(
      valueListenable: context.repository.profile,
      builder: (context, profile, _) => AdminPage(
        title: 'Security',
        children: [
          AdminPanel(
            children: [
              if (profile?.emailVerified ?? true)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                  child: Row(
                    children: [
                      ExcludeSemantics(child: Icon(FLucideIcons.mailCheck, size: 24, color: context.duvet.live)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text('Email verified', style: DuvetType.label.copyWith(color: colors.foreground)),
                      ),
                    ],
                  ),
                )
              else
                GlassRow(
                  icon: FLucideIcons.mail,
                  label: 'Verify your email',
                  detail: 'Not verified yet',
                  onPressed: () => _push(const VerifyEmailPage()),
                ),
            ],
          ),
          const Overline('Sign-in'),
          AdminPanel(
            children: [
              GlassRow(
                icon: FLucideIcons.keyRound,
                label: 'Reset password',
                detail: _sendingReset ? 'Sending…' : null,
                onPressed: _sendResetPassword,
              ),
              GlassRow(icon: FLucideIcons.mail, label: 'Change email', onPressed: () => _push(const ChangeEmailPage())),
            ],
          ),
        ],
      ),
    );
  }
}

/// Appearance, as the desktop's section: the theme, how messages show, then
/// what the desktop has no need of (the gesture that replies, the app's icon)
/// beside code blocks and faces in voice.
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context) {
    final appearance = AppearanceScope.of(context);
    // Null where the app doesn't hand them down (a test's bare app): no Voice group.
    final voicePrefs = VoicePrefsScope.maybeOf(context);
    final colors = context.theme.colors;
    return AdminPage(
      title: 'Appearance',
      children: [
        const Overline('Theme'),
        Segmented<ThemeMode>(
          label: 'Theme',
          value: appearance.value,
          options: const {ThemeMode.system: 'System', ThemeMode.light: 'Light', ThemeMode.dark: 'Dark'},
          onChanged: appearance.set,
        ),
        // The desktop's Messages: bubbles, or its flat rows.
        const Overline('Messages'),
        Segmented<MessageLayout>(
          label: 'Message layout',
          value: appearance.messageLayout,
          options: const {MessageLayout.bubbles: 'Bubbles', MessageLayout.flat: 'Flat rows'},
          onChanged: appearance.setMessageLayout,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            'Flat rows fit more on screen; bubbles are easier to follow.',
            style: DuvetType.caption.copyWith(color: colors.mutedForeground),
          ),
        ),
        const Overline('Reply to a message'),
        _ReplyGesturePicker(value: appearance.replyGesture, onChanged: appearance.setReplyGesture),
        const Overline('Code blocks'),
        AdminPanel(
          children: [
            GlassRow(
              label: 'Code theme',
              detail: appearance.codeTheme == null ? 'GitHub' : 'Custom',
              onPressed: () =>
                  showGlassDialogSheet<void>(context, label: 'Code theme', builder: (_) => const _CodeThemeSheet()),
            ),
          ],
        ),
        const _LauncherIconPicker(),
        if (voicePrefs != null) ...[
          const Overline('Voice'),
          ListenableBuilder(
            listenable: voicePrefs,
            builder: (context, _) => AdminPanel(
              children: [
                SettingToggle(
                  label: 'Faces in voice',
                  detail: 'Voice tiles show everyone’s animated face instead of their picture',
                  value: voicePrefs.facesInVoice,
                  onChanged: voicePrefs.setFacesInVoice,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// A VS Code theme for code blocks, by its URL: fetched once, on Apply, and
/// previewed on the surface it's used on, so applying a dark one in light
/// mode still shows.
class _CodeThemeSheet extends StatefulWidget {
  const _CodeThemeSheet();

  @override
  State<_CodeThemeSheet> createState() => _CodeThemeSheetState();
}

class _CodeThemeSheetState extends State<_CodeThemeSheet> {
  late final _url = TextEditingController(text: AppearanceScope.of(context).codeTheme?.url);
  String? _error;
  bool _busy = false;

  static const _sample =
      'package main\n\n// Greet says hello.\nfunc Greet(name string) string {\n\treturn fmt.Sprintf("Hi, %s", name) + strconv.Itoa(42)\n}';

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final appearance = AppearanceScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await appearance.applyCodeTheme(_url.text);
    } catch (e) {
      debugPrint('code theme: $e');
      if (mounted) setState(() => _error = 'Couldn’t read a VS Code theme there');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final appearance = AppearanceScope.of(context);
    final theme = appearance.codeTheme;
    final dark = theme?.dark ?? Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? Duvet.dark : Duvet.light;
    final style = DuvetType.code.copyWith(fontSize: 13, height: 1.5, color: surface.foreground);
    final where = theme == null
        ? 'GitHub’s colors, as on the desktop'
        : ['Used in ${dark ? 'dark' : 'light'} mode', if (ownBubble.onDark == dark) 'and on your bubbles'].join(' ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text('Code theme', style: DuvetType.title.copyWith(color: colors.foreground)),
          ),
          const SizedBox(height: 4),
          Text(
            'A VS Code color theme’s JSON, by its link.',
            style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
          ),
          const SizedBox(height: 16),
          DuvetTextField(
            label: 'Theme link',
            controller: _url,
            hint: 'https://…/theme.json',
            error: _error,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _apply(),
          ),
          const SizedBox(height: 16),
          // The theme's own surface, not the app's: its colors are made for it.
          Semantics(
            label: 'Preview. $where',
            excludeSemantics: true,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: surface.card,
                borderRadius: BorderRadius.circular(DuvetTokens.radiusField),
                border: Border.all(color: colors.border),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text.rich(highlightCode(_sample, 'go', base: style, dark: dark, custom: theme)!),
              ),
            ),
          ),
          const SizedBox(height: 6),
          ExcludeSemantics(
            child: Text(where, style: DuvetType.caption.copyWith(color: colors.mutedForeground)),
          ),
          const SizedBox(height: 16),
          DuvetButton(label: 'Apply', variant: ButtonVariant.primary, expand: true, busy: _busy, onPressed: _apply),
          if (theme != null) ...[
            const SizedBox(height: 8),
            Center(
              child: TextAction(
                label: 'Use the default',
                onPressed: () {
                  _url.clear();
                  setState(() => _error = null);
                  appearance.resetCodeTheme();
                },
              ),
            ),
          ],
        ],
      ),
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

/// The app's icon on the home screen, each one a tile to pick it by, under its
/// own heading. Nothing where it can't be changed (anywhere but Android).
class _LauncherIconPicker extends StatefulWidget {
  const _LauncherIconPicker();

  @override
  State<_LauncherIconPicker> createState() => _LauncherIconPickerState();
}

class _LauncherIconPickerState extends State<_LauncherIconPicker> {
  LauncherIcon? _picked;

  @override
  void initState() {
    super.initState();
    LauncherIcon.picked().then((icon) {
      if (mounted && icon != null) setState(() => _picked = icon);
    });
  }

  Future<void> _pick(LauncherIcon icon) async {
    if (icon == _picked) return;
    final before = _picked;
    HapticFeedback.selectionClick();
    setState(() => _picked = icon);
    try {
      await icon.pick();
    } catch (e) {
      debugPrint('launcher icon: $e');
      if (mounted) setState(() => _picked = before);
    }
  }

  @override
  Widget build(BuildContext context) {
    final picked = _picked;
    if (picked == null) return const SizedBox.shrink();
    final colors = context.theme.colors;
    final tokens = context.duvet;
    final still = MediaQuery.disableAnimationsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Overline('App icon'),
        Semantics(
          label: 'App icon',
          explicitChildNodes: true,
          child: Row(
            children: [
              for (final (i, icon) in LauncherIcon.values.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    container: true,
                    button: true,
                    inMutuallyExclusiveGroup: true,
                    checked: icon == picked,
                    label: icon.label,
                    excludeSemantics: true,
                    onTap: () => _pick(icon),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _pick(icon),
                      child: AnimatedContainer(
                        duration: still ? Duration.zero : DuvetTokens.pressOut,
                        height: 104,
                        padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
                        decoration: BoxDecoration(
                          color: icon == picked ? tokens.selectedFill : colors.secondary,
                          borderRadius: const BorderRadius.all(Radius.circular(DuvetTokens.radiusButton)),
                          boxShadow: icon == picked ? tokens.shadowControl : null,
                        ),
                        child: Column(
                          children: [
                            Expanded(child: SvgPicture.asset(icon.asset, excludeFromSemantics: true)),
                            const SizedBox(height: 8),
                            Text(
                              icon.label,
                              maxLines: 1,
                              style: DuvetType.label.copyWith(
                                fontSize: 14,
                                color: icon == picked ? colors.foreground : colors.mutedForeground,
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
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            'Your home screen shows it once you close Duvet. Some launchers need a restart first.',
            style: DuvetType.caption.copyWith(color: colors.mutedForeground),
          ),
        ),
      ],
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
        color: picked ? ownBubble.fill : colors.mutedForeground.withValues(alpha: 0.35),
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
