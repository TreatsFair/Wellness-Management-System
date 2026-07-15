import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/appointment_repository.dart';
import '../../data/repositories/commission_repository.dart';
import '../../data/repositories/customer_repository.dart';
import '../../data/repositories/dashboard_repository.dart';
import '../../data/repositories/transaction_repository.dart';

const _teal = Color(0xFF1B6B72);
const _ink = Color(0xFF1A1A2E);
const _muted = Color(0xFF6B7280);
const _page = Color(0xFFF4F5F7);
const _line = Color(0xFFE5E7EB);

DateTime _stripDate(DateTime date) => DateTime(date.year, date.month, date.day);

bool _sameDay(DateTime left, DateTime right) =>
    _stripDate(left) == _stripDate(right);

String _asString(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  final text = value.toString();
  return text.trim().isEmpty ? fallback : text;
}

String _normalizeStaffName(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

double _asDouble(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

List<Map<String, dynamic>> _asMapList(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => item.map((key, value) => MapEntry(key.toString(), value)))
      .toList();
}

// Postgres timestamptz values (created_at, actual_completed_at, ...) arrive as
// ISO strings with an offset, which DateTime.parse reads as UTC. Convert to the
// device's local (Malaysia) zone so bill times display in KL and the two-axis
// day bucketing compares against the same local calendar day. Naive timestamps
// (e.g. start_at) parse as local already, so toLocal() is a harmless no-op there.
DateTime _asDateTime(Object? value) {
  if (value is DateTime) return value.toLocal();
  if (value is String) {
    return (DateTime.tryParse(value) ?? DateTime.now()).toLocal();
  }
  return DateTime.now();
}

DateTime? _tryDateTime(Object? value) {
  if (value is DateTime) return value.toLocal();
  if (value is String) return DateTime.tryParse(value)?.toLocal();
  return null;
}

DateTime? _historyServiceCompletedAt({
  required Map<String, dynamic> appointment,
  required List<Map<String, dynamic>> groupAppointments,
  required DateTime? fallback,
}) {
  if (appointment.isNotEmpty) return _tryDateTime(appointment['actualCompletedAt']);
  if (groupAppointments.isEmpty) return fallback;

  DateTime? latest;
  for (final item in groupAppointments) {
    final status = _asString(item['status']).toLowerCase();
    if (status == 'cancelled' || status == 'canceled' || status == 'no_show') {
      continue;
    }
    final completedAt = _tryDateTime(item['actualCompletedAt']);
    if (completedAt == null) return null;
    if (latest == null || completedAt.isAfter(latest)) latest = completedAt;
  }
  return latest;
}

String _normalizeOrderSource({
  required Object? txSource,
  required Object? appointmentType,
  required String appointmentId,
  required String appointmentGroupId,
}) {
  final source = _asString(txSource).trim().toLowerCase();
  if (source == 'walkin' || source == 'walk-in') return 'walkin';
  if (source == 'appointment' || source == 'booking') return 'appointment';
  if (source == 'online' || source == 'online_booking') return 'online';

  final type = _asString(appointmentType).trim().toLowerCase();
  if (type == 'walkin' || type == 'walk-in') return 'walkin';
  if (type == 'appointment' || type.isEmpty && appointmentId.isNotEmpty) {
    return 'appointment';
  }

  if (appointmentGroupId.isNotEmpty && appointmentId.isEmpty) return 'walkin';
  return 'walkin';
}

enum _HistoryPane { bill, services, customers, staff }

class SalesHistoryScreen extends StatefulWidget {
  final String userRole;

  const SalesHistoryScreen({super.key, required this.userRole});

  @override
  State<SalesHistoryScreen> createState() => _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends State<SalesHistoryScreen> {
  final _dashboardRepository = DashboardRepository();
  final _transactionRepository = TransactionRepository();
  final _appointmentRepository = AppointmentRepository();
  DateTime _selectedDate = _stripDate(DateTime.now());
  List<_HistoryOrder> _orders = [];
  _HistorySummary _summary = _HistorySummary.empty;
  Map<String, Map<String, dynamic>> _therapists = {};
  _HistoryPane _activePane = _HistoryPane.bill;
  bool _loading = true;
  String? _error;
  bool _showOrdersOnPhone = false;

  bool get _isAdmin => widget.userRole.toLowerCase().trim() == 'admin';
  bool get _canGoNextDay => _selectedDate.isBefore(_stripDate(DateTime.now()));

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<Map<String, Map<String, dynamic>>> _loadDocMap(
    String collection,
    Iterable<String> ids,
  ) async {
    return _dashboardRepository.loadByIds(collection, ids);
  }

  Future<void> _loadHistory() async {
    setState(() {
      _loading = true;
      _error = null;
      if (!_isAdmin) _selectedDate = _stripDate(DateTime.now());
    });

    try {
      await _appointmentRepository.completeDueAppointments();
      final transactionRows = await _transactionRepository.listTransactions();

      final transactionDocs = transactionRows.where((row) {
        final status = _asString(row['paymentStatus']).toLowerCase();
        return status.isEmpty || status == 'paid' || status == 'voided';
      }).toList();

      final transactionData = transactionDocs;
      final appointmentIds = transactionData
          .map((d) => _asString(d['appointmentId']))
          .where((id) => id.isNotEmpty);
      final appointmentGroupIds = transactionData
          .map((d) => _asString(d['appointmentGroupId']))
          .where((id) => id.isNotEmpty)
          .toSet();
      final customerIds = transactionData
          .map((d) => _asString(d['customerId']))
          .where((id) => id.isNotEmpty);

      final appointments = await _loadDocMap('appointments', appointmentIds);
      final groupAppointmentRows = await _dashboardRepository.loadWhereIn(
        'appointments',
        'appointment_group_id',
        appointmentGroupIds.cast<Object>(),
      );
      final appointmentsByGroup = <String, List<Map<String, dynamic>>>{};
      for (final appointment in groupAppointmentRows) {
        final groupId = _asString(appointment['appointmentGroupId']);
        if (groupId.isEmpty) continue;
        appointmentsByGroup.putIfAbsent(groupId, () => []).add(appointment);
      }
      final allocationRows = await _appointmentRepository
          .therapistAllocationsForAppointments([
            ...appointments.keys,
            ...groupAppointmentRows.map((row) => _asString(row['id'])),
          ]);
      final allocationsByAppointment =
          <String, List<Map<String, dynamic>>>{};
      for (final allocation in allocationRows) {
        final appointmentId = _asString(
          allocation['appointmentId'] ?? allocation['appointment_id'],
        );
        if (appointmentId.isEmpty) continue;
        allocationsByAppointment
            .putIfAbsent(appointmentId, () => [])
            .add(allocation);
      }
      final linkedCustomerIds = appointments.values
          .map((d) => _asString(d['customerId']))
          .where((id) => id.isNotEmpty);
      final groupCustomerIds = groupAppointmentRows
          .map((d) => _asString(d['customerId']))
          .where((id) => id.isNotEmpty);
      final serviceIds = [
        ...transactionData.map((d) => _asString(d['serviceId'])),
        ...appointments.values.map((d) => _asString(d['serviceId'])),
        ...groupAppointmentRows.map((d) => _asString(d['serviceId'])),
        ...transactionData.expand(
          (d) => _asMapList(
            d['serviceItems'] ?? d['service_items'] ?? d['items'],
          ).map((item) => _asString(item['id'], _asString(item['serviceId']))),
        ),
      ].where((id) => id.isNotEmpty);
      final roomIds = [
        ...transactionData.map((d) => _asString(d['roomId'])),
        ...appointments.values.map((d) => _asString(d['roomId'])),
        ...groupAppointmentRows.map((d) => _asString(d['roomId'])),
      ].where((id) => id.isNotEmpty);

      final customers = await _loadDocMap('customers', [
        ...customerIds,
        ...linkedCustomerIds,
        ...groupCustomerIds,
      ]);
      final services = await _loadDocMap('services', serviceIds);
      final therapistRows = await _dashboardRepository.listTherapists();
      final therapists = {
        for (final therapist in therapistRows)
          _asString(therapist['id']): therapist,
      }..remove('');
      final rooms = await _loadDocMap('rooms', roomIds);

      final orders = transactionDocs
          .map(
            (transaction) => _HistoryOrder.fromTransaction(
              transaction,
              appointments: appointments,
              appointmentsByGroup: appointmentsByGroup,
              customers: customers,
              services: services,
              therapists: therapists,
              rooms: rooms,
              allocationsByAppointment: allocationsByAppointment,
            ),
          )
          .where(
            (order) =>
                _sameDay(order.paidAt, _selectedDate) ||
                (order.serviceCompletedAt != null &&
                    _sameDay(order.serviceCompletedAt!, _selectedDate)),
          )
          .toList()
        ..sort((a, b) => b.displayAt.compareTo(a.displayAt));

      if (!mounted) return;
      setState(() {
        _orders = orders;
        _summary = _HistorySummary.fromOrders(orders, _selectedDate);
        _therapists = therapists;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _orders = [];
        _summary = _HistorySummary.empty;
        _therapists = {};
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _openDatePicker() async {
    if (!_isAdmin) return;
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (context) => _HistoryCalendarDialog(initialDate: _selectedDate),
    );
    if (picked == null) return;
    final today = _stripDate(DateTime.now());
    final cleanPicked = _stripDate(picked);
    setState(() {
      _selectedDate = cleanPicked.isAfter(today) ? today : cleanPicked;
    });
    await _loadHistory();
  }

  Future<void> _moveDate(int days) async {
    if (!_isAdmin) return;
    final nextDate = _selectedDate.add(Duration(days: days));
    final today = _stripDate(DateTime.now());
    setState(() {
      _selectedDate = nextDate.isAfter(today) ? today : nextDate;
    });
    await _loadHistory();
  }

  void _openServicesBreakdown() {
    if (MediaQuery.of(context).size.width >= 900) {
      setState(() => _activePane = _HistoryPane.services);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _ServicesBreakdownScreen(
          selectedDate: _selectedDate,
          orders: _orders,
        ),
      ),
    );
  }

  void _openCustomerBreakdown() {
    if (MediaQuery.of(context).size.width >= 900) {
      setState(() => _activePane = _HistoryPane.customers);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _CustomerBreakdownScreen(
          selectedDate: _selectedDate,
          orders: _orders,
        ),
      ),
    );
  }

  void _openStaffCommission() {
    if (MediaQuery.of(context).size.width >= 900) {
      setState(() => _activePane = _HistoryPane.staff);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _StaffCommissionScreen(
          selectedDate: _selectedDate,
          orders: _orders,
          therapists: _therapists,
          onTapOrder: _openOrderDetail,
        ),
      ),
    );
  }

  void _openBillList() {
    if (MediaQuery.of(context).size.width >= 900) {
      setState(() => _activePane = _HistoryPane.bill);
      return;
    }
    setState(() => _showOrdersOnPhone = true);
  }

  void _openOrderDetail(_HistoryOrder order) {
    _showDetailDrawer(
      context: context,
      title: 'Bill Details',
      child: _OrderDetailSheet(
        order: order,
        isAdmin: _isAdmin,
        onVoid: () => _voidOrder(order),
        onEditTherapists: () => _editTherapistAllocations(order),
      ),
    );
  }

  Future<void> _editTherapistAllocations(_HistoryOrder order) async {
    final appointmentIds = order.linkedAppointmentIds;
    if (!_isAdmin || appointmentIds.isEmpty) return;
    var appointmentId = appointmentIds.first;
    if (appointmentIds.length > 1) {
      final selected = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Select service'),
          children: [
            for (var index = 0; index < appointmentIds.length; index++)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, appointmentIds[index]),
                child: Text('Pax ${index + 1} service'),
              ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      appointmentId = selected;
    }

    final existing = await _appointmentRepository.therapistAllocations(
      appointmentId,
    );
    if (!mounted) return;
    final saved = await showDialog<_TherapistAllocationEdit>(
      context: context,
      builder: (context) => _TherapistAllocationDialog(
        therapists: _therapists,
        existing: existing,
      ),
    );
    if (saved == null || !mounted) return;
    try {
      await _appointmentRepository.setCompletedTherapistAllocations(
        appointmentId: appointmentId,
        allocations: saved.allocations,
        reason: saved.reason,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      await _loadHistory();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Therapist commission updated')),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to update commission: $error')),
        );
      }
    }
  }

  Future<void> _voidOrder(_HistoryOrder order) async {
    if (!_isAdmin) return;
    if (order.isVoided) return;

    final firstConfirm = await _confirmVoidOrder(
      title: 'Void this bill?',
      message:
          'This will mark ${order.receiptNumber} as voided and remove it from paid totals.',
      actionLabel: 'Continue',
    );
    if (firstConfirm != true || !mounted) return;

    final finalConfirm = await _confirmVoidOrder(
      title: 'Confirm void bill',
      message:
          'This action cannot be undone. The bill card will remain as voided for audit history.',
      actionLabel: 'Void Bill',
      destructive: true,
    );
    if (finalConfirm != true || !mounted) return;

    try {
      await _transactionRepository.updateTransaction(order.id, {
        'paymentStatus': 'voided',
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      if (order.appointmentGroupId.isNotEmpty) {
        await _appointmentRepository.voidAppointmentGroup(
          order.appointmentGroupId,
        );
      } else if (order.appointmentId.isNotEmpty) {
        await _appointmentRepository.voidAppointment(order.appointmentId);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      await _loadHistory();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${order.receiptNumber} voided'),
          backgroundColor: _teal,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to void bill: $e'),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<bool?> _confirmVoidOrder({
    required String title,
    required String message,
    required String actionLabel,
    bool destructive = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: destructive
                    ? const Color(0xFFE53935)
                    : _teal,
                foregroundColor: Colors.white,
              ),
              child: Text(actionLabel),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width >= 900;
    return Scaffold(
      backgroundColor: _page,
      body: SafeArea(
        child: isTablet
            ? _buildTablet()
            : _showOrdersOnPhone
            ? _buildPhoneOrders()
            : _buildPhoneSummary(),
      ),
    );
  }

  Widget _buildTablet() {
    return Row(
      children: [
        SizedBox(
          width: 292,
          child: _HistorySidePanel(
            selectedDate: _selectedDate,
            summary: _summary,
            loading: _loading,
            isAdmin: _isAdmin,
            selectedPane: _activePane,
            onBack: () => Navigator.pop(context),
            onPickDate: _openDatePicker,
            onPreviousDate: () => _moveDate(-1),
            onNextDate: () => _moveDate(1),
            canGoNextDate: _canGoNextDay,
            onOpenOrders: _openBillList,
            onOpenServices: _openServicesBreakdown,
            onOpenCustomers: _openCustomerBreakdown,
            onOpenStaff: _openStaffCommission,
          ),
        ),
        const VerticalDivider(width: 1, color: _line),
        Expanded(child: _buildActivePane()),
      ],
    );
  }

  Widget _buildActivePane() {
    switch (_activePane) {
      case _HistoryPane.services:
        return _ServicesBreakdownScreen(
          selectedDate: _selectedDate,
          orders: _orders,
          embedded: true,
        );
      case _HistoryPane.customers:
        return _CustomerBreakdownScreen(
          selectedDate: _selectedDate,
          orders: _orders,
          embedded: true,
        );
      case _HistoryPane.staff:
        return _StaffCommissionScreen(
          selectedDate: _selectedDate,
          orders: _orders,
          therapists: _therapists,
          onTapOrder: _openOrderDetail,
          embedded: true,
        );
      case _HistoryPane.bill:
        return _HistoryOrderPane(
          selectedDate: _selectedDate,
          orders: _orders,
          summary: _summary,
          loading: _loading,
          error: _error,
          onRefresh: _loadHistory,
          onTapOrder: _openOrderDetail,
        );
    }
  }

  Widget _buildPhoneSummary() {
    return _HistorySidePanel(
      selectedDate: _selectedDate,
      summary: _summary,
      loading: _loading,
      isAdmin: _isAdmin,
      selectedPane: _HistoryPane.bill,
      onBack: () => Navigator.pop(context),
      onPickDate: _openDatePicker,
      onPreviousDate: () => _moveDate(-1),
      onNextDate: () => _moveDate(1),
      canGoNextDate: _canGoNextDay,
      onOpenOrders: _openBillList,
      onOpenServices: _openServicesBreakdown,
      onOpenCustomers: _openCustomerBreakdown,
      onOpenStaff: _openStaffCommission,
    );
  }

  Widget _buildPhoneOrders() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(4, 10, 16, 12),
          color: Colors.white,
          child: Row(
            children: [
              BackButton(
                color: _teal,
                onPressed: () => setState(() => _showOrdersOnPhone = false),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Bill History',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      DateFormat('EEE, d MMM yyyy').format(_selectedDate),
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              _IconAction(
                icon: Icons.refresh,
                tooltip: 'Refresh history',
                onTap: _loadHistory,
              ),
            ],
          ),
        ),
        Expanded(
          child: _HistoryOrderPane(
            selectedDate: _selectedDate,
            orders: _orders,
            summary: _summary,
            loading: _loading,
            error: _error,
            onRefresh: _loadHistory,
            onTapOrder: _openOrderDetail,
            compact: true,
          ),
        ),
      ],
    );
  }
}

