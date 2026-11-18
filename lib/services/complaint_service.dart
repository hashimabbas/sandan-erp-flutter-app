import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/assignee.dart';
import '../models/complaint_lookups.dart';
import '../models/work_order.dart' show Vocab;
import 'facility_session.dart';

class CreateComplaintResult {
  const CreateComplaintResult({
    required this.success,
    this.message,
    this.fieldErrors,
    this.complaintId,
  });

  final bool success;
  final String? message;
  final Map<String, String>? fieldErrors;

  /// SPEC-025 Step 6 — the id of what was just created, so the screen can
  /// offer to assign it. Null on failure, and null for an assignment, which
  /// already knows which job it acted on.
  final String? complaintId;
}

/// SPEC-004: Facility Manager complaint creation + its read-only lookups.
/// Every request carries the same bearer token AuthService stores — this
/// class does not manage the session itself, only reads it.
class ComplaintService {
  ComplaintService({FacilitySession? session, http.Client? client})
      : _session = session ?? FacilitySession(),
        _client = client ?? http.Client();

  /// SPEC-025 Step 6 — injectable, the pattern `WorkOrderService` already
  /// uses. ⚠️ Until now this class called the `http` package's top-level
  /// functions, so **not one of its methods could be tested**: the screen it
  /// serves has no widget tests for exactly that reason. Every call below was
  /// moved onto this client unchanged.

  /// SPEC-024 Phase 1, Step 1 — this class used to declare its own copy of
  /// `'facility_token'` and build its own headers. Both now come from
  /// `FacilitySession`, so the string exists once.
  final FacilitySession _session;
  final http.Client _client;

  Future<Map<String, String>> _authHeaders() => _session.authHeaders();

