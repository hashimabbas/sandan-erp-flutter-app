import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../data/local_database.dart';
import '../data/work_order_store.dart';
import '../models/facility_user.dart';
import 'facility_session.dart';

class AuthResult {
  const AuthResult({required this.success, this.message, this.user});

  final bool success;
  final String? message;
  final FacilityUser? user;
}

/// Talks to SPEC-003's `/api/facility/login` and `/api/facility/logout`
/// endpoints and persists the resulting token + user via secure storage, so
/// a session survives an app restart — matching the Spec's "indefinite but
/// immediately revocable" session decision.
class AuthService {
  AuthService({FacilitySession? session, WorkOrderStore? cache})
      : _session = session ?? FacilitySession(),
        _cache = cache ?? WorkOrderStore(LocalDatabase.instance);

  /// SPEC-024 Phase 1, Step 1 — `'facility_token'` used to be declared here
  /// AND in `ComplaintService`, and Phase 1 added a third reader. The key and
  /// the headers now live in one place; this class keeps the session's
  /// lifecycle and no longer owns where it is kept.
  final FacilitySession _session;

  /// 🔴 **SPEC-024 Phase 2 (D2) — the session is not the only thing a sign-out
  /// has to end.** Until Phase 2 this class cleared two secure-storage keys
  /// and that was the whole of a sign-out. With work orders cached on the
  /// device, the next man to sign in on that phone would have opened *My Work*
  /// to a list the server would have refused him — real rows, right layout,
  /// and the only thing wrong being **whose** they are.
  ///
  /// ⚠️ It clears the **cache** and never the **outbox**. A cached job is a
  /// copy of something the server has; a queued action exists nowhere else,
  /// and deleting it would destroy a technician's only record of work he
  /// finished with no signal (D3).
  final WorkOrderStore _cache;

