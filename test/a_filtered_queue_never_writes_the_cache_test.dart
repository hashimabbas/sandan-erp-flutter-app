import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sandan_facility_app/data/local_database.dart';
import 'package:sandan_facility_app/data/outbox.dart';
import 'package:sandan_facility_app/data/queue_filters.dart';
import 'package:sandan_facility_app/data/work_order_repository.dart';
import 'package:sandan_facility_app/data/work_order_store.dart';
import 'package:sandan_facility_app/models/work_order.dart';
import 'package:sandan_facility_app/services/api_result.dart';
import 'package:sandan_facility_app/services/facility_session.dart';
import 'package:sandan_facility_app/services/work_order_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/work_order_payload.dart';

/// SPEC-024 Phase 5, Step 1 — **the test that protects the cache.**
///
/// 🔴🔴 **Why it is the first test of this Step and not the last.**
/// `WorkOrderStore.replaceFor()` opens with
/// `DELETE FROM work_orders WHERE user_id = ?`. The sync is allowed to do that
/// because it fetches the user's *whole* scoped set — a guarantee Step 0 had to
/// build, after discovering the premise was false and the method had been
/// deleting rows for three months.
///
/// 🎯 **A filter breaks that guarantee by design.** A filtered fetch returns a
/// subset by definition, so if it ever reached `replaceFor()` the cache would
/// lose every row outside the filter — Step 0's defect wearing a filter's hat,
/// in the very class whose docblock was corrected for it.
///
/// ⚠️ **So `queue()` is a read.** Hashim, 2026-11-18: *"`queue()` must remain a
/// read-only operation and must not modify Sqflite data. Filtered manager
/// searches must not write to or replace the local synchronized dataset."*
void main() {
  sqfliteFfiInit();

  late LocalDatabase database;
  late WorkOrderStore store;
  late Outbox outbox;

  const userId = 7;

  setUp(() {
    database = LocalDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    store = WorkOrderStore(database);
    outbox = Outbox(database);
  });

  tearDown(() => database.close());

  /// A server that records every query it was asked, and serves [ids] paged.
  WorkOrderService serving(
    List<String> ids, {
    int perPage = 100,
    List<Map<String, String>>? queries,
    int? failOnPage,
  }) {
    return WorkOrderService(
      session: FacilitySession(),
      client: MockClient((request) async {
        queries?.add(request.url.queryParameters);

        final page = int.parse(request.url.queryParameters['page'] ?? '1');

        if (page == failOnPage) {
          return http.Response('{"message":"Server error"}', 500);
        }

        final slice = ids.skip((page - 1) * perPage).take(perPage).toList();

        return http.Response(
          jsonEncode({
            'data': [for (final id in slice) workOrderJson(id: id)],
            'meta': {
              'current_page': page,
              'last_page': (ids.length / perPage).ceil().clamp(1, 999),
              'per_page': perPage,
              'total': ids.length,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  }

  WorkOrderRepository repositoryOn(WorkOrderService service) =>
      WorkOrderRepository(userId: userId, store: store, outbox: outbox, service: service);

  group('the cache is not the filter\'s business', () {
    test('🔴🔴 a filtered queue writes NOTHING to the store — not a row, not a syncedAt', () async {
      // A cache the unfiltered sync put there.
      final synced = DateTime.utc(2026, 11, 18, 9);
      await store.replaceFor(userId, [
        WorkOrder.fromJson(workOrderJson(id: 'cached-1')),
        WorkOrder.fromJson(workOrderJson(id: 'cached-2')),
      ], syncedAt: synced);

      final before = (await store.rowsFor(userId)).map((job) => job.id).toList();
      final syncedBefore = await store.syncedAtFor(userId);

      // A filter that matches something else entirely.
      final result = await repositoryOn(serving(['filtered-9']))
          .queue(const QueueFilters(status: 'completed'));

      expect(result, isA<ApiSuccess<List<WorkOrder>>>());
      expect((result as ApiSuccess<List<WorkOrder>>).data.single.id, 'filtered-9');

      // 🎯 The assertion of this whole Step: the disk did not move.
      expect((await store.rowsFor(userId)).map((job) => job.id).toList(), before);
      expect(await store.syncedAtFor(userId), syncedBefore);
    });

    test('⚠️ and an EMPTY filtered result does not empty the cache either', () async {
      // The dangerous shape: zero rows handed to `replaceFor` would delete
      // everything and call the phone up to date.
      await store.replaceFor(userId, [
        WorkOrder.fromJson(workOrderJson(id: 'cached-1')),
      ], syncedAt: DateTime.utc(2026, 11, 18, 9));

      final result = await repositoryOn(serving(const []))
          .queue(const QueueFilters(status: 'cancelled'));

      expect((result as ApiSuccess<List<WorkOrder>>).data, isEmpty);
      expect(await store.rowsFor(userId), hasLength(1));
    });

    test('❌ a failed filtered fetch does NOT fall back to the cache', () async {
      // ⚠️ Unlike `myWork()`. Answering a filter from the cache would mean
      // filtering in Dart, and a stale answer to a filter set one second ago
      // is worse than an honest refusal — the manager would act on it.
      await store.replaceFor(userId, [
        WorkOrder.fromJson(workOrderJson(id: 'cached-1')),
      ], syncedAt: DateTime.utc(2026, 11, 18, 9));

      final result = await repositoryOn(serving(['x'], failOnPage: 1))
          .queue(const QueueFilters(priority: 'high'));

      expect(result, isA<ApiFailure<List<WorkOrder>>>());
      expect(await store.rowsFor(userId), hasLength(1), reason: 'the cache must survive untouched');
    });

    test(
      '✅ the unfiltered sync still writes — the control that proves the above is not vacuous',
      () async {
        final result = await repositoryOn(serving(['fresh-1', 'fresh-2'])).myWork();

        expect(result, isA<ApiSuccess<Cached<List<WorkOrder>>>>());
        expect((await store.rowsFor(userId)).map((job) => job.id).toList(), ['fresh-1', 'fresh-2']);
      },
    );
  });

  group('what the server is actually asked', () {
    test('✅ every set filter is sent, and every unset one is ABSENT', () async {
      final queries = <Map<String, String>>[];

      await repositoryOn(serving(const [], queries: queries)).queue(
        const QueueFilters(
          status: 'assigned',
          priority: 'high',
          buildingId: 'b-1',
          categoryId: 'c-1',
          subcategoryId: 's-1',
          technicianId: 42,
          breached: true,
        ),
      );

      expect(queries.single, containsPair('status', 'assigned'));
      expect(queries.single, containsPair('priority', 'high'));
      expect(queries.single, containsPair('building_id', 'b-1'));
      expect(queries.single, containsPair('category_id', 'c-1'));
      expect(queries.single, containsPair('subcategory_id', 's-1'));
      // 🔴 An integer, because `users.id` is a bigint while every other id in
      // this module is a UUID. A UUID here is a 422 from the server.
      expect(queries.single, containsPair('technician_id', '42'));
      expect(queries.single, containsPair('breached', '1'));
    });

    test('⚠️ an empty filter set sends no filter keys at all', () async {
      final queries = <Map<String, String>>[];

      await repositoryOn(serving(const [], queries: queries)).queue(const QueueFilters());

      // Only transport keys remain. ❌ Never `?status=`, which would be this
      // app asserting a filter it does not have.
      expect(queries.single.keys.toSet(), {'per_page', 'page'});
    });

    test(
      '🔴 a filtered list is still page one of N — the walk is reused, not reimplemented',
      () async {
        final queries = <Map<String, String>>[];
        final ids = List.generate(41, (i) => 'f-${i.toString().padLeft(3, '0')}');

        final result = await repositoryOn(serving(ids, perPage: 20, queries: queries))
            .queue(const QueueFilters(status: 'new'));

        expect((result as ApiSuccess<List<WorkOrder>>).data, hasLength(41));
        expect(queries.map((q) => q['page']).toList(), ['1', '2', '3']);
        // The filter travels on every page, not just the first.
        expect(queries.every((q) => q['status'] == 'new'), isTrue);
      },
    );
  });

  group('the filter set itself', () {
    test('🔧 changing the category CLEARS the subcategory, so no contradiction is ever sent', () {
      const filters = QueueFilters(categoryId: 'c-1', subcategoryId: 's-1');

      // 🔴 The server refuses `category_id=A` with a subcategory of B as a
      // CONTRADICTION — a 422, not an empty list. A screen that changed the
      // category and kept the old subcategory would send a contradiction the
      // user never typed.
      final changed = filters.withCategory('c-2');

      expect(changed.categoryId, 'c-2');
      expect(changed.subcategoryId, isNull);
      expect(changed.toQuery().containsKey('subcategory_id'), isFalse);
    });

    test('🔧 clearing the category clears both', () {
      const filters = QueueFilters(categoryId: 'c-1', subcategoryId: 's-1');

      final cleared = filters.withCategory(null);

      expect(cleared.categoryId, isNull);
      expect(cleared.subcategoryId, isNull);
      expect(cleared.isEmpty, isTrue);
    });

    test('✅ breached is a boolean that is sent only when true', () {
      expect(const QueueFilters().toQuery().containsKey('breached'), isFalse);
      expect(const QueueFilters(breached: true).toQuery()['breached'], '1');
    });
  });
}
