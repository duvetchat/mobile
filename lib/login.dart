import 'package:duvet_client/duvet.dart' show DuvetApiException, DuvetAuthException;
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'account.dart';
import 'data/scope.dart';
import 'theme.dart';
import 'widgets/mascot.dart';
import 'widgets/rows.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
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
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: Mascot(size: 120)),
                    const SizedBox(height: 20),
                    Semantics(
                      header: true,
                      child: Text(
                        'Sign in to Duvet',
                        textAlign: TextAlign.center,
                        style: DuvetType.largeTitle.copyWith(color: colors.foreground),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'A cozy place to talk',
                      textAlign: TextAlign.center,
                      style: DuvetType.snippet.copyWith(color: colors.mutedForeground),
                    ),
                    const SizedBox(height: 32),
                    DuvetTextField(
                      label: 'Email',
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                    ),
                    const SizedBox(height: 16),
                    DuvetTextField(
                      label: 'Password',
                      controller: _password,
                      obscure: true,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _submit(),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextAction(
                        label: 'Forgot password?',
                        onPressed: () => _push(const ForgotPasswordScreen()),
                      ),
                    ),
                    if (_error case final error?) ...[
                      const SizedBox(height: 8),
                      Semantics(
                        liveRegion: true,
                        child: Text(error, style: DuvetType.caption.copyWith(color: colors.error)),
                      ),
                    ],
                    const SizedBox(height: 16),
                    DuvetButton(
                      label: 'Sign in',
                      variant: ButtonVariant.primary,
                      expand: true,
                      busy: _busy,
                      onPressed: _submit,
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('New to Duvet?', style: DuvetType.snippet.copyWith(color: colors.mutedForeground)),
                        TextAction(label: 'Create an account', onPressed: () => _push(const SignUpScreen())),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
