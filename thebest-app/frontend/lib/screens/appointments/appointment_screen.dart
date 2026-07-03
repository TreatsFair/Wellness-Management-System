import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/services/csp_service.dart';
import '../../data/repositories/appointment_repository.dart';
import '../../data/repositories/commission_repository.dart';
import '../../data/repositories/dashboard_repository.dart';
import '../../data/services/supabase_table_service.dart';
import '../booking/booking_screen.dart';

DateTime _stripTime(DateTime date) => DateTime(date.year, date.month, date.day);

int _timeToMinutes(String time) {
  final parts = time.split(':');
  if (parts.length < 2) return 0;
  final hour = int.tryParse(parts[0]) ?? 0;
  final minute = int.tryParse(parts[1]) ?? 0;
  return hour * 60 + minute;
}

String _minutesToTime(int minutes) {
  final normalized = minutes % (24 * 60);
  final hour = (normalized ~/ 60).toString().padLeft(2, '0');
  final minute = (normalized % 60).toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _clockLabel(String time) {
  final minutes = _timeToMinutes(time);
  final hour = (minutes ~/ 60) % 24;
  final minute = minutes % 60;
  return DateFormat('h:mm a').format(DateTime(2026, 1, 1, hour, minute));
}

DateTime? _readDateTime(Object? value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

int? _minutesFromDate(DateTime? value, DateTime baseDate) {
  if (value == null) return null;
  final base = DateTime(baseDate.year, baseDate.month, baseDate.day);
  return value.difference(base).inMinutes;
}

String _hourLabel(int hour) {
  final normalized = hour % 24;
  final displayHour = normalized == 0
      ? 12
      : normalized > 12
      ? normalized - 12
      : normalized;
  return '$displayHour${normalized < 12 ? 'am' : 'pm'}';
}

double _readDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

int _readInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

String _generateReceiptNumber() {
  final now = DateTime.now();
  return 'TXN-${DateFormat('yyyyMMdd').format(now)}-'
      '${now.millisecondsSinceEpoch.toString().substring(8)}';
}

class _ScheduleAppointment {
  final String id;
  final String appointmentGroupId;
  final String customerId;
  final String dateKey;
  final DateTime date;
  final String startTime;
  final String endTime;
  final DateTime? startAt;
  final DateTime? endAt;
  final String status;
  final String customerName;
  final String customerPhone;
  final String serviceId;
  final String serviceName;
  final String serviceDescription;
  final String therapistId;
  final String therapistName;
  final String roomId;
  final String roomName;
  final String notes;
  final double price;
  final List<Map<String, dynamic>> serviceItems;
  final Map<String, dynamic> therapistCommissionData;

  const _ScheduleAppointment({
    required this.id,
    required this.appointmentGroupId,
    required this.customerId,
    required this.dateKey,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.startAt,
    required this.endAt,
    required this.status,
    required this.customerName,
    required this.customerPhone,
    required this.serviceId,
    required this.serviceName,
    required this.serviceDescription,
    required this.therapistId,
    required this.therapistName,
    required this.roomId,
    required this.roomName,
    required this.notes,
    required this.price,
    required this.serviceItems,
    required this.therapistCommissionData,
  });

  factory _ScheduleAppointment.fromMap(
    Map<String, dynamic> data, {
    required Map<String, Map<String, dynamic>> customers,
    required Map<String, Map<String, dynamic>> services,
    required Map<String, Map<String, dynamic>> therapists,
    required Map<String, Map<String, dynamic>> rooms,
  }) {
    final customerId = data['customerId']?.toString() ?? '';
    final customer = customers[customerId];
    final serviceId = data['serviceId']?.toString() ?? '';
    final therapistId = data['therapistId']?.toString() ?? '';
    final roomId = data['roomId']?.toString() ?? '';
    final service = services[serviceId];
    final therapist = therapists[therapistId];
    final room = rooms[roomId];
    final dateKey = _readDateKey(data['date']);
    final isGuestCustomer =
        customerId.trim().isEmpty || customerId == 'walk_in_guest';
    final rawCustomerName =
        data['customerName']?.toString() ?? customer?['name']?.toString();
    final customerName = isGuestCustomer && _isGuestName(rawCustomerName)
        ? 'Guest'
        : rawCustomerName ?? 'Customer';

    return _ScheduleAppointment(
      id: data['id']?.toString() ?? '',
      appointmentGroupId: data['appointmentGroupId']?.toString() ?? '',
      customerId: customerId,
      dateKey: dateKey,
      date: _readDate(dateKey, data['date']),
      startTime: data['startTime']?.toString() ?? '09:00',
      endTime: data['endTime']?.toString() ?? '10:00',
      startAt: _readDateTime(data['startAt']),
      endAt: _readDateTime(data['endAt']),
      status: data['status']?.toString().trim().toLowerCase() ?? 'pending',
      customerName: customerName,
      customerPhone:
          data['customerPhone']?.toString() ??
          customer?['phone']?.toString() ??
          '-',
      serviceId: serviceId,
      serviceName:
          data['serviceName']?.toString() ??
          service?['name']?.toString() ??
          'Service',
      serviceDescription:
          data['serviceDescription']?.toString() ??
          service?['description']?.toString() ??
          'Wellness treatment',
      therapistId: therapistId,
      therapistName:
          data['therapistName']?.toString() ??
          therapist?['name']?.toString() ??
          'Unassigned',
      roomId: roomId,
      roomName:
          data['roomName']?.toString() ?? room?['name']?.toString() ?? 'Room',
      notes: data['notes']?.toString() ?? '',
      price: _readDouble(data['totalPrice'] ?? data['price']),
      serviceItems: _readServiceItems(
        data['serviceItems'],
        serviceId: serviceId,
        serviceName:
            data['serviceName']?.toString() ??
            service?['name']?.toString() ??
            'Service',
        service: service,
        fallbackPrice: _readDouble(data['totalPrice'] ?? data['price']),
      ),
      therapistCommissionData: {
        'id': therapistId,
        'name': therapist?['name'],
        'serviceCommissions': therapist?['serviceCommissions'],
      },
    );
  }

  static List<Map<String, dynamic>> _readServiceItems(
    Object? value, {
    required String serviceId,
    required String serviceName,
    required Map<String, dynamic>? service,
    required double fallbackPrice,
  }) {
    if (value is List && value.isNotEmpty) {
      return value.whereType<Map>().map((item) {
        final data = Map<String, dynamic>.from(item);
        final itemId =
            data['id']?.toString() ?? data['serviceId']?.toString() ?? '';
        final linkedService = itemId == serviceId ? service : null;
        return {
          ...data,
          'id': itemId,
          'name':
              data['name']?.toString() ??
              linkedService?['name']?.toString() ??
              serviceName,
          'duration': _readInt(
            data['duration'] ?? linkedService?['duration'],
            60,
          ),
          'price': _readDouble(data['price'] ?? linkedService?['price']),
          'therapistCommission': _readDouble(
            data['therapistCommission'] ??
                linkedService?['therapistCommission'],
          ),
          'counterCommission': _readDouble(
            data['counterCommission'] ?? linkedService?['counterCommission'],
          ),
        };
      }).toList();
    }

    return [
      {
        'id': serviceId,
        'name': serviceName,
        'duration': _readInt(service?['duration'], 60),
        'price': fallbackPrice > 0
            ? fallbackPrice
            : _readDouble(service?['price']),
        'therapistCommission': _readDouble(service?['therapistCommission']),
        'counterCommission': _readDouble(service?['counterCommission']),
      },
    ];
  }

  static String _readDateKey(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return DateFormat('yyyy-MM-dd').format(DateTime.now());
    return raw.length >= 10 ? raw.substring(0, 10) : raw;
  }

  static DateTime _readDate(String dateKey, Object? value) {
    return DateTime.tryParse(dateKey) ?? _stripTime(DateTime.now());
  }

  static bool _isGuestName(Object? value) {
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    return normalized.isEmpty ||
        normalized == 'guest' ||
        normalized == 'guest account' ||
        normalized == 'walk-in guest';
  }

  int get startMinutes {
    return _minutesFromDate(startAt, date) ?? _timeToMinutes(startTime);
  }

  int get endMinutes {
    final timestampMinutes = _minutesFromDate(endAt, date);
    if (timestampMinutes != null) return timestampMinutes;
    final start = _timeToMinutes(startTime);
    var end = _timeToMinutes(endTime);
    if (end <= start) end += 24 * 60;
    return end;
  }

  int get hour => startMinutes ~/ 60;
  int get durationMinutes => (endMinutes - startMinutes).clamp(0, 1440);
  String get startLabel => _clockLabel(startTime);
  String get endLabel => _clockLabel(endTime);
  String get timeRange => '$startLabel - $endLabel';
  String get priceLabel => 'RM ${price.toStringAsFixed(0)}';
  String get servicePriceLabel => '$serviceName - $priceLabel';
  bool get isCompleted => status == 'completed';
  bool get isCancelled => status == 'cancelled' || status == 'canceled';
  bool get isPending => !isCompleted && !isCancelled;
  bool get isGuestAccount =>
      customerId.trim().isEmpty || customerId == 'walk_in_guest';

  String get statusLabel {
    if (isCompleted) return 'Completed';
    if (isCancelled) return 'Cancelled';
    return 'Pending';
  }

  String get initials {
    final parts = customerName.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return customerName.isEmpty ? '?' : customerName[0].toUpperCase();
  }

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return customerName.toLowerCase().contains(q) ||
        customerPhone.toLowerCase().contains(q) ||
        serviceName.toLowerCase().contains(q) ||
        therapistName.toLowerCase().contains(q) ||
        roomName.toLowerCase().contains(q);
  }
}

class _AppointmentGroup {
  final String id;
  final String appointmentGroupId;
  final List<_ScheduleAppointment> appointments;

  const _AppointmentGroup({
    required this.id,
    required this.appointmentGroupId,
    required this.appointments,
  });

  _ScheduleAppointment get primary => appointments.first;
  bool get isGroup => appointmentGroupId.isNotEmpty && appointments.length > 1;
  int get paxCount => appointments.length;
  DateTime get date => primary.date;
  String get dateKey => primary.dateKey;
  String get customerName => primary.customerName;
  String get customerPhone => primary.customerPhone;
  String get initials => primary.initials;
  bool get isGuestAccount => primary.isGuestAccount;
  bool get isCancelled => appointments.every((a) => a.isCancelled);
  bool get isCompleted => appointments.every((a) => a.isCompleted);
  bool get isPending => !isCompleted && !isCancelled;
  String get statusLabel => isCompleted
      ? 'Completed'
      : isCancelled
      ? 'Cancelled'
      : 'Pending';

  int get startMinutes =>
      appointments.map((a) => a.startMinutes).reduce((a, b) => a < b ? a : b);
  int get endMinutes =>
      appointments.map((a) => a.endMinutes).reduce((a, b) => a > b ? a : b);
  int get durationMinutes => (endMinutes - startMinutes).clamp(0, 1440);
  String get timeRange =>
      '${_clockLabel(_minutesToTime(startMinutes))} - ${_clockLabel(_minutesToTime(endMinutes))}';
  double get price => appointments.fold(0, (total, a) => total + a.price);
  String get priceLabel => 'RM ${price.toStringAsFixed(0)}';

  String get serviceName {
    if (!isGroup) return primary.serviceName;
    return '$paxCount pax services';
  }

  String get serviceDescription {
    if (!isGroup) return primary.serviceDescription;
    return '${appointments.length} service allocations';
  }

  String get servicePriceLabel {
    if (!isGroup) return primary.servicePriceLabel;
    return '$serviceName - $priceLabel';
  }

  String get therapistName {
    if (!isGroup) return primary.therapistName;
    final count = appointments
        .map((a) => a.therapistId.isNotEmpty ? a.therapistId : a.therapistName)
        .toSet()
        .length;
    return '$count staff assigned';
  }

  String get roomName {
    if (!isGroup) return primary.roomName;
    final count = appointments
        .map((a) => a.roomId.isNotEmpty ? a.roomId : a.roomName)
        .toSet()
        .length;
    return '$count resources';
  }

  List<Map<String, dynamic>> get serviceItems {
    final items = <Map<String, dynamic>>[];
    for (var index = 0; index < appointments.length; index++) {
      final appointment = appointments[index];
      for (final item in appointment.serviceItems) {
        items.add({
          ...item,
          'paxIndex': index + 1,
          'paxLabel': 'Pax ${index + 1}',
          'paxCustomerName': appointment.customerName,
          'assignedTherapistId':
              item['assignedTherapistId'] ?? appointment.therapistId,
          'assignedTherapistName':
              item['assignedTherapistName'] ?? appointment.therapistName,
          'assignedRoomId': item['assignedRoomId'] ?? appointment.roomId,
          'assignedRoomName': item['assignedRoomName'] ?? appointment.roomName,
        });
      }
    }
    return items;
  }

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return appointments.any((a) => a.matches(q));
  }
}

