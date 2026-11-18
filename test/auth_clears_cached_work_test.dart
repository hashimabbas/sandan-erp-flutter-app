import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sandan_facility_app/data/local_database.dart';
import 'package:sandan_facility_app/data/outbox.dart';
import 'package:sandan_facility_app/data/work_order_store.dart';
import 'package:sandan_facility_app/models/work_order.dart';
import 'package:sandan_facility_app/services/auth_service.dart';
import 'package:sandan_facility_app/services/facility_session.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/work_order_payload.dart';

/// SPEC-024 Phase 2, Step 5 — 🔴 **the hole the Impact Analysis found, closed
/// and then tested.**
///
/// Before Phase 2, a sign-out cleared **two secure-storage keys** and that was
/// all of it. With work orders cached on the device, the next man to sign in
/// on that phone would have opened *My Work* to a list the server would have
/// refused him: real rows, the right layout, and the only thing wrong being
/// **whose** they are.
///
/// ⚠️ And the mirror rule, which is a different rule: the **outbox** survives
/// a sign-out. A cached job is a copy of something the server has; a queued
/// action exists nowhere else, and clearing it would destroy a technician's
/// only record of work he finished with no signal (D3).
void main() {
  sqfliteFfiInit();
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDatabase database;
  late WorkOrderStore store;
  late Outbox outbox;

  setUp(() {
    database = LocalDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    store = WorkOrderStore(database);
    outbox = Outbox(database);

    FlutterSecureStorage.setMockInitialValues({
      FacilitySession.tokenKey: 'a-token',
      FacilitySession.userKey: jsonEncode({'id': 7, 'name': 'Fathi', 'role': 'technician'}),
    });
  });

  tearDown(() => database.close());

  AuthService authService() => AuthService(session: FacilitySession(), cache: store);

  Future<void> seedCachedWork() => store.replaceFor(
        7,
        [WorkOrder.fromJson(workOrderJson(id: 'sevens-job'))],
        syncedAt: DateTime(2026, 10, 28, 8, 40),
      );

  test('🔴 signing out clears this user\'s cached work', () async {
    await seedCachedWork();

    await authService().logout();

    expect(await store.rowsFor(7), isEmpty);
    expect(await store.syncedAtFor(7), isNull);
  });

  test('🔴 an expired session clears it too — both doors, not one', () async {
    await seedCachedWork();

    // ⚠️ Two places end a session, and a rule applied in one of them is the
    // exact shape of the finding this phase opened with: a scope enforced
    // once and forgotten once **reads as done**.
    await authService().endExpiredSession();

    expect(await store.rowsFor(7), isEmpty);
  });

  test('🔴 a pending outbox item SURVIVES the sign-out', () async {
    await seedCachedWork();
    await outbox.enqueue(
      userId: 7,
      method: 'PATCH',
      path: '/api/facility/work-orders/sevens-job/complete',
      body: {'notes': 'Finished in the basement, no signal.'},
    );

    await authService().logout();

    final survivor = (await outbox.pending(7)).single;

    expect(survivor.path, '/api/facility/work-orders/sevens-job/complete');
    expect(survivor.userId, 7);
  });

  test('signing in drops another user\'s cached work', () async {
    await store.replaceFor(
      8,
      [WorkOrder.fromJson(workOrderJson(id: 'eights-job'))],
      syncedAt: DateTime(2026, 10, 28, 8, 40),
    );

    // The app was killed before `logout()` ran; technician 7 signs in.
    await authService().dropOtherUsersCachedWork(7);

    expect(await store.rowsFor(8), isEmpty);
  });

  test('a sign-out with nothing cached still ends the session', () async {
    // ⚠️ A sign-out that refused to finish because a database could not be
    // opened would leave a man signed in, which is worse than a cache that
    // outlives its session by one sign-in.
    await authService().logout();

    expect(await FacilitySession().readToken(), isNull);
  });
}
