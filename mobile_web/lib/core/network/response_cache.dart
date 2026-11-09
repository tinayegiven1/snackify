import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// A saved answer from the server: what it said and when.
typedef CachedResponse = ({String body, DateTime savedAt});

/// Copies of the server's answers, kept on the device so screens can still show the last
/// known information when the server cannot be reached. Only for reading: nothing is ever
/// sent from here. Wiped at sign-out and at each new sign-in, so one person never sees
/// another's information.
abstract class ResponseCache {
  Future<CachedResponse?> read(String key);
  Future<void> write(String key, String body);
  Future<void> clear();

  /// Files in the app's private folder on phones; memory only in a browser, where a saved
  /// copy would outlive the tab on a shared computer.
  static ResponseCache forDevice() => kIsWeb ? MemoryResponseCache() : FileResponseCache();
}

/// Lost when the app closes (browsers and tests).
class MemoryResponseCache implements ResponseCache {
  final Map<String, CachedResponse> _entries = {};

  @override
  Future<CachedResponse?> read(String key) async => _entries[key];

  @override
  Future<void> write(String key, String body) async =>
      _entries[key] = (body: body, savedAt: DateTime.now());

  @override
  Future<void> clear() async => _entries.clear();
}

/// One small JSON file per answer, in the app's private support folder (other apps cannot
/// read it, and it is removed when the app is uninstalled).
class FileResponseCache implements ResponseCache {
  FileResponseCache({Future<Directory> Function()? baseFolder})
    : _baseFolder = baseFolder ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _baseFolder;
  Directory? _folder;

  Future<Directory> _dir() async {
    final folder = _folder ??= Directory('${(await _baseFolder()).path}/offline');
    if (!folder.existsSync()) await folder.create(recursive: true);
    return folder;
  }

  /// A file name from the key: two 32-bit FNV-1a hashes with different starting values, so
  /// short and safe whatever the address holds. (32-bit numbers only: the web build cannot
  /// even compile 64-bit literals, although this class is never used there.)
  static String _fileName(String key) {
    final bytes = utf8.encode(key);
    String fnv32(int start) {
      var hash = start;
      for (final unit in bytes) {
        hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
      }
      return hash.toRadixString(16).padLeft(8, '0');
    }

    return '${fnv32(0x811c9dc5)}${fnv32(0x050c5d1f)}.json';
  }

  @override
  Future<CachedResponse?> read(String key) async {
    try {
      final file = File('${(await _dir()).path}/${_fileName(key)}');
      if (!file.existsSync()) return null;
      final saved = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      // Two addresses could share a file name; only the one that wrote it reads it back.
      if (saved['key'] != key) return null;
      return (body: saved['body'] as String, savedAt: DateTime.parse(saved['savedAt'] as String));
    } on Object {
      return null; // A damaged copy is no copy.
    }
  }

  @override
  Future<void> write(String key, String body) async {
    try {
      final file = File('${(await _dir()).path}/${_fileName(key)}');
      await file.writeAsString(
        jsonEncode({'key': key, 'savedAt': DateTime.now().toIso8601String(), 'body': body}),
        flush: true,
      );
    } on Object {
      // Saving a copy is a convenience; the screen already has what it asked for.
    }
  }

  @override
  Future<void> clear() async {
    try {
      final folder = await _dir();
      if (folder.existsSync()) await folder.delete(recursive: true);
      _folder = null;
    } on Object {
      // Nothing more can be done; the next sign-in tries again.
    }
  }
}

/// Whether the server can be reached, as the app last found out, and when the information on
/// screen was last brought up to date.
class ConnectionStatus extends ChangeNotifier {
  bool _offline = false;
  bool get offline => _offline;

  /// When a request last reached the server.
  DateTime? _lastOnlineAt;
  DateTime? get lastOnlineAt => _lastOnlineAt;

  /// The oldest saved copy shown since going offline: what the banner says the screens show.
  DateTime? _showingFrom;
  DateTime? get showingFrom => _showingFrom;

  /// Goes up each time the information is refreshed after coming back online, so screens can
  /// reload.
  int _refreshes = 0;
  int get refreshes => _refreshes;

  void markOnline() {
    _lastOnlineAt = DateTime.now();
    if (!_offline) return;
    _offline = false;
    _showingFrom = null;
    notifyListeners();
  }

  void markOffline() {
    if (_offline) return;
    _offline = true;
    notifyListeners();
  }

  /// A saved copy from [savedAt] is being shown.
  void showedCopyFrom(DateTime savedAt) {
    if (_showingFrom == null || savedAt.isBefore(_showingFrom!)) {
      _showingFrom = savedAt;
      notifyListeners();
    }
  }

  void refreshed() {
    _refreshes++;
    notifyListeners();
  }
}
