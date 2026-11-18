import 'dart:io' show Platform;

/// Points the app at the Sandan ERP backend (SPEC-003's `/api/facility/*`
/// routes). Physical Android devices can't reach the host machine via
/// `localhost` or the emulator-only `10.0.2.2` alias, so this uses the
/// host's LAN IP — update it if the dev machine's IP changes.
class ApiConfig {
  ApiConfig._();

  static String get baseUrl {
    if (!Platform.isAndroid) return 'http://localhost:8000';
    return 'http://192.168.100.13:8000';
  }
}
