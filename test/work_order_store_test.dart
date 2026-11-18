import 'package:flutter_test/flutter_test.dart';
import 'package:sandan_facility_app/data/local_database.dart';
import 'package:sandan_facility_app/data/work_order_store.dart';
import 'package:sandan_facility_app/models/work_order.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/work_order_payload.dart';

/// SPEC-024 Phase 2, Step 2 — the cache, and the scope it must not lose.
///
/// 🔴 **The test that carries this phase is `invisible to another user`.** A
/// cache written while one technician was signed in sits on the disk after he
/// signs out; ADR-012's scope is a **server** fact, and these tests are what
/// make it a device fact as well.
void main() {
  sqfliteFfiInit();

  late LocalDatabase database;
  late WorkOrderStore store;

  setUp(() {
    database = LocalDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    store = WorkOrderStore(database);
  });

  tearDown(() => database.close());

  final syncedAt = DateTime.utc(2026, 10, 28, 8, 40);

  WorkOrder order({String id = 'job-1', String? reference = 'MS-2026-000042'}) =>
      WorkOrder.fromJson(workOrderJson(id: id, reference: reference));

  test('a cached row is read back through the SAME decoder that wrote it', () async {
    await store.replaceFor(7, [order()], syncedAt: syncedAt);

    final rows = await store.rowsFor(7);

    expect(rows, hasLength(1));
    // Every field the screen uses, read from disk rather than from HTTP.
    expect(rows.single.id, 'job-1');
    expect(rows.single.reference, 'MS-2026-000042');
    expect(rows.single.status.label, 'Assigned');
    expect(rows.single.priority.label, 'High');
    expect(rows.single.location, 'Unit 1/E101');
    expect(rows.single.sla.hasBreached, isFalse);
  });

  test('🔴 rows cached for one user are INVISIBLE to another', () async {
    await store.replaceFor(7, [order(id: 'belongs-to-7')], syncedAt: syncedAt);

    // Technician 8 signs in on the same phone. The server would never return
    // this row for him; neither may the disk.
    expect(await store.rowsFor(8), isEmpty);
    expect(await store.rowFor(8, 'belongs-to-7'), isNull);
    expect(await store.syncedAtFor(8), isNull);
  });

  test('🔴 signing in drops every OTHER user\'s cache, even if sign-out never ran', () async {
    await store.replaceFor(7, [order(id: 'belongs-to-7')], syncedAt: syncedAt);

    // The app was killed before `logout()` could run. The next man signs in.
    await store.dropCacheExcept(8);

    expect(await store.rowsFor(7), isEmpty);
    expect(await store.syncedAtFor(7), isNull);
  });

  test('signing out clears this user and leaves a pending outbox item alone', () async {
    await store.replaceFor(7, [order()], syncedAt: syncedAt);

    final db = await database.open();
    await db.insert('outbox', {
      'user_id': 7,
      'method': 'PATCH',
      'path': '/api/facility/work-orders/job-1/complete',
      'body': null,
      'created_at': syncedAt.toIso8601String(),
    });

    await store.clearCacheFor(7);

    expect(await store.rowsFor(7), isEmpty);
    expect(await store.syncedAtFor(7), isNull);
    // 🔴 D3: a cache is a copy of something the server has; a queued action
    // exists NOWHERE else. Clearing it on sign-out would destroy a
    // technician's only record of work he actually finished.
    expect(await db.query('outbox'), hasLength(1));
  });

  test('a replace removes a row the next sync no longer returns', () async {
    await store.replaceFor(7, [order(id: 'a'), order(id: 'b')], syncedAt: syncedAt);

    // 🎯 Job `b` was reassigned to somebody else, so the server stops
    // returning it. It must disappear from this phone — a merge would have
    // left him working on a job that is no longer his.
    await store.replaceFor(7, [order(id: 'a')], syncedAt: syncedAt);

    expect((await store.rowsFor(7)).map((o) => o.id), ['a']);
  });

  test('the server\'s order is preserved, not re-sorted here', () async {
    await store.replaceFor(
      7,
      [order(id: 'third'), order(id: 'first'), order(id: 'second')],
      syncedAt: syncedAt,
    );

    expect((await store.rowsFor(7)).map((o) => o.id), ['third', 'first', 'second']);
  });

  test('🔴 an interrupted replace leaves the PREVIOUS rows, never an empty list', () async {
    await store.replaceFor(7, [order(id: 'real-job')], syncedAt: syncedAt);

    // A row whose payload cannot be encoded makes the insert throw **inside**
    // the transaction — the nearest a test can get to a process dying halfway
    // through the replace.
    final poisoned = WorkOrder.fromJson({
      ...workOrderJson(id: 'poisoned'),
      'unencodable': Object(),
    });

    await expectLater(
      store.replaceFor(7, [poisoned], syncedAt: syncedAt),
      throwsA(anything),
    );

    // 🎯 An empty list is the most reassuring possible lie: on this screen it
    // reads as "no work orders are assigned to you right now".
    expect((await store.rowsFor(7)).map((o) => o.id), ['real-job']);
  });

  test('syncedAt is what the app recorded, to the minute', () async {
    await store.replaceFor(7, [order()], syncedAt: syncedAt);

    expect(await store.syncedAtFor(7), syncedAt.toLocal());
  });

  test('evict removes exactly the row the server refused', () async {
    await store.replaceFor(7, [order(id: 'mine'), order(id: 'not-mine')], syncedAt: syncedAt);

    // D6: the server has just answered 403 for `not-mine`. A cached copy that
    // survives that answer is the scope leak with a longer fuse.
    await store.evict(7, 'not-mine');

    expect((await store.rowsFor(7)).map((o) => o.id), ['mine']);
    expect(await store.rowFor(7, 'not-mine'), isNull);
  });

  test('a job assigned to two technicians is cached for both', () async {
    await store.replaceFor(7, [order(id: 'shared')], syncedAt: syncedAt);
    await store.replaceFor(8, [order(id: 'shared')], syncedAt: syncedAt);

    // ⚠️ The primary key is (id, user_id). Keyed on `id` alone, user 8's sync
    // would have silently emptied user 7's list.
    expect(await store.rowFor(7, 'shared'), isNotNull);
    expect(await store.rowFor(8, 'shared'), isNotNull);
  });
}
