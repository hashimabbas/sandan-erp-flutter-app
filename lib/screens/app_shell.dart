import 'package:flutter/material.dart';

import '../data/local_database.dart';
import '../data/outbox.dart';
import '../data/queue_filters.dart';
import '../data/work_order_repository.dart';
import '../data/work_order_store.dart';
import '../models/facility_user.dart';
import '../services/auth_service.dart';
import '../services/complaint_service.dart';
import '../theme/app_colors.dart';
import 'home_screen.dart';
import 'login_screen.dart';
import 'new_complaint_screen.dart';
import 'profile_screen.dart';
import 'queue_screen.dart';

/// **The app's one shell: a tab bar over an `IndexedStack`.**
///
/// 🎯 **Hashim, 2026-11-21: *"نفّذ IndexedStack … تحسينات كبيرة تعني تجربة
/// التطبيق ككل"*.** Until now the bottom bar PUSHED a screen over Home, so the
/// bar vanished on the screen it had just opened, every return started that
/// screen from nothing, and the bar could never show where you were.
///
/// Now each tab is a **living** branch:
///
/// - 🔴 **`IndexedStack` keeps every tab alive.** The queue's filters, its
///   scroll position and the manager's figures survive a trip to Profile and
///   back — the state is not rebuilt, because the widget was never disposed.
/// - 🔴🔴 **Each tab owns its own `Navigator`.** Opening a work order pushes
///   INSIDE that tab, so the bar stays visible and `back` returns to the tab
///   you were in rather than to Home. Without this, one root navigator would
///   cover the bar with the detail screen — which is the behaviour this change
///   exists to end.
/// - ⚠️ **Sign-out and session expiry use `rootNavigator: true`**, and this is
///   the trap of the whole pattern: `Navigator.of(context)` inside a tab is
///   the TAB's navigator, so the login screen would open *inside a tab, under
///   the bar*, with the signed-out session still standing behind it.
///
/// 🔴 **Sign-out stays ONE implementation.** The pending-queue warning (Phase
/// 3 D8) lives here and nowhere else; `HomeScreen`'s header menu and the
/// Profile tab both call this one method, because a second sign-out that
/// skipped that question would be the warning's first bug.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.user,
    this.workOrderSource,
    this.complaintService,
    this.authService,
  });

  final FacilityUser user;

  /// Injected by tests only — a widget test must not open a real database.
  final WorkOrderSource? workOrderSource;
  final ComplaintService? complaintService;
  final AuthService? authService;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final AuthService _auth = widget.authService ?? AuthService();

  /// One source for the shell, the Home tab and the sign-out count, so the
  /// warning and the rows read the same queue.
  late final WorkOrderSource _source =
      widget.workOrderSource ??
      WorkOrderRepository(
        userId: widget.user.id,
        store: WorkOrderStore(LocalDatabase.instance),
        outbox: Outbox(LocalDatabase.instance),
      );

  int _index = 0;

  /// One key per tab, so each branch keeps its own history.
  final Map<AppTab, GlobalKey<NavigatorState>> _navigators = {};

  bool get _isFieldRole =>
      widget.user.role == FacilityRole.technician || widget.user.role == FacilityRole.worker;

  /// Only the Facility Manager holds `facility.complaints.create`.
  bool get _canCreateComplaint => widget.user.role == FacilityRole.facilityManager;

  /// 🔴 **A field role gets Home and Profile only, by measurement.** He holds
  /// no create permission and the queue endpoint returns **only his own
  /// assigned jobs**, so a `status: new` list is empty by construction — and
  /// an empty tab is worse than no tab. For him, Home IS his work.
  List<AppTab> get _tabs => [
    AppTab.home,
    if (!_isFieldRole) AppTab.work,
    if (!_isFieldRole) AppTab.complaints,
    AppTab.profile,
  ];

  GlobalKey<NavigatorState> _navigatorFor(AppTab tab) =>
      _navigators.putIfAbsent(tab, () => GlobalKey<NavigatorState>());

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    final media = MediaQuery.of(context);

    return PopScope(
      // ⚠️ The back button belongs to the tab you are standing in: it pops
      // that tab's own stack first, then returns you to Home, and only leaves
      // the app from Home with nothing pushed.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;

        final navigator = _navigatorFor(tabs[_index]).currentState;

        if (navigator != null && navigator.canPop()) {
          navigator.pop();

          return;
        }

        if (_index != 0) {
          setState(() => _index = 0);

          return;
        }

        if (mounted) Navigator.of(context, rootNavigator: true).maybePop();
      },
      child: Scaffold(
        extendBody: true,
        backgroundColor: AppColors.bgBottom,
        body: IndexedStack(
          index: _index,
          children: [
            for (final tab in tabs)
              // 🔴 A `Navigator` per tab: a detail screen opens inside the tab
              // and the bar stays where it is.
              //
              // 🔴🔴 **And the tab is TOLD how tall the bar is.** The bar floats
              // over the content (`extendBody`), so without this every screen
              // inside a tab lays out underneath it — measured, not feared: the
              // Complaints tab's *New complaint* button sat **under the bar**
              // and a tap landed on the bar instead. A widget test caught it
              // ("would not hit test on the specified widget"), which is the
              // second time this change was saved by asking the question in a
              // test rather than looking at a screenshot.
              //
              // ✅ Raising `viewPadding` is what makes it the SHELL's problem
              // once: `Scaffold` already moves its floating action button and
              // its body above that padding, so no screen in the app needs to
              // know a bar exists.
              MediaQuery(
                data: media.copyWith(
                  padding: media.padding.copyWith(bottom: media.padding.bottom + kShellBarHeight),
                  viewPadding: media.viewPadding.copyWith(
                    bottom: media.viewPadding.bottom + kShellBarHeight,
                  ),
                ),
                child: Navigator(
                  key: _navigatorFor(tab),
                  onGenerateRoute: (settings) => MaterialPageRoute(
                    settings: settings,
                    builder: (_) => _rootOf(tab),
                  ),
                ),
              ),
          ],
        ),
        bottomNavigationBar: AppBottomBar(
          tabs: tabs,
          currentIndex: _index,
          onSelected: _select,
        ),
      ),
    );
  }

  /// 🎯 **Tapping the tab you are already on pops its stack to the root** —
  /// the behaviour every mature tabbed app has, and the only way back out of a
  /// detail screen without reaching for the back button.
  void _select(int next) {
    if (next == _index) {
      final navigator = _navigatorFor(_tabs[_index]).currentState;

      if (navigator != null && navigator.canPop()) {
        navigator.popUntil((route) => route.isFirst);
      }

      return;
    }

    setState(() => _index = next);
  }

  Widget _rootOf(AppTab tab) {
    switch (tab) {
      case AppTab.home:
        return HomeScreen(
          user: widget.user,
          workOrderSource: _source,
          complaintService: widget.complaintService,
          onSignOut: _signOut,
          onSessionExpired: _handleSessionExpired,
        );
      case AppTab.work:
        return QueueScreen(
          userId: widget.user.id,
          onSessionExpired: _handleSessionExpired,
        );
      case AppTab.complaints:
        // 🔴 **A complaint and a work order are the SAME ROW.** `GET
        // /api/facility/work-orders` reads the `complaints` table and there is
        // no complaints-list endpoint at all, so this tab asks that list a
        // different question: `status: new`, the complaints that are nobody's
        // work yet.
        //
        // 🔧 **The push uses the TAB'S OWN CONTEXT, not the tab's
        // `GlobalKey`.** Pushing through `_navigatorFor(...).currentState`
        // silently did nothing — a null state is an expression that evaluates
        // to nothing, so the button looked broken in exactly the way the
        // *"coming soon"* buttons had. `Builder` puts this context BELOW the
        // tab's `Navigator`, so `Navigator.of(context)` resolves to it and a
        // failure would be a crash rather than silence.
        return Builder(
          builder: (tabContext) => QueueScreen(
            userId: widget.user.id,
            onSessionExpired: _handleSessionExpired,
            initialFilters: const QueueFilters(status: 'new'),
            title: 'Complaints',
            onRaiseComplaint: _canCreateComplaint
                ? () => Navigator.of(tabContext).push(
                    MaterialPageRoute(builder: (_) => NewComplaintScreen(userId: widget.user.id)),
                  )
                : null,
          ),
        );
      case AppTab.profile:
        return ProfileScreen(
          user: widget.user,
          source: _source,
          onSignOut: _signOut,
          authService: widget.authService,
        );
    }
  }

  /// 🔴 **SPEC-024 Phase 3 (D8) — a man must not sign out unaware that work is
  /// still on this phone**, and this is the one place that asks. It asks; it
  /// never refuses: he may need to hand the phone over, and blocking a
  /// sign-out would make the app worse than the paper it replaces.
  Future<void> _signOut() async {
    final waiting = await _pendingCount();

    if (!mounted) return;

    if (waiting > 0 && !await _confirmSignOut(waiting)) return;

    await _auth.logout();

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
            child: const Text('Sign out anyway'),
          ),
        ],
      ),
    );

    return confirmed ?? false;
  }

  /// 🔴 **SPEC-024 Phase 1, Step 3 (D6) — the ERP stopped accepting the
  /// token.** ⚠️ Only a **401** reaches here: a 403 means *this job is not
  /// yours*, and signing a man out for tapping the wrong row would be a bug
  /// wearing a security badge. The service draws that line.
  Future<void> _handleSessionExpired() async {
    await _auth.endExpiredSession();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Your session has ended. Please sign in again.')),
    );

    _toLogin();
  }

  /// ⚠️ **`rootNavigator: true`, and it is the trap of this whole pattern.**
  /// Inside a tab, `Navigator.of(context)` is the TAB's navigator — the login
  /// screen would open inside a tab, under the bar, with the signed-out
  /// session standing behind it.
  void _toLogin() {
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }
}