class _HistoryOrder {
  final String id;
  final String receiptNumber;
  final String appointmentId;
  final String appointmentGroupId;
  final List<String> linkedAppointmentIds;
  final String source;
  final String customerId;
  final String customerName;
  final String customerPhone;
  final String serviceName;
  final String therapistId;
  final String therapistName;
  final String roomName;
  final String paymentMethod;
  final String paymentStatus;
  final int itemCount;
  final List<_HistoryServiceGroup> serviceGroups;
  final List<Map<String, dynamic>> rawServiceItems;
  final List<Map<String, dynamic>> therapistAllocations;
  final double servicePrice;
  final double sstAmount;
  final double totalAmount;
  final double therapistCommissionAmount;
  final double counterCommissionAmount;
  final DateTime paidAt;
  final DateTime? serviceCompletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const _HistoryOrder({
    required this.id,
    required this.receiptNumber,
    required this.appointmentId,
    required this.appointmentGroupId,
    required this.linkedAppointmentIds,
    required this.source,
    required this.customerId,
    required this.customerName,
    required this.customerPhone,
    required this.serviceName,
    required this.therapistId,
    required this.therapistName,
    required this.roomName,
    required this.paymentMethod,
    required this.paymentStatus,
    required this.itemCount,
    required this.serviceGroups,
    required this.rawServiceItems,
    required this.therapistAllocations,
    required this.servicePrice,
    required this.sstAmount,
    required this.totalAmount,
    required this.therapistCommissionAmount,
    required this.counterCommissionAmount,
    required this.paidAt,
    required this.serviceCompletedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory _HistoryOrder.fromTransaction(
    Map<String, dynamic> tx, {
    required Map<String, Map<String, dynamic>> appointments,
    required Map<String, List<Map<String, dynamic>>> appointmentsByGroup,
    required Map<String, Map<String, dynamic>> customers,
    required Map<String, Map<String, dynamic>> services,
    required Map<String, Map<String, dynamic>> therapists,
    required Map<String, Map<String, dynamic>> rooms,
    required Map<String, List<Map<String, dynamic>>>
        allocationsByAppointment,
  }) {
    final appointmentId = _asString(tx['appointmentId']);
    final appointmentGroupId = _asString(tx['appointmentGroupId']);
    final appointment = appointments[appointmentId] ?? {};
    final groupAppointments = appointmentsByGroup[appointmentGroupId] ?? const [];
    final hasLinkedAppointment =
        appointment.isNotEmpty || groupAppointments.isNotEmpty;
    final paidAt = _tryDateTime(tx['paidAt']) ?? _asDateTime(tx['createdAt']);
    final serviceCompletedAt = _historyServiceCompletedAt(
      appointment: appointment,
      groupAppointments: groupAppointments,
      fallback: hasLinkedAppointment ? null : paidAt,
    );
    final source = _normalizeOrderSource(
      txSource: tx['source'],
      appointmentType: appointment['type'],
      appointmentId: appointmentId,
      appointmentGroupId: appointmentGroupId,
    );
    final customerId = _asString(tx['customerId']).isNotEmpty
        ? _asString(tx['customerId'])
        : _asString(appointment['customerId']);
    final customer = customers[customerId] ?? {};
    final serviceId = _asString(tx['serviceId']).isNotEmpty
        ? _asString(tx['serviceId'])
        : _asString(appointment['serviceId']);
    final therapistId = _asString(appointment['therapistId']).isNotEmpty
        ? _asString(appointment['therapistId'])
        : _asString(tx['therapistId']);
    final roomId = _asString(tx['roomId']).isNotEmpty
        ? _asString(tx['roomId'])
        : _asString(appointment['roomId']);
    final service = services[serviceId] ?? {};
    final therapist = therapists[therapistId] ?? {};
    final room = rooms[roomId] ?? {};
    final rawItems =
        _asMapList(tx['serviceItems'] ?? tx['service_items'] ?? tx['items'])
            .map((item) {
              final itemId = _asString(
                item['id'],
                _asString(item['serviceId']),
              );
              final linkedService = services[itemId] ?? {};
              return {
                ...linkedService,
                ...item,
                'id': itemId.isEmpty
                    ? _asString(item['name'], _asString(linkedService['id']))
                    : itemId,
                'name': _asString(
                  item['name'],
                  _asString(linkedService['name'], 'Service'),
                ),
                'category': _asString(
                  item['category'],
                  _asString(linkedService['category'], 'Services'),
                ),
                'imageUrl': _asString(
                  item['imageUrl'],
                  _asString(
                    item['image'],
                    _asString(
                      linkedService['imageUrl'],
                      _asString(linkedService['image']),
                    ),
                  ),
                ),
                'assignedTherapistId': _asString(
                  item['assignedTherapistId'],
                  therapistId,
                ),
                'assignedTherapistName': _asString(
                  item['assignedTherapistName'],
                  _asString(therapist['name'], _asString(tx['therapistName'])),
                ),
                'assignedRoomId': _asString(item['assignedRoomId'], roomId),
                'assignedRoomName': _asString(
                  item['assignedRoomName'],
                  _asString(room['name'], _asString(tx['roomName'])),
                ),
              };
            })
            .toList();
    final itemCount = rawItems.isNotEmpty
        ? rawItems.length
        : _asInt(tx['itemCount'], 1);
    final servicePrice = _asDouble(
      tx['servicePrice'],
      _asDouble(appointment['totalPrice']),
    );
    final customerName = _asString(
      tx['customerName'],
      _asString(customer['name'], 'Guest'),
    );
    final customerPhone = _asString(
      tx['customerPhone'],
      _asString(customer['phone'], '-'),
    );
    final serviceName = _asString(
      tx['serviceName'],
      _asString(service['name'], 'Service'),
    );
    final therapistName = _asString(
      therapist['name'],
      _asString(tx['therapistName'], '-'),
    );
    final roomName = _asString(tx['roomName'], _asString(room['name'], '-'));
    final baseServiceGroups = _HistoryServiceGroup.fromItems(
      rawItems,
      fallbackCustomerName: customerName,
      fallbackServiceName: serviceName,
      fallbackTherapistName: therapistName,
      fallbackRoomName: roomName,
      fallbackAmount: servicePrice,
    );
    final linkedAppointmentRows = appointmentId.isNotEmpty
        ? [appointment]
        : List<Map<String, dynamic>>.from(groupAppointments)
      ..sort((left, right) {
        final leftCreated = _tryDateTime(
          left['createdAt'] ?? left['created_at'],
        );
        final rightCreated = _tryDateTime(
          right['createdAt'] ?? right['created_at'],
        );
        return (leftCreated ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(rightCreated ?? DateTime.fromMillisecondsSinceEpoch(0));
      });
    final serviceGroups = <_HistoryServiceGroup>[];
    for (var index = 0; index < baseServiceGroups.length; index++) {
      final baseGroup = baseServiceGroups[index];
      if (index >= linkedAppointmentRows.length) {
        serviceGroups.add(baseGroup);
        continue;
      }
      final linkedAppointment = linkedAppointmentRows[index];
      final linkedId = _asString(linkedAppointment['id']);
      final allocationRows = List<Map<String, dynamic>>.from(
        allocationsByAppointment[linkedId] ?? const [],
      )..sort((left, right) {
          final leftCreated = _tryDateTime(
            left['createdAt'] ?? left['created_at'],
          );
          final rightCreated = _tryDateTime(
            right['createdAt'] ?? right['created_at'],
          );
          return (leftCreated ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(
                rightCreated ?? DateTime.fromMillisecondsSinceEpoch(0),
              );
        });
      final allocationNames = <String>[];
      for (final allocation in allocationRows) {
        final share = _asDouble(
          allocation['commissionShare'] ?? allocation['commission_share'],
        );
        if (share <= 0) continue;
        final allocationTherapistId = _asString(
          allocation['therapistId'] ?? allocation['therapist_id'],
        );
        final name = _asString(therapists[allocationTherapistId]?['name']);
        if (name.isNotEmpty && !allocationNames.contains(name)) {
          allocationNames.add(name);
        }
      }
      if (allocationNames.isEmpty) {
        final currentTherapistId = _asString(
          linkedAppointment['therapistId'],
        );
        final currentName = _asString(
          therapists[currentTherapistId]?['name'],
          baseGroup.therapistName,
        );
        if (currentName.isNotEmpty) allocationNames.add(currentName);
      }
      serviceGroups.add(
        baseGroup.copyWithTherapistNames(allocationNames),
      );
    }

    return _HistoryOrder(
      id: _asString(tx['id']),
      receiptNumber: _asString(tx['receiptNumber'], _asString(tx['id'])),
      appointmentId: appointmentId,
      appointmentGroupId: appointmentGroupId,
      linkedAppointmentIds: appointmentId.isNotEmpty
          ? [appointmentId]
          : groupAppointments
              .map((item) => _asString(item['id']))
              .where((id) => id.isNotEmpty)
              .toList(),
      source: source,
      customerId: customerId,
      customerName: customerName,
      customerPhone: customerPhone,
      serviceName: serviceName,
      therapistId: therapistId,
      therapistName: therapistName,
      roomName: roomName,
      paymentMethod: _asString(tx['paymentMethod'], 'unknown'),
      paymentStatus: _asString(tx['paymentStatus'], 'paid').toLowerCase(),
      itemCount: itemCount <= 0 ? 1 : itemCount,
      serviceGroups: serviceGroups,
      rawServiceItems: rawItems,
      therapistAllocations: [
        if (appointmentId.isNotEmpty)
          ...(allocationsByAppointment[appointmentId] ?? const []),
        for (final item in groupAppointments)
          ...(allocationsByAppointment[_asString(item['id'])] ?? const []),
      ],
      servicePrice: servicePrice,
      sstAmount: _asDouble(tx['sstAmount']),
      totalAmount: _asDouble(
        tx['totalAmount'],
        _asDouble(appointment['totalPrice']),
      ),
      therapistCommissionAmount: _asDouble(tx['therapistCommissionAmount']),
      counterCommissionAmount: _asDouble(tx['counterCommissionAmount']),
      paidAt: paidAt,
      serviceCompletedAt: serviceCompletedAt,
      createdAt: paidAt,
      updatedAt: _asDateTime(tx['updatedAt'] ?? tx['createdAt']),
    );
  }

  bool get isAppointmentBooking => source == 'appointment' || source == 'online';
  bool get isWalkIn => source == 'walkin';
  bool get isVoided => paymentStatus == 'voided';
  bool get isServiceCompleted => serviceCompletedAt != null;
  DateTime get displayAt => serviceCompletedAt ?? paidAt;
  String get serviceStateLabel =>
      isServiceCompleted ? 'Service Completed' : 'Service Pending';
  String get sourceLabel {
    if (source == 'online') return 'Online Booking';
    if (isAppointmentBooking) return 'Appointment booking';
    if (isWalkIn) return 'Walk-in';
    return source.isEmpty ? 'Walk-in' : source;
  }
  String get paymentLabel {
    switch (paymentMethod) {
      case 'cash':
        return 'Cash';
      case 'qr_code':
        return 'QR Code';
      case 'credit_card':
      case 'card':
        return 'Credit Card';
      case 'debit_card':
        return 'Debit Card';
      case 'billplz':
      case 'online':
        return 'Online';
      default:
        return paymentMethod.isEmpty ? 'Payment' : paymentMethod;
    }
  }

  IconData get paymentIcon {
    switch (paymentMethod) {
      case 'cash':
        return Icons.payments_outlined;
      case 'qr_code':
        return Icons.qr_code_2_outlined;
      case 'credit_card':
      case 'card':
        return Icons.credit_card_outlined;
      case 'debit_card':
        return Icons.credit_card;
      default:
        return Icons.receipt_long_outlined;
    }
  }
}

class _HistoryServiceGroup {
  final int paxNumber;
  final String customerName;
  final List<String> services;
  final String therapistName;
  final List<String> therapistNames;
  final String roomName;
  final String startTime;
  final String endTime;
  final double amount;

  const _HistoryServiceGroup({
    required this.paxNumber,
    required this.customerName,
    required this.services,
    required this.therapistName,
    required this.therapistNames,
    required this.roomName,
    required this.startTime,
    required this.endTime,
    required this.amount,
  });

  String get serviceLabel =>
      services.isEmpty ? 'Service' : services.join(', ');

  _HistoryServiceGroup copyWithTherapistNames(List<String> names) {
    final resolved = names.where((name) => name.trim().isNotEmpty).toList();
    return _HistoryServiceGroup(
      paxNumber: paxNumber,
      customerName: customerName,
      services: services,
      therapistName: resolved.isEmpty ? therapistName : resolved.first,
      therapistNames: resolved.isEmpty ? [therapistName] : resolved,
      roomName: roomName,
      startTime: startTime,
      endTime: endTime,
      amount: amount,
    );
  }

  String get timeLabel {
    if (startTime.isEmpty && endTime.isEmpty) return '';
    if (endTime.isEmpty) return startTime;
    return '$startTime - $endTime';
  }

  static List<_HistoryServiceGroup> fromItems(
    List<Map<String, dynamic>> items, {
    required String fallbackCustomerName,
    required String fallbackServiceName,
    required String fallbackTherapistName,
    required String fallbackRoomName,
    required double fallbackAmount,
  }) {
    if (items.isEmpty) {
      return [
        _HistoryServiceGroup(
          paxNumber: 1,
          customerName: fallbackCustomerName,
          services: [fallbackServiceName],
          therapistName: fallbackTherapistName,
          therapistNames: [fallbackTherapistName],
          roomName: fallbackRoomName,
          startTime: '',
          endTime: '',
          amount: fallbackAmount,
        ),
      ];
    }

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final item in items) {
      final key = [
        _asString(item['assignedTherapistId']),
        _asString(item['assignedTherapistName']),
        _asString(item['assignedRoomId']),
        _asString(item['assignedRoomName']),
        _asString(item['startTime']),
        _asString(item['endTime']),
      ].join('|');
      grouped.putIfAbsent(key, () => []).add(item);
    }

    var paxNumber = 0;
    return grouped.values.map((groupItems) {
      paxNumber += 1;
      final first = groupItems.first;
      final customerName = paxNumber == 1 ? fallbackCustomerName : 'Guest';
      final services = groupItems
          .map((item) => _asString(item['name'], 'Service'))
          .where((name) => name.trim().isNotEmpty)
          .toList();
      final amount = groupItems.fold<double>(
        0,
        (total, item) => total + _asDouble(item['price']),
      );
      return _HistoryServiceGroup(
        paxNumber: paxNumber,
        customerName: customerName,
        services: services.isEmpty ? [fallbackServiceName] : services,
        therapistName: _asString(
          first['assignedTherapistName'],
          fallbackTherapistName,
        ),
        therapistNames: [
          _asString(
            first['assignedTherapistName'],
            fallbackTherapistName,
          ),
        ],
        roomName: _asString(first['assignedRoomName'], fallbackRoomName),
        startTime: _asString(first['startTime']),
        endTime: _asString(first['endTime']),
        amount: amount == 0 ? fallbackAmount : amount,
      );
    }).toList();
  }
}

class _HistorySummary {
  final double collection;
  final double serviceNet;
  final double sst;
  final int orderCount;
  final int itemCount;
  final int customerCount;
  final Map<String, double> paymentTotals;
  final double totalTherapistCommission;

  const _HistorySummary({
    required this.collection,
    required this.serviceNet,
    required this.sst,
    required this.orderCount,
    required this.itemCount,
    required this.customerCount,
    required this.paymentTotals,
    required this.totalTherapistCommission,
  });

  static const empty = _HistorySummary(
    collection: 0,
    serviceNet: 0,
    sst: 0,
    orderCount: 0,
    itemCount: 0,
    customerCount: 0,
    paymentTotals: {'cash': 0, 'qr_code': 0, 'credit_card': 0, 'debit_card': 0},
    totalTherapistCommission: 0,
  );

  factory _HistorySummary.fromOrders(
    List<_HistoryOrder> orders,
    DateTime selectedDate,
  ) {
    final paidOrders = orders.where((order) => !order.isVoided).toList();
    final collectionOrders = paidOrders
        .where((order) => _sameDay(order.paidAt, selectedDate))
        .toList();
    final serviceOrders = paidOrders
        .where(
          (order) =>
              order.serviceCompletedAt != null &&
              _sameDay(order.serviceCompletedAt!, selectedDate),
        )
        .toList();
    final paymentTotals = {
      'cash': 0.0,
      'qr_code': 0.0,
      'credit_card': 0.0,
      'debit_card': 0.0,
      'online': 0.0,
      'other': 0.0,
    };
    final customers = <String>{};
    var collection = 0.0;
    var serviceNet = 0.0;
    var sst = 0.0;
    var itemCount = 0;
    var totalTherapistCommission = 0.0;

    for (final order in collectionOrders) {
      collection += order.totalAmount;
      sst += order.sstAmount;
      customers.add(
        order.customerId.isNotEmpty ? order.customerId : order.customerName,
      );
      final method = (order.paymentMethod == 'billplz' ||
              order.paymentMethod == 'online')
          ? 'online'
          : order.paymentMethod;
      if (paymentTotals.containsKey(method)) {
        paymentTotals[method] = paymentTotals[method]! + order.totalAmount;
      } else {
        paymentTotals['other'] = paymentTotals['other']! + order.totalAmount;
      }
    }

    for (final order in serviceOrders) {
      serviceNet += order.servicePrice;
      itemCount += order.itemCount;
      totalTherapistCommission += order.therapistCommissionAmount;
    }

    return _HistorySummary(
      collection: collection,
      serviceNet: serviceNet,
      sst: sst,
      orderCount: collectionOrders.length,
      itemCount: itemCount,
      customerCount: customers.where((id) => id.trim().isNotEmpty).length,
      paymentTotals: paymentTotals,
      totalTherapistCommission: totalTherapistCommission,
    );
  }

  double get averageOrder => orderCount == 0 ? 0 : collection / orderCount;
}

class _HistorySidePanel extends StatelessWidget {
  final DateTime selectedDate;
  final _HistorySummary summary;
  final bool loading;
  final bool isAdmin;
  final _HistoryPane selectedPane;
  final VoidCallback onBack;
  final VoidCallback onPickDate;
  final VoidCallback onPreviousDate;
  final VoidCallback onNextDate;
  final bool canGoNextDate;
  final VoidCallback? onOpenOrders;
  final VoidCallback onOpenServices;
  final VoidCallback onOpenCustomers;
  final VoidCallback onOpenStaff;

  const _HistorySidePanel({
    required this.selectedDate,
    required this.summary,
    required this.loading,
    required this.isAdmin,
    required this.selectedPane,
    required this.onBack,
    required this.onPickDate,
    required this.onPreviousDate,
    required this.onNextDate,
    required this.canGoNextDate,
    required this.onOpenServices,
    required this.onOpenCustomers,
    required this.onOpenStaff,
    this.onOpenOrders,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
            children: [
              SizedBox(
                height: 36,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _IconAction(
                        icon: Icons.close,
                        tooltip: 'Close history',
                        onTap: onBack,
                      ),
                    ),
                    Center(
                      child: _DateControl(
                        date: selectedDate,
                        isAdmin: isAdmin,
                        onPickDate: onPickDate,
                        onPreviousDate: onPreviousDate,
                        onNextDate: onNextDate,
                        canGoNextDate: canGoNextDate,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isAdmin) ...[
                const SizedBox(height: 10),
                const _StaffDateNotice(),
              ],
              const SizedBox(height: 22),
              _CollectionTile(
                total: summary.collection,
                orderCount: summary.orderCount,
                loading: loading,
              ),
              const SizedBox(height: 18),
              const _SideSectionLabel('Payment Breakdown'),
              _SideMetricRow(
                icon: Icons.payments_outlined,
                iconColor: const Color(0xFFD946EF),
                label: 'Cash',
                value: _money(summary.paymentTotals['cash'] ?? 0),
              ),
              _SideMetricRow(
                icon: Icons.qr_code_2_outlined,
                iconColor: const Color(0xFF7C3AED),
                label: 'QR Code',
                value: _money(summary.paymentTotals['qr_code'] ?? 0),
              ),
              _SideMetricRow(
                icon: Icons.credit_card_outlined,
                iconColor: const Color(0xFF2563EB),
                label: 'Credit Card',
                value: _money(summary.paymentTotals['credit_card'] ?? 0),
              ),
              _SideMetricRow(
                icon: Icons.credit_card,
                iconColor: const Color(0xFFF59E0B),
                label: 'Debit Card',
                value: _money(summary.paymentTotals['debit_card'] ?? 0),
              ),
              _SideMetricRow(
                icon: Icons.language_outlined,
                iconColor: const Color(0xFF0EA5E9),
                label: 'Online',
                value: _money(summary.paymentTotals['online'] ?? 0),
              ),
              if ((summary.paymentTotals['other'] ?? 0) > 0)
                _SideMetricRow(
                  icon: Icons.account_balance_wallet_outlined,
                  iconColor: const Color(0xFF64748B),
                  label: 'Other',
                  value: _money(summary.paymentTotals['other'] ?? 0),
                ),
              const SizedBox(height: 22),
              const _SideSectionLabel('Daily Sales'),
              _SideMetricRow(
                icon: Icons.shopping_cart_outlined,
                iconColor: const Color(0xFF2563EB),
                label: 'Bill',
                value: '${summary.orderCount}',
                selected: selectedPane == _HistoryPane.bill,
                onTap: onOpenOrders,
              ),
              _SideMetricRow(
                icon: Icons.spa_outlined,
                iconColor: const Color(0xFF10B981),
                label: 'Services',
                value: '${summary.itemCount}',
                selected: selectedPane == _HistoryPane.services,
                onTap: onOpenServices,
              ),
              _SideMetricRow(
                icon: Icons.people_outline,
                iconColor: const Color(0xFF1B6B72),
                label: 'Customers',
                value: '${summary.customerCount}',
                selected: selectedPane == _HistoryPane.customers,
                onTap: onOpenCustomers,
              ),
              _SideMetricRow(
                icon: Icons.badge_outlined,
                iconColor: const Color(0xFFF59E0B),
                label: 'Staff',
                value: _money(summary.totalTherapistCommission),
                selected: selectedPane == _HistoryPane.staff,
                onTap: onOpenStaff,
              ),
              const SizedBox(height: 22),
              const _SideSectionLabel('Tax & Settlement'),
              _SideMetricRow(
                icon: Icons.receipt_long_outlined,
                iconColor: const Color(0xFF64748B),
                label: 'Service Net',
                value: _money(summary.serviceNet),
              ),
              _SideMetricRow(
                icon: Icons.percent_outlined,
                iconColor: const Color(0xFF64748B),
                label: 'SST',
                value: _money(summary.sst),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DateControl extends StatelessWidget {
  final DateTime date;
  final bool isAdmin;
  final VoidCallback onPickDate;
  final VoidCallback onPreviousDate;
  final VoidCallback onNextDate;
  final bool canGoNextDate;

  const _DateControl({
    required this.date,
    required this.isAdmin,
    required this.onPickDate,
    required this.onPreviousDate,
    required this.onNextDate,
    required this.canGoNextDate,
  });

  @override
  Widget build(BuildContext context) {
    final label = DateFormat('dd/MM/yyyy').format(date);
    if (!isAdmin) {
      return Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFE8F5F5),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 14, color: _teal),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: _teal,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFFE8F5F5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TinyDateButton(
            icon: Icons.chevron_left,
            enabled: isAdmin,
            onTap: onPreviousDate,
          ),
          InkWell(
            onTap: isAdmin ? onPickDate : null,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Icon(Icons.calendar_today_outlined, size: 14, color: _teal),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      color: _teal,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ),
          _TinyDateButton(
            icon: Icons.chevron_right,
            enabled: canGoNextDate,
            onTap: onNextDate,
          ),
        ],
      ),
    );
  }
}

class _TinyDateButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _TinyDateButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        width: 30,
        height: 36,
        child: Icon(
          icon,
          size: 17,
          color: enabled ? _teal : const Color(0xFF94A3B8),
        ),
      ),
    );
  }
}

class _StaffDateNotice extends StatelessWidget {
  const _StaffDateNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: _muted),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Staff view is limited to today\'s paid sales.',
              style: TextStyle(
                color: _muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CollectionTile extends StatelessWidget {
  final double total;
  final int orderCount;
  final bool loading;

  const _CollectionTile({
    required this.total,
    required this.orderCount,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFDFF1FA),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Daily Collection',
                  style: TextStyle(
                    color: Color(0xFF2563EB),
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  loading
                      ? 'Loading paid sales'
                      : '$orderCount paid bill${orderCount == 1 ? '' : 's'}',
                  style: const TextStyle(
                    color: Color(0xFF2563EB),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Text(
            loading ? '-' : _money(total),
            style: const TextStyle(
              color: Color(0xFF2563EB),
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _SideSectionLabel extends StatelessWidget {
  final String label;

  const _SideSectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      child: Text(
        label,
        style: const TextStyle(
          color: _ink,
          fontSize: 14,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _SideMetricRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final bool selected;
  final VoidCallback? onTap;

  const _SideMetricRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final child = Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFE8F5F5) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: _ink,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: selected ? _teal : _muted,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: _teal, size: 17),
          ],
        ],
      ),
    );
    if (onTap == null) return child;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: child,
    );
  }
}

class _HistoryOrderPane extends StatelessWidget {
  final DateTime selectedDate;
  final List<_HistoryOrder> orders;
  final _HistorySummary summary;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;
  final ValueChanged<_HistoryOrder> onTapOrder;
  final bool compact;

  const _HistoryOrderPane({
    required this.selectedDate,
    required this.orders,
    required this.summary,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onTapOrder,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _page,
      child: Column(
        children: [
          if (!compact)
            Container(
              height: 76,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Daily Bill Sales - ${DateFormat('EEE, d MMM yyyy').format(selectedDate)}',
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  _HeaderStat(label: 'Bill', value: '${summary.orderCount}'),
                  const SizedBox(width: 10),
                  _HeaderStat(
                    label: 'Collection',
                    value: _money(summary.collection),
                  ),
                  const SizedBox(width: 10),
                  _IconAction(
                    icon: Icons.refresh,
                    tooltip: 'Refresh history',
                    onTap: onRefresh,
                  ),
                ],
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: onRefresh,
              color: _teal,
              child: _buildBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (loading) {
      return const Center(child: CircularProgressIndicator(color: _teal));
    }
    if (error != null) {
      return ListView(
        padding: const EdgeInsets.all(18),
        children: [
          _HistoryMessage(
            icon: Icons.cloud_off_outlined,
            title: 'Unable to load sales history',
            subtitle: error!,
          ),
        ],
      );
    }
    if (orders.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(18),
        children: const [
          _HistoryMessage(
            icon: Icons.receipt_long_outlined,
            title: 'No paid bills for this day',
            subtitle: 'Completed walk-in transactions will appear here.',
          ),
        ],
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 18, 0, compact ? 12 : 18, 22),
      itemCount: orders.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: EdgeInsets.only(
              top: compact ? 12 : 0,
              bottom: 10,
              left: compact ? 2 : 0,
            ),
            child: Text(
              'Total - ${orders.length}',
              style: const TextStyle(
                color: _ink,
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
          );
        }
        final order = orders[index - 1];
        return _HistoryOrderCard(
          order: order,
          compact: compact,
          onTap: () => onTapOrder(order),
        );
      },
    );
  }
}

class _HeaderStat extends StatelessWidget {
  final String label;
  final String value;

  const _HeaderStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: _muted,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: const TextStyle(
              color: _teal,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryOrderCard extends StatelessWidget {
  final _HistoryOrder order;
  final bool compact;
  final VoidCallback onTap;

  const _HistoryOrderCard({
    required this.order,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: EdgeInsets.all(compact ? 12 : 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFF1F5F9)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: compact ? _buildCompact() : _buildWide(),
          ),
        ),
      ),
    );
  }

  Widget _buildWide() {
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.description_outlined,
              size: 18,
              color: Color(0xFF2563EB),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: _OrderTextBlock(
                title: order.receiptNumber,
                subtitle: order.isVoided
                    ? 'Voided · ${DateFormat('hh:mm a, dd/MM/yyyy').format(order.displayAt)}'
                    : DateFormat('hh:mm a, dd/MM/yyyy').format(order.displayAt),
              ),
            ),
            Expanded(
              flex: 2,
              child: _OrderTextBlock(
                title: order.customerName,
                subtitle: order.customerPhone,
              ),
            ),
            Expanded(
              flex: 2,
              child: _OrderTextBlock(
                title: order.serviceName,
                subtitle: order.therapistName == '-'
                    ? order.roomName
                    : '${order.therapistName} - ${order.roomName}',
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _money(order.totalAmount),
                  style: TextStyle(
                    color: order.isVoided
                        ? const Color(0xFF9CA3AF)
                        : const Color(0xFF2563EB),
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    decoration: order.isVoided
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 4),
                if (order.isVoided)
                  const _VoidedChip()
                else
                  Text(
                    '${order.itemCount} item${order.itemCount == 1 ? '' : 's'}',
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ],
        ),
        const Divider(height: 20, color: Color(0xFFF1F5F9)),
        Row(
          children: [
            _PaymentChip(order: order),
            const Spacer(),
            const Icon(Icons.chevron_right, color: Color(0xFFCBD5E1)),
          ],
        ),
      ],
    );
  }

