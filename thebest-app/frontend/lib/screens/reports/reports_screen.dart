import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/accessibility/accessibility_settings.dart';
import '../../core/utils/staff_initials.dart';
import '../../data/repositories/appointment_repository.dart';
import '../../data/repositories/dashboard_repository.dart';
import '../../data/repositories/service_repository.dart';
import '../../data/repositories/therapist_repository.dart';

const _teal = Color(0xFF1B6B72);
const _ink = Color(0xFF111827);
const _muted = Color(0xFF6B7280);
const _line = Color(0xFFE5E7EB);
const _blue = Color(0xFF2563EB);
const _green = Color(0xFF15955A);
const _amber = Color(0xFFF59E0B);
const _rose = Color(0xFFE11D48);
const _violet = Color(0xFF7C3AED);
const _counterPoolId = '__counter_pool__';

DateTime _stripDate(DateTime date) => DateTime(date.year, date.month, date.day);

bool _inDateRange(DateTime value, DateTime start, DateTime endExclusive) {
  final day = _stripDate(value);
  return !day.isBefore(start) && day.isBefore(endExclusive);
}

String _asString(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  final text = value.toString().trim();
  return text.isEmpty ? fallback : text;
}

double _asDouble(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? fallback;
  return fallback;
}

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

DateTime? _asDateTime(Object? value) {
  // timestamptz values parse as UTC; convert to device-local (Malaysia) so the
  // two-axis day bucketing (paidAt / serviceCompletedAt vs the selected range)
  // and displayed times use the same local calendar day. Naive timestamps are
  // already local, so toLocal() is a no-op for them.
  if (value is DateTime) return value.toLocal();
  if (value is String) return DateTime.tryParse(value)?.toLocal();
  return null;
}

bool _isPaid(Map<String, dynamic> row) {
  final status = _asString(row['paymentStatus']).toLowerCase();
  return status.isEmpty || status == 'paid';
}

String _money(double value) {
  final decimals = value == value.roundToDouble() ? 0 : 2;
  return 'RM ${value.toStringAsFixed(decimals)}';
}

String _compactMoney(double value) {
  final sign = value < 0 ? '-' : '';
  final amount = value.abs();
  if (amount >= 1000000) {
    return '${sign}RM ${(amount / 1000000).toStringAsFixed(1)}m';
  }
  if (amount >= 1000) {
    return '${sign}RM ${(amount / 1000).toStringAsFixed(1)}k';
  }
  return '$sign${_money(amount)}';
}

String _normalizeRole(Object? value) {
  final raw = _asString(value).toLowerCase();
  if (raw.contains('counter') || raw.contains('cashier')) return 'Counter';
  return 'Therapist';
}

String _normalizeCategory(Object? value) {
  final raw = _asString(value).toLowerCase();
  if (raw.contains('package')) return 'Packages';
  if (raw.contains('add')) return 'Add-ons';
  return 'Services';
}

Map<String, double> _commissionMap(Object? value) {
  if (value is! Map) return {};
  final result = <String, double>{};
  value.forEach((key, item) {
    result[key.toString()] = _asDouble(item);
  });
  return result;
}

String _lookupKey(Object? value) {
  return _asString(value).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

bool _sameLookupValue(Object? left, Object? right) {
  final leftKey = _lookupKey(left);
  final rightKey = _lookupKey(right);
  return leftKey.isNotEmpty && leftKey == rightKey;
}

String _staffIdByName(
  Map<String, Map<String, dynamic>> staff,
  Object? name,
) {
  final target = _lookupKey(name);
  if (target.isEmpty) return '';
  for (final entry in staff.entries) {
    if (_lookupKey(entry.value['name']) == target) return entry.key;
  }
  return '';
}

String _resolvedOrderStaffId(
  Map<String, Map<String, dynamic>> staff,
  String id,
  String name,
) {
  if (id.isNotEmpty && staff.containsKey(id)) return id;
  final nameId = _staffIdByName(staff, name);
  if (nameId.isNotEmpty) return nameId;
  return id;
}

String _resolveStaffId({
  required Map<String, Map<String, dynamic>> staff,
  required List<Object?> idCandidates,
  required List<Object?> nameCandidates,
}) {
  for (final value in idCandidates) {
    final id = _asString(value);
    if (id.isNotEmpty && staff.containsKey(id)) return id;
  }
  for (final value in nameCandidates) {
    final id = _staffIdByName(staff, value);
    if (id.isNotEmpty) return id;
  }
  for (final value in idCandidates) {
    final id = _asString(value);
    if (id.isNotEmpty) return id;
  }
  return '';
}

DateTime? _serviceCompletedAtFor({
  required Map<String, dynamic> appointment,
  required List<Map<String, dynamic>> groupAppointments,
  required DateTime? fallback,
}) {
  if (appointment.isNotEmpty) {
    return _asDateTime(appointment['actualCompletedAt']);
  }
  if (groupAppointments.isEmpty) return fallback;

  DateTime? latest;
  for (final item in groupAppointments) {
    final status = _asString(item['status']).toLowerCase();
    if (status == 'cancelled' || status == 'canceled' || status == 'no_show') {
      continue;
    }
    final completedAt = _asDateTime(item['actualCompletedAt']);
    if (completedAt == null) return null;
    if (latest == null || completedAt.isAfter(latest)) latest = completedAt;
  }
  return latest;
}

enum _ReportRange { today, sevenDays, lastMonth, month, custom }

extension _ReportRangeDetails on _ReportRange {
  String get label {
    switch (this) {
      case _ReportRange.today:
        return 'Today';
      case _ReportRange.sevenDays:
        return '7 Days';
      case _ReportRange.lastMonth:
        return 'Last Month';
      case _ReportRange.month:
        return 'This Month';
      case _ReportRange.custom:
        return 'Custom';
    }
  }

  DateTime startFor(DateTime today) {
    switch (this) {
      case _ReportRange.today:
        return today;
      case _ReportRange.sevenDays:
        return today.subtract(const Duration(days: 6));
      case _ReportRange.lastMonth:
        return DateTime(today.year, today.month - 1);
      case _ReportRange.month:
        return DateTime(today.year, today.month);
      case _ReportRange.custom:
        return today.subtract(const Duration(days: 6));
    }
  }

  DateTime endExclusiveFor(DateTime today) {
    switch (this) {
      case _ReportRange.today:
      case _ReportRange.sevenDays:
        return today.add(const Duration(days: 1));
      case _ReportRange.lastMonth:
        return DateTime(today.year, today.month);
      case _ReportRange.month:
      case _ReportRange.custom:
        return today.add(const Duration(days: 1));
    }
  }
}

class _ReportSnapshot {
  final _ReportData data;
  final Map<String, Map<String, dynamic>> servicesById;
  final Map<String, Map<String, dynamic>> staffById;

  const _ReportSnapshot({
    required this.data,
    required this.servicesById,
    required this.staffById,
  });
}

Future<_ReportSnapshot> _loadReportSnapshot({
  required DashboardRepository dashboardRepository,
  required AppointmentRepository appointmentRepository,
  required ServiceRepository serviceRepository,
  required TherapistRepository therapistRepository,
  required DateTime start,
  required DateTime endExclusive,
}) async {
  await appointmentRepository.completeDueAppointments();
  final transactions = await dashboardRepository.listTransactions();
  final paidTransactions = transactions.where(_isPaid).toList();
  final appointmentIds = paidTransactions
      .map((row) => _asString(row['appointmentId']))
      .where((id) => id.isNotEmpty)
      .toSet();
  final appointmentGroupIds = paidTransactions
      .map((row) => _asString(row['appointmentGroupId']))
      .where((id) => id.isNotEmpty)
      .toSet();

  final appointments = await dashboardRepository.loadByIds(
    'appointments',
    appointmentIds,
  );
  final groupAppointments = await dashboardRepository.loadWhereIn(
    'appointments',
    'appointment_group_id',
    appointmentGroupIds.cast<Object>(),
  );
  final appointmentsByGroup = <String, List<Map<String, dynamic>>>{};
  for (final appointment in groupAppointments) {
    final groupId = _asString(appointment['appointmentGroupId']);
    if (groupId.isEmpty) continue;
    appointmentsByGroup.putIfAbsent(groupId, () => []).add(appointment);
  }
  final allocationRows = await appointmentRepository
      .therapistAllocationsForAppointments([
        ...appointments.keys,
        ...groupAppointments.map((row) => _asString(row['id'])),
      ]);
  final allocationsByAppointment = <String, List<Map<String, dynamic>>>{};
  for (final allocation in allocationRows) {
    final appointmentId = _asString(
      allocation['appointmentId'] ?? allocation['appointment_id'],
    );
    if (appointmentId.isEmpty) continue;
    allocationsByAppointment
        .putIfAbsent(appointmentId, () => [])
        .add(allocation);
  }
  final services = await serviceRepository.listServices();
  final staff = await therapistRepository.listTherapists();
  final servicesById = {
    for (final service in services) _asString(service['id']): service,
  }..remove('');
  final staffById = {
    for (final staffMember in staff) _asString(staffMember['id']): staffMember,
  }..remove('');

  final orders = paidTransactions
      .map(
        (transaction) => _ReportOrder.fromTransaction(
          transaction,
          appointments: appointments,
          appointmentsByGroup: appointmentsByGroup,
          services: servicesById,
          staff: staffById,
          allocationsByAppointment: allocationsByAppointment,
        ),
      )
      .where(
        (order) =>
            _inDateRange(order.paidAt, start, endExclusive) ||
            (order.serviceCompletedAt != null &&
                _inDateRange(order.serviceCompletedAt!, start, endExclusive)),
      )
      .toList()
    ..sort((a, b) => b.displayAt.compareTo(a.displayAt));

  return _ReportSnapshot(
    data: _ReportData.fromOrders(
      orders: orders,
      start: start,
      endExclusive: endExclusive,
      services: servicesById,
      staff: staffById,
    ),
    servicesById: servicesById,
    staffById: staffById,
  );
}

class ReportsScreen extends StatefulWidget {
  final String userRole;

  const ReportsScreen({super.key, required this.userRole});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final _dashboardRepository = DashboardRepository();
  final _serviceRepository = ServiceRepository();
  final _appointmentRepository = AppointmentRepository();
  final _therapistRepository = TherapistRepository();

  _ReportRange _range = _ReportRange.month;
  DateTime? _customStartDate;
  DateTime? _customEndDate;
  _ReportData _data = _ReportData.empty;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.userRole.toLowerCase().trim() == 'admin') {
      _loadReports();
    } else {
      _loading = false;
    }
  }

  DateTime get _today => _stripDate(DateTime.now());
  DateTime get _rangeStart => _range == _ReportRange.custom
      ? (_customStartDate ?? _range.startFor(_today))
      : _range.startFor(_today);
  DateTime get _rangeEndExclusive => _range == _ReportRange.custom
      ? (_customEndDate ?? _today).add(const Duration(days: 1))
      : _range.endExclusiveFor(_today);

  String get _rangeLabel {
    final start = _rangeStart;
    final end = _rangeEndExclusive.subtract(const Duration(days: 1));
    if (start == end) return DateFormat('d MMM yyyy').format(start);
    return '${DateFormat('d MMM').format(start)} - ${DateFormat('d MMM yyyy').format(end)}';
  }

  Future<void> _loadReports() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final snapshot = await _loadReportSnapshot(
        dashboardRepository: _dashboardRepository,
        appointmentRepository: _appointmentRepository,
        serviceRepository: _serviceRepository,
        therapistRepository: _therapistRepository,
        start: _rangeStart,
        endExclusive: _rangeEndExclusive,
      );

      if (!mounted) return;
      setState(() {
        _data = snapshot.data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _selectRange(_ReportRange range) {
    if (range == _ReportRange.custom) {
      _openCustomRange();
      return;
    }
    if (_range == range) return;
    setState(() => _range = range);
    _loadReports();
  }

  Future<void> _openCustomRange() async {
    final picked = await showDialog<DateTimeRange>(
      context: context,
      builder: (context) => _ReportDateRangeDialog(
        initialStartDate: _rangeStart,
        initialEndDate: _rangeEndExclusive.subtract(
          const Duration(days: 1),
        ),
        firstDate: DateTime(2020),
        lastDate: _today,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _range = _ReportRange.custom;
      _customStartDate = _stripDate(picked.start);
      _customEndDate = _stripDate(picked.end);
    });
    _loadReports();
  }

  Future<void> _openStaffCommissionReport() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _StaffCommissionReportScreen(
          initialStartDate: _rangeStart,
          initialEndDate: _rangeEndExclusive.subtract(
            const Duration(days: 1),
          ),
        ),
      ),
    );
    if (mounted) _loadReports();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.userRole.toLowerCase().trim() != 'admin') {
      return Scaffold(
        appBar: AppBar(title: const Text('Reports')),
        body: const Center(
          child: Text('Reports are available to administrators only.'),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: const Text(
          'Reports',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _loadReports,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        color: _teal,
        onRefresh: _loadReports,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1040;
            final compact = constraints.maxWidth < 600;
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                wide ? 28 : 16,
                compact ? 8 : 10,
                wide ? 28 : 16,
                compact ? 24 : 28,
              ),
              child: SizedBox(
                width: constraints.maxWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                  _ReportHeader(
                    range: _range,
                    rangeLabel: _rangeLabel,
                    loading: _loading,
                    onRangeChanged: _selectRange,
                  ),
                  SizedBox(height: compact ? 10 : 18),
                  if (_error != null) ...[
                    _ErrorCard(message: _error!, onRetry: _loadReports),
                    SizedBox(height: compact ? 10 : 18),
                  ],
                  _MetricGrid(data: _data, loading: _loading),
                  SizedBox(height: compact ? 10 : 18),
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: _SalesTrendCard(
                            data: _data,
                            loading: _loading,
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          flex: 2,
                          child: _CategoryChartCard(
                            data: _data,
                            loading: _loading,
                          ),
                        ),
                      ],
                    )
                  else ...[
                    _SalesTrendCard(data: _data, loading: _loading),
                    SizedBox(height: compact ? 10 : 18),
                    _CategoryChartCard(data: _data, loading: _loading),
                  ],
                  SizedBox(height: compact ? 10 : 18),
                  _DiscountPromotionsCard(data: _data, loading: _loading),
                  SizedBox(height: compact ? 10 : 18),
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _TopServicesCard(
                            data: _data,
                            loading: _loading,
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: _StaffCommissionCard(
                            data: _data,
                            loading: _loading,
                            onViewAll: _openStaffCommissionReport,
                          ),
                        ),
                      ],
                    )
                  else ...[
                    _TopServicesCard(data: _data, loading: _loading),
                    SizedBox(height: compact ? 10 : 18),
                    _StaffCommissionCard(
                      data: _data,
                      loading: _loading,
                      onViewAll: _openStaffCommissionReport,
                    ),
                  ],
                  SizedBox(height: compact ? 10 : 18),
                  _PaymentBreakdownCard(data: _data, loading: _loading),
                ],
              ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ReportOrder {
  final String id;
  final String appointmentId;
  final String appointmentGroupId;
  final String customerId;
  final String customerName;
  final String therapistId;
  final String therapistName;
  final String counterStaffId;
  final String counterStaffName;
  final String paymentMethod;
  final List<_ReportServiceItem> serviceItems;
  final List<Map<String, dynamic>> therapistAllocations;
  final double serviceNet;
  final double sstAmount;
  final double grossAmount;
  final double discountAmount;
  final double totalAmount;
  final String promotionCode;
  final double therapistCommissionAmount;
  final double counterCommissionAmount;
  final DateTime paidAt;
  final DateTime? serviceCompletedAt;
  final DateTime createdAt;

  const _ReportOrder({
    required this.id,
    required this.appointmentId,
    required this.appointmentGroupId,
    required this.customerId,
    required this.customerName,
    required this.therapistId,
    required this.therapistName,
    required this.counterStaffId,
    required this.counterStaffName,
    required this.paymentMethod,
    required this.serviceItems,
    required this.therapistAllocations,
    required this.serviceNet,
    required this.sstAmount,
    required this.grossAmount,
    required this.discountAmount,
    required this.totalAmount,
    required this.promotionCode,
    required this.therapistCommissionAmount,
    required this.counterCommissionAmount,
    required this.paidAt,
    required this.serviceCompletedAt,
    required this.createdAt,
  });

  factory _ReportOrder.fromTransaction(
    Map<String, dynamic> transaction, {
    required Map<String, Map<String, dynamic>> appointments,
    required Map<String, List<Map<String, dynamic>>> appointmentsByGroup,
    required Map<String, Map<String, dynamic>> services,
    required Map<String, Map<String, dynamic>> staff,
    required Map<String, List<Map<String, dynamic>>>
        allocationsByAppointment,
  }) {
    final appointmentId = _asString(transaction['appointmentId']);
    final appointmentGroupId = _asString(transaction['appointmentGroupId']);
    final appointment = appointments[appointmentId] ?? <String, dynamic>{};
    final groupAppointments = appointmentsByGroup[appointmentGroupId] ?? const [];
    final hasLinkedAppointment =
        appointment.isNotEmpty || groupAppointments.isNotEmpty;
    final customerId = _asString(transaction['customerId']).isNotEmpty
        ? _asString(transaction['customerId'])
        : _asString(appointment['customerId']);
    final rawTherapistName = _asString(
      transaction['therapistName'],
      _asString(
        transaction['staffName'],
        _asString(appointment['therapistName'], _asString(appointment['staffName'])),
      ),
    );
    final therapistId = _resolveStaffId(
      staff: staff,
      idCandidates: [
        transaction['therapistId'],
        transaction['therapist_id'],
        transaction['staffId'],
        transaction['staff_id'],
        appointment['therapistId'],
        appointment['therapist_id'],
        appointment['staffId'],
        appointment['staff_id'],
      ],
      nameCandidates: [
        rawTherapistName,
        transaction['therapistName'],
        transaction['staffName'],
        appointment['therapistName'],
        appointment['staffName'],
      ],
    );
    final staffMember = staff[therapistId] ?? <String, dynamic>{};
    final rawCounterName = _asString(
      transaction['counterStaffName'],
      _asString(
        transaction['cashierName'],
        _asString(transaction['counterName'], _asString(transaction['staffName'])),
      ),
    );
    final counterStaffId = _asString(
      _resolveStaffId(
        staff: staff,
        idCandidates: [
          transaction['counterStaffId'],
          transaction['counter_staff_id'],
          transaction['cashierId'],
          transaction['cashier_id'],
          transaction['counterId'],
          transaction['counter_id'],
        ],
        nameCandidates: [
          rawCounterName,
          transaction['counterStaffName'],
          transaction['cashierName'],
          transaction['counterName'],
        ],
      ),
    );
    final counterStaff = staff[counterStaffId] ?? <String, dynamic>{};
    final serviceItems = _resolveServiceItems(
      transaction,
      appointment: appointment,
      services: services,
    );
    final itemTotal = serviceItems.fold<double>(
      0,
      (total, item) => total + item.price,
    );
    final serviceNet = itemTotal > 0
        ? itemTotal
        : _asDouble(
            transaction['servicePrice'],
            _asDouble(appointment['totalPrice']),
          );
    final sstAmount = _asDouble(transaction['sstAmount']);
    final totalAmount = _asDouble(
      transaction['totalAmount'],
      serviceNet + sstAmount,
    );
    final discountAmount = _asDouble(transaction['discountAmount']);
    final grossAmount = _asDouble(
      transaction['grossAmount'],
      totalAmount + discountAmount,
    );

    final paidAt =
        _asDateTime(transaction['paidAt']) ??
        _asDateTime(transaction['createdAt']) ??
        DateTime.now();
    final serviceCompletedAt = _serviceCompletedAtFor(
      appointment: appointment,
      groupAppointments: groupAppointments,
      fallback: hasLinkedAppointment ? null : paidAt,
    );

    return _ReportOrder(
      id: _asString(transaction['id']),
      appointmentId: appointmentId,
      appointmentGroupId: appointmentGroupId,
      customerId: customerId,
      customerName: _asString(transaction['customerName'], 'Guest'),
      therapistId: therapistId,
      therapistName: _asString(
        rawTherapistName,
        _asString(staffMember['name'], '-'),
      ),
      counterStaffId: counterStaffId,
      counterStaffName: _asString(
        rawCounterName,
        _asString(counterStaff['name']),
      ),
      paymentMethod: _asString(transaction['paymentMethod'], 'other'),
      serviceItems: serviceItems,
      therapistAllocations: [
        if (appointmentId.isNotEmpty)
          ...(allocationsByAppointment[appointmentId] ?? const []),
        for (final item in groupAppointments)
          ...(allocationsByAppointment[_asString(item['id'])] ?? const []),
      ],
      serviceNet: serviceNet,
      sstAmount: sstAmount,
      grossAmount: grossAmount,
      discountAmount: discountAmount,
      totalAmount: totalAmount <= 0 ? serviceNet : totalAmount,
      promotionCode: _asString(transaction['promotionCode']),
      therapistCommissionAmount: _asDouble(
        transaction['therapistCommissionAmount'],
      ),
      counterCommissionAmount: _asDouble(
        transaction['counterCommissionAmount'],
      ),
      paidAt: paidAt,
      serviceCompletedAt: serviceCompletedAt,
      createdAt: paidAt,
    );
  }

  bool get isAppointment =>
      appointmentId.isNotEmpty || appointmentGroupId.isNotEmpty;
  bool get isServiceCompleted => serviceCompletedAt != null;
  DateTime get displayAt => serviceCompletedAt ?? paidAt;
}

