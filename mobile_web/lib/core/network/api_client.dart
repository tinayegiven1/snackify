import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Thrown when the API cannot be reached or returns an error response.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.code = 'UNKNOWN', this.fieldErrors = const {}});

  /// Shown to the user. The backend writes these in plain language.
  final String message;
  final int? statusCode;

  /// The backend's error code, e.g. INVALID_CREDENTIALS, or NETWORK_ERROR when unreachable.
  final String code;

  /// Problems with individual fields, e.g. {'sku': 'Already used by another product'}.
  final Map<String, String> fieldErrors;

  bool get isNetworkError => code == networkErrorCode;

  static const networkErrorCode = 'NETWORK_ERROR';

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}

/// Thin wrapper around HTTP calls to the Snackify backend.
/// UI widgets should not call this directly; use a feature repository or service instead.
class ApiClient {
  ApiClient({required String baseUrl, http.Client? httpClient})
    : _baseUrl = baseUrl,
      _http = httpClient ?? http.Client();

  final String _baseUrl;
  final http.Client _http;

  static const _timeout = Duration(seconds: 10);

  /// Session token sent as "Authorization: Bearer ..." while signed in.
  String? authToken;

  /// Called when a signed-in request is rejected with 401 (session expired, signed out
  /// elsewhere, or account deactivated).
  VoidCallback? onSessionExpired;

  Future<Map<String, dynamic>> getJson(String path) => _send('GET', path);

  Future<Map<String, dynamic>> postJson(String path, [Map<String, Object?>? body]) =>
      _send('POST', path, body);

  Future<Map<String, dynamic>> patchJson(String path, Map<String, Object?> body) =>
      _send('PATCH', path, body);

  Future<Map<String, dynamic>> putJson(String path, Map<String, Object?> body) =>
      _send('PUT', path, body);

  /// Uploads a file as the raw request body (e.g. a supplier invoice) and returns the JSON
  /// answer. The server decides the file's type from its content, not from [contentType].
  Future<Map<String, dynamic>> postBytes(
    String path,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
  }) => _send('POST', path, _RawBody(bytes, contentType));

  /// Downloads a file, e.g. an invoice PDF. Errors are reported like those of JSON requests.
  Future<Uint8List> getBytes(String path, {String accept = 'application/octet-stream'}) async {
    final response = await _request('GET', path, accept: accept);
    return response.bodyBytes;
  }

  Future<Map<String, dynamic>> _send(String method, String path, [Object? body]) async {
    final response = await _request(
      method,
      path,
      body: body,
      // Uploads can be several megabytes on a slow connection.
      timeout: body is _RawBody ? const Duration(seconds: 120) : _timeout,
    );

    // 204 No Content and other empty successes.
    if (response.body.isEmpty) return const {};

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw ApiException('The server sent an invalid response.', statusCode: response.statusCode);
    }
    if (decoded is! Map<String, dynamic>) {
      throw ApiException(
        'The server sent an unexpected response.',
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  /// Sends a request and returns the successful response; throws [ApiException] otherwise.
  Future<http.Response> _request(
    String method,
    String path, {
    Object? body,
    String accept = 'application/json',
    Duration timeout = _timeout,
  }) async {
    final request = http.Request(method, Uri.parse('$_baseUrl$path'))..headers['Accept'] = accept;
    if (body is _RawBody) {
      request.headers['Content-Type'] = body.contentType;
      request.bodyBytes = body.bytes;
    } else if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final token = authToken;
    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }

    final http.Response response;
    try {
      response = await _http.send(request).then(http.Response.fromStream).timeout(timeout);
    } on Exception {
      throw ApiException(
        'Cannot reach the Snackify server. Check your connection and try again.',
        code: ApiException.networkErrorCode,
      );
    }

    if (response.statusCode == 401 && token != null) {
      onSessionExpired?.call();
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      Object? decoded;
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        decoded = null; // Not the backend's JSON error shape; report the HTTP status instead.
      }
      throw _errorFrom(decoded, response.statusCode);
    }
    return response;
  }

  /// Reads the backend's standard error shape:
  /// { "error": { "code", "message", "details": [{ "field", "message" }] } }.
  ApiException _errorFrom(Object? body, int statusCode) {
    if (body is Map<String, dynamic>) {
      final error = body['error'];
      if (error is Map<String, dynamic> && error['message'] is String) {
        final details = error['details'];
        return ApiException(
          error['message'] as String,
          statusCode: statusCode,
          code: error['code'] is String ? error['code'] as String : 'UNKNOWN',
          fieldErrors: {
            if (details is List)
              for (final item in details.whereType<Map<String, dynamic>>())
                if (item['field'] is String && item['message'] is String)
                  item['field'] as String: item['message'] as String,
          },
        );
      }
    }
    return ApiException('The request failed (HTTP $statusCode).', statusCode: statusCode);
  }
}

/// A request body sent as it is (a file), not as JSON.
class _RawBody {
  const _RawBody(this.bytes, this.contentType);

  final Uint8List bytes;
  final String contentType;
}
