import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/work_order.dart';
import 'local_database.dart';

/// SPEC-024 Phase 2, Step 2 — the work orders this phone has been told about.
///
/// 🔴 **The finding this class exists to not commit.** ADR-012 settled that
/// what a technician may see is his **assignment**, and the server enforces it
/// with `Complaint::scopeVisibleTo()`. A cache turns that server fact into a
/// **device** fact: rows written while one man was signed in sit on the disk
/// after he signs out, and the next man would open *My Work* to a list the
/// server would have refused him — before any fetch returned.
///
/// ✅ So the scope is enforced **twice, on purpose**:
///
/// 1. Every row carries its `user_id` and **every read filters by it**.
/// 2. A change of identity **drops** the other user's rows ([dropCacheExcept]).
///
/// Belt and braces, because (2) is a one-off action that can fail and (1) is a
/// property of every query. ADR-012's whole lesson is that a scope applied in
/// one place and forgotten in another **reads as done**.
///
/// ⚠️ **This class never touches `outbox`.** A cache is a copy of something the
/// server has; a queued action exists **nowhere else**, and deleting it on
/// sign-out would destroy a technician's only record of work he finished.
/// Architecture Review D3.
class WorkOrderStore {
  WorkOrderStore(this._database);

  final LocalDatabase _database;

  /// Replaces everything this user has cached, in **one transaction**.
  ///
  /// 🔴 Atomic or nothing. A delete-then-insert that is interrupted leaves an
  /// **empty** list, which on this screen looks exactly like *"no work orders
  /// are assigned to you right now"* — a lie in the most reassuring possible
  /// form.
  ///
  /// 🎯 It **replaces** rather than merges because the endpoint returns the
  /// full scoped set with no cursor and no deletion feed: a job reassigned away
  /// from this technician simply stops being returned, and must therefore
  /// disappear from his phone. A merge would have to infer that from absence,
  /// which is what a replace does without the inference (D4).
  ///
  /// 🔧 **CORRECTED 2026-11-18 (SPEC-024 Phase 5, Step 0). The sentence above
  /// was false when it was written, and so was D4's version of it.** The
  /// endpoint has **paginated at 20 since Phase 0's own first commit**; what it
  /// returns is page one of N. This class was therefore being handed twenty
  /// rows and deleting the rest — a merge would merely have failed to add
  /// them. ⚠️ **The behaviour was right; only the premise was wrong**, so
  /// nothing here changed: `WorkOrderService.fetchMyWork()` now walks every
  /// page and returns the complete set **or a failure**, so what reaches this
  /// method really is the full scoped set. ❌ A partial result must never be
  /// passed to it.
  Future<void> replaceFor(
    int userId,
    List<WorkOrder> orders, {
    required DateTime syncedAt,
  }) async {
    final db = await _database.open();

    await db.transaction((txn) async {
      await txn.delete('work_orders', where: 'user_id = ?', whereArgs: [userId]);

      for (var position = 0; position < orders.length; position++) {
        await txn.insert('work_orders', {
          'id': orders[position].id,
          'user_id': userId,
          // The server's own payload — see `WorkOrder.source`.
          'payload': jsonEncode(orders[position].source),
          // ⚠️ The server's order is kept as given. "Newest first" is the
          // ERP's answer, not the app's, and re-sorting here would be a second
          // one.
          'position': position,
        });
      }

      await txn.insert(
        'sync_state',
        {'user_id': userId, 'synced_at': syncedAt.toUtc().toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<List<WorkOrder>> rowsFor(int userId) async {
    final db = await _database.open();

    final rows = await db.query(
      'work_orders',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'position',
    );

    return rows
        .map((row) => WorkOrder.fromJson(
              jsonDecode(row['payload'] as String) as Map<String, dynamic>,
            ))
        .toList(growable: false);
  }

  Future<WorkOrder?> rowFor(int userId, String id) async {
    final db = await _database.open();

    final rows = await db.query(
      'work_orders',
      where: 'user_id = ? AND id = ?',
      whereArgs: [userId, id],
      limit: 1,
    );

    if (rows.isEmpty) return null;

    return WorkOrder.fromJson(
      jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>,
    );
  }

  /// When the app last heard from the server for this user, or null if it never
  /// has. ⚠️ Not when the server computed anything — D5 names the reference
  /// precisely, because this project has already shipped one figure that was
  /// true once and presented as current.
  Future<DateTime?> syncedAtFor(int userId) async {
    final db = await _database.open();

    final rows = await db.query(
      'sync_state',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );

    if (rows.isEmpty) return null;

    return DateTime.tryParse(rows.single['synced_at'] as String)?.toLocal();
  }

  /// Writes one refreshed row back without disturbing the rest of the list —
  /// the detail screen fetches a single job and must not drop the other nine.
  ///
  /// ⚠️ Not in the Plan, and added while building Step 4: without it a detail
  /// refresh would either leave the cache stale or force a full replace from a
  /// payload that only ever described one job.
  Future<void> upsert(int userId, WorkOrder order) async {
    final db = await _database.open();

    await db.transaction((txn) async {
      final existing = await txn.query(
        'work_orders',
        columns: ['position'],
        where: 'user_id = ? AND id = ?',
        whereArgs: [userId, order.id],
        limit: 1,
      );

      // A job fetched by id that is not in the list yet goes to the end — it
      // has no place in an order the server never gave it.
      final position = existing.isNotEmpty
          ? existing.single['position'] as int
          : ((await txn.rawQuery(
                'SELECT COALESCE(MAX(position), -1) + 1 AS next FROM work_orders WHERE user_id = ?',
                [userId],
              )).single['next'] as int);

      await txn.insert(
        'work_orders',
        {
          'id': order.id,
          'user_id': userId,
          'payload': jsonEncode(order.source),
          'position': position,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Removes one row from this user's cache — D6: the server has just answered
  /// **403** for it, and a cached copy that survives that answer is the leak
  /// above with a longer fuse.
  Future<void> evict(int userId, String id) async {
    final db = await _database.open();

    await db.delete('work_orders', where: 'user_id = ? AND id = ?', whereArgs: [userId, id]);
  }

  /// Sign-out. Clears the cache **and the sync time** for this user, and
  /// nothing else. ⚠️ Not the outbox (D3).
  Future<void> clearCacheFor(int userId) async {
    final db = await _database.open();

    await db.transaction((txn) async {
      await txn.delete('work_orders', where: 'user_id = ?', whereArgs: [userId]);
      await txn.delete('sync_state', where: 'user_id = ?', whereArgs: [userId]);
    });
  }

  /// Sign-in. 🔴 Drops every **other** user's cached rows before the first
  /// read, because a sign-out that never completed — a killed app, a flat
  /// battery — must not leave the next man looking at another technician's
  /// work.
  Future<void> dropCacheExcept(int userId) async {
    final db = await _database.open();

    await db.transaction((txn) async {
      await txn.delete('work_orders', where: 'user_id != ?', whereArgs: [userId]);
      await txn.delete('sync_state', where: 'user_id != ?', whereArgs: [userId]);
    });
  }
}
