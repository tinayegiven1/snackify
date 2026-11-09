import 'dart:async';

import 'api_client.dart';
import 'response_cache.dart';

/// Keeps the information saved on the device up to date, and notices when the server can be
/// reached again.
///
/// - After signing in (and when the main screens open) it fetches the main lists, so they can
///   be seen offline even if nobody opened them yet.
/// - While offline it checks every [retryEvery] whether the server is back; when it is, it
///   fetches the lists again and tells the screens to reload ([ConnectionStatus.refreshed]).
class SyncService {
  SyncService({
    required ApiClient api,
    required Future<bool> Function() checkHealth,
    required List<Future<void> Function()> refreshers,
    this.retryEvery = const Duration(seconds: 20),
  }) : _connection = api.connection,
       _checkHealth = checkHealth,
       _refreshers = refreshers {
    _connection.addListener(_onConnectionChanged);
  }

  final ConnectionStatus _connection;
  final Future<bool> Function() _checkHealth;
  final List<Future<void> Function()> _refreshers;

  /// How often to check for the server while offline; null checks only when asked (tests).
  final Duration? retryEvery;

  Timer? _retry;
  bool _syncing = false;

  void _onConnectionChanged() {
    final every = retryEvery;
    if (_connection.offline) {
      if (every != null) _retry ??= Timer.periodic(every, (_) => syncNow());
    } else {
      _retry?.cancel();
      _retry = null;
    }
  }

  /// Fetches the main lists so they are saved on the device. Each one that fails (offline, or
  /// not allowed for this user) is simply skipped.
  Future<void> warmUp() async {
    for (final refresh in _refreshers) {
      try {
        await refresh();
      } on Object {
        // Not available to this user, or the server could not be reached: nothing to save.
      }
    }
  }

  /// Checks the server now: if it is back, brings the saved information up to date and tells
  /// the screens to reload. Returns whether the server could be reached.
  Future<bool> syncNow() async {
    if (_syncing) return !_connection.offline;
    _syncing = true;
    try {
      final wasOffline = _connection.offline;
      if (!await _checkHealth()) return false;
      await warmUp();
      if (wasOffline) _connection.refreshed();
      return true;
    } finally {
      _syncing = false;
    }
  }

  void dispose() {
    _retry?.cancel();
    _connection.removeListener(_onConnectionChanged);
  }
}