class AppointmentsScreen extends StatefulWidget {
  final String userRole;

  const AppointmentsScreen({super.key, required this.userRole});

  @override
  State<AppointmentsScreen> createState() => _AppointmentsScreenState();
}

class _AppointmentsScreenState extends State<AppointmentsScreen> {
  final _appointmentRepository = AppointmentRepository();
  final _dashboardRepository = DashboardRepository();
  final _businessSettingsTable = SupabaseTableService('business_settings');

  late DateTime _selectedDate;
  late DateTime _windowStart;
  final _searchController = TextEditingController();
  List<_ScheduleAppointment> _appointments = [];
  _AppointmentGroup? _selectedGroup;
  int _openHour = 9;
  int _closeHour = 21;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedDate = _stripTime(DateTime.now());
    _windowStart = _startOfWeek(_selectedDate);
    _searchController.addListener(() => setState(() {}));
    _loadAppointments();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  static DateTime _startOfWeek(DateTime date) {
    final clean = _stripTime(date);
    return clean.subtract(Duration(days: clean.weekday % 7));
  }

  String _dateKey(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

  int _parseBusinessMinutes(Object? value, int fallback) {
    final raw = value?.toString().trim() ?? '';
    final parts = raw.split(':');
    if (parts.length < 2) return fallback;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return fallback;
    return hour * 60 + minute;
  }

  Future<void> _loadBusinessHours() async {
    try {
      final rows = await _businessSettingsTable.list(limit: 1);
      final row = rows.isEmpty ? null : rows.first;
      final openMinutes = _parseBusinessMinutes(row?['openTime'], 9 * 60);
      var closeMinutes = _parseBusinessMinutes(row?['closeTime'], 21 * 60);
      if (closeMinutes <= openMinutes) closeMinutes += 24 * 60;
      final open = openMinutes ~/ 60;
      final close = (closeMinutes / 60).ceil();
      if (!mounted) return;
      setState(() {
        _openHour = open;
        _closeHour = close;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _openHour = 9;
        _closeHour = 21;
      });
    }
  }

  List<DateTime> get _visibleDays =>
      List.generate(7, (index) => _windowStart.add(Duration(days: index)));

  List<_AppointmentGroup> get _appointmentGroups {
    final byGroup = <String, List<_ScheduleAppointment>>{};
    for (final appointment in _appointments) {
      final key = appointment.appointmentGroupId.isNotEmpty
          ? appointment.appointmentGroupId
          : appointment.id;
      byGroup.putIfAbsent(key, () => []).add(appointment);
    }

    final groups =
        byGroup.entries.map((entry) {
          final items = entry.value
            ..sort((a, b) {
              final start = a.startMinutes.compareTo(b.startMinutes);
              if (start != 0) return start;
              return a.customerName.compareTo(b.customerName);
            });
          final groupId = items.first.appointmentGroupId;
          return _AppointmentGroup(
            id: entry.key,
            appointmentGroupId: groupId,
            appointments: items,
          );
        }).toList()..sort((a, b) {
          final dateCompare = a.dateKey.compareTo(b.dateKey);
          if (dateCompare != 0) return dateCompare;
          return a.startMinutes.compareTo(b.startMinutes);
        });
    return groups;
  }

  List<_AppointmentGroup> get _filteredGroups {
    return _appointmentGroups
        .where((group) => group.matches(_searchController.text))
        .toList();
  }

  List<_AppointmentGroup> get _selectedDayGroups {
    final key = _dateKey(_selectedDate);
    final list = _filteredGroups.where((a) => a.dateKey == key).toList();
    list.sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
    return list;
  }

  List<_ScheduleAppointment> _appointmentsForDay(DateTime date) {
    final key = _dateKey(date);
    return _appointmentGroups
        .where((group) => group.dateKey == key)
        .map((group) => group.primary)
        .toList();
  }

  int get _pendingCount => _selectedDayGroups.where((a) => a.isPending).length;

  double get _selectedDaySales =>
      _selectedDayGroups.fold<double>(0, (total, group) => total + group.price);

  Future<void> _loadAppointments() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _loadBusinessHours();
      final startKey = _dateKey(_windowStart);
      final endKey = _dateKey(_windowStart.add(const Duration(days: 6)));
      final appointmentRows = await _appointmentRepository
          .getAppointmentsInDateRange(startKey, endKey);
      final customerIds = appointmentRows
          .map((data) => data['customerId']?.toString() ?? '')
          .where((id) => id.isNotEmpty);
      final serviceIds = appointmentRows
          .map((data) => data['serviceId']?.toString() ?? '')
          .where((id) => id.isNotEmpty);
      final therapistIds = appointmentRows
          .map((data) => data['therapistId']?.toString() ?? '')
          .where((id) => id.isNotEmpty);
      final roomIds = appointmentRows
          .map((data) => data['roomId']?.toString() ?? '')
          .where((id) => id.isNotEmpty);

      final customers = await _dashboardRepository.loadByIds(
        'customers',
        customerIds,
      );
      final services = await _dashboardRepository.loadByIds(
        'services',
        serviceIds,
      );
      final therapists = await _dashboardRepository.loadByIds(
        'therapists',
        therapistIds,
      );
      final rooms = await _dashboardRepository.loadByIds('rooms', roomIds);

      final appointments =
          appointmentRows
              .where((data) {
                final type = data['type']?.toString().trim().toLowerCase();
                return type == null ||
                    type.isEmpty ||
                    type == 'appointment' ||
                    type == 'online';
              })
              .map(
                (data) => _ScheduleAppointment.fromMap(
                  data,
                  customers: customers,
                  services: services,
                  therapists: therapists,
                  rooms: rooms,
                ),
              )
              .where((appointment) => !appointment.isCancelled)
              .toList()
            ..sort((a, b) {
              final dateCompare = a.dateKey.compareTo(b.dateKey);
              if (dateCompare != 0) return dateCompare;
              return a.startMinutes.compareTo(b.startMinutes);
            });

      if (!mounted) return;
      setState(() {
        _appointments = appointments;
        if (_selectedGroup != null) {
          final matches = _appointmentGroups
              .where((group) => group.id == _selectedGroup!.id)
              .toList();
          _selectedGroup = matches.isEmpty ? null : matches.first;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _moveDays(int days) {
    setState(() {
      _windowStart = _windowStart.add(Duration(days: days));
      _selectedDate = _selectedDate.add(Duration(days: days));
      _selectedGroup = null;
    });
    _loadAppointments();
  }

  Future<void> _openCalendarPicker() async {
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (context) => _MonthCalendarDialog(initialDate: _selectedDate),
    );
    if (picked == null) return;

    setState(() {
      _selectedDate = _stripTime(picked);
      _windowStart = _startOfWeek(picked);
      _selectedGroup = null;
    });
    _loadAppointments();
  }

  void _selectDate(DateTime date) {
    setState(() {
      _selectedDate = _stripTime(date);
      _selectedGroup = null;
    });
  }

  Future<void> _openBooking() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NewAppointmentScreen(userRole: widget.userRole),
      ),
    );
    if (mounted) _loadAppointments();
  }

