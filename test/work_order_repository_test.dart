import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sandan_facility_app/data/local_database.dart';
import 'package:sandan_facility_app/data/outbox.dart';
import 'package:sandan_facility_app/data/work_order_repository.dart';
import 'package:sandan_facility_app/data/work_order_store.dart';
import 'package:sandan_facility_app/models/work_order.dart';
import 'package:sandan_facility_app/services/api_result.dart';
import 'package:sandan_facility_app/services/facility_session.dart';
import 'package:sandan_facility_app/services/work_order_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/work_order_payload.dart';

/// SPEC-024 Phase 2, Step 4 — the seam, and the four answers it can give.
///
/// 🎯 **The test this phase was written for is `offline, with a cache`.** Until
/// today a technician with no signal got *"Could not reach the server"* and
/// nothing else, however much work was assigned to him.
void main() {
  sqfliteFfiInit();

  late LocalDatabase database;
  late WorkOrderStore store;
  late Outbox outbox;

  setUp(() {
    database = LocalDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    store = WorkOrderStore(database);
    outbox = Outbox(database);
  });

  tearDown(() => database.close());

  final syncedAt = DateTime.utc(2026, 10, 28, 8, 40);

  WorkOrderService respondingWith(Object body, {int status = 200}) => WorkOrderService(
        session: FacilitySession(),
        client: MockClient((_) async => http.Response(
              jsonEncode(body),
              status,
              headers: {'content-type': 'application/json'},
            )),
      );

  /// A client that cannot reach anything — the whole point of this phase.
  WorkOrderService unreachable() => WorkOrderService(
        session: FacilitySession(),
        client: MockClient((_) async => throw http.ClientException('offline')),
      );

  Map<String, dynamic> listBody(List<Map<String, dynamic>> rows) => {
        'data': rows,
        'meta': {'current_page': 1, 'last_page': 1, 'per_page': 20, 'total': rows.length},
      };

  WorkOrderRepository repository(WorkOrderService service) => WorkOrderRepository(
        userId: 7,
        store: store,
        outbox: outbox,
        service: service,
        clock: () => syncedAt,
      );

  group('myWork', () {
    test('a successful fetch fills the cache and reports the network', () async {
      final result = await repository(respondingWith(listBody([workOrderJson(id: 'a')]))).myWork();

      final feed = (result as ApiSuccess<Cached<List<WorkOrder>>>).data;

      expect(feed.source, WorkSource.network);
      expect(feed.isStale, isFalse);
      expect(feed.syncedAt, syncedAt);
      expect(feed.data.single.id, 'a');
      // The fetch did not merely display — it recorded.
      expect((await store.rowsFor(7)).single.id, 'a');
    });

    test('🎯 offline, with a cache: the list is served from the disk and SAYS so', () async {
      await store.replaceFor(7, [WorkOrder.fromJson(workOrderJson(id: 'a'))], syncedAt: syncedAt);

      final result = await repository(unreachable()).myWork();

      final feed = (result as ApiSuccess<Cached<List<WorkOrder>>>).data;

      expect(feed.source, WorkSource.cache);
      expect(feed.isStale, isTrue);
      expect(feed.syncedAt, syncedAt.toLocal());
      expect(feed.data.single.id, 'a');
      // ⚠️ The reason is carried in the technician's words, not as a status
      // code — it is the thing the screen prints next to the timestamp.
      expect(feed.notice, contains('connection'));
    });

    test('offline with an EMPTY cache is still a failure, exactly as in Phase 1', () async {
      final result = await repository(unreachable()).myWork();

      // 🔴 "No work orders are assigned to you right now" because the server
      // was unreachable would be the most reassuring possible lie.
      expect(result, isA<ApiFailure<Cached<List<WorkOrder>>>>());
      expect((result as ApiFailure).kind, ApiErrorKind.network);
    });

    test('🔴 a 401 is never softened by a cache', () async {
      await store.replaceFor(7, [WorkOrder.fromJson(workOrderJson())], syncedAt: syncedAt);

      final result = await repository(respondingWith({'message': 'Unauthenticated.'}, status: 401))
          .myWork();

      // The session is over. Serving the cache here would keep a signed-out
      // man looking at work he can no longer act on.
      expect((result as ApiFailure).kind, ApiErrorKind.sessionExpired);
    });

    test('a sync that returns fewer rows shrinks the cache', () async {
      await store.replaceFor(
        7,
        [WorkOrder.fromJson(workOrderJson(id: 'a')), WorkOrder.fromJson(workOrderJson(id: 'b'))],
        syncedAt: syncedAt,
      );

      await repository(respondingWith(listBody([workOrderJson(id: 'a')]))).myWork();

      expect((await store.rowsFor(7)).map((o) => o.id), ['a']);
    });
  });

  group('one', () {
    test('a refreshed job updates its cached row without disturbing the list', () async {
      await store.replaceFor(
        7,
        [WorkOrder.fromJson(workOrderJson(id: 'a')), WorkOrder.fromJson(workOrderJson(id: 'b'))],
        syncedAt: syncedAt,
      );

      await repository(respondingWith({
        'data': workOrderJson(id: 'b', description: 'Re-inspected: the seal, not the hose.'),
      })).one('b');

      final rows = await store.rowsFor(7);

      expect(rows.map((o) => o.id), ['a', 'b']);
      expect(rows.last.description, 'Re-inspected: the seal, not the hose.');
    });

    test('offline, the cached job is shown with its freshness', () async {
      await store.replaceFor(7, [WorkOrder.fromJson(workOrderJson(id: 'a'))], syncedAt: syncedAt);

      final result = await repository(unreachable()).one('a');

      final detail = (result as ApiSuccess<Cached<WorkOrder>>).data;

      expect(detail.source, WorkSource.cache);
      expect(detail.data.id, 'a');
      expect(detail.syncedAt, syncedAt.toLocal());
    });

    test('🔴 a 403 EVICTS the cached row and propagates the refusal', () async {
      await store.replaceFor(7, [WorkOrder.fromJson(workOrderJson(id: 'a'))], syncedAt: syncedAt);

      final result = await repository(respondingWith({'message': 'Forbidden.'}, status: 403))
          .one('a');

      // 🎯 The server has just said the row is not his. A cached copy that
      // outlives that answer is the ADR-012 leak with a longer fuse.
      expect((result as ApiFailure).kind, ApiErrorKind.forbidden);
      expect(await store.rowFor(7, 'a'), isNull);
    });

    test('offline with nothing cached propagates the network failure', () async {
      final result = await repository(unreachable()).one('never-seen');

      expect((result as ApiFailure).kind, ApiErrorKind.network);
    });
  });

  test('🔴 the repository reads and writes ONLY its own user', () async {
    await store.replaceFor(8, [WorkOrder.fromJson(workOrderJson(id: 'eights-job'))], syncedAt: syncedAt);

    final result = await repository(unreachable()).myWork();

    // Technician 8's rows are on this phone. Technician 7 is signed in, and
    // the fetch failed — the fallback must still refuse to show them.
    expect(result, isA<ApiFailure<Cached<List<WorkOrder>>>>());
    expect((await store.rowsFor(8)).single.id, 'eights-job');
  });
}
