import 'dart:io';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../data/evidence_files.dart';
import '../data/implemented_acts.dart';

import '../data/work_order_repository.dart';
import '../models/assignee.dart';
import '../models/work_order.dart';
import '../services/complaint_service.dart';
import '../services/api_result.dart';
import '../theme/app_colors.dart';
import '../widgets/animated_gradient_background.dart';
import '../widgets/assignee_picker.dart';
import '../widgets/status_chip.dart';

/// SPEC-024 Phase 1, Step 4 — one work order, in full.
///
/// 🎯 **This screen is why the phase has two screens and not one expanding
/// row.** `GET /api/facility/work-orders/{id}` authorizes `view` **per job**,
/// so without a client that fetches a single work order by id, the one route
/// proving per-row authorization would be exercised by no client at all. The
/// list is scoped on the server; this is where that scope is *enforced* rather
/// than merely applied.
///
/// ⚠️ **Nothing here is actionable, and the screen says so.** Starting,
/// completing, referring and photographing arrive in Phase 3, and a job shown
/// with no way to act on it is honest only if it admits that.
class WorkOrderScreen extends StatefulWidget {
  const WorkOrderScreen({
    super.key,
    required this.id,
    required this.repository,
    required this.onSessionExpired,
    this.pickPhoto,
    this.service,
  });

  /// SPEC-024 Phase 5, Step 3 — the staff lookup, injected by tests only.
  ///
  /// ⚠️ It is a LOOKUP and never a second opinion about who may be
  /// assigned: the list it serves is the web's own, the trade only **marks**
  /// a man (SPEC-025: *the filter informs, never constrains*), and whether
  /// this manager may assign at all was answered by the server in the act's
  /// `allowed`.
  final ComplaintService? service;

  /// Injected by tests only. 🔴 `image_picker` and `path_provider` both work
  /// through platform channels, which `flutter test` does not have — so a
  /// screen that called them directly could not be tested at all. Returning
  /// the path of a file already kept in the app's own storage keeps the
  /// screen's own logic (the stage default, the pending state) provable.
  final Future<String?> Function(String jobId)? pickPhoto;

  final String id;

  /// SPEC-024 Phase 2 — the same repository the list uses, passed in rather
  /// than built here so both screens read one cache and one database
  /// connection.
  final WorkOrderSource repository;

  /// 🔴 A 401 ends the session; a 403 does not. The service draws that line,
  /// and this screen passes only the first of them upwards.
  final VoidCallback onSessionExpired;

  @override
  State<WorkOrderScreen> createState() => _WorkOrderScreenState();
}

class _WorkOrderScreenState extends State<WorkOrderScreen> {
  late final ComplaintService _service = widget.service ?? ComplaintService();

  bool _loading = true;
  String? _error;
  WorkOrder? _job;

  /// D5, as on the list: a cached job says when it was saved. 🔴 And a
  /// **403** is never answered from the cache — the repository evicts the row,
  /// because the server has just said it is not this man's.
  DateTime? _syncedAt;
  String? _staleNotice;

  /// 🔴 SPEC-024 Phase 3 (D2) — an act recorded here and not yet sent.
  /// **The status is NOT changed optimistically.** An app that showed
  /// `completed` the moment a man pressed the button would be a second author
  /// of the fact, and would have to walk the status backwards when the server
  /// refused — so he would have seen a completion that never happened. This
  /// project has already shipped one figure that was true at a moment and
  /// presented as current; *pending* is the honest shape.
  String? _pendingNotice;

  bool _acting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final result = await widget.repository.one(widget.id);

    if (!mounted) return;