  Future<void> _updateStatus(
    _ScheduleAppointment appointment,
    String status,
  ) async {
    await _appointmentRepository.updateAppointment(appointment.id, {
      'status': status,
    });
    await _loadAppointments();
  }

  Future<void> _cancelAppointment(_ScheduleAppointment appointment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel booking?'),
        content: Text(
          '${appointment.customerName} at ${appointment.timeRange} will be marked as cancelled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel Booking'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _updateStatus(appointment, 'cancelled');
    if (mounted) setState(() => _selectedGroup = null);
  }

  Future<void> _cancelAppointmentGroup(_AppointmentGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel group booking?'),
        content: Text(
          '${group.customerName} (${group.paxCount} pax) at ${group.timeRange} will be marked as cancelled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel Booking'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final appointment in group.appointments) {
      await _appointmentRepository.updateAppointment(appointment.id, {
        'status': 'cancelled',
      });
    }
    await _loadAppointments();
    if (mounted) setState(() => _selectedGroup = null);
  }

  Future<void> _openEdit(_ScheduleAppointment appointment) async {
    final saved = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(
        builder: (_) => NewAppointmentScreen(
          userRole: widget.userRole,
          editPayload: _editPayloadForAppointments([appointment]),
        ),
      ),
    );
    if (saved != null && mounted) {
      await _loadAppointments();
    }
  }

