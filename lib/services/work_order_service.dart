import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../data/queue_filters.dart';
import '../models/work_order.dart';
import 'api_result.dart';
import 'facility_session.dart';

/// SPEC-024 Phase 1, Step 1 — the work orders assigned to the signed-in user.
///
/// 🎯 **The call the app could not make until today.** SPEC-018 shipped the
/// whole work-order lifecycle on session-authenticated web routes, which a
/// token client cannot reach, so `/api/facility/*` held nine routes and not one
/// of them concerned a work order. The home screen has been showing a fixture
/// ever since.
///
/// ⚠️ **This service asks for nothing it is not entitled to.** The list is
/// scoped on the server by `Complaint::scopeVisibleTo()`, so there is no
/// "my jobs" filter to pass — the token decides. An app-side filter would be a
/// second answer to a question the ERP already answers (ADR-012).
class WorkOrderService {
  WorkOrderService({http.Client? client, FacilitySession? session})
    : _client = client ?? http.Client(),
      _session = session ?? FacilitySession();

  final http.Client _client;
  final FacilitySession _session;

  /// How many rows one request asks for. 🔴 The server validates this and
  /// **422s** above its own ceiling of 100 — it is not clamped, because a
  /// clamp would hand back a short list and call it complete.
  static const syncPageSize = 100;

  /// 🔴 **A bound on the walk, and it is a refusal rather than a truncation.**
  /// `scopeVisibleTo()` passes the Facility Manager's query through unchanged,
  /// so his set is every complaint in the system and the walk would otherwise
  /// have no end. At 100 a page this is 5,000 work orders; past that a phone
  /// is the wrong tool, and silence is the wrong answer.
  ///
  /// ⚠️ It is a number with its reasoning written down, not a measurement. It
  /// becomes measurable the first week a manager uses the screen.
  static const maxPages = 50;

