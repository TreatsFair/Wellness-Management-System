import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/accessibility/accessibility_settings.dart';
import '../../core/outlets/outlet_context.dart';
import '../../core/services/csp_service.dart';
import '../../core/services/therapist_availability_refresh.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/staff_initials.dart';
import '../../data/repositories/appointment_repository.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/business_hours_repository.dart';
import '../../data/repositories/dashboard_repository.dart';
import '../../data/repositories/image_upload_repository.dart';
import '../../data/repositories/notification_repository.dart';
import '../../data/repositories/profile_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/transaction_repository.dart';
import '../../data/services/supabase_table_service.dart';
import '../../widgets/app_toast.dart';
import '../appointments/appointment_screen.dart';
import '../booking/booking_screen.dart';
import '../customers/customer_screen.dart';
import '../history/sales_history_screen.dart';
import '../orders/order_screen.dart';
import '../management/management_screen.dart';
import '../reports/reports_screen.dart';
import '../timetable/timetable_screen.dart';

enum _DashboardMainCard { quickBook, orders, appointments, members }

enum _DashboardOtherCard { history, members, management, reports, timetable }

typedef _DashboardReorder = void Function(String draggedId, String targetId);

const _defaultTabletMainOrder = <_DashboardMainCard>[
  _DashboardMainCard.quickBook,
  _DashboardMainCard.orders,
  _DashboardMainCard.appointments,
];

const _defaultPhoneMainOrder = <_DashboardMainCard>[
  _DashboardMainCard.appointments,
  _DashboardMainCard.quickBook,
  _DashboardMainCard.orders,
  _DashboardMainCard.members,
];

const _defaultOtherOrder = <_DashboardOtherCard>[
  _DashboardOtherCard.history,
  _DashboardOtherCard.members,
  _DashboardOtherCard.management,
  _DashboardOtherCard.reports,
  _DashboardOtherCard.timetable,
];

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
  final String id;
  final String name;
  final String imageUrl;
  final String status;
  final String reservationStatus;
  final bool isFree;
  final int doneCount;
  final int queuePosition;

  /// True for the therapist whose turn is next in the live running queue
  /// (the first free-now therapist, or the queue head while everyone is busy).
  /// Drives the "Next" badge.
  final bool isNext;

  const _TherapistStatus({
    this.id = '',
    required this.name,
    this.imageUrl = '',
    required this.status,
    this.reservationStatus = '',
    required this.isFree,
    required this.doneCount,
    this.queuePosition = 0,
    this.isNext = false,
  });

  _TherapistStatus copyWith({
    String? status,
    String? reservationStatus,
    bool? isFree,
    int? doneCount,
    int? queuePosition,
    bool? isNext,
  }) => _TherapistStatus(
    id: id,
    name: name,
    imageUrl: imageUrl,
    status: status ?? this.status,
    reservationStatus: reservationStatus ?? this.reservationStatus,
    isFree: isFree ?? this.isFree,
    doneCount: doneCount ?? this.doneCount,
    queuePosition: queuePosition ?? this.queuePosition,
    isNext: isNext ?? this.isNext,
  );
}

class _BusinessProfile {
  final String outletId;
  final String outletName;
  final String name;
  final String location;
  final String openTime;
  final String closeTime;
  final String logoInitial;
  final String logoUrl;
  final SelectedImage? logoUpload;
  final String? settingsDocumentId;

  const _BusinessProfile({
    required this.outletId,
    required this.outletName,
    required this.name,
    required this.location,
    required this.openTime,
    required this.closeTime,
    required this.logoInitial,
    this.logoUrl = '',
    this.logoUpload,
    this.settingsDocumentId,
  });

  _BusinessProfile copyWith({
    String? outletId,
    String? outletName,
    String? name,
    String? location,
    String? openTime,
    String? closeTime,
    String? logoInitial,
    String? logoUrl,
    SelectedImage? logoUpload,
    String? settingsDocumentId,
  }) {
    return _BusinessProfile(
      outletId: outletId ?? this.outletId,
      outletName: outletName ?? this.outletName,
      name: name ?? this.name,
      location: location ?? this.location,
      openTime: openTime ?? this.openTime,
      closeTime: closeTime ?? this.closeTime,
      logoInitial: logoInitial ?? this.logoInitial,
      logoUrl: logoUrl ?? this.logoUrl,
      logoUpload: logoUpload,
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
  outletId: '00000000-0000-0000-0000-000000000128',
  outletName: 'PV128',
  name: 'The Best Family Wellness',
  location: 'Kuala Lumpur',
  openTime: '09:00',
  closeTime: '21:00',
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

String _cleanTime(String value) {
  final raw = value.trim();
  return raw.length >= 5 ? raw.substring(0, 5) : raw;
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

String _queueReservationLabel(TherapistQueueEntry entry) {
  final start = entry.reservationStartAt;
  final end = entry.reservationEndAt;
  if (start != null && start.isNotEmpty && end != null && end.isNotEmpty) {
    return 'Reserved ${_timeLabel(start)}–${_timeLabel(end)}';
  }
  return 'Reserved';
}

bool _reservationApproaches(
  String? startTime,
  DateTime now, {
  int thresholdMinutes = 60,
}) {
  if (startTime == null || startTime.isEmpty) return false;
  final delta = _timeToMinutes(startTime) - (now.hour * 60 + now.minute);
  return delta >= 0 && delta <= thresholdMinutes;
}

bool _isCancelled(Map<String, dynamic> data) {
  final status = _asString(data['status']).toLowerCase().trim();
  return status == 'cancelled' || status == 'canceled';
}

bool _isWalkInAppointment(Map<String, dynamic> data) {
  final type = _asString(data['type']).toLowerCase().trim();
  return type == 'walkin' || type == 'walk_in' || type == 'walk-in';
}

bool _isReservedWalkInAppointment(Map<String, dynamic> data) {
  if (!_isWalkInAppointment(data)) return false;
  final status = _asString(data['status']).toLowerCase().trim();
  return status == 'confirmed' && _isPaid(data);
}

bool _isPendingAppointmentStatus(String status) {
  return status == 'pending' ||
      status == 'confirmed' ||
      status == 'in_progress';
}

bool _isPaid(Map<String, dynamic> data) {
  final status = _asString(data['paymentStatus']).toLowerCase().trim();
  return status.isEmpty || status == 'paid';
}

bool _isVoidedPayment(Map<String, dynamic> data) {
  return _asString(data['paymentStatus']).toLowerCase().trim() == 'voided';
}

bool _isNoShow(Map<String, dynamic> data) {
  final status = _asString(data['status']).toLowerCase().trim();
  return status == 'no_show' || status == 'no-show' || status == 'noshow';
}

bool _isStartedServiceSession(Map<String, dynamic> data) {
  return _asDateTime(data['actualStartedAt']) != null &&
      !_isCancelled(data) &&
      !_isVoidedPayment(data) &&
      !_isNoShow(data);
}

Map<String, int> _startedServiceCounts(
  Iterable<Map<String, dynamic>> appointments,
  String dateKey,
) {
  final counts = <String, int>{};
  for (final appointment in appointments) {
    if (_asString(appointment['date']) != dateKey ||
        !_isStartedServiceSession(appointment)) {
      continue;
    }
    final therapistId = _asString(appointment['therapistId']);
    if (therapistId.isEmpty) continue;
    counts.update(therapistId, (value) => value + 1, ifAbsent: () => 1);
  }
  return counts;
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
  final _appointmentRepository = AppointmentRepository();
  final _settingsRepository = SettingsRepository();

  final _businessHoursTable = SupabaseTableService('business_hours');
  final _outletsTable = SupabaseTableService('outlets');
  _BusinessProfile _businessProfile = _placeholderBusinessProfile;
  _DashboardData _dashboardData = _DashboardData.empty;
  List<_TherapistStatus> _therapistStatusSource = [];
  bool _isCurrentUserAdmin = false;
  String _currentUserRole = 'staff';
  String _currentUserEmail = 'No email';
  bool _isLoadingBusinessSettings = true;
  bool _isLoadingDashboardData = true;
  String? _dashboardError;
  SharedPreferences? _dashboardPreferences;
  List<_DashboardMainCard> _tabletMainOrder = [..._defaultTabletMainOrder];
  List<_DashboardMainCard> _phoneMainOrder = [..._defaultPhoneMainOrder];
  List<_DashboardOtherCard> _tabletOtherOrder = [..._defaultOtherOrder];
  List<_DashboardOtherCard> _phoneOtherOrder = [..._defaultOtherOrder];

  final _notificationRepository = NotificationRepository();
  final _transactionRepository = TransactionRepository();
  int _unreadNotifications = 0;
  RealtimeChannel? _notificationChannel;
  List<Map<String, dynamic>> _todayAppointmentsCache = [];
  List<AppNotification> _startingSoon = [];
  final Set<String> _startingSoonNotified = {};
  Timer? _startingSoonTimer;
  Timer? _therapistQueueTimer;
  bool _isRefreshingTherapistQueue = false;
  int _dashboardLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    TherapistAvailabilityRefresh.revision.addListener(
      _onTherapistAvailabilityInvalidated,
    );
    _loadBusinessSettings();
    _loadDashboardData();
    unawaited(_loadDashboardOrders());
    unawaited(_refreshUnreadNotifications());
    _subscribeToNotifications();
    OutletContext.activeOutletId.addListener(_onOutletChangedForNotifications);
    _startingSoonTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshStartingSoon(),
    );
    _therapistQueueTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_refreshTherapistQueueBoard()),
    );
  }

  @override
  void dispose() {
    _startingSoonTimer?.cancel();
    _therapistQueueTimer?.cancel();
    TherapistAvailabilityRefresh.revision.removeListener(
      _onTherapistAvailabilityInvalidated,
    );
    OutletContext.activeOutletId.removeListener(
      _onOutletChangedForNotifications,
    );
    final channel = _notificationChannel;
    _notificationChannel = null;
    if (channel != null) {
      unawaited(_notificationRepository.unsubscribe(channel));
    }
    super.dispose();
  }

  void _onTherapistAvailabilityInvalidated() {
    unawaited(_loadDashboardData());
  }

  // ── Notifications ────────────────────────────────────────────────

  void _onOutletChangedForNotifications() {
    _startingSoonNotified.clear();
    _startingSoon = [];
    _subscribeToNotifications();
    unawaited(_refreshUnreadNotifications());
  }

  void _subscribeToNotifications() {
    final previous = _notificationChannel;
    if (previous != null) {
      unawaited(_notificationRepository.unsubscribe(previous));
    }
    _notificationChannel = _notificationRepository.subscribeToInserts(
      _onNotificationInsert,
    );
  }

  Future<void> _refreshUnreadNotifications() async {
    try {
      final count = await _notificationRepository.unreadCount();
      if (!mounted) return;
      setState(() => _unreadNotifications = count);
    } catch (_) {
      // The notifications table may not exist yet (migration 077 pending);
      // the dashboard must keep working without it.
    }
  }

  void _onNotificationInsert(AppNotification notification) {
    if (!mounted) return;
    setState(() => _unreadNotifications += 1);
    _showNotificationToast(notification);
    // New online bookings and cancellations change today's numbers.
    unawaited(_loadDashboardData(showSpinner: false));
  }

  void _showNotificationToast(AppNotification notification) {
    if (!mounted) return;
    AppToast.notice(
      context,
      title: notification.title,
      message: notification.body,
      icon: _notificationIconFor(notification.type),
      accentColor: _notificationAccentFor(notification.type),
      actionLabel: notification.hasOpenableTarget ? 'View' : null,
      onAction: notification.hasOpenableTarget
          ? () => _openNotificationTarget(notification)
          : null,
    );
  }

