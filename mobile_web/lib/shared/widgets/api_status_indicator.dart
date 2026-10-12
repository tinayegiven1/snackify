import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

enum _ApiStatus { checking, online, offline }

/// Shows whether the backend API is reachable. Tap to check again.
class ApiStatusIndicator extends StatefulWidget {
  const ApiStatusIndicator({super.key, required this.checkHealth});

  final Future<bool> Function() checkHealth;

  @override
  State<ApiStatusIndicator> createState() => _ApiStatusIndicatorState();
}

class _ApiStatusIndicatorState extends State<ApiStatusIndicator> {
  _ApiStatus _status = _ApiStatus.checking;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (_status != _ApiStatus.checking) {
      setState(() => _status = _ApiStatus.checking);
    }
    final healthy = await widget.checkHealth();
    if (!mounted) return;
    setState(() => _status = healthy ? _ApiStatus.online : _ApiStatus.offline);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (label, color, icon) = switch (_status) {
      _ApiStatus.checking => ('Checking API…', colorScheme.outline, Icons.sync),
      _ApiStatus.online => ('API online', SnackifyColors.success, Icons.cloud_done_outlined),
      _ApiStatus.offline => ('API offline', colorScheme.error, Icons.cloud_off_outlined),
    };

    return Tooltip(
      message: 'Tap to check the API connection again',
      child: ActionChip(
        avatar: Icon(icon, size: 18, color: color),
        label: Text(label),
        onPressed: _status == _ApiStatus.checking ? null : _check,
      ),
    );
  }
}
