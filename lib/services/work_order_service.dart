import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
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

  Future<ApiResult<List<WorkOrder>>> fetchMyWork({String? status}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/api/facility/work-orders')
        .replace(queryParameters: status == null ? null : {'status': status});

    return _get(uri, (body) {
      final rows = (body['data'] as List<dynamic>?) ?? const [];

      return rows
          .map((row) => WorkOrder.fromJson(row as Map<String, dynamic>))
          .toList(growable: false);
    });
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
        response = await _client.send(
          http.Request(method, uri)
            ..headers.addAll(headers)
            ..body = jsonEncode(body ?? const <String, dynamic>{}),
        ).then(http.Response.fromStream);
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
      return const ApiFailure(
        ApiErrorKind.forbidden,
        'This work order is not assigned to you.',
      );
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
