import 'package:flutter/material.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/network/api_client.dart';
import 'core/network/backend_health_service.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/auth/data/token_store.dart';
import 'features/auth/presentation/auth_controller.dart';

void main() {
  final api = ApiClient(baseUrl: AppConfig.apiBaseUrl);
  final auth = AuthController(AuthRepository(api: api, tokenStore: SecureTokenStore()))..restore();
  final healthService = BackendHealthService(api);
  runApp(SnackifyApp(auth: auth, checkBackendHealth: healthService.isHealthy));
}
