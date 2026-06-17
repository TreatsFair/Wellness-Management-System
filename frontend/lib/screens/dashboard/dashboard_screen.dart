import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/dashboard_repository.dart';
import '../../data/repositories/profile_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../appointments/appointment_screen.dart';
import '../booking/booking_screen.dart';
import '../customers/customer_screen.dart';
import '../history/sales_history_screen.dart';
import '../orders/order_screen.dart';
import '../management/management_screen.dart';
import '../reports/reports_screen.dart';

class _DashboardStats {
  final int todayAppointments;
  final int tomorrowAppointments;
  final int doneAppointments;
  final int pendingAppointments;
  final double todaySales;
  final int totalTransactions;
  final int totalCustomers;
  final int newCustomersThisWeek;
  final double weekRevenue;
  final int weekAppointments;
  final double averageTransactionValue;

  const _DashboardStats({
    required this.todayAppointments,
    required this.tomorrowAppointments,
    required this.doneAppointments,
    required this.pendingAppointments,
    required this.todaySales,
    required this.totalTransactions,
    required this.totalCustomers,
    required this.newCustomersThisWeek,
    required this.weekRevenue,
    required this.weekAppointments,
    required this.averageTransactionValue,
  });

  static const empty = _DashboardStats(
    todayAppointments: 0,
    tomorrowAppointments: 0,
    doneAppointments: 0,
    pendingAppointments: 0,
    todaySales: 0,
    totalTransactions: 0,
    totalCustomers: 0,
    newCustomersThisWeek: 0,
    weekRevenue: 0,
    weekAppointments: 0,
    averageTransactionValue: 0,
  );
}

class _TherapistStatus {
  final String name;
  final String status;
  final bool isFree;
  final int doneCount;

  const _TherapistStatus({
    required this.name,
    required this.status,
    required this.isFree,
    required this.doneCount,
  });
}

class _BusinessProfile {
  final String name;
  final String location;
  final String logoInitial;
  final String? settingsDocumentId;

  const _BusinessProfile({
    required this.name,
    required this.location,
    required this.logoInitial,
    this.settingsDocumentId,
  });

  _BusinessProfile copyWith({
    String? name,
    String? location,
    String? logoInitial,
    String? settingsDocumentId,
  }) {
    return _BusinessProfile(
      name: name ?? this.name,
      location: location ?? this.location,
      logoInitial: logoInitial ?? this.logoInitial,
      settingsDocumentId: settingsDocumentId ?? this.settingsDocumentId,
    );
  }
}

class _TransactionSummary {
  final String customerName;
  final String serviceName;
  final String therapistName;
  final String date;
  final String time;
  final double amount;

  const _TransactionSummary({
    required this.customerName,
    required this.serviceName,
    required this.therapistName,
    required this.date,
    required this.time,
    required this.amount,
  });
}

class _DashboardData {
  final _DashboardStats stats;
  final List<_TherapistStatus> therapists;
  final List<_TransactionSummary> recentTransactions;

  const _DashboardData({
    required this.stats,
    required this.therapists,
    required this.recentTransactions,
  });

  static const empty = _DashboardData(
    stats: _DashboardStats.empty,
    therapists: [],
    recentTransactions: [],
  );
}

const _placeholderBusinessProfile = _BusinessProfile(
  name: 'The Best Family Wellness',
  location: 'Kuala Lumpur',
  logoInitial: 'W',
);

const _businessSettingsDocumentId = 'mAERFw4PbxfgzILaNV1X';

DateTime _stripDate(DateTime date) => DateTime(date.year, date.month, date.day);

DateTime _startOfWeek(DateTime date) {
  final clean = _stripDate(date);
  return clean.subtract(Duration(days: clean.weekday % 7));
}

