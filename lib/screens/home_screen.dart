import 'package:flutter/material.dart';

import '../data/local_database.dart';
import '../data/queue_filters.dart';
import '../data/outbox.dart';
import '../data/work_order_repository.dart';
import '../data/work_order_store.dart';
import '../models/facility_user.dart';
import '../models/work_order.dart';
import '../models/work_order_summary.dart';
import '../services/api_result.dart';
import '../services/auth_service.dart';
import '../services/complaint_service.dart';
import '../theme/app_colors.dart';
import '../widgets/animated_gradient_background.dart';
import '../widgets/task_row_tile.dart';
import 'login_screen.dart';
import 'profile_screen.dart';
import 'queue_screen.dart';
import 'work_order_screen.dart';
import 'new_complaint_screen.dart';

/// Home/Dashboard screen, redesigned as a Premium Dark Enterprise /
/// Facility Operations UI (styled after the reference mockup Mujahid — the
/// Facility Manager — shared), but scoped to this app's two modules,
/// Maintenance and Cleaning. All content here is static placeholder data:
/// the Maintenance/Cleaning Spec hasn't been approved yet, so there is no
/// backend API to wire this to. See facility-app-scope-boundary memory —
/// Handover, Evacuation, Inventory and Procurement are intentionally
/// absent. This redesign is UI/UX only — no business logic, API, or
/// authorization change (Facility Manager-only complaint creation and the
/// technician/worker My Work split are preserved exactly as before).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.user, this.workOrderSource, this.complaintService});

  final FacilityUser user;

  /// Injected by tests only (SPEC-024 Phase 2). A default source opens the
  /// real database, and a widget test must not perform real I/O — see
  /// `WorkOrderSource`.
  final WorkOrderSource? workOrderSource;

  /// Injected by tests only (SPEC-024 Phase 5, Step 4). It serves the
  /// manager's four figures, and a widget test must not reach the network.
  final ComplaintService? complaintService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _authService = AuthService();

  /// One source for the screen and the list beneath it, so the sign-out
  /// warning and the rows read the same queue.
  late final WorkOrderSource _source =
      widget.workOrderSource ??
      WorkOrderRepository(
        userId: widget.user.id,
        store: WorkOrderStore(LocalDatabase.instance),
        outbox: Outbox(LocalDatabase.instance),
      );

  /// 🔴 **SPEC-024 Phase 3 (D8) — a man must not sign out unaware that work
  /// is still on this phone.** Phase 2 settled that the outbox is NOT cleared
  /// by a sign-out and is never sent under anybody else's token; what it could
  /// not do was *tell him*, having no screens. So a technician could sign out
  /// with three completions that exist nowhere else and be told nothing.
  ///
  /// 🎯 **It asks; it never refuses.** He may need to hand the phone over, and
  /// blocking a sign-out would make the app worse than the paper it replaces.
  Future<void> _handleLogout() async {
    final waiting = await _pendingCount();

    if (!mounted) return;

    if (waiting > 0 && !await _confirmSignOut(waiting)) return;

    await _authService.logout();
    if (!mounted) return;
    _toLogin();
  }

  Future<int> _pendingCount() async {
    try {
      return await _source.pendingCount();
    } catch (_) {
      // ⚠️ A sign-out must not fail because a database could not be opened.
      // Being unable to count is not a reason to keep a man signed in.
      return 0;
    }
  }

  Future<bool> _confirmSignOut(int waiting) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          waiting == 1
              ? 'One action has not been sent yet'
              : '$waiting actions have not been sent yet',
        ),
        // ⚠️ True to Phase 2's D3: the items are kept and will be sent under
        // HIS identity, never the next person's.
        content: const Text(
          'They are saved on this phone and will be sent the next time you '
          'sign in. Sign out anyway?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay signed in'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            // ⚠️ "anyway" rather than "Sign out": the menu item already says
            // that, and a dialogue whose button repeats the thing you just
            // pressed does not read as a question.
            child: const Text('Sign out anyway'),
          ),
        ],
      ),
    );

    return confirmed ?? false;
  }

  /// 🔴 **SPEC-024 Phase 1, Step 3 (D6) — the ERP stopped accepting the
  /// token.** `AuthService.restoreSession()` has promised since SPEC-003 that
  /// the token is *"trusted until an authenticated request comes back 401"*,
  /// and nothing fulfilled it: a technician whose token was revoked saw a list
  /// that failed to load, with no explanation and no way back.
  ///
  /// ⚠️ **Only a 401 reaches here.** A 403 means *this job is not yours* —
  /// which Phase 0 returns deliberately — and signing a man out for tapping
  /// the wrong row would be a bug wearing a security badge. The service draws
  /// that line; this method only acts on the side of it that ends a session.
  Future<void> _handleSessionExpired() async {
    await _authService.endExpiredSession();
    if (!mounted) return;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Your session has ended. Please sign in again.')));

    _toLogin();
  }

  Future<void> _openProfile() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfileScreen(
          user: widget.user,
          source: _source,
          // 🔴 One sign-out, not two. `_handleLogout` owns the pending-queue
          // question (Phase 3 D8), and a second implementation that skipped
          // that question would be the warning's first bug.
          onSignOut: _handleLogout,
        ),
      ),
    );

    // The queue may have drained while he was in there, and the markers on the
    // list are read from it.
    if (mounted) setState(() {});
  }

  void _toLogin() {
    Navigator.of(
      context,
    ).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (route) => false);
  }

  String get _roleLabel {
    switch (widget.user.role) {
      case FacilityRole.facilityManager:
        return 'Facility Manager';
      case FacilityRole.supervisor:
        return 'Supervisor';
      case FacilityRole.technician:
        return 'Technician';
      case FacilityRole.worker:
        return 'Worker';
    }
  }

  bool get _isFieldRole =>
      widget.user.role == FacilityRole.technician || widget.user.role == FacilityRole.worker;

  void _notImplemented(String feature) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$feature — coming soon')));
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dateLabel = '${_weekday(now.weekday)}, ${now.day} ${_month(now.month)}';

    return Scaffold(
      extendBody: true,
      body: AnimatedGradientBackground(
        child: SafeArea(
          bottom: false,
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                sliver: SliverToBoxAdapter(
                  child: _Header(
                    name: widget.user.name,
                    roleLabel: _roleLabel,
                    dateLabel: dateLabel,
                    onLogout: _handleLogout,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 110),
                sliver: SliverToBoxAdapter(
                  child: _isFieldRole
                      ? _MyWorkView(
                          userId: widget.user.id,
                          repository: _source,
                          onAction: _notImplemented,
                          onSessionExpired: _handleSessionExpired,
                        )
                      : _ManagerDashboardView(
                          onAction: _notImplemented,
                          canCreateComplaint: widget.user.role == FacilityRole.facilityManager,
                          userId: widget.user.id,
                          onSessionExpired: _handleSessionExpired,
                          service: widget.complaintService,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _BottomNavBar(
        onOtherTap: _notImplemented,
        onProfile: _openProfile,
        isFieldRole: _isFieldRole,
      ),
    );
  }

  static String _weekday(int day) =>
      const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][day - 1];

  static String _month(int month) => const [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ][month - 1];
}

// ─────────────────────────── Header ───────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.roleLabel,
    required this.dateLabel,
    required this.onLogout,
  });

  final String name;
  final String roleLabel;
  final String dateLabel;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Good morning, $name 👋',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$roleLabel · $dateLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _ProfileButton(name: name, onLogout: onLogout),
      ],
    );
  }
}