  void _refreshStartingSoon() {
    if (!mounted) return;
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final soon = <AppNotification>[];
    for (final data in _todayAppointmentsCache) {
      final status = _asString(data['status']).toLowerCase();
      if (status != 'confirmed') continue;
      final id = _asString(data['id']);
      if (id.isEmpty) continue;
      final start = _timeToMinutes(_asString(data['startTime']));
      final minutesAway = start - nowMinutes;
      if (minutesAway < 0 || minutesAway > 10) continue;
      final serviceName = _asString(data['serviceName'], 'Appointment');
      final startLabel = _timeLabel(_asString(data['startTime']));
      final timingTitle = minutesAway == 0
          ? 'Appointment starting now'
          : 'Appointment in $minutesAway minute${minutesAway == 1 ? '' : 's'}';
      final notification = AppNotification(
        id: 'soon-$id',
        type: AppNotification.startingSoonType,
        title: timingTitle,
        body: '$serviceName at $startLabel',
        appointmentId: id,
        createdAt: now,
      );
      soon.add(notification);
      if (_startingSoonNotified.add(id)) {
        _showNotificationToast(notification);
      }
    }
    setState(() => _startingSoon = soon);
  }

  Future<void> _openNotificationTarget(AppNotification notification) async {
    if (!mounted) return;
    if (notification.type != AppNotification.startingSoonType) {
      unawaited(_notificationRepository.markRead(notification.id));
    }
    // Failed/expired online-payment notifications point to a booking hold.
    // There is no hold-detail screen, so mark them read without pretending
    // that a generic appointment screen is their destination.
    if (!notification.hasOpenableTarget) {
      unawaited(_refreshUnreadNotifications());
      return;
    }
    final role = _currentUserRole;
    if (notification.linksToTransaction) {
      try {
        final transaction = await _transactionRepository.getTransaction(
          notification.transactionId,
        );
        final receiptNumber = _asString(transaction?['receiptNumber']);
        if (!mounted) return;
        if (receiptNumber.isNotEmpty) {
          await showTransactionOrderDetailSheet(
            context,
            receiptNumber: receiptNumber,
          );
        } else {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SalesHistoryScreen(userRole: role),
            ),
          );
        }
      } catch (_) {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SalesHistoryScreen(userRole: role)),
        );
      }
    } else {
      DateTime? initialDate;
      if (notification.appointmentId.isNotEmpty) {
        try {
          final row = await _appointmentRepository.getAppointment(
            notification.appointmentId,
          );
          initialDate = _asDateTime(row?['date']);
        } catch (_) {
          initialDate = null;
        }
      }
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              AppointmentsScreen(userRole: role, initialDate: initialDate),
        ),
      );
    }
    unawaited(_refreshUnreadNotifications());
    unawaited(_loadDashboardData(showSpinner: false));
  }

  Future<void> _openNotificationCenter() async {
    await showDialog<void>(
      context: context,
      builder: (context) => _NotificationDialog(
        repository: _notificationRepository,
        startingSoon: _startingSoon,
        onOpenTarget: _openNotificationTarget,
      ),
    );
    unawaited(_refreshUnreadNotifications());
  }

  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 900;

  String _dashboardOrderKey(String layout) {
    final owner = _authRepository.currentUser?.id ?? 'device';
    return 'dashboard_card_order:$owner:$layout';
  }

  List<T> _restoreDashboardOrder<T extends Enum>(
    List<String>? saved,
    List<T> defaults,
  ) {
    final byName = {for (final item in defaults) item.name: item};
    final restored = <T>[];
    for (final name in saved ?? const <String>[]) {
      final item = byName[name];
      if (item != null && !restored.contains(item)) restored.add(item);
    }
    for (final item in defaults) {
      if (!restored.contains(item)) restored.add(item);
    }
    return restored;
  }

  Future<void> _loadDashboardOrders() async {
    final preferences = await SharedPreferences.getInstance();
    final tabletMain = _restoreDashboardOrder(
      preferences.getStringList(_dashboardOrderKey('tablet_main')),
      _defaultTabletMainOrder,
    );
    final phoneMain = _restoreDashboardOrder(
      preferences.getStringList(_dashboardOrderKey('phone_main')),
      _defaultPhoneMainOrder,
    );
    final tabletOther = _restoreDashboardOrder(
      preferences.getStringList(_dashboardOrderKey('tablet_other')),
      _defaultOtherOrder,
    );
    final phoneOther = _restoreDashboardOrder(
      preferences.getStringList(_dashboardOrderKey('phone_other')),
      _defaultOtherOrder,
    );
    if (!mounted) return;
    setState(() {
      _dashboardPreferences = preferences;
      _tabletMainOrder = tabletMain;
      _phoneMainOrder = phoneMain;
      _tabletOtherOrder = tabletOther;
      _phoneOtherOrder = phoneOther;
    });
  }

  List<T> _moveDashboardCard<T extends Enum>(
    List<T> current,
    String draggedId,
    String targetId,
  ) {
    final oldIndex = current.indexWhere((item) => item.name == draggedId);
    final targetIndex = current.indexWhere((item) => item.name == targetId);
    if (oldIndex < 0 || targetIndex < 0 || oldIndex == targetIndex) {
      return current;
    }
    final next = [...current];
    final moved = next.removeAt(oldIndex);
    next.insert(targetIndex.clamp(0, next.length), moved);
    return next;
  }

  Future<void> _saveDashboardOrder(String layout, Iterable<Enum> order) async {
    final preferences =
        _dashboardPreferences ?? await SharedPreferences.getInstance();
    _dashboardPreferences = preferences;
    await preferences.setStringList(
      _dashboardOrderKey(layout),
      order.map((item) => item.name).toList(),
    );
  }

  void _reorderTabletMain(String draggedId, String targetId) {
    final next = _moveDashboardCard(_tabletMainOrder, draggedId, targetId);
    if (identical(next, _tabletMainOrder)) return;
    setState(() => _tabletMainOrder = next);
    unawaited(_saveDashboardOrder('tablet_main', next));
  }

  void _reorderPhoneMain(String draggedId, String targetId) {
    final next = _moveDashboardCard(_phoneMainOrder, draggedId, targetId);
    if (identical(next, _phoneMainOrder)) return;
    setState(() => _phoneMainOrder = next);
    unawaited(_saveDashboardOrder('phone_main', next));
  }

  void _reorderTabletOther(String draggedId, String targetId) {
    final next = _moveDashboardCard(_tabletOtherOrder, draggedId, targetId);
    if (identical(next, _tabletOtherOrder)) return;
    setState(() => _tabletOtherOrder = next);
    unawaited(_saveDashboardOrder('tablet_other', next));
  }

  void _reorderPhoneOther(String draggedId, String targetId) {
    final next = _moveDashboardCard(_phoneOtherOrder, draggedId, targetId);
    if (identical(next, _phoneOtherOrder)) return;
    setState(() => _phoneOtherOrder = next);
    unawaited(_saveDashboardOrder('phone_other', next));
  }

  Future<Map<String, Map<String, dynamic>>> _loadDocMap(
    String collection,
    Iterable<String> ids,
  ) async {
    return _dashboardRepository.loadByIds(collection, ids);
  }

  Future<void> _loadDashboardData({bool showSpinner = true}) async {
    final loadGeneration = ++_dashboardLoadGeneration;
    if (mounted && showSpinner) {
      setState(() {
        _isLoadingDashboardData = true;
        _dashboardError = null;
      });
    }

    try {
      await _appointmentRepository.completeDueAppointments();
      await _appointmentRepository.markPastAppointmentsNoShow();
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
        (data) =>
            !_isCancelled(data) &&
            !_isVoidedPayment(data) &&
            (!_isWalkInAppointment(data) || _isReservedWalkInAppointment(data)),
      );
      final todayAppointments = activeAppointments
          .where((data) => _asString(data['date']) == todayKey)
          .toList();
      final tomorrowAppointments = activeAppointments
          .where((data) => _asString(data['date']) == tomorrowKey)
          .toList();
      final serviceCountsByTherapist = _startedServiceCounts(
        appointments,
        todayKey,
      );
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
      // Staff Availability is the therapist queue board -- counter/cashier
      // staff are not part of the running queue, so keep them out of it.
      final therapistStatuses = therapistRows.where((data) {
        final role = _asString(data['role']).toLowerCase();
        return !role.contains('counter') && !role.contains('cashier');
      }).map((data) {
        final therapistId = _asString(data['id']);
        final therapistAppointments = todayAppointments
            .where(
              (appointment) =>
                  _asString(appointment['therapistId']) == therapistId,
            )
            .toList();
        final doneCount = serviceCountsByTherapist[therapistId] ?? 0;
        Map<String, dynamic>? currentAppointment;
        Map<String, dynamic>? nextReservation;
        var nextReservationStart = 24 * 60 + 1;
        for (final appointment in therapistAppointments) {
          final status = _asString(appointment['status']).toLowerCase();
          if (!_isPendingAppointmentStatus(status)) continue;
          final actualStart = _asDateTime(
            appointment['actualStartedAt'],
          )?.toLocal();
          final expectedEnd = _asDateTime(appointment['endAt'])?.toLocal();
          final scheduledStart = _timeToMinutes(
            _asString(appointment['startTime']),
          );
          final end = expectedEnd == null
              ? _timeToMinutes(_asString(appointment['endTime']))
              : expectedEnd.hour * 60 + expectedEnd.minute;
          if (actualStart != null && end > nowMinutes) {
            currentAppointment = appointment;
            break;
          }
          if (actualStart == null &&
              end > nowMinutes &&
              scheduledStart < nextReservationStart) {
            nextReservation = appointment;
            nextReservationStart = scheduledStart;
          }
        }

        final name = _asString(data['name'], 'Staff');
        final availability = data['availabilityStatus'];
        final busyUntil = _asString(data['busyUntil']);
        final isAvailable = availability is bool ? availability : true;
        final isFree = currentAppointment == null && isAvailable;
        final liveEnd = currentAppointment == null
            ? null
            : _asDateTime(currentAppointment['endAt'])?.toLocal();
        final endTime = currentAppointment == null
            ? busyUntil
            : liveEnd == null
            ? _asString(currentAppointment['endTime'])
            : DateFormat('HH:mm').format(liveEnd);
        final reservationEnd = nextReservation == null
            ? ''
            : _asString(nextReservation['endTime']);
        final reservationRange = nextReservation == null
            ? ''
            : '${_timeLabel(_asString(nextReservation['startTime']))}–${_timeLabel(reservationEnd)}';
        final status = currentAppointment != null
            ? endTime.isEmpty
                  ? 'Busy now'
                  : 'Busy until ${_timeLabel(endTime)}'
            : isFree
            ? 'Free now'
            : busyUntil.isEmpty
            ? 'Unavailable now'
            : 'Unavailable until ${_timeLabel(busyUntil)}';

        return _TherapistStatus(
          id: therapistId,
          name: name,
          imageUrl: _asString(
            data['profileImageUrl'],
            _asString(data['imageUrl']),
          ),
          status: status,
          reservationStatus:
              nextReservation != null &&
                  _reservationApproaches(
                    _asString(nextReservation['startTime']),
                    now,
                  )
              ? 'Reserved $reservationRange'
              : '',
          isFree: isFree,
          doneCount: doneCount,
        );
      }).toList();

      // Order the staff board by the live running queue and flag whose turn is
      // next (first free-now in rotation order). Best-effort: if the queue RPC
      // is unavailable the board just keeps its default order.
      final orderedTherapistStatuses =
          await _applyQueueOrder(therapistStatuses) ??
          const <_TherapistStatus>[];

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
        ...linkedAppointments.values.map(
          (data) => _asString(data['serviceId']),
        ),
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

      if (!mounted || loadGeneration != _dashboardLoadGeneration) return;
      setState(() {
        _therapistStatusSource = therapistStatuses;
        _dashboardData = _DashboardData(
          stats: stats,
          therapists: orderedTherapistStatuses,
          recentTransactions: recentTransactions,
        );
        _todayAppointmentsCache = todayAppointments;
        _isLoadingDashboardData = false;
      });
      _refreshStartingSoon();
    } catch (e) {
      if (!mounted || loadGeneration != _dashboardLoadGeneration) return;
      setState(() {
        _dashboardError = e.toString();
        _isLoadingDashboardData = false;
      });
    }
  }

  /// Sorts the staff board by the live running queue (rotation order) and marks
  /// the therapist whose turn is next. When nobody is free for the full
  /// duration window, the first person in rotation remains Next so the board
  /// never loses the live queue head. Only staff in the current shift-aware
  /// queue are returned. Best-effort: any RPC failure returns the source list.
  Future<List<_TherapistStatus>?> _applyQueueOrder(
    List<_TherapistStatus> statuses,
  ) async {
    try {
      final now = DateTime.now();
      final queue = await CspService.getTherapistQueue(
        outletId: OutletContext.activeOutletId.value,
        date: DateFormat('yyyy-MM-dd').format(now),
        nowTime: DateFormat('HH:mm:ss').format(now),
        // The Dashboard has no selected service. A one-minute window answers
        // the generic question "who is free right now" without hiding staff
        // near the end of a shift behind an arbitrary 60-minute assumption.
        duration: 1,
      );
      if (queue.isEmpty) return const <_TherapistStatus>[];

      final rankById = <String, int>{};
      String? nextId;
      for (var i = 0; i < queue.length; i++) {
        rankById[queue[i].therapistId] = i;
        if (nextId == null && queue[i].isRecommended) {
          nextId = queue[i].therapistId;
        }
      }
      nextId ??= queue.first.therapistId;

      final statusById = {for (final status in statuses) status.id: status};
      final ordered = <_TherapistStatus>[];
      for (final entry in queue) {
        final status = statusById[entry.therapistId];
        if (status == null) continue;
        ordered.add(
          status.copyWith(
            status: entry.isFreeNow
                ? 'Free now'
                : entry.freeAt == null || entry.freeAt!.isEmpty
                ? 'Busy now'
                : 'Busy until ${_timeLabel(entry.freeAt!)}',
            reservationStatus:
                (entry.isReserved || entry.isTentativeHold) &&
                    _reservationApproaches(entry.reservationStartAt, now)
                ? _queueReservationLabel(entry)
                : status.reservationStatus,
            isFree: entry.isFreeNow,
            isNext: entry.therapistId == nextId,
          ),
        );
      }
      ordered.sort((a, b) {
        if (a.isNext != b.isNext) return a.isNext ? -1 : 1;
        if (a.isFree != b.isFree) return a.isFree ? -1 : 1;
        return (rankById[a.id] ?? 9999).compareTo(rankById[b.id] ?? 9999);
      });
      return [
        for (var index = 0; index < ordered.length; index++)
          ordered[index].copyWith(queuePosition: index + 1),
      ];
    } catch (error) {
      debugPrint('Unable to apply live therapist queue order: $error');
      return null;
    }
  }

  Future<void> _refreshTherapistQueueBoard() async {
    if (_isRefreshingTherapistQueue || _therapistStatusSource.isEmpty) {
      return;
    }
    _isRefreshingTherapistQueue = true;
    try {
      final now = DateTime.now();
      final todayKey = _dateKey(now);
      final appointmentRows = await _dashboardRepository.appointmentsForDate(
        todayKey,
      );
      final counts = _startedServiceCounts(appointmentRows, todayKey);
      final updatedSource = [
        for (final therapist in _therapistStatusSource)
          therapist.copyWith(doneCount: counts[therapist.id] ?? 0),
      ];
      final therapists = await _applyQueueOrder(updatedSource);
      if (therapists == null) return;
      if (!mounted) return;
      setState(() {
        _therapistStatusSource = updatedSource;
        _dashboardData = _DashboardData(
          stats: _dashboardData.stats,
          therapists: therapists,
          recentTransactions: _dashboardData.recentTransactions,
        );
      });
    } finally {
      _isRefreshingTherapistQueue = false;
    }
  }

  Future<void> _loadBusinessSettings() async {
    final currentUser = _authRepository.currentUser;
    var email = currentUser?.email;

    final activeOutlet = OutletContext.activeOutlet;
    var profile = _placeholderBusinessProfile.copyWith(
      outletId: activeOutlet.id,
      outletName: activeOutlet.name,
    );
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
      final outlet = await _outletsTable.getById(activeOutlet.id);
      if (outlet != null) {
        profile = profile.copyWith(
          outletName: _asString(outlet['name'], activeOutlet.name),
          location: _asString(outlet['address'], profile.location),
        );
      }
    } catch (_) {
      // Keep the known outlet name and fallback address.
    }

    try {
      final data = await _settingsRepository.getBusinessSettings();
      if (data != null) {
        profile = _BusinessProfile(
          outletId: profile.outletId,
          outletName: profile.outletName,
          name: (data['businessName'] as String?)?.trim().isNotEmpty == true
              ? (data['businessName'] as String).trim()
              : _placeholderBusinessProfile.name,
          location: profile.location,
          openTime: profile.openTime,
          closeTime: profile.closeTime,
          logoInitial: _placeholderBusinessProfile.logoInitial,
          logoUrl: _asString(data['logoUrl']),
          settingsDocumentId: _asString(data['id']),
        );
      }
    } catch (_) {
      // Keep the placeholder business profile when settings are unavailable.
    }

    try {
      final hourRows = await _businessHoursTable.findBy(
        'day_of_week',
        DateTime.now().weekday % 7,
        limit: 1,
      );
      final hours = hourRows.isEmpty ? null : hourRows.first;
      if (hours != null) {
        profile = profile.copyWith(
          openTime: _cleanTime(_asString(hours['openTime'], profile.openTime)),
          closeTime: _cleanTime(
            _asString(hours['closeTime'], profile.closeTime),
          ),
        );
      }
    } catch (_) {
      // Keep default business hours when the hours row is unavailable.
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
    if (profile.outletId != OutletContext.activeOutletId.value) {
      OutletContext.select(profile.outletId);
      setState(() {
        _isLoadingBusinessSettings = true;
        _isLoadingDashboardData = true;
      });
      await _loadBusinessSettings();
      await _loadDashboardData();
      return;
    }

    final uid = _authRepository.currentUser?.id;
    if (!_isCurrentUserAdmin || uid == null) {
      AppToast.error(
        context,
        'Only admins can edit business settings',
        title: 'Not allowed',
      );
      return;
    }

    final settingsDocumentId =
        profile.settingsDocumentId ?? _businessSettingsDocumentId;

    try {
      var logoUrl = profile.logoUrl;
      if (profile.logoUpload != null) {
        logoUrl = await ImageUploadRepository().uploadImage(
          image: profile.logoUpload!,
          folder: 'business',
          id: 'logo',
          previousUrl: _businessProfile.logoUrl,
        );
      } else if (logoUrl.trim().isEmpty &&
          _businessProfile.logoUrl.trim().isNotEmpty) {
        await ImageUploadRepository().removePublicUrl(_businessProfile.logoUrl);
      }

      final savedSettings = await _settingsRepository.updateBusinessSettings(
        {'businessName': profile.name, 'logoUrl': logoUrl},
        id: settingsDocumentId == _businessSettingsDocumentId
            ? null
            : settingsDocumentId,
      );

      await _outletsTable.update(profile.outletId, {
        'address': profile.location,
      });

      if (!mounted) return;
      setState(() {
        _businessProfile = profile.copyWith(
          logoUrl: logoUrl,
          settingsDocumentId: _asString(
            savedSettings['id'],
            settingsDocumentId,
          ),
        );
      });

      AppToast.success(context, 'Business settings updated');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Unable to save business settings: $e');
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

  Future<void> _switchOutlet(String outletId) async {
    if (!_isCurrentUserAdmin ||
        outletId == OutletContext.activeOutletId.value) {
      return;
    }
    OutletContext.select(outletId);
    if (!mounted) return;
    setState(() {
      _isLoadingBusinessSettings = true;
      _isLoadingDashboardData = true;
    });
    await _loadBusinessSettings();
    await _loadDashboardData();
  }

  Future<void> _openTodayQueueManager() async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TodayQueueManagementDialog(
        outletId: OutletContext.activeOutletId.value,
      ),
    );
    if (changed == true) {
      await _loadDashboardData(showSpinner: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = _isTablet(context);
    return Scaffold(
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
                notificationCount: _unreadNotifications + _startingSoon.length,
                onOpenNotifications: _openNotificationCenter,
                onRefreshDashboard: _loadDashboardData,
                onManageTodayQueue: _openTodayQueueManager,
                onOpenSettings: _openBusinessSettings,
                onSwitchOutlet: _switchOutlet,
                mainOrder: _tabletMainOrder,
                otherOrder: _tabletOtherOrder,
                onReorderMain: _reorderTabletMain,
                onReorderOther: _reorderTabletOther,
              )
            : _PhoneLayout(
                profile: _businessProfile,
                email: _currentUserEmail,
                role: _currentUserRole,
                isLoadingSettings: _isLoadingBusinessSettings,
                dashboardData: _dashboardData,
                isLoadingDashboard: _isLoadingDashboardData,
                dashboardError: _dashboardError,
                notificationCount: _unreadNotifications + _startingSoon.length,
                onOpenNotifications: _openNotificationCenter,
                onRefreshDashboard: _loadDashboardData,
                onManageTodayQueue: _openTodayQueueManager,
                onOpenSettings: _openBusinessSettings,
                onSwitchOutlet: _switchOutlet,
                mainOrder: _phoneMainOrder,
                otherOrder: _phoneOtherOrder,
                onReorderMain: _reorderPhoneMain,
                onReorderOther: _reorderPhoneOther,
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
  final int notificationCount;
  final VoidCallback onOpenNotifications;
  final Future<void> Function() onRefreshDashboard;
  final VoidCallback onManageTodayQueue;
  final VoidCallback onOpenSettings;
  final Future<void> Function(String) onSwitchOutlet;
  final List<_DashboardMainCard> mainOrder;
  final List<_DashboardOtherCard> otherOrder;
  final _DashboardReorder onReorderMain;
  final _DashboardReorder onReorderOther;

  const _TabletLayout({
    required this.profile,
    required this.email,
    required this.role,
    required this.isLoadingSettings,
    required this.dashboardData,
    required this.isLoadingDashboard,
    required this.dashboardError,
    required this.notificationCount,
    required this.onOpenNotifications,
    required this.onRefreshDashboard,
    required this.onManageTodayQueue,
    required this.onOpenSettings,
    required this.onSwitchOutlet,
    required this.mainOrder,
    required this.otherOrder,
    required this.onReorderMain,
    required this.onReorderOther,
  });

  Widget _buildMainCard(BuildContext context, _DashboardMainCard card) {
    final child = switch (card) {
      _DashboardMainCard.quickBook => _TabletQuickBookCard(
        role: role,
        onRefreshDashboard: onRefreshDashboard,
      ),
      _DashboardMainCard.orders => _TabletOrdersCard(
        stats: dashboardData.stats,
        isLoading: isLoadingDashboard,
        onRefreshDashboard: onRefreshDashboard,
      ),
      _DashboardMainCard.appointments => _TabletAppointmentCard(
        role: role,
        stats: dashboardData.stats,
        isLoading: isLoadingDashboard,
        onRefreshDashboard: onRefreshDashboard,
      ),
      _DashboardMainCard.members => _TabletOtherCard(
        icon: Icons.people_alt_rounded,
        label: 'Members',
        iconBg: AppColors.infoSoft,
        iconColor: AppColors.info,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CustomerScreen()),
        ),
      ),
    };
    return _ReorderableDashboardCard(
      group: 'tablet-main',
      id: card.name,
      onReorder: onReorderMain,
      child: child,
    );
  }

  Widget _buildOtherCard(BuildContext context, _DashboardOtherCard card) {
    final child = switch (card) {
      _DashboardOtherCard.history => _TabletOtherCard(
        icon: Icons.history_rounded,
        label: 'History',
        iconBg: AppColors.infoSoft,
        iconColor: AppColors.info,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SalesHistoryScreen(userRole: role)),
        ),
      ),
      _DashboardOtherCard.members => _TabletOtherCard(
        icon: Icons.people_alt_rounded,
        label: 'Members',
        iconBg: AppColors.infoSoft,
        iconColor: AppColors.info,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CustomerScreen()),
        ),
      ),
      _DashboardOtherCard.management => _TabletOtherCard(
        icon: Icons.manage_accounts_rounded,
        label: 'Management',
        iconBg: AppColors.successSoft,
        iconColor: AppColors.success,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ManagementScreen(userRole: role)),
        ),
      ),
      _DashboardOtherCard.reports => _TabletOtherCard(
        icon: Icons.insights_rounded,
        label: 'Reports',
        iconBg: AppColors.primarySoft,
        iconColor: AppColors.primary,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ReportsScreen(userRole: role)),
        ),
      ),
      _DashboardOtherCard.timetable => _TabletOtherCard(
        icon: Icons.calendar_view_week_rounded,
        label: 'Timetable',
        iconBg: AppColors.accentSoft,
        iconColor: AppColors.accent,
        onTap: () async {
          await Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => TimetableScreen(userRole: role)),
          );
          await onRefreshDashboard();
        },
      ),
    };
    return _ReorderableDashboardCard(
      group: 'tablet-other',
      id: card.name,
      onReorder: onReorderOther,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleOtherOrder = otherOrder
        .where((card) => role == 'admin' || card != _DashboardOtherCard.reports)
        .toList();
    return Column(
      children: [
        // ── Top bar ────────────────────────────────────────────
        _DashboardTopBar(
          profile: profile,
          email: email,
          role: role,
          isLoadingSettings: isLoadingSettings,
          notificationCount: notificationCount,
          onOpenNotifications: onOpenNotifications,
          onOpenSettings: onOpenSettings,
          onSwitchOutlet: onSwitchOutlet,
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

                SizedBox(
                  height: 210 * context.uiScale.dashboardScale,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (
                        var index = 0;
                        index < mainOrder.length;
                        index++
                      ) ...[
                        if (index > 0) const SizedBox(width: 16),
                        Expanded(
                          child: _buildMainCard(context, mainOrder[index]),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 32),

                _TabletStaffAvailabilityCard(
                  therapists: dashboardData.therapists,
                  isLoading: isLoadingDashboard,
                  onManageTodayQueue: onManageTodayQueue,
                ),

                const SizedBox(height: 32),

                // Others section label
                const _SectionLabel('Others'),
                const SizedBox(height: 12),

                // Long-press an action card to rearrange this row.
                Row(
                  children: [
                    for (
                      var index = 0;
                      index < visibleOtherOrder.length;
                      index++
                    ) ...[
                      if (index > 0) const SizedBox(width: 16),
                      Expanded(
                        child: _buildOtherCard(
                          context,
                          visibleOtherOrder[index],
                        ),
                      ),
                    ],
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

class _BusinessLogoAvatar extends StatelessWidget {
  final _BusinessProfile profile;
  final double size;
  final bool circular;
  final SelectedImage? preview;

  const _BusinessLogoAvatar({
    required this.profile,
    required this.size,
    this.circular = false,
    this.preview,
  });

  @override
  Widget build(BuildContext context) {
    final imageUrl = profile.logoUrl.trim();
    final hasImage = preview != null || imageUrl.isNotEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(circular ? size / 2 : 12),
      child: Container(
        width: size,
        height: size,
        color: hasImage ? Colors.transparent : const Color(0xFF1B6B72),
        alignment: Alignment.center,
        child: preview != null
            ? Image.memory(
                preview!.bytes,
                width: size,
                height: size,
                fit: BoxFit.cover,
              )
            : imageUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: imageUrl,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => _LogoInitial(profile: profile),
                placeholder: (_, _) => _LogoInitial(profile: profile),
              )
            : _LogoInitial(profile: profile),
      ),
    );
  }
}

class _LogoInitial extends StatelessWidget {
  final _BusinessProfile profile;

  const _LogoInitial({required this.profile});

  @override
  Widget build(BuildContext context) {
    return Text(
      profile.logoInitial,
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.bold,
        fontSize: 16,
      ),
    );
  }
}

/// Shared dashboard header used by both the tablet and phone layouts:
/// business identity on the left, role pill + recent-sales bell + settings
/// on the right. Styled from the app-wide design tokens.
class _DashboardTopBar extends StatelessWidget {
  final _BusinessProfile profile;
  final String email;
  final String role;
  final bool isLoadingSettings;
  final int notificationCount;
  final VoidCallback onOpenNotifications;
  final VoidCallback onOpenSettings;
  final Future<void> Function(String) onSwitchOutlet;

  const _DashboardTopBar({
    required this.profile,
    required this.email,
    required this.role,
    required this.isLoadingSettings,
    required this.notificationCount,
    required this.onOpenNotifications,
    required this.onOpenSettings,
    required this.onSwitchOutlet,
  });

  void _openBusinessProfile(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => _BusinessProfileDialog(
        profile: profile,
        email: email,
        isAdmin: role == 'admin',
        onSwitchOutlet: onSwitchOutlet,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.appSurface,
        border: Border(bottom: BorderSide(color: context.appBorder)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => _openBusinessProfile(context),
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xs),
                child: Row(
                  children: [
                    _BusinessLogoAvatar(
                      profile: profile,
                      size: 38,
                      circular: true,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.label.copyWith(fontSize: 15),
                          ),
                          Text(
                            profile.outletName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _RolePill(role: role, isLoading: isLoadingSettings),
          const SizedBox(width: AppSpacing.sm),
          IconButton.outlined(
            onPressed: onOpenNotifications,
            tooltip: 'Notifications',
            style: IconButton.styleFrom(
              side: BorderSide(color: context.appBorder),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
            ),
            icon: Badge(
              isLabelVisible: notificationCount > 0,
              label: Text('$notificationCount'),
              child: const Icon(Icons.notifications_rounded),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          IconButton.filled(
            onPressed: onOpenSettings,
            tooltip: 'Business settings',
            style: IconButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
            ),
            icon: const Icon(Icons.settings_rounded),
          ),
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
          color: AppColors.primary,
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
                    Icons.add_rounded,
                    color: AppColors.primary,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                const Text(
                  'Quick Book',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
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
                  icon: Icons.point_of_sale_rounded,
                  bg: AppColors.accentSoft,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 12),
                Text(
                  'Order',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: context.appText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Sales Collected',
              style: TextStyle(fontSize: 12, color: context.appMuted),
            ),
            const SizedBox(height: 6),
            Text(
              isLoading ? '-' : 'RM ${stats.todaySales.toStringAsFixed(0)}',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: context.appText,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              isLoading
                  ? 'Loading transactions'
                  : '${stats.totalTransactions} paid transactions',
              style: TextStyle(fontSize: 12, color: context.appMuted),
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
                  icon: Icons.event_available_rounded,
                  bg: AppColors.primarySoft,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 12),
                Text(
                  'Appointment',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: context.appText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Total',
              style: TextStyle(fontSize: 12, color: context.appMuted),
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

/// Full-width staff availability board for the tablet dashboard. Shows
/// every therapist in two readable columns instead of squeezing two rows
/// into a small card.
class _TabletStaffAvailabilityCard extends StatelessWidget {
  final List<_TherapistStatus> therapists;
  final bool isLoading;
  final VoidCallback onManageTodayQueue;

  const _TabletStaffAvailabilityCard({
    required this.therapists,
    required this.isLoading,
    required this.onManageTodayQueue,
  });

  @override
  Widget build(BuildContext context) {
    return _TabletCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _IconBox(
                    icon: Icons.groups_rounded,
                    bg: AppColors.primarySoft,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Staff Availability',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: context.appText,
                    ),
                  ),
                  if (!isLoading) ...[
                    const SizedBox(width: 14),
                    _LiveQueueHeaderMetrics(therapists: therapists),
                  ],
                  const Spacer(),
                  TextButton.icon(
                    onPressed: onManageTodayQueue,
                    icon: const Icon(Icons.tune_rounded, size: 16),
                    label: const Text("Manage today's queue"),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF1B6B72),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const TherapistAvailabilityScreen(),
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF1B6B72),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('View all'),
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
                  'No therapist is in the live queue right now',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    return _TherapistQueueGrid(
                      therapists: therapists,
                      twoColumns: constraints.maxWidth >= 680,
                    );
                  },
                ),
            ],
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
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: context.appText,
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
  final int notificationCount;
  final VoidCallback onOpenNotifications;
  final Future<void> Function() onRefreshDashboard;
  final VoidCallback onManageTodayQueue;
  final VoidCallback onOpenSettings;
  final Future<void> Function(String) onSwitchOutlet;
  final List<_DashboardMainCard> mainOrder;
  final List<_DashboardOtherCard> otherOrder;
  final _DashboardReorder onReorderMain;
  final _DashboardReorder onReorderOther;

  const _PhoneLayout({
    required this.profile,
    required this.email,
    required this.role,
    required this.isLoadingSettings,
    required this.dashboardData,
    required this.isLoadingDashboard,
    required this.dashboardError,
    required this.notificationCount,
    required this.onOpenNotifications,
    required this.onRefreshDashboard,
    required this.onManageTodayQueue,
    required this.onOpenSettings,
    required this.onSwitchOutlet,
    required this.mainOrder,
    required this.otherOrder,
    required this.onReorderMain,
    required this.onReorderOther,
  });

  Widget _buildMainCard(BuildContext context, _DashboardMainCard card) {
    final child = switch (card) {
      _DashboardMainCard.appointments => _PhoneAppointmentCard(
        role: role,
        stats: dashboardData.stats,
        isLoading: isLoadingDashboard,
        onRefreshDashboard: onRefreshDashboard,
      ),
      _DashboardMainCard.quickBook => _PhoneQuickBookCard(
        role: role,
        onRefreshDashboard: onRefreshDashboard,
      ),
      _DashboardMainCard.orders => _PhonePosCard(
        stats: dashboardData.stats,
        isLoading: isLoadingDashboard,
        onRefreshDashboard: onRefreshDashboard,
      ),
      _DashboardMainCard.members => _PhoneCustomersCard(
        stats: dashboardData.stats,
        isLoading: isLoadingDashboard,
        onRefreshDashboard: onRefreshDashboard,
      ),
    };
    return _ReorderableDashboardCard(
      group: 'phone-main',
      id: card.name,
      onReorder: onReorderMain,
      child: child,
    );
  }

  Widget _buildOtherCard(BuildContext context, _DashboardOtherCard card) {
    final child = switch (card) {
      _DashboardOtherCard.history => _PhoneOtherCard(
        icon: Icons.history_rounded,
        label: 'History',
        iconBg: AppColors.infoSoft,
        iconColor: AppColors.info,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SalesHistoryScreen(userRole: role)),
        ),
      ),
      _DashboardOtherCard.members => _PhoneOtherCard(
        icon: Icons.people_alt_rounded,
        label: 'Members',
        iconBg: AppColors.infoSoft,
        iconColor: AppColors.info,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const CustomerScreen()),
        ),
      ),
      _DashboardOtherCard.management => _PhoneOtherCard(
        icon: Icons.manage_accounts_rounded,
        label: 'Management',
        iconBg: AppColors.successSoft,
        iconColor: AppColors.success,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ManagementScreen(userRole: role)),
        ),
      ),
      _DashboardOtherCard.reports => _PhoneOtherCard(
        icon: Icons.insights_rounded,
        label: 'Reports',
        iconBg: AppColors.primarySoft,
        iconColor: AppColors.primary,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ReportsScreen(userRole: role)),
        ),
      ),
      _DashboardOtherCard.timetable => _PhoneOtherCard(
        icon: Icons.calendar_view_week_rounded,
        label: 'Timetable',
        iconBg: AppColors.accentSoft,
        iconColor: AppColors.accent,
        onTap: () async {
          await Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => TimetableScreen(userRole: role)),
          );
          await onRefreshDashboard();
        },
      ),
    };
    return _ReorderableDashboardCard(
      group: 'phone-other',
      id: card.name,
      onReorder: onReorderOther,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Top bar ──────────────────────────────────────────
          _DashboardTopBar(
            profile: profile,
            email: email,
            role: role,
            isLoadingSettings: isLoadingSettings,
            notificationCount: notificationCount,
            onOpenNotifications: onOpenNotifications,
            onOpenSettings: onOpenSettings,
            onSwitchOutlet: onSwitchOutlet,
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

                _DashboardCardGrid(
                  children: [
                    for (final card in mainOrder) _buildMainCard(context, card),
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
                _PhoneStaffStatusCard(
                  role: role,
                  therapists: dashboardData.therapists,
                  isLoading: isLoadingDashboard,
                  onManageTodayQueue: onManageTodayQueue,
                ),

                const SizedBox(height: 24),

                // ── Others section ────────────────────────────
                const _SectionLabel('Others'),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final singleColumn =
                        (context.uiScale.preset == UiScalePreset.large ||
                            MediaQuery.textScalerOf(context).scale(1) > 1.15) &&
                        constraints.maxWidth < 520;
                    return GridView.count(
                      crossAxisCount: singleColumn ? 1 : 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: singleColumn ? 4.2 : 2.2,
                      children: [
                        for (final card in otherOrder)
                          if (role == 'admin' ||
                              card != _DashboardOtherCard.reports)
                            _buildOtherCard(context, card),
                      ],
                    );
                  },
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

class _ReorderableDashboardCard extends StatelessWidget {
  final String group;
  final String id;
  final Widget child;
  final _DashboardReorder onReorder;

  const _ReorderableDashboardCard({
    required this.group,
    required this.id,
    required this.child,
    required this.onReorder,
  });

  String get _dragData => '$group:$id';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return DragTarget<String>(
          onWillAcceptWithDetails: (details) =>
              details.data.startsWith('$group:') && details.data != _dragData,
          onAcceptWithDetails: (details) {
            onReorder(details.data.substring(group.length + 1), id);
          },
          builder: (context, candidates, rejected) {
            final highlighted = candidates.isNotEmpty;
            return Stack(
              fit: StackFit.passthrough,
              children: [
                LongPressDraggable<String>(
                  data: _dragData,
                  delay: const Duration(milliseconds: 450),
                  hapticFeedbackOnStart: true,
                  feedback: Material(
                    color: Colors.transparent,
                    child: SizedBox(
                      width: constraints.maxWidth,
                      child: Opacity(opacity: 0.92, child: child),
                    ),
                  ),
                  childWhenDragging: Opacity(opacity: 0.25, child: child),
                  child: child,
                ),
                if (highlighted)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _DashboardCardGrid extends StatelessWidget {
  final List<Widget> children;

  const _DashboardCardGrid({required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stack =
            (context.uiScale.preset == UiScalePreset.large ||
                MediaQuery.textScalerOf(context).scale(1) > 1.15) &&
            constraints.maxWidth < 520;
        if (stack) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < children.length; index++) ...[
                if (index > 0) const SizedBox(height: 12),
                children[index],
              ],
            ],
          );
        }
        return Column(
          children: [
            for (var index = 0; index < children.length; index += 2) ...[
              if (index > 0) const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: children[index]),
                  const SizedBox(width: 12),
                  Expanded(
                    child: index + 1 < children.length
                        ? children[index + 1]
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ],
          ],
        );
      },
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
                  icon: Icons.event_available_rounded,
                  bg: AppColors.primarySoft,
                  color: AppColors.primary,
                  size: 32,
                ),
                const SizedBox(width: 8),
                Text(
                  'Appointments',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: context.appText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Total Today',
              style: TextStyle(fontSize: 11, color: context.appMuted),
            ),
            const SizedBox(height: 4),
            Text(
              isLoading ? '-' : '${stats.todayAppointments}',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: context.appText,
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
          color: AppColors.primary,
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
              child: const Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Quick Book',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
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
                  icon: Icons.point_of_sale_rounded,
                  bg: AppColors.accentSoft,
                  color: AppColors.accent,
                  size: 32,
                ),
                const SizedBox(width: 8),
                Text(
                  'Order',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: context.appText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Sales Collected',
              style: TextStyle(fontSize: 11, color: context.appMuted),
            ),
            const SizedBox(height: 4),
            Text(
              isLoading ? '-' : 'RM ${stats.todaySales.toStringAsFixed(0)}',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: context.appText,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isLoading ? 'Loading' : '${stats.totalTransactions} transactions',
              style: TextStyle(fontSize: 11, color: context.appMuted),
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
                  icon: Icons.people_alt_rounded,
                  bg: AppColors.infoSoft,
                  color: AppColors.info,
                  size: 32,
                ),
                const SizedBox(width: 8),
                Text(
                  'Members',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: context.appText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Total',
              style: TextStyle(fontSize: 11, color: context.appMuted),
            ),
            const SizedBox(height: 4),
            Text(
              isLoading ? '-' : '${stats.totalCustomers}',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: context.appText,
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
                icon: Icons.analytics_rounded,
                bg: AppColors.primarySoft,
                color: AppColors.primary,
                size: 32,
              ),
              const SizedBox(width: 10),
              Text(
                'Revenue Summary',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: context.appText,
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
  final VoidCallback onManageTodayQueue;

  const _PhoneStaffStatusCard({
    required this.role,
    required this.therapists,
    required this.isLoading,
    required this.onManageTodayQueue,
  });

  @override
  Widget build(BuildContext context) {
    return _PhoneCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _IconBox(
                icon: Icons.groups_rounded,
                bg: AppColors.primarySoft,
                color: AppColors.primary,
                size: 32,
              ),
              const SizedBox(width: 8),
              Text(
                'Staff Today',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: context.appText,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: "Manage today's queue",
                onPressed: onManageTodayQueue,
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.tune_rounded,
                  size: 19,
                  color: Color(0xFF1B6B72),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const TherapistAvailabilityScreen(),
                  ),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: const Color(0xFF1B6B72),
                ),
                child: const Text('View all'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _LiveTherapistQueueSummary(therapists: therapists, compact: true),
          const SizedBox(height: 10),
          if (isLoading)
            const Text(
              'Loading staff status',
              style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
            )
          else if (therapists.isEmpty)
            const Text(
              'No therapist is in the live queue right now',
              style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
            )
          else
            _TherapistQueueGrid(therapists: therapists, twoColumns: false),
        ],
      ),
    );
  }
}

class _TodayQueueManagementDialog extends StatefulWidget {
  const _TodayQueueManagementDialog({required this.outletId});

  final String outletId;

  @override
  State<_TodayQueueManagementDialog> createState() =>
      _TodayQueueManagementDialogState();
}

class _TodayQueueManagementDialogState
    extends State<_TodayQueueManagementDialog> {
  TodayQueueManagement? _queue;
  bool _loading = true;
  bool _saving = false;
  bool _changed = false;
  String? _error;

  String get _today => DateFormat('yyyy-MM-dd').format(DateTime.now());
  String get _nowTime => DateFormat('HH:mm:ss').format(DateTime.now());

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final queue = await CspService.getTodayQueueManagement(
        outletId: widget.outletId,
        date: _today,
        nowTime: _nowTime,
      );
      if (!mounted) return;
      setState(() {
        _queue = queue;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _runChange(Future<void> Function() action) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await action();
      _changed = true;
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changeStarter() async {
    final queue = _queue;
    if (queue == null || queue.liveQueue.isEmpty) return;
    final reasonController = TextEditingController();
    var selectedId = queue.starter?.therapistId ?? '';
    final request = await showDialog<_StarterQueueRequest>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text("Change today's starter"),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Choose from therapists who are active, scheduled and currently on shift.',
                    style: TextStyle(color: Color(0xFF64748B), height: 1.4),
                  ),
                  if (queue.requiresResetWarning) ...[
                    const SizedBox(height: 14),
                    const _QueueResetWarning(),
                  ],
                  const SizedBox(height: 14),
                  for (final therapist in queue.liveQueue) ...[
                    _QueueChoiceTile(
                      therapist: therapist,
                      selected: therapist.therapistId == selectedId,
                      onTap: () => setDialogState(
                        () => selectedId = therapist.therapistId,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  const SizedBox(height: 6),
                  TextField(
                    controller: reasonController,
                    maxLength: 500,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Reason (optional)',
                      hintText: 'Why is today starting differently?',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: selectedId.isEmpty
                  ? null
                  : () => Navigator.pop(
                      dialogContext,
                      _StarterQueueRequest(
                        therapistId: selectedId,
                        reason: reasonController.text,
                        confirmReset: queue.requiresResetWarning,
                      ),
                    ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1B6B72),
              ),
              child: Text(
                queue.requiresResetWarning
                    ? 'Reset and change starter'
                    : 'Change starter',
              ),
            ),
          ],
        ),
      ),
    );
    reasonController.dispose();
    if (request == null) return;
    await _runChange(
      () => CspService.changeTodayQueueStarter(
        outletId: widget.outletId,
        date: _today,
        therapistId: request.therapistId,
        reason: request.reason,
        confirmReset: request.confirmReset,
      ),
    );
  }

  Future<void> _reorderQueue() async {
    final queue = _queue;
    if (queue == null || queue.liveQueue.length < 2) return;
    final reordered = [...queue.liveQueue];
    final request = await showDialog<_ReorderQueueRequest>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Reorder current live queue'),
          content: SizedBox(
            width: 520,
            height: 470,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Drag the currently on-shift therapists into the order the counter should follow.',
                  style: TextStyle(color: Color(0xFF64748B), height: 1.4),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: reordered.length,
                    onReorderItem: (oldIndex, newIndex) {
                      setDialogState(() {
                        final moved = reordered.removeAt(oldIndex);
                        reordered.insert(newIndex, moved);
                      });
                    },
                    itemBuilder: (context, index) {
                      final therapist = reordered[index];
                      return Padding(
                        key: ValueKey(therapist.therapistId),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _QueueReorderTile(
                          therapist: therapist,
                          dragHandle: ReorderableDragStartListener(
                            index: index,
                            child: const Padding(
                              padding: EdgeInsets.all(10),
                              child: Icon(
                                Icons.drag_indicator_rounded,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                _ReorderQueueRequest(
                  therapistIds: [
                    for (final therapist in reordered)
                      therapist.therapistId,
                  ],
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1B6B72),
              ),
              child: const Text('Save live order'),
            ),
          ],
        ),
      ),
    );
    if (request == null) return;
    await _runChange(
      () => CspService.reorderCurrentTherapistQueue(
        outletId: widget.outletId,
        date: _today,
        therapistIds: request.therapistIds,
      ),
    );
  }

  Future<void> _resetAutomatic() async {
    final queue = _queue;
    if (queue == null) return;
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset to automatic starter?'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Today's starter will be recalculated from the previous operating day's stored starter.",
                style: TextStyle(color: Color(0xFF64748B), height: 1.4),
              ),
              if (queue.requiresResetWarning) ...[
                const SizedBox(height: 14),
                const _QueueResetWarning(),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: reasonController,
                maxLength: 500,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1B6B72),
            ),
            child: Text(
              queue.requiresResetWarning
                  ? 'Reset live order'
                  : 'Reset to automatic',
            ),
          ),
        ],
      ),
    );
    final reason = reasonController.text;
    reasonController.dispose();
    if (confirmed != true) return;
    await _runChange(
      () => CspService.resetTodayQueueToAutomatic(
        outletId: widget.outletId,
        date: _today,
        reason: reason,
        confirmReset: queue.requiresResetWarning,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: Color(0xFFE8F5F5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.tune_rounded,
                      color: Color(0xFF1B6B72),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Manage today's queue",
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _saving
                        ? null
                        : () => Navigator.pop(context, _changed),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (_loading)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (queue == null)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text("Unable to load today's queue."),
                        const SizedBox(height: 10),
                        OutlinedButton(
                          onPressed: _load,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _TodayQueueOverview(queue: queue),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          _QueueDialogError(message: _error!),
                        ],
                        const SizedBox(height: 18),
                        _QueueManagementAction(
                          icon: Icons.person_pin_circle_outlined,
                          title: "Change today's starter",
                          subtitle:
                              'Choose a different scheduled, on-shift therapist.',
                          onTap: _saving ? null : _changeStarter,
                        ),
                        const SizedBox(height: 10),
                        _QueueManagementAction(
                          icon: Icons.swap_vert_rounded,
                          title: 'Reorder current live queue',
                          subtitle:
                              'Drag the visible live queue into a new today-only order.',
                          onTap: _saving || queue.liveQueue.length < 2
                              ? null
                              : _reorderQueue,
                        ),
                        const SizedBox(height: 10),
                        _QueueManagementAction(
                          icon: Icons.restart_alt_rounded,
                          title: 'Reset',
                          subtitle:
                              "Reset to use the original numbered order queue.",
                          onTap: _saving ? null : _resetAutomatic,
                        ),
                        if (_saving) ...[
                          const SizedBox(height: 16),
                          const LinearProgressIndicator(minHeight: 2),
                        ],
                      ],
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

class _StarterQueueRequest {
  const _StarterQueueRequest({
    required this.therapistId,
    required this.reason,
    required this.confirmReset,
  });

  final String therapistId;
  final String reason;
  final bool confirmReset;
}

class _ReorderQueueRequest {
  const _ReorderQueueRequest({required this.therapistIds});

  final List<String> therapistIds;
}

class _TodayQueueOverview extends StatelessWidget {
  const _TodayQueueOverview({required this.queue});

  final TodayQueueManagement queue;

  @override
  Widget build(BuildContext context) {
    final changedAt = queue.changedAt?.toLocal();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.appSurfaceRaised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.appBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 20,
            runSpacing: 14,
            children: [
              _QueueOverviewPerson(
                label: 'Stored starter',
                therapist: queue.starter,
              ),
              _QueueOverviewPerson(
                label: 'Current live Next',
                therapist: queue.currentNext,
                showNext: true,
              ),
              _QueueOverviewStatus(
                isManual: queue.isManualOverride,
                changedAt: changedAt,
              ),
            ],
          ),
          if ((queue.reason ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Reason: ${queue.reason!.trim()}',
              style: TextStyle(
                fontSize: 11.5,
                color: context.appMuted,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _QueueOverviewPerson extends StatelessWidget {
  const _QueueOverviewPerson({
    required this.label,
    required this.therapist,
    this.showNext = false,
  });

  final String label;
  final TodayQueueTherapist? therapist;
  final bool showNext;

  @override
  Widget build(BuildContext context) {
    final person = therapist;
    return SizedBox(
      width: 190,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 10.5, color: context.appMuted),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              _TodayQueueAvatar(therapist: person, size: 34),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  person?.name ?? 'Not set',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: context.appText,
                  ),
                ),
              ),
              if (showNext && person != null)
                const Padding(
                  padding: EdgeInsets.only(left: 5),
                  child: Icon(
                    Icons.auto_awesome,
                    size: 15,
                    color: Color(0xFF1B6B72),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QueueOverviewStatus extends StatelessWidget {
  const _QueueOverviewStatus({
    required this.isManual,
    required this.changedAt,
  });

  final bool isManual;
  final DateTime? changedAt;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 190,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Starter source',
            style: TextStyle(fontSize: 10.5, color: context.appMuted),
          ),
          const SizedBox(height: 7),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: isManual
                  ? const Color(0xFFFFF7ED)
                  : const Color(0xFFECFDF3),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              isManual ? 'Manual override' : 'Automatic',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: isManual
                    ? const Color(0xFFB45309)
                    : const Color(0xFF15803D),
              ),
            ),
          ),
          if (changedAt != null) ...[
            const SizedBox(height: 5),
            Text(
              'Changed ${DateFormat('h:mm a').format(changedAt!)}',
              style: TextStyle(fontSize: 10, color: context.appMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _QueueManagementAction extends StatelessWidget {
  const _QueueManagementAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.appSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: context.appBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: const Color(0xFF1B6B72), size: 21),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: context.appText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: context.appMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: Color(0xFF94A3B8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueueChoiceTile extends StatelessWidget {
  const _QueueChoiceTile({
    required this.therapist,
    required this.selected,
    required this.onTap,
  });

  final TodayQueueTherapist therapist;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFFE8F5F5) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: BorderSide(
          color: selected
              ? const Color(0xFF1B6B72)
              : const Color(0xFFE2E8F0),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              _TodayQueueAvatar(therapist: therapist, size: 38),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  therapist.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected
                    ? const Color(0xFF1B6B72)
                    : const Color(0xFFCBD5E1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueueReorderTile extends StatelessWidget {
  const _QueueReorderTile({
    required this.therapist,
    required this.dragHandle,
  });

  final TodayQueueTherapist therapist;
  final Widget dragHandle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        color: context.appSurface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: context.appBorder),
      ),
      child: Row(
        children: [
          _TodayQueueAvatar(therapist: therapist, size: 38),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              therapist.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          dragHandle,
        ],
      ),
    );
  }
}

class _TodayQueueAvatar extends StatelessWidget {
  const _TodayQueueAvatar({required this.therapist, required this.size});

  final TodayQueueTherapist? therapist;
  final double size;

  @override
  Widget build(BuildContext context) {
    final person = therapist;
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Color(0xFFE8F5F5),
        shape: BoxShape.circle,
      ),
      child: Text(
        staffInitials(person?.name ?? '?'),
        style: TextStyle(
          fontSize: size * 0.3,
          fontWeight: FontWeight.w800,
          color: const Color(0xFF1B6B72),
        ),
      ),
    );
    final imageUrl = person?.profileImageUrl.trim() ?? '';
    if (imageUrl.isEmpty) return fallback;
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: imageUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

class _QueueResetWarning extends StatelessWidget {
  const _QueueResetWarning();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFDBA74)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 19),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              "Today's queue has already rotated. This action will reset the current live order for the rest of today.",
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: Color(0xFF9A3412),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueDialogError extends StatelessWidget {
  const _QueueDialogError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Text(
        message.contains('RESET_CONFIRMATION_REQUIRED')
            ? "Today's queue has already rotated. Confirm the reset before continuing."
            : 'Unable to update the live queue. Refresh and try again.',
        style: const TextStyle(fontSize: 11.5, color: Color(0xFFB91C1C)),
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
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: context.appText,
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
  final bool isAdmin;
  final Future<void> Function(String) onSwitchOutlet;

  const _BusinessProfileDialog({
    required this.profile,
    required this.email,
    required this.isAdmin,
    required this.onSwitchOutlet,
  });

  Future<void> _chooseOutlet(BuildContext context) async {
    if (!isAdmin) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Switch outlet'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: OutletContext.outlets
              .map(
                (outlet) => ListTile(
                  leading: Icon(
                    outlet.id == profile.outletId
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: const Color(0xFFF59E0B),
                  ),
                  title: Text(outlet.name),
                  subtitle: Text(
                    outlet == OutletContext.pv128
                        ? 'G13-A, PV128, Jalan Genting Kelang'
                        : '50G, Jalan Seri Utara 1, Taman Wahyu',
                  ),
                  onTap: () => Navigator.of(dialogContext).pop(outlet.id),
                ),
              )
              .toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (selected == null || selected == profile.outletId || !context.mounted) {
      return;
    }
    Navigator.of(context).pop();
    await onSwitchOutlet(selected);
  }

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
              _BusinessLogoAvatar(profile: profile, size: 82, circular: true),
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
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: isAdmin ? () => _chooseOutlet(context) : null,
                  borderRadius: BorderRadius.circular(14),
                  child: _BusinessProfileRow(
                    icon: Icons.storefront_outlined,
                    iconBg: const Color(0xFFFFF3D6),
                    iconColor: const Color(0xFFF59E0B),
                    label: 'Outlet',
                    value: profile.location.toUpperCase(),
                    showChevron: isAdmin,
                  ),
                ),
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
        color: context.appSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.appBorder),
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
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: context.appText,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 14,
                color: context.appMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (showChevron) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: context.appMuted),
          ],
        ],
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  final String role;
  final bool isLoading;

  const _RolePill({required this.role, this.isLoading = false});

  @override
  Widget build(BuildContext context) {
    final isAdmin = role == 'admin';
    final label = isLoading
        ? '...'
        : isAdmin
        ? 'Admin'
        : 'Staff';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isAdmin ? AppColors.accentSoft : AppColors.primarySoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: isAdmin ? AppColors.accent : AppColors.primary,
        ),
      ),
    );
  }
}