class _ReportServiceItem {
  final String id;
  final String name;
  final String category;
  final int duration;
  final double price;
  final double therapistCommission;
  final double counterCommission;
  final String assignedTherapistId;
  final String assignedTherapistName;

  const _ReportServiceItem({
    required this.id,
    required this.name,
    required this.category,
    required this.duration,
    required this.price,
    required this.therapistCommission,
    required this.counterCommission,
    this.assignedTherapistId = '',
    this.assignedTherapistName = '',
  });
}

List<_ReportServiceItem> _resolveServiceItems(
  Map<String, dynamic> transaction, {
  required Map<String, dynamic> appointment,
  required Map<String, Map<String, dynamic>> services,
}) {
  final directItems = _parseServiceItems(
    transaction['serviceItems'] ?? transaction['items'],
    services,
  );
  if (directItems.isNotEmpty) return directItems;

  final appointmentItems = _parseServiceItems(
    appointment['serviceItems'] ?? appointment['items'],
    services,
  );
  if (appointmentItems.isNotEmpty) return appointmentItems;

  final serviceId = _asString(transaction['serviceId']).isNotEmpty
      ? _asString(transaction['serviceId'])
      : _asString(appointment['serviceId']);
  final service = services[serviceId] ?? <String, dynamic>{};
  final name = _asString(
    transaction['serviceName'],
    _asString(appointment['serviceName'], _asString(service['name'], 'Service')),
  );
  final price = _asDouble(
    transaction['servicePrice'],
    _asDouble(appointment['totalPrice'], _asDouble(service['price'])),
  );

  return [
    _ReportServiceItem(
      id: serviceId,
      name: name,
      category: _normalizeCategory(service['category']),
      duration: _asInt(service['duration']),
      price: price,
      therapistCommission: _asDouble(service['therapistCommission']),
      counterCommission: _asDouble(service['counterCommission']),
      assignedTherapistId: _asString(
        transaction['therapistId'],
        _asString(appointment['therapistId']),
      ),
      assignedTherapistName: _asString(
        transaction['therapistName'],
        _asString(appointment['therapistName']),
      ),
    ),
  ];
}

List<_ReportServiceItem> _parseServiceItems(
  Object? value,
  Map<String, Map<String, dynamic>> services,
) {
  if (value is! List) return [];
  final items = <_ReportServiceItem>[];
  for (final item in value) {
    if (item is! Map) continue;
    final data = Map<String, dynamic>.from(item);
    final serviceId = _asString(data['id'], _asString(data['serviceId']));
    final service = services[serviceId] ?? <String, dynamic>{};
    items.add(
      _ReportServiceItem(
        id: serviceId,
        name: _asString(data['name'], _asString(service['name'], 'Service')),
        category: _normalizeCategory(data['category'] ?? service['category']),
        duration: _asInt(data['duration'], _asInt(service['duration'])),
        price: _asDouble(data['price'], _asDouble(service['price'])),
        therapistCommission: _asDouble(
          data['therapistCommission'],
          _asDouble(service['therapistCommission']),
        ),
        counterCommission: _asDouble(
          data['counterCommission'],
          _asDouble(service['counterCommission']),
        ),
        assignedTherapistId: _asString(
          data['assignedTherapistId'],
          _asString(data['therapistId']),
        ),
        assignedTherapistName: _asString(
          data['assignedTherapistName'],
          _asString(data['therapistName']),
        ),
      ),
    );
  }
  return items;
}

