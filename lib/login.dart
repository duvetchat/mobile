import 'package:duvet_client/duvet.dart' show DuvetApiException, DuvetAuthException;
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'account.dart';
import 'data/scope.dart';
import 'theme.dart';
import 'widgets/chrome.dart';
import 'widgets/pillow.dart';
import 'widgets/rows.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  bool _show = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The face follows the email as it's typed, and the password's field.
    for (final l in <Listenable>[_email, _emailFocus, _passwordFocus]) {
      l.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.repository.logIn(email, password);
    } on DuvetAuthException {
      _fail('That email and password don’t match.');
    } on DuvetApiException catch (e) {
      _fail(e.statusCode == 429 ? 'Too many tries. Wait a moment.' : 'Couldn’t sign in (${e.statusCode}).');
    } on Exception {
      _fail('Couldn’t reach Duvet. Check your connection.');
    }
  }

  void _fail(String message) {
    if (mounted) {
      setState(() {
        _busy = false;
        _error = message;
      });
    }
  }

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Wordmark(),
                  const SizedBox(height: 20),
                  // The form inside the mascot: its eyes on the email as
                  // it's typed, shut over the password, one peeking while
                  // it's shown.
                  PillowPanel(
                    mood: passwordMood(shown: _show, typing: _passwordFocus.hasFocus),
                    gaze: _show ? const Offset(0.4, 0.7) : gazeAlong(_email.text, typing: _emailFocus.hasFocus),
                    child: AutofillGroup(child: _form()),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // In the panel, so in night's colors: see [PillowPanel].
  Widget _form() => Builder(
    builder: (context) {
      final colors = context.theme.colors;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Sign in to Duvet',
              textAlign: TextAlign.center,
              style: DuvetType.title.copyWith(fontSize: 26, color: colors.foreground),
            ),
          ),
          const SizedBox(height: 24),
          DuvetTextField(
            label: 'Email',
            controller: _email,
            focusNode: _emailFocus,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
          ),
          const SizedBox(height: 16),
          DuvetTextField(
            label: 'Password',
            controller: _password,
            focusNode: _passwordFocus,
            obscure: !_show,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _submit(),
            trailing: IconAction(
              icon: _show ? FLucideIcons.eyeOff : FLucideIcons.eye,
              label: _show ? 'Hide password' : 'Show password',
              color: colors.mutedForeground,
              onPressed: () => setState(() => _show = !_show),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextAction(label: 'Forgot password?', onPressed: () => _push(const ForgotPasswordScreen())),
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(error, style: DuvetType.caption.copyWith(color: colors.error)),
            ),
          ],
          const SizedBox(height: 16),
          DuvetButton(label: 'Sign in', variant: ButtonVariant.primary, expand: true, busy: _busy, onPressed: _submit),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('New to Duvet?', style: DuvetType.snippet.copyWith(color: colors.mutedForeground)),
              TextAction(label: 'Create an account', onPressed: () => _push(const SignUpScreen())),
            ],
          ),
        ],
      );
    },
  );
}
