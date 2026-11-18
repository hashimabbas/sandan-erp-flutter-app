import 'dart:convert';

import 'local_database.dart';

/// What a send attempt came back as. ⚠️ Only [sent] lets the queue move on.
enum OutboxDisposition {
  /// 2xx — **or** a replay the server recognised. Phase 0 settled that a
  /// transition replayed to its target state answers **200**, not 422, so a
  /// lost reply costs nothing on the second try.
  sent,

  /// 🔴 **422 — a real refusal, and NOT a sign the action was already
  /// applied.** Phase 0 measured the exception that makes this distinction
  /// load-bearing: a **referral** changes no status, so a replayed `refer` to
  /// a *different* provider is a genuine 422, and a `confirm` with nothing
  /// referred is a genuine 422. A drain that read 422 as "already done" would
  /// delete a queued action that never happened.
  refused,

  /// 401 — the token is finished. The drain stops and the items **stay**.
  sessionExpired,

  /// The request never arrived. Still offline; try again later.
  unreachable,
}

class OutboxSendResult {
  const OutboxSendResult(this.disposition, {this.error});

  final OutboxDisposition disposition;

  /// Recorded against the item so a human can be shown why it is stuck. Null
  /// when there is nothing to say.
  final String? error;
}

class OutboxItem {
  const OutboxItem({
    required this.id,
    required this.userId,
    required this.jobId,
    required this.filePath,
    required this.fileField,
    required this.method,
    required this.path,
    required this.body,
    required this.createdAt,
    required this.attempts,
    required this.lastError,
  });

  factory OutboxItem.fromRow(Map<String, Object?> row) => OutboxItem(
        id: row['id'] as int,
        userId: row['user_id'] as int,
        jobId: row['job_id'] as String?,
        filePath: row['file_path'] as String?,
        fileField: row['file_field'] as String?,
        method: row['method'] as String,
        path: row['path'] as String,
        body: row['body'] == null
            ? null
            : jsonDecode(row['body'] as String) as Map<String, dynamic>,
        createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
        attempts: row['attempts'] as int,
        lastError: row['last_error'] as String?,
      );

  /// 🔴 Also the queue's **order**. §3 Trap 2 of the Spec: `start` then
  /// `complete` is legal and the reverse is not, so this is the lifecycle, not
  /// an optimisation.
  final int id;

  /// 🔴 Whose token queued it. The drain will not send it under anybody
  /// else's — attributing one technician's finished work to another would be a
  /// falsification in the ERP, not a bug in the app.
  final int userId;

  /// 🔴 Which work order this act belongs to — the unit the ordering rule
  /// applies to (D4). Nullable because the column was added in v2 and an
  /// upgraded row may predate it; in practice every act carries one.
  final String? jobId;

  /// A file on this device, queued **on disk** because a photograph does not
  /// belong in a JSON column. ⚠️ It is a COPY in the app's own storage, never
  /// a picker's temporary path, which the OS may delete — a queue item
  /// pointing at nothing is a photograph silently lost.
  final String? filePath;

  /// The multipart field the file is sent as (`photo`).
  final String? fileField;

  final String method;
  final String path;
  final Map<String, dynamic>? body;

  /// How long this action has been sitting on the phone. ⚠️ Recorded, and
  /// **not** acted on: SPEC-024 §6 Q2 — *how long may work stay "recorded on
  /// this phone"?* — is unanswered by Sandan, so this phase invents no expiry
  /// and makes it possible to answer the question with real ages later.
  final DateTime createdAt;

  final int attempts;
  final String? lastError;
}

class DrainReport {
  const DrainReport({
    required this.sent,
    required this.stoppedBy,
    this.remaining = 0,
    this.stalledJobs = const {},
  });

  final int sent;

  /// Why the drain stopped, or null if nothing stopped it.
  ///
  /// ⚠️ With per-job chains (D4) a drain can both **send** and **stop**: one
  /// job's chain stalls while others finish. This reports the first stall's
  /// reason, and [stalledJobs] says where.
  final OutboxDisposition? stoppedBy;

  final int remaining;

  /// The jobs whose chains stopped. 🔴 A `sessionExpired` stops the whole
  /// drain and not one chain, so this stays empty in that case.
  final Set<String?> stalledJobs;
}