class _NotificationDialog extends StatefulWidget {
  final NotificationRepository repository;
  final List<AppNotification> startingSoon;
  final Future<void> Function(AppNotification) onOpenTarget;

  const _NotificationDialog({
    required this.repository,
    required this.startingSoon,
    required this.onOpenTarget,
  });

  @override
  State<_NotificationDialog> createState() => _NotificationDialogState();
}

class _NotificationDialogState extends State<_NotificationDialog> {
  static const _pageSize = 30;

  List<AppNotification> _items = [];
  bool _loading = true;
  bool _hasMore = false;
  int _limit = _pageSize;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await widget.repository.getNotifications(limit: _limit);
      if (!mounted) return;
      setState(() {
        _items = items;
        _hasMore = items.length >= _limit;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadMore() async {
    _limit += _pageSize;
    await _load();
  }

  Future<void> _markAllRead() async {
    try {
      await widget.repository.markAllRead();
    } catch (_) {}
    await _load();
  }

  Future<void> _openTarget(AppNotification notification) async {
    if (!notification.hasOpenableTarget) {
      await widget.repository.markRead(notification.id);
      await _load();
      return;
    }
    Navigator.of(context).pop();
    await widget.onOpenTarget(notification);
  }

  @override
  Widget build(BuildContext context) {
    final feed = [...widget.startingSoon, ..._items];
    final feedRows = _notificationFeedRows(feed);
    final unread = _items.where((n) => n.isUnread).length;

    final screen = MediaQuery.of(context).size;
    final isPhone = screen.width < 520;
    final availableHeight = screen.height - (isPhone ? 32 : 48);
    final dialogHeight = availableHeight
        .clamp(360.0, isPhone ? 620.0 : 560.0)
        .toDouble();

    return Dialog(
      insetPadding: isPhone
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 16)
          : const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SizedBox(
        width: 620,
        height: dialogHeight,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            isPhone ? 12 : 18,
            14,
            isPhone ? 12 : 18,
            20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFFE0F3F1),
                    ),
                    child: const Icon(
                      Icons.notifications_none_outlined,
                      color: Color(0xFF1B6B72),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Notifications',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                            color: context.appText,
                          ),
                        ),
                        Text(
                          unread > 0 ? '$unread unread' : 'All caught up',
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF9E9E9E),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (unread > 0)
                    TextButton(
                      onPressed: _markAllRead,
                      child: const Text(
                        'Mark all read',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    color: const Color(0xFF9E9E9E),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: _loading && _items.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _error != null && feed.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'Unable to load notifications: $_error',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFFB45309),
                          ),
                        ),
                      )
                    : feed.isEmpty
                    ? const _NotificationEmptyState()
                    : ScrollConfiguration(
                        behavior: const _NoScrollbarScrollBehavior(),
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: feedRows.length + (_hasMore ? 1 : 0),
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            if (index >= feedRows.length) {
                              return Center(
                                child: TextButton(
                                  onPressed: _loading ? null : _loadMore,
                                  child: Text(
                                    _loading
                                        ? 'Loading...'
                                        : 'View older notifications',
                                    style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              );
                            }
                            final row = feedRows[index];
                            final notification = row.notification;
                            if (notification == null) {
                              return _NotificationSectionLabel(
                                label: row.sectionLabel!,
                              );
                            }
                            return _NotificationTile(
                              notification: notification,
                              onTap: () => _openTarget(notification),
                            );
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

class _NotificationFeedRow {
  final String? sectionLabel;
  final AppNotification? notification;

  const _NotificationFeedRow.section(this.sectionLabel) : notification = null;

  const _NotificationFeedRow.item(this.notification) : sectionLabel = null;
}

List<_NotificationFeedRow> _notificationFeedRows(
  List<AppNotification> notifications,
) {
  final rows = <_NotificationFeedRow>[];
  String? currentSection;
  for (final notification in notifications) {
    final section = _notificationSectionFor(notification.createdAt);
    if (section != currentSection) {
      currentSection = section;
      rows.add(_NotificationFeedRow.section(section));
    }
    rows.add(_NotificationFeedRow.item(notification));
  }
  return rows;
}

String _notificationSectionFor(DateTime value) {
  final date = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(date.year, date.month, date.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) return 'Today';
  if (difference == 1) return 'Yesterday';
  return DateFormat('EEEE, d MMMM').format(date);
}

IconData _notificationIconFor(String type) => switch (type) {
  'new_online_appointment' => Icons.event_available_outlined,
  'online_payment_received' || 'payment_received' => Icons.payments_outlined,
  'appointment_checked_in' => Icons.login_rounded,
  'payment_failed' => Icons.error_outline,
  'payment_expired' => Icons.timer_off_outlined,
  'appointment_cancelled' => Icons.event_busy_outlined,
  'appointment_voided' => Icons.block_outlined,
  'refund_completed' => Icons.undo_outlined,
  'transaction_review' => Icons.rate_review_outlined,
  AppNotification.startingSoonType => Icons.schedule_outlined,
  _ => Icons.notifications_none_outlined,
};

Color _notificationAccentFor(String type) => switch (type) {
  'payment_failed' ||
  'payment_expired' ||
  'appointment_cancelled' ||
  'appointment_voided' => const Color(0xFFC62828),
  'transaction_review' || 'refund_completed' => const Color(0xFFB45309),
  'online_payment_received' || 'payment_received' => const Color(0xFF15803D),
  'appointment_checked_in' => const Color(0xFF2563EB),
  AppNotification.startingSoonType => const Color(0xFF7C3AED),
  _ => const Color(0xFF1B6B72),
};

class _NotificationSectionLabel extends StatelessWidget {
  final String label;

  const _NotificationSectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 2),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: context.appMuted,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final AppNotification notification;
  final VoidCallback? onTap;

  const _NotificationTile({required this.notification, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = _notificationAccentFor(notification.type);
    final timeLabel = DateFormat(
      'd MMM, h:mm a',
    ).format(notification.createdAt);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: notification.isUnread
              ? Color.alphaBlend(
                  accent.withValues(alpha: 0.08),
                  context.appSurfaceRaised,
                )
              : context.appSurfaceRaised,
          border: Border.all(
            color: notification.isUnread
                ? accent.withValues(alpha: 0.35)
                : context.appBorder,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: 0.12),
              ),
              child: Icon(
                _notificationIconFor(notification.type),
                size: 20,
                color: accent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          notification.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: notification.isUnread
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: context.appText,
                          ),
                        ),
                      ),
                      if (notification.isUnread)
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(left: 8, top: 4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: accent,
                          ),
                        ),
                    ],
                  ),
                  if (notification.body.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      notification.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: context.appMuted),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    notification.type == AppNotification.startingSoonType
                        ? 'Now'
                        : timeLabel,
                    style: TextStyle(fontSize: 12, color: context.appMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            if (notification.hasOpenableTarget)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Color(0xFF9E9E9E),
                ),
              ),
          ],
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
        color: context.appSurfaceRaised,
        border: Border.all(color: context.appBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        'Online bookings, payments, cancellations, and refunds will appear here.',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          color: context.appMuted,
          fontWeight: FontWeight.w600,
        ),
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
  final _imageUploadRepository = ImageUploadRepository();
  final _hoursRepository = BusinessHoursRepository();
  late final TextEditingController _nameController;
  late final TextEditingController _locationController;
  SelectedImage? _logoPreview;
  bool _logoRemoved = false;
  bool _hoursLoading = true;
  bool _hoursSaving = false;
  final Set<int> _dirtyHourDays = <int>{};
  bool _hoursExpanded = false;
  String? _hoursError;
  List<BusinessDayHours> _week = List.generate(7, BusinessDayHours.fallback);

  static const _dayNames = [
    'Sunday',
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
  ];
  static const _displayOrder = [1, 2, 3, 4, 5, 6, 0];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.name);
    _locationController = TextEditingController(text: widget.profile.location);
    unawaited(_loadHours());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _pickLogo() async {
    if (!widget.isAdmin) return;
    try {
      final image = await _imageUploadRepository.pickImage();
      if (image == null || !mounted) return;
      setState(() {
        _logoPreview = image;
        _logoRemoved = false;
      });
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, e.toString());
    }
  }

  void _removeLogo() {
    if (!widget.isAdmin) return;
    setState(() {
      _logoPreview = null;
      _logoRemoved = true;
    });
  }

  Future<void> _loadHours() async {
    if (mounted) {
      setState(() {
        _hoursLoading = true;
        _hoursError = null;
      });
    }
    try {
      final week = await _hoursRepository.listWeek();
      if (!mounted) return;
      setState(() {
        _week = week;
        _dirtyHourDays.clear();
        _hoursLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _hoursError = error.toString();
        _hoursLoading = false;
      });
    }
  }

  String _hoursLabel(BusinessDayHours day) {
    if (day.isClosed) return 'Closed';
    final open = _parseHoursTime(day.openTime).format(context);
    final close = _parseHoursTime(day.closeTime).format(context);
    return '$open – $close${day.isOvernight ? ' (+1)' : ''}';
  }

  String get _weekHoursSummary {
    if (_hoursLoading) return 'Loading weekly hours…';
    if (_hoursError != null) return 'Opening hours unavailable';
    final groups = <String>[];
    var runStart = 0;
    for (var index = 1; index <= _displayOrder.length; index++) {
      final same =
          index < _displayOrder.length &&
          _week[_displayOrder[index]].sameHoursAs(
            _week[_displayOrder[runStart]],
          );
      if (same) continue;
      final firstDay = _displayOrder[runStart];
      final lastDay = _displayOrder[index - 1];
      final label = firstDay == lastDay
          ? _dayNames[firstDay].substring(0, 3)
          : '${_dayNames[firstDay].substring(0, 3)}–'
                '${_dayNames[lastDay].substring(0, 3)}';
      groups.add('$label ${_hoursLabel(_week[firstDay])}');
      runStart = index;
    }
    return groups.join(' · ');
  }

  TimeOfDay _parseHoursTime(String value) {
    final parts = value.split(':');
    return TimeOfDay(
      hour: int.tryParse(parts.first) ?? 9,
      minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
    );
  }

  Future<void> _editHours(int dayOfWeek) async {
    if (!widget.isAdmin || _hoursSaving) return;
    final result = await showDialog<BusinessDayHours>(
      context: context,
      builder: (_) => _DashboardDayHoursDialog(
        title: _dayNames[dayOfWeek],
        initial: _week[dayOfWeek],
      ),
    );
    if (result == null) return;
    setState(() {
      _week = List<BusinessDayHours>.of(_week)..[dayOfWeek] = result;
      _dirtyHourDays.add(dayOfWeek);
    });
  }

  Future<void> _setAllHours() async {
    if (!widget.isAdmin || _hoursSaving) return;
    final result = await showDialog<BusinessDayHours>(
      context: context,
      builder: (_) => _DashboardDayHoursDialog(
        title: 'All days',
        initial: _week[_displayOrder.first],
        confirmLabel: 'Set all days',
        helperText: 'This replaces the schedule for every day of the week.',
      ),
    );
    if (result == null) return;
    setState(() {
      _week = [
        for (final day in _week)
          day.copyWith(
            openTime: result.openTime,
            closeTime: result.closeTime,
            isClosed: result.isClosed,
          ),
      ];
      _dirtyHourDays
        ..clear()
        ..addAll(List<int>.generate(7, (day) => day));
    });
  }

  Future<bool> _saveHours() async {
    if (_dirtyHourDays.isEmpty) return true;
    setState(() => _hoursSaving = true);
    try {
      await _hoursRepository.saveWeek([
        for (final day in _week)
          if (_dirtyHourDays.contains(day.dayOfWeek)) day,
      ]);
      final week = await _hoursRepository.listWeek();
      if (!mounted) return false;
      setState(() {
        _week = week;
        _dirtyHourDays.clear();
      });
      return true;
    } catch (error) {
      if (!mounted) return false;
      AppToast.error(context, 'Unable to save opening hours: $error');
      return false;
    } finally {
      if (mounted) setState(() => _hoursSaving = false);
    }
  }

  Future<void> _save() async {
    if (!widget.isAdmin || _hoursSaving) return;
    if (!await _saveHours() || !mounted) return;

    Navigator.of(context).pop(
      widget.profile.copyWith(
        name: _nameController.text.trim(),
        location: _locationController.text.trim(),
        logoUrl: _logoRemoved ? '' : widget.profile.logoUrl,
        logoUpload: _logoPreview,
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
      AppToast.error(context, e.message);
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
                          'Only admins can edit business details and opening hours.',
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
                    _DashboardBusinessHoursEditor(
                      week: _week,
                      loading: _hoursLoading,
                      saving: _hoursSaving,
                      expanded: _hoursExpanded,
                      summary: _weekHoursSummary,
                      error: _hoursError,
                      isAdmin: widget.isAdmin,
                      dayNames: _dayNames,
                      displayOrder: _displayOrder,
                      hoursLabel: _hoursLabel,
                      onEdit: _editHours,
                      onSetAll: _setAllHours,
                      onRetry: _loadHours,
                      onToggle: () =>
                          setState(() => _hoursExpanded = !_hoursExpanded),
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
                        _BusinessLogoAvatar(
                          profile: widget.profile.copyWith(
                            logoUrl: _logoRemoved ? '' : widget.profile.logoUrl,
                          ),
                          preview: _logoPreview,
                          size: 80,
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              OutlinedButton.icon(
                                onPressed: widget.isAdmin ? _pickLogo : null,
                                icon: const Icon(Icons.upload_outlined),
                                label: Text(
                                  _logoPreview == null &&
                                          widget.profile.logoUrl.trim().isEmpty
                                      ? 'Upload Logo'
                                      : 'Replace Logo',
                                ),
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size.fromHeight(58),
                                  foregroundColor: const Color(0xFF5F6B7A),
                                  side: const BorderSide(
                                    color: Color(0xFFE0E0E0),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  textStyle: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextButton.icon(
                                onPressed:
                                    widget.isAdmin &&
                                        (_logoPreview != null ||
                                            widget.profile.logoUrl
                                                .trim()
                                                .isNotEmpty) &&
                                        !_logoRemoved
                                    ? _removeLogo
                                    : null,
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('Remove Logo'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '',
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
                      onPressed: widget.isAdmin && !_hoursSaving ? _save : null,
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
                      child: _hoursSaving
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Save Changes'),
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

class _DashboardBusinessHoursEditor extends StatelessWidget {
  const _DashboardBusinessHoursEditor({
    required this.week,
    required this.loading,
    required this.saving,
    required this.expanded,
    required this.summary,
    required this.error,
    required this.isAdmin,
    required this.dayNames,
    required this.displayOrder,
    required this.hoursLabel,
    required this.onEdit,
    required this.onSetAll,
    required this.onRetry,
    required this.onToggle,
  });

  final List<BusinessDayHours> week;
  final bool loading;
  final bool saving;
  final bool expanded;
  final String summary;
  final String? error;
  final bool isAdmin;
  final List<String> dayNames;
  final List<int> displayOrder;
  final String Function(BusinessDayHours day) hoursLabel;
  final ValueChanged<int> onEdit;
  final VoidCallback onSetAll;
  final VoidCallback onRetry;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    const border = Color(0xFFE0E0E0);
    const muted = Color(0xFF5F6B7A);
    const ink = Color(0xFF1A1A2E);
    const accent = Color(0xFF1B6B72);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Opening Hours',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: muted,
          ),
        ),
        const SizedBox(height: 10),
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
              decoration: BoxDecoration(
                color: const Color(0xFFF6F7F8),
                border: Border.all(color: border),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(Icons.schedule_outlined, color: accent),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      summary,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(Icons.expand_more, color: muted),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !expanded
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: error != null
                      ? Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF6F7F8),
                            border: Border.all(color: border),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline, color: muted),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'Opening hours could not be loaded.',
                                  style: TextStyle(color: muted, fontSize: 13),
                                ),
                              ),
                              TextButton(
                                onPressed: loading ? null : onRetry,
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        )
                      : loading
                      ? const Padding(
                          padding: EdgeInsets.all(18),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: isAdmin && !saving ? onSetAll : null,
                                icon: const Icon(
                                  Icons.copy_all_outlined,
                                  size: 17,
                                ),
                                label: const Text('Set all days'),
                              ),
                            ),
                            Container(
                              decoration: BoxDecoration(
                                border: Border.all(color: border),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                children: [
                                  for (
                                    var index = 0;
                                    index < displayOrder.length;
                                    index++
                                  )
                                    _DashboardBusinessHoursRow(
                                      day: dayNames[displayOrder[index]],
                                      hours: hoursLabel(
                                        week[displayOrder[index]],
                                      ),
                                      closed:
                                          week[displayOrder[index]].isClosed,
                                      isLast: index == displayOrder.length - 1,
                                      onEdit: isAdmin && !saving
                                          ? () => onEdit(displayOrder[index])
                                          : null,
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Hours are saved with Save Changes. Private '
                              'custom staff hours remain unchanged.',
                              style: TextStyle(fontSize: 12, color: muted),
                            ),
                          ],
                        ),
                ),
        ),
      ],
    );
  }
}