    switch (result) {
      case ApiSuccess(:final data):
        setState(() {
          _job = data.data;
          _syncedAt = data.syncedAt;
          _staleNotice = data.isStale ? data.notice : null;
          _loading = false;
        });
      case ApiFailure(:final kind, :final message):
        if (kind == ApiErrorKind.sessionExpired) {
          widget.onSessionExpired();
          return;
        }
        // ⚠️ A 403 lands here like any other refusal, and that is deliberate:
        // "this work order is not assigned to you" is a fact the technician
        // should read, not an event the app should act on.
        setState(() {
          _error = message;
          _loading = false;
        });
    }
  }

  Future<void> _perform(WorkOrderAction act) async {
    if (_acting) return;

    // ⚠️ A referral needs the provider's name, and there is no provider
    // master data anywhere in this project — so it is free text, and that is
    // a question for Sandan rather than a dropdown the app invents.
    String? referredTo;

    if (act.value == 'refer') {
      referredTo = await _askForProvider();

      if (referredTo == null || referredTo.trim().isEmpty) return;
    }

    // 🔴 **SPEC-024 Phase 5 Step 2 — cancelling and handing back each need a
    // STATED CAUSE, and the server refuses a blank one in the domain** (the
    // rule moved into `ComplaintLifecycleService::transition()` on
    // 2026-11-19). Asking here is not a second copy of that rule: it is the
    // difference between a manager typing a sentence and a manager meeting a
    // 422 he cannot act on.
    String? reason;

    if (act.value == 'cancel' || act.value == 'reject') {
      reason = await _askForReason(act);

      if (reason == null || reason.trim().isEmpty) return;
    }

    // 🔴 **Ruling 4 (Hashim, 2026-11-19): the extension decision lives on
    // THIS screen and opens a dialog** — *"من شاشة تفاصيل أمر العمل؛ لأنه
    // يحتاج إلى approved وnote"*. It is the only one of the manager's five
    // that is not a single tap: two fields, one of which the domain
    // *requires* when the answer is no.
    _ExtensionDecision? decision;

    if (act.value == 'decide_extension') {
      decision = await _askForExtensionDecision();

      if (decision == null) return;
    }

    // 🔴 **SPEC-024 Phase 5, Step 3 — assigning asks WHO first.** It is
    // the second act on this screen that is not a single tap, and like the
    // extension decision it lives here and never on a queue row (ruling 4).
    List<int>? chosen;

    if (act.value == 'assign') {
      chosen = await _askWhoTakesIt();

      // ⚠️ An empty choice CANCELS rather than sending: the server
      // validates `technician_ids` as `min:1`, and meeting a 422 for a form
      // the app could answer itself is what the reason dialogs already avoid.
      if (chosen == null || chosen.isEmpty) return;
    }

    setState(() => _acting = true);

    if (act.value == 'upload_evidence') {
      setState(() => _acting = false);
      await _photograph();

      return;
    }

    final result = switch (act.value) {
      // 🔴 **SPEC-034 — a single tap, and no dialog**: arrival has nothing
      // to type. ⚠️ The repository stamps the instant HERE, on the phone, so
      // a queued act drained hours later still reports when he arrived.
      'arrive' => await widget.repository.arrive(widget.id),
      'start' => await widget.repository.start(widget.id),
      'complete' => await widget.repository.complete(widget.id),
      'refer' => await widget.repository.refer(widget.id, referredTo!.trim()),
      'confirm_referral' => await widget.repository.confirmReferral(widget.id),

      // ─── SPEC-024 Phase 5, Steps 2–3 — the Facility Manager's six ───
      //
      // ⚠️ None of these is queued: the repository sends them once. A
      // manager's judgement drained hours later would land on a job that
      // has moved.
      'assign' => await widget.repository.assign(widget.id, chosen!),
      'verify' => await widget.repository.verify(widget.id),
      'close' => await widget.repository.close(widget.id),
      'cancel' => await widget.repository.cancel(widget.id, reason!.trim()),
      'reject' => await widget.repository.reject(widget.id, reason!.trim()),
      'decide_extension' => await widget.repository.decideExtension(
        widget.id,
        approved: decision!.approved,
        note: decision.note,
      ),

      _ => const ActResult(ActOutcome.refused, message: 'This version of the app cannot do that yet.'),
    };

    if (!mounted) return;

    setState(() {
      _acting = false;

      switch (result.outcome) {
        case ActOutcome.applied:
          // ✅ The status moved because the SERVER moved it, and the response
          // already carries the acts available next.
          _job = result.job ?? _job;
          _pendingNotice = null;
        case ActOutcome.pending:
          _pendingNotice = '${act.label}: recorded on this phone — not yet sent.';
        case ActOutcome.refused:
          _pendingNotice = null;
      }
    });

    if (result.outcome == ActOutcome.refused && result.message != null) {
      // 🔴 The SERVER's sentence, not one written here. The lifecycle's
      // refusals are already written for a person to read.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message!)),
      );
    }
  }

  /// 🔴 **The default is a default and never a lock.** Only the man holding
  /// the camera knows what the photograph shows; the default saves a tap in
  /// the common case, and a technician who photographs finished work and is
  /// given no way to say so would either mislabel it or not take it.
  String _defaultStage() {
    const done = {'completed', 'verified', 'closed'};

    return done.contains(_job?.status.value) ? 'after' : 'before';
  }

  Future<void> _photograph() async {
    final stage = await _askForStage(_defaultStage());

    if (stage == null) return;

    final path = await (widget.pickPhoto ?? _pickFromCamera)(widget.id);

    if (path == null || !mounted) return;

    setState(() => _acting = true);

    final result = await widget.repository.uploadEvidence(
      widget.id,
      filePath: path,
      stage: stage,
      // 🎯 Sent because a queue makes the gap between capture and arrival
      // real, and the server keeps the two timestamps apart on purpose.
      capturedAt: DateTime.now(),
    );

    if (!mounted) return;

    setState(() {
      _acting = false;
      _pendingNotice = result.isPending
          ? 'Photograph: recorded on this phone — not yet sent.'
          : null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(switch (result.outcome) {
          ActOutcome.applied => 'Photograph sent.',
          ActOutcome.pending => 'Photograph saved on this phone. It will be sent when there is a signal.',
          ActOutcome.refused => result.message ?? 'The server refused the photograph.',
        }),
      ),
    );
  }

  /// ⚠️ The camera **and** the gallery. The gallery is not a convenience:
  /// a technician may photograph a job before he opens it, and that is the
  /// basement case this whole phase is about.
  Future<String?> _pickFromCamera(String jobId) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photograph'),
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose one already taken'),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source == null) return null;

    final picked = await ImagePicker().pickImage(source: source, imageQuality: 85);

    if (picked == null) return null;

    // 🔴 Copied into the app's own storage before it is queued. A picker
    // hands back a temporary file the OS may delete, and a queue item
    // pointing at nothing is a photograph silently lost.
    return EvidenceFiles(directory: getApplicationDocumentsDirectory)
        .keep(File(picked.path), jobId: jobId);
  }

  Future<String?> _askForStage(String fallback) => showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('What does the photograph show?'),
          content: const Text('The server records this against the job.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('before'),
              child: Text(fallback == 'before' ? 'Before (suggested)' : 'Before'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('after'),
              child: Text(fallback == 'after' ? 'After (suggested)' : 'After'),
            ),
          ],
        ),
      );

  Future<String?> _askForProvider() {
    final controller = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Waiting on a provider'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Who is it with?',
            hintText: 'e.g. the water company',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Record it'),
          ),
        ],
      ),
    );
  }

  /// SPEC-024 Phase 5 Step 2 — the stated cause a cancellation or a hand-back
  /// requires.
  ///
  /// ⚠️ **The act's own label is the title**, so the manager is never asked
  /// *"why?"* without being told what he is answering about — the two acts
  /// reach this dialog by different buttons and must not look identical in
  /// it.
  /// SPEC-024 Phase 5, Step 3 — **who takes this job?**
  ///
  /// 🔴 **The men already on the job are PRE-SELECTED, and that is a
  /// correctness decision rather than a convenience.** The server assigns with
  /// `syncWithoutDetaching`: it adds and never removes. A picker that opened
  /// empty would read as *nobody is on this job*, and a manager would re-pick
  /// the man already there — or, worse, believe he had replaced him.
  ///
  /// 🔴 **So the sheet says out loud what it cannot do.** Nothing in the
  /// entire ERP can take a human-assigned technician off a job: the only
  /// `detach()` in the application replaces the SYSTEM's own automatic
  /// assignment (SPEC-031 Step 8). Hashim put that capability out of scope on
  /// 2026-11-19 — see `SPEC-024-finding-nobody-can-be-taken-off-a-job.md` —
  /// and an absence a manager discovers by being surprised is the thing that
  /// finding exists to prevent.
  ///
  /// ⚠️ **The trade only marks a man.** `fetchAssignees()` is asked with this
  /// job's category so the picker can show whose trade matches, and it
  /// excludes nobody (SPEC-025: *the filter informs, never constrains*).
  Future<List<int>?> _askWhoTakesIt() async {
    final job = _job;

    if (job == null) return null;

    // ⚠️ Already-assigned ids come back as STRINGS on the wire, like every id
    // in this payload. A silent `int.parse` failure here would quietly
    // unselect a man who is on the job, so anything unparseable is dropped
    // rather than guessed at.
    final current = job.technicians
        .map((person) => int.tryParse(person.id))
        .whereType<int>()
        .toSet();

    var chosen = Set<int>.from(current);
    var list = const AssigneeList.empty();
    var loading = true;

    // 🔴 Loaded BEFORE the sheet opens would mean a frozen screen with no
    // explanation; loaded inside it, the picker shows its own spinner.
    final future = _service.fetchAssignees(categoryId: job.categoryId);

    if (!mounted) return null;

    return showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          if (loading) {
            future.then((result) {
              if (!sheetContext.mounted) return;

              setSheetState(() {
                list = result;
                loading = false;
              });
            });
          }

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Hand the job to somebody',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  // 🔴 The sentence the finding document asks for.
                  const Text(
                    'Adding somebody does not take anybody off this job.',
                    key: Key('assign-adds-only-notice'),
                    style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Assigning needs a connection — it is not saved on this phone.',
                    style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 14),
                  Flexible(
                    child: SingleChildScrollView(
                      child: AssigneePicker(
                        list: list,
                        selected: chosen,
                        loading: loading,
                        onChanged: (next) => setSheetState(() => chosen = next),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        key: const Key('assign-dismiss'),
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        child: const Text('Not now'),
                      ),
                      TextButton(
                        key: const Key('assign-confirm'),
                        // ⚠️ Disabled when nothing would change: the server
                        // refuses an empty list, and re-sending exactly the
                        // men already on the job is a request that asserts
                        // nothing.
                        onPressed: chosen.isEmpty || setEquals(chosen, current)
                            ? null
                            : () => Navigator.of(sheetContext).pop(chosen.toList()),
                        child: const Text('Assign'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<String?> _askForReason(WorkOrderAction act) {
    final controller = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(act.label),
        content: TextField(
          key: const Key('act-reason-field'),
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: 'Why?',
            hintText: act.value == 'cancel'
                ? 'e.g. reported twice; the other work order covers it'
                : 'e.g. this needs the electrical team',
          ),
        ),
        actions: [
          TextButton(
            key: const Key('act-reason-dismiss'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Not now'),
          ),
          TextButton(
            key: const Key('act-reason-confirm'),
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(act.label),
          ),
        ],
      ),
    );
  }

  /// 🔴 **Ruling 4's dialog: `approved` and a note, on the DETAIL screen.**
  ///
  /// ⚠️ **Grant and Refuse are two buttons, not a switch with a confirm.**
  /// The decision is the act; making the manager set a toggle and then press
  /// *OK* invites the commonest mistake there is — pressing OK on the
  /// default.
  ///
  /// 🔴 **A refusal with no note is refused by the DOMAIN** (*"refusing more
  /// time requires a reason"*), so *Refuse* is disabled until something is
  /// typed. ✅ A grant may carry a note and need not.
  Future<_ExtensionDecision?> _askForExtensionDecision() {
    final controller = TextEditingController();

    return showDialog<_ExtensionDecision>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Request for more time'),
          content: TextField(
            key: const Key('extension-note-field'),
            controller: controller,
            autofocus: true,
            maxLines: 3,
            onChanged: (_) => setDialogState(() {}),
            decoration: const InputDecoration(
              labelText: 'Note',
              hintText: 'Required to refuse; optional to grant',
            ),
          ),
          actions: [
            TextButton(
              key: const Key('extension-dismiss'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Not now'),
            ),
            TextButton(
              key: const Key('extension-refuse'),
              onPressed: controller.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(
                        _ExtensionDecision(approved: false, note: controller.text),
                      ),
              child: const Text('Refuse'),
            ),
            TextButton(
              key: const Key('extension-grant'),
              onPressed: () => Navigator.of(context).pop(
                _ExtensionDecision(approved: true, note: controller.text),
              ),
              child: const Text('Grant'),
            ),
          ],
        ),
      ),
    );
  }

  String _syncedLabel() {
    final at = _syncedAt;
    if (at == null) return '';

    final minute = at.minute.toString().padLeft(2, '0');

    return ' at ${at.hour.toString().padLeft(2, '0')}:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedGradientBackground(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Text(
                      'Work Order',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: Text('Loading…', style: TextStyle(color: AppColors.textMuted)),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextButton(onPressed: _load, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }

    final job = _job!;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Row(
          children: [
            StatusChip(status: job.status),
            const SizedBox(width: 8),
            Text(
              job.priority.label,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (job.reference != null)
          Text(
            job.reference!,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        const SizedBox(height: 6),
        Text(
          job.description,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, height: 1.5),
        ),
        const SizedBox(height: 22),
        _Field('Location', job.location),
        _Field('Category', [job.category, job.subcategory].whereType<String>().join(' · ')),
        _Field(
          // §9.9: several technicians, none ranked above another. The pivot
          // carries no `is_lead`, so this must not imply an order.
          job.technicians.length == 1 ? 'Assigned to' : 'Assigned to (${job.technicians.length})',
          job.technicians.isEmpty
              ? 'Nobody'
              : job.technicians.map((t) => t.name).join(', '),
        ),
        const SizedBox(height: 10),
        _SlaPanel(sla: job.sla),
        const SizedBox(height: 18),
        // 🔴 D5: a cached job says so. The SLA panel above is read from
        // the server's own booleans, and a stale one could be hours old —
        // presenting it as current is the defect that put a permanent
        // "SLA BREACHED" on a finished job.
        if (_staleNotice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              '${_staleNotice!} Showing the copy saved${_syncedLabel()} on this phone.',
              style: const TextStyle(color: AppColors.warning, fontSize: 11.5),
            ),
          )
        else if (_syncedAt != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'Updated${_syncedLabel()}.',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5),
            ),
          ),
        // ⚠️ The "read-only for now" line is GONE. It would now be false, and
        // a stale reassurance is worse than none.
        if (_pendingNotice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _pendingNotice!,
              style: const TextStyle(color: AppColors.warning, fontSize: 12.5),
            ),
          ),
        _ActionsPanel(
          actions: job.actions,
          busy: _acting,
          onAct: _perform,
        ),
      ],
    );
  }
}


