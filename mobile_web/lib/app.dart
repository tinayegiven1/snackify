import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'shared/widgets/app_shell.dart';

class SnackifyApp extends StatelessWidget {
  const SnackifyApp({super.key, required this.checkBackendHealth});

  /// Returns true when the Snackify API is reachable. Injected so tests can fake it.
  final Future<bool> Function() checkBackendHealth;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Snackify',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: AppShell(checkBackendHealth: checkBackendHealth),
    );
  }
}
