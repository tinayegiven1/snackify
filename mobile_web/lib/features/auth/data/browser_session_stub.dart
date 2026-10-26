// Not a web browser (Android, tests): the encrypted store is always available.

bool get browserCanEncrypt => true;

String? readTabSession(String key) => throw UnsupportedError('Only in a web browser');

void writeTabSession(String key, String value) => throw UnsupportedError('Only in a web browser');

void deleteTabSession(String key) => throw UnsupportedError('Only in a web browser');
