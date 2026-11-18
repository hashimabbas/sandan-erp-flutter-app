import 'package:flutter/material.dart';

import '../data/work_order_repository.dart';
import '../models/facility_user.dart';
import '../services/auth_service.dart';
import '../theme/app_colors.dart';
import '../widgets/animated_gradient_background.dart';
import '../widgets/glass_card.dart';

/// SPEC-024 Phase 4, Step 3 — the account surface.
///
/// 🎯 **The screen exists for the queue, not for the name.** Phase 3 put a
/// warning on sign-out and promised the unsent work *a proper home*; this is
/// it. 🔴 And it is the only place SPEC-024 §6 **Q2** — *how long may work stay
/// "recorded on this phone"?* — can ever be answered with evidence: Phase 2
/// invented no expiry and recorded each item's age instead, precisely so that
/// the question would one day be settled by real numbers.
///
/// ⚠️ **Identity comes from the stored session, not the server.** There is no
/// `facility/me`, so if an administrator renames a man or changes his role the
/// app shows the old one until he signs in again. That is acceptable because
/// since **ADR-013** the app does not act on the role at all — what he may do
/// arrives per job, from the server. The label here is identity, not
/// authority.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.user,
    required this.source,
    required this.onSignOut,
    this.authService,
  });

  final FacilityUser user;

  final WorkOrderSource source;

  /// 🔴 Sign-out goes back to the caller rather than being re-implemented
  /// here. `HomeScreen` owns the pending-queue question (Phase 3 D8), and a
  /// second sign-out that skipped that question would be the warning's first
  /// bug.
  final Future<void> Function() onSignOut;

  /// Injected by tests only.
  final AuthService? authService;

  /// The version shown at the bottom. ⚠️ Hardcoded from `pubspec.yaml` rather
  /// than read through `package_info_plus`: one more native dependency to show
  /// one string is not worth it, and a stale number here is visible rather
  /// than dangerous.
  static const appVersion = '1.0.0+1';

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final AuthService _auth = widget.authService ?? AuthService();

  List<PendingAct> _pending = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final pending = await widget.source.pendingActs();

    if (!mounted) return;

    setState(() {
      _pending = pending;
      _loading = false;
    });
  }

  String get _roleLabel => switch (widget.user.role) {
        FacilityRole.facilityManager => 'Facility Manager',
        FacilityRole.supervisor => 'Supervisor',
        FacilityRole.technician => 'Technician',
        FacilityRole.worker => 'Worker',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedGradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
                  ),
                  const Text(
                    'Account',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                  children: [
                    GlassCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.user.name,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _roleLabel,
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _PendingSection(pending: _pending, loading: _loading),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _changePassword,
                      child: const Text('Change password'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: () async {
                        // The caller's sign-out, which asks about unsent work.
                        await widget.onSignOut();
                      },
                      child: const Text('Sign out'),
                    ),
                    const SizedBox(height: 20),
                    Center(
                      child: Text(
                        'Sandan Facility ${ProfileScreen.appVersion}',
                        style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _changePassword() async {
    final result = await showDialog<_PasswordAttempt>(
      context: context,
      builder: (context) => const _ChangePasswordDialog(),
    );

    if (result == null || !mounted) return;

    final outcome = await _auth.changePassword(
      currentPassword: result.current,
      newPassword: result.next,
    );

    if (!mounted) return;

    // 🔴 The SERVER's sentence on a refusal — "The password field must be at
    // least 8 characters" is written for a person, and anything this app wrote
    // instead would be a second description of the same rule.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(outcome.message ?? (outcome.success ? 'Password updated.' : 'That did not work.'))),
    );
  }
}

/// 🔴 The reason this screen was built. Every act still on the phone, oldest
/// first, with how long it has waited and why it is stuck.
class _PendingSection extends StatelessWidget {
  const _PendingSection({required this.pending, required this.loading});

  final List<PendingAct> pending;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Waiting to be sent',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          if (loading)
            const Text('Checking…', style: TextStyle(color: AppColors.textMuted, fontSize: 12))
          else if (pending.isEmpty)
            // ⚠️ Said plainly. "Nothing here" on a queue screen reads as a
            // screen that failed to load.
            const Text(
              'Everything you have done has reached the server.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            )
          else
            for (final act in pending)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${act.action} · waiting ${_age(act.createdAt)}',
                      style: const TextStyle(color: AppColors.warning, fontSize: 12.5),
                    ),
                    if (act.lastError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          // The server's own words, stored by the drain.
                          act.lastError!,
                          style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
          // ⚠️ No retry button and no delete button. Retrying happens on every
          // act and every list refresh, so a button would duplicate it — and
          // deleting a queued act is deleting work the server has never seen,
          // which is the one thing this screen must not make easy.
        ],
      ),
    );
  }

  static String _age(DateTime since) {
    final minutes = DateTime.now().difference(since).inMinutes;

    if (minutes < 1) return 'less than a minute';
    if (minutes < 60) return '$minutes minute${minutes == 1 ? '' : 's'}';

    final hours = minutes ~/ 60;

    if (hours < 24) return '$hours hour${hours == 1 ? '' : 's'}';

    final days = hours ~/ 24;

    return '$days day${days == 1 ? '' : 's'}';
  }
}

class _PasswordAttempt {
  const _PasswordAttempt(this.current, this.next);

  final String current;
  final String next;
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change password'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _current,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Current password'),
          ),
          TextField(
            controller: _next,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'New password'),
          ),
          TextField(
            controller: _confirm,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Repeat the new password'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 12)),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text(
              // ⚠️ Said before he tries, because a password change is the one
              // act in this app that is NOT queued — and a man who expects it
              // to behave like the others would believe it had worked.
              'This one needs a connection — it is not saved on the phone like your work is.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 11),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Change it'),
        ),
      ],
    );
  }

  void _submit() {
    // Only the two checks the app can make without the server: that something
    // was typed, and that the two new ones match. 🔴 Everything else — the
    // length, the strength, whether the current one is right — is the server's
    // to say, in its own words.
    if (_current.text.isEmpty || _next.text.isEmpty) {
      setState(() => _error = 'Fill in all three boxes.');

      return;
    }

    if (_next.text != _confirm.text) {
      setState(() => _error = 'The two new passwords do not match.');

      return;
    }

    Navigator.of(context).pop(_PasswordAttempt(_current.text, _next.text));
  }
}