class _ProfileButton extends StatelessWidget {
  const _ProfileButton({required this.name, required this.onLogout});

  final String name;
  final VoidCallback onLogout;

  String get _initial => name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Account',
      offset: const Offset(0, 48),
      color: AppColors.surfaceElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      onSelected: (value) {
        if (value == 'logout') onLogout();
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: Text(
            name,
            style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'logout',
          child: Row(
            children: [
              Icon(Icons.logout, size: 18, color: AppColors.error),
              SizedBox(width: 10),
              Text('Sign out', style: TextStyle(color: AppColors.error)),
            ],
          ),
        ),
      ],
      child: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: AppColors.accentGradient,
          border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1),
        ),
        child: Text(
          _initial,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

// ─────────────────────────── Section title ───────────────────────────

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── Manager dashboard ───────────────────────────

/// SPEC-024 Phase 1, Step 3 — the Facility Manager's home, with the invented
/// figures taken out.
///
/// 🔴 **This showed four statistics — Open Complaints, Pending Tasks,
/// Completed Today, Overdue — and all four came from `MockDashboardData`.**
/// They were not stale or approximate; they were **made up**, and nothing on
/// the screen said so. A manager reading "3 Overdue" had no way to know the
/// number described nothing.
///
/// ✅ They are **removed rather than marked as demo**. A figure labelled
/// *demo* is still a figure people quote, and the manager already has these
/// numbers — correct ones — in the browser. The real dashboard is Phase 5,
/// and it will be built on the field data Phases 1–3 start producing.
///
/// ✅ **What stays is what was always real:** raising a complaint, which this
/// app has done since SPEC-004.
/// 🔧 **SPEC-024 Phase 5, Step 4 — the four figures are back, and this time
/// they are counted by the ERP.** The notice below is **discharged, not
/// deleted**: it promised the numbers would return built on real data, and
/// `GET facility/work-orders/summary` is that. It still renders whenever the
/// figures cannot be fetched, because a zero and a failure must never look
/// alike on the screen that learnt that lesson.
class _ManagerDashboardView extends StatefulWidget {
  const _ManagerDashboardView({
    required this.onAction,
    required this.canCreateComplaint,
    required this.userId,
    required this.onSessionExpired,
    this.service,
  });

  /// Injected by tests only.
  final ComplaintService? service;

  final void Function(String feature) onAction;
  final bool canCreateComplaint;

  /// SPEC-024 Phase 5, Step 1 — the queue needs the signed-in user, because
  /// `WorkOrderRepository` scopes every read and write by it.
  final int userId;
  final VoidCallback onSessionExpired;

  @override
  State<_ManagerDashboardView> createState() => _ManagerDashboardViewState();
}

class _ManagerDashboardViewState extends State<_ManagerDashboardView> {
  late final ComplaintService _service = widget.service ?? ComplaintService();

  WorkOrderSummary? _summary;
  bool _loadingFigures = true;

  @override
  void initState() {
    super.initState();
    _loadFigures();
  }

  /// ⚠️ **No cache, deliberately.** The queue has no offline story by design
  /// (Step 1), and a count read from a snapshot is one a manager would act on.
  Future<void> _loadFigures() async {
    final summary = await _service.fetchSummary();

    if (!mounted) return;

    setState(() {
      _summary = summary;
      _loadingFigures = false;
    });
  }

  void _openQueue({QueueFilters filters = const QueueFilters()}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => QueueScreen(
          userId: widget.userId,
          onSessionExpired: widget.onSessionExpired,
          initialFilters: filters,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('Quick Action'),
        _PrimaryActionCard(
          title: 'New Complaint',
          subtitle: 'Report a facility issue',
          icon: Icons.add_rounded,
          onTap: widget.canCreateComplaint
              ? () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => NewComplaintScreen(userId: widget.userId)),
                )
              : () => widget.onAction('New Complaint'),
        ),
        const SizedBox(height: 14),
        // 🎯 **SPEC-024 Phase 5, Step 1 — the manager's own work finally has
        // a door.** Until now this screen offered him one action (raise a
        // complaint) and a notice that everything else lives in the browser.
        _PrimaryActionCard(
          key: const Key('open-work-queue'),
          title: 'Work Queue',
          subtitle: 'Filter by status, priority, building, category or technician',
          icon: Icons.filter_list_rounded,
          onTap: _openQueue,
        ),
        const SizedBox(height: 28),
        const _SectionTitle('Right now'),
        _figures(),
        const SizedBox(height: 28),
      ],
    );
  }

  /// 🔴 **Three states, and the third is the one that matters.** Loading,
  /// four figures, or — when the server could not be reached or answered
  /// anything but 200 — **no figure at all**, with the reason. A zero and a
  /// failure must never look alike on this screen: it is the screen that
  /// showed four invented counts, and the notice below is the one that
  /// replaced them.
  Widget _figures() {
    if (_loadingFigures) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(child: SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }

    final summary = _summary;

    if (summary == null) {
      return Container(
        key: const Key('figures-unavailable'),
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The figures could not be loaded',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              // 🎯 The standard this screen set when the invented counts were
              // deleted: "removed rather than left to be quoted".
              'No number is shown rather than a wrong one. They are counted by the '
              'server, so this needs a connection — the web app has them meanwhile.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('figures-retry'),
                onPressed: () {
                  setState(() => _loadingFigures = true);
                  _loadFigures();
                },
                child: const Text('Try again'),
              ),
            ),
          ],
        ),
      );
    }

    return Row(
      children: [
        _FigureTile(
          key: const Key('figure-open'),
          label: 'Open',
          value: summary.open,
          onTap: _openQueue,
        ),
        const SizedBox(width: 10),
        _FigureTile(
          key: const Key('figure-in-progress'),
          label: 'In progress',
          value: summary.inProgress,
          onTap: () => _openQueue(filters: const QueueFilters(status: 'in_progress')),
        ),
        const SizedBox(width: 10),
        _FigureTile(
          key: const Key('figure-completed-today'),
          label: 'Done today',
          value: summary.completedToday,
          onTap: () => _openQueue(filters: const QueueFilters(status: 'completed')),
        ),
        const SizedBox(width: 10),
        // 🔴 **"Late to assign", never "Late".** The tile counts ASSIGNMENT
        // breaches alone; the queue's `breached` filter is the wider set
        // (assignment OR arrival), so this tile opens a list that may be
        // LONGER than its own number. Two names, because they are two sets —
        // and the arrival half is the figure Hashim forbade until SPEC-034.
        _FigureTile(
          key: const Key('figure-overdue'),
          label: 'Late to assign',
          value: summary.overdueAssignment,
          onTap: () => _openQueue(filters: const QueueFilters(breached: true)),
        ),
      ],
    );
  }
}