  /// Every work order this user may see — **all of the pages, or none of
  /// them**.
  ///
  /// 🔴 **The defect this replaces.** The endpoint has paginated at 20 since
  /// SPEC-024 Phase 0's own first commit, and this method read `body['data']`
  /// and never `meta` — the word `page` appeared nowhere in `lib/`. So the app
  /// was capped at twenty, silently; and because the sync **replaces** the
  /// cache with what it fetched, it was deleting the rest. It bites the
  /// Facility Manager first, whose scope is the whole system.
  ///
  /// 🎯 **All or nothing, and the caller cannot opt out of that.** A partial
  /// list never leaves this method: a failed page returns the failure, the
  /// repository falls back to the cache, and the screen keeps saying where its
  /// data came from. A half-finished sync must not quietly become *fresh*.
  ///
  /// ⚠️ **What this does not fix, said rather than engineered away:** a job
  /// created *during* the walk may be missed, and one deleted may be absent
  /// from a later page. That is inherent to walking a live list with no
  /// cursor, it is bounded by the next sync, and it is not the defect being
  /// fixed here.
  /// 🔧 **SPEC-024 Phase 5, Step 1 — `status` becomes the whole filter
  /// set.** The seven keys live in [QueueFilters], which is the only place in
  /// `lib/` that knows their server-side names. ⚠️ **Every filter is applied
  /// by the server**; this method sends parameters and nothing else.
  ///
  /// 🔴 **A filtered result must NOT be cached.** The caller decides that,
  /// and `WorkOrderRepository.queue()` is the path that does not: handing a
  /// filtered list to `WorkOrderStore.replaceFor()` would delete every row
  /// outside the filter, which is Step 0's defect wearing a filter's hat.
  Future<ApiResult<List<WorkOrder>>> fetchMyWork({String? status, QueueFilters? filters}) async {
    // ⚠️ Keyed by id, so a row repeated across a page boundary **collapses**
    // instead of being inserted twice. The server now orders totally
    // (`created_at DESC, id DESC`) and should not repeat one — but a store
    // that threw mid-transaction on a duplicate id would leave correct
    // behaviour with an impossible diagnosis. A `Map` keeps insertion order,
    // so the server's order survives untouched.
    final collected = <String, WorkOrder>{};

    var page = 1;

    while (true) {
      final uri = Uri.parse('${ApiConfig.baseUrl}/api/facility/work-orders').replace(
        queryParameters: {
          'per_page': '$syncPageSize',
          'page': '$page',
          // ⚠️ `status` stays a parameter of its own because Phase 1 shipped
          // it and the field screens still pass it. When both are given the
          // filter set wins, so there is one answer rather than two.
          'status': ?status,
          ...?filters?.toQuery(),
        },
      );

      final result = await _get(uri, (body) => body);

      switch (result) {
        case ApiFailure(:final kind, :final message):
          // 🔴 No partial result, ever. Not even the pages that did arrive.
          return ApiFailure(kind, message);

        case ApiSuccess(:final data):
          // 🔴 **Decoded inside a try, and an existing test is why.** Until
          // Step 0 the rows were parsed inside `_get`'s own try, so a payload
          // that changed shape arrived as *"the server sent something this
          // version of the app cannot read"*. Walking pages moved the parse
          // out here — and the first run of the suite turned that one honest
          // failure into an **uncaught cast** rising through the service into
          // a widget. ⚠️ Every page keeps the old guarantee.
          try {
            for (final row in (data['data'] as List<dynamic>?) ?? const []) {
              final order = WorkOrder.fromJson(row as Map<String, dynamic>);

              collected.putIfAbsent(order.id, () => order);
            }
          } catch (_) {
            return const ApiFailure(ApiErrorKind.server, _unreadable);
          }

          // ⚠️ Read defensively rather than cast: a `meta` of the wrong shape
          // must mean *one page*, not a crash. The same lesson, one key over.
          final rawMeta = data['meta'];
          final meta = rawMeta is Map<String, dynamic> ? rawMeta : null;
          // ⚠️ A server that sends no `meta` is treated as a single page, so
          // an older deployment keeps working rather than looping.
          final lastPage = (meta?['last_page'] as num?)?.toInt() ?? 1;
          final currentPage = (meta?['current_page'] as num?)?.toInt() ?? page;

          if (lastPage > maxPages) {
            return const ApiFailure(ApiErrorKind.server, _tooMuchWork);
          }

          if (currentPage >= lastPage) {
            return ApiSuccess(collected.values.toList(growable: false));
          }

          page = currentPage + 1;
      }
    }
  }

  Future<ApiResult<WorkOrder>> fetchOne(String id) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/api/facility/work-orders/$id');