class _ReportData {
  final List<_ReportOrder> orders;
  final _ReportSummary summary;
  final List<_DailySales> dailySales;
  final List<_BreakdownSlice> categorySales;
  final List<_BreakdownSlice> paymentSales;
  final List<_ServicePerformance> topServices;
  final List<_StaffCommission> staffCommissions;
  final List<_PromotionDiscount> promotionDiscounts;
  final double counterCommissionTotal;
  final double counterCommissionPool;

  const _ReportData({
    required this.orders,
    required this.summary,
    required this.dailySales,
    required this.categorySales,
    required this.paymentSales,
    required this.topServices,
    required this.staffCommissions,
    required this.promotionDiscounts,
    required this.counterCommissionTotal,
    required this.counterCommissionPool,
  });

  static const empty = _ReportData(
    orders: [],
    summary: _ReportSummary.empty,
    dailySales: [],
    categorySales: [],
    paymentSales: [],
    topServices: [],
    staffCommissions: [],
    promotionDiscounts: [],
    counterCommissionTotal: 0,
    counterCommissionPool: 0,
  );

  factory _ReportData.fromOrders({
    required List<_ReportOrder> orders,
    required DateTime start,
    required DateTime endExclusive,
    required Map<String, Map<String, dynamic>> services,
    required Map<String, Map<String, dynamic>> staff,
  }) {
    final dayCount = math.max(1, endExclusive.difference(start).inDays);
    final dailyTotals = List<double>.filled(dayCount, 0);
    final serviceStats = <String, _MutableServicePerformance>{};
    final categoryTotals = <String, double>{};
    final paymentTotals = <String, double>{};
    final paymentCounts = <String, int>{};
    final customers = <String>{};
    final staffTotals = <String, _MutableStaffCommission>{};
    final promotionTotals = <String, _MutablePromotionDiscount>{};

    var totalSales = 0.0;
    var grossSales = 0.0;
    var discounts = 0.0;
    var discountedTransactions = 0;
    var serviceNet = 0.0;
    var sst = 0.0;
    var itemCount = 0;
    var appointmentOrders = 0;
    var walkInOrders = 0;
    var staffCommission = 0.0;
    var counterCommissionTotal = 0.0;
    var counterCommissionPool = 0.0;
    var counterPoolJobs = 0;
    var counterPoolSales = 0.0;

    for (final order in orders) {
      final paidInRange = _inDateRange(order.paidAt, start, endExclusive);
      final serviceInRange =
          order.serviceCompletedAt != null &&
          _inDateRange(order.serviceCompletedAt!, start, endExclusive);

      if (paidInRange) {
        totalSales += order.totalAmount;
        grossSales += order.grossAmount;
        discounts += order.discountAmount;
        if (order.discountAmount > 0.004) {
          discountedTransactions += 1;
          final code = order.promotionCode.isEmpty
              ? 'Promotion'
              : order.promotionCode;
          promotionTotals
              .putIfAbsent(code, () => _MutablePromotionDiscount(code))
            ..uses += 1
            ..discount += order.discountAmount
            ..gross += order.grossAmount
            ..net += order.totalAmount;
        }
        sst += order.sstAmount;
        final customerKey = order.customerId.isNotEmpty
            ? order.customerId
            : '${order.id}:${order.customerName}';
        customers.add(customerKey);

        final dayIndex = _stripDate(order.paidAt).difference(start).inDays;
        if (dayIndex >= 0 && dayIndex < dailyTotals.length) {
          dailyTotals[dayIndex] += order.totalAmount;
        }

        final payment = order.paymentMethod.trim().isEmpty
            ? 'other'
            : order.paymentMethod.trim().toLowerCase();
        paymentTotals[payment] =
            (paymentTotals[payment] ?? 0) + order.totalAmount;
        paymentCounts[payment] = (paymentCounts[payment] ?? 0) + 1;
      }

      if (!serviceInRange) continue;

      serviceNet += order.serviceNet;
      itemCount += order.serviceItems.length;
      if (order.isAppointment) {
        appointmentOrders += 1;
      } else {
        walkInOrders += 1;
      }

      final resolvedTherapistId = _resolvedOrderStaffId(
        staff,
        order.therapistId,
        order.therapistName,
      );
      final resolvedCounterStaffId = _resolvedOrderStaffId(
        staff,
        order.counterStaffId,
        order.counterStaffName,
      );
      final staffRow = staff[resolvedTherapistId] ?? <String, dynamic>{};
      final staffRole = _normalizeRole(
        staffRow['role'] ?? staffRow['employmentType'],
      );
      var calculatedTherapistCommission = 0.0;
      var calculatedCounterCommission = 0.0;
      var hasAssignedServiceStaff = order.therapistAllocations.isNotEmpty;

      for (final item in order.serviceItems) {
        final serviceKey = item.id.isNotEmpty
            ? item.id
            : item.name.toLowerCase();
        final servicePerformance = serviceStats.putIfAbsent(
          serviceKey,
          () => _MutableServicePerformance(
            id: item.id,
            name: item.name,
            category: item.category,
          ),
        );
        servicePerformance
          ..quantity += 1
          ..revenue += item.price;

        categoryTotals[item.category] =
            (categoryTotals[item.category] ?? 0) + item.price;

        final service = services[item.id] ?? <String, dynamic>{};

        final itemStaffId = _resolvedOrderStaffId(
          staff,
          item.assignedTherapistId,
          item.assignedTherapistName,
        );
        if (itemStaffId.isNotEmpty && order.therapistAllocations.isEmpty) {
          hasAssignedServiceStaff = true;
          final itemStaff = staff[itemStaffId] ?? <String, dynamic>{};
          final itemStaffRole = _normalizeRole(
            itemStaff['role'] ?? itemStaff['employmentType'],
          );
          final itemCommission = _commissionForItem(
            item,
            service: service,
            staff: itemStaff,
            staffRole: itemStaffRole,
          );
          final entry = staffTotals.putIfAbsent(
            itemStaffId,
            () => _MutableStaffCommission(
              id: itemStaffId,
              name: _asString(
                itemStaff['name'],
                _asString(item.assignedTherapistName, 'Staff'),
              ),
              role: itemStaffRole,
            ),
          );
          entry
            ..commission += itemCommission
            ..jobs += 1
            ..sales += item.price;
          staffCommission += itemCommission;
        } else if (resolvedTherapistId.isNotEmpty) {
          calculatedTherapistCommission += _commissionForItem(
            item,
            service: service,
            staff: staffRow,
            staffRole: staffRole,
          );
        }

        if (resolvedCounterStaffId.isNotEmpty) {
          final counterStaff =
              staff[resolvedCounterStaffId] ?? <String, dynamic>{};
          calculatedCounterCommission += _commissionForItem(
            item,
            service: service,
            staff: counterStaff,
            staffRole: 'Counter',
          );
        }
      }
      for (final allocation in order.therapistAllocations) {
        final allocationStaffId = _asString(
          allocation['therapistId'] ?? allocation['therapist_id'],
        );
        if (allocationStaffId.isEmpty) continue;
        final allocationStaff =
            staff[allocationStaffId] ?? <String, dynamic>{};
        final share = _asDouble(
          allocation['commissionShare'] ?? allocation['commission_share'],
        );
        final amount = _asDouble(
          allocation['commissionAmount'] ?? allocation['commission_amount'],
        );
        final entry = staffTotals.putIfAbsent(
          allocationStaffId,
          () => _MutableStaffCommission(
            id: allocationStaffId,
            name: _asString(allocationStaff['name'], 'Therapist'),
            role: _normalizeRole(allocationStaff['role']),
          ),
        );
        entry
          ..commission += amount
          ..jobs += 1
          ..sales += order.serviceNet * share;
        staffCommission += amount;
      }
      final orderStaffCommission = order.therapistCommissionAmount > 0
          ? order.therapistCommissionAmount
          : calculatedTherapistCommission;
      final orderCounterCommission = order.counterCommissionAmount > 0
          ? order.counterCommissionAmount
          : calculatedCounterCommission;

      if (!hasAssignedServiceStaff && resolvedTherapistId.isNotEmpty) {
        final staffName = _asString(
          staffRow['name'],
          order.therapistName == '-' ? 'Staff' : order.therapistName,
        );
        final entry = staffTotals.putIfAbsent(
          resolvedTherapistId,
          () => _MutableStaffCommission(
            id: resolvedTherapistId,
            name: staffName,
            role: staffRole,
          ),
        );
        entry
          ..commission += orderStaffCommission
          ..jobs += 1
          ..sales += order.serviceNet;
        staffCommission += orderStaffCommission;
      }

      if (resolvedCounterStaffId.isNotEmpty) {
        final counterStaff =
            staff[resolvedCounterStaffId] ?? <String, dynamic>{};
        final staffName = _asString(
          counterStaff['name'],
          _asString(order.counterStaffName, 'Counter Staff'),
        );
        final entry = staffTotals.putIfAbsent(
          resolvedCounterStaffId,
          () => _MutableStaffCommission(
            id: resolvedCounterStaffId,
            name: staffName,
            role: 'Counter',
          ),
        );
        entry
          ..commission += orderCounterCommission
          ..jobs += 1
          ..sales += order.serviceNet;
        staffCommission += orderCounterCommission;
        counterCommissionTotal += orderCounterCommission;
      }

      if (order.counterStaffId.isEmpty && order.counterCommissionAmount > 0) {
        counterCommissionPool += order.counterCommissionAmount;
        counterCommissionTotal += order.counterCommissionAmount;
        counterPoolJobs += 1;
        counterPoolSales += order.serviceNet;
        staffCommission += order.counterCommissionAmount;
      }
    }

    final dailySales = List.generate(dayCount, (index) {
      return _DailySales(
        date: start.add(Duration(days: index)),
        amount: dailyTotals[index],
      );
    });
    final categorySales = categoryTotals.entries
        .map(
          (entry) => _BreakdownSlice(
            label: entry.key,
            amount: entry.value,
            count: 0,
            color: _categoryColor(entry.key),
          ),
        )
        .toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
    final paymentSales = paymentTotals.entries
        .map(
          (entry) => _BreakdownSlice(
            label: _paymentLabel(entry.key),
            amount: entry.value,
            count: paymentCounts[entry.key] ?? 0,
            color: _paymentColor(entry.key),
          ),
        )
        .toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
    final topServices = serviceStats.values
        .map((item) => item.toValue())
        .toList()
      ..sort((a, b) {
        final quantityCompare = b.quantity.compareTo(a.quantity);
        if (quantityCompare != 0) return quantityCompare;
        return b.revenue.compareTo(a.revenue);
      });
    final staffCommissions = [
      for (final staffRow in staff.values)
        staffTotals[_asString(staffRow['id'])]?.toValue() ??
            _StaffCommission(
              id: _asString(staffRow['id']),
              name: _asString(staffRow['name'], 'Staff'),
              role: _normalizeRole(
                staffRow['role'] ?? staffRow['employmentType'],
              ),
              jobs: 0,
              sales: 0,
              commission: 0,
            ),
      for (final entry in staffTotals.entries)
        if (!staff.containsKey(entry.key)) entry.value.toValue(),
      if (counterCommissionPool > 0)
        _StaffCommission(
          id: _counterPoolId,
          name: 'Counter Commission',
          role: 'Counter',
          jobs: counterPoolJobs,
          sales: counterPoolSales,
          commission: counterCommissionPool,
        ),
    ]
      ..sort((a, b) {
        final commissionCompare = b.commission.compareTo(a.commission);
        if (commissionCompare != 0) return commissionCompare;
        final jobCompare = b.jobs.compareTo(a.jobs);
        if (jobCompare != 0) return jobCompare;
        return a.name.compareTo(b.name);
      });

    return _ReportData(
      orders: orders,
      summary: _ReportSummary(
        totalSales: totalSales,
        grossSales: grossSales,
        discounts: discounts,
        discountedTransactions: discountedTransactions,
        serviceNet: serviceNet,
        sst: sst,
        orderCount: orders
            .where((order) => _inDateRange(order.paidAt, start, endExclusive))
            .length,
        itemCount: itemCount,
        customerCount: customers.length,
        appointmentOrders: appointmentOrders,
        walkInOrders: walkInOrders,
        staffCommission: staffCommission,
      ),
      dailySales: dailySales,
      categorySales: categorySales,
      paymentSales: paymentSales,
      topServices: topServices.take(3).toList(),
      staffCommissions: staffCommissions,
      promotionDiscounts: promotionTotals.values
          .map((value) => value.toValue())
          .toList()
        ..sort((a, b) => b.discount.compareTo(a.discount)),
      counterCommissionTotal: counterCommissionTotal,
      counterCommissionPool: counterCommissionPool,
    );
  }
}

