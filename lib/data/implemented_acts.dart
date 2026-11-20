/// SPEC-024 Phase 5, Step 0 — what **this build** can actually perform.
///
/// 🔴 **The defect this closes.** ADR-013 makes the server's `actions` payload
/// open-ended on purpose — the server names the acts — and the app obeyed it
/// fully: every act was rendered, and an `allowed` one was rendered
/// **enabled**. But the dispatcher implements five of nine, so `pause`,
/// `resume`, `request_materials` and `request_extension` fell through to
/// *"This version of the app cannot do that yet."* **after the press.**
/// Measured on a real `in_progress` row with the seeded technician, `pause`
/// and `request_materials` came back ALLOWED — two enabled dead buttons on an
/// ordinary job, four across the states a working day produces.
///
/// 🎯 **The real finding was the absent check**: nothing in either repository
/// failed when the server offered an act no client implemented. Each of the
/// four was correctly out of scope when its endpoint shipped (SPEC-031,
/// SPEC-027, SPEC-028) — the gap was structural, not careless.
///
/// ⚠️ **This is NOT a second opinion about availability, and the distinction
/// is the whole of ADR-013.** The server still decides whether an act is
/// *allowed* and still writes the sentence explaining a refusal. This file
/// only records what this build has **code** for, so it can decline to present
/// as pressable a thing it cannot do. The alternative is what shipped: an
/// enabled button that fails.
library;

import '../contracts/work_order_acts.dart';

/// The acts `WorkOrderScreen` dispatches today.
const implementedActs = <String>{
  // SPEC-034 — the technician says he is on site, before he starts.
  'arrive',
  'start',
  'complete',
  'refer',
  'confirm_referral',
  'upload_evidence',
  // SPEC-024 Phase 5, Step 2 — the Facility Manager's five, and Step 3's
  // `assign` ahead of them.
  'assign',
  // SPEC-036 — the other half of `assign`.
  'unassign',
  'verify',
  'close',
  'cancel',
  'reject',
  'decide_extension',
  // SPEC-037 Phase 1 — the technician's own three. 🎯 They were the oldest
  // entries in the list below: shipped on the server by SPEC-031 and
  // SPEC-028, with no caller on this phone until today.
  'pause',
  'resume',
  'request_extension',
};

/// The acts the server offers that this build has no code for — **declared,
/// not discovered.**
///
/// 🔴 Every value here must be a deliberate decision, because
/// `the_app_implements_every_act_test.dart` requires this set and
/// [implementedActs] together to cover [workOrderActs] exactly. A tenth act
/// arriving from the ERP fails that test until somebody either implements it
/// or writes it down here.
///
/// 🔧 **2026-11-20: the "all four" this comment described are now ONE.**
/// Hashim's Step 0 boundary of 2026-11-18 — *"لا توسع النطاق إلى تكاملات
/// Pause/Resume أو Materials أو Extension في هذه المرحلة"* — kept the four
/// out of SPEC-024's scope, and SPEC-037 was opened to close them. Three
/// closed in its Phase 1; the fourth is held, not forgotten.
///
/// 🎯 **These sets describe the BUILD, never a role.** That is why the list
/// could honestly hold the manager's five as done while the technician's own
/// three were not — and why it can now hold thirteen acts and one absence.
const notYetImplementedActs = <String>{
  // 🔧 **SPEC-037, 2026-11-20: four became ONE.** `pause`, `resume` and
  // `request_extension` moved above when Phase 1 built them. What is left is
  // the one act that is **blocked rather than unbuilt**: Phase 2 of SPEC-037
  // is held on a question Hashim declined to turn into a decision, and until
  // it is answered the app must not present a parts request it cannot shape.
  'request_materials',
};

/// Whether this build can perform [act] at all.
bool thisBuildPerforms(String act) => implementedActs.contains(act);

/// What a person reads instead of pressing a button that would fail.
///
/// ⚠️ It describes the **app**, never the job. A technician told *"you cannot
/// do this"* would reasonably blame his permissions; he is told the build is
/// behind instead, which is the truth and is something he can act on.
const thisBuildCannot = 'This version of the app cannot do this yet — use the web, or update the app.';