class _DashboardBusinessHoursRow extends StatelessWidget {
  const _DashboardBusinessHoursRow({
    required this.day,
    required this.hours,
    required this.closed,
    required this.isLast,
    required this.onEdit,
  });

  final String day;
  final String hours;
  final bool closed;
  final bool isLast;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(13, 7, 5, 7),
    decoration: BoxDecoration(
      border: isLast
          ? null
          : const Border(bottom: BorderSide(color: Color(0xFFE6E8EB))),
    ),
    child: Row(
      children: [
        SizedBox(
          width: 86,
          child: Text(
            day,
            style: const TextStyle(
              color: Color(0xFF1A1A2E),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(
            hours,
            style: TextStyle(
              color: closed ? const Color(0xFF7A8492) : const Color(0xFF1A1A2E),
              fontSize: 13,
              fontStyle: closed ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ),
        IconButton(
          onPressed: onEdit,
          tooltip: 'Edit $day',
          icon: const Icon(Icons.edit_outlined, size: 18),
          color: const Color(0xFF1B6B72),
        ),
      ],
    ),
  );
}

class _DashboardDayHoursDialog extends StatefulWidget {
  const _DashboardDayHoursDialog({
    required this.title,
    required this.initial,
    this.confirmLabel = 'Save',
    this.helperText,
  });

  final String title;
  final BusinessDayHours initial;
  final String confirmLabel;
  final String? helperText;

  @override
  State<_DashboardDayHoursDialog> createState() =>
      _DashboardDayHoursDialogState();
}

class _DashboardDayHoursDialogState extends State<_DashboardDayHoursDialog> {
  late TimeOfDay _open = _parse(widget.initial.openTime);
  late TimeOfDay _close = _parse(widget.initial.closeTime);
  late bool _closed = widget.initial.isClosed;

  static TimeOfDay _parse(String value) {
    final parts = value.split(':');
    return TimeOfDay(
      hour: int.tryParse(parts.first) ?? 9,
      minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
    );
  }

  static String _storage(TimeOfDay time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  Future<void> _pick({required bool opening}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: opening ? _open : _close,
    );
    if (picked == null) return;
    setState(() {
      if (opening) {
        _open = picked;
      } else {
        _close = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final overnight =
        _close.hour * 60 + _close.minute <= _open.hour * 60 + _open.minute;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.helperText != null) ...[
            Text(
              widget.helperText!,
              style: const TextStyle(color: Color(0xFF5F6B7A), fontSize: 12),
            ),
            const SizedBox(height: 8),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Closed'),
            subtitle: const Text('No staff or customer bookings can be taken'),
            value: _closed,
            onChanged: (value) => setState(() => _closed = value),
          ),
          if (!_closed) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _DashboardHoursTimeField(
                    label: 'Opens',
                    time: _open,
                    onTap: () => _pick(opening: true),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DashboardHoursTimeField(
                    label: 'Closes',
                    time: _close,
                    onTap: () => _pick(opening: false),
                  ),
                ),
              ],
            ),
            if (overnight) ...[
              const SizedBox(height: 8),
              const Text(
                'Closes after midnight, on the following day.',
                style: TextStyle(color: Color(0xFF5F6B7A), fontSize: 12),
              ),
            ],
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            widget.initial.copyWith(
              openTime: _storage(_open),
              closeTime: _storage(_close),
              isClosed: _closed,
            ),
          ),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _DashboardHoursTimeField extends StatelessWidget {
  const _DashboardHoursTimeField({
    required this.label,
    required this.time,
    required this.onTap,
  });

  final String label;
  final TimeOfDay time;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(
        time.format(context),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
  );
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
    return Row(
      children: [
        Container(
          width: 4,
          height: 19,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.15,
            color: context.appText,
          ),
        ),
      ],
    );
  }
}

class _TabletCard extends StatelessWidget {
  final Widget child;
  const _TabletCard({required this.child});

  @override
  Widget build(BuildContext context) {
    final metrics = context.uiScale;
    return Container(
      padding: EdgeInsets.all(metrics.cardPadding + 4),
      decoration: BoxDecoration(
        color: context.appSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.appBorder),
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
    final metrics = context.uiScale;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(metrics.cardPadding),
      decoration: BoxDecoration(
        color: context.appSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.appBorder),
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
        border: Border.all(color: color.withValues(alpha: 0.12)),
      ),
      child: Icon(icon, color: color, size: size * 0.58),
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
        Text(label, style: TextStyle(fontSize: 14, color: context.appText)),
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

/// Compact inline availability counts for the tablet Staff Availability header.
/// The phone keeps the fuller one-line strip below its header where space is
/// more constrained.
class _LiveQueueHeaderMetrics extends StatelessWidget {
  const _LiveQueueHeaderMetrics({required this.therapists});

  final List<_TherapistStatus> therapists;

  @override
  Widget build(BuildContext context) {
    final total = therapists.length;
    final free = therapists.where((therapist) => therapist.isFree).length;
    final busy = total - free;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.appBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _LiveQueueDot(),
          const SizedBox(width: 7),
          _QueueMetric(
            label: 'Free',
            value: free,
            color: const Color(0xFF16A34A),
          ),
          const _QueueMetricDivider(),
          _QueueMetric(
            label: 'Busy',
            value: busy,
            color: const Color(0xFFD97706),
          ),
          const _QueueMetricDivider(),
          _QueueMetric(
            label: 'Total',
            value: total,
            color: context.appMuted,
          ),
        ],
      ),
    );
  }
}

class _LiveTherapistQueueSummary extends StatelessWidget {
  const _LiveTherapistQueueSummary({
    required this.therapists,
    this.compact = false,
  });