/// SPEC-024 Phase 3, Step 5 — the buttons, rendered **from the server's
/// `actions` block**.
///
/// 🔴 **Nothing in Dart decides what is available.** An allowed act acts; a
/// refused one is disabled and shows the server's reason underneath it. The
/// alternative was a copy of the transition map, the referral rules and a
/// role→permission table in the app — four server facts, one of which (the
/// permissions) the login payload does not even send.
class _ActionsPanel extends StatelessWidget {
  const _ActionsPanel({required this.actions, required this.busy, required this.onAct});

  final List<WorkOrderAction> actions;
  final bool busy;
  final Future<void> Function(WorkOrderAction act) onAct;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) {
      // ⚠️ A cached row written before this version has no acts. Saying so
      // beats showing a job with no buttons and no explanation.
      return const Text(
        'Refresh this job to see what you can do with it.',
        style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final act in actions)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilledButton(
                  // 🔴 **SPEC-024 Phase 5, Step 0 — the runtime detector.**
                  // An act this build has no code for is drawn DISABLED,
                  // where it used to be drawn enabled and fail after the
                  // press. ⚠️ This is not a second opinion about
                  // availability: the server still decides `allowed`, and the
                  // app only declines to offer what it cannot perform.
                  onPressed: act.allowed && !busy && thisBuildPerforms(act.value)
                      ? () => onAct(act)
                      : null,
                  child: Text(act.label),
                ),
                // The build's own limit is reported ahead of the server's
                // reason, because when this build cannot act at all the
                // server's sentence describes a decision that was never
                // reached.
                if (!thisBuildPerforms(act.value))
                  const Padding(
                    padding: EdgeInsets.only(top: 4, left: 2),
                    child: Text(
                      thisBuildCannot,
                      style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                    ),
                  )
                else if (!act.allowed && act.reason != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 2),
                    child: Text(
                      act.reason!,
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(color: AppColors.textPrimary, fontSize: 13.5)),
        ],
      ),
    );
  }
}

