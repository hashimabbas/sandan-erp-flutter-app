import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sandan_facility_app/data/local_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// SPEC-024 Phase 2, Step 1 — the schema, proved without a device.
///
/// 🔴 These tests run against the **FFI** factory and an in-memory database.
/// `flutter test` has no platform channels, so the native `sqflite` library
/// does not exist here; the factory is injected for exactly this reason
/// (Architecture Review D9).
void main() {
  sqfliteFfiInit();

  LocalDatabase newDatabase() => LocalDatabase(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );

  test('creates all three tables at the current schema version', () async {
    final database = newDatabase();
    final db = await database.open();

    final tables = (await db.query('sqlite_master', columns: ['name'], where: "type = 'table'"))
        .map((row) => row['name'] as String)
        .toSet();

    expect(tables, containsAll(<String>['work_orders', 'sync_state', 'outbox']));
    expect(await db.getVersion(), LocalDatabase.schemaVersion);

    await database.close();
  });

  test('a work order row keeps a TEXT uuid and an INTEGER user', () async {
    final database = newDatabase();
    final db = await database.open();

    // 🔴 The two id types the Phase 1 Plan §0.3 warned about, now asserted:
    // a char(36) uuid and a bigint user id in one row.
    await db.insert('work_orders', {
      'id': '9f8b7c16-4d2e-4a11-9c3f-2b5e6a7d8c90',
      'user_id': 7,
      'payload': '{"id":"9f8b7c16-4d2e-4a11-9c3f-2b5e6a7d8c90"}',
      'position': 0,
    });

    final rows = await db.query('work_orders');

    expect(rows, hasLength(1));
    expect(rows.single['id'], isA<String>());
    expect(rows.single['user_id'], isA<int>());

    await database.close();
  });

  test('the same work order may be cached for two different users', () async {
    final database = newDatabase();
    final db = await database.open();

    // ⚠️ The primary key is (id, user_id), not id. A job assigned to two
    // technicians is one row on the server and one row **per man** here, and a
    // bare `id` key would have made the second insert overwrite the first —
    // silently emptying one technician's list when the other synced.
    for (final userId in [7, 8]) {
      await db.insert('work_orders', {
        'id': 'shared-job',
        'user_id': userId,
        'payload': '{}',
        'position': 0,
      });
    }

    expect(await db.query('work_orders'), hasLength(2));

    await database.close();
  });

  test('an outbox item gets its order from the autoincrementing id', () async {
    final database = newDatabase();
    final db = await database.open();

    for (final path in ['/a/start', '/b/complete', '/c/refer']) {
      await db.insert('outbox', {
        'user_id': 7,
        'method': 'PATCH',
        'path': path,
        'body': null,
        'created_at': DateTime.utc(2026, 10, 28).toIso8601String(),
      });
    }

    final ids = (await db.query('outbox', orderBy: 'id')).map((r) => r['id']).toList();

    expect(ids, [1, 2, 3]);
    // `attempts` must default without the caller supplying it, because the
    // drain increments it and never initialises it.
    expect((await db.query('outbox', where: 'id = 1')).single['attempts'], 0);

    await database.close();
  });

  test('sync_state holds one row per user', () async {
    final database = newDatabase();
    final db = await database.open();

    await db.insert('sync_state', {
      'user_id': 7,
      'synced_at': DateTime.utc(2026, 10, 28, 8, 40).toIso8601String(),
    });

    expect((await db.query('sync_state')).single['synced_at'], '2026-10-28T08:40:00.000Z');

    await database.close();
  });

  test('open() is memoised, so two callers racing at startup share a connection', () async {
    final database = newDatabase();

    final results = await Future.wait([database.open(), database.open()]);

    expect(results.first, same(results.last));

    await database.close();
  });

  group('schema v1 -> v2 (SPEC-024 Phase 3, Step 2)', () {
    /// A v1 database, built exactly as Phase 2 shipped it.
    Future<void> createV1(String path) async {
      final db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('CREATE TABLE work_orders (id TEXT NOT NULL, user_id INTEGER NOT NULL, payload TEXT NOT NULL, position INTEGER NOT NULL, PRIMARY KEY (id, user_id))');
            await db.execute('CREATE TABLE sync_state (user_id INTEGER PRIMARY KEY, synced_at TEXT NOT NULL)');
            await db.execute('CREATE TABLE outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, method TEXT NOT NULL, path TEXT NOT NULL, body TEXT, created_at TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT)');
          },
        ),
      );

      await db.insert('outbox', {
        'user_id': 7,
        'method': 'PATCH',
        'path': '/api/facility/work-orders/job-1/complete',
        'body': null,
        'created_at': DateTime.utc(2026, 10, 28).toIso8601String(),
      });

      await db.close();
    }

    test('🔴 upgrades in place and KEEPS a queued item', () async {
      final directory = await Directory.systemTemp.createTemp('sandan_migrate_test');
      final path = '${directory.path}/app.db';

      await createV1(path);

      final upgraded = LocalDatabase(factory: databaseFactoryFfi, path: path);
      final db = await upgraded.open();

      expect(await db.getVersion(), 2);

      // 🎯 The whole reason the migration is additive. The outbox may hold the
      // only record of work a technician actually finished, so a migration
      // that recreated the table would throw real work away.
      final queue = await db.query('outbox');

      expect(queue, hasLength(1));
      expect(queue.single['path'], '/api/facility/work-orders/job-1/complete');
      // The new columns exist and are null on a row that predates them.
      expect(queue.single['job_id'], isNull);
      expect(queue.single['file_path'], isNull);

      await upgraded.close();
      await directory.delete(recursive: true);
    });

    test('a fresh database is created at v2 with the new columns', () async {
      final database = newDatabase();
      final db = await database.open();

      final columns = (await db.rawQuery('PRAGMA table_info(outbox)'))
          .map((row) => row['name'] as String)
          .toSet();

      expect(columns, containsAll(<String>['job_id', 'file_path', 'file_field']));
      expect(await db.getVersion(), 2);

      await database.close();
    });
  });
}