/// How much room the floating bar takes from the bottom of every tab.
///
/// ⚠️ A constant, because the bar's own geometry is a constant: 14 of margin,
/// 8 of padding top and bottom, and about 37 of icon-and-label. It is handed to
/// each tab as `viewPadding`, so `Scaffold` keeps its body and its floating
/// action button clear of the bar without any screen knowing about it.
const double kShellBarHeight = 84;

/// The four destinations of the app, and the only list of them.
enum AppTab {
  home(icon: Icons.space_dashboard_rounded, label: 'Home'),
  work(icon: Icons.assignment_rounded, label: 'Work'),
  complaints(icon: Icons.report_problem_rounded, label: 'Complaints'),
  profile(icon: Icons.person_rounded, label: 'Profile');

  const AppTab({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// The bar itself.
///
/// ⚠️ **The highlight no longer lies.** It was hardcoded to `i == 0`, so every
/// item drew as selected — including the three that did nothing at all. It now
/// follows the shell's own index, which is the single source of where you are.
class AppBottomBar extends StatelessWidget {
  const AppBottomBar({
    super.key,
    required this.tabs,
    required this.currentIndex,
    required this.onSelected,
  });

  final List<AppTab> tabs;
  final int currentIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: AppColors.glassBorder, width: 0.6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 28,
              spreadRadius: -4,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Row(
          children: [
            for (var i = 0; i < tabs.length; i++)
              Expanded(
                child: _NavButton(
                  tab: tabs[i],
                  isCurrent: i == currentIndex,
                  onTap: () => onSelected(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.tab, required this.isCurrent, required this.onTap});

  final AppTab tab;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = isCurrent ? AppColors.accentSoft : AppColors.textMuted;

    return InkWell(
      key: Key('nav-${tab.name}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isCurrent ? AppColors.accent.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(tab.icon, size: 21, color: color),
            const SizedBox(height: 4),
            Text(
              tab.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w600,
                letterSpacing: 0.1,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