    return _get(uri, (body) => WorkOrder.fromJson(body['data'] as Map<String, dynamic>));
  }

  /// Performs one queued act and returns the server's `data` block.
  ///
  /// 🔴 **SPEC-024 Phase 3 — one sender, built once.** Every act the outbox
  /// holds goes through here, so *what a 422 means* has exactly one reader.
  /// Two senders would be two answers to that question, and this phase already
  /// has enough readers of it.
  ///
  /// ⚠️ It returns the decoded `data` map rather than a [WorkOrder], because
  /// the four transitions answer with a work order and the evidence upload
  /// answers with an evidence row. The caller knows which it asked for; this
  /// method does not need to.
  Future<ApiResult<Map<String, dynamic>>> send({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    String? filePath,
    String? fileField,
  }) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}$path');

    http.Response response;

    try {
      final headers = await _session.authHeaders();

      if (filePath != null && fileField != null) {
        final request = http.MultipartRequest(method, uri)
          // ⚠️ `Content-Type` is REMOVED: http sets the multipart boundary
          // itself, and sending `application/json` here makes the server see
          // an empty body — no file, no fields, and a validation error that
          // blames the client for sending nothing.
          ..headers.addAll({...headers}..remove('Content-Type'))
          ..files.add(await http.MultipartFile.fromPath(fileField, filePath));

        body?.forEach((key, value) {
          if (value != null) request.fields[key] = value.toString();
        });

        response = await http.Response.fromStream(await _client.send(request));
      } else {
        response = await _client
            .send(
              http.Request(method, uri)
                ..headers.addAll(headers)
                ..body = jsonEncode(body ?? const <String, dynamic>{}),
            )
            .then(http.Response.fromStream);
      }
    } on SocketException {
      return const ApiFailure(ApiErrorKind.network, _unreachable);
    } catch (_) {
      return const ApiFailure(ApiErrorKind.network, _unreachable);
    }

    if (response.statusCode == 401) {
      return const ApiFailure(ApiErrorKind.sessionExpired, _sessionOver);
    }

    if (response.statusCode == 403) {
      return const ApiFailure(ApiErrorKind.forbidden, _notYours);
    }

    // 🔴 422 is a DOMAIN refusal and must be distinguishable from anything
    // else: the lifecycle said no, in a sentence written for the technician.
    // The contract is `errors.<field>[0]`, built by SPEC-018 Phase 10 Step 2
    // and read here by its first client.
    if (response.statusCode == 422) {
      final decoded = _decode(response.body);
      final errors = decoded?['errors'] as Map<String, dynamic>?;

      final fieldErrors = <String, String>{
        if (errors != null)
          for (final entry in errors.entries)
            entry.key: (entry.value as List<dynamic>).first.toString(),
      };

      return ApiFailure(
        ApiErrorKind.refused,
        fieldErrors.values.firstOrNull ??
            (decoded?['message'] as String? ?? 'The server refused this action.'),
        fieldErrors: fieldErrors,
      );
    }

    if (response.statusCode != 200 && response.statusCode != 201) {
      return const ApiFailure(ApiErrorKind.server, _serverUnhappy);
    }

    final decoded = _decode(response.body);
    final data = decoded?['data'];

    if (data is! Map<String, dynamic>) {
      return const ApiFailure(ApiErrorKind.server, _unreadable);
    }

    return ApiSuccess(data);
  }

  Map<String, dynamic>? _decode(String body) {
    if (body.isEmpty) return null;

    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static const _unreachable = 'Could not reach the server. Check your connection.';
  static const _sessionOver = 'Your session has ended. Please sign in again.';
  static const _notYours = 'This work order is not assigned to you.';
  static const _serverUnhappy = 'The server could not answer right now. Please try again.';
  static const _unreadable = 'The server sent something this version of the app cannot read.';

  /// 🔴 A refusal, not a truncation — and it names the limit, because a man
  /// told only that something failed cannot tell anyone what to change.
  static const _tooMuchWork =
      'There is more work here than this app will load at once (over '
      '${maxPages * syncPageSize} jobs). Filter the list on the web, or ask for a filtered view.';

  Future<ApiResult<T>> _get<T>(Uri uri, T Function(Map<String, dynamic>) parse) async {
    http.Response response;

    try {
      response = await _client.get(uri, headers: await _session.authHeaders());
    } catch (_) {
      return const ApiFailure(
        ApiErrorKind.network,
        'Could not reach the server. Check your connection.',
      );
    }

    // 🔴 The 401/403 split, decided here so no screen has to remember it.
    if (response.statusCode == 401) {
      return const ApiFailure(
        ApiErrorKind.sessionExpired,
        'Your session has ended. Please sign in again.',
      );
    }

    if (response.statusCode == 403) {
      // Phase 0 returns this deliberately for a job assigned to somebody else.
      // It is a fact about the row, not about the session.
      return const ApiFailure(ApiErrorKind.forbidden, 'This work order is not assigned to you.');
    }

    if (response.statusCode != 200) {
      return const ApiFailure(
        ApiErrorKind.server,
        'The server could not answer right now. Please try again.',
      );
    }

    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;

      return ApiSuccess(parse(body));
    } catch (_) {
      // ⚠️ Every field is decoded by hand, so a payload that changed shape
      // arrives here rather than as a crash inside a widget's build method.
      return const ApiFailure(
        ApiErrorKind.server,
        'The server sent something this version of the app cannot read.',
      );
    }
  }
}