  final List<_TherapistStatus> therapists;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final total = therapists.length;
    final free = therapists.where((therapist) => therapist.isFree).length;
    final busy = total - free;

    // Deliberately one line tall: this is a glanceable status strip above the
    // therapist cards, not a stat panel competing with them.
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 7 : 8,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.appBorder),
      ),
      child: Row(
        children: [
          const _LiveQueueDot(),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              'Live team availability',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: context.appMuted,
              ),
            ),
          ),
          const Spacer(),
          _QueueMetric(
            label: 'Free',
            value: free,
            color: const Color(0xFF16A34A),
          ),
          _QueueMetricDivider(),
          _QueueMetric(
            label: 'Busy',
            value: busy,
            color: const Color(0xFFD97706),
          ),
          _QueueMetricDivider(),
          _QueueMetric(
            label: 'On shift',
            value: total,
            color: context.appMuted,
          ),
        ],
      ),
    );
  }
}

class _LiveQueueDot extends StatelessWidget {
  const _LiveQueueDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: const BoxDecoration(
        color: Color(0xFF22C55E),
        shape: BoxShape.circle,
      ),
    );
  }
}

class _QueueMetricDivider extends StatelessWidget {
  const _QueueMetricDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 11,
      margin: const EdgeInsets.symmetric(horizontal: 9),
      color: context.appBorder,
    );
  }
}

