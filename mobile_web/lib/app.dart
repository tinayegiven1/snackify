import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'features/auth/presentation/auth_controller.dart';
import 'features/auth/presentation/login_screen.dart';
import 'shared/widgets/app_shell.dart';

class SnackifyApp extends StatelessWidget {
  const SnackifyApp({super.key, required this.auth, required this.checkBackendHealth});

  final AuthController auth;

  /// Returns true when the Snackify API is reachable. Injected so tests can fake it.
  final Future<bool> Function() checkBackendHealth;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Snackify',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      // Show the login screen or the app, depending on whether someone is signed in.
      home: ListenableBuilder(
        listenable: auth,
        builder: (context, _) => switch (auth.status) {
          AuthStatus.restoring => const Scaffold(body: Center(child: CircularProgressIndicator())),
          AuthStatus.signedOut => LoginScreen(auth: auth),
          AuthStatus.signedIn => AppShell(
            user: auth.user!,
            onSignOut: auth.signOut,
            checkBackendHealth: checkBackendHealth,
          ),
        },
      ),
    );
  }
}
