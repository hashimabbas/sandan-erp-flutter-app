import '../models/work_order.dart';
import '../services/api_result.dart';
import '../services/work_order_service.dart';
import 'evidence_files.dart';
import 'outbox.dart';
import 'work_order_store.dart';

/// Where the data on the screen actually came from.
enum WorkSource { network, cache }

/// Data, plus the two things a screen needs in order to be honest about it.
class Cached<T> {
  const Cached(this.data, {required this.source, this.syncedAt, this.notice});

  final T data;

  final WorkSource source;

  /// When the app last heard from the server for this user. ⚠️ **Not** when the
  /// server computed anything, and never derived from a row's own timestamps.
  final DateTime? syncedAt;

  /// Why this is cached rather than fresh, in words for the technician. Null
  /// when [source] is [WorkSource.network].
  final String? notice;

  bool get isStale => source == WorkSource.cache;
}

/// What happened when a man pressed a button.
///
/// 🔴 **There are three outcomes and the middle one is the point.** The act
/// reached the server (`applied`), or it is on the phone and not yet sent
/// (`pending`), or the server refused it (`refused`). Phase 2 taught the
/// reading half of this lesson; the writing half is sharper, because *pending*
/// is work that exists nowhere else.
enum ActOutcome { applied, pending, refused }

class ActResult {
  const ActResult(this.outcome, {this.job, this.message});

  final ActOutcome outcome;

  /// The job as the server now describes it — only on [ActOutcome.applied],
  /// because only then has anything actually changed.
  final WorkOrder? job;

  /// The server's own sentence when it refused, or the reason it is pending.
  final String? message;

  bool get isPending => outcome == ActOutcome.pending;
}

/// One act waiting on this phone, as the account screen shows it.
///
/// 🎯 **Why the ages are here at all.** SPEC-024 §6 **Q2** asks *how long
/// may a work order stay "recorded on this phone"?* — and Sandan has not
/// answered. Phase 2 deliberately invented **no expiry**, recording each
/// item's `created_at` instead so the question could one day be answered with
/// real ages rather than a guess. This is where those ages become visible.
class PendingAct {
  const PendingAct({
    required this.jobId,
    required this.action,
    required this.createdAt,
    required this.attempts,
    required this.lastError,
  });

  final String? jobId;

  /// ⚠️ The app's own description of the request it built — `start`,
  /// `complete`, `refer`, `referral/confirm`, `evidence`. It is deliberately
  /// NOT the server's `actions` label: those arrive with a work order and this
  /// screen may be read with no signal at all. Describing a queued **request**
  /// is the app's business; describing a work order's **state** is not.
  final String action;

  final DateTime createdAt;
  final int attempts;

  /// The server's own sentence, if it has refused this item. 🔴 Without it an
  /// item the server keeps refusing sits in the queue for ever with no way for
  /// the technician to learn why.
  final String? lastError;
}

/// What a screen is allowed to know about where its work orders come from.
///
/// 🔴 **Added because a widget test must not perform real I/O.** The first
/// version of Step 5 handed the screens a live [WorkOrderRepository] over an
/// in-memory database, and `testWidgets` **hung for minutes with no output** —
/// a widget test runs inside fake async, which pumps timers and microtasks but
/// not a database's real completions. The hang is not a quirk to work around:
/// a screen test should prove what the screen does with an answer, and the
/// answers themselves are proved in `work_order_repository_test.dart`, which
/// is an ordinary test and may do all the I/O it likes.
abstract interface class WorkOrderSource {
  Future<ApiResult<Cached<List<WorkOrder>>>> myWork();

  Future<ApiResult<Cached<WorkOrder>>> one(String id);

  /// SPEC-024 Phase 3 — the five field acts. Each one is queued first and
  /// sent immediately after, so there is no second code path for being
  /// offline (D3): the rare case is the only case.
  Future<ActResult> start(String jobId);

  Future<ActResult> complete(String jobId);

  Future<ActResult> refer(String jobId, String referredTo);

  Future<ActResult> confirmReferral(String jobId);

  Future<ActResult> uploadEvidence(
    String jobId, {
    required String filePath,
    required String stage,
    DateTime? capturedAt,
  });

  /// How many acts are waiting to be sent — read by the sign-out warning
  /// (D8) and the list's pending markers.
  Future<int> pendingCount();

  /// The jobs with unsent work, so a row can be marked without asking per
  /// row.
  Future<Set<String>> pendingJobIds();

  /// Everything waiting to be sent, oldest first — read by the account
  /// screen (Phase 4 D4).
  Future<List<PendingAct>> pendingActs();
}

