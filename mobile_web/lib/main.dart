import 'package:flutter/material.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/network/api_client.dart';
import 'core/network/backend_health_service.dart';

void main() {
  final healthService = BackendHealthService(ApiClient(baseUrl: AppConfig.apiBaseUrl));
  runApp(SnackifyApp(checkBackendHealth: healthService.isHealthy));
}