/// SPEC-024 Phase 2, Step 3 — the actions this phone has recorded and the
/// server has not heard yet.
///
/// 🎯 **This is the only data in the app that is not a copy of something.** A
/// cached work order can be fetched again; a completion recorded in a basement
/// exists **here and nowhere else** until it drains. That single fact decides
/// everything below: it is why sign-out does not clear it (D3), why it is a
/// SQL table rather than a rewritten JSON file (D1), and why the drain stops
/// at the first unresolved item instead of pressing on.
///
/// ⚠️ **Nothing enqueues into it in this phase.** Phase 3 owns the field
/// actions, so the proof here is a synthetic item — recorded as a real
/// limitation in the Impact Analysis rather than dressed up. The shape is kept
/// deliberately dumb for the same reason: it holds a method, a path and a JSON
/// body, and knows nothing of `start` or `complete`. If Phase 3 has to change
/// it, a small guess is cheap to correct.
class Outbox {
  Outbox(this._database);

  final LocalDatabase _database;

  Future<int> enqueue({
    required int userId,
    required String method,
    required String path,
    String? jobId,
    Map<String, dynamic>? body,
    String? filePath,
    String? fileField,
    DateTime? createdAt,
  }) async {
    final db = await _database.open();

    return db.insert('outbox', {
      'user_id': userId,
      'job_id': jobId,
      'method': method,
      'path': path,
      'body': body == null ? null : jsonEncode(body),
      'file_path': filePath,
      'file_field': fileField,
      'created_at': (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
    });
  }

  /// This user's queue, oldest first. ⚠️ Filtered by owner, like every read in
  /// `WorkOrderStore` — the scope is a property of the query, not of the
  /// caller's memory.
  Future<List<OutboxItem>> pending(int userId) async {
    final db = await _database.open();

    final rows = await db.query(
      'outbox',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'id',
    );

    return rows.map(OutboxItem.fromRow).toList(growable: false);
  }

  Future<int> countFor(int userId) async => (await pending(userId)).length;

  /// Sends what is queued for [userId]: **each job's chain in order, one item
  /// at a time, and a failure stops only THAT job's chain**.
  ///
  /// 🔴 **This refines Phase 2, which drained one global queue and stopped
  /// at the first failure.** The reason for strict order was always the
  /// lifecycle — `start` then `complete` is legal and the reverse is not — and
  /// that reason is about **one job**. Applied globally it did collateral
  /// damage: one stuck item would freeze completions on every other job for
  /// ever, and a technician's whole afternoon would sit behind a single
  /// refusal he might not be able to resolve. Phase 2 could not see it,
  /// because with no writers there was never a second job to block.
  ///
  /// ⚠️ **A 401 still stops everything**, because it is not about a job at
  /// all: the token is finished, so no chain can make progress.
  ///
  /// [send] is a function rather than an HTTP client so these rules can be
  /// proved without a network.
  Future<DrainReport> drain({
    required int userId,
    required Future<OutboxSendResult> Function(OutboxItem item) send,
  }) async {
    final db = await _database.open();
    final queue = await pending(userId);

    var sent = 0;
    OutboxDisposition? firstStall;
    final stalled = <String?>{};

    for (final item in queue) {
      // The chain this item belongs to has already stopped. 🔴 Skipping it is
      // the ordering rule, not an optimisation: sending `complete` after
      // `start` failed would ask the server for a transition it refuses.
      if (stalled.contains(item.jobId)) continue;

      final result = await send(item);

      if (result.disposition == OutboxDisposition.sent) {
        await db.delete('outbox', where: 'id = ?', whereArgs: [item.id]);
        sent++;
        continue;
      }

      // ⚠️ A 401 is not the item's fault, so it costs the item nothing: no
      // attempt is counted and no error recorded against it. The session has
      // ended; the work has not — and no other chain can go anywhere either.
      if (result.disposition == OutboxDisposition.sessionExpired) {
        return DrainReport(
          sent: sent,
          stoppedBy: OutboxDisposition.sessionExpired,
          remaining: queue.length - sent,
        );
      }

      await db.update(
        'outbox',
        {'attempts': item.attempts + 1, 'last_error': result.error},
        where: 'id = ?',
        whereArgs: [item.id],
      );

      stalled.add(item.jobId);
      firstStall ??= result.disposition;
    }

    return DrainReport(
      sent: sent,
      stoppedBy: firstStall,
      remaining: queue.length - sent,
      stalledJobs: stalled,
    );
  }
}