  Future<AuthResult> login({
    required String email,
    required String password,
  }) async {
    final Uri uri = Uri.parse('${ApiConfig.baseUrl}/api/facility/login');

    http.Response response;
    try {
      response = await http.post(
        uri,
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'email': email.trim(), 'password': password}),
      );
    } catch (_) {
      return const AuthResult(
        success: false,
        message: 'Could not reach the server. Check your connection.',
      );
    }

    final body = _decode(response.body);

    if (response.statusCode == 200 && body != null) {
      final user = FacilityUser.fromJson(body['user'] as Map<String, dynamic>);
      await _session.write(
        token: body['token'] as String,
        userJson: jsonEncode(user.toJson()),
      );
      await dropOtherUsersCachedWork(user.id);

      return AuthResult(success: true, user: user);
    }

    if (response.statusCode == 422 && body != null) {
      final errors = body['errors'] as Map<String, dynamic>?;
      final message = errors?['email']?.first as String? ?? 'Invalid credentials.';
      return AuthResult(success: false, message: message);
    }

    return const AuthResult(
      success: false,
      message: 'Something went wrong. Please try again.',
    );
  }

  /// SPEC-024 Phase 4, Step 2 — the one thing about a password a field user
  /// can do for himself.
  ///
  /// 🔴 **Not queued, and it must never be.** An act in the outbox is field
  /// work the server has not heard yet; a password change offline simply
  /// cannot happen, and queueing it would mean a man believing his password
  /// changed hours before it did — then finding the old one still works. The
  /// screen says *"you need a connection for this"* instead.
  ///
  /// ⚠️ The server requires the CURRENT password as well as the token,
  /// because this project's Sanctum tokens never expire.
  Future<AuthResult> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    http.Response response;

    try {
      response = await http.put(
        Uri.parse('${ApiConfig.baseUrl}/api/facility/password'),
        headers: await _session.authHeaders(),
        body: jsonEncode({
          'current_password': currentPassword,
          'password': newPassword,
          // The server validates `confirmed`, so the confirmation travels with
          // it — the screen has already matched the two fields, and sending
          // only one would turn the server's own rule into a 422 nobody
          // expected.
          'password_confirmation': newPassword,
        }),
      );
    } catch (_) {
      return const AuthResult(
        success: false,
        message: 'Could not reach the server. Check your connection.',
      );
    }

    if (response.statusCode == 200) {
      return const AuthResult(success: true, message: 'Password updated.');
    }

    if (response.statusCode == 401) {
      return const AuthResult(
        success: false,
        message: 'Your session has ended. Please sign in again.',
      );
    }

    final body = _decode(response.body);

    if (response.statusCode == 422 && body != null) {
      // 🔴 The SERVER's sentence, per field — `errors.<field>[0]`, the
      // contract SPEC-018 Phase 10 Step 2 built. "The password field must be
      // at least 8 characters" is written for a person; anything this app
      // wrote instead would be a second description of the same rule.
      final errors = body['errors'] as Map<String, dynamic>?;
      final first = errors?.values.first;

      return AuthResult(
        success: false,
        message: first is List && first.isNotEmpty
            ? first.first.toString()
            : (body['message'] as String? ?? 'The server refused that password.'),
      );
    }

    if (response.statusCode == 429) {
      // ⚠️ The endpoint is throttled at 6 a minute, like the web's. Said in
      // words, because a silent failure here reads as "my password is wrong".
      return const AuthResult(
        success: false,
        message: 'Too many attempts. Wait a minute and try again.',
      );
    }

    return const AuthResult(
      success: false,
      message: 'Something went wrong. Please try again.',
    );
  }

  Future<void> logout() async {
    final token = await _session.readToken();
    if (token != null) {
      try {
        await http.post(
          Uri.parse('${ApiConfig.baseUrl}/api/facility/logout'),
          headers: {
            'Accept': 'application/json',
            'Authorization': 'Bearer $token',
          },
        );
      } catch (_) {
        // Best-effort server-side revocation — clear the local session
        // regardless so the user is signed out on this device either way.
      }
    }
    await _clearCachedWork();
    await _session.clear();
  }

  /// SPEC-024 Phase 1 (D6) — what the app does when the ERP stops accepting
  /// the token. `restoreSession()` below has always promised the token is
  /// *"trusted until an authenticated request comes back 401"*, and until now
  /// **nothing fulfilled that promise**: no screen handled a 401, so a
  /// technician whose token was revoked saw a list that failed to load and no
  /// explanation.
  ///
  /// ⚠️ A 403 must NEVER reach this. It means *this job is not yours*, which
  /// Phase 0 returns deliberately — signing a man out for tapping the wrong
  /// row would be a bug wearing a security badge.
  Future<void> endExpiredSession() async {
    await _clearCachedWork();
    await _session.clear();
  }

  /// Reads who is signed in **before** the session is cleared — afterwards
  /// there is nothing left to say whose cache to drop.
  ///
  /// ⚠️ Failures are swallowed deliberately: a sign-out that refuses to finish
  /// because a database could not be opened would leave a man signed in, which
  /// is worse than a cache that outlives its session by one sign-in — and
  /// [dropOtherUsersCachedWork] catches exactly that case on the way back in.
  Future<void> _clearCachedWork() async {
    try {
      final userJson = await _session.readUserJson();
      if (userJson == null) return;

      final user = FacilityUser.fromJson(jsonDecode(userJson) as Map<String, dynamic>);

      await _cache.clearCacheFor(user.id);
    } catch (_) {
      // No store, no stored user, or no database — nothing cached to clear.
    }
  }

  /// 🔴 Called on a successful sign-in. Drops every **other** user's cached
  /// work before the first read, because a sign-out that never completed — a
  /// killed app, a flat battery — must not leave the next man looking at
  /// another technician's jobs.
  Future<void> dropOtherUsersCachedWork(int userId) async {
    try {
      await _cache.dropCacheExcept(userId);
    } catch (_) {
      // See above: a device without a working database has no cache to leak.
    }
  }

  /// Restores a previously stored session (no network call — the token is
  /// trusted until an authenticated request comes back 401).
  Future<FacilityUser?> restoreSession() async {
    try {
      final token = await _session.readToken();
      final userJson = await _session.readUserJson();
      if (token == null || userJson == null) return null;
      return FacilityUser.fromJson(jsonDecode(userJson) as Map<String, dynamic>);
    } catch (_) {
      // No secure-storage backend available (e.g. in a test environment) —
      // treat it the same as "no stored session".
      return null;
    }
  }

  Map<String, dynamic>? _decode(String body) {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}