/// SPEC-024 Phase 2, Step 4 — the seam between the screen and the two places
/// a work order can come from.
///
/// 🎯 **Before this, the network fed the screen. Now the network fills the
/// store, and the store feeds the screen.** That is the whole of Phase 2: with
/// no signal the technician used to get *"Could not reach the server"* and
/// nothing else.
///
/// 🔴 **`WorkOrderService` is deliberately not told any of this.** It is the
/// one place that decides *a 401 is not a 403*; a service that also decided
/// *and if offline, read the disk* would fuse two unrelated rules, and the next
/// reader would copy one of them. Measured precedent in this app: the token key
/// was declared in two services until Phase 1 gave it one home.
class WorkOrderRepository implements WorkOrderSource {
  WorkOrderRepository({
    required this.userId,
    required this.store,
    required this.outbox,
    WorkOrderService? service,
    DateTime Function()? clock,
  })  : _service = service ?? WorkOrderService(),
        _clock = clock ?? DateTime.now;

  /// 🔴 The signed-in `users.id` — an **int**, while a work order's id is a
  /// UUID string. Every read and write below is scoped by it, because ADR-012's
  /// scope must survive being copied onto a disk.
  final int userId;

  final WorkOrderStore store;

  final Outbox outbox;

  final WorkOrderService _service;
  final DateTime Function() _clock;

  /// The list. Fetches, and falls back to the disk when the fetch cannot
  /// reach the server.
  @override
  Future<ApiResult<Cached<List<WorkOrder>>>> myWork() async {
    final result = await _service.fetchMyWork();

    switch (result) {
      case ApiSuccess(:final data):
        final syncedAt = _clock();
        await store.replaceFor(userId, data, syncedAt: syncedAt);

        return ApiSuccess(Cached(data, source: WorkSource.network, syncedAt: syncedAt));

      case ApiFailure(:final kind, :final message):
        // 🔴 A 401 is never softened by a cache. The session is over, the
        // caller signs the user out, and the cache is cleared on the way.
        if (kind == ApiErrorKind.sessionExpired) return ApiFailure(kind, message);

        final cached = await store.rowsFor(userId);

        // ⚠️ An empty cache means this is still a plain failure, exactly as in
        // Phase 1. Showing "nothing is assigned to you" because the server was
        // unreachable would be the most reassuring possible lie.
        if (cached.isEmpty) return ApiFailure(kind, message);

        return ApiSuccess(Cached(
          cached,
          source: WorkSource.cache,
          syncedAt: await store.syncedAtFor(userId),
          notice: message,
        ));
    }
  }

  /// One job. Answers from the cache when the server cannot be reached — and
  /// 🔴 **deletes the cached copy when the server answers 403**, because it has
  /// just said the row is not this man's, and a cached copy that outlives that
  /// answer is the scope leak with a longer fuse.
  @override
  Future<ApiResult<Cached<WorkOrder>>> one(String id) async {
    final result = await _service.fetchOne(id);

    switch (result) {
      case ApiSuccess(:final data):
        await store.upsert(userId, data);

        return ApiSuccess(Cached(
          data,
          source: WorkSource.network,
          syncedAt: await store.syncedAtFor(userId),
        ));

      case ApiFailure(:final kind, :final message):
        if (kind == ApiErrorKind.forbidden) {
          await store.evict(userId, id);

          return ApiFailure(kind, message);
        }

        if (kind == ApiErrorKind.sessionExpired) return ApiFailure(kind, message);

        final cached = await store.rowFor(userId, id);

        if (cached == null) return ApiFailure(kind, message);

        return ApiSuccess(Cached(
          cached,
          source: WorkSource.cache,
          syncedAt: await store.syncedAtFor(userId),
          notice: message,
        ));
    }
  }

  // ───────────────────────── the acts (Phase 3) ─────────────────────────

  @override
  Future<ActResult> start(String jobId) =>
      _act(jobId, 'PATCH', 'start');

  @override
  Future<ActResult> complete(String jobId) =>
      _act(jobId, 'PATCH', 'complete');

  @override
  Future<ActResult> refer(String jobId, String referredTo) =>
      // ⚠️ `referred_to`, measured from the controller. The app sent
      // `provider` in a Phase 2 test fixture and the server would have
      // answered 422 on a field it has never had.
      _act(jobId, 'PATCH', 'refer', body: {'referred_to': referredTo});

  @override
  Future<ActResult> confirmReferral(String jobId) =>
      _act(jobId, 'PATCH', 'referral/confirm');

  @override
  Future<ActResult> uploadEvidence(
    String jobId, {
    required String filePath,
    required String stage,
    DateTime? capturedAt,
  }) =>
      _act(
        jobId,
        'POST',
        'evidence',
        body: {
          'stage': stage,
          // 🎯 Sent because a queue makes the gap between capture and
          // arrival real, and the server keeps the two timestamps apart on
          // purpose. ⚠️ `device_identifier` is deliberately not sent: the
          // server stores all three as claims it never trusts, so inventing
          // a device id would add a dependency and no truth.
          if (capturedAt != null) 'device_captured_at': capturedAt.toUtc().toIso8601String(),
        },
        filePath: filePath,
        fileField: 'photo',
        parsesWorkOrder: false,
      );

