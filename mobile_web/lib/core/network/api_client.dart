import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thrown when the API cannot be reached or returns an error response.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thin wrapper around HTTP calls to the Snackify backend.
/// UI widgets should not call this directly; use a feature service instead.
class ApiClient {
  ApiClient({required String baseUrl, http.Client? httpClient})
    : _baseUrl = baseUrl,
      _http = httpClient ?? http.Client();

  final String _baseUrl;
  final http.Client _http;

  static const _timeout = Duration(seconds: 5);

  Future<Map<String, dynamic>> getJson(String path) async {
    final http.Response response;
    try {
      response = await _http
          .get(Uri.parse('$_baseUrl$path'), headers: {'Accept': 'application/json'})
          .timeout(_timeout);
    } on Exception catch (error) {
      throw ApiException('Could not reach the Snackify API: $error');
    }

    final Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      throw ApiException('The API returned an invalid response.', statusCode: response.statusCode);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(_errorMessage(body), statusCode: response.statusCode);
    }
    if (body is! Map<String, dynamic>) {
      throw ApiException(
        'The API returned an unexpected response.',
        statusCode: response.statusCode,
      );
    }
    return body;
  }

  /// Reads the backend's standard error shape: { "error": { "code", "message" } }.
  String _errorMessage(Object? body) {
    if (body is Map<String, dynamic>) {
      final error = body['error'];
      if (error is Map<String, dynamic> && error['message'] is String) {
        return error['message'] as String;
      }
    }
    return 'The API request failed.';
  }
}
