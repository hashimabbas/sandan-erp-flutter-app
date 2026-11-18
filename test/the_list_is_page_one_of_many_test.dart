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

/// SPEC-024 Phase 5, Step 0 — the list was **page one of N**, and the sync
/// replaced everything with it.
///
/// 🔴 **The defect.** The endpoint has paginated at 20 since Phase 0's own
/// first commit; this app read `body['data']` and never `meta`. The word
/// `page` appeared nowhere in `lib/`. So the app was capped at twenty work
/// orders — and because Phase 2's sync **replaces** the cache with what it
/// fetched, it was deleting the rest. A merge would merely have failed to add
/// them.
///
/// 🔴 **Phase 2's Architecture Review D4 chose that replace on a premise that
/// was false when it was written** — *"the endpoint returns the full scoped
/// set with no cursor"* — and the same sentence was a docblock on
/// `WorkOrderStore.replaceFor()`. Both are corrected in place today; the
/// behaviour was right and only the premise was wrong.
///
/// 🎯 **All or nothing (Hashim, 2026-11-18):** *"إذا فشل تحميل أي صفحة، يجب
/// الاحتفاظ بالبيانات المحلية السابقة وعدم تطبيق نتيجة جزئية."*
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

  /// Serves [total] work orders in pages of [perPage], failing on
  /// [failOnPage] when one is named.
  ///
  /// ⚠️ It records every page asked for, because half of what this Step can
  /// get wrong is *which pages were requested*, not what came back.
  WorkOrderService paged({
    required int total,
    int perPage = 100,
    int? failOnPage,
    List<String>? ids,
    List<int>? requested,
  }) {
    final all = ids ?? List.generate(total, (i) => 'job-${i.toString().padLeft(3, '0')}');

    return WorkOrderService(
      session: FacilitySession(),
      client: MockClient((request) async {
        final page = int.parse(request.url.queryParameters['page'] ?? '1');
        requested?.add(page);

        if (page == failOnPage) {
          return http.Response('{"message":"Server error"}', 500);
        }

        final from = (page - 1) * perPage;
        final slice = all.skip(from).take(perPage).toList();

        return http.Response(
          jsonEncode({
            'data': [for (final id in slice) workOrderJson(id: id)],
            'meta': {
              'current_page': page,
              'last_page': (all.length / perPage).ceil(),
              'per_page': perPage,
              'total': all.length,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  }

  group('the walk', () {
    test('🔴 41 work orders arrive over three pages, in the server\'s order', () async {
      final pages = <int>[];

      final result = await paged(total: 41, perPage: 20, requested: pages).fetchMyWork();

      final jobs = (result as ApiSuccess<List<WorkOrder>>).data;

      // Before today this returned the first twenty and said nothing.
      expect(jobs, hasLength(41));
      expect(pages, [1, 2, 3]);

      // 🎯 The server's order is kept as given. "Newest first" is the ERP's
      // answer and re-sorting here would be a second one.
      expect(jobs.first.id, 'job-000');
      expect(jobs.last.id, 'job-040');
    });

    test('🔴 a row repeated across a page boundary collapses', () async {
      // The server now orders totally (`created_at DESC, id DESC`), so it
      // should not repeat one. But a duplicate reaching `replaceFor` would
      // throw mid-transaction on the primary key — correct behaviour with an
      // impossible diagnosis.
      final result = await paged(
        total: 4,
        perPage: 2,
        ids: ['job-1', 'job-2', 'job-2', 'job-3'],
      ).fetchMyWork();

      final jobs = (result as ApiSuccess<List<WorkOrder>>).data;

      expect(jobs.map((job) => job.id).toList(), ['job-1', 'job-2', 'job-3']);
    });

    test('⚠️ a server that sends no meta is treated as ONE page', () async {
      // An older deployment must keep working rather than looping for ever.
      final service = WorkOrderService(
        session: FacilitySession(),
        client: MockClient((_) async => http.Response(
              jsonEncode({'data': [workOrderJson(id: 'job-1')]}),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );

      final result = await service.fetchMyWork();

      expect((result as ApiSuccess<List<WorkOrder>>).data, hasLength(1));
    });

    test('🔴 past the page budget it REFUSES — it does not truncate', () async {
      final service = WorkOrderService(
        session: FacilitySession(),
        client: MockClient((_) async => http.Response(
              jsonEncode({
                'data': [workOrderJson(id: 'job-1')],
                // One page past the budget.
                'meta': {
                  'current_page': 1,
                  'last_page': WorkOrderService.maxPages + 1,
                  'per_page': 100,
                  'total': 999999,
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );

      final result = await service.fetchMyWork();

      expect(result, isA<ApiFailure>());
      // 🎯 It names the limit: a man told only that something failed cannot
      // tell anyone what to change.
      expect((result as ApiFailure).message, contains('5000'));
    });
  });

  group('all or nothing', () {
    WorkOrderRepository repositoryOver(WorkOrderService service) => WorkOrderRepository(
          userId: 7,
          store: store,
          outbox: outbox,
          service: service,
          clock: () => DateTime.utc(2026, 11, 18, 9),
        );

    test('🔴 page 2 of 3 fails — the PREVIOUS cache is kept, untouched', () async {
      // What the phone already holds, from a sync that completed.
      await store.replaceFor(
        7,
        [
          WorkOrder.fromJson(workOrderJson(id: 'old-1', description: 'Yesterday.')),
          WorkOrder.fromJson(workOrderJson(id: 'old-2', description: 'Yesterday.')),
        ],
        syncedAt: DateTime.utc(2026, 11, 17, 8),
      );

      final result = await repositoryOver(
        paged(total: 41, perPage: 20, failOnPage: 2),
      ).myWork();

      final cached = (result as ApiSuccess<Cached<List<WorkOrder>>>).data;

      // 🔴 Not page one's twenty rows, and not an empty list either. The
      // previous cache, whole, and labelled as cached.
      expect(cached.source, WorkSource.cache);
      expect(cached.data.map((job) => job.id).toList(), ['old-1', 'old-2']);
      expect(cached.syncedAt, DateTime.utc(2026, 11, 17, 8).toLocal());
      expect(cached.notice, isNotNull);

      // 🎯 And the cache on disk is untouched — the proof that no partial
      // replace ran. Before the fetch-all walk, a short answer WAS the
      // replacement.
      expect((await store.rowsFor(7)).map((job) => job.id).toList(), ['old-1', 'old-2']);
      expect(await store.syncedAtFor(7), DateTime.utc(2026, 11, 17, 8).toLocal());
    });

    test('✅ a complete walk replaces the cache with all 41 rows', () async {
      await store.replaceFor(
        7,
        [WorkOrder.fromJson(workOrderJson(id: 'old-1'))],
        syncedAt: DateTime.utc(2026, 11, 17, 8),
      );

      final result = await repositoryOver(paged(total: 41, perPage: 20)).myWork();

      final cached = (result as ApiSuccess<Cached<List<WorkOrder>>>).data;

      expect(cached.source, WorkSource.network);
      expect(cached.data, hasLength(41));
      expect(await store.rowsFor(7), hasLength(41));
      // The row the server no longer returns is gone — the replace still does
      // what Phase 2 built it to do.
      expect(await store.rowFor(7, 'old-1'), isNull);
    });

    test('⚠️ page 1 failing with an EMPTY cache is still a plain failure', () async {
      // Phase 1's rule, unchanged: showing "nothing is assigned to you"
      // because the server was unreachable is the most reassuring possible
      // lie.
      final result = await repositoryOver(
        paged(total: 41, perPage: 20, failOnPage: 1),
      ).myWork();

      expect(result, isA<ApiFailure>());
    });
  });
}