class _QueueMetric extends StatelessWidget {
  const _QueueMetric({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '$value',
          style: TextStyle(
            fontSize: 13,
            height: 1,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            height: 1,
            fontWeight: FontWeight.w600,
            color: context.appMuted,
          ),
        ),
      ],
    );
  }
}

class _TherapistQueueGrid extends StatelessWidget {
  const _TherapistQueueGrid({
    required this.therapists,
    required this.twoColumns,
  });

  final List<_TherapistStatus> therapists;
  final bool twoColumns;

  Widget _column(List<_TherapistStatus> items) {
    return Column(
      children: [
        for (var index = 0; index < items.length; index++) ...[
          _TherapistQueueCard(therapist: items[index]),
          if (index != items.length - 1) const SizedBox(height: 8),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!twoColumns || therapists.length < 2) return _column(therapists);

    // Column-major layout: finish the left column top-to-bottom, then read the
    // right column top-to-bottom. This preserves the queue's visible order.
    final split = (therapists.length + 1) ~/ 2;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _column(therapists.take(split).toList())),
        const SizedBox(width: 12),
        Expanded(child: _column(therapists.skip(split).toList())),
      ],
    );
  }
}

class _TherapistQueueCard extends StatelessWidget {
  const _TherapistQueueCard({required this.therapist});

