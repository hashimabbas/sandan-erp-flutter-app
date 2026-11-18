import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// SPEC-024 Phase 1, Step 1 — the one place the session lives.
///
/// Before this, `'facility_token'` was declared as a private `static const` in
/// **both** `AuthService` and `ComplaintService`. Phase 1 adds a third reader,
/// and three copies of one string is a change waiting to be made in two places
/// out of three.
///
/// This is the same argument the ERP made for `scopePayableBy()` and
/// `scopeVisibleTo()` one layer down: when a question has more than one reader,
/// it gets one home — and it gets it the day the second reader appears, not
/// after they disagree.
class FacilitySession {
  FacilitySession({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const tokenKey = 'facility_token';
  static const userKey = 'facility_user';

  final FlutterSecureStorage _storage;

  /// Returns null when there is no session **and** when secure storage is
  /// unavailable at all — a test environment has no platform channel, and a
  /// caller cannot act differently on the two cases anyway.
  Future<String?> readToken() async {
    try {
      return await _storage.read(key: tokenKey);
    } catch (_) {
      return null;
    }
  }

  Future<String?> readUserJson() async {
    try {
      return await _storage.read(key: userKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> write({required String token, required String userJson}) async {
    await _storage.write(key: tokenKey, value: token);
    await _storage.write(key: userKey, value: userJson);
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: tokenKey);
      await _storage.delete(key: userKey);
    } catch (_) {
      // Nothing stored, or no backend — either way there is no session left.
    }
  }

  /// The headers every authenticated call carries. `Authorization` is omitted
  /// rather than sent empty when there is no token, so the server answers 401
  /// instead of parsing a malformed header.
  Future<Map<String, String>> authHeaders() async {
    final token = await readToken();

    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }
}
