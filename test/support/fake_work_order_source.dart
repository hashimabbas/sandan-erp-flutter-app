import 'package:sandan_facility_app/data/queue_filters.dart';
import 'package:sandan_facility_app/data/work_order_repository.dart';
import 'package:sandan_facility_app/models/work_order.dart';
import 'package:sandan_facility_app/services/api_result.dart';

/// A [WorkOrderSource] that answers from memory.
///
/// 🔴 **Why a widget test does not use the real repository.** `testWidgets`
/// runs inside fake async, which pumps timers and microtasks but **not** a
/// database's real completions — handing the screens a live repository made
/// the suite hang for minutes with no output, which is the worst way for a
/// test environment to report anything. The repository's own behaviour is
/// proved in `work_order_repository_test.dart`, an ordinary test that may do
/// as much I/O as it likes; these tests prove what the **screen** does with
/// an answer.
class FakeWorkOrderSource implements WorkOrderSource {
  FakeWorkOrderSource({this.list, this.detail});

  ApiResult<Cached<List<WorkOrder>>>? list;
  ApiResult<Cached<WorkOrder>>? detail;

  int listCalls = 0;

  /// SPEC-024 Phase 5, Step 1 — what the filtered queue returns.
  ApiResult<List<WorkOrder>>? queueResult;

  /// 🎯 **Every filter set this fake was asked for, in order.** A widget test
  /// proves which filters a screen sent by reading this — and, just as
  /// importantly, that it sent the queue call at all rather than filtering a
  /// cached list in Dart.
  final List<QueueFilters> queueCalls = <QueueFilters>[];

  @override
  Future<ApiResult<Cached<List<WorkOrder>>>> myWork() async {
    listCalls++;

    return list ??
        const ApiFailure(
          ApiErrorKind.network,
          'Could not reach the server. Check your connection.',
        );
  }

  @override
  Future<ApiResult<List<WorkOrder>>> queue(QueueFilters filters) async {
    queueCalls.add(filters);

    return queueResult ??
        const ApiFailure(
          ApiErrorKind.network,
          'Could not reach the server. Check your connection.',
        );
  }

  @override
  Future<ApiResult<Cached<WorkOrder>>> one(String id) async =>
      detail ??
      const ApiFailure(ApiErrorKind.network, 'Could not reach the server. Check your connection.');

  // ───────────────────── the acts (SPEC-024 Phase 3) ─────────────────────

  /// What every act returns. A test sets it to the outcome it is proving.
  ActResult result = const ActResult(ActOutcome.applied);

  /// What was asked for, in order — so a widget test can prove that pressing
  /// a button called the right act with the right argument.
  final List<String> calls = <String>[];

  Set<String> pending = const {};

  @override
  Future<ActResult> arrive(String jobId, {DateTime? at}) async {
    calls.add('arrive:$jobId');

    return result;
  }

  @override
  Future<ActResult> start(String jobId) async {
    calls.add('start:$jobId');

    return result;
  }

  @override
  Future<ActResult> complete(String jobId) async {
    calls.add('complete:$jobId');

    return result;
  }

  @override
  Future<ActResult> refer(String jobId, String referredTo) async {
    calls.add('refer:$jobId:$referredTo');

    return result;
  }

  @override
  Future<ActResult> confirmReferral(String jobId) async {
    calls.add('confirm:$jobId');

    return result;
  }

  @override
  Future<ActResult> uploadEvidence(
    String jobId, {
    required String filePath,
    required String stage,
    DateTime? capturedAt,
  }) async {
    calls.add('evidence:$jobId:$stage');

    return result;
  }

  // ──────── the manager's six (SPEC-024 Phase 5 Steps 2–3) ────────

  @override
  Future<ActResult> assign(String jobId, List<int> technicianIds) async {
    calls.add('assign:$jobId:${technicianIds.join(',')}');

    return result;
  }

  @override
  Future<ActResult> verify(String jobId) async {
    calls.add('verify:$jobId');

    return result;
  }

  @override
  Future<ActResult> close(String jobId) async {
    calls.add('close:$jobId');

    return result;
  }

  @override
  Future<ActResult> cancel(String jobId, String reason) async {
    calls.add('cancel:$jobId:$reason');

    return result;
  }

  @override
  Future<ActResult> reject(String jobId, String reason) async {
    calls.add('reject:$jobId:$reason');

    return result;
  }

  @override
  Future<ActResult> decideExtension(String jobId, {required bool approved, String? note}) async {
    calls.add('decide:$jobId:$approved:${note ?? ''}');

    return result;
  }

  @override
  Future<int> pendingCount() async => pending.length;

  @override
  Future<Set<String>> pendingJobIds() async => pending;

  /// What the account screen will show. A test sets it to the queue it is
  /// proving.
  List<PendingAct> acts = const [];

  @override
  Future<List<PendingAct>> pendingActs() async => acts;
}