double _commissionForItem(
  _ReportServiceItem item, {
  required Map<String, dynamic> service,
  required Map<String, dynamic> staff,
  required String staffRole,
}) {
  final overrides = _commissionMap(staff['commissionOverrides']);
  if (item.id.isNotEmpty && overrides.containsKey(item.id)) {
    return overrides[item.id]!;
  }
  final serviceCommission = staffRole == 'Counter'
      ? _asDouble(service['counterCommission'])
      : _asDouble(service['therapistCommission']);
  if (serviceCommission > 0) return serviceCommission;
  return staffRole == 'Counter'
      ? item.counterCommission
      : item.therapistCommission;
}

class _ReportSummary {
  final double totalSales;
  final double grossSales;
  final double discounts;
  final int discountedTransactions;
  final double serviceNet;
  final double sst;
  final int orderCount;
  final int itemCount;
  final int customerCount;
  final int appointmentOrders;
  final int walkInOrders;
  final double staffCommission;

  const _ReportSummary({
    required this.totalSales,
    required this.grossSales,
    required this.discounts,
    required this.discountedTransactions,
    required this.serviceNet,
    required this.sst,
    required this.orderCount,
    required this.itemCount,
    required this.customerCount,
    required this.appointmentOrders,
    required this.walkInOrders,
    required this.staffCommission,
  });

  static const empty = _ReportSummary(
    totalSales: 0,
    grossSales: 0,
    discounts: 0,
    discountedTransactions: 0,
    serviceNet: 0,
    sst: 0,
    orderCount: 0,
    itemCount: 0,
    customerCount: 0,
    appointmentOrders: 0,
    walkInOrders: 0,
    staffCommission: 0,
  );

  double get averageOrder => orderCount == 0 ? 0 : totalSales / orderCount;
  double get averageDiscount => discountedTransactions == 0
      ? 0
      : discounts / discountedTransactions;
}

class _PromotionDiscount {
  final String code;
  final int uses;
  final double discount;
  final double gross;
  final double net;

  const _PromotionDiscount({
    required this.code,
    required this.uses,
    required this.discount,
    required this.gross,
    required this.net,
  });
}

class _MutablePromotionDiscount {
  final String code;
  int uses = 0;
  double discount = 0;
  double gross = 0;
  double net = 0;

  _MutablePromotionDiscount(this.code);

  _PromotionDiscount toValue() => _PromotionDiscount(
        code: code,
        uses: uses,
        discount: discount,
        gross: gross,
        net: net,
      );
}

class _DailySales {
  final DateTime date;
  final double amount;

  const _DailySales({required this.date, required this.amount});
}

class _BreakdownSlice {
  final String label;
  final double amount;
  final int count;
  final Color color;

  const _BreakdownSlice({
    required this.label,
    required this.amount,
    required this.count,
    required this.color,
  });
}

class _ServicePerformance {
  final String id;
  final String name;
  final String category;
  final int quantity;
  final double revenue;

  const _ServicePerformance({
    required this.id,
    required this.name,
    required this.category,
    required this.quantity,
    required this.revenue,
  });
}

class _StaffCommission {
  final String id;
  final String name;
  final String role;
  final int jobs;
  final double sales;
  final double commission;

  const _StaffCommission({
    required this.id,
    required this.name,
    required this.role,
    required this.jobs,
    required this.sales,
    required this.commission,
  });

  String get initials => staffInitials(name, fallback: 'S');
}

class _MutableServicePerformance {
  final String id;
  final String name;
  final String category;
  int quantity = 0;
  double revenue = 0;

  _MutableServicePerformance({
    required this.id,
    required this.name,
    required this.category,
  });

  _ServicePerformance toValue() {
    return _ServicePerformance(
      id: id,
      name: name,
      category: category,
      quantity: quantity,
      revenue: revenue,
    );
  }
}

class _MutableStaffCommission {
  final String id;
  final String name;
  final String role;
  int jobs = 0;
  double sales = 0;
  double commission = 0;

  _MutableStaffCommission({
    required this.id,
    required this.name,
    required this.role,
  });

  _StaffCommission toValue() {
    return _StaffCommission(
      id: id,
      name: name,
      role: role,
      jobs: jobs,
      sales: sales,
      commission: commission,
    );
  }
}

Color _categoryColor(String category) {
  switch (category) {
    case 'Packages':
      return _violet;
    case 'Add-ons':
      return _amber;
    default:
      return _teal;
  }
}

String _paymentLabel(String value) {
  switch (value) {
    case 'cash':
      return 'Cash';
    case 'qr_code':
      return 'QR Code';
    case 'credit_card':
    case 'card':
      return 'Credit';
    case 'debit_card':
      return 'Debit Card';
    case 'others':
      return 'Others';
    case 'billplz':
    case 'online':
      return 'Online';
    default:
      return value.isEmpty ? 'Other' : value;
  }
}

Color _paymentColor(String value) {
  switch (value) {
    case 'cash':
      return _green;
    case 'qr_code':
      return _blue;
    case 'credit_card':
    case 'card':
      return _violet;
    case 'debit_card':
      return _amber;
    case 'others':
      return _muted;
    default:
      return _muted;
  }
}

class _ReportHeader extends StatelessWidget {
  final _ReportRange range;
  final String rangeLabel;
  final bool loading;
  final ValueChanged<_ReportRange> onRangeChanged;

  const _ReportHeader({
    required this.range,
    required this.rangeLabel,
    required this.loading,
    required this.onRangeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    return _ReportCard(
      padding: EdgeInsets.all(phone ? 16 : 18),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 700;
          final title = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'REPORTING OVERVIEW',
                style: TextStyle(
                  color: _teal,
                  fontSize: phone ? 10 : 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
              SizedBox(height: phone ? 4 : 6),
              Text(
                'Business Performance',
                style: TextStyle(
                  color: _ink,
                  fontSize: phone ? 20 : 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: phone ? 3 : 6),
              Text(
                rangeLabel,
                style: TextStyle(
                  color: _muted,
                  fontSize: phone ? 12 : 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          );
          final controls = Wrap(
            spacing: phone ? 6 : 8,
            runSpacing: phone ? 6 : 8,
            alignment: compact ? WrapAlignment.start : WrapAlignment.end,
            children: _ReportRange.values.map((item) {
              final custom = item == _ReportRange.custom;
              return _RangeChip(
                label: custom ? null : item.label,
                icon: custom ? Icons.calendar_month_rounded : null,
                tooltip: custom ? 'Custom date range' : null,
                selected: item == range,
                enabled: !loading,
                compact: phone,
                onTap: () => onRangeChanged(item),
              );
            }).toList(),
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, SizedBox(height: phone ? 10 : 14), controls],
            );
          }

          return Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 16),
              controls,
            ],
          );
        },
      ),
    );
  }
}

class _RangeChip extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final String? tooltip;
  final bool selected;
  final bool enabled;
  final bool compact;
  final VoidCallback onTap;

  const _RangeChip({
    required this.label,
    this.icon,
    this.tooltip,
    required this.selected,
    required this.enabled,
    this.compact = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final iconOnly = icon != null && (label == null || label!.isEmpty);
    final chip = InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: iconOnly ? (compact ? 40 : 44) : null,
        constraints: BoxConstraints(minHeight: compact ? 40 : 44),
        padding: EdgeInsets.symmetric(
          horizontal: iconOnly ? 0 : (compact ? 10 : 14),
          vertical: compact ? 8 : 10,
        ),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? _teal : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? _teal : _line),
        ),
        child: iconOnly
            ? Icon(
                icon,
                color: selected ? Colors.white : _teal,
                size: compact ? 18 : 20,
              )
            : Text(
                label!,
                style: TextStyle(
                  color: selected ? Colors.white : _ink,
                  fontWeight: FontWeight.w800,
                  fontSize: compact ? 11.5 : 12,
                ),
              ),
      ),
    );
    return Semantics(
      button: true,
      label: tooltip ?? label,
      enabled: enabled,
      child: Tooltip(
        message: tooltip ?? label ?? '',
        child: chip,
      ),
    );
  }
}

class _ReportDateRangeDialog extends StatefulWidget {
  final DateTime initialStartDate;
  final DateTime initialEndDate;
  final DateTime firstDate;
  final DateTime lastDate;

  const _ReportDateRangeDialog({
    required this.initialStartDate,
    required this.initialEndDate,
    required this.firstDate,
    required this.lastDate,
  });

  @override
  State<_ReportDateRangeDialog> createState() => _ReportDateRangeDialogState();
}

class _ReportDateRangeDialogState extends State<_ReportDateRangeDialog> {
  late DateTime _firstDate;
  late DateTime _lastDate;
  late DateTime _startDate;
  late DateTime _endDate;
  late DateTime _visibleMonth;
  bool _selectingStart = true;

  @override
  void initState() {
    super.initState();
    _firstDate = _stripDate(widget.firstDate);
    _lastDate = _stripDate(widget.lastDate);
    _startDate = _clampDate(_stripDate(widget.initialStartDate));
    _endDate = _clampDate(_stripDate(widget.initialEndDate));
    if (_endDate.isBefore(_startDate)) _endDate = _startDate;
    _visibleMonth = DateTime(_startDate.year, _startDate.month);
  }

  DateTime _clampDate(DateTime date) {
    if (date.isBefore(_firstDate)) return _firstDate;
    if (date.isAfter(_lastDate)) return _lastDate;
    return date;
  }

  bool _isSameDate(DateTime first, DateTime second) =>
      first.year == second.year &&
      first.month == second.month &&
      first.day == second.day;

  String _rangeText() {
    if (_isSameDate(_startDate, _endDate)) {
      return DateFormat('d MMM yyyy').format(_startDate);
    }
    return '${DateFormat('d MMM').format(_startDate)} – ${DateFormat('d MMM yyyy').format(_endDate)}';
  }

