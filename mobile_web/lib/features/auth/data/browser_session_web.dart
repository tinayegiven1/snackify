import 'package:web/web.dart' as web;

/// False on a plain-http page reached by a network address (e.g. http://192.168.1.44:3000):
/// browsers then switch off WebCrypto, which the encrypted token store needs.
bool get browserCanEncrypt => web.window.isSecureContext;

String? readTabSession(String key) => web.window.sessionStorage.getItem(key);

void writeTabSession(String key, String value) => web.window.sessionStorage.setItem(key, value);

void deleteTabSession(String key) => web.window.sessionStorage.removeItem(key);
