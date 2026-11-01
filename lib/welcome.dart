import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import 'account.dart';
import 'login.dart';
import 'theme.dart';
import 'widgets/ghost_art.dart';
import 'widgets/rows.dart';

/// Signed out: the app icon under a night sky, the wordmark, and the two ways
/// in. Each opens its form over this screen.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final width = MediaQuery.sizeOf(context).width;
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          Positioned(top: 0, left: 0, child: NightSky.welcome(width: width)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                children: [
                  // Where the design sets it: the clouds sit under the line, not the wordmark.
                  const SizedBox(height: 93),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: context.duvet.shadowFloat,
                    ),
                    child: const AppIcon(size: 128),
                  ),
                  const SizedBox(height: 28),
                  Semantics(
                    header: true,
                    child: Text(
                      'duvet',
                      style: DuvetType.largeTitle.copyWith(
                        fontSize: 68,
                        letterSpacing: 68 * -0.03,
                        height: 1,
                        color: colors.foreground,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Talk with your people.',
                    textAlign: TextAlign.center,
                    style: DuvetType.body.copyWith(fontSize: 17, color: colors.mutedForeground),
                  ),
                  const Spacer(),
                  DuvetButton(
                    label: 'Create account',
                    variant: ButtonVariant.primary,
                    expand: true,
                    onPressed: () => open(const SignUpScreen()),
                  ),
                  const SizedBox(height: 12),
                  DuvetButton(label: 'Sign in', expand: true, onPressed: () => open(const LoginScreen())),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