  void _moveMonth(int offset) {
    final nextMonth = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + offset,
    );
    final firstMonth = DateTime(_firstDate.year, _firstDate.month);
    final lastMonth = DateTime(_lastDate.year, _lastDate.month);
    if (nextMonth.isBefore(firstMonth) || nextMonth.isAfter(lastMonth)) {
      return;
    }
    setState(() => _visibleMonth = nextMonth);
  }

  void _activateStart() {
    setState(() {
      _selectingStart = true;
      _visibleMonth = DateTime(_startDate.year, _startDate.month);
    });
  }

  void _activateEnd() {
    setState(() {
      _selectingStart = false;
      _visibleMonth = DateTime(_endDate.year, _endDate.month);
    });
  }

  void _selectDate(DateTime date) {
    final cleanDate = _stripDate(date);
    if (cleanDate.isBefore(_firstDate) || cleanDate.isAfter(_lastDate)) {
      return;
    }
    setState(() {
      if (_selectingStart) {
        _startDate = cleanDate;
        if (_endDate.isBefore(_startDate)) _endDate = _startDate;
        _selectingStart = false;
      } else if (cleanDate.isBefore(_startDate)) {
        _endDate = _startDate;
        _startDate = cleanDate;
      } else {
        _endDate = cleanDate;
      }
      _visibleMonth = DateTime(cleanDate.year, cleanDate.month);
    });
  }

  Widget _dateButton({
    required String label,
    required DateTime date,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: active ? _teal.withValues(alpha: 0.08) : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: active ? _teal : _line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: active ? _teal : _muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                DateFormat('d MMM yyyy').format(date),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dayCell(DateTime day, DateTime today) {
    final cleanDay = _stripDate(day);
    final inMonth = day.month == _visibleMonth.month;
    final disabled =
        cleanDay.isBefore(_firstDate) || cleanDay.isAfter(_lastDate);
    final inRange = !cleanDay.isBefore(_startDate) &&
        !cleanDay.isAfter(_endDate) &&
        !disabled;
    final endpoint = _isSameDate(cleanDay, _startDate) ||
        _isSameDate(cleanDay, _endDate);
    final isToday = _isSameDate(cleanDay, today);

    return InkWell(
      onTap: disabled ? null : () => _selectDate(cleanDay),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: inRange ? _teal.withValues(alpha: 0.10) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        alignment: Alignment.center,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: endpoint ? _teal : Colors.transparent,
            border: isToday && !endpoint
                ? Border.all(color: _teal)
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            '${day.day}',
            style: TextStyle(
              color: disabled
                  ? _muted.withValues(alpha: 0.30)
                  : endpoint
                  ? Colors.white
                  : inMonth
                  ? _ink
                  : _muted,
              fontSize: 13,
              fontWeight: endpoint || isToday
                  ? FontWeight.w900
                  : FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    final firstDay = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    final gridStart = firstDay.subtract(Duration(days: firstDay.weekday % 7));
    final days = List.generate(
      42,
      (index) => gridStart.add(Duration(days: index)),
    );
    final today = _stripDate(DateTime.now());
    final firstMonth = DateTime(_firstDate.year, _firstDate.month);
    final lastMonth = DateTime(_lastDate.year, _lastDate.month);
    final canMovePrevious = _visibleMonth.isAfter(firstMonth);
    final canMoveNext = _visibleMonth.isBefore(lastMonth);

    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: phone ? 12 : 24,
        vertical: 24,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            phone ? 14 : 18,
            14,
            phone ? 14 : 18,
            14,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Custom date range',
                          style: TextStyle(
                            color: _ink,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${_rangeText()} · ${_selectingStart ? 'Choose a start date' : 'Choose an end date'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _dateButton(
                    label: 'FROM',
                    date: _startDate,
                    active: _selectingStart,
                    onTap: _activateStart,
                  ),
                  const SizedBox(width: 8),
                  _dateButton(
                    label: 'TO',
                    date: _endDate,
                    active: !_selectingStart,
                    onTap: _activateEnd,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      DateFormat('MMMM yyyy').format(_visibleMonth),
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Previous month',
                    onPressed:
                        canMovePrevious ? () => _moveMonth(-1) : null,
                    icon: const Icon(Icons.chevron_left_rounded),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    tooltip: 'Next month',
                    onPressed: canMoveNext ? () => _moveMonth(1) : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  for (final label in const ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
                    Expanded(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: _muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                ),
                itemCount: days.length,
                itemBuilder: (context, index) => _dayCell(days[index], today),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(
                      DateTimeRange(start: _startDate, end: _endDate),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: _teal,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Apply'),
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

class _MetricGrid extends StatelessWidget {
  final _ReportData data;
  final bool loading;

  const _MetricGrid({required this.data, required this.loading});

  @override
  Widget build(BuildContext context) {
    final summary = data.summary;
    final earningStaff = data.staffCommissions
        .where((staff) => staff.commission > 0)
        .length;
    final financialCards = [
      _MetricCard(
        title: 'Gross Sales',
        value: loading ? '-' : _money(summary.grossSales),
        detail: 'Before promotional discounts',
        icon: Icons.receipt_long_outlined,
        color: _teal,
      ),
      _MetricCard(
        title: 'Discounts',
        value: loading ? '-' : _money(summary.discounts),
        detail: '${summary.discountedTransactions} discounted sales',
        icon: Icons.local_offer_outlined,
        color: _rose,
      ),
      _MetricCard(
        title: 'Net Sales',
        value: loading ? '-' : _money(summary.totalSales),
        detail: 'Gross less discounts',
        icon: Icons.calculate_outlined,
        color: _teal,
      ),
      _MetricCard(
        title: 'Sales Collected',
        value: loading ? '-' : _money(summary.totalSales),
        detail: '${summary.orderCount} paid transactions',
        icon: Icons.payments_outlined,
        color: _teal,
      ),
    ];
    final operationsCards = [
      _MetricCard(
        title: 'Services Completed',
        value: loading ? '-' : '${summary.itemCount}',
        detail: '${summary.appointmentOrders} bookings, ${summary.walkInOrders} walk-ins',
        icon: Icons.inventory_2_outlined,
        color: _teal,
      ),
      _MetricCard(
        title: 'Average Order',
        value: loading ? '-' : _money(summary.averageOrder),
        detail: '${summary.customerCount} customers',
        icon: Icons.trending_up_rounded,
        color: _teal,
      ),
      _MetricCard(
        title: 'Staff Commission',
        value: loading ? '-' : _money(summary.staffCommission),
        detail: '$earningStaff staff earning',
        icon: Icons.groups_2_outlined,
        color: _teal,
      ),
      _MetricCard(
        title: 'Counter Commission',
        value: loading ? '-' : _money(data.counterCommissionTotal),
        detail: 'Counter staff earnings',
        icon: Icons.point_of_sale_outlined,
        color: _teal,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 1000
            ? 4
            : width >= 340
                ? 2
                : 1;
        final mobile = width < 600;
        final largeUi =
            context.uiScale.preset == UiScalePreset.large ||
            MediaQuery.textScalerOf(context).scale(1) > 1.15;
        Widget grid(List<Widget> cards) {
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: cards.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: mobile ? 8 : 12,
              mainAxisSpacing: mobile ? 8 : 12,
              mainAxisExtent: mobile
                  ? (largeUi ? 156 : 136)
                  : (largeUi ? 184 : 160),
            ),
            itemBuilder: (context, index) => cards[index],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _ReportSectionHeading(
              title: 'Financial overview',
              subtitle: 'Revenue, discounts and collected sales',
            ),
            SizedBox(height: mobile ? 8 : 10),
            grid(financialCards),
            SizedBox(height: mobile ? 14 : 18),
            const _ReportSectionHeading(
              title: 'Operations & team',
              subtitle: 'Completed services and commission signals',
            ),
            SizedBox(height: mobile ? 8 : 10),
            grid(operationsCards),
          ],
        );
      },
    );
  }
}

class _ReportSectionHeading extends StatelessWidget {
  final String title;
  final String subtitle;

  const _ReportSectionHeading({
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: _ink,
                  fontSize: phone ? 15 : 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  color: _muted,
                  fontSize: phone ? 11.5 : 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: phone ? 1 : 2,
          child: Divider(color: _line, height: 1),
        ),
      ],
    );
  }
}

class _DiscountPromotionsCard extends StatelessWidget {
  final _ReportData data;
  final bool loading;

  const _DiscountPromotionsCard({required this.data, required this.loading});

  @override
  Widget build(BuildContext context) {
    final summary = data.summary;
    final compact = MediaQuery.of(context).size.width < 600;
    final grossSalesAffected = data.promotionDiscounts.fold<double>(
      0,
      (total, item) => total + item.gross,
    );
    final stats = [
      _DiscountStat('Total discounts', _money(summary.discounts)),
      _DiscountStat(
        'Discounted transactions',
        '${summary.discountedTransactions}',
      ),
      _DiscountStat('Average discount', _money(summary.averageDiscount)),
      _DiscountStat('Gross sales affected', _money(grossSalesAffected)),
    ];
    return _ReportCard(
      padding: EdgeInsets.all(compact ? 12 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(
            title: 'Discounts & Promotions',
            subtitle: 'Redeemed monetary promotions in this date range',
            icon: Icons.local_offer_rounded,
            color: _rose,
          ),
          SizedBox(height: compact ? 14 : 18),
          if (loading)
            SizedBox(
              height: compact ? 96 : 120,
              child: const _ChartSkeleton(),
            )
          else ...[
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 760
                    ? 4
                    : constraints.maxWidth >= 320
                    ? 2
                    : 1;
                final gap = compact ? 8.0 : 12.0;
                final panelPadding = compact ? 8.0 : 10.0;
                final availableWidth = constraints.maxWidth - panelPadding * 2;
                final itemWidth = columns == 1
                    ? availableWidth
                    : (availableWidth - gap * (columns - 1)) / columns;
                return Container(
                  padding: EdgeInsets.all(panelPadding),
                  decoration: BoxDecoration(
                    color: _rose.withValues(alpha: 0.025),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _rose.withValues(alpha: 0.10)),
                  ),
                  child: Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final stat in stats)
                        SizedBox(width: itemWidth, child: stat),
                    ],
                  ),
                );
              },
            ),
            SizedBox(height: compact ? 16 : 20),
            if (data.promotionDiscounts.isEmpty)
              _DiscountEmptyState(compact: compact)
            else ...[
              Row(
                children: [
                  Text(
                    'Redeemed promotions',
                    style: TextStyle(
                      color: _ink,
                      fontSize: compact ? 12 : 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Divider(color: _line, height: 1)),
                ],
              ),
              for (final promotion in data.promotionDiscounts) ...[
                const SizedBox(height: 8),
                _PromotionActivityRow(
                  promotion: promotion,
                  compact: compact,
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }
}

class _PromotionActivityRow extends StatelessWidget {
  final _PromotionDiscount promotion;
  final bool compact;

  const _PromotionActivityRow({
    required this.promotion,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 14,
        vertical: compact ? 10 : 12,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _SoftIcon(
            icon: Icons.local_offer_rounded,
            color: _rose,
            size: compact ? 34 : 38,
          ),
          SizedBox(width: compact ? 9 : 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  promotion.code,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _ink,
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${promotion.uses} use${promotion.uses == 1 ? '' : 's'} · Gross ${_money(promotion.gross)} · Net ${_money(promotion.net)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _muted,
                    fontSize: compact ? 10.5 : 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: compact ? 8 : 12),
          Container(
            constraints: BoxConstraints(minWidth: compact ? 70 : 84),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 10,
              vertical: compact ? 7 : 8,
            ),
            decoration: BoxDecoration(
              color: _rose.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'DISCOUNT',
                  style: TextStyle(
                    color: _rose,
                    fontSize: compact ? 8 : 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '-${_money(promotion.discount)}',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: _rose,
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DiscountEmptyState extends StatelessWidget {
  final bool compact;

  const _DiscountEmptyState({required this.compact});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 16,
        vertical: compact ? 14 : 18,
      ),
      decoration: BoxDecoration(
        color: _rose.withValues(alpha: 0.025),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _rose.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          _SoftIcon(
            icon: Icons.local_offer_rounded,
            color: _muted,
            size: compact ? 38 : 44,
          ),
          SizedBox(width: compact ? 10 : 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No promotions redeemed yet',
                  style: TextStyle(
                    color: _ink,
                    fontSize: compact ? 12 : 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Promotion activity will appear here once a discount is used.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _muted,
                    fontSize: compact ? 10.5 : 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DiscountStat extends StatelessWidget {
  final String label;
  final String value;

  const _DiscountStat(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: phone ? 76 : 82),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: phone ? 12 : 14,
          vertical: phone ? 10 : 12,
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _rose.withValues(alpha: 0.12)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _muted,
                fontSize: phone ? 10.5 : 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              value,
              style: TextStyle(
                color: _ink,
                fontSize: phone ? 18 : 20,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String title;
  final String value;
  final String detail;
  final IconData icon;
  final Color color;

  const _MetricCard({
    required this.title,
    required this.value,
    required this.detail,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    return _ReportCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            height: 4,
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: phone ? 10 : 16,
                vertical: phone ? 8 : 12,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _SoftIcon(
                        icon: icon,
                        color: color,
                        size: phone ? 32 : 38,
                      ),
                      SizedBox(width: phone ? 8 : 10),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _ink,
                            fontSize: phone ? 12 : 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: phone ? 12 : 16),
                  SizedBox(
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        value,
                        maxLines: 1,
                        style: TextStyle(
                          color: _ink,
                          fontSize: phone ? 21 : 23,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                  if (value != '-') ...[
                    SizedBox(height: phone ? 2 : 4),
                    Text(
                      detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _muted,
                        fontSize: phone ? 10.5 : 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SalesTrendCard extends StatelessWidget {
  final _ReportData data;
  final bool loading;

  const _SalesTrendCard({required this.data, required this.loading});

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    return _ReportCard(
      padding: EdgeInsets.all(phone ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(
            title: 'Sales Trend',
            subtitle: 'Daily collection',
            icon: Icons.show_chart_rounded,
            color: _blue,
          ),
          SizedBox(height: phone ? 10 : 18),
          SizedBox(
            height: phone ? 190 : 292,
            child: loading
                ? const _ChartSkeleton()
                : data.summary.orderCount == 0
                    ? const _EmptyState(
                        icon: Icons.show_chart_rounded,
                        title: 'No sales in this range',
                      )
                    : _SalesLineChart(points: data.dailySales),
          ),
        ],
      ),
    );
  }
}

class _SalesLineChart extends StatelessWidget {
  final List<_DailySales> points;

  const _SalesLineChart({required this.points});

  @override
  Widget build(BuildContext context) {
    final spots = [
      for (var index = 0; index < points.length; index++)
        FlSpot(index.toDouble(), points[index].amount),
    ];
    final maxAmount = points.fold<double>(
      0,
      (maxValue, item) => math.max(maxValue, item.amount),
    );
    final maxY = maxAmount <= 0 ? 10.0 : maxAmount * 1.22;
    final labelStep = math.max(1, (points.length / 5).ceil());

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: math.max(1, points.length - 1).toDouble(),
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => const FlLine(
            color: _line,
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 48,
              getTitlesWidget: (value, meta) {
                if (value == 0 || value == maxY) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  axisSide: meta.axisSide,
                  child: Text(
                    _compactMoney(value),
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: labelStep.toDouble(),
              reservedSize: 32,
              getTitlesWidget: (value, meta) {
                final index = value.round();
                if (index < 0 || index >= points.length) {
                  return const SizedBox.shrink();
                }
                if (index % labelStep != 0 && index != points.length - 1) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  axisSide: meta.axisSide,
                  child: Text(
                    DateFormat(points.length <= 7 ? 'EEE' : 'd MMM')
                        .format(points[index].date),
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (items) => items.map((item) {
              final index = item.x.round().clamp(0, points.length - 1);
              return LineTooltipItem(
                '${DateFormat('d MMM').format(points[index].date)}\n${_money(item.y)}',
                const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              );
            }).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: false,
            color: _blue,
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: FlDotData(show: spots.length <= 10),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _blue.withValues(alpha: 0.18),
                  _blue.withValues(alpha: 0.02),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryChartCard extends StatelessWidget {
  final _ReportData data;
  final bool loading;

  const _CategoryChartCard({required this.data, required this.loading});

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    return _ReportCard(
      padding: EdgeInsets.all(phone ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(
            title: 'Revenue Mix',
            subtitle: 'By service type',
            icon: Icons.bar_chart_rounded,
            color: _teal,
          ),
          SizedBox(height: phone ? 10 : 18),
          SizedBox(
            height: phone ? 180 : 292,
            child: loading
                ? const _ChartSkeleton()
                : data.categorySales.isEmpty
                    ? const _EmptyState(
                        icon: Icons.bar_chart_rounded,
                        title: 'No category data',
                      )
                    : _CategoryBarChart(items: data.categorySales),
          ),
        ],
      ),
    );
  }
}

class _CategoryBarChart extends StatelessWidget {
  final List<_BreakdownSlice> items;

  const _CategoryBarChart({required this.items});

  @override
  Widget build(BuildContext context) {
    final maxAmount = items.fold<double>(
      0,
      (maxValue, item) => math.max(maxValue, item.amount),
    );
    final maxY = maxAmount <= 0 ? 10.0 : maxAmount * 1.25;

    return BarChart(
      BarChartData(
        maxY: maxY,
        minY: 0,
        alignment: BarChartAlignment.spaceAround,
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final item = items[group.x.toInt()];
              return BarTooltipItem(
                '${item.label}\n${_money(item.amount)}',
                const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              );
            },
          ),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => const FlLine(
            color: _line,
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              getTitlesWidget: (value, meta) {
                if (value == 0 || value == maxY) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  axisSide: meta.axisSide,
                  child: Text(
                    _compactMoney(value),
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index < 0 || index >= items.length) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  axisSide: meta.axisSide,
                  child: Text(
                    items[index].label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var index = 0; index < items.length; index++)
            BarChartGroupData(
              x: index,
              barRods: [
                BarChartRodData(
                  toY: items[index].amount,
                  width: 34,
                  color: items[index].color,
                  borderRadius: BorderRadius.circular(4),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _TopServicesCard extends StatelessWidget {
  final _ReportData data;
  final bool loading;

  const _TopServicesCard({required this.data, required this.loading});

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    return _ReportCard(
      padding: EdgeInsets.all(phone ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(
            title: 'Top 3 Services',
            subtitle: 'Best selling by quantity',
            icon: Icons.emoji_events_outlined,
            color: _amber,
          ),
          const SizedBox(height: 16),
          if (loading)
            const _ListSkeleton(rows: 3)
          else if (data.topServices.isEmpty)
            SizedBox(
              height: phone ? 180 : 292,
              child: const _EmptyState(
                icon: Icons.emoji_events_outlined,
                title: 'No services sold yet',
              ),
            )
          else
            for (var index = 0; index < data.topServices.length; index++) ...[
              _TopServiceRow(
                rank: index + 1,
                service: data.topServices[index],
                maxRevenue: data.topServices.first.revenue,
              ),
              if (index != data.topServices.length - 1)
                SizedBox(height: phone ? 8 : 12),
            ],
        ],
      ),
    );
  }
}

class _TopServiceRow extends StatelessWidget {
  final int rank;
  final _ServicePerformance service;
  final double maxRevenue;

  const _TopServiceRow({
    required this.rank,
    required this.service,
    required this.maxRevenue,
  });

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    final progress = maxRevenue <= 0 ? 0.0 : service.revenue / maxRevenue;
    return Container(
      padding: EdgeInsets.all(phone ? 9 : 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          Container(
            width: phone ? 30 : 34,
            height: phone ? 30 : 34,
            decoration: BoxDecoration(
              color: _amber.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              '$rank',
              style: const TextStyle(
                color: _amber,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  service.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                SizedBox(height: phone ? 5 : 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0, 1),
                    minHeight: phone ? 5 : 6,
                    backgroundColor: _line,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(_amber),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${service.quantity} sold',
                style: TextStyle(
                  color: _ink,
                  fontWeight: FontWeight.w900,
                  fontSize: phone ? 10 : 12,
                ),
              ),
              SizedBox(height: phone ? 2 : 4),
              Text(
                _money(service.revenue),
                style: TextStyle(
                  color: _muted,
                  fontSize: phone ? 10 : 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StaffCommissionCard extends StatelessWidget {
  final _ReportData data;
  final bool loading;
  final VoidCallback onViewAll;

  const _StaffCommissionCard({
    required this.data,
    required this.loading,
    required this.onViewAll,
  });

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    final topStaff = data.staffCommissions.take(3).toList();
    final maxCommission = topStaff.fold<double>(
      0,
      (maxValue, item) => math.max(maxValue, item.commission),
    );

    return _ReportCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: _CardTitle(
                  title: 'Staff Commission',
                  subtitle: 'Top 3 overall',
                  icon: Icons.groups_2_outlined,
                  color: _violet,
                ),
              ),
              TextButton.icon(
                onPressed: onViewAll,
                icon: Icon(Icons.open_in_full_rounded, size: phone ? 14 : 16),
                label: const Text('View All'),
                style: TextButton.styleFrom(
                  foregroundColor: _teal,
                  padding: EdgeInsets.symmetric(
                    horizontal: phone ? 6 : 8,
                    vertical: phone ? 4 : 8,
                  ),
                  textStyle: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: phone ? 11 : 14,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: phone ? 10 : 16),
          if (loading)
            const _ListSkeleton(rows: 3)
          else if (topStaff.isEmpty)
            const _EmptyState(
              icon: Icons.groups_2_outlined,
              title: 'No staff commission yet',
            )
          else
            for (var index = 0; index < topStaff.length; index++) ...[
              _StaffCommissionRow(
                rank: index + 1,
                staff: topStaff[index],
                maxCommission: maxCommission,
              ),
              if (index != topStaff.length - 1)
                SizedBox(height: phone ? 8 : 12),
            ],
        ],
      ),
    );
  }
}

class _StaffCommissionRow extends StatelessWidget {
  final int rank;
  final _StaffCommission staff;
  final double maxCommission;

  const _StaffCommissionRow({
    required this.rank,
    required this.staff,
    required this.maxCommission,
  });

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    final progress =
        maxCommission <= 0 ? 0.0 : staff.commission / maxCommission;
    final color = staff.role == 'Counter' ? _rose : _violet;
    return Container(
      padding: EdgeInsets.all(phone ? 9 : 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          Container(
            width: phone ? 30 : 42,
            height: phone ? 30 : 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              '$rank',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w900,
                fontSize: phone ? 13 : 16,
              ),
            ),
          ),
          SizedBox(width: phone ? 8 : 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  staff.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w900,
                    fontSize: phone ? 13 : 15,
                  ),
                ),
                SizedBox(height: phone ? 5 : 9),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0, 1),
                    minHeight: phone ? 5 : 6,
                    backgroundColor: _line,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: phone ? 8 : 12),
          Text(
            _money(staff.commission),
            style: TextStyle(
              color: _ink,
              fontWeight: FontWeight.w900,
              fontSize: phone ? 12 : 14,
            ),
          ),
        ],
      ),
    );
  }
}

class _StaffCommissionReportScreen extends StatefulWidget {
  final DateTime initialStartDate;
  final DateTime initialEndDate;

  const _StaffCommissionReportScreen({
    required this.initialStartDate,
    required this.initialEndDate,
  });

  @override
  State<_StaffCommissionReportScreen> createState() =>
      _StaffCommissionReportScreenState();
}

class _StaffCommissionReportScreenState
    extends State<_StaffCommissionReportScreen> {
  final _dashboardRepository = DashboardRepository();
  final _serviceRepository = ServiceRepository();
  final _appointmentRepository = AppointmentRepository();
  final _therapistRepository = TherapistRepository();

  late DateTime _startDate;
  late DateTime _endDate;
  _ReportData _data = _ReportData.empty;
  Map<String, Map<String, dynamic>> _servicesById = {};
  Map<String, Map<String, dynamic>> _staffById = {};
  String? _selectedStaffId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startDate = _stripDate(widget.initialStartDate);
    _endDate = _stripDate(widget.initialEndDate);
    _loadReport();
  }

  Future<void> _loadReport() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final snapshot = await _loadReportSnapshot(
        dashboardRepository: _dashboardRepository,
        appointmentRepository: _appointmentRepository,
        serviceRepository: _serviceRepository,
        therapistRepository: _therapistRepository,
        start: _startDate,
        endExclusive: _endDate.add(const Duration(days: 1)),
      );
      final staff = snapshot.data.staffCommissions;
      final selectedStillExists =
          staff.any((item) => item.id == _selectedStaffId);

      if (!mounted) return;
      setState(() {
        _data = snapshot.data;
        _servicesById = snapshot.servicesById;
        _staffById = snapshot.staffById;
        _selectedStaffId = selectedStillExists
            ? _selectedStaffId
            : staff.isEmpty
                ? null
                : staff.first.id;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _pickDate({required bool start}) async {
    final current = start ? _startDate : _endDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: _teal,
                  secondary: _teal,
                ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;

    setState(() {
      if (start) {
        _startDate = _stripDate(picked);
        if (_startDate.isAfter(_endDate)) _endDate = _startDate;
      } else {
        _endDate = _stripDate(picked);
        if (_endDate.isBefore(_startDate)) _startDate = _endDate;
      }
    });
    await _loadReport();
  }

  _StaffCommission? get _selectedStaff {
    final id = _selectedStaffId;
    if (id == null) return null;
    for (final staff in _data.staffCommissions) {
      if (staff.id == id) return staff;
    }
    return null;
  }

  List<_StaffOrderRecord> get _selectedRecords {
    final staff = _selectedStaff;
    if (staff == null) return [];
    return _recordsForStaff(
      staff: staff,
      orders: _data.orders,
      services: _servicesById,
      staffById: _staffById,
    );
  }

  _StaffCommission? _staffByIdValue(String id) {
    for (final staff in _data.staffCommissions) {
      if (staff.id == id) return staff;
    }
    return null;
  }

  void _selectStaff(String id, {required bool openFullScreen}) {
    setState(() => _selectedStaffId = id);
    if (!openFullScreen) return;

    final staff = _staffByIdValue(id);
    if (staff == null) return;
    final records = _recordsForStaff(
      staff: staff,
      orders: _data.orders,
      services: _servicesById,
      staffById: _staffById,
    );
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => _StaffOrderHistoryScreen(
          staff: staff,
          records: records,
          rangeLabel:
              '${DateFormat('d MMM').format(_startDate)} - ${DateFormat('d MMM yyyy').format(_endDate)}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: const Text(
          'Staff Commission',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _loadReport,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        color: _teal,
        onRefresh: _loadReport,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 980;
            final phone = constraints.maxWidth < 600;
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                wide ? 28 : phone ? 10 : 16,
                phone ? 4 : 8,
                wide ? 28 : phone ? 10 : 16,
                phone ? 16 : 28,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _StaffCommissionFilterCard(
                    startDate: _startDate,
                    endDate: _endDate,
                    totalCommission: _data.summary.staffCommission,
                    staffCount: _data.staffCommissions.length,
                    loading: _loading,
                    onPickStart: () => _pickDate(start: true),
                    onPickEnd: () => _pickDate(start: false),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    _ErrorCard(message: _error!, onRetry: _loadReport),
                  ],
                  const SizedBox(height: 16),
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 360,
                          child: _StaffListPanel(
                            staff: _data.staffCommissions,
                            selectedStaffId: _selectedStaffId,
                            loading: _loading,
                            onSelected: (id) => _selectStaff(
                              id,
                              openFullScreen: false,
                            ),
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: _StaffOrderHistoryPanel(
                            staff: _selectedStaff,
                            records: _selectedRecords,
                            loading: _loading,
                          ),
                        ),
                      ],
                    )
                  else ...[
                    _StaffListPanel(
                      staff: _data.staffCommissions,
                      selectedStaffId: _selectedStaffId,
                      loading: _loading,
                      onSelected: (id) => _selectStaff(
                        id,
                        openFullScreen: phone,
                      ),
                    ),
                    if (!phone) ...[
                      const SizedBox(height: 16),
                      _StaffOrderHistoryPanel(
                        staff: _selectedStaff,
                        records: _selectedRecords,
                        loading: _loading,
                      ),
                    ],
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StaffCommissionFilterCard extends StatelessWidget {
  final DateTime startDate;
  final DateTime endDate;
  final double totalCommission;
  final int staffCount;
  final bool loading;
  final VoidCallback onPickStart;
  final VoidCallback onPickEnd;

  const _StaffCommissionFilterCard({
    required this.startDate,
    required this.endDate,
    required this.totalCommission,
    required this.staffCount,
    required this.loading,
    required this.onPickStart,
    required this.onPickEnd,
  });

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    return _ReportCard(
      padding: EdgeInsets.all(phone ? 12 : 18),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 720;
          final title = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Commission Report',
                style: TextStyle(
                  color: _ink,
                  fontSize: phone ? 18 : 23,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: phone ? 3 : 6),
              Text(
                loading
                    ? 'Loading staff performance'
                    : '${_money(totalCommission)} total - $staffCount staff',
                style: TextStyle(
                  color: _muted,
                  fontSize: phone ? 11 : 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          );
          final controls = Wrap(
            spacing: phone ? 6 : 10,
            runSpacing: phone ? 6 : 10,
            children: [
              _DateFilterButton(
                label: 'From',
                date: startDate,
                onTap: loading ? null : onPickStart,
              ),
              _DateFilterButton(
                label: 'To',
                date: endDate,
                onTap: loading ? null : onPickEnd,
              ),
            ],
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [title, SizedBox(height: phone ? 10 : 14), controls],
            );
          }

          return Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 16),
              controls,
            ],
          );
        },
      ),
    );
  }
}

class _DateFilterButton extends StatelessWidget {
  final String label;
  final DateTime date;
  final VoidCallback? onTap;

  const _DateFilterButton({
    required this.label,
    required this.date,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: phone ? 9 : 12,
          vertical: phone ? 8 : 10,
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.calendar_today_outlined, size: 16, color: _teal),
            SizedBox(width: phone ? 6 : 8),
            Text(
              '$label ${DateFormat('d MMM yyyy').format(date)}',
              style: TextStyle(
                color: _ink,
                fontSize: phone ? 10.5 : 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StaffListPanel extends StatelessWidget {
  final List<_StaffCommission> staff;
  final String? selectedStaffId;
  final bool loading;
  final ValueChanged<String> onSelected;

  const _StaffListPanel({
    required this.staff,
    required this.selectedStaffId,
    required this.loading,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    return _ReportCard(
      padding: EdgeInsets.all(phone ? 10 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(
            title: 'All Staff',
            subtitle: 'Tap a staff to view orders',
            icon: Icons.badge_outlined,
            color: _teal,
          ),
          SizedBox(height: phone ? 10 : 14),
          if (loading)
            const _ListSkeleton(rows: 6)
          else if (staff.isEmpty)
            const _EmptyState(
              icon: Icons.badge_outlined,
              title: 'No staff found',
            )
          else
            for (var index = 0; index < staff.length; index++) ...[
              _StaffListItem(
                staff: staff[index],
                selected: staff[index].id == selectedStaffId,
                onTap: () => onSelected(staff[index].id),
              ),
              if (index != staff.length - 1) SizedBox(height: phone ? 6 : 8),
            ],
        ],
      ),
    );
  }
}

class _StaffListItem extends StatelessWidget {
  final _StaffCommission staff;
  final bool selected;
  final VoidCallback onTap;

  const _StaffListItem({
    required this.staff,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    final color = staff.role == 'Counter' ? _rose : _violet;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(
          horizontal: phone ? 8 : 10,
          vertical: phone ? 7 : 9,
        ),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.08) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? color.withValues(alpha: 0.45) : _line,
          ),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 3,
              height: phone ? 30 : 36,
              decoration: BoxDecoration(
                color: selected ? color : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            SizedBox(width: phone ? 7 : 9),
            CircleAvatar(
              radius: phone ? 14 : 16,
              backgroundColor: color.withValues(alpha: 0.12),
              child: staff.id == _counterPoolId
                  ? Icon(
                      Icons.point_of_sale_outlined,
                      color: color,
                      size: phone ? 14 : 16,
                    )
                  : Text(
                      staff.initials,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w900,
                        fontSize: phone ? 10 : 11,
                      ),
                    ),
            ),
            SizedBox(width: phone ? 8 : 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    staff.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _ink,
                      fontWeight: FontWeight.w900,
                      fontSize: phone ? 12.5 : 13,
                    ),
                  ),
                  SizedBox(height: phone ? 2 : 3),
                  Text(
                    '${staff.role} - ${staff.jobs} orders',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _muted,
                      fontSize: phone ? 10 : 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              _money(staff.commission),
              style: TextStyle(
                color: selected ? color : _ink,
                fontWeight: FontWeight.w900,
                fontSize: phone ? 12 : 12.5,
              ),
            ),
            if (phone) ...[
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right_rounded, size: 18, color: _muted),
            ],
          ],
        ),
      ),
    );
  }
}

class _StaffOrderHistoryPanel extends StatelessWidget {
  final _StaffCommission? staff;
  final List<_StaffOrderRecord> records;
  final bool loading;

  const _StaffOrderHistoryPanel({
    required this.staff,
    required this.records,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    final selectedStaff = staff;
    return _ReportCard(
      padding: EdgeInsets.all(MediaQuery.of(context).size.width < 600 ? 10 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            title: selectedStaff == null ? 'Order History' : selectedStaff.name,
            subtitle: selectedStaff == null
                ? 'Select a staff'
                : '${records.length} orders - ${_money(selectedStaff.commission)} commission',
            icon: Icons.receipt_long_outlined,
            color: _blue,
          ),
          const SizedBox(height: 10),
          if (loading)
            const _ListSkeleton(rows: 7)
          else if (selectedStaff == null)
            const _EmptyState(
              icon: Icons.receipt_long_outlined,
              title: 'Select a staff to view order history',
            )
          else if (records.isEmpty)
            const _EmptyState(
              icon: Icons.receipt_long_outlined,
              title: 'No orders for this staff in this range',
            )
          else
            for (var index = 0; index < records.length; index++) ...[
              _StaffOrderHistoryTile(record: records[index]),
              if (index != records.length - 1) const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

class _StaffOrderHistoryScreen extends StatelessWidget {
  final _StaffCommission staff;
  final List<_StaffOrderRecord> records;
  final String rangeLabel;

  const _StaffOrderHistoryScreen({
    required this.staff,
    required this.records,
    required this.rangeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final color = staff.role == 'Counter' ? _rose : _violet;
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: Text(
          staff.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
        children: [
          _ReportCard(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: color.withValues(alpha: 0.12),
                  child: staff.id == _counterPoolId
                      ? Icon(
                          Icons.point_of_sale_outlined,
                          color: color,
                          size: 18,
                        )
                      : Text(
                          staff.initials,
                          style: TextStyle(
                            color: color,
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${records.length} orders',
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$rangeLabel - ${staff.role}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _money(staff.commission),
                      style: TextStyle(
                        color: color,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Commission',
                      style: TextStyle(
                        color: _muted,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (records.isEmpty)
            const _ReportCard(
              padding: EdgeInsets.all(16),
              child: _EmptyState(
                icon: Icons.receipt_long_outlined,
                title: 'No orders for this staff in this range',
              ),
            )
          else
            for (var index = 0; index < records.length; index++) ...[
              _StaffOrderHistoryTile(record: records[index]),
              if (index != records.length - 1) const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

class _StaffOrderHistoryTile extends StatelessWidget {
  final _StaffOrderRecord record;

  const _StaffOrderHistoryTile({required this.record});

  void _openDetail(BuildContext context) {
    if (MediaQuery.of(context).size.width < 600) {
      Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => _StaffOrderDetailScreen(record: record),
        ),
      );
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => _StaffOrderDetailDialog(record: record),
    );
  }

  @override
  Widget build(BuildContext context) {
    final order = record.order;
    final roleColor = record.role.contains('Counter') ? _rose : _violet;
    final phone = MediaQuery.of(context).size.width < 600;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openDetail(context),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: EdgeInsets.all(phone ? 9 : 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _line),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 620;
              if (compact) {
                return _CompactStaffOrderTileContent(
                  record: record,
                  color: roleColor,
                );
              }

              final details = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          order.customerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _RoleBadge(label: record.role, color: roleColor),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    record.serviceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 9),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _MiniInfoPill(
                        icon: Icons.schedule_outlined,
                        label: DateFormat('d MMM yyyy - h:mm a')
                            .format(order.displayAt),
                      ),
                      _MiniInfoPill(
                        icon: Icons.wallet_outlined,
                        label: _paymentLabel(order.paymentMethod),
                      ),
                      _MiniInfoPill(
                        icon: Icons.work_outline_rounded,
                        label: record.role,
                        color: roleColor,
                      ),
                    ],
                  ),
                ],
              );
              final totals = Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    'Commission',
                    style: TextStyle(
                      color: _muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _money(record.commission),
                    style: TextStyle(
                      color: roleColor,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Order ${_money(order.totalAmount)}',
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              );

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 4,
                    height: 70,
                    decoration: BoxDecoration(
                      color: roleColor,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: details),
                  const SizedBox(width: 16),
                  totals,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CompactStaffOrderTileContent extends StatelessWidget {
  final _StaffOrderRecord record;
  final Color color;

  const _CompactStaffOrderTileContent({
    required this.record,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final order = record.order;
    final date = DateFormat('d MMM, h:mm a').format(order.displayAt);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 4,
          height: 50,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      order.customerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _RoleBadge(label: record.role, color: color, compact: true),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                record.serviceName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  const Icon(Icons.schedule_outlined, size: 13, color: _muted),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      date,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.wallet_outlined, size: 13, color: _muted),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      _paymentLabel(order.paymentMethod),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 62, maxWidth: 86),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _money(record.commission),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                _money(order.totalAmount),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RoleBadge extends StatelessWidget {
  final String label;
  final Color color;
  final bool compact;

  const _RoleBadge({
    required this.label,
    required this.color,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: compact ? 82 : 130),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 7 : 9,
          vertical: compact ? 3 : 5,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: color,
            fontSize: compact ? 10 : 11,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _StaffOrderDetailScreen extends StatelessWidget {
  final _StaffOrderRecord record;

  const _StaffOrderDetailScreen({required this.record});

  @override
  Widget build(BuildContext context) {
    final order = record.order;
    final roleColor = record.role.contains('Counter') ? _rose : _violet;
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: const Text(
          'Order Detail',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
        children: [
          _ReportCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: roleColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.receipt_long_outlined,
                        color: roleColor,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            order.customerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            DateFormat('d MMM yyyy - h:mm a')
                                .format(order.displayAt),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _muted,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _RoleBadge(
                      label: record.role,
                      color: roleColor,
                      compact: true,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _OrderDetailMetric(
                        label: 'Order',
                        value: _money(order.totalAmount),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _OrderDetailMetric(
                        label: 'Commission',
                        value: _money(record.commission),
                        color: roleColor,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _ReportCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                _DetailRow(
                  icon: Icons.person_outline_rounded,
                  label: 'Customer',
                  value: order.customerName,
                ),
                _DetailRow(
                  icon: Icons.wallet_outlined,
                  label: 'Payment',
                  value: _paymentLabel(order.paymentMethod),
                ),
                _DetailRow(
                  icon: Icons.work_outline_rounded,
                  label: 'Staff Role',
                  value: record.role,
                  valueColor: roleColor,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          _ReportCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Services',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                if (order.serviceItems.isEmpty)
                  const Text(
                    'Service',
                    style: TextStyle(
                      color: _muted,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                else
                  for (final item in order.serviceItems) ...[
                    _ServiceDetailLine(item: item),
                    if (item != order.serviceItems.last)
                      const SizedBox(height: 8),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderDetailMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _OrderDetailMetric({
    required this.label,
    required this.value,
    this.color = _ink,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: _muted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _StaffOrderDetailDialog extends StatelessWidget {
  final _StaffOrderRecord record;

  const _StaffOrderDetailDialog({required this.record});

  @override
  Widget build(BuildContext context) {
    final order = record.order;
    final roleColor = record.role.contains('Counter') ? _rose : _violet;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: roleColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.receipt_long_outlined,
                        color: roleColor,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            order.customerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            DateFormat('EEEE, d MMM yyyy - h:mm a')
                                .format(order.displayAt),
                            style: const TextStyle(
                              color: _muted,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                _DetailRow(
                  icon: Icons.person_outline_rounded,
                  label: 'Customer',
                  value: order.customerName,
                ),
                _DetailRow(
                  icon: Icons.work_outline_rounded,
                  label: 'Staff Role',
                  value: record.role,
                  valueColor: roleColor,
                ),
                _DetailRow(
                  icon: Icons.wallet_outlined,
                  label: 'Payment',
                  value: _paymentLabel(order.paymentMethod),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Services',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                if (order.serviceItems.isEmpty)
                  const Text(
                    'Service',
                    style: TextStyle(
                      color: _muted,
                      fontWeight: FontWeight.w700,
                    ),
                  )
                else
                  for (final item in order.serviceItems) ...[
                    _ServiceDetailLine(item: item),
                    if (item != order.serviceItems.last)
                      const SizedBox(height: 8),
                  ],
                const SizedBox(height: 18),
                const Divider(height: 1, color: _line),
                const SizedBox(height: 16),
                _AmountLine(
                  label: 'Order Total',
                  value: _money(order.totalAmount),
                ),
                const SizedBox(height: 10),
                _AmountLine(
                  label: 'Commission',
                  value: _money(record.commission),
                  color: roleColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color valueColor;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor = _ink,
  });

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: _muted, size: 20),
          SizedBox(width: phone ? 8 : 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(
                    color: valueColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceDetailLine extends StatelessWidget {
  final _ReportServiceItem item;

  const _ServiceDetailLine({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          _SoftIcon(icon: Icons.spa_outlined, color: _teal, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${item.duration} min',
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Text(
            _money(item.price),
            style: const TextStyle(
              color: _teal,
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _AmountLine extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _AmountLine({
    required this.label,
    required this.value,
    this.color = _ink,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: _muted,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 18,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _MiniInfoPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _MiniInfoPill({
    required this.icon,
    required this.label,
    this.color = _muted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _StaffOrderRecord {
  final _ReportOrder order;
  final String role;
  final double commission;

  const _StaffOrderRecord({
    required this.order,
    required this.role,
    required this.commission,
  });

  String get serviceName {
    if (order.serviceItems.isEmpty) return 'Service';
    return order.serviceItems.map((item) => item.name).join(', ');
  }
}

List<_StaffOrderRecord> _recordsForStaff({
  required _StaffCommission staff,
  required List<_ReportOrder> orders,
  required Map<String, Map<String, dynamic>> services,
  required Map<String, Map<String, dynamic>> staffById,
}) {
  final records = <_StaffOrderRecord>[];
  for (final order in orders) {
    if (!order.isServiceCompleted) continue;
    var commission = 0.0;
    final roles = <String>[];
    final assignedItems = order.serviceItems.where((item) {
      final itemStaffId = _resolvedOrderStaffId(
        staffById,
        item.assignedTherapistId,
        item.assignedTherapistName,
      );
      return itemStaffId == staff.id ||
          _sameLookupValue(item.assignedTherapistName, staff.name);
    }).toList();
    final therapistMatches =
        order.therapistId == staff.id ||
        _sameLookupValue(order.therapistName, staff.name);
    final counterMatches =
        order.counterStaffId == staff.id ||
        _sameLookupValue(order.counterStaffName, staff.name);

    if (staff.id == _counterPoolId) {
      commission += _counterPoolCommissionForOrder(order, services);
      if (commission > 0) roles.add('Counter Commission');
    } else {
      final storedAllocations = order.therapistAllocations.where(
        (allocation) =>
            _asString(
              allocation['therapistId'] ?? allocation['therapist_id'],
            ) ==
            staff.id,
      );
      if (storedAllocations.isNotEmpty) {
        commission += storedAllocations.fold<double>(
          0,
          (total, allocation) =>
              total +
              _asDouble(
                allocation['commissionAmount'] ??
                    allocation['commission_amount'],
              ),
        );
        roles.add('Therapist');
      } else if (order.therapistAllocations.isEmpty &&
          assignedItems.isNotEmpty) {
        for (final item in assignedItems) {
          commission += _commissionForItem(
            item,
            service: services[item.id] ?? <String, dynamic>{},
            staff: staffById[staff.id] ?? <String, dynamic>{},
            staffRole: staff.role,
          );
        }
        roles.add('Therapist');
      } else if (order.therapistAllocations.isEmpty && therapistMatches) {
        commission += _therapistCommissionForOrder(
          order,
          services,
          staffById,
          matchedStaff: staff,
        );
        roles.add('Therapist');
      }
      if (counterMatches) {
        commission += _counterCommissionForOrder(
          order,
          services,
          staffById,
          matchedStaff: staff,
        );
        roles.add('Counter');
      }
    }

    if (roles.isEmpty) continue;
    records.add(
      _StaffOrderRecord(
        order: order,
        role: roles.join(' + '),
        commission: commission,
      ),
    );
  }
  records.sort((a, b) => b.order.displayAt.compareTo(a.order.displayAt));
  return records;
}

double _therapistCommissionForOrder(
  _ReportOrder order,
  Map<String, Map<String, dynamic>> services,
  Map<String, Map<String, dynamic>> staffById,
  {
  _StaffCommission? matchedStaff,
}) {
  if (order.therapistCommissionAmount > 0) {
    return order.therapistCommissionAmount;
  }
  final resolvedId = matchedStaff == null
      ? order.therapistId
      : _resolvedOrderStaffId(
          staffById,
          order.therapistId,
          matchedStaff.name,
        );
  final staff = staffById[resolvedId] ?? <String, dynamic>{};
  final role = _normalizeRole(staff['role'] ?? staff['employmentType']);
  return order.serviceItems.fold<double>(0, (total, item) {
    return total +
        _commissionForItem(
          item,
          service: services[item.id] ?? <String, dynamic>{},
          staff: staff,
          staffRole: role,
        );
  });
}

double _counterCommissionForOrder(
  _ReportOrder order,
  Map<String, Map<String, dynamic>> services,
  Map<String, Map<String, dynamic>> staffById,
  {
  _StaffCommission? matchedStaff,
}) {
  if (order.counterCommissionAmount > 0) {
    return order.counterCommissionAmount;
  }
  final resolvedId = matchedStaff == null
      ? order.counterStaffId
      : _resolvedOrderStaffId(
          staffById,
          order.counterStaffId,
          matchedStaff.name,
        );
  final staff = staffById[resolvedId] ?? <String, dynamic>{};
  return order.serviceItems.fold<double>(0, (total, item) {
    return total +
        _commissionForItem(
          item,
          service: services[item.id] ?? <String, dynamic>{},
          staff: staff,
          staffRole: 'Counter',
        );
  });
}

double _counterPoolCommissionForOrder(
  _ReportOrder order,
  Map<String, Map<String, dynamic>> services,
) {
  if (order.counterStaffId.isNotEmpty) return 0;
  return order.counterCommissionAmount;
}

class _PaymentBreakdownCard extends StatelessWidget {
  final _ReportData data;
  final bool loading;

  const _PaymentBreakdownCard({required this.data, required this.loading});

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    final maxAmount = data.paymentSales.fold<double>(
      0,
      (maxValue, item) => math.max(maxValue, item.amount),
    );

    return _ReportCard(
      padding: EdgeInsets.all(phone ? 12 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(
            title: 'Payment Breakdown',
            subtitle: 'Collection by method',
            icon: Icons.account_balance_wallet_outlined,
            color: _green,
          ),
          SizedBox(height: phone ? 10 : 16),
          if (loading)
            const _ListSkeleton(rows: 3)
          else if (data.paymentSales.isEmpty)
            const _EmptyState(
              icon: Icons.account_balance_wallet_outlined,
              title: 'No payment data',
            )
          else
            for (var index = 0; index < data.paymentSales.length; index++) ...[
              _PaymentBreakdownRow(
                item: data.paymentSales[index],
                maxAmount: maxAmount,
              ),
              if (index != data.paymentSales.length - 1)
                SizedBox(height: phone ? 8 : 12),
            ],
        ],
      ),
    );
  }
}

class _PaymentBreakdownRow extends StatelessWidget {
  final _BreakdownSlice item;
  final double maxAmount;

  const _PaymentBreakdownRow({
    required this.item,
    required this.maxAmount,
  });

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    final progress = maxAmount <= 0 ? 0.0 : item.amount / maxAmount;
    return Row(
      children: [
        SizedBox(
          width: phone ? 70 : 92,
          child: Row(
            children: [
              Container(
                width: phone ? 7 : 9,
                height: phone ? 7 : 9,
                decoration:
                    BoxDecoration(color: item.color, shape: BoxShape.circle),
              ),
              SizedBox(width: phone ? 5 : 8),
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w900,
                    fontSize: phone ? 10 : 12,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: phone ? 8 : 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress.clamp(0, 1),
              minHeight: phone ? 6 : 9,
              backgroundColor: _line,
              valueColor: AlwaysStoppedAnimation<Color>(item.color),
            ),
          ),
        ),
        SizedBox(width: phone ? 8 : 12),
        SizedBox(
          width: phone ? 82 : 120,
          child: Text(
            '${_money(item.amount)}  ${item.count}x',
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _muted,
              fontWeight: FontWeight.w800,
              fontSize: phone ? 10 : 12,
            ),
          ),
        ),
      ],
    );
  }
}

class _CardTitle extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;

  const _CardTitle({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.of(context).size.width < 600;
    return Row(
      children: [
        _SoftIcon(icon: icon, color: color, size: phone ? 32 : 40),
        SizedBox(width: phone ? 8 : 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _ink,
                  fontWeight: FontWeight.w900,
                  fontSize: phone ? 15 : 16,
                ),
              ),
              SizedBox(height: phone ? 2 : 3),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _muted,
                  fontWeight: FontWeight.w700,
                  fontSize: phone ? 12 : 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SoftIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const _SoftIcon({
    required this.icon,
    required this.color,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: color, size: size * 0.52),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _ReportCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return _ReportCard(
      child: Row(
        children: [
          _SoftIcon(icon: Icons.error_outline_rounded, color: _rose),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Retry'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _rose,
              side: const BorderSide(color: _rose),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;

  const _EmptyState({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SoftIcon(icon: icon, color: _muted, size: 44),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _muted,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChartSkeleton extends StatelessWidget {
  const _ChartSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var index = 0; index < 5; index++) ...[
          Expanded(
            child: Align(
              alignment: Alignment.center,
              child: Container(
                height: 10,
                decoration: BoxDecoration(
                  color: _line.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
          if (index != 4) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _ListSkeleton extends StatelessWidget {
  final int rows;

  const _ListSkeleton({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var index = 0; index < rows; index++) ...[
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _line,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  children: [
                    Container(
                      height: 10,
                      decoration: BoxDecoration(
                        color: _line,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 8,
                      margin: const EdgeInsets.only(right: 80),
                      decoration: BoxDecoration(
                        color: _line.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (index != rows - 1) const SizedBox(height: 14),
        ],
      ],
    );
  }
}