  Future<void> _openEditGroup(
    _AppointmentGroup group, {
    String? activeAppointmentId,
  }) async {
    final result = await Navigator.push<Object?>(
      context,
      MaterialPageRoute(
        builder: (_) => NewAppointmentScreen(
          userRole: widget.userRole,
          editPayload: _editPayloadForAppointments(
            group.appointments,
            activeAppointmentId: activeAppointmentId,
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;

    await _loadAppointments();
    if (result == 'confirmGroupPayment') {
      final updated = _appointmentGroups
          .where((item) => item.id == group.id)
          .toList();
      if (updated.isNotEmpty && mounted) {
        await _openGroupCheckout(updated.first);
      }
    }
  }

  AppointmentEditPayload _editPayloadForAppointments(
    List<_ScheduleAppointment> appointments, {
    String? activeAppointmentId,
  }) {
    final sorted = [...appointments]
      ..sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
    final primary = sorted.first;
    final activeIndex = sorted.indexWhere((a) => a.id == activeAppointmentId);
    return AppointmentEditPayload(
      appointmentId: sorted.length == 1 ? primary.id : null,
      appointmentGroupId: primary.appointmentGroupId.isEmpty
          ? null
          : primary.appointmentGroupId,
      date: primary.date,
      customerId: primary.customerId,
      customerName: primary.customerName,
      customerPhone: primary.customerPhone,
      activePaxIndex: activeIndex < 0 ? 0 : activeIndex,
      allocations: sorted.map((appointment) {
        final serviceIds = <String>{
          ...appointment.serviceItems
              .map((item) => item['id']?.toString() ?? '')
              .where((id) => id.isNotEmpty),
          if (appointment.serviceId.isNotEmpty) appointment.serviceId,
        }.toList();
        return AppointmentEditAllocation(
          appointmentId: appointment.id,
          serviceIds: serviceIds,
          therapistId: appointment.therapistId,
          roomId: appointment.roomId,
          startTime: appointment.startTime,
          endTime: appointment.endTime,
        );
      }).toList(),
    );
  }

  Future<void> _openCheckout(_ScheduleAppointment appointment) async {
    final checkedOut = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _AppointmentCheckoutSheet(appointment: appointment),
    );
    if (checkedOut == true && mounted) {
      await _loadAppointments();
    }
  }

  Future<void> _openGroupCheckout(_AppointmentGroup group) async {
    final checkedOut = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _AppointmentGroupCheckoutSheet(group: group),
    );
    if (checkedOut == true && mounted) {
      await _loadAppointments();
    }
  }

  void _showMobileSummary(_AppointmentGroup group) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: group.isGroup
              ? _AppointmentGroupSummaryPanel(
                  group: group,
                  compact: true,
                  onClose: () => Navigator.pop(context),
                  onEditGroup: () async {
                    Navigator.pop(context);
                    await _openEditGroup(group);
                  },
                  onEditPax: (appointment) async {
                    Navigator.pop(context);
                    await _openEditGroup(
                      group,
                      activeAppointmentId: appointment.id,
                    );
                  },
                  onComplete: group.isPending
                      ? () async {
                          Navigator.pop(context);
                          await _openGroupCheckout(group);
                        }
                      : null,
                  onCancel: group.isCompleted
                      ? null
                      : () async {
                          Navigator.pop(context);
                          await _cancelAppointmentGroup(group);
                        },
                )
              : _AppointmentSummaryPanel(
                  appointment: group.primary,
                  compact: true,
                  onClose: () => Navigator.pop(context),
                  onEdit: () async {
                    Navigator.pop(context);
                    await _openEdit(group.primary);
                  },
                  onComplete: group.isPending
                      ? () async {
                          Navigator.pop(context);
                          await _openCheckout(group.primary);
                        }
                      : null,
                  onCancel: group.isCompleted
                      ? null
                      : () async {
                          Navigator.pop(context);
                          await _cancelAppointment(group.primary);
                        },
                ),
        ),
      ),
    );
  }

  void _showMobileCluster(List<_AppointmentGroup> appointments) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          itemCount: appointments.length,
          separatorBuilder: (context, index) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final appointment = appointments[index];
            return _MobileAppointmentCard(
              appointment: appointment,
              onTap: () {
                Navigator.pop(context);
                setState(() => _selectedGroup = appointment);
                _showMobileSummary(appointment);
              },
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width >= 900;
    return Scaffold(
      backgroundColor: const Color(0xFFF4F8F2),
      body: SafeArea(child: isTablet ? _buildTablet() : _buildMobile()),
    );
  }

  Widget _buildMobile() {
    return Column(
      children: [
        _MobileScheduleHeader(
          monthLabel: DateFormat('MMMM yyyy').format(_selectedDate),
          onBack: () => Navigator.pop(context),
          onOpenCalendar: _openCalendarPicker,
          onAdd: _openBooking,
        ),
        _ScheduleCalendarStrip(
          days: _visibleDays,
          selectedDate: _selectedDate,
          appointmentsForDay: _appointmentsForDay,
          onSelect: _selectDate,
          onPrevious: () => _moveDays(-1),
          onNext: () => _moveDays(1),
          compact: true,
        ),
        Expanded(child: _buildMobileBody()),
      ],
    );
  }

  Widget _buildMobileBody() {
    if (_loading) return const _ScheduleLoading();
    if (_error != null) return _ScheduleError(onRetry: _loadAppointments);

    final appointments = _selectedDayGroups;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
      children: [
        _MobileDaySummary(
          date: _selectedDate,
          count: appointments.length,
          pending: _pendingCount,
          sales: _selectedDaySales,
        ),
        const SizedBox(height: 14),
        if (appointments.isEmpty)
          const _ScheduleEmptyState()
        else
          _MobileTimeline(
            appointments: appointments,
            openHour: _openHour,
            closeHour: _closeHour,
            selectedDate: _selectedDate,
            onTapAppointment: (appointment) {
              setState(() => _selectedGroup = appointment);
              _showMobileSummary(appointment);
            },
            onTapCluster: _showMobileCluster,
          ),
      ],
    );
  }

  Widget _buildTablet() {
    return Stack(
      children: [
        Positioned.fill(
          child: Column(
            children: [
              _TabletScheduleHeader(
                monthLabel: DateFormat('MMMM yyyy').format(_selectedDate),
                searchController: _searchController,
                onBack: () => Navigator.pop(context),
                onOpenCalendar: _openCalendarPicker,
                onAdd: _openBooking,
              ),
              _ScheduleCalendarStrip(
                days: _visibleDays,
                selectedDate: _selectedDate,
                appointmentsForDay: _appointmentsForDay,
                onSelect: _selectDate,
                onPrevious: () => _moveDays(-1),
                onNext: () => _moveDays(1),
                compact: false,
              ),
              Expanded(child: _buildTabletBody()),
            ],
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          top: 198,
          right: _selectedGroup == null ? -390 : 18,
          bottom: 18,
          width: 360,
          child: IgnorePointer(
            ignoring: _selectedGroup == null,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 140),
              opacity: _selectedGroup == null ? 0 : 1,
              child: _selectedGroup == null
                  ? const SizedBox.shrink()
                  : _selectedGroup!.isGroup
                  ? _AppointmentGroupSummaryPanel(
                      group: _selectedGroup!,
                      onClose: () => setState(() => _selectedGroup = null),
                      onEditGroup: () => _openEditGroup(_selectedGroup!),
                      onEditPax: (appointment) => _openEditGroup(
                        _selectedGroup!,
                        activeAppointmentId: appointment.id,
                      ),
                      onComplete: _selectedGroup!.isPending
                          ? () => _openGroupCheckout(_selectedGroup!)
                          : null,
                      onCancel: _selectedGroup!.isCompleted
                          ? null
                          : () => _cancelAppointmentGroup(_selectedGroup!),
                    )
                  : _AppointmentSummaryPanel(
                      appointment: _selectedGroup!.primary,
                      onClose: () => setState(() => _selectedGroup = null),
                      onEdit: () => _openEdit(_selectedGroup!.primary),
                      onComplete: _selectedGroup!.isPending
                          ? () => _openCheckout(_selectedGroup!.primary)
                          : null,
                      onCancel: _selectedGroup!.isCompleted
                          ? null
                          : () => _cancelAppointment(_selectedGroup!.primary),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTabletBody() {
    if (_loading) return const _ScheduleLoading();
    if (_error != null) return _ScheduleError(onRetry: _loadAppointments);

    final appointments = _selectedDayGroups;
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 18, 28, 32),
      children: [
        _TabletDaySummary(
          date: _selectedDate,
          count: appointments.length,
          pending: _pendingCount,
        ),
        const SizedBox(height: 12),
        if (appointments.isEmpty)
          const _ScheduleEmptyState()
        else
          _TabletTimeline(
            appointments: appointments,
            openHour: _openHour,
            closeHour: _closeHour,
            selectedDate: _selectedDate,
            selectedId: _selectedGroup?.id,
            onSelect: (appointment) =>
                setState(() => _selectedGroup = appointment),
          ),
      ],
    );
  }
}

class _MobileScheduleHeader extends StatelessWidget {
  final String monthLabel;
  final VoidCallback onBack;
  final VoidCallback onOpenCalendar;
  final VoidCallback onAdd;

  const _MobileScheduleHeader({
    required this.monthLabel,
    required this.onBack,
    required this.onOpenCalendar,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
            color: const Color(0xFF111827),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                onTap: onOpenCalendar,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.calendar_today_outlined,
                        size: 16,
                        color: Color(0xFF2F7D59),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          monthLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111827),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.keyboard_arrow_down,
                        size: 18,
                        color: Color(0xFF6B7280),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 42,
            height: 42,
            child: FilledButton(
              onPressed: onAdd,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2F7D59),
                padding: EdgeInsets.zero,
                shape: const CircleBorder(),
              ),
              child: const Icon(Icons.add, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabletScheduleHeader extends StatelessWidget {
  final String monthLabel;
  final TextEditingController searchController;
  final VoidCallback onBack;
  final VoidCallback onOpenCalendar;
  final VoidCallback onAdd;

  const _TabletScheduleHeader({
    required this.monthLabel,
    required this.searchController,
    required this.onBack,
    required this.onOpenCalendar,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(
        children: [
          IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back)),
          const SizedBox(width: 4),
          InkWell(
            onTap: onOpenCalendar,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.calendar_today_outlined,
                    size: 16,
                    color: Color(0xFF2F7D59),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    monthLabel,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.keyboard_arrow_down,
                    size: 18,
                    color: Color(0xFF6B7280),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          SizedBox(
            width: 330,
            child: TextField(
              controller: searchController,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search customers, services...',
                hintStyle: const TextStyle(fontSize: 14),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Text(
                    'Ctrl K',
                    style: TextStyle(
                      fontSize: 10,
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 17),
            label: const Text(
              'New Appointment',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF1B6B72),
              side: const BorderSide(color: Color(0xFF1B6B72)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthCalendarDialog extends StatefulWidget {
  final DateTime initialDate;

  const _MonthCalendarDialog({required this.initialDate});

  @override
  State<_MonthCalendarDialog> createState() => _MonthCalendarDialogState();
}

class _MonthCalendarDialogState extends State<_MonthCalendarDialog> {
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
    final selected = _stripTime(widget.initialDate);
    final today = _stripTime(DateTime.now());

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
                    onPressed: () => _moveMonth(1),
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
                  final cleanDay = _stripTime(day);
                  final isSelected = cleanDay == selected;
                  final isToday = cleanDay == today;
                  final inMonth = day.month == _visibleMonth.month;

                  return InkWell(
                    onTap: () => Navigator.pop(context, cleanDay),
                    borderRadius: BorderRadius.circular(18),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected
                            ? const Color(0xFF2F7D59)
                            : Colors.transparent,
                        border: isToday && !isSelected
                            ? Border.all(color: const Color(0xFF2F7D59))
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
                      foregroundColor: const Color(0xFF2F7D59),
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

class _ScheduleCalendarStrip extends StatelessWidget {
  final List<DateTime> days;
  final DateTime selectedDate;
  final List<_ScheduleAppointment> Function(DateTime date) appointmentsForDay;
  final ValueChanged<DateTime> onSelect;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool compact;

  const _ScheduleCalendarStrip({
    required this.days,
    required this.selectedDate,
    required this.appointmentsForDay,
    required this.onSelect,
    required this.onPrevious,
    required this.onNext,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: EdgeInsets.fromLTRB(
        compact ? 12 : 24,
        10,
        compact ? 12 : 24,
        12,
      ),
      child: Row(
        children: [
          if (!compact) ...[
            _CalendarNavButton(
              icon: Icons.chevron_left,
              compact: compact,
              onPressed: onPrevious,
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Row(
              children: days.map((day) {
                final selected = _stripTime(day) == _stripTime(selectedDate);
                final count = appointmentsForDay(day).length;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 6),
                    child: _DayTile(
                      day: day,
                      selected: selected,
                      count: count,
                      compact: compact,
                      onTap: () => onSelect(day),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 10),
            _CalendarNavButton(
              icon: Icons.chevron_right,
              compact: compact,
              onPressed: onNext,
            ),
          ],
        ],
      ),
    );
  }
}

class _CalendarNavButton extends StatelessWidget {
  final IconData icon;
  final bool compact;
  final VoidCallback onPressed;

  const _CalendarNavButton({
    required this.icon,
    required this.compact,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final size = compact ? 34.0 : 44.0;
    return SizedBox(
      width: size,
      height: size,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(compact ? 17 : 12),
          ),
          side: const BorderSide(color: Color(0xFFE5E7EB)),
          backgroundColor: Colors.white,
        ),
        child: Icon(
          icon,
          size: compact ? 18 : 22,
          color: const Color(0xFF111827),
        ),
      ),
    );
  }
}

class _DayTile extends StatelessWidget {
  final DateTime day;
  final bool selected;
  final int count;
  final bool compact;
  final VoidCallback onTap;

  const _DayTile({
    required this.day,
    required this.selected,
    required this.count,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: compact ? 68 : 92,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF2F7D59) : Colors.white,
          borderRadius: BorderRadius.circular(compact ? 8 : 10),
          border: Border.all(
            color: selected ? const Color(0xFF2F7D59) : const Color(0xFFE5E7EB),
          ),
          boxShadow: selected
              ? const [
                  BoxShadow(
                    color: Color(0x1F2F7D59),
                    blurRadius: 10,
                    offset: Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              DateFormat('EEE').format(day).toUpperCase(),
              style: TextStyle(
                fontSize: compact ? 9 : 12,
                fontWeight: FontWeight.w800,
                color: selected ? Colors.white : const Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              DateFormat('d').format(day),
              style: TextStyle(
                fontSize: compact ? 17 : 28,
                fontWeight: FontWeight.w900,
                color: selected ? Colors.white : const Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              selected ? 'Today' : '$count booking${count == 1 ? '' : 's'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compact ? 9 : 12,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : const Color(0xFF6B7280),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileDaySummary extends StatelessWidget {
  final DateTime date;
  final int count;
  final int pending;
  final double sales;

  const _MobileDaySummary({
    required this.date,
    required this.count,
    required this.pending,
    required this.sales,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${DateFormat('EEE, d MMM').format(date).toUpperCase()} - TODAY',
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '$count booking${count == 1 ? '' : 's'}',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      'RM ${sales.toStringAsFixed(0)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        _CountPill(color: const Color(0xFF16A34A), value: count - pending),
        const SizedBox(width: 6),
        _CountPill(color: const Color(0xFF2563EB), value: pending),
      ],
    );
  }
}

class _TabletDaySummary extends StatelessWidget {
  final DateTime date;
  final int count;
  final int pending;

  const _TabletDaySummary({
    required this.date,
    required this.count,
    required this.pending,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            DateFormat('EEEE, d MMMM yyyy').format(date),
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w900,
              color: Color(0xFF111827),
            ),
          ),
        ),
        _LegendPill(color: const Color(0xFF16A34A), label: '$count Bookings'),
        const SizedBox(width: 10),
        _LegendPill(color: const Color(0xFF2563EB), label: '$pending Pending'),
      ],
    );
  }
}

class _CountPill extends StatelessWidget {
  final Color color;
  final int value;

  const _CountPill({required this.color, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            '$value',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _LegendPill extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendPill({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _TimelinePlacement {
  final _AppointmentGroup appointment;
  final int lane;
  final int laneCount;

  const _TimelinePlacement({
    required this.appointment,
    required this.lane,
    required this.laneCount,
  });
}

double _calculateTop(int startMinutes, int openHour, double hourHeight) {
  final minutesFromStart = startMinutes - openHour * 60;
  return minutesFromStart * (hourHeight / 60);
}

double _calculateHeight(int startMinutes, int endMinutes, double hourHeight) {
  final duration = (endMinutes - startMinutes).clamp(0, 24 * 60);
  return duration * (hourHeight / 60);
}

List<List<_AppointmentGroup>> _buildOverlapGroups(
  List<_AppointmentGroup> appointments,
) {
  final sorted = [...appointments]
    ..sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
  final groups = <List<_AppointmentGroup>>[];
  var current = <_AppointmentGroup>[];
  var currentEnd = -1;

  for (final appointment in sorted) {
    if (current.isEmpty || appointment.startMinutes < currentEnd) {
      current.add(appointment);
      if (appointment.endMinutes > currentEnd) {
        currentEnd = appointment.endMinutes;
      }
    } else {
      groups.add(current);
      current = [appointment];
      currentEnd = appointment.endMinutes;
    }
  }

  if (current.isNotEmpty) groups.add(current);
  return groups;
}

List<_TimelinePlacement> _assignOverlapLanes(
  List<_AppointmentGroup> appointments,
) {
  final placements = <_TimelinePlacement>[];
  for (final group in _buildOverlapGroups(appointments)) {
    final lanesEnd = <int>[];
    final laneByAppointment = <String, int>{};

    for (final appointment in group) {
      var lane = lanesEnd.indexWhere((end) => appointment.startMinutes >= end);
      if (lane == -1) {
        lane = lanesEnd.length;
        lanesEnd.add(appointment.endMinutes);
      } else {
        lanesEnd[lane] = appointment.endMinutes;
      }
      laneByAppointment[appointment.id] = lane;
    }

    final laneCount = lanesEnd.length.clamp(1, 6);
    for (final appointment in group) {
      placements.add(
        _TimelinePlacement(
          appointment: appointment,
          lane: laneByAppointment[appointment.id] ?? 0,
          laneCount: laneCount,
        ),
      );
    }
  }
  return placements;
}

class _MobileTimeline extends StatelessWidget {
  final List<_AppointmentGroup> appointments;
  final int openHour;
  final int closeHour;
  final DateTime selectedDate;
  final ValueChanged<_AppointmentGroup> onTapAppointment;
  final ValueChanged<List<_AppointmentGroup>> onTapCluster;

  const _MobileTimeline({
    required this.appointments,
    required this.openHour,
    required this.closeHour,
    required this.selectedDate,
    required this.onTapAppointment,
    required this.onTapCluster,
  });

  @override
  Widget build(BuildContext context) {
    const hourHeight = 72.0;
    const labelWidth = 38.0;
    const gutter = 10.0;
    final totalHeight = (closeHour - openHour) * hourHeight;
    final groups = _buildOverlapGroups(appointments);

    return SizedBox(
      height: totalHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final canvasWidth = constraints.maxWidth - labelWidth - gutter;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              _TimelineGrid(
                openHour: openHour,
                closeHour: closeHour,
                hourHeight: hourHeight,
                labelWidth: labelWidth,
                gutter: gutter,
                showNowLine:
                    _stripTime(selectedDate) == _stripTime(DateTime.now()),
              ),
              for (final group in groups)
                _buildMobilePositionedGroup(
                  group: group,
                  openHour: openHour,
                  hourHeight: hourHeight,
                  left: labelWidth + gutter,
                  width: canvasWidth,
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMobilePositionedGroup({
    required List<_AppointmentGroup> group,
    required int openHour,
    required double hourHeight,
    required double left,
    required double width,
  }) {
    final start = group
        .map((a) => a.startMinutes)
        .reduce((a, b) => a < b ? a : b);
    final end = group.map((a) => a.endMinutes).reduce((a, b) => a > b ? a : b);
    final top = _calculateTop(start, openHour, hourHeight);
    final height = _calculateHeight(
      start,
      end,
      hourHeight,
    ).clamp(42.0, 220.0).toDouble();

    if (group.length == 1) {
      final appointment = group.first;
      return Positioned(
        top: top,
        left: left,
        width: width,
        height: height,
        child: _MobileTimelineBlock(
          appointment: appointment,
          onTap: () => onTapAppointment(appointment),
        ),
      );
    }

    return Positioned(
      top: top,
      left: left,
      width: width,
      height: height,
      child: _MobileCollapsedBlock(
        appointments: group,
        onTap: () => onTapCluster(group),
      ),
    );
  }
}

class _TabletTimeline extends StatelessWidget {
  final List<_AppointmentGroup> appointments;
  final int openHour;
  final int closeHour;
  final DateTime selectedDate;
  final String? selectedId;
  final ValueChanged<_AppointmentGroup> onSelect;

  const _TabletTimeline({
    required this.appointments,
    required this.openHour,
    required this.closeHour,
    required this.selectedDate,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    const hourHeight = 78.0;
    const labelWidth = 58.0;
    const gutter = 16.0;
    final totalHeight = (closeHour - openHour) * hourHeight;
    final placements = _assignOverlapLanes(appointments);

    return SizedBox(
      height: totalHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final canvasLeft = labelWidth + gutter;
          final canvasWidth = constraints.maxWidth - canvasLeft;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              _TimelineGrid(
                openHour: openHour,
                closeHour: closeHour,
                hourHeight: hourHeight,
                labelWidth: labelWidth,
                gutter: gutter,
                showNowLine:
                    _stripTime(selectedDate) == _stripTime(DateTime.now()),
              ),
              for (final placement in placements)
                _buildTabletPositionedCard(
                  placement: placement,
                  openHour: openHour,
                  hourHeight: hourHeight,
                  canvasLeft: canvasLeft,
                  canvasWidth: canvasWidth,
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTabletPositionedCard({
    required _TimelinePlacement placement,
    required int openHour,
    required double hourHeight,
    required double canvasLeft,
    required double canvasWidth,
  }) {
    const spacing = 10.0;
    final appointment = placement.appointment;
    final laneWidth =
        (canvasWidth - spacing * (placement.laneCount - 1)) /
        placement.laneCount;
    final left = canvasLeft + placement.lane * (laneWidth + spacing);
    final top = _calculateTop(appointment.startMinutes, openHour, hourHeight);
    final height = _calculateHeight(
      appointment.startMinutes,
      appointment.endMinutes,
      hourHeight,
    ).clamp(88.0, 260.0).toDouble();

    return Positioned(
      top: top,
      left: left,
      width: laneWidth,
      height: height,
      child: _TabletAppointmentCardTile(
        appointment: appointment,
        selected: selectedId == appointment.id,
        forceDotOnlyStatus: placement.laneCount >= 4,
        onTap: () => onSelect(appointment),
      ),
    );
  }
}

class _TimelineGrid extends StatelessWidget {
  final int openHour;
  final int closeHour;
  final double hourHeight;
  final double labelWidth;
  final double gutter;
  final bool showNowLine;

  const _TimelineGrid({
    required this.openHour,
    required this.closeHour,
    required this.hourHeight,
    required this.labelWidth,
    required this.gutter,
    required this.showNowLine,
  });

  @override
  Widget build(BuildContext context) {
    final totalHeight = (closeHour - openHour) * hourHeight;
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final nowTop = _calculateTop(nowMinutes, openHour, hourHeight);
    final showNow =
        showNowLine &&
        nowMinutes >= openHour * 60 &&
        nowMinutes <= closeHour * 60;

    return Stack(
      children: [
        for (var hour = openHour; hour <= closeHour; hour++) ...[
          Positioned(
            top: (hour - openHour) * hourHeight,
            left: 0,
            width: labelWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                _hourLabel(hour),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF4B5563),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          Positioned(
            top: (hour - openHour) * hourHeight,
            left: labelWidth + gutter,
            right: 0,
            child: const Divider(height: 1, color: Color(0xFFE5E7EB)),
          ),
          if (hour < closeHour)
            Positioned(
              top: (hour - openHour) * hourHeight + hourHeight / 2,
              left: labelWidth + gutter,
              right: 0,
              child: const Divider(height: 1, color: Color(0xFFF1F5F9)),
            ),
        ],
        if (showNow)
          Positioned(
            top: nowTop.clamp(0.0, totalHeight),
            left: 0,
            right: 0,
            child: Row(
              children: [
                const SizedBox(
                  width: 38,
                  child: Text(
                    'NOW',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: Color(0xFFE53935),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE53935),
                    shape: BoxShape.circle,
                  ),
                ),
                Expanded(
                  child: Container(height: 2, color: const Color(0xFFE53935)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MobileTimelineBlock extends StatelessWidget {
  final _AppointmentGroup appointment;
  final VoidCallback onTap;

  const _MobileTimelineBlock({required this.appointment, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = _statusColorsFor(
      appointment.isPending,
      appointment.isCompleted,
    );
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: colors.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.border),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 62;
            return Row(
              children: [
                Container(
                  width: 4,
                  height: double.infinity,
                  decoration: BoxDecoration(
                    color: colors.accent,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        appointment.customerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        compact
                            ? appointment.priceLabel
                            : appointment.servicePriceLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF4B5563),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 150,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          appointment.timeRange,
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF111827),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MobileCollapsedBlock extends StatelessWidget {
  final List<_AppointmentGroup> appointments;
  final VoidCallback onTap;

  const _MobileCollapsedBlock({
    required this.appointments,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final first = appointments.first;
    final colors = _statusColorsFor(first.isPending, first.isCompleted);
    final start = appointments
        .map((a) => a.startMinutes)
        .reduce((a, b) => a.compareTo(b) < 0 ? a : b);
    final end = appointments
        .map((a) => a.endMinutes)
        .reduce((a, b) => a.compareTo(b) > 0 ? a : b);
    final timeRange =
        '${_clockLabel(_minutesToTime(start))} - '
        '${_clockLabel(_minutesToTime(end))}';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F8F2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.border),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: colors.accent,
              child: Text(
                '${appointments.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${appointments.length} overlapping bookings',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF111827),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    timeRange,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF4B5563),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.keyboard_arrow_up, color: Color(0xFF2F7D59)),
          ],
        ),
      ),
    );
  }
}

class _MobileAppointmentCard extends StatelessWidget {
  final _AppointmentGroup appointment;
  final VoidCallback onTap;

  const _MobileAppointmentCard({
    required this.appointment,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _statusColorsFor(
      appointment.isPending,
      appointment.isCompleted,
    );
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE5E7EB)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0D000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 310;
            return Row(
              children: [
                Container(
                  width: 3,
                  height: 48,
                  decoration: BoxDecoration(
                    color: colors.accent,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        appointment.customerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        compact
                            ? appointment.priceLabel
                            : appointment.servicePriceLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF4B5563),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 150,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      appointment.timeRange,
                      maxLines: 1,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xFF111827),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TabletAppointmentCardTile extends StatelessWidget {
  final _AppointmentGroup appointment;
  final bool selected;
  final bool forceDotOnlyStatus;
  final VoidCallback onTap;

  const _TabletAppointmentCardTile({
    required this.appointment,
    required this.selected,
    required this.forceDotOnlyStatus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _statusColorsFor(
      appointment.isPending,
      appointment.isCompleted,
    );
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: colors.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? colors.accent : colors.border,
            width: selected ? 2 : 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0D000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 112;
            final tight =
                constraints.maxWidth < 220 || constraints.maxHeight < 104;
            final veryCompact =
                constraints.maxWidth < 180 || constraints.maxHeight < 86;
            final priceOnly =
                constraints.maxWidth < 150 || constraints.maxHeight < 66;
            final dotOnly =
                forceDotOnlyStatus ||
                priceOnly ||
                constraints.maxWidth < 145 ||
                constraints.maxHeight < 58;

            return Padding(
              padding: EdgeInsets.all(compact || tight ? 9 : 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 4,
                    decoration: BoxDecoration(
                      color: colors.accent,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  SizedBox(width: tight ? 8 : 10),
                  Expanded(
                    child: priceOnly
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              appointment.priceLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF111827),
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          )
                        : Column(
                            mainAxisAlignment: compact
                                ? MainAxisAlignment.spaceBetween
                                : MainAxisAlignment.start,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                appointment.customerName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: tight ? 13 : 15,
                                  color: const Color(0xFF111827),
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Text(
                                appointment.timeRange,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: tight ? 11 : 13,
                                  color: const Color(0xFF374151),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                veryCompact
                                    ? appointment.priceLabel
                                    : appointment.servicePriceLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF4B5563),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(width: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _TimelineStatusBadge(
                      label: appointment.statusLabel,
                      colors: colors,
                      compact: tight,
                      dotOnly: dotOnly,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AppointmentStatusStyle {
  final Color accent;
  final Color bg;
  final Color border;

  const _AppointmentStatusStyle({
    required this.accent,
    required this.bg,
    required this.border,
  });
}

class _AppointmentGroupSummaryPanel extends StatelessWidget {
  final _AppointmentGroup group;
  final bool compact;
  final VoidCallback onClose;
  final VoidCallback onEditGroup;
  final void Function(_ScheduleAppointment appointment) onEditPax;
  final VoidCallback? onComplete;
  final VoidCallback? onCancel;

  const _AppointmentGroupSummaryPanel({
    required this.group,
    required this.onClose,
    required this.onEditGroup,
    required this.onEditPax,
    required this.onComplete,
    required this.onCancel,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _statusColorsFor(group.isPending, group.isCompleted);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(compact ? 18 : 16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _StatusBadge(label: group.statusLabel, colors: colors),
                const SizedBox(width: 8),
                _StatusBadge(label: '${group.paxCount} pax', colors: colors),
                const Spacer(),
                IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: colors.accent.withValues(alpha: 0.78),
                  child: Text(
                    group.initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.customerName,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        group.customerPhone,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            _SummaryItem(
              icon: Icons.groups_2_outlined,
              label: 'Pax',
              title: '${group.paxCount}',
            ),
            _SummaryItem(
              icon: Icons.spa_outlined,
              label: 'Services',
              title: '${group.serviceItems.length} services',
            ),
            _SummaryItem(
              icon: Icons.person_outline,
              label: 'Staff',
              title: group.therapistName,
            ),
            _SummaryItem(
              icon: Icons.meeting_room_outlined,
              label: 'Resources',
              title: group.roomName,
            ),
            _SummaryItem(
              icon: Icons.calendar_today_outlined,
              label: 'Date',
              title: DateFormat('EEEE, d MMMM yyyy').format(group.date),
            ),
            _SummaryItem(
              icon: Icons.schedule_outlined,
              label: 'Time',
              title: group.timeRange,
            ),
            _SummaryItem(
              icon: Icons.payments_outlined,
              label: 'Price',
              title: 'RM ${group.price.toStringAsFixed(0)}',
            ),
            const SizedBox(height: 6),
            const Text(
              'Service Details',
              style: TextStyle(
                fontSize: 13,
                color: Color(0xFF111827),
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            for (var index = 0; index < group.appointments.length; index++)
              _GroupPaxDetailCard(
                index: index,
                appointment: group.appointments[index],
                onEdit: () => onEditPax(group.appointments[index]),
              ),
            const SizedBox(height: 12),
            _PanelActionButton(
              icon: Icons.edit_outlined,
              label: 'Edit Appointment',
              color: const Color(0xFFF59E0B),
              onPressed: onEditGroup,
            ),
            if (onComplete != null)
              _PanelActionButton(
                icon: Icons.point_of_sale_outlined,
                label: 'Confirm Group Payment',
                color: const Color(0xFF15803D),
                onPressed: onComplete!,
              ),
            if (onCancel != null)
              _PanelActionButton(
                icon: Icons.delete_outline,
                label: 'Cancel Group Booking',
                color: const Color(0xFFE53935),
                onPressed: onCancel!,
              ),
          ],
        ),
      ),
    );
  }
}

class _GroupPaxDetailCard extends StatelessWidget {
  final int index;
  final _ScheduleAppointment appointment;
  final VoidCallback onEdit;

  const _GroupPaxDetailCard({
    required this.index,
    required this.appointment,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                color: Color(0xFF2563EB),
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
                  'Pax ${index + 1} - ${appointment.customerName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  appointment.serviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF4B5563),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${appointment.therapistName} - ${appointment.roomName} - ${appointment.priceLabel}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Edit pax',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 18),
            color: const Color(0xFFF59E0B),
          ),
        ],
      ),
    );
  }
}

_AppointmentStatusStyle _statusColors(_ScheduleAppointment appointment) {
  return _statusColorsFor(appointment.isPending, appointment.isCompleted);
}

_AppointmentStatusStyle _statusColorsFor(bool isPending, bool isCompleted) {
  if (isPending) {
    return const _AppointmentStatusStyle(
      accent: Color(0xFF2563EB),
      bg: Color(0xFFEFF6FF),
      border: Color(0xFF93C5FD),
    );
  }
  if (isCompleted) {
    return const _AppointmentStatusStyle(
      accent: Color(0xFF15803D),
      bg: Color(0xFFF0FDF4),
      border: Color(0xFF86EFAC),
    );
  }
  return const _AppointmentStatusStyle(
    accent: Color(0xFF2F7D59),
    bg: Color(0xFFF0F7F0),
    border: Color(0xFFB7DCB9),
  );
}

class _AppointmentSummaryPanel extends StatelessWidget {
  final _ScheduleAppointment appointment;
  final bool compact;
  final VoidCallback onClose;
  final VoidCallback onEdit;
  final VoidCallback? onComplete;
  final VoidCallback? onCancel;

  const _AppointmentSummaryPanel({
    required this.appointment,
    required this.onClose,
    required this.onEdit,
    required this.onComplete,
    required this.onCancel,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _statusColors(appointment);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(compact ? 18 : 16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _StatusBadge(label: appointment.statusLabel, colors: colors),
                const Spacer(),
                IconButton(onPressed: onClose, icon: const Icon(Icons.close)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: colors.accent.withValues(alpha: 0.78),
                  child: Text(
                    appointment.initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        appointment.customerName,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        appointment.customerPhone,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            _SummaryItem(
              icon: Icons.spa_outlined,
              label: 'Service',
              title: appointment.serviceName,
              subtitle: appointment.serviceDescription,
            ),
            _SummaryItem(
              icon: Icons.person_outline,
              label: 'Therapist',
              title: appointment.therapistName,
            ),
            _SummaryItem(
              icon: Icons.meeting_room_outlined,
              label: 'Room / Zone',
              title: appointment.roomName,
            ),
            _SummaryItem(
              icon: Icons.calendar_today_outlined,
              label: 'Date',
              title: DateFormat('EEEE, d MMMM yyyy').format(appointment.date),
            ),
            _SummaryItem(
              icon: Icons.schedule_outlined,
              label: 'Time',
              title:
                  '${appointment.timeRange} (${appointment.durationMinutes} min)',
            ),
            _SummaryItem(
              icon: Icons.payments_outlined,
              label: 'Price',
              title: 'RM ${appointment.price.toStringAsFixed(0)}',
            ),
            if (appointment.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              const Text(
                'Notes',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  appointment.notes,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF374151),
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 18),
            _PanelActionButton(
              icon: Icons.edit_outlined,
              label: 'Edit Appointment',
              color: const Color(0xFFF59E0B),
              onPressed: onEdit,
            ),
            if (onComplete != null)
              _PanelActionButton(
                icon: Icons.point_of_sale_outlined,
                label: 'Confirm Payment',
                color: const Color(0xFF15803D),
                onPressed: onComplete!,
              ),
            if (onCancel != null)
              _PanelActionButton(
                icon: Icons.delete_outline,
                label: 'Cancel Booking',
                color: const Color(0xFFE53935),
                onPressed: onCancel!,
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final _AppointmentStatusStyle colors;

  const _StatusBadge({required this.label, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: colors.accent,
          fontSize: 13,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _TimelineStatusBadge extends StatelessWidget {
  final String label;
  final _AppointmentStatusStyle colors;
  final bool compact;
  final bool dotOnly;

  const _TimelineStatusBadge({
    required this.label,
    required this.colors,
    this.compact = false,
    this.dotOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    if (dotOnly) {
      return Tooltip(
        message: label,
        child: Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            color: colors.accent,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: colors.accent.withValues(alpha: 0.24),
                blurRadius: 7,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
      );
    }

    final dotSize = compact ? 6.0 : 7.0;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.accent.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              color: colors.accent,
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: compact ? 5 : 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 10 : 11,
              color: colors.accent,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String title;
  final String? subtitle;

  const _SummaryItem({
    required this.icon,
    required this.label,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF4B5563)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF111827),
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  const _PanelActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 18),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: color,
            side: BorderSide(color: color.withValues(alpha: 0.72)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
      ),
    );
  }
}

class _AppointmentCheckoutSheet extends StatefulWidget {
  final _ScheduleAppointment appointment;

  const _AppointmentCheckoutSheet({required this.appointment});

  @override
  State<_AppointmentCheckoutSheet> createState() =>
      _AppointmentCheckoutSheetState();
}

class _AppointmentCheckoutSheetState extends State<_AppointmentCheckoutSheet> {
  final _appointmentRepository = AppointmentRepository();
  final _commissionRepository = CommissionRepository();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final String _receiptNumber;
  String? _paymentMethod;
  bool _saveCustomerProfile = false;
  bool _saving = false;

  double get _servicePrice => widget.appointment.price;
  double get _sstAmount => _servicePrice * 0.06;
  double get _totalAmount => _servicePrice + _sstAmount;

  bool get _canConfirm {
    if (_paymentMethod == null || _saving) return false;
    return true;
  }

  bool get _hasMemberDetails {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    return !_isGuestPlaceholder(name) && phone.isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    _receiptNumber = _generateReceiptNumber();
    _saveCustomerProfile = widget.appointment.isGuestAccount;
    _name = TextEditingController(
      text: _isGuestPlaceholder(widget.appointment.customerName)
          ? 'Guest'
          : widget.appointment.customerName,
    )..addListener(_refresh);
    _phone = TextEditingController(
      text: widget.appointment.customerPhone.trim() == '-'
          ? ''
          : widget.appointment.customerPhone,
    )..addListener(_refresh);
  }

  @override
  void dispose() {
    _name.removeListener(_refresh);
    _phone.removeListener(_refresh);
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  bool _isGuestPlaceholder(String value) {
    final normalized = value.trim().toLowerCase();
    return widget.appointment.isGuestAccount &&
        (normalized.isEmpty ||
            normalized == 'guest' ||
            normalized == 'guest account' ||
            normalized == 'walk-in guest');
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String _resolvedCustomerName() {
    final value = _name.text.trim();
    if (value.isNotEmpty) return value;
    return widget.appointment.isGuestAccount
        ? 'Guest'
        : widget.appointment.customerName;
  }

  Future<void> _confirmCheckout() async {
    if (!_canConfirm) return;
    setState(() => _saving = true);

    try {
      var customerId = widget.appointment.customerId;
      final customerName = _resolvedCustomerName();
      final counterStaff = await _commissionRepository
          .getAvailableCounterStaff();
      final therapistCommissionAmount =
          CommissionRepository.commissionForServices(
            widget.appointment.serviceItems,
            staff: widget.appointment.therapistCommissionData,
            role: 'Therapist',
          );
      final counterCommissionAmount = counterStaff == null
          ? 0.0
          : CommissionRepository.commissionForServices(
              widget.appointment.serviceItems,
              staff: counterStaff,
              role: 'Counter',
            );
      final shouldSaveCustomerProfile =
          widget.appointment.isGuestAccount &&
          _saveCustomerProfile &&
          _hasMemberDetails;

      await _appointmentRepository.checkoutAppointment(
        appointmentId: widget.appointment.id,
        newCustomerValues: shouldSaveCustomerProfile
            ? {
                'name': customerName,
                'phone': _phone.text.trim(),
                'gender': '',
                'joinDate': DateFormat('yyyy-MM-dd').format(DateTime.now()),
                'notes': 'Created from appointment checkout',
              }
            : null,
        appointmentUpdates: {'customerId': customerId},
        transactionValues: {
          'customerId': customerId,
          'customerName': customerName,
          'customerPhone': _phone.text.trim().isNotEmpty
              ? _phone.text.trim()
              : widget.appointment.customerPhone,
          'serviceId': widget.appointment.serviceId,
          'serviceName': widget.appointment.serviceName,
          'serviceItems': widget.appointment.serviceItems,
          'itemCount': widget.appointment.serviceItems.length,
          'therapistId': widget.appointment.therapistId,
          'therapistName': widget.appointment.therapistName,
          if (counterStaff != null) ...{
            'counterStaffId': counterStaff['id'],
            'counterStaffName': counterStaff['name'],
          },
          'roomName': widget.appointment.roomName,
          'servicePrice': _servicePrice,
          'sstAmount': _sstAmount,
          'totalAmount': _totalAmount,
          'therapistCommissionAmount': therapistCommissionAmount,
          'counterCommissionAmount': counterCommissionAmount,
          'source': 'appointment',
          'paymentMethod': _paymentMethod,
          'paymentStatus': 'paid',
          'receiptNumber': _receiptNumber,
        },
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Payment recorded and booking completed'),
          backgroundColor: Color(0xFF1B6B72),
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to confirm booking: $e'),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 620,
            maxHeight: MediaQuery.of(context).size.height * 0.92,
          ),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: EdgeInsets.fromLTRB(20, 18, 20, bottomInset + 20),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Confirm Payment',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF111827),
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '#$_receiptNumber',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF6B7280),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context, false),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Customer Details',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _EditField(label: 'Name', controller: _name),
                  const SizedBox(height: 12),
                  _EditField(
                    label: 'Phone',
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                  ),
                  if (widget.appointment.isGuestAccount) ...[
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: _saveCustomerProfile,
                      onChanged: _saving
                          ? null
                          : (value) => setState(
                              () => _saveCustomerProfile = value ?? false,
                            ),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: const Color(0xFF1B6B72),
                      title: const Text(
                        'Save as customer profile',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                      subtitle: const Text(
                        'A member is created only when name and phone are filled.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _CheckoutRecapCard(appointment: widget.appointment),
                  const SizedBox(height: 16),
                  _CheckoutPriceCard(
                    servicePrice: _servicePrice,
                    sstAmount: _sstAmount,
                    totalAmount: _totalAmount,
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Payment Method',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 460;
                      final width = compact
                          ? constraints.maxWidth
                          : (constraints.maxWidth - 24) / 3;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.payments_outlined,
                              label: 'Cash',
                              isSelected: _paymentMethod == 'cash',
                              onTap: () =>
                                  setState(() => _paymentMethod = 'cash'),
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.qr_code_2_outlined,
                              label: 'QR Code',
                              isSelected: _paymentMethod == 'qr_code',
                              onTap: () =>
                                  setState(() => _paymentMethod = 'qr_code'),
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.credit_card_outlined,
                              label: 'Card',
                              isSelected: _paymentMethod == 'card',
                              onTap: () =>
                                  setState(() => _paymentMethod = 'card'),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: _canConfirm ? _confirmCheckout : null,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check, size: 18),
                      label: const Text('Confirm Payment & Complete'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1B6B72),
                        disabledBackgroundColor: const Color(0xFFBDBDBD),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        textStyle: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppointmentGroupCheckoutSheet extends StatefulWidget {
  final _AppointmentGroup group;

  const _AppointmentGroupCheckoutSheet({required this.group});

  @override
  State<_AppointmentGroupCheckoutSheet> createState() =>
      _AppointmentGroupCheckoutSheetState();
}

class _AppointmentGroupCheckoutSheetState
    extends State<_AppointmentGroupCheckoutSheet> {
  final _appointmentRepository = AppointmentRepository();
  final _commissionRepository = CommissionRepository();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final String _receiptNumber;
  String? _paymentMethod;
  bool _saveCustomerProfile = false;
  bool _saving = false;

  double get _servicePrice => widget.group.price;
  double get _sstAmount => _servicePrice * 0.06;
  double get _totalAmount => _servicePrice + _sstAmount;

  bool get _canConfirm => _paymentMethod != null && !_saving;

  bool get _hasMemberDetails {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    return !_isGuestPlaceholder(name) && phone.isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    _receiptNumber = _generateReceiptNumber();
    _saveCustomerProfile = widget.group.isGuestAccount;
    _name = TextEditingController(
      text: _isGuestPlaceholder(widget.group.customerName)
          ? 'Guest'
          : widget.group.customerName,
    )..addListener(_refresh);
    _phone = TextEditingController(
      text: widget.group.customerPhone.trim() == '-'
          ? ''
          : widget.group.customerPhone,
    )..addListener(_refresh);
  }

  @override
  void dispose() {
    _name.removeListener(_refresh);
    _phone.removeListener(_refresh);
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  bool _isGuestPlaceholder(String value) {
    final normalized = value.trim().toLowerCase();
    return widget.group.isGuestAccount &&
        (normalized.isEmpty ||
            normalized == 'guest' ||
            normalized == 'guest account' ||
            normalized == 'walk-in guest');
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String _resolvedCustomerName() {
    final value = _name.text.trim();
    if (value.isNotEmpty) return value;
    return widget.group.isGuestAccount ? 'Guest' : widget.group.customerName;
  }

  double _therapistCommissionTotal() {
    var total = 0.0;
    for (final appointment in widget.group.appointments) {
      total += CommissionRepository.commissionForServices(
        appointment.serviceItems,
        staff: appointment.therapistCommissionData,
        role: 'Therapist',
      );
    }
    return total;
  }

  Future<void> _confirmCheckout() async {
    if (!_canConfirm) return;
    setState(() => _saving = true);

    try {
      var customerId = widget.group.primary.customerId;
      final customerName = _resolvedCustomerName();
      final counterStaff = await _commissionRepository
          .getAvailableCounterStaff();
      final therapistCommissionAmount = _therapistCommissionTotal();
      final counterCommissionAmount = counterStaff == null
          ? 0.0
          : CommissionRepository.commissionForServices(
              widget.group.serviceItems,
              staff: counterStaff,
              role: 'Counter',
            );
      final shouldSaveCustomerProfile =
          widget.group.isGuestAccount &&
          _saveCustomerProfile &&
          _hasMemberDetails;

      await _appointmentRepository.checkoutAppointmentGroup(
        appointmentGroupId: widget.group.appointmentGroupId,
        appointmentIds: widget.group.appointments.map((a) => a.id).toList(),
        newCustomerValues: shouldSaveCustomerProfile
            ? {
                'name': customerName,
                'phone': _phone.text.trim(),
                'gender': '',
                'joinDate': DateFormat('yyyy-MM-dd').format(DateTime.now()),
                'notes': 'Created from group appointment checkout',
              }
            : null,
        appointmentUpdates: {'customerId': customerId},
        transactionValues: {
          'customerId': customerId,
          'customerName': customerName,
          'customerPhone': _phone.text.trim().isNotEmpty
              ? _phone.text.trim()
              : widget.group.customerPhone,
          'serviceId': widget.group.primary.serviceId,
          'serviceName': widget.group.serviceName,
          'serviceItems': widget.group.serviceItems,
          'itemCount': widget.group.serviceItems.length,
          'therapistId': widget.group.primary.therapistId,
          'therapistName': widget.group.therapistName,
          if (counterStaff != null) ...{
            'counterStaffId': counterStaff['id'],
            'counterStaffName': counterStaff['name'],
          },
          'roomName': widget.group.roomName,
          'servicePrice': _servicePrice,
          'sstAmount': _sstAmount,
          'totalAmount': _totalAmount,
          'therapistCommissionAmount': therapistCommissionAmount,
          'counterCommissionAmount': counterCommissionAmount,
          'source': 'appointment',
          'paymentMethod': _paymentMethod,
          'paymentStatus': 'paid',
          'receiptNumber': _receiptNumber,
        },
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Group payment recorded and booking completed'),
          backgroundColor: Color(0xFF1B6B72),
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to confirm group booking: $e'),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 620,
            maxHeight: MediaQuery.of(context).size.height * 0.92,
          ),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: EdgeInsets.fromLTRB(20, 18, 20, bottomInset + 20),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Confirm Group Payment',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF111827),
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '#$_receiptNumber',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF6B7280),
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context, false),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Customer Details',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _EditField(label: 'Name', controller: _name),
                  const SizedBox(height: 12),
                  _EditField(
                    label: 'Phone',
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                  ),
                  if (widget.group.isGuestAccount) ...[
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: _saveCustomerProfile,
                      onChanged: _saving
                          ? null
                          : (value) => setState(
                              () => _saveCustomerProfile = value ?? false,
                            ),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      activeColor: const Color(0xFF1B6B72),
                      title: const Text(
                        'Save as customer profile',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                      subtitle: const Text(
                        'A member is created only when name and phone are filled.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _GroupCheckoutRecapCard(group: widget.group),
                  const SizedBox(height: 16),
                  _CheckoutPriceCard(
                    servicePrice: _servicePrice,
                    sstAmount: _sstAmount,
                    totalAmount: _totalAmount,
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Payment Method',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 460;
                      final width = compact
                          ? constraints.maxWidth
                          : (constraints.maxWidth - 24) / 3;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.payments_outlined,
                              label: 'Cash',
                              isSelected: _paymentMethod == 'cash',
                              onTap: () =>
                                  setState(() => _paymentMethod = 'cash'),
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.qr_code_2_outlined,
                              label: 'QR Code',
                              isSelected: _paymentMethod == 'qr_code',
                              onTap: () =>
                                  setState(() => _paymentMethod = 'qr_code'),
                            ),
                          ),
                          SizedBox(
                            width: width,
                            child: _CheckoutPaymentMethodCard(
                              icon: Icons.credit_card_outlined,
                              label: 'Card',
                              isSelected: _paymentMethod == 'card',
                              onTap: () =>
                                  setState(() => _paymentMethod = 'card'),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: _canConfirm ? _confirmCheckout : null,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check, size: 18),
                      label: const Text('Confirm Payment & Complete'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1B6B72),
                        disabledBackgroundColor: const Color(0xFFBDBDBD),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        textStyle: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckoutRecapCard extends StatelessWidget {
  final _ScheduleAppointment appointment;

  const _CheckoutRecapCard({required this.appointment});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  appointment.serviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5F5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${appointment.durationMinutes} min',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1B6B72),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${appointment.therapistName} - ${appointment.roomName}',
            style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 3),
          Text(
            '${DateFormat('EEE, d MMM yyyy').format(appointment.date)} - ${appointment.timeRange}',
            style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
        ],
      ),
    );
  }
}

class _GroupCheckoutRecapCard extends StatelessWidget {
  final _AppointmentGroup group;

  const _GroupCheckoutRecapCard({required this.group});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${group.paxCount} pax services',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5F5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  group.timeRange,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1B6B72),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (var index = 0; index < group.appointments.length; index++)
            Padding(
              padding: EdgeInsets.only(
                bottom: index == group.appointments.length - 1 ? 0 : 8,
              ),
              child: _GroupCheckoutPaxRow(
                index: index,
                appointment: group.appointments[index],
              ),
            ),
        ],
      ),
    );
  }
}

class _GroupCheckoutPaxRow extends StatelessWidget {
  final int index;
  final _ScheduleAppointment appointment;

  const _GroupCheckoutPaxRow({required this.index, required this.appointment});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pax ${index + 1}',
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF2563EB),
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${appointment.customerName} - ${appointment.serviceName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF111827),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${appointment.therapistName} - ${appointment.roomName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          appointment.priceLabel,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF111827),
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _CheckoutPriceCard extends StatelessWidget {
  final double servicePrice;
  final double sstAmount;
  final double totalAmount;

  const _CheckoutPriceCard({
    required this.servicePrice,
    required this.sstAmount,
    required this.totalAmount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEEEEEE)),
      ),
      child: Column(
        children: [
          _CheckoutPriceRow('Service', 'RM ${servicePrice.toStringAsFixed(2)}'),
          const SizedBox(height: 8),
          _CheckoutPriceRow('SST (6%)', 'RM ${sstAmount.toStringAsFixed(2)}'),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(color: Color(0xFFEEEEEE), height: 1),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              Text(
                'RM ${totalAmount.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
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

class _CheckoutPriceRow extends StatelessWidget {
  final String label;
  final String value;

  const _CheckoutPriceRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: Color(0xFF6B6B6B)),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 13, color: Color(0xFF1A1A2E)),
        ),
      ],
    );
  }
}

class _CheckoutPaymentMethodCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _CheckoutPaymentMethodCard({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1B6B72) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF1B6B72)
                : const Color(0xFFEEEEEE),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 24,
              color: isSelected ? Colors.white : const Color(0xFF6B6B6B),
            ),
            const SizedBox(height: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: isSelected ? Colors.white : const Color(0xFF1A1A2E),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppointmentEditSheet extends StatefulWidget {
  final _ScheduleAppointment appointment;

  const _AppointmentEditSheet({required this.appointment});

  @override
  State<_AppointmentEditSheet> createState() => _AppointmentEditSheetState();
}

class _AppointmentEditSheetState extends State<_AppointmentEditSheet> {
  final _appointmentRepository = AppointmentRepository();
  late final TextEditingController _start;
  late final TextEditingController _end;
  late final TextEditingController _notes;
  late final TextEditingController _price;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _start = TextEditingController(text: widget.appointment.startTime);
    _end = TextEditingController(text: widget.appointment.endTime);
    _notes = TextEditingController(text: widget.appointment.notes);
    _price = TextEditingController(
      text: widget.appointment.price.toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _notes.dispose();
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final startTime = _normalizeEditTime(_start.text);
    final endTime = _normalizeEditTime(_end.text);
    final price =
        double.tryParse(_price.text.trim()) ?? widget.appointment.price;

    if (startTime == null || endTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Use a valid time, for example 09:30'),
          backgroundColor: Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      if (widget.appointment.therapistId.isEmpty ||
          widget.appointment.roomId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Appointment needs staff and room before saving.'),
            backgroundColor: Color(0xFFE53935),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final result = await CspService.updateAppointment(
        appointmentId: widget.appointment.id,
        therapistId: widget.appointment.therapistId,
        roomId: widget.appointment.roomId,
        date: widget.appointment.dateKey,
        startTime: startTime,
        endTime: endTime,
      );

      if (!mounted) return;
      if (!result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: const Color(0xFFE53935),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      await _appointmentRepository.updateAppointment(widget.appointment.id, {
        'notes': _notes.text.trim(),
        'totalPrice': price,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to save appointment: $e'),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _normalizeEditTime(String value) {
    final raw = value.trim();
    final match = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?$').firstMatch(raw);
    if (match == null) return null;

    final hour = int.tryParse(match.group(1) ?? '');
    final minute = int.tryParse(match.group(2) ?? '');
    final second = int.tryParse(match.group(3) ?? '0');
    if (hour == null ||
        minute == null ||
        second == null ||
        hour > 23 ||
        minute > 59 ||
        second > 59) {
      return null;
    }

    return '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        18,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Edit Appointment',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: _EditField(label: 'Start', controller: _start),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _EditField(label: 'End', controller: _end),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _EditField(
              label: 'Price',
              controller: _price,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            _EditField(label: 'Notes', controller: _notes, maxLines: 3),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2F7D59),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(_saving ? 'Saving...' : 'Save Changes'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final int maxLines;
  final TextInputType? keyboardType;

  const _EditField({
    required this.label,
    required this.controller,
    this.maxLines = 1,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: const Color(0xFFF6FAF5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
      ),
    );
  }
}

class _ScheduleLoading extends StatelessWidget {
  const _ScheduleLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(color: Color(0xFF2F7D59)),
    );
  }
}

class _ScheduleError extends StatelessWidget {
  final VoidCallback onRetry;

  const _ScheduleError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFE53935), size: 30),
          const SizedBox(height: 10),
          const Text(
            'Unable to load appointments.',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _ScheduleEmptyState extends StatelessWidget {
  const _ScheduleEmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: const Column(
        children: [
          Icon(
            Icons.event_available_outlined,
            color: Color(0xFF2F7D59),
            size: 34,
          ),
          SizedBox(height: 10),
          Text(
            'No appointments for this day',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: Color(0xFF111827),
            ),
          ),
          SizedBox(height: 4),
          Text(
            'New bookings will appear here automatically.',
            style: TextStyle(color: Color(0xFF6B7280)),
          ),
        ],
      ),
    );
  }
}
