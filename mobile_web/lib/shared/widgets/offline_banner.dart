import 'package:flutter/material.dart';

import '../../core/formatting/dates.dart';
import '../../core/network/response_cache.dart';
import '../../core/theme/app_theme.dart';

/// Shown above the screens while the server cannot be reached: what is on screen is the copy
/// saved on this device, and changes have to wait for a connection.
class OfflineBanner extends StatefulWidget {
  const OfflineBanner({super.key, required this.connection, required this.onTryNow});

  final ConnectionStatus connection;

  /// Checks the connection now; true when the server was reached.
  final Future<bool> Function() onTryNow;

  @override
  State<OfflineBanner> createState() => _OfflineBannerState();
}

class _OfflineBannerState extends State<OfflineBanner> {
  bool _checking = false;

  /// e.g. "9 Nov 2026 10:20".
  static String _when(DateTime at) =>
      '${formatApiDate(toApiDate(at))} '
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

  Future<void> _tryNow() async {
    setState(() => _checking = true);
    try {
      await widget.onTryNow();
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final from = widget.connection.showingFrom ?? widget.connection.lastOnlineAt;
    return Material(
      color: SnackifyColors.warnFill,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_outlined, color: SnackifyColors.warn),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  [
                    'Offline.',
                    if (from != null) 'Showing information from ${_when(from)}.',
                    'Changes need a connection.',
                  ].join(' '),
                  style: const TextStyle(color: SnackifyColors.ink, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: _checking ? null : _tryNow,
                child: _checking
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Try now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