  /// SPEC-024 Phase 1, Step 2 — the words the server uses, fetched instead of
  /// declared.
  ///
  /// 🔴 **This endpoint was built FOR this app and the app never called it.**
  /// SPEC-018 Step 4 added `lookup/vocabulary` specifically so the priority
  /// list would stop being a compile-time constant in Dart — and until today
  /// it was referenced nowhere in `lib/`, while this screen went on posting
  /// `'medium'`, a value the server stopped accepting when D3 renamed it to
  /// `'normal'`. A dated alias in `StoreFacilityComplaintRequest` has been
  /// translating it ever since, and retiring that alias is what this step
  /// makes possible.
  ///
  /// ⚠️ **Guarded by `create` on Complaint**, like its three sibling lookups —
  /// so a **technician gets 403 here**, measured. That is correct: this screen
  /// is the Facility Manager's. Any future caller on a field screen must take
  /// its vocabulary from the work-order payload, which already carries
  /// `{value, label}` per row, rather than from here.
  Future<ComplaintVocabulary> fetchVocabulary() async {
    final response = await _client.get(
      Uri.parse('${ApiConfig.baseUrl}/api/facility/complaints/lookup/vocabulary'),
      headers: await _authHeaders(),
    );

    if (response.statusCode != 200) {
      throw Exception('Could not load the vocabulary (${response.statusCode}).');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    return ComplaintVocabulary(
      priorities: _vocabList(body['priorities']),
      statuses: _vocabList(body['statuses']),
    );
  }

  List<Vocab> _vocabList(Object? raw) => ((raw as List<dynamic>?) ?? const [])
      .map((e) => Vocab.fromJson(e as Map<String, dynamic>))
      .toList(growable: false);

  Future<List<BuildingLookup>> fetchBuildings() async {
    final response = await _client.get(
      Uri.parse('${ApiConfig.baseUrl}/api/facility/complaints/lookup/buildings'),
      headers: await _authHeaders(),
    );
    final list = jsonDecode(response.body) as List<dynamic>;
    return list.map((e) => BuildingLookup.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<UnitLookup>> fetchUnits(String buildingId) async {
    final response = await _client.get(
      Uri.parse('${ApiConfig.baseUrl}/api/facility/complaints/lookup/units?building_id=$buildingId'),
      headers: await _authHeaders(),
    );
    final list = jsonDecode(response.body) as List<dynamic>;
    return list.map((e) => UnitLookup.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<ComplaintCategoryLookup>> fetchCategories() async {
    final response = await _client.get(
      Uri.parse('${ApiConfig.baseUrl}/api/facility/complaints/lookup/categories'),
      headers: await _authHeaders(),
    );
    final list = jsonDecode(response.body) as List<dynamic>;
    return list.map((e) => ComplaintCategoryLookup.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Tenants/owners tied to the unit's active contracts — the mobile form
  /// never accepts a free-text party (SPEC-004 §4.2), only a real record.
  Future<({List<PartyLookup> tenants, List<PartyLookup> owners})> fetchRelatedParties(
    String unitId,
  ) async {
    final response = await _client.get(
      Uri.parse('${ApiConfig.baseUrl}/api/facility/units/$unitId/related-parties'),
      headers: await _authHeaders(),
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final tenants = (body['tenants'] as List<dynamic>? ?? [])
        .map((e) => PartyLookup.fromTenantJson(e as Map<String, dynamic>))
        .toList();
    final owners = (body['owners'] as List<dynamic>? ?? [])
        .map((e) => PartyLookup.fromOwnerJson(e as Map<String, dynamic>))
        .toList();
    return (tenants: tenants, owners: owners);
  }

  /// Manual fallback search (type is 'tenant' or 'owner') — mirrors the web
  /// Reception form's ReceptionEntitySelector, used when the unit has no
  /// suggested party, or the Facility Manager just wants to search directly.
  Future<List<PartyLookup>> searchParties({required String type, required String search}) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/api/facility/complaints/lookup/parties')
        .replace(queryParameters: {'type': type, 'search': search});
    final response = await _client.get(uri, headers: await _authHeaders());
    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .map(
          (e) => type == 'tenant'
              ? PartyLookup.fromTenantJson(e as Map<String, dynamic>)
              : PartyLookup.fromOwnerJson(e as Map<String, dynamic>),
        )
        .toList();
  }

  Future<CreateComplaintResult> createComplaint({
    required String buildingId,
    String? unitId,
    String? blockNumber,
    String? tenantId,
    String? ownerId,
    required String categoryId,
    required String subcategoryId,
    required String description,
    required String priority,
    List<int> technicianIds = const [],
  }) async {
    http.Response response;
    try {
      response = await _client.post(
        Uri.parse('${ApiConfig.baseUrl}/api/facility/complaints'),
        headers: await _authHeaders(),
        body: jsonEncode({
          'building_id': buildingId,
          if (unitId != null) 'unit_id': unitId,
          if (blockNumber != null && blockNumber.isNotEmpty) 'block_number': blockNumber,
          if (tenantId != null) 'tenant_id': tenantId,
          if (ownerId != null) 'owner_id': ownerId,
          'category_id': categoryId,
          'subcategory_id': subcategoryId,
          'description': description,
          'priority': priority,
          // SPEC-025 D1 - omitted entirely when nobody was chosen, so a
          // request without an assignment is byte-for-byte the request this
          // app has always sent.
          if (technicianIds.isNotEmpty) 'technician_ids': technicianIds,
        }),
      );
    } catch (_) {
      return const CreateComplaintResult(
        success: false,
        message: 'Could not reach the server. Check your connection.',
      );
    }

    if (response.statusCode == 201) {
      // The server returns the complaint it created. Its id is read
      // defensively: a missing id must not fail a complaint that was in fact
      // logged - it only costs the "assign now" offer that follows.
      String? id;
      try {
        id = (jsonDecode(response.body) as Map<String, dynamic>)['id'] as String?;
      } catch (_) {
        id = null;
      }

      return CreateComplaintResult(success: true, complaintId: id);
    }

    if (response.statusCode == 422) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final errors = (body['errors'] as Map<String, dynamic>? ?? {});
      return CreateComplaintResult(
        success: false,
        message: body['message'] as String? ?? 'Please check the form and try again.',
        fieldErrors: errors.map((key, value) => MapEntry(key, (value as List).first as String)),
      );
    }

    if (response.statusCode == 403) {
      return const CreateComplaintResult(
        success: false,
        message: 'You are not authorized to create a complaint.',
      );
    }

    return const CreateComplaintResult(
      success: false,
      message: 'Something went wrong. Please try again.',
    );
  }

  /// SPEC-025 Step 6 — who this job can be given to.
  ///
  /// 🎯 The category goes WITH the question, because the server orders the
  /// answer by whether each person's trade matches the job's. 🔴 It never
  /// returns an empty list on account of the filter (D7): the trade **informs**
  /// the choice and the Facility Manager can still pick anybody.
  ///
  /// ⚠️ Returns an empty list rather than throwing when the lookup fails. The
  /// picker is **optional** (D1), and a complaint that cannot be logged
  /// because a convenience lookup failed would be a worse outcome than one
  /// logged without an assignee.
  Future<AssigneeList> fetchAssignees({String? categoryId}) async {
    final query = categoryId == null ? '' : '?category_id=$categoryId';

    try {
      final response = await _client.get(
        Uri.parse('${ApiConfig.baseUrl}/api/facility/complaints/lookup/assignees$query'),
        headers: await _authHeaders(),
      );

      if (response.statusCode != 200) {
        return const AssigneeList.empty();
      }

      return AssigneeList.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    } catch (_) {
      return const AssigneeList.empty();
    }
  }

  /// SPEC-025 Step 6 — hand an existing job to somebody.
  ///
  /// 🔴 **Never queued.** The outbox carries a technician's own field acts; a
  /// manager assigning work he cannot see confirmed is a promise this app
  /// cannot keep, so offline this simply fails and says so — the same rule the
  /// password change follows.
  ///
  /// ⚠️ Reuses `CreateComplaintResult` rather than declaring an identical
  /// second class: success, a message and the server's field errors are the
  /// same three facts, and `errors.technician_ids[0]` is the contract both
  /// endpoints answer with.
  Future<CreateComplaintResult> assignWorkOrder({
    required String complaintId,
    required List<int> technicianIds,
  }) async {
    http.Response response;
    try {
      response = await _client.patch(
        Uri.parse('${ApiConfig.baseUrl}/api/facility/work-orders/$complaintId/assign'),
        headers: await _authHeaders(),
        body: jsonEncode({'technician_ids': technicianIds}),
      );
    } catch (_) {
      return const CreateComplaintResult(
        success: false,
        message: 'Could not reach the server. Assigning needs a connection.',
      );
    }

    if (response.statusCode == 200) {
      return const CreateComplaintResult(success: true);
    }

    if (response.statusCode == 422) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final errors = (body['errors'] as Map<String, dynamic>? ?? {});

      return CreateComplaintResult(
        success: false,
        message: errors.isEmpty
            ? body['message'] as String? ?? 'This job cannot be assigned.'
            : (errors.values.first as List).first as String,
        fieldErrors: errors.map((key, value) => MapEntry(key, (value as List).first as String)),
      );
    }

    if (response.statusCode == 403) {
      return const CreateComplaintResult(
        success: false,
        message: 'Assigning work is not something your role does.',
      );
    }

    return const CreateComplaintResult(
      success: false,
      message: 'Something went wrong. Please try again.',
    );
  }
}

/// What `lookup/vocabulary` returns: the server's own words, in the server's
/// own order.
///
/// 🎯 The ORDER matters. The web's create form defaults to
/// `priorities[0]?.value`, so the app does the same — the default is whatever
/// the server lists first, never a name written in Dart. That is how a default
/// stops being a second opinion.
class ComplaintVocabulary {
  const ComplaintVocabulary({required this.priorities, required this.statuses});

  final List<Vocab> priorities;
  final List<Vocab> statuses;
}
