import 'package:sqflite/sqflite.dart';

/// SPEC-024 Phase 2, Step 1 — the one place this app opens a database.
///
/// 🎯 **Why there is a database at all, and why it is SQL.** The work-order
/// cache would have been happy with a JSON file: it is small and always read
/// whole. The **outbox** would not. Rewriting a whole file to remove one sent
/// item is a torn write waiting for a flat battery, and a queue whose single
/// purpose is that an interruption loses nothing cannot be built on that.
/// Architecture Review Phase 2, D1.
///
/// 🔴 **The factory and the path are injected.** `flutter test` has no platform
/// channels, so `sqflite`'s native library and `path_provider`'s documents
/// directory both throw there. A store that opened its own database in its
/// constructor would be **untestable**, not merely awkward — the same reason
/// `FacilitySession` takes a `FlutterSecureStorage` and `WorkOrderService`
/// takes an `http.Client`.
class LocalDatabase {
  LocalDatabase({this.factory, this.path});

  /// The one handle the running app uses. ⚠️ A test never touches it — it
  /// constructs its own with the FFI factory and an in-memory path, which is
  /// the whole reason the factory is a constructor argument.
  ///
  /// It exists so two screens do not open two connections to the same file.
  static final LocalDatabase instance = LocalDatabase();

  /// Bumped only with a migration in [_upgrade].
  ///
  /// **v1** (Phase 2) the cache, the sync time and the outbox.
  /// **v2** (Phase 3) `job_id`, `file_path` and `file_field` on the outbox —
  /// per-job draining and the photograph, which does not fit in a JSON body.
  static const schemaVersion = 2;

  static const fileName = 'sandan_facility.db';

  /// Where the file lives. Null means the platform's own databases directory
  /// — which a test cannot ask for, so a test always passes one.
  final String? path;

  /// 🔴 Null means *the platform's own factory*, **resolved when the database
  /// is opened and not when this is constructed**. `databaseFactory` throws
  /// under `flutter test`, and reading it in the constructor made merely
  /// *building* a screen — any screen that constructs an `AuthService` —
  /// throw in six existing tests. A constructor must not need a platform.
  final DatabaseFactory? factory;

  Future<Database>? _opening;

  /// Opens the database once per instance. The future is memoised rather than
  /// the [Database] itself, so two callers racing at startup get the same
  /// connection instead of two half-opened ones.
  Future<Database> open() => _opening ??= _open();

  Future<void> close() async {
    final opening = _opening;
    if (opening == null) return;

    _opening = null;
    (await opening).close();
  }

  Future<Database> _open() async {
    final resolved = factory ?? databaseFactory;
    final target = path ?? '${await resolved.getDatabasesPath()}/$fileName';

    return resolved.openDatabase(
      target,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (db, _) => _create(db),
        onUpgrade: (db, from, to) => _upgrade(db, from, to),
      ),
    );
  }

  static Future<void> _create(Database db) async {
    // 🔴 `user_id` is an INTEGER and a work order's `id` is a UUID TEXT.
    // `users.id` is a bigint; `complaints.id` is a char(36). Copying one type
    // onto the other is a runtime failure on a device that no compiler and no
    // analyzer would have caught — the trap the Phase 1 Plan recorded as §0.3,
    // now written into a schema.
    //
    // ⚠️ The work order is stored as **the server's own JSON**, not as a
    // column per field. `WorkOrder.fromJson` already decodes that shape by
    // hand; a column-shaped second copy of it would be a second schema to keep
    // in step with the API, and the first one to drift would do so silently.
    await db.execute('''
      CREATE TABLE work_orders (
        id TEXT NOT NULL,
        user_id INTEGER NOT NULL,
        payload TEXT NOT NULL,
        position INTEGER NOT NULL,
        PRIMARY KEY (id, user_id)
      )
    ''');

    // D5's reference: the moment the app last heard from the server. ⚠️ Not
    // the moment the server computed anything, and never derived from a row's
    // own timestamps. Stored as ISO-8601 UTC.
    await db.execute('''
      CREATE TABLE sync_state (
        user_id INTEGER PRIMARY KEY,
        synced_at TEXT NOT NULL
      )
    ''');

    // D7: the queue knows nothing about work orders. It holds a request and an
    // owner, and `id` — autoincrementing — *is* its order. §3 Trap 2 of the
    // Spec: `start` then `complete` is legal and the reverse is not, so the
    // order is not an optimisation, it is the lifecycle.
    //
    // 🔴 `user_id` is who queued it. D3: an item is never sent under another
    // man's token, because that would attribute his work to the wrong
    // technician in the ERP — a falsification, not a bug.
    //
    // 🔴 **v2, Phase 3 D4 — `job_id` exists because the ordering rule is
    // PER JOB.** Phase 2 drained one global queue and stopped at the first
    // failure; the reason for that was the lifecycle (`start` then `complete`
    // is legal and the reverse is not), and that reason is about one job. Read
    // globally it meant a single stuck item froze every other job's work for
    // ever — which Phase 2 never noticed, because with no writers there was
    // never a second job to block.
    //
    // ⚠️ **`file_path` and `file_field` exist because a photograph does not
    // fit in `body`.** An evidence upload is multipart and the file is several
    // megabytes; the Spec said it plainly — queued **on disk**, with the item
    // holding its path. The file is a COPY in the app's own storage, never the
    // picker's temporary path, which the OS may delete.
    await db.execute('''
      CREATE TABLE outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        job_id TEXT,
        method TEXT NOT NULL,
        path TEXT NOT NULL,
        body TEXT,
        file_path TEXT,
        file_field TEXT,
        created_at TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
      )
    ''');

    await db.execute('CREATE INDEX work_orders_user ON work_orders (user_id, position)');
    await db.execute('CREATE INDEX outbox_user ON outbox (user_id, id)');
  }

  /// 🎯 **The guard Phase 2 wrote is doing its job in the first phase that
  /// needed it.** It threw rather than falling through silently, so a missing
  /// migration could not be discovered as corrupted data months later.
  static Future<void> _upgrade(Database db, int from, int to) async {
    // v1 → v2: additive only, so an existing queue survives. 🔴 That matters
    // more here than anywhere else in the app: the outbox may hold the only
    // record of work a technician actually finished, and a migration that
    // recreated the table would throw it away.
    if (from == 1) {
      await db.execute('ALTER TABLE outbox ADD COLUMN job_id TEXT');
      await db.execute('ALTER TABLE outbox ADD COLUMN file_path TEXT');
      await db.execute('ALTER TABLE outbox ADD COLUMN file_field TEXT');

      from = 2;
    }

    if (from == to) return;

    throw UnsupportedError(
      'No migration exists from schema v$from to v$to.',
    );
  }
}