  @override
  Future<int> pendingCount() => outbox.countFor(userId);

  @override
  Future<Set<String>> pendingJobIds() async => (await outbox.pending(userId))
      .map((item) => item.jobId)
      .whereType<String>()
      .toSet();

  @override
  Future<List<PendingAct>> pendingActs() async => (await outbox.pending(userId))
      .map((item) => PendingAct(
            jobId: item.jobId,
            // Reversing the app's OWN path construction, which is why this is
            // not a second vocabulary: the repository built this string.
            action: item.jobId == null
                ? item.path
                : item.path.split('/${item.jobId}/').last,
            createdAt: item.createdAt,
            attempts: item.attempts,
            lastError: item.lastError,
          ))
      .toList(growable: false);

  /// Queue it, then try to send it.
  ///
  /// 🔴 **There is no "send directly when online" path**, and that is D3.
  /// Two paths mean two behaviours and the rare one rots unexercised — which
  /// matters more, not less, now that the aeroplane-mode run is deferred and
  /// having no signal is said to be rare. With one path, every act every
  /// technician performs exercises the queue.
  Future<ActResult> _act(
    String jobId,
    String method,
    String suffix, {
    Map<String, dynamic>? body,
    String? filePath,
    String? fileField,
    bool parsesWorkOrder = true,
  }) async {
    // 🔴 The id of THIS act, kept because the drain that follows may also
    // carry other jobs' items — and a refusal belonging to another job must
    // never be reported as the answer to the button this man just pressed.
    // A test caught exactly that: starting job-2 reported *"Not started."*,
    // which was job-1's refusal.
    final itemId = await outbox.enqueue(
      userId: userId,
      jobId: jobId,
      method: method,
      path: '/api/facility/work-orders/$jobId/$suffix',
      body: body,
      filePath: filePath,
      fileField: fileField,
    );

    Map<String, dynamic>? lastData;
    String? refusal;
    var refused = false;

    await outbox.drain(
      userId: userId,
      send: (item) async {
        final result = await _service.send(
          method: item.method,
          path: item.path,
          body: item.body,
          filePath: item.filePath,
          fileField: item.fileField,
        );

        final isThisAct = item.id == itemId;

        switch (result) {
          case ApiSuccess(:final data):
            if (isThisAct) lastData = data;

            // 🔴 No outbox row is removed without its file. Otherwise the
            // phone fills up with photographs of jobs that closed weeks ago
            // and nothing points at them any more.
            if (item.filePath != null) await EvidenceFiles.discard(item.filePath!);

            return const OutboxSendResult(OutboxDisposition.sent);

          case ApiFailure(:final kind, :final message):
            // 🔴 A 403 is not retryable and never will be: the server says
            // the job is not this man's. Keeping it queued would retry it for
            // ever. It is reported as a refusal, and the cached row goes —
            // the same rule the read path follows (D6).
            if (kind == ApiErrorKind.forbidden) {
              // ⚠️ Evicted for the item's OWN job, not for the job this call
              // was about — the server refused the row it was sent.
              await store.evict(userId, item.jobId ?? jobId);

              if (isThisAct) {
                refused = true;
                refusal = message;
              }

              return OutboxSendResult(OutboxDisposition.refused, error: message);
            }

            if (kind == ApiErrorKind.refused) {
              if (isThisAct) {
                refused = true;
                refusal = message;
              }

              return OutboxSendResult(OutboxDisposition.refused, error: message);
            }

            if (kind == ApiErrorKind.sessionExpired) {
              return const OutboxSendResult(OutboxDisposition.sessionExpired);
            }

            return OutboxSendResult(OutboxDisposition.unreachable, error: message);
        }
      },
    );

    if (refused) {
      // ⚠️ The item stays queued with its error recorded — Phase 2's rule,
      // unchanged: a 422 never means *already done*. What changes is that the
      // technician is told, in the server's own words.
      return ActResult(ActOutcome.refused, message: refusal);
    }

    if (lastData != null && parsesWorkOrder) {
      final job = WorkOrder.fromJson(lastData!);
      // ✅ The status changed because the SERVER said so, and the cache takes
      // its word. Every transition answers with the fresh work order, so this
      // costs no extra request.
      await store.upsert(userId, job);

      return ActResult(ActOutcome.applied, job: job);
    }

    if (lastData != null) {
      // An evidence upload: it reached the server, and the job itself did not
      // change.
      return const ActResult(ActOutcome.applied);
    }

    return const ActResult(
      ActOutcome.pending,
      message: 'Recorded on this phone \u2014 not yet sent.',
    );
  }
}