/// 🔴 **The breach is READ, never computed.**
///
/// `assignment_breached` and `arrival_breached` arrive as booleans the ERP
/// decided, because D4a's referred-time subtraction is part of what a breach
/// MEANS. Date arithmetic here would be a second definition of a breach, and
/// the first job that sat waiting on a water company would prove the two
/// disagree.
class _SlaPanel extends StatelessWidget {
  const _SlaPanel({required this.sla});

  final SlaState sla;

  @override
  Widget build(BuildContext context) {
    final breached = sla.hasBreached;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: breached ? AppColors.error.withValues(alpha: 0.5) : AppColors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            breached ? 'SLA BREACHED' : 'SLA',
            style: TextStyle(
              color: breached ? AppColors.error : AppColors.textMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 8),
          if (sla.cycleNumber == null)
            // ⚠️ A job with no cycle is not a job with no data — the server
            // sends the whole shape with nulls, so this states the fact
            // rather than rendering an empty panel that looks broken.
            const Text(
              'No SLA cycle has been opened for this job yet.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            )
          else ...[
            _SlaLine('Assignment', due: sla.assignmentDueAt, met: sla.assignedAt, breached: sla.assignmentBreached),
            _SlaLine('Arrival', due: sla.arrivalDueAt, met: sla.arrivedAt, breached: sla.arrivalBreached),
            if (sla.referredMinutes > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  // D4a: the clock stops while an external provider has it.
                  '${sla.referredMinutes} min excluded while referred',
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                ),
              ),
            if (sla.hasOpenReferral)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Waiting on an external provider.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 11.5),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _SlaLine extends StatelessWidget {
  const _SlaLine(this.label, {required this.due, required this.met, required this.breached});

  final String label;
  final DateTime? due;
  final DateTime? met;
  final bool breached;

  @override
  Widget build(BuildContext context) {
    String two(int n) => n.toString().padLeft(2, '0');
    String clock(DateTime d) => '${two(d.hour)}:${two(d.minute)}';

    final value = met != null
        ? 'done ${clock(met!)}'
        : due != null
            ? 'due ${clock(due!)}'
            : 'not recorded';

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12.5)),
          ),
          Text(
            value,
            style: TextStyle(
              color: breached ? AppColors.error : AppColors.textPrimary,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// SPEC-024 Phase 5 Step 2 — what the extension dialog returns.
///
/// ⚠️ A record would have done; a named class is used so that `approved` is
/// never read positionally. `(true, 'note')` and `(false, 'note')` differ by
/// one character at a call site and by everything in the ledger.
class _ExtensionDecision {
  const _ExtensionDecision({required this.approved, this.note});

  final bool approved;
  final String? note;
}
