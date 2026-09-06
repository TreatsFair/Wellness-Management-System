import 'package:flutter/material.dart';

import '../core/accessibility/accessibility_settings.dart';
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
import 'app_shell_scope.dart';
import 'quick_action_button.dart';
import 'section_header.dart';

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
  bool _fullscreen = false;

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
      icon: Icons.history_outlined,
      selectedIcon: Icons.history,
      label: 'History',
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
        return SalesHistoryScreen(key: key, userRole: _userRole);
      default:
        return _MoreScreen(key: key, userRole: _userRole);
    }
  }

  void _selectTab(int index) {
    if (index == _selectedIndex) return;
    setState(() {
      _selectedIndex = index;
      _fullscreen = false;
    });
  }

  void _setFullscreen(bool fullscreen) {
    if (_fullscreen == fullscreen) return;
    setState(() => _fullscreen = fullscreen);
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = Responsive.isTablet(context);
    final metrics = context.uiScale;

    // Tablet keeps the dashboard-as-hub layout: the dashboard's own cards
    // navigate to every screen, so no rail is shown.
    if (isTablet) {
      return const DashboardScreen();
    }

    final body = AppShellScope(
      selectTab: _selectTab,
      fullscreen: _fullscreen,
      setFullscreen: _setFullscreen,
      child: _buildScreen(),
    );
    return Scaffold(
      body: SafeArea(child: body),
      bottomNavigationBar: _fullscreen
          ? null
          : NavigationBar(
              height: metrics.navigationHeight,
              labelBehavior:
                  (metrics.preset == UiScalePreset.large ||
                          MediaQuery.textScalerOf(context).scale(1) > 1.15) &&
                      MediaQuery.sizeOf(context).width < 520
                  ? NavigationDestinationLabelBehavior.onlyShowSelected
                  : NavigationDestinationLabelBehavior.alwaysShow,
              selectedIndex: _selectedIndex,
              onDestinationSelected: _selectTab,
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

/// Occasional destinations: walk-ins, members, management, reports.
class _MoreScreen extends StatelessWidget {
  final String userRole;

  const _MoreScreen({super.key, required this.userRole});

  @override
  Widget build(BuildContext context) {
    final isAdmin = userRole == 'admin';
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          const SectionHeader('Daily operations'),
          const SizedBox(height: AppSpacing.md),
          QuickActionButton(
            icon: Icons.point_of_sale_rounded,
            label: 'Walk-in order',
            sublabel: 'Create a walk-in service order',
            accentColor: AppColors.accent,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WalkInPosScreen()),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          QuickActionButton(
            icon: Icons.people_alt_rounded,
            label: 'Members',
            sublabel: 'Customer list and details',
            accentColor: AppColors.info,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CustomerScreen()),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          const SectionHeader('Business management'),
          const SizedBox(height: AppSpacing.md),
          QuickActionButton(
            icon: Icons.tune_rounded,
            label: 'Management',
            sublabel: 'Services, rooms, therapists, online booking',
            accentColor: AppColors.primary,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ManagementScreen(userRole: userRole),
              ),
            ),
          ),
          if (isAdmin) ...[
            const SizedBox(height: AppSpacing.xl),
            const SectionHeader('Business insights'),
            const SizedBox(height: AppSpacing.md),
            QuickActionButton(
              icon: Icons.insights_rounded,
              label: 'Reports',
              sublabel: 'Sales, commissions, and analytics',
              accentColor: AppColors.primary,
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
