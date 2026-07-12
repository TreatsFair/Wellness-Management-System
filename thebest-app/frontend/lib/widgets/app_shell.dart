import 'package:flutter/material.dart';

import '../core/outlets/outlet_context.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/responsive.dart';
import '../data/repositories/profile_repository.dart';
import '../screens/appointments/appointment_screen.dart';
import '../screens/customers/customer_screen.dart';
import '../screens/dashboard/dashboard_screen.dart';
import '../screens/history/sales_history_screen.dart';
import '../screens/management/management_screen.dart';
import '../screens/orders/order_screen.dart';
import '../screens/reports/reports_screen.dart';
import '../screens/timetable/timetable_screen.dart';
import 'quick_action_button.dart';
import 'section_header.dart';

/// Tab indexes for [AppShell], used with [AppShellScope.selectTab].
abstract final class AppShellTabs {
  static const int home = 0;
  static const int appointments = 1;
  static const int timetable = 2;
  static const int walkIn = 3;
  static const int more = 4;
}

/// Lets screens inside the shell switch tabs (e.g. dashboard quick actions
/// jumping to Timetable) without pushing duplicate routes.
class AppShellScope extends InheritedWidget {
  final void Function(int index) selectTab;

  const AppShellScope({
    super.key,
    required this.selectTab,
    required super.child,
  });

  static AppShellScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppShellScope>();

  @override
  bool updateShouldNotify(AppShellScope oldWidget) => false;
}

/// Persistent navigation wrapper for the whole app: bottom navigation bar
/// on phones, navigation rail on tablets. The five daily destinations are
/// always one tap away; occasional screens live under "More".
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _profileRepository = ProfileRepository();
  int _selectedIndex = 0;
  String _userRole = 'staff';

  @override
  void initState() {
    super.initState();
    _loadRole();
    OutletContext.activeOutletId.addListener(_onOutletChanged);
  }

  @override
  void dispose() {
    OutletContext.activeOutletId.removeListener(_onOutletChanged);
    super.dispose();
  }

  void _onOutletChanged() {
    // Re-key the active screen so every tab reloads with the new outlet.
    if (mounted) setState(() {});
  }

  Future<void> _loadRole() async {
    try {
      final profile = await _profileRepository.getCurrentProfile();
      final role = profile?.role.toLowerCase().trim();
      if (!mounted) return;
      setState(() => _userRole = role == 'admin' ? 'admin' : 'staff');
    } catch (_) {
      // Keep the default staff role when the profile lookup fails.
    }
  }

  // Labels must stay short enough to render on one line on a narrow phone —
  // a wrapped label misaligns the whole bar.
  static const _destinations = [
    (icon: Icons.home_outlined, selectedIcon: Icons.home, label: 'Home'),
    (
      icon: Icons.event_note_outlined,
      selectedIcon: Icons.event_note,
      label: 'Bookings',
    ),
    (
      icon: Icons.calendar_view_week_outlined,
      selectedIcon: Icons.calendar_view_week,
      label: 'Timetable',
    ),
    (
      icon: Icons.point_of_sale_outlined,
      selectedIcon: Icons.point_of_sale,
      label: 'Walk-in',
    ),
    (
      icon: Icons.grid_view_outlined,
      selectedIcon: Icons.grid_view,
      label: 'More',
    ),
  ];

  Widget _buildScreen() {
    // Keyed by tab + outlet: switching either one rebuilds the screen so it
    // always shows fresh data, matching the old push-based behavior.
    final key = ValueKey(
      '$_selectedIndex-${OutletContext.activeOutletId.value}-$_userRole',
    );
    switch (_selectedIndex) {
      case 0:
        return DashboardScreen(key: key);
      case 1:
        return AppointmentsScreen(key: key, userRole: _userRole);
      case 2:
        return TimetableScreen(key: key, userRole: _userRole);
      case 3:
        return WalkInPosScreen(key: key);
      default:
        return _MoreScreen(key: key, userRole: _userRole);
    }
  }

  void _selectTab(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = Responsive.isTablet(context);

    // Tablet keeps the dashboard-as-hub layout: the dashboard's own cards
    // navigate to every screen, so no rail is shown.
    if (isTablet) {
      return const DashboardScreen();
    }

    final body = AppShellScope(selectTab: _selectTab, child: _buildScreen());
    return Scaffold(
      body: SafeArea(child: body),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) =>
            setState(() => _selectedIndex = index),
        destinations: [
          for (final destination in _destinations)
            NavigationDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selectedIcon),
              label: destination.label,
            ),
        ],
      ),
    );
  }
}

/// Occasional destinations: history, members, management, reports.
class _MoreScreen extends StatelessWidget {
  final String userRole;

  const _MoreScreen({super.key, required this.userRole});

  @override
  Widget build(BuildContext context) {
    final isAdmin = userRole == 'admin';
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          const Padding(
            padding: EdgeInsets.only(
              left: AppSpacing.xs,
              bottom: AppSpacing.md,
            ),
            child: Text('More', style: AppText.title),
          ),
          const SectionHeader('Daily reference'),
          const SizedBox(height: AppSpacing.md),
          QuickActionButton(
            icon: Icons.history_outlined,
            label: 'Sales history',
            sublabel: 'Past orders and payments',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SalesHistoryScreen(userRole: userRole),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          QuickActionButton(
            icon: Icons.people_outline,
            label: 'Members',
            sublabel: 'Customer list and details',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CustomerScreen()),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          const SectionHeader('Setup'),
          const SizedBox(height: AppSpacing.md),
          QuickActionButton(
            icon: Icons.tune_outlined,
            label: 'Management',
            sublabel: 'Services, rooms, therapists, online booking',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ManagementScreen(userRole: userRole),
              ),
            ),
          ),
          if (isAdmin) ...[
            const SizedBox(height: AppSpacing.md),
            QuickActionButton(
              icon: Icons.bar_chart_outlined,
              label: 'Reports',
              sublabel: 'Sales, commissions, and analytics',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ReportsScreen(userRole: userRole),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