/// SPEC-024 Phase 5, Step 4 — one figure, and a door into the list behind it.
class _FigureTile extends StatelessWidget {
  const _FigureTile({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final int value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$value',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 11, height: 1.3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimaryActionCard extends StatelessWidget {
  const _PrimaryActionCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            gradient: AppColors.accentGradient,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: AppColors.accent.withValues(alpha: 0.32),
                blurRadius: 22,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── Work list (shared) ───────────────────────────

class _WorkListEntry {
  const _WorkListEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.time,
    this.onTap,
  });

  /// SPEC-024 Phase 1, Step 4 — a row has somewhere to go.
  final VoidCallback? onTap;

  final IconData icon;
  final String title;
  final String subtitle;
  final Vocab status;
  final String time;
}

/// Premium solid-surface list container — a subtle divider between rows,
/// no border wrapping each individual row (per the redesign direction).
class _WorkList extends StatelessWidget {
  const _WorkList({required this.items});

  final List<_WorkListEntry> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Center(
          child: Text(
            'Nothing here right now.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: AppColors.divider),
            TaskRowTile(
              icon: items[i].icon,
              title: items[i].title,
              subtitle: items[i].subtitle,
              status: items[i].status,
              time: items[i].time,
              onTap: items[i].onTap,
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────── My Work (technician/worker) ───────────────────────────

/// SPEC-024 Phase 1, Step 3 — the field user's real work, from the ERP.
///
/// 🔴 **This widget read `MockDashboardData.myWork` until today**, which is
/// why the app showed a technician three invented jobs and no way to tell they
/// were invented. The fixture is deleted; this is the first screen in the
/// app's history that shows what the server actually holds.
///
/// ⚠️ **It does not filter.** `Complaint::scopeVisibleTo()` scopes the list on
/// the server, so there is no "mine" predicate to apply here — an app-side
/// filter would be a second answer to a question ADR-012 settled.
///
/// ⚠️ **And it does not fetch the vocabulary.** `lookup/vocabulary` is
/// guarded by `create` on Complaint, so a technician is **denied** it
/// (measured). Each row carries its own `{value, label}`, which is why the
/// payload was built that way.
class _MyWorkView extends StatefulWidget {
  const _MyWorkView({
    required this.userId,
    required this.onAction,
    required this.onSessionExpired,
    this.repository,
  });

  /// 🔴 The signed-in `users.id`. Everything this screen reads from the device
  /// is scoped by it — ADR-012's scope has to survive being written to a disk.
  final int userId;

  final void Function(String feature) onAction;
  final VoidCallback onSessionExpired;

  /// Injected by tests only. A default repository opens the real database,
  /// which `flutter test` has no native library for.
  final WorkOrderSource? repository;

  @override
  State<_MyWorkView> createState() => _MyWorkViewState();
}

class _MyWorkViewState extends State<_MyWorkView> {
  late final WorkOrderSource _repository =
      widget.repository ??
      WorkOrderRepository(
        userId: widget.userId,
        store: WorkOrderStore(LocalDatabase.instance),
        outbox: Outbox(LocalDatabase.instance),
      );

  bool _loading = true;
  String? _error;
  List<WorkOrder> _jobs = const [];

  /// 🔴 **SPEC-024 Phase 2 (D5) — where the list came from, and when.** A
  /// cache turns *"my work"* into *"my work as of a time"*, and showing
  /// yesterday's list with no marker is the same class of defect as the SLA
  /// breach that sat on a finished job for ever: a figure that was true once,
  /// presented as if it were true now.
  DateTime? _syncedAt;
  String? _staleNotice;

  /// 🔴 D2 — the jobs carrying work this phone has not sent. If having no
  /// signal is rare, then a queued item is a rare event; a rare state nobody
  /// can see is the one that will be misread when it happens.
  Set<String> _pendingJobs = const {};

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

    final result = await _repository.myWork();
    final pending = await _pendingJobIds();

    if (!mounted) return;

    switch (result) {
      case ApiSuccess(:final data):
        setState(() {
          _jobs = data.data;
          _pendingJobs = pending;
          _syncedAt = data.syncedAt;
          // ⚠️ A network failure with rows on the disk is a **note**, not an
          // error: a retry button is the wrong thing to show a man who is
          // holding a perfectly usable list, because it teaches him the app is
          // broken when it is working as designed.
          _staleNotice = data.isStale ? data.notice : null;
          _loading = false;
        });
      case ApiFailure(:final kind, :final message):
        // 🔴 A 401 ends the session; a 403 does NOT. The service already
        // drew that line — this screen only acts on it.
        if (kind == ApiErrorKind.sessionExpired) {
          widget.onSessionExpired();
          return;
        }
        setState(() {
          _error = message;
          _loading = false;
        });
    }
  }

  Future<Set<String>> _pendingJobIds() async {
    try {
      return await _repository.pendingJobIds();
    } catch (_) {
      return const {};
    }
  }

  /// ⚠️ The time the app last heard from the **server**, never a row's own
  /// timestamp. An empty string when it has never heard at all, so the
  /// sentence around it still reads.
  String _syncedLabel() {
    final at = _syncedAt;
    if (at == null) return '';

    final minute = at.minute.toString().padLeft(2, '0');

    return ' at ${at.hour.toString().padLeft(2, '0')}:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle('My Work Orders'),
        if (_loading)
          const _WorkListMessage(text: 'Loading your work\u2026')
        else if (_error != null)
          _WorkListMessage(text: _error!, onRetry: _load)
        else if (_jobs.isEmpty)
          // ⚠️ An empty list is an ordinary morning, not a fault. Saying
          // "nothing here" would read as a screen that failed to load.
          const _WorkListMessage(text: 'No work orders are assigned to you right now.')
        else
          _WorkList(
            items: [
              for (final job in _jobs)
                _WorkListEntry(
                  icon: Icons.build_outlined,
                  title: job.reference == null
                      ? job.description
                      : '${job.reference} \u00b7 ${job.description}',
                  subtitle: job.location,
                  status: job.status,
                  // ⚠️ Unsent work outranks both the breach and the priority
                  // here, because it is the one thing the technician can act
                  // on — the other two are facts about the job.
                  time: _pendingJobs.contains(job.id)
                      ? 'Not yet sent'
                      : (job.sla.hasBreached ? 'SLA breached' : job.priority.label),
                  // 🔴 The id, not the reference. `complaint_number` is
                  // generated by `CreateComplaintAction` and is NULL on a row
                  // written any other way — routing by it would 404 on exactly
                  // the jobs an import created.
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => WorkOrderScreen(
                        id: job.id,
                        repository: _repository,
                        onSessionExpired: widget.onSessionExpired,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 10),
        // 🔴 D5: said in words, because the alternative is a screen that
        // cannot tell the technician whether he is looking at today's work.
        if (_staleNotice != null)
          Text(
            '${_staleNotice!} Showing the work saved${_syncedLabel()} on this phone.',
            style: const TextStyle(color: AppColors.warning, fontSize: 11.5),
          )
        else if (_syncedAt != null)
          Text(
            'Updated${_syncedLabel()}.',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 11.5),
          ),
        const SizedBox(height: 6),
        // ⚠️ Said out loud rather than implied by the absence of buttons: a
        // screen that shows a job with no way to start it is honest only if it
        // says the actions are coming.
        const Text(
          'Read-only for now \u2014 starting, completing and photographing a job arrive next.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
        ),
      ],
    );
  }
}

/// One message box for every non-list state, so loading, failure and emptiness
/// cannot drift into looking like three different screens.
class _WorkListMessage extends StatelessWidget {
  const _WorkListMessage({required this.text, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 10),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────── Bottom navigation ───────────────────────────

/// Visual structure only — Home is the real, current screen; the other
/// three are intentionally not implemented yet (no Work/Complaints/Profile
/// screens exist), so tapping them surfaces the same honest "coming soon"
/// feedback used elsewhere on this screen rather than pretending to
/// navigate anywhere.
///
/// 🔧 **SPEC-024 Phase 1, corrected after the device run (2026-10-28).**
/// The Architecture Review D4 said the `Work` tab is REMOVED for a field role
/// once Home becomes *My Work*, and the Plan's Step 3 repeated it — and I
/// shipped Step 3 without doing it. Hashim's screenshots showed the tab still
/// there, under a Home screen that is already his work list.
///
/// 🎯 A tab that duplicates the screen under it is worse than a missing
/// one: it teaches a technician that tapping "Work" is how he reaches his
/// work, and then refuses.
class _BottomNavBar extends StatelessWidget {
  const _BottomNavBar({
    required this.onOtherTap,
    required this.onProfile,
    required this.isFieldRole,
  });

  final void Function(String feature) onOtherTap;

  /// ✅ SPEC-024 Phase 4 — `Profile` stops saying *coming soon*.
  /// ⚠️ `Complaints` still does: it is the Facility Manager's surface
  /// (Phase 5), deferred on purpose and not forgotten.
  final VoidCallback onProfile;

  /// For a technician or a worker, Home IS My Work.
  final bool isFieldRole;

  List<(IconData, String)> get _items => [
    const (Icons.home_rounded, 'Home'),
    if (!isFieldRole) const (Icons.assignment_outlined, 'Work'),
    const (Icons.report_problem_outlined, 'Complaints'),
    const (Icons.person_outline, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            for (var i = 0; i < _items.length; i++)
              Expanded(
                child: InkWell(
                  onTap: switch (_items[i].$2) {
                    'Home' => null,
                    'Profile' => onProfile,
                    final other => () => onOtherTap(other),
                  },
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _items[i].$1,
                          size: 22,
                          color: i == 0 ? AppColors.accentSoft : AppColors.textMuted,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _items[i].$2,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: i == 0 ? AppColors.accentSoft : AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