  final _TherapistStatus therapist;

  @override
  Widget build(BuildContext context) {
    final statusColor = therapist.isFree
        ? const Color(0xFF16A34A)
        : const Color(0xFFD97706);
    final serviceLabel = therapist.doneCount == 1
        ? '1 service today'
        : '${therapist.doneCount} services today';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: context.appSurface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: context.appBorder),
      ),
      child: Row(
        children: [
          _TherapistQueueAvatar(therapist: therapist),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  therapist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: context.appText,
                  ),
                ),
                if (therapist.reservationStatus.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: Color(0xFF2563EB),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          therapist.reservationStatus,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF2563EB),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        therapist.status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: statusColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            serviceLabel,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: context.appMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _TherapistQueueAvatar extends StatelessWidget {
  const _TherapistQueueAvatar({required this.therapist});

  final _TherapistStatus therapist;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Color(0xFFE8F5F5),
        shape: BoxShape.circle,
      ),
      child: Text(
        staffInitials(therapist.name),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: Color(0xFF1B6B72),
        ),
      ),
    );
    final imageUrl = therapist.imageUrl.trim();
    if (imageUrl.isEmpty) return fallback;

    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: imageUrl,
        width: 36,
        height: 36,
        fit: BoxFit.cover,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
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
        Text(label, style: TextStyle(fontSize: 11, color: context.appMuted)),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: context.appText,
          ),
        ),
      ],
    );
  }
}
