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

  @override
  Future<ApiResult<Cached<List<WorkOrder>>>> myWork() async {
    listCalls++;

    return list ??
        const ApiFailure(ApiErrorKind.network, 'Could not reach the server. Check your connection.');
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