  Widget _buildCompact() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.description_outlined,
              size: 17,
              color: Color(0xFF2563EB),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                order.receiptNumber,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Text(
              _money(order.totalAmount),
              style: TextStyle(
                color: order.isVoided
                    ? const Color(0xFF9CA3AF)
                    : const Color(0xFF2563EB),
                fontSize: 13,
                fontWeight: FontWeight.w900,
                decoration: order.isVoided
                    ? TextDecoration.lineThrough
                    : TextDecoration.none,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${DateFormat('hh:mm a').format(order.displayAt)} - ${order.customerName}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _ink,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          '${order.serviceName} - ${order.itemCount} service${order.itemCount == 1 ? '' : 's'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _muted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _PaymentChip(order: order),
            if (order.isVoided) ...[
              const SizedBox(width: 8),
              const _VoidedChip(),
            ],
          ],
        ),
      ],
    );
  }
}

class _OrderTextBlock extends StatelessWidget {
  final String title;
  final String subtitle;

  const _OrderTextBlock({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.isEmpty ? '-' : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _ink,
            fontSize: 13,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle.isEmpty ? '-' : subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _muted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _PaymentChip extends StatelessWidget {
  final _HistoryOrder order;

  const _PaymentChip({required this.order});

  @override
  Widget build(BuildContext context) {
    final color = order.isVoided ? const Color(0xFF6B7280) : _ink;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: order.isVoided
            ? const Color(0xFFF3F4F6)
            : const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            order.isVoided ? Icons.block_rounded : order.paymentIcon,
            size: 14,
            color: _muted,
          ),
          const SizedBox(width: 6),
          Text(
            order.isVoided
                ? 'Voided : ${_money(order.totalAmount)}'
                : '${order.paymentLabel} : ${_money(order.totalAmount)}',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _VoidedChip extends StatelessWidget {
  const _VoidedChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Text(
        'VOIDED',
        style: TextStyle(
          color: Color(0xFFB91C1C),
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _HistoryMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _HistoryMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 80),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Column(
        children: [
          Icon(icon, color: _teal, size: 34),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _ink,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _muted,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderDetailSheet extends StatelessWidget {
  final _HistoryOrder order;
  final bool isAdmin;
  final VoidCallback onVoid;
  final VoidCallback onEditTherapists;

  const _OrderDetailSheet({
    required this.order,
    required this.isAdmin,
    required this.onVoid,
    required this.onEditTherapists,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          18,
          0,
          18,
          MediaQuery.of(context).viewInsets.bottom + 18,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    order.receiptNumber,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  _money(order.totalAmount),
                  style: TextStyle(
                    color: order.isVoided ? const Color(0xFF9CA3AF) : _teal,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    decoration: order.isVoided
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              DateFormat('EEEE, d MMM yyyy - hh:mm a').format(order.displayAt),
              style: const TextStyle(
                color: _muted,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 18),
            const _DetailSectionTitle('Service Details'),
            const SizedBox(height: 10),
            for (var i = 0; i < order.serviceGroups.length; i++) ...[
              _ServiceGroupCard(group: order.serviceGroups[i]),
              if (i != order.serviceGroups.length - 1)
                const SizedBox(height: 8),
            ],
            const Divider(height: 28, color: _line),
            _DetailRow('Source', order.sourceLabel),
            _DetailRow('Customer', order.customerName),
            _DetailRow('Phone', order.customerPhone),
            _DetailRow(
              'Payment',
              order.isVoided ? '${order.paymentLabel} · Voided' : order.paymentLabel,
            ),
            const Divider(height: 28, color: _line),
            _DetailRow('Service Net', _money(order.servicePrice)),
            _DetailRow('SST', _money(order.sstAmount)),
            _DetailRow('Total', _money(order.totalAmount), strong: true),
            if (isAdmin && order.isServiceCompleted && !order.isVoided) ...[
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onEditTherapists,
                  icon: const Icon(Icons.group_add_outlined, size: 18),
                  label: const Text('Edit Therapist Commission'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _teal,
                    side: const BorderSide(color: _teal),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
            if (isAdmin && !order.isVoided) ...[
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onVoid,
                  icon: const Icon(Icons.block_rounded, size: 18),
                  label: const Text('Void Bill'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE53935),
                    side: const BorderSide(color: Color(0xFFE53935)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TherapistAllocationEdit {
  const _TherapistAllocationEdit({
    required this.allocations,
    required this.reason,
  });

  final List<Map<String, dynamic>> allocations;
  final String reason;
}

class _TherapistAllocationDialog extends StatefulWidget {
  const _TherapistAllocationDialog({
    required this.therapists,
    required this.existing,
  });

  final Map<String, Map<String, dynamic>> therapists;
  final List<Map<String, dynamic>> existing;

  @override
  State<_TherapistAllocationDialog> createState() =>
      _TherapistAllocationDialogState();
}

class _TherapistAllocationDialogState
    extends State<_TherapistAllocationDialog> {
  final _reasonController = TextEditingController();
  late final List<_EditableTherapistShare> _shares;

  @override
  void initState() {
    super.initState();
    _shares = widget.existing
        .map(
          (row) => _EditableTherapistShare(
            therapistId: _asString(
              row['therapistId'] ?? row['therapist_id'],
            ),
            percent: (_asDouble(
                      row['commissionShare'] ?? row['commission_share'],
                    ) *
                    100)
                .round(),
          ),
        )
        .where((share) => share.therapistId.isNotEmpty)
        .toList();
    if (_shares.isEmpty && widget.therapists.isNotEmpty) {
      _shares.add(
        _EditableTherapistShare(
          therapistId: '',
          percent: 100,
        ),
      );
    }
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _equalize() {
    if (_shares.isEmpty) return;
    final base = 100 ~/ _shares.length;
    var remaining = 100;
    for (var index = 0; index < _shares.length; index++) {
      final value = index == _shares.length - 1 ? remaining : base;
      _shares[index].percent = value;
      remaining -= value;
    }
  }

  void _addTherapist() {
    if (_shares.any((share) => share.therapistId.isEmpty)) return;
    final used = _shares
        .map((share) => share.therapistId)
        .where((id) => id.isNotEmpty)
        .toSet();
    final available = widget.therapists.keys.where((id) => !used.contains(id));
    if (available.isEmpty) return;
    setState(() {
      _shares.add(
        _EditableTherapistShare(
          therapistId: '',
          percent: 0,
        ),
      );
    });
  }

  void _removeTherapist(int index) {
    if (_shares.length <= 1) return;
    setState(() {
      _shares.removeAt(index);
      _equalize();
    });
  }

  void _submit() {
    final reason = _reasonController.text.trim();
    if (_shares.any((share) => share.therapistId.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a therapist for every row')),
      );
      return;
    }
    final total = _shares.fold<int>(0, (sum, share) => sum + share.percent);
    if (total != 100) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Commission must total 100%')),
      );
      return;
    }
    Navigator.pop(
      context,
      _TherapistAllocationEdit(
        reason: reason,
        allocations: _shares
            .map(
              (share) => {
                'therapist_id': share.therapistId,
                'commission_share': share.percent / 100,
              },
            )
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = _shares.fold<int>(0, (sum, share) => sum + share.percent);
    final selectedTherapistIds = _shares
        .map((share) => share.therapistId)
        .where((id) => id.isNotEmpty)
        .toSet();
    final canAddTherapist =
        !_shares.any((share) => share.therapistId.isEmpty) &&
        selectedTherapistIds.length < widget.therapists.length;
    return AlertDialog(
      title: const Text('Edit therapist commission'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < _shares.length; index++) ...[
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(_shares[index]),
                        initialValue: _shares[index].therapistId.isEmpty
                            ? null
                            : _shares[index].therapistId,
                        decoration: const InputDecoration(
                          labelText: 'Therapist',
                          hintText: 'Select therapist',
                          border: OutlineInputBorder(),
                        ),
                        items: widget.therapists.entries
                            .where(
                              (entry) =>
                                  entry.key == _shares[index].therapistId ||
                                  !_shares.any(
                                    (share) => share.therapistId == entry.key,
                                  ),
                            )
                            .map(
                              (entry) => DropdownMenuItem(
                                value: entry.key,
                                child: Text(_asString(entry.value['name'])),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _shares[index].therapistId = value;
                              _equalize();
                            });
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 105,
                      child: DropdownButtonFormField<int>(
                        initialValue: _shares[index].percent,
                        decoration: const InputDecoration(
                          labelText: 'Share',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final percent in (
                            {0, 25, 50, 75, 100, _shares[index].percent}
                                  .toList()
                              ..sort()
                          ))
                            DropdownMenuItem(
                              value: percent,
                              child: Text('$percent%'),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _shares[index].percent = value);
                          }
                        },
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove therapist',
                      onPressed: _shares.length > 1
                          ? () => _removeTherapist(index)
                          : null,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: canAddTherapist ? _addTherapist : null,
                  icon: const Icon(Icons.add),
                  label: const Text('Add therapist'),
                ),
              ),
              Text(
                'Total: $total%',
                style: TextStyle(
                  color: total == 100 ? _teal : const Color(0xFFE53935),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _reasonController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Correction reason (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

class _EditableTherapistShare {
  _EditableTherapistShare({
    required this.therapistId,
    required this.percent,
  });

  String therapistId;
  int percent;
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool strong;

  const _DetailRow(this.label, this.value, {this.strong = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: const TextStyle(
                color: _muted,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: strong ? _teal : _ink,
                fontSize: strong ? 15 : 13,
                fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailSectionTitle extends StatelessWidget {
  final String label;

  const _DetailSectionTitle(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: _ink,
        fontSize: 14,
        fontWeight: FontWeight.w900,
      ),
    );
  }
}

/// Always fully expanded (no collapse/expand toggle) — every pax's service
/// details should be visible immediately, on both tablet and phone.
class _ServiceGroupCard extends StatelessWidget {
  final _HistoryServiceGroup group;

  const _ServiceGroupCard({required this.group});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pax ${group.paxNumber} - ${group.customerName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _ink,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${group.serviceLabel} - ${_money(group.amount)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          _ServiceDetailLine(
            icon: Icons.spa_outlined,
            label: 'Service',
            value: group.serviceLabel,
          ),
          for (var index = 0; index < group.therapistNames.length; index++)
            _ServiceDetailLine(
              icon: Icons.person_outline,
              label: group.therapistNames.length == 1
                  ? 'Therapist'
                  : 'Therapist ${index + 1}',
              value: group.therapistNames[index],
            ),
          _ServiceDetailLine(
            icon: Icons.meeting_room_outlined,
            label: 'Room / Zone',
            value: group.roomName,
          ),
          if (group.timeLabel.isNotEmpty)
            _ServiceDetailLine(
              icon: Icons.schedule_outlined,
              label: 'Time',
              value: group.timeLabel,
            ),
          _ServiceDetailLine(
            icon: Icons.payments_outlined,
            label: 'Amount',
            value: _money(group.amount),
            strong: true,
          ),
        ],
      ),
    );
  }
}

class _ServiceDetailLine extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool strong;

  const _ServiceDetailLine({
    required this.icon,
    required this.label,
    required this.value,
    this.strong = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: _muted),
          const SizedBox(width: 8),
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: const TextStyle(
                color: _muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: strong ? _teal : _ink,
                fontSize: 12,
                fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, color: _teal, size: 21),
        ),
      ),
    );
  }
}

class _HistoryCalendarDialog extends StatefulWidget {
  final DateTime initialDate;

  const _HistoryCalendarDialog({required this.initialDate});

  @override
  State<_HistoryCalendarDialog> createState() => _HistoryCalendarDialogState();
}

class _HistoryCalendarDialogState extends State<_HistoryCalendarDialog> {
  late DateTime _visibleMonth;

  @override
  void initState() {
    super.initState();
    _visibleMonth = DateTime(widget.initialDate.year, widget.initialDate.month);
  }

  void _moveMonth(int offset) {
    setState(() {
      _visibleMonth = DateTime(
        _visibleMonth.year,
        _visibleMonth.month + offset,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final firstDay = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    final gridStart = firstDay.subtract(Duration(days: firstDay.weekday % 7));
    final days = List.generate(
      42,
      (index) => gridStart.add(Duration(days: index)),
    );
    final selected = _stripDate(widget.initialDate);
    final today = _stripDate(DateTime.now());
    final currentMonth = DateTime(today.year, today.month);
    final canMoveNextMonth = _visibleMonth.isBefore(currentMonth);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      DateFormat('MMMM yyyy').format(_visibleMonth),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _moveMonth(-1),
                    icon: const Icon(Icons.chevron_left),
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    onPressed: canMoveNextMonth ? () => _moveMonth(1) : null,
                    icon: const Icon(Icons.chevron_right),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: const [
                  _WeekdayLabel('SUN'),
                  _WeekdayLabel('MON'),
                  _WeekdayLabel('TUE'),
                  _WeekdayLabel('WED'),
                  _WeekdayLabel('THU'),
                  _WeekdayLabel('FRI'),
                  _WeekdayLabel('SAT'),
                ],
              ),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisSpacing: 7,
                  crossAxisSpacing: 7,
                ),
                itemCount: days.length,
                itemBuilder: (context, index) {
                  final day = days[index];
                  final cleanDay = _stripDate(day);
                  final isSelected = cleanDay == selected;
                  final isToday = cleanDay == today;
                  final inMonth = day.month == _visibleMonth.month;
                  final isFuture = cleanDay.isAfter(today);

                  return InkWell(
                    onTap: isFuture
                        ? null
                        : () => Navigator.pop(context, cleanDay),
                    borderRadius: BorderRadius.circular(18),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected ? _teal : Colors.transparent,
                        border: isToday && !isSelected
                            ? Border.all(color: _teal)
                            : null,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${day.day}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected || isToday
                              ? FontWeight.w900
                              : FontWeight.w700,
                          color: isSelected
                              ? Colors.white
                              : isFuture
                              ? const Color(0xFFE2E8F0)
                              : inMonth
                              ? const Color(0xFF111827)
                              : const Color(0xFFCBD5E1),
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => Navigator.pop(context, today),
                    icon: const Icon(Icons.today_outlined, size: 17),
                    label: const Text('Today'),
                    style: TextButton.styleFrom(
                      foregroundColor: _teal,
                      textStyle: const TextStyle(fontWeight: FontWeight.w800),
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

class _WeekdayLabel extends StatelessWidget {
  final String label;

  const _WeekdayLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 10,
          color: Color(0xFF6B7280),
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

String _money(double value) => value.toStringAsFixed(2);

String _maskedPhone(String value) {
  return value.trim().isEmpty || value == '-' ? '-' : value;
}

// ── Shared breakdown-page header ─────────────────────────────────

class _BreakdownHeader extends StatelessWidget {
  final String title;
  final DateTime date;
  final List<Widget> trailing;
  final bool showBack;

  const _BreakdownHeader({
    required this.title,
    required this.date,
    this.trailing = const [],
    this.showBack = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 10, 16, 12),
      color: Colors.white,
      child: Row(
        children: [
          if (showBack)
            BackButton(
              color: _teal,
              onPressed: () => Navigator.of(context).pop(),
            )
          else
            const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  DateFormat('EEE, d MMM yyyy').format(date),
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

/// Opens centered drill-down detail for bills, customers, and staff.
Future<void> _showDetailDrawer({
  required BuildContext context,
  required String title,
  required Widget child,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: const Color(0x66000000),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) {
      final size = MediaQuery.of(context).size;
      final dialogWidth = size.width < 620 ? size.width - 28 : 560.0;
      final dialogHeight = size.height * 0.82;
      return Center(
        child: Material(
          color: Colors.transparent,
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: dialogWidth,
                maxHeight: dialogHeight.clamp(360.0, 760.0),
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 30,
                      offset: const Offset(0, 18),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 52,
                      height: 4,
                      margin: const EdgeInsets.only(top: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFCBD5E1),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 14, 12, 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: _ink,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close_rounded),
                            color: _ink,
                            tooltip: 'Close',
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: _line),
                    Expanded(child: child),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

// ── Services breakdown ───────────────────────────────────────────

class _ServiceBreakdownItem {
  final String id;
  final String name;
  final String category;
  final String imageUrl;
  int count = 0;
  double amount = 0;

  _ServiceBreakdownItem({
    required this.id,
    required this.name,
    required this.category,
    required this.imageUrl,
  });
}

class _ServicesBreakdownScreen extends StatefulWidget {
  final DateTime selectedDate;
  final List<_HistoryOrder> orders;
  final bool embedded;

  const _ServicesBreakdownScreen({
    required this.selectedDate,
    required this.orders,
    this.embedded = false,
  });

  @override
  State<_ServicesBreakdownScreen> createState() =>
      _ServicesBreakdownScreenState();
}

class _ServicesBreakdownScreenState extends State<_ServicesBreakdownScreen> {
  String _tab = 'All';

  static const _tabs = [
    'All',
    'Services',
    'Packages',
    'Add-ons',
    'Online Booking',
  ];

  List<_ServiceBreakdownItem> get _filteredItems {
    final paidOrders = widget.orders.where(
      (order) => !order.isVoided && order.isServiceCompleted,
    );
    final grouped = <String, _ServiceBreakdownItem>{};

    for (final order in paidOrders) {
      if (_tab == 'Online Booking' && order.source != 'online') continue;

      final items = order.rawServiceItems.isNotEmpty
          ? order.rawServiceItems
          : [
              {
                'id': order.serviceName,
                'name': order.serviceName,
                'category': 'Services',
                'price': order.servicePrice,
              },
            ];

      for (final item in items) {
        final category = _asString(item['category'], 'Services');
        if (_tab != 'All' && _tab != 'Online Booking' && category != _tab) {
          continue;
        }
        final id = _asString(item['id'], _asString(item['name'], 'service'));
        final name = _asString(item['name'], 'Service');
        final price = _asDouble(item['price']);
        final entry = grouped.putIfAbsent(
          id,
          () => _ServiceBreakdownItem(
            id: id,
            name: name,
            category: category,
            imageUrl: _asString(
              item['imageUrl'],
              _asString(item['image'], _asString(item['publicImageUrl'])),
            ),
          ),
        );
        entry.count += 1;
        entry.amount += price;
      }
    }

    final list = grouped.values.toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final items = _filteredItems;
    final totalAmount = items.fold<double>(
      0,
      (total, item) => total + item.amount,
    );
    final totalCount = items.fold<int>(0, (total, item) => total + item.count);

    final content = Container(
      color: _page,
      child: Column(
          children: [
            _BreakdownHeader(
              title: 'Services',
              date: widget.selectedDate,
              showBack: !widget.embedded,
              trailing: [
                _HeaderStat(label: 'Items', value: '$totalCount'),
                const SizedBox(width: 10),
                _HeaderStat(label: 'Total', value: _money(totalAmount)),
              ],
            ),
            _ServiceBreakdownTabs(
              tabs: _tabs,
              selected: _tab,
              onSelected: (tab) => setState(() => _tab = tab),
            ),
            const Divider(height: 1, color: _line),
            Expanded(
              child: items.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(18),
                      children: const [
                        _HistoryMessage(
                          icon: Icons.spa_outlined,
                          title: 'No services sold for this day',
                          subtitle: 'Completed services will appear here.',
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 22),
                      itemCount: items.length,
                      itemBuilder: (context, index) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _ServiceBreakdownCard(item: items[index]),
                      ),
                    ),
            ),
          ],
        ),
    );
    if (widget.embedded) return content;
    return Scaffold(
      backgroundColor: _page,
      body: SafeArea(child: content),
    );
  }
}

class _ServiceBreakdownCard extends StatelessWidget {
  final _ServiceBreakdownItem item;

  const _ServiceBreakdownCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFF1F5F9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          _ServiceBreakdownImage(imageUrl: item.imageUrl),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    item.category,
                    style: const TextStyle(
                      color: _muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Container(
            width: 96,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5F5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${item.count} sold',
                  style: const TextStyle(
                    color: _teal,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _money(item.amount),
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 14,
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

class _ServiceBreakdownTabs extends StatelessWidget {
  final List<String> tabs;
  final String selected;
  final ValueChanged<String> onSelected;

  const _ServiceBreakdownTabs({
    required this.tabs,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Center(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: tabs.map((tab) {
              final active = selected == tab;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: InkWell(
                  onTap: () => onSelected(tab),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tab,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                            color: active ? _teal : const Color(0xFF9E9E9E),
                          ),
                        ),
                        const SizedBox(height: 8),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          height: 3,
                          width: active ? 40 : 0,
                          decoration: BoxDecoration(
                            color: _teal,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

class _ServiceBreakdownImage extends StatelessWidget {
  final String imageUrl;

  const _ServiceBreakdownImage({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 64,
        height: 64,
        color: const Color(0xFFE8F5F5),
        child: imageUrl.isEmpty
            ? const Icon(Icons.spa_outlined, size: 22, color: _teal)
            : Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const Icon(Icons.spa_outlined, size: 22, color: _teal),
              ),
      ),
    );
  }
}

// ── Customer breakdown ───────────────────────────────────────────

class _CustomerBreakdownScreen extends StatelessWidget {
  final DateTime selectedDate;
  final List<_HistoryOrder> orders;
  final bool embedded;

  const _CustomerBreakdownScreen({
    required this.selectedDate,
    required this.orders,
    this.embedded = false,
  });

  Map<String, List<_HistoryOrder>> get _byCustomer {
    final map = <String, List<_HistoryOrder>>{};
    for (final order in orders.where(
      (order) => !order.isVoided && order.isServiceCompleted,
    )) {
      final key = order.customerId.isNotEmpty
          ? order.customerId
          : order.customerName;
      if (key.trim().isEmpty) continue;
      map.putIfAbsent(key, () => []).add(order);
    }
    return map;
  }

  DateTime _latestUpdateFor(List<_HistoryOrder> customerOrders) {
    return customerOrders
        .map((order) => order.updatedAt)
        .reduce((a, b) => a.isAfter(b) ? a : b);
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _byCustomer;
    final entries = grouped.entries.toList()
      ..sort((a, b) => _latestUpdateFor(b.value).compareTo(_latestUpdateFor(a.value)));
    final totalRevenue = orders
        .where((order) => !order.isVoided && order.isServiceCompleted)
        .fold<double>(0, (total, order) => total + order.totalAmount);

    final content = Container(
      color: _page,
      child: Column(
          children: [
            _BreakdownHeader(
              title: 'Customers',
              date: selectedDate,
              showBack: !embedded,
              trailing: [
                _HeaderStat(label: 'Customers', value: '${entries.length}'),
                const SizedBox(width: 10),
                _HeaderStat(label: 'Total', value: _money(totalRevenue)),
              ],
            ),
            Expanded(
              child: entries.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(18),
                      children: const [
                        _HistoryMessage(
                          icon: Icons.people_outline,
                          title: 'No customers for this day',
                          subtitle: 'Customers who visit will appear here.',
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(18),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final customerOrders = entries[index].value;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _CustomerBreakdownCard(
                            customerOrders: customerOrders,
                            onTap: () => _showDetailDrawer(
                              context: context,
                              title: '${customerOrders.first.customerName} Bills',
                              child: _CustomerDetailSheet(
                                customerOrders: customerOrders,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
    );
    if (embedded) return content;
    return Scaffold(
      backgroundColor: _page,
      body: SafeArea(child: content),
    );
  }
}

class _CustomerBreakdownCard extends StatelessWidget {
  final List<_HistoryOrder> customerOrders;
  final VoidCallback onTap;

  const _CustomerBreakdownCard({
    required this.customerOrders,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final first = customerOrders.first;
    final total = customerOrders.fold<double>(
      0,
      (total, order) => total + order.totalAmount,
    );
    final paymentTotals = <String, double>{};
    for (final order in customerOrders) {
      paymentTotals.update(
        order.paymentLabel,
        (value) => value + order.totalAmount,
        ifAbsent: () => order.totalAmount,
      );
    }

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFF1F5F9)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: const Color(0xFFFFE4D6),
                    child: Text(
                      first.customerName.isEmpty
                          ? '?'
                          : first.customerName[0].toUpperCase(),
                      style: const TextStyle(
                        color: Color(0xFF9A3412),
                        fontSize: 16,
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
                          first.customerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _maskedPhone(first.customerPhone),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _money(total),
                        style: const TextStyle(
                          color: Color(0xFF1D4ED8),
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${customerOrders.length} Bill${customerOrders.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const Divider(height: 22, color: Color(0xFFF1F5F9)),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: paymentTotals.entries
                      .map(
                        (entry) => Text(
                          '${entry.key} : ${_money(entry.value)}',
                          style: const TextStyle(
                            color: _ink,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomerDetailSheet extends StatefulWidget {
  final List<_HistoryOrder> customerOrders;

  const _CustomerDetailSheet({required this.customerOrders});

  @override
  State<_CustomerDetailSheet> createState() => _CustomerDetailSheetState();
}

class _CustomerDetailSheetState extends State<_CustomerDetailSheet> {
  final _customerRepository = CustomerRepository();
  bool _loadingHistory = true;
  List<Map<String, dynamic>> _previousOrders = [];

  _HistoryOrder get _first => widget.customerOrders.first;
  String get _customerId => _first.customerId;

  @override
  void initState() {
    super.initState();
    if (_customerId.isNotEmpty) {
      _loadHistory();
    } else {
      _loadingHistory = false;
    }
  }

  Future<void> _loadHistory() async {
    try {
      final txs = await _customerRepository.getCustomerOrders(_customerId);
      final todayIds = widget.customerOrders.map((o) => o.id).toSet();
      final previous = txs
          .where((tx) => !todayIds.contains(_asString(tx['id'])))
          .toList()
        ..sort(
          (a, b) => _asString(
            b['createdAt'],
          ).compareTo(_asString(a['createdAt'])),
        );
      if (!mounted) return;
      setState(() {
        _previousOrders = previous;
        _loadingHistory = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingHistory = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final todayOrders = [...widget.customerOrders]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final latestOrder = todayOrders.first;
    final earlierToday = todayOrders.skip(1).toList();

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          18,
          16,
          18,
          MediaQuery.of(context).viewInsets.bottom + 18,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${todayOrders.length} bill${todayOrders.length == 1 ? '' : 's'} today',
              style: const TextStyle(
                color: _muted,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            const _DetailSectionTitle('Latest Bill'),
            const SizedBox(height: 10),
            _TodayBillServicesCard(order: latestOrder),
            if (earlierToday.isNotEmpty || _customerId.isNotEmpty) ...[
              const Divider(height: 28, color: _line),
              const _DetailSectionTitle('Previous Bills'),
              const SizedBox(height: 10),
              for (final order in earlierToday)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _TodayBillServicesCard(order: order),
                ),
              if (_loadingHistory)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: CircularProgressIndicator(color: _teal),
                  ),
                )
              else ...[
                if (_previousOrders.isEmpty)
                  if (earlierToday.isEmpty)
                    const Text(
                      'No previous bills',
                      style: TextStyle(
                        color: _muted,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                else
                  for (final tx in _previousOrders)
                    _PreviousOrderLine(tx: tx),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _TodayBillServicesCard extends StatelessWidget {
  final _HistoryOrder order;

  const _TodayBillServicesCard({required this.order});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  order.receiptNumber,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                DateFormat('hh:mm a').format(order.updatedAt),
                style: const TextStyle(
                  color: _teal,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final group in order.serviceGroups)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.spa_outlined, size: 15, color: _muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      group.serviceLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _money(group.amount),
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 14, color: _line),
          _DetailRow('Bill Total', _money(order.totalAmount), strong: true),
        ],
      ),
    );
  }
}

class _PreviousOrderLine extends StatelessWidget {
  final Map<String, dynamic> tx;

  const _PreviousOrderLine({required this.tx});

  @override
  Widget build(BuildContext context) {
    final createdAt = _asDateTime(tx['createdAt']);
    final serviceName = _asString(tx['serviceName'], 'Service');
    final amount = _asDouble(tx['totalAmount']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  serviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  DateFormat('d MMM yyyy').format(createdAt),
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Text(
            _money(amount),
            style: const TextStyle(
              color: _ink,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Staff commission ─────────────────────────────────────────────

class _StaffOrderLine {
  final _HistoryOrder order;
  final List<Map<String, dynamic>> items;
  final double commission;

  const _StaffOrderLine({
    required this.order,
    required this.items,
    required this.commission,
  });
}

class _StaffEarning {
  final String id;
  final String name;
  double commission = 0;
  int serviceCount = 0;
  final List<_StaffOrderLine> lines = [];

  _StaffEarning({required this.id, required this.name});
}

class _StaffCommissionScreen extends StatelessWidget {
  final DateTime selectedDate;
  final List<_HistoryOrder> orders;
  final Map<String, Map<String, dynamic>> therapists;
  final ValueChanged<_HistoryOrder> onTapOrder;
  final bool embedded;

  const _StaffCommissionScreen({
    required this.selectedDate,
    required this.orders,
    required this.therapists,
    required this.onTapOrder,
    this.embedded = false,
  });

  Map<String, _StaffEarning> _computeEarnings() {
    final earnings = <String, _StaffEarning>{};
    final therapistIdByName = {
      for (final entry in therapists.entries)
        _normalizeStaffName(_asString(entry.value['name'])): entry.key,
    }..remove('');

    for (final order in orders.where(
      (order) => !order.isVoided && order.isServiceCompleted,
    )) {
      if (order.therapistAllocations.isNotEmpty) {
        for (final allocation in order.therapistAllocations) {
          final therapistId = _asString(
            allocation['therapistId'] ?? allocation['therapist_id'],
          );
          if (therapistId.isEmpty) continue;
          final therapistName = _asString(
            therapists[therapistId]?['name'],
            'Therapist',
          );
          final commission = _asDouble(
            allocation['commissionAmount'] ?? allocation['commission_amount'],
          );
          if (commission <= 0) continue;
          final earning = earnings.putIfAbsent(
            therapistId,
            () => _StaffEarning(id: therapistId, name: therapistName),
          );
          earning.commission += commission;
          earning.serviceCount += 1;
          earning.lines.add(
            _StaffOrderLine(
              order: order,
              items: order.rawServiceItems,
              commission: commission,
            ),
          );
        }
        continue;
      }
      final items = order.rawServiceItems.isNotEmpty
          ? order.rawServiceItems
          : [
              {
                'assignedTherapistId': '',
                'assignedTherapistName': order.therapistName,
                'id': order.serviceName,
                'name': order.serviceName,
                'price': order.servicePrice,
                'therapistCommission': order.therapistCommissionAmount,
              },
            ];

      final byTherapist = <String, List<Map<String, dynamic>>>{};
      for (final item in items) {
        final therapistName = _asString(
          item['assignedTherapistName'],
          order.therapistName,
        );
        var therapistId = _asString(item['assignedTherapistId']);
        if (therapistId.isEmpty) {
          therapistId =
              therapistIdByName[_normalizeStaffName(therapistName)] ??
              order.therapistId;
        }
        if (therapistId.isEmpty) {
          therapistId = therapistName.isNotEmpty ? therapistName : 'unknown';
        }
        final resolvedTherapistName = _asString(
          therapists[therapistId]?['name'],
          therapistName,
        );
        byTherapist
            .putIfAbsent(therapistId, () => [])
            .add({
              ...item,
              'assignedTherapistId': therapistId,
              'assignedTherapistName': resolvedTherapistName,
            });
      }

      for (final entry in byTherapist.entries) {
        final therapistId = entry.key;
        final therapistItems = entry.value;
        final therapistName = _asString(
          therapistItems.first['assignedTherapistName'],
          '-',
        );
        final therapistDoc = therapists[therapistId];
        final commission = therapistItems.fold<double>(
          0,
          (total, item) =>
              total +
              CommissionRepository.commissionForService(
                item,
                staff: therapistDoc,
                role: 'Therapist',
              ),
        );

        final earning = earnings.putIfAbsent(
          therapistId,
          () => _StaffEarning(id: therapistId, name: therapistName),
        );
        earning.commission += commission;
        earning.serviceCount += therapistItems.length;
        earning.lines.add(
          _StaffOrderLine(
            order: order,
            items: therapistItems,
            commission: commission,
          ),
        );
      }
    }

    return earnings;
  }

  void _openStaffDrawer(BuildContext context, _StaffEarning earning) {
    _showDetailDrawer(
      context: context,
      title: earning.name,
      child: _StaffDetailContent(
        earning: earning,
        onTapOrder: onTapOrder,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final earnings = _computeEarnings().values
        .where((earning) => earning.commission > 0)
        .toList()
      ..sort((a, b) => b.commission.compareTo(a.commission));
    final totalCommission = earnings.fold<double>(
      0,
      (total, earning) => total + earning.commission,
    );

    final content = Container(
      color: _page,
      child: Column(
          children: [
            _BreakdownHeader(
              title: 'Staff',
              date: selectedDate,
              showBack: !embedded,
              trailing: [
                _HeaderStat(label: 'Staff', value: '${earnings.length}'),
                const SizedBox(width: 10),
                _HeaderStat(
                  label: 'Commission',
                  value: _money(totalCommission),
                ),
              ],
            ),
            Expanded(
              child: earnings.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.all(18),
                      children: const [
                        _HistoryMessage(
                          icon: Icons.badge_outlined,
                          title: 'No staff commission for this day',
                          subtitle: 'Completed services will appear here.',
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(18),
                      itemCount: earnings.length,
                      itemBuilder: (context, index) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _StaffEarningCard(
                          earning: earnings[index],
                          onTap: () =>
                              _openStaffDrawer(context, earnings[index]),
                        ),
                      ),
                    ),
            ),
          ],
        ),
    );
    if (embedded) return content;
    return Scaffold(
      backgroundColor: _page,
      body: SafeArea(child: content),
    );
  }
}

class _StaffEarningCard extends StatelessWidget {
  final _StaffEarning earning;
  final VoidCallback onTap;

  const _StaffEarningCard({required this.earning, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFF1F5F9)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5F5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.badge_outlined,
                  size: 19,
                  color: _teal,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      earning.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${earning.serviceCount} service${earning.serviceCount == 1 ? '' : 's'} - ${earning.lines.length} bill${earning.lines.length == 1 ? '' : 's'}',
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
                _money(earning.commission),
                style: const TextStyle(
                  color: _teal,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, color: Color(0xFFCBD5E1)),
            ],
          ),
        ),
      ),
    );
  }
}

class _StaffDetailContent extends StatelessWidget {
  final _StaffEarning earning;
  final ValueChanged<_HistoryOrder> onTapOrder;

  const _StaffDetailContent({
    required this.earning,
    required this.onTapOrder,
  });

  @override
  Widget build(BuildContext context) {
    final lines = [...earning.lines]
      ..sort((a, b) => b.order.updatedAt.compareTo(a.order.updatedAt));
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F5F5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.badge_outlined, color: _teal, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${earning.serviceCount} service${earning.serviceCount == 1 ? '' : 's'} across ${earning.lines.length} bill${earning.lines.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                    color: _teal,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                _money(earning.commission),
                style: const TextStyle(
                  color: _teal,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (lines.isEmpty)
          const _HistoryMessage(
            icon: Icons.receipt_long_outlined,
            title: 'No bills for this staff',
            subtitle: 'Commission-linked bills will appear here.',
          )
        else
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _StaffOrderLineTile(
                line: line,
                onTap: () => onTapOrder(line.order),
              ),
            ),
      ],
    );
  }
}

class _StaffOrderLineTile extends StatelessWidget {
  final _StaffOrderLine line;
  final VoidCallback onTap;

  const _StaffOrderLineTile({
    required this.line,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final services = line.items
        .map((item) => _asString(item['name'], 'Service'))
        .where((name) => name.isNotEmpty)
        .join(', ');
    return Material(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  line.order.receiptNumber,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                DateFormat('hh:mm a').format(line.order.displayAt),
                style: const TextStyle(
                  color: _muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            services.isEmpty ? line.order.serviceName : services,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _muted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  line.order.customerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFFCBD5E1), size: 18),
            ],
          ),
          const Divider(height: 16, color: _line),
          Row(
            children: [
              const Text(
                'Commission earned',
                style: TextStyle(
                  color: _muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              Text(
                _money(line.commission),
                style: const TextStyle(
                  color: _teal,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          _DetailRow('Bill Total', _money(line.order.totalAmount)),
        ],
          ),
        ),
      ),
    );
  }
}