String _dateKey(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

String _asString(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  final text = value.toString();
  return text.trim().isEmpty ? fallback : text;
}

double _asDouble(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

DateTime? _asDateTime(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

int _timeToMinutes(String value) {
  final parts = value.split(':');
  if (parts.length < 2) return 0;
  return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
}

String _timeLabel(String value) {
  final parts = value.split(':');
  if (parts.length < 2) return value;
  final hour = int.tryParse(parts[0]) ?? 0;
  final minute = int.tryParse(parts[1]) ?? 0;
  return DateFormat('h:mm a').format(DateTime(2026, 1, 1, hour, minute));
}

bool _isCancelled(Map<String, dynamic> data) {
  final status = _asString(data['status']).toLowerCase().trim();
  return status == 'cancelled' || status == 'canceled';
}

bool _isPendingAppointmentStatus(String status) {
  return status == 'pending' || status == 'confirmed' || status == 'in_progress';
}

bool _isPaid(Map<String, dynamic> data) {
  final status = _asString(data['paymentStatus']).toLowerCase().trim();
  return status.isEmpty || status == 'paid';
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _authRepository = AuthRepository();
  final _profileRepository = ProfileRepository();
  final _dashboardRepository = DashboardRepository();
  final _settingsRepository = SettingsRepository();
  _BusinessProfile _businessProfile = _placeholderBusinessProfile;
  _DashboardData _dashboardData = _DashboardData.empty;
  bool _isCurrentUserAdmin = false;
  String _currentUserRole = 'staff';
  String _currentUserEmail = 'No email';
  bool _isLoadingBusinessSettings = true;
  bool _isLoadingDashboardData = true;
  String? _dashboardError;

  @override
  void initState() {
    super.initState();
    _loadBusinessSettings();
    _loadDashboardData();
  }

  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 900;

  Future<Map<String, Map<String, dynamic>>> _loadDocMap(
    String collection,
    Iterable<String> ids,
  ) async {
    return _dashboardRepository.loadByIds(collection, ids);
  }

  Future<void> _loadDashboardData() async {
    if (mounted) {
      setState(() {
        _isLoadingDashboardData = true;
        _dashboardError = null;
      });
    }

    try {
      final now = DateTime.now();
      final today = _stripDate(now);
      final tomorrow = today.add(const Duration(days: 1));
      final weekStart = _startOfWeek(today);
      final weekEnd = weekStart.add(const Duration(days: 7));
      final todayKey = _dateKey(today);
      final tomorrowKey = _dateKey(tomorrow);
      final weekStartKey = _dateKey(weekStart);
      final weekEndKey = _dateKey(weekEnd.subtract(const Duration(days: 1)));

      final appointments = await _dashboardRepository.appointmentsForDateRange(
        weekStartKey,
        weekEndKey,
      );
      final customerRows = await _dashboardRepository.listCustomers();
      final therapistRows = await _dashboardRepository.listTherapists();
      final todayTransactionRows = await _dashboardRepository
          .transactionsForDate(today);
      final weekTransactionRows = await _dashboardRepository
          .transactionsForDateRange(weekStart, weekEnd);
      final recentTransactionRows = await _dashboardRepository
          .recentTransactions(limit: 8);

      final activeAppointments = appointments.where(
        (data) => !_isCancelled(data),
      );
      final todayAppointments = activeAppointments
          .where((data) => _asString(data['date']) == todayKey)
          .toList();
      final tomorrowAppointments = activeAppointments
          .where((data) => _asString(data['date']) == tomorrowKey)
          .toList();
      final weekAppointments = activeAppointments.length;
      final doneAppointments = todayAppointments
          .where(
            (data) => _asString(data['status']).toLowerCase() == 'completed',
          )
          .length;
      final pendingAppointments = todayAppointments
          .where(
            (data) => _isPendingAppointmentStatus(
              _asString(data['status']).toLowerCase(),
            ),
          )
          .length;

      final todayPaidTransactions = todayTransactionRows
          .where((data) => _isPaid(data))
          .toList();
      final weekPaidTransactions = weekTransactionRows
          .where((data) => _isPaid(data))
          .toList();
      final todaySales = todayPaidTransactions.fold<double>(
        0,
        (total, data) => total + _asDouble(data['totalAmount']),
      );
      final weekRevenue = weekPaidTransactions.fold<double>(
        0,
        (total, data) => total + _asDouble(data['totalAmount']),
      );

      final customers = {
        for (final data in customerRows) _asString(data['id']): data,
      };
      final newCustomersThisWeek = customerRows.where((data) {
        final joinDate = DateTime.tryParse(_asString(data['joinDate']));
        final createdAt = _asDateTime(data['createdAt']);
        final customerDate = joinDate ?? createdAt;
        if (customerDate == null) return false;
        return !customerDate.isBefore(weekStart) &&
            customerDate.isBefore(weekEnd);
      }).length;

      final nowMinutes = now.hour * 60 + now.minute;
      final therapistStatuses = therapistRows.map((data) {
        final therapistId = _asString(data['id']);
        final therapistAppointments = todayAppointments
            .where(
              (appointment) =>
                  _asString(appointment['therapistId']) == therapistId,
            )
            .toList();
        final doneCount = therapistAppointments
            .where(
              (appointment) =>
                  _asString(appointment['status']).toLowerCase() == 'completed',
            )
            .length;
        Map<String, dynamic>? currentAppointment;
        for (final appointment in therapistAppointments) {
          final status = _asString(appointment['status']).toLowerCase();
          if (!_isPendingAppointmentStatus(status)) continue;
          final start = _timeToMinutes(_asString(appointment['startTime']));
          final end = _timeToMinutes(_asString(appointment['endTime']));
          if (start <= nowMinutes && end > nowMinutes) {
            currentAppointment = appointment;
            break;
          }
        }

        final name = _asString(data['name'], 'Staff');
        final availability = data['availabilityStatus'];
        final busyUntil = _asString(data['busyUntil']);
        final isAvailable = availability is bool ? availability : true;
        final isFree = currentAppointment == null && isAvailable;
        final endTime = currentAppointment == null
            ? busyUntil
            : _asString(currentAppointment['endTime']);
        final status = isFree
            ? 'Free now'
            : endTime.isEmpty
            ? 'Busy now'
            : 'Busy until ${_timeLabel(endTime)}';

        return _TherapistStatus(
          name: name,
          status: status,
          isFree: isFree,
          doneCount: doneCount,
        );
      }).toList();

      final transactionData = recentTransactionRows
          .where((data) => _isPaid(data))
          .take(6)
          .toList();
      final appointmentIds = transactionData
          .map((data) => _asString(data['appointmentId']))
          .where((id) => id.isNotEmpty);
      final linkedAppointments = await _loadDocMap(
        'appointments',
        appointmentIds,
      );
      final serviceIds = [
        ...transactionData.map((data) => _asString(data['serviceId'])),
        ...linkedAppointments.values.map((data) => _asString(data['serviceId'])),
      ].where((id) => id.isNotEmpty);
      final therapistIds = [
        ...transactionData.map((data) => _asString(data['therapistId'])),
        ...linkedAppointments.values.map(
          (data) => _asString(data['therapistId']),
        ),
      ].where((id) => id.isNotEmpty);
      final linkedServices = await _loadDocMap('services', serviceIds);
      final linkedTherapists = await _loadDocMap('therapists', therapistIds);

      final recentTransactions = transactionData.map((data) {
        final appointment =
            linkedAppointments[_asString(data['appointmentId'])];
        final serviceId = _asString(data['serviceId']).isNotEmpty
            ? _asString(data['serviceId'])
            : _asString(appointment?['serviceId']);
        final therapistId = _asString(data['therapistId']).isNotEmpty
            ? _asString(data['therapistId'])
            : _asString(appointment?['therapistId']);
        final service = linkedServices[serviceId];
        final therapist = linkedTherapists[therapistId];
        final customerId = _asString(data['customerId']);
        final customer = customers[customerId];
        final createdAt = _asDateTime(data['createdAt']) ?? now;
        return _TransactionSummary(
          customerName: _asString(
            data['customerName'],
            _asString(customer?['name'], 'Guest'),
          ),
          serviceName: _asString(
            data['serviceName'],
            _asString(service?['name'], 'Service'),
          ),
          therapistName: _asString(
            data['therapistName'],
            _asString(therapist?['name'], '-'),
          ),
          date: DateFormat('d MMM yyyy').format(createdAt),
          time: DateFormat('h:mm a').format(createdAt),
          amount: _asDouble(data['totalAmount']),
        );
      }).toList();

      final weekTransactionCount = weekPaidTransactions.length;
      final stats = _DashboardStats(
        todayAppointments: todayAppointments.length,
        tomorrowAppointments: tomorrowAppointments.length,
        doneAppointments: doneAppointments,
        pendingAppointments: pendingAppointments,
        todaySales: todaySales,
        totalTransactions: todayPaidTransactions.length,
        totalCustomers: customerRows.length,
        newCustomersThisWeek: newCustomersThisWeek,
        weekRevenue: weekRevenue,
        weekAppointments: weekAppointments,
        averageTransactionValue: weekTransactionCount == 0
            ? 0
            : weekRevenue / weekTransactionCount,
      );

      if (!mounted) return;
      setState(() {
        _dashboardData = _DashboardData(
          stats: stats,
          therapists: therapistStatuses,
          recentTransactions: recentTransactions,
        );
        _isLoadingDashboardData = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dashboardError = e.toString();
        _isLoadingDashboardData = false;
      });
    }
  }

  Future<void> _loadBusinessSettings() async {
    final currentUser = _authRepository.currentUser;
    var email = currentUser?.email;

    var profile = _placeholderBusinessProfile;
    var normalizedRole = 'staff';

    try {
      final userProfile = await _profileRepository.getCurrentProfile();
      final role = userProfile?.role.toLowerCase().trim();
      normalizedRole = role == 'admin' ? 'admin' : 'staff';
      if ((userProfile?.email ?? '').trim().isNotEmpty) {
        email = userProfile!.email.trim();
      }
    } catch (_) {
      // Keep the default staff role when the profile lookup fails.
    }

    try {
      final data = await _settingsRepository.getBusinessSettings();
      if (data != null) {
        profile = _BusinessProfile(
          name: (data['businessName'] as String?)?.trim().isNotEmpty == true
              ? (data['businessName'] as String).trim()
              : _placeholderBusinessProfile.name,
          location: (data['location'] as String?)?.trim().isNotEmpty == true
              ? (data['location'] as String).trim()
              : _placeholderBusinessProfile.location,
          logoInitial: _placeholderBusinessProfile.logoInitial,
          settingsDocumentId: _asString(data['id']),
        );
      }
    } catch (_) {
      // Keep the placeholder business profile when settings are unavailable.
    }

    if (!mounted) return;
    setState(() {
      _businessProfile = profile;
      _isCurrentUserAdmin = normalizedRole == 'admin';
      _currentUserRole = normalizedRole;
      _currentUserEmail = email?.trim().isNotEmpty == true
          ? email!.trim()
          : 'No email';
      _isLoadingBusinessSettings = false;
    });
  }

  Future<void> _saveBusinessSettings(_BusinessProfile profile) async {
    final uid = _authRepository.currentUser?.id;
    if (!_isCurrentUserAdmin || uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only admins can edit business settings'),
          backgroundColor: Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final settingsDocumentId =
        profile.settingsDocumentId ?? _businessSettingsDocumentId;

    try {
      final savedSettings = await _settingsRepository.updateBusinessSettings(
        {
          'businessName': profile.name,
          'location': profile.location,
        },
        id: settingsDocumentId == _businessSettingsDocumentId
            ? null
            : settingsDocumentId,
      );

      if (!mounted) return;
      setState(() {
        _businessProfile = profile.copyWith(
          settingsDocumentId: _asString(
            savedSettings['id'],
            settingsDocumentId,
          ),
        );
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Business settings updated'),
          backgroundColor: Color(0xFF1B6B72),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to save business settings: $e'),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _openBusinessSettings() async {
    final updatedProfile = await showDialog<_BusinessProfile>(
      context: context,
      builder: (context) => _BusinessSettingsDialog(
        profile: _businessProfile,
        isAdmin: _isCurrentUserAdmin,
      ),
    );

    if (updatedProfile == null) return;

    await _saveBusinessSettings(updatedProfile);
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = _isTablet(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF0F0F0),
      body: SafeArea(
        child: isTablet
            ? _TabletLayout(
                profile: _businessProfile,
                email: _currentUserEmail,
                role: _currentUserRole,
                isLoadingSettings: _isLoadingBusinessSettings,
                dashboardData: _dashboardData,
                isLoadingDashboard: _isLoadingDashboardData,
                dashboardError: _dashboardError,
                onRefreshDashboard: _loadDashboardData,
                onOpenSettings: _openBusinessSettings,
              )
            : _PhoneLayout(
                profile: _businessProfile,
                email: _currentUserEmail,
                role: _currentUserRole,
                isLoadingSettings: _isLoadingBusinessSettings,
                dashboardData: _dashboardData,
                isLoadingDashboard: _isLoadingDashboardData,
                dashboardError: _dashboardError,
                onRefreshDashboard: _loadDashboardData,
                onOpenSettings: _openBusinessSettings,
              ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TABLET LAYOUT — landscape, grid-based like Image 1
// ─────────────────────────────────────────────────────────────────────────────
class _TabletLayout extends StatelessWidget {
  final _BusinessProfile profile;
  final String email;
  final String role;
  final bool isLoadingSettings;
  final _DashboardData dashboardData;
  final bool isLoadingDashboard;
  final String? dashboardError;
  final Future<void> Function() onRefreshDashboard;
  final VoidCallback onOpenSettings;

  const _TabletLayout({
    required this.profile,
    required this.email,
    required this.role,
    required this.isLoadingSettings,
    required this.dashboardData,
    required this.isLoadingDashboard,
    required this.dashboardError,
    required this.onRefreshDashboard,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Top bar ────────────────────────────────────────────
        _TabletTopBar(
          profile: profile,
          email: email,
          role: role,
          isLoadingSettings: isLoadingSettings,
          transactions: dashboardData.recentTransactions,
          onOpenSettings: onOpenSettings,
        ),
        if (dashboardError != null)
          _DashboardErrorBanner(
            message: dashboardError!,
            onRetry: onRefreshDashboard,
          ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Main section label
                const _SectionLabel('Main'),
                const SizedBox(height: 12),

                // 4-column main cards row
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Quick Book card
                      Expanded(
                        child: _TabletQuickBookCard(
                          role: role,
                          onRefreshDashboard: onRefreshDashboard,
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Orders card
                      Expanded(
                        child: _TabletOrdersCard(
                          stats: dashboardData.stats,
                          isLoading: isLoadingDashboard,
                          onRefreshDashboard: onRefreshDashboard,
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Appointment card
                      Expanded(
                        child: _TabletAppointmentCard(
                          role: role,
                          stats: dashboardData.stats,
                          isLoading: isLoadingDashboard,
                          onRefreshDashboard: onRefreshDashboard,
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Therapists card
                      Expanded(
                        child: _TabletTherapistsCard(
                          role: role,
                          therapists: dashboardData.therapists,
                          isLoading: isLoadingDashboard,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 32),

                // Others section label
                const _SectionLabel('Others'),
                const SizedBox(height: 12),

                // 4-column others row
                Row(
                  children: [
                    Expanded(
                      child: _TabletOtherCard(
                        icon: Icons.history_outlined,
                        label: 'History',
                        iconBg: const Color(0xFFE8F4F8),
                        iconColor: const Color(0xFF5BA4B5),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SalesHistoryScreen(userRole: role),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _TabletOtherCard(
                        icon: Icons.people_outline,
                        label: 'Members',
                        iconBg: const Color(0xFFE3F2FD),
                        iconColor: const Color(0xFF1B6B72),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const CustomerScreen(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _TabletOtherCard(
                        icon: Icons.tune_outlined,
                        label: 'Management',
                        iconBg: const Color(0xFFE8F5E9),
                        iconColor: const Color(0xFF4CAF50),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ManagementScreen(userRole: role),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _TabletOtherCard(
                        icon: Icons.bar_chart_outlined,
                        label: 'Reports',
                        iconBg: const Color(0xFFEDE7F6),
                        iconColor: const Color(0xFF7C3AED),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ReportsScreen(userRole: role),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TabletTopBar extends StatelessWidget {
  final _BusinessProfile profile;
  final String email;
  final String role;
  final bool isLoadingSettings;
  final List<_TransactionSummary> transactions;
  final VoidCallback onOpenSettings;

  const _TabletTopBar({
    required this.profile,
    required this.email,
    required this.role,
    required this.isLoadingSettings,
    required this.transactions,
    required this.onOpenSettings,
  });

  void _openBusinessProfile(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) =>
          _BusinessProfileDialog(profile: profile, email: email),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Row(
        children: [
          InkWell(
            onTap: () => _openBusinessProfile(context),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF1B6B72),
                    ),
                    child: Center(
                      child: Text(
                        profile.logoInitial,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                      Text(
                        profile.location,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF9E9E9E),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          _RolePill(role: role, isLoading: isLoadingSettings),
          const SizedBox(width: 12),
          _NotificationButton(transactions: transactions),
          const SizedBox(width: 12),
          _SettingsButton(onPressed: onOpenSettings),
        ],
      ),
    );
  }
}

class _TabletQuickBookCard extends StatelessWidget {
  final String role;
  final Future<void> Function() onRefreshDashboard;

  const _TabletQuickBookCard({
    required this.role,
    required this.onRefreshDashboard,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NewAppointmentScreen(userRole: role),
          ),
        );
        await onRefreshDashboard();
      },
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFF23848A),
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.add,
                    color: Color(0xFF23848A),
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                const Text(
                  'Quick Book',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            const Spacer(),
            const Text(
              'Create new appointment',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'AI-optimised scheduling',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.white.withValues(alpha: 0.82),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabletOrdersCard extends StatelessWidget {
  final _DashboardStats stats;
  final bool isLoading;
  final Future<void> Function() onRefreshDashboard;

  const _TabletOrdersCard({
    required this.stats,
    required this.isLoading,
    required this.onRefreshDashboard,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const WalkInPosScreen()),
        );
        await onRefreshDashboard();
      },
      child: _TabletCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _IconBox(
                  icon: Icons.point_of_sale_outlined,
                  bg: const Color(0xFFFFF3E0),
                  color: const Color(0xFFF59E0B),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Order',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Today Sales',
              style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
            ),
            const SizedBox(height: 6),
            Text(
              isLoading ? '-' : 'RM ${stats.todaySales.toStringAsFixed(0)}',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isLoading
                  ? 'Loading transactions'
                  : '${stats.totalTransactions} paid transactions',
              style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabletAppointmentCard extends StatelessWidget {
  final String role;
  final _DashboardStats stats;
  final bool isLoading;
  final Future<void> Function() onRefreshDashboard;

  const _TabletAppointmentCard({
    required this.role,
    required this.stats,
    required this.isLoading,
    required this.onRefreshDashboard,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AppointmentsScreen(userRole: role)),
        );
        await onRefreshDashboard();
      },
      child: _TabletCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _IconBox(
                  icon: Icons.calendar_today_outlined,
                  bg: const Color(0xFFE8F5E9),
                  color: const Color(0xFF1B6B72),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Appointment',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Total',
              style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
            ),
            const SizedBox(height: 10),
            _AppointmentRow(
              label: 'Today',
              count: isLoading ? '-' : '${stats.todayAppointments}',
            ),
            const SizedBox(height: 10),
            _AppointmentRow(
              label: 'Tomorrow',
              count: isLoading ? '-' : '${stats.tomorrowAppointments}',
            ),
          ],
        ),
      ),
    );
  }
}

class _TabletTherapistsCard extends StatelessWidget {
  final String role;
  final List<_TherapistStatus> therapists;
  final bool isLoading;

  const _TabletTherapistsCard({
    required this.role,
    required this.therapists,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    final visibleTherapists = therapists.take(2).toList();

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const TherapistAvailabilityScreen()),
      ),
      child: _TabletCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _IconBox(
                  icon: Icons.people_outline,
                  bg: const Color(0xFFF3E8FF),
                  color: const Color(0xFF7C3AED),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Staff',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Status Today',
              style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
            ),
            const SizedBox(height: 10),
            if (isLoading)
              const Text(
                'Loading staff status',
                style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
              )
            else if (visibleTherapists.isEmpty)
              const Text(
                'No staff yet',
                style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
              )
            else
              for (final therapist in visibleTherapists) ...[
                _TherapistRow(
                  name: therapist.name,
                  status: therapist.status,
                  statusColor: therapist.isFree
                      ? const Color(0xFF4CAF50)
                      : const Color(0xFFF59E0B),
                  done: '${therapist.doneCount} done',
                ),
                if (therapist != visibleTherapists.last)
                  const Divider(height: 16, color: Color(0xFFF0F0F0)),
              ],
          ],
        ),
      ),
    );
  }
}

class _TabletOtherCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color iconBg;
  final Color iconColor;
  final VoidCallback? onTap;

  const _TabletOtherCard({
    required this.icon,
    required this.label,
    required this.iconBg,
    required this.iconColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: _TabletCard(
          child: Row(
            children: [
              _IconBox(icon: icon, bg: iconBg, color: iconColor),
              const SizedBox(width: 12),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A2E),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PHONE LAYOUT — vertical, analytics before staff status
// ─────────────────────────────────────────────────────────────────────────────
class _PhoneLayout extends StatelessWidget {
  final _BusinessProfile profile;
  final String email;
  final String role;
  final bool isLoadingSettings;
  final _DashboardData dashboardData;
  final bool isLoadingDashboard;
  final String? dashboardError;
  final Future<void> Function() onRefreshDashboard;
  final VoidCallback onOpenSettings;

  const _PhoneLayout({
    required this.profile,
    required this.email,
    required this.role,
    required this.isLoadingSettings,
    required this.dashboardData,
    required this.isLoadingDashboard,
    required this.dashboardError,
    required this.onRefreshDashboard,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Top bar ──────────────────────────────────────────
          _PhoneTopBar(
            profile: profile,
            email: email,
            role: role,
            isLoadingSettings: isLoadingSettings,
            transactions: dashboardData.recentTransactions,
            onOpenSettings: onOpenSettings,
          ),
          if (dashboardError != null)
            _DashboardErrorBanner(
              message: dashboardError!,
              onRetry: onRefreshDashboard,
            ),

          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Main section ─────────────────────────────
                const _SectionLabel('Main'),
                const SizedBox(height: 12),

                // Row 1: Appointments + Quick Book
                Row(
                  children: [
                    Expanded(
                      child: _PhoneAppointmentCard(
                        role: role,
                        stats: dashboardData.stats,
                        isLoading: isLoadingDashboard,
                        onRefreshDashboard: onRefreshDashboard,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _PhoneQuickBookCard(
                        role: role,
                        onRefreshDashboard: onRefreshDashboard,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Row 2: Order + Members
                Row(
                  children: [
                    Expanded(
                      child: _PhonePosCard(
                        stats: dashboardData.stats,
                        isLoading: isLoadingDashboard,
                        onRefreshDashboard: onRefreshDashboard,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _PhoneCustomersCard(
                        stats: dashboardData.stats,
                        isLoading: isLoadingDashboard,
                        onRefreshDashboard: onRefreshDashboard,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // ── Analytics section (FIRST on phone) ───────
                const _SectionLabel('Analytics'),
                const SizedBox(height: 12),
                _PhoneAnalyticsCard(
                  stats: dashboardData.stats,
                  isLoading: isLoadingDashboard,
                ),

                const SizedBox(height: 24),

                // ── Staff Status section ──────────────────────
                const _SectionLabel('Staff Status'),
                const SizedBox(height: 12),
                _PhoneStaffStatusCard(
                  role: role,
                  therapists: dashboardData.therapists,
                  isLoading: isLoadingDashboard,
                ),

                const SizedBox(height: 24),

                // ── Others section ────────────────────────────
                const _SectionLabel('Others'),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 2.2,
                  children: [
                    _PhoneOtherCard(
                      icon: Icons.history_outlined,
                      label: 'History',
                      iconBg: const Color(0xFFE8F4F8),
                      iconColor: const Color(0xFF5BA4B5),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => SalesHistoryScreen(userRole: role),
                        ),
                      ),
                    ),
                    _PhoneOtherCard(
                      icon: Icons.people_outline,
                      label: 'Members',
                      iconBg: const Color(0xFFE3F2FD),
                      iconColor: const Color(0xFF1B6B72),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const CustomerScreen(),
                        ),
                      ),
                    ),
                    _PhoneOtherCard(
                      icon: Icons.tune_outlined,
                      label: 'Management',
                      iconBg: const Color(0xFFE8F5E9),
                      iconColor: const Color(0xFF4CAF50),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ManagementScreen(userRole: role),
                        ),
                      ),
                    ),
                    _PhoneOtherCard(
                      icon: Icons.bar_chart_outlined,
                      label: 'Reports',
                      iconBg: const Color(0xFFEDE7F6),
                      iconColor: const Color(0xFF7C3AED),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ReportsScreen(userRole: role),
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PhoneTopBar extends StatelessWidget {
  final _BusinessProfile profile;
  final String email;
  final String role;
  final bool isLoadingSettings;
  final List<_TransactionSummary> transactions;
  final VoidCallback onOpenSettings;

  const _PhoneTopBar({
    required this.profile,
    required this.email,
    required this.role,
    required this.isLoadingSettings,
    required this.transactions,
    required this.onOpenSettings,
  });

  void _openBusinessProfile(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) =>
          _BusinessProfileDialog(profile: profile, email: email),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => _openBusinessProfile(context),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF1B6B72),
                      ),
                      child: Center(
                        child: Text(
                          profile.logoInitial,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1A1A2E),
                            ),
                          ),
                          Text(
                            profile.location,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF9E9E9E),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _RolePill(role: role, isLoading: isLoadingSettings, compact: true),
          const SizedBox(width: 8),
          _NotificationButton(transactions: transactions, compact: true),
          const SizedBox(width: 8),
          _SettingsButton(onPressed: onOpenSettings, compact: true),
        ],
      ),
    );
  }
}

class _PhoneAppointmentCard extends StatelessWidget {
  final String role;
  final _DashboardStats stats;
  final bool isLoading;
  final Future<void> Function() onRefreshDashboard;

  const _PhoneAppointmentCard({
    required this.role,
    required this.stats,
    required this.isLoading,
    required this.onRefreshDashboard,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AppointmentsScreen(userRole: role)),
        );
        await onRefreshDashboard();
      },
      child: _PhoneCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _IconBox(
                  icon: Icons.calendar_today_outlined,
                  bg: const Color(0xFFE8F5E9),
                  color: const Color(0xFF1B6B72),
                  size: 32,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Appointments',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Total Today',
              style: TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
            ),
            const SizedBox(height: 4),
            Text(
              isLoading ? '-' : '${stats.todayAppointments}',
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  isLoading ? '- Done  ' : '${stats.doneAppointments} Done  ',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF4CAF50),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  isLoading
                      ? '- Pending'
                      : '${stats.pendingAppointments} Pending',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFF59E0B),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PhoneQuickBookCard extends StatelessWidget {
  final String role;
  final Future<void> Function() onRefreshDashboard;

  const _PhoneQuickBookCard({
    required this.role,
    required this.onRefreshDashboard,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NewAppointmentScreen(userRole: role),
          ),
        );
        await onRefreshDashboard();
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1B6B72),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.add, color: Colors.white, size: 20),
            ),
            const SizedBox(height: 12),
            const Text(
              'Quick Book',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Create new\nappointment',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhonePosCard extends StatelessWidget {
  final _DashboardStats stats;
  final bool isLoading;
  final Future<void> Function() onRefreshDashboard;

  const _PhonePosCard({
    required this.stats,
    required this.isLoading,
    required this.onRefreshDashboard,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const WalkInPosScreen()),
        );
        await onRefreshDashboard();
      },
      child: _PhoneCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _IconBox(
                  icon: Icons.point_of_sale_outlined,
                  bg: const Color(0xFFFFF3E0),
                  color: const Color(0xFFF59E0B),
                  size: 32,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Order',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Today Sales',
              style: TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
            ),
            const SizedBox(height: 4),
            Text(
              isLoading ? '-' : 'RM ${stats.todaySales.toStringAsFixed(0)}',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isLoading ? 'Loading' : '${stats.totalTransactions} transactions',
              style: const TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhoneCustomersCard extends StatelessWidget {
  final _DashboardStats stats;
  final bool isLoading;
  final Future<void> Function() onRefreshDashboard;

  const _PhoneCustomersCard({
    required this.stats,
    required this.isLoading,
    required this.onRefreshDashboard,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CustomerScreen()),
        );
        await onRefreshDashboard();
      },
      child: _PhoneCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _IconBox(
                  icon: Icons.people_outline,
                  bg: const Color(0xFFE3F2FD),
                  color: const Color(0xFF1B6B72),
                  size: 32,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Members',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Total',
              style: TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
            ),
            const SizedBox(height: 4),
            Text(
              isLoading ? '-' : '${stats.totalCustomers}',
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isLoading
                  ? 'Loading'
                  : '+${stats.newCustomersThisWeek} this week',
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF1B6B72),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhoneAnalyticsCard extends StatelessWidget {
  final _DashboardStats stats;
  final bool isLoading;

  const _PhoneAnalyticsCard({required this.stats, required this.isLoading});

  @override
  Widget build(BuildContext context) {
    return _PhoneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _IconBox(
                icon: Icons.attach_money,
                bg: const Color(0xFFE8F5E9),
                color: const Color(0xFF1B6B72),
                size: 32,
              ),
              const SizedBox(width: 10),
              const Text(
                'Revenue Summary',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _AnalyticsStat(
                label: 'This Week',
                value: isLoading
                    ? '-'
                    : 'RM ${stats.weekRevenue.toStringAsFixed(0)}',
              ),
              _AnalyticsStat(
                label: 'Appointments',
                value: isLoading ? '-' : '${stats.weekAppointments}',
              ),
              _AnalyticsStat(
                label: 'Avg. Value',
                value: isLoading
                    ? '-'
                    : 'RM ${stats.averageTransactionValue.toStringAsFixed(0)}',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PhoneStaffStatusCard extends StatelessWidget {
  final String role;
  final List<_TherapistStatus> therapists;
  final bool isLoading;

  const _PhoneStaffStatusCard({
    required this.role,
    required this.therapists,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    return _PhoneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Staff Today',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const TherapistAvailabilityScreen(),
                  ),
                ),
                child: const Text(
                  'View All',
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFF1B6B72),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (isLoading)
            const Text(
              'Loading staff status',
              style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
            )
          else if (therapists.isEmpty)
            const Text(
              'No staff yet',
              style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
            )
          else
            for (final therapist in therapists) ...[
              _TherapistRow(
                name: therapist.name,
                status: therapist.status,
                statusColor: therapist.isFree
                    ? const Color(0xFF4CAF50)
                    : const Color(0xFFF59E0B),
                done: '${therapist.doneCount} done',
              ),
              if (therapist != therapists.last)
                const Divider(height: 16, color: Color(0xFFF0F0F0)),
            ],
        ],
      ),
    );
  }
}

class _PhoneOtherCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color iconBg;
  final Color iconColor;
  final VoidCallback? onTap;

  const _PhoneOtherCard({
    required this.icon,
    required this.label,
    required this.iconBg,
    required this.iconColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: _PhoneCard(
          child: Row(
            children: [
              _IconBox(icon: icon, bg: iconBg, color: iconColor, size: 32),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A2E),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED SMALL WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class _DashboardErrorBanner extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _DashboardErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: Color(0xFFE53935)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Dashboard data unavailable: $message',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF991B1B),
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _BusinessProfileDialog extends StatelessWidget {
  final _BusinessProfile profile;
  final String email;

  const _BusinessProfileDialog({required this.profile, required this.email});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    color: const Color(0xFF1E88E5),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.logout_outlined),
                    color: const Color(0xFF1E88E5),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                width: 82,
                height: 82,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF1B6B72),
                ),
                child: Text(
                  profile.logoInitial,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                profile.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                email,
                style: const TextStyle(fontSize: 14, color: Color(0xFF9E9E9E)),
              ),
              const SizedBox(height: 24),
              _BusinessProfileRow(
                icon: Icons.storefront_outlined,
                iconBg: const Color(0xFFFFF3D6),
                iconColor: const Color(0xFFF59E0B),
                label: 'Outlet',
                value: profile.location.toUpperCase(),
                showChevron: true,
              ),
              const SizedBox(height: 12),
              const _BusinessProfileRow(
                icon: Icons.description_outlined,
                iconBg: Color(0xFFE3F2FD),
                iconColor: Color(0xFF1E88E5),
                label: 'Subscription',
                value: '31/12/2026',
              ),
              const SizedBox(height: 12),
              Row(
                children: const [
                  Expanded(
                    child: _BusinessProfileRow(
                      icon: Icons.language_outlined,
                      iconBg: Color(0xFFE3F2FD),
                      iconColor: Color(0xFF1E88E5),
                      label: 'Language',
                      value: 'English',
                      compact: true,
                      showChevron: true,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: _BusinessProfileRow(
                      icon: Icons.settings_outlined,
                      iconBg: Color(0xFFF1F3F6),
                      iconColor: Color(0xFF5F6B7A),
                      label: 'Version',
                      value: '1.0.0',
                      compact: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BusinessProfileRow extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String label;
  final String value;
  final bool compact;
  final bool showChevron;

  const _BusinessProfileRow({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.label,
    required this.value,
    this.compact = false,
    this.showChevron = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(minHeight: compact ? 60 : 58),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 18,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(icon, color: iconColor, size: 18),
          ),
          SizedBox(width: compact ? 10 : 14),
          Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 14,
                color: Color(0xFF8A8F98),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (showChevron) ...[
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 18, color: Color(0xFFB0B5BD)),
          ],
        ],
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  final String role;
  final bool isLoading;
  final bool compact;

  const _RolePill({
    required this.role,
    this.isLoading = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final isAdmin = role == 'admin';
    final label = isLoading
        ? '...'
        : isAdmin
        ? 'Admin'
        : 'Staff';
    final showIcon = isLoading;

    return Container(
      height: compact ? 38 : 46,
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 22),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE0E0E0)),
        borderRadius: BorderRadius.circular(compact ? 19 : 14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon) ...[
            Icon(
              Icons.hourglass_empty_outlined,
              size: compact ? 17 : 20,
              color: const Color(0xFF1B6B72),
            ),
            SizedBox(width: compact ? 4 : 8),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: compact ? 12 : 16,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF1A1A2E),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotificationButton extends StatelessWidget {
  final List<_TransactionSummary> transactions;
  final bool compact;

  const _NotificationButton({required this.transactions, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final buttonSize = compact ? 38.0 : 48.0;
    final iconSize = compact ? 20.0 : 24.0;

    return InkWell(
      onTap: () {
        showDialog<void>(
          context: context,
          builder: (context) => _NotificationDialog(transactions: transactions),
        );
      },
      borderRadius: BorderRadius.circular(compact ? 19 : 14),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: buttonSize,
            height: buttonSize,
            decoration: BoxDecoration(
              color: compact ? const Color(0xFFC8963E) : Colors.white,
              border: compact
                  ? null
                  : Border.all(color: const Color(0xFFE0E0E0)),
              borderRadius: BorderRadius.circular(compact ? 19 : 14),
            ),
            child: Icon(
              Icons.notifications_none_outlined,
              color: compact ? Colors.white : const Color(0xFF5F6B7A),
              size: iconSize,
            ),
          ),
          if (transactions.isNotEmpty)
            Positioned(
              top: compact ? -4 : -6,
              right: compact ? -2 : -4,
              child: Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFFE53935),
                ),
                child: Text(
                  '${transactions.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NotificationDialog extends StatelessWidget {
  final List<_TransactionSummary> transactions;

  const _NotificationDialog({required this.transactions});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    color: const Color(0xFF1E88E5),
                  ),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 4),
              Center(
                child: Container(
                  width: 82,
                  height: 82,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFE0F3F1),
                  ),
                  child: const Icon(
                    Icons.notifications_none_outlined,
                    color: Color(0xFF1B6B72),
                    size: 38,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const Center(
                child: Text(
                  'Recent Transactions',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  transactions.isEmpty
                      ? 'No paid transactions yet'
                      : '${transactions.length} recent transactions',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF9E9E9E),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Flexible(
                child: ScrollConfiguration(
                  behavior: const _NoScrollbarScrollBehavior(),
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: transactions.isEmpty ? 1 : transactions.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      if (transactions.isEmpty) {
                        return const _NotificationEmptyState();
                      }
                      return _TransactionTile(transaction: transactions[index]);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationEmptyState extends StatelessWidget {
  const _NotificationEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBFC),
        border: Border.all(color: const Color(0xFFE6E8EB)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Text(
        'Completed payments will appear here.',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          color: Color(0xFF5F6B7A),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final _TransactionSummary transaction;

  const _TransactionTile({required this.transaction});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBFC),
        border: Border.all(color: const Color(0xFFE6E8EB)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _IconBox(
            icon: Icons.shopping_cart_outlined,
            bg: const Color(0xFFE0F3F1),
            color: const Color(0xFF1B6B72),
            size: 40,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  transaction.customerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  transaction.serviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF5F6B7A),
                  ),
                ),
                if (transaction.therapistName != '-') ...[
                  const SizedBox(height: 3),
                  Text(
                    'By ${transaction.therapistName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF5F6B7A),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  '${transaction.date}  -  ${transaction.time}',
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF5F6B7A),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'RM ${transaction.amount.toStringAsFixed(0)}',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1B6B72),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoScrollbarScrollBehavior extends ScrollBehavior {
  const _NoScrollbarScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class _SettingsButton extends StatelessWidget {
  final VoidCallback onPressed;
  final bool compact;

  const _SettingsButton({required this.onPressed, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final size = compact ? 38.0 : 48.0;

    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(compact ? 19 : 14),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF1B6B72),
          borderRadius: BorderRadius.circular(compact ? 19 : 14),
        ),
        child: Icon(
          Icons.settings_outlined,
          color: Colors.white,
          size: compact ? 20 : 24,
        ),
      ),
    );
  }
}

class _BusinessSettingsDialog extends StatefulWidget {
  final _BusinessProfile profile;
  final bool isAdmin;

  const _BusinessSettingsDialog({required this.profile, required this.isAdmin});

  @override
  State<_BusinessSettingsDialog> createState() =>
      _BusinessSettingsDialogState();
}

class _BusinessSettingsDialogState extends State<_BusinessSettingsDialog> {
  final _authRepository = AuthRepository();
  late final TextEditingController _nameController;
  late final TextEditingController _locationController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.name);
    _locationController = TextEditingController(text: widget.profile.location);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  void _save() {
    if (!widget.isAdmin) return;

    Navigator.of(context).pop(
      widget.profile.copyWith(
        name: _nameController.text.trim(),
        location: _locationController.text.trim(),
      ),
    );
  }

  Future<void> _signOut() async {
    final shouldSignOut = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Log out?'),
        content: const Text(
          'Are you sure you want to log out of this account?',
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );

    if (shouldSignOut != true || !mounted) return;

    try {
      await _authRepository.signOut();
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
    } on AuthRepositoryException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(30, 28, 30, 24),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Business Settings',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFFF1F3F6),
                      foregroundColor: const Color(0xFF5F6B7A),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFE6E8EB)),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(30, 28, 30, 30),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!widget.isAdmin) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3E0),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'Only admins can edit business name, location, and logo.',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF8A5A00),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                    ],
                    _BusinessSettingsField(
                      label: 'Business Name',
                      controller: _nameController,
                      enabled: widget.isAdmin,
                    ),
                    const SizedBox(height: 24),
                    _BusinessSettingsField(
                      label: 'Location',
                      controller: _locationController,
                      enabled: widget.isAdmin,
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Business Logo',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF5F6B7A),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1B6B72),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            widget.profile.logoInitial,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: widget.isAdmin ? () {} : null,
                            icon: const Icon(Icons.upload_outlined),
                            label: const Text('Upload Logo'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(58),
                              foregroundColor: const Color(0xFF5F6B7A),
                              side: const BorderSide(color: Color(0xFFE0E0E0)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Recommended: Square image, min 200x200px',
                      style: TextStyle(fontSize: 14, color: Color(0xFF5F6B7A)),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _signOut,
                      icon: const Icon(Icons.logout_outlined),
                      label: const Text('Log Out'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                        backgroundColor: const Color(0xFFE53935),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: Color(0xFFE6E8EB)),
            Padding(
              padding: const EdgeInsets.all(30),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        backgroundColor: const Color(0xFFF1F3F6),
                        foregroundColor: const Color(0xFF1A1A2E),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: widget.isAdmin ? _save : null,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                        backgroundColor: const Color(0xFF1B6B72),
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: const Color(0xFFE6E8EB),
                        disabledForegroundColor: const Color(0xFF9E9E9E),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: const Text('Save Changes'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BusinessSettingsField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool enabled;

  const _BusinessSettingsField({
    required this.label,
    required this.controller,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF5F6B7A),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: controller,
          enabled: enabled,
          style: const TextStyle(fontSize: 16, color: Color(0xFF1A1A2E)),
          decoration: InputDecoration(
            filled: true,
            fillColor: enabled ? Colors.white : const Color(0xFFF6F7F8),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE0E0E0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(
                color: Color(0xFF1B6B72),
                width: 1.5,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 18,
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: Color(0xFF1A1A2E),
      ),
    );
  }
}

class _TabletCard extends StatelessWidget {
  final Widget child;
  const _TabletCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _PhoneCard extends StatelessWidget {
  final Widget child;
  const _PhoneCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _IconBox extends StatelessWidget {
  final IconData icon;
  final Color bg;
  final Color color;
  final double size;

  const _IconBox({
    required this.icon,
    required this.bg,
    required this.color,
    this.size = 38,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: color, size: size * 0.55),
    );
  }
}

class _AppointmentRow extends StatelessWidget {
  final String label;
  final String count;
  const _AppointmentRow({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A2E)),
        ),
        Text(
          count,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1B6B72),
          ),
        ),
      ],
    );
  }
}

class _TherapistRow extends StatelessWidget {
  final String name;
  final String status;
  final Color statusColor;
  final String done;

  const _TherapistRow({
    required this.name,
    required this.status,
    required this.statusColor,
    required this.done,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Status dot
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: statusColor),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              Text(
                status,
                style: TextStyle(
                  fontSize: 11,
                  color: statusColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            done,
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF9E9E9E),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _AnalyticsStat extends StatelessWidget {
  final String label;
  final String value;
  const _AnalyticsStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1A1A2E),
          ),
        ),
      ],
    );
  }
}
