import 'package:flutter/material.dart';

import 'core/app_services.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/presentation/auth_controller.dart';
import 'features/auth/presentation/login_screen.dart';
import 'shared/widgets/app_shell.dart';

class SnackifyApp extends StatelessWidget {
  const SnackifyApp({super.key, required this.auth, required this.services});

  final AuthController auth;
  final AppServices services;

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
            services: services,
          ),
        },
      ),
    );
  }
}
