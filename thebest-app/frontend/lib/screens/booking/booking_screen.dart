import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/outlets/outlet_context.dart';
import '../../core/services/csp_service.dart';
import '../../core/utils/error_message.dart';
import '../../data/repositories/appointment_repository.dart';
import '../../data/repositories/customer_repository.dart';
import '../../data/repositories/room_repository.dart';
import '../../data/repositories/service_repository.dart';
import '../../data/repositories/therapist_repository.dart';
import '../../data/services/supabase_table_service.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/therapist_queue_picker.dart';

DateTime _stripDate(DateTime date) => DateTime(date.year, date.month, date.day);

int _bookingTimeToMinutes(String time) {
  final parts = time.split(':');
  if (parts.length < 2) return 0;
  return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
}

String _bookingMinutesToTime(int minutes) {
  final normalized = minutes % (24 * 60);
  final hour = (normalized ~/ 60).toString().padLeft(2, '0');
  final minute = (normalized % 60).toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _bookingCleanTime(String value) {
  final raw = value.trim();
  if (raw.length >= 5) return raw.substring(0, 5);
  return raw;
}

String _bookingTimeLabel(String value) {
  final minutes = _bookingTimeToMinutes(value);
  return DateFormat(
    'h:mm a',
  ).format(DateTime(2026, 1, 1, (minutes ~/ 60) % 24, minutes % 60));
}

String _normalizeRoomType(Object? value) {
  final raw = value?.toString().trim().toLowerCase() ?? '';
  if (raw.isEmpty || raw == '-') return '';
  final normalized = raw.replaceAll(RegExp(r'[\s-]+'), '_');
  if (normalized.contains('body')) return 'body_room';
  if (normalized.contains('foot')) return 'foot_chair';
  return normalized;
}

// ── Models ────────────────────────────────────────────────────────

class _Service {
  final String id, name, imageUrl, roomType, category;
  final int duration;
  final int bufferAfterMinutes;
  final double price;
  final double therapistCommission;
  final double counterCommission;

  const _Service({
    required this.id,
    required this.name,
    required this.imageUrl,
    required this.roomType,
    required this.category,
    required this.duration,
    required this.bufferAfterMinutes,
    required this.price,
    required this.therapistCommission,
    required this.counterCommission,
  });

  factory _Service.fromMap(Map<String, dynamic> d) {
    return _Service(
      id: d['id']?.toString() ?? '',
      name: d['name']?.toString() ?? '',
      imageUrl: (d['imageUrl'] ?? d['image'])?.toString().trim() ?? '',
      roomType: _normalizeRoomType(d['roomType']),
      category: d['category']?.toString().trim() ?? 'Services',
      duration: _parseInt(d['duration'], fallback: 60),
      bufferAfterMinutes: _parseInt(d['bufferAfterMinutes'], fallback: 0),
      price: _parseDouble(d['price']),
      therapistCommission: _parseDouble(d['therapistCommission']),
      counterCommission: _parseDouble(d['counterCommission']),
    );
  }

  static int _parseInt(Object? value, {required int fallback}) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  static double _parseDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }
}

bool _isActiveDoc(Map<String, dynamic> data) {
  final value = data['isActive'] ?? data['active'];
  if (value is bool) return value;
  if (value is String) return value.toLowerCase().trim() == 'true';
  return true;
}

class _Therapist {
  final String id, name, gender, imageUrl;
  final bool isFree;
  final String busyUntil;

  /// Availability summary for the booking's selected date (not "right now"):
  /// e.g. 'Available', 'On leave', 'Off today',
  /// 'Busy until 3:30 PM'. [statusTone] drives the badge color:
  /// 'free' (green), 'busy' (amber), 'off' (gray).
  final String statusLabel;
  final String statusTone;

  /// Why this therapist was picked (queue / gender_preference /
  /// specific_customer_request / manual_override) and its independent
  /// therapist assignment lifecycle state.
  final String assignmentSource;
  final String? requestedGender;
  final String therapistAssignmentState;

  const _Therapist({
    required this.id,
    required this.name,
    required this.gender,
    required this.imageUrl,
    required this.isFree,
    required this.busyUntil,
    this.statusLabel = '',
    this.statusTone = 'free',
    this.assignmentSource = 'queue',
    this.requestedGender,
    this.therapistAssignmentState = 'confirmed',
  });

  _Therapist withAssignment({
    required String source,
    String? requestedGender,
    String therapistAssignmentState = 'confirmed',
  }) {
    return _Therapist(
      id: id,
      name: name,
      gender: gender,
      imageUrl: imageUrl,
      isFree: isFree,
      busyUntil: busyUntil,
      statusLabel: statusLabel,
      statusTone: statusTone,
      assignmentSource: source,
      requestedGender: requestedGender,
      therapistAssignmentState: therapistAssignmentState,
    );
  }

  bool get isFemale => gender.startsWith('f');
  bool get isMale => gender.startsWith('m');

  Color get photoBg => isFemale
      ? const Color(0xFFFCE7F3)
      : isMale
      ? const Color(0xFFE0F2FE)
      : const Color(0xFFE8F5F5);

  Color get photoColor => isFemale
      ? const Color(0xFFDB2777)
      : isMale
      ? const Color(0xFF0284C7)
      : const Color(0xFF1B6B72);

  IconData get photoIcon => isFemale
      ? Icons.female
      : isMale
      ? Icons.male
      : Icons.person_outline;
}

class _RoomZone {
  final String id, name, type, floor, imageUrl, allocationMode;
  final int totalSlots, freeSlots;

  const _RoomZone({
    required this.id,
    required this.name,
    required this.type,
    required this.floor,
    required this.imageUrl,
    required this.allocationMode,
    required this.totalSlots,
    required this.freeSlots,
  });

  bool get usesSpecificRooms => allocationMode == 'specific_room';
}

class _TimeSlot {
  final String start, end;
  final bool isRecommended, isAvailable;
  final int score;
  final String reason;
  final String unavailableDetail;
  final int roomAvailableSlots;
  final String? previousBlockEnd, nextBlockStart;
  final int? gapBeforeMinutes, gapAfterMinutes;

  const _TimeSlot({
    required this.start,
    required this.end,
    required this.isRecommended,
    required this.isAvailable,
    this.score = 0,
    this.reason = '',
    this.unavailableDetail = '',
    this.roomAvailableSlots = 0,
    this.previousBlockEnd,
    this.nextBlockStart,
    this.gapBeforeMinutes,
    this.gapAfterMinutes,
  });

  String get label => '${_bookingTimeLabel(start)} - ${_bookingTimeLabel(end)}';

  String get reasonLabel {
    if (unavailableDetail.isNotEmpty) return unavailableDetail;
    switch (reason) {
      case 'fills_between_bookings':
        return nextBlockStart == null
            ? 'Fills the available schedule gap'
            : 'Uses the full open window before ${_bookingTimeLabel(nextBlockStart!)}';
      case 'starts_after_booking':
        return previousBlockEnd == null
            ? 'Starts immediately after a booking'
            : 'Starts when the schedule clears at ${_bookingTimeLabel(previousBlockEnd!)}';
      case 'starts_after_booking_short_gap':
        return 'Starts at ${_bookingTimeLabel(previousBlockEnd ?? start)} · leaves ${gapAfterMinutes ?? 0} min before next';
      case 'ends_before_booking':
        return nextBlockStart == null
            ? 'Fits directly before the next booking'
            : 'Fits directly before the ${_bookingTimeLabel(nextBlockStart!)} booking';
      case 'ends_before_booking_short_gap':
        return 'Fits before ${_bookingTimeLabel(nextBlockStart ?? end)} · leaves ${gapBeforeMinutes ?? 0} min after previous';
      case 'balances_workload':
        return 'Balances staff workload';
      case 'leaves_short_gap':
        final gaps = [
          gapBeforeMinutes,
          gapAfterMinutes,
        ].whereType<int>().where((gap) => gap > 0).toList()..sort();
        return gaps.isEmpty
            ? 'Leaves a short idle gap'
            : 'Leaves a ${gaps.first}-minute idle gap';
      case 'starts_after_unavailability':
        return 'Starts when the therapist becomes available';
      case 'starts_at_shift':
        return 'Starts at the beginning of the therapist shift';
      case 'custom_time':
        return 'Exact time checked and available';
      case 'capacity_first_available':
        return 'Earliest shared start with full capacity';
      case 'therapist_on_leave':
        return 'Therapist on leave';
      case 'outside_working_hours':
        return 'Outside working hours';
      case 'assigned_to_other_pax':
        return 'Therapist already booked for another pax';
      default:
        return 'Good schedule fit';
    }
  }
}

class _Customer {
  final String id, name, phone;
  const _Customer({required this.id, required this.name, required this.phone});

  factory _Customer.fromMap(Map<String, dynamic> d) {
    return _Customer(
      id: d['id']?.toString() ?? '',
      name: d['name'] ?? '',
      phone: d['phone'] ?? '',
    );
  }

  static _Customer get guest =>
      const _Customer(id: 'walk_in_guest', name: 'Guest', phone: '');

  bool get isGuest => id == 'walk_in_guest';
}

class _BookingAllocation {
  final String appointmentId;
  final List<_Service> services;
  final _Therapist therapist;
  final _RoomZone room;
  final _TimeSlot slot;

  const _BookingAllocation({
    this.appointmentId = '',
    required this.services,
    required this.therapist,
    required this.room,
    required this.slot,
  });

  _Service get primaryService => services.first;

  int get duration =>
      services.fold(0, (total, service) => total + service.duration);

  double get price =>
      services.fold(0, (total, service) => total + service.price);

  String get serviceNameSummary {
    if (services.length == 1) return services.first.name;
    return services.map((service) => service.name).join(', ');
  }

  String get endTime =>
      _bookingMinutesToTime(_bookingTimeToMinutes(slot.start) + duration);

  List<Map<String, dynamic>> get serviceItems => services
      .map(
        (service) => {
          'id': service.id,
          'name': service.name,
          'category': service.category,
          'duration': service.duration,
          'price': service.price,
          'therapistCommission': service.therapistCommission,
          'counterCommission': service.counterCommission,
          'assignedTherapistId': therapist.id,
          'assignedTherapistName': therapist.name,
          'assignedRoomId': room.id,
          'assignedRoomName': room.name,
          'startTime': slot.start,
          'endTime': endTime,
        },
      )
      .toList();

  Map<String, dynamic> toCspAllocation({required int paxIndex}) {
    return {
      'pax_index': paxIndex,
      if (appointmentId.isNotEmpty) 'appointment_id': appointmentId,
      'therapist_id': therapist.id,
      'room_id': room.id,
      'service_id': primaryService.id,
      'start_time': slot.start,
      'end_time': endTime,
      'total_price': price,
      'service_name': serviceNameSummary,
      'service_items': serviceItems,
      'item_count': services.length,
      'assignment_source': therapist.assignmentSource,
      'requested_therapist_id':
          therapist.assignmentSource == 'specific_customer_request'
          ? therapist.id
          : null,
      'requested_gender': therapist.requestedGender,
      'therapist_assignment_state': therapist.therapistAssignmentState,
      'room_assignment_state': 'pending',
    };
  }
}

class _CapacityTherapistPreference {
  const _CapacityTherapistPreference({
    this.assignmentSource = 'queue',
    this.requestedGender,
  });

  final String assignmentSource;
  final String? requestedGender;

  bool get isComplete =>
      assignmentSource != 'gender_preference' || requestedGender != null;

  String get label => switch (assignmentSource) {
    'gender_preference' => requestedGender ?? 'Gender preference',
    _ => 'Auto assigned',
  };
}

class _CapacityPaxSelection {
  const _CapacityPaxSelection({
    required this.services,
    required this.preference,
  });

  final List<_Service> services;
  final _CapacityTherapistPreference preference;

  int get duration =>
      services.fold(0, (total, service) => total + service.duration);

  int get bufferAfterMinutes => services.fold<int>(
    0,
    (buffer, service) => service.bufferAfterMinutes > buffer
        ? service.bufferAfterMinutes
        : buffer,
  );

  double get price =>
      services.fold(0, (total, service) => total + service.price);

  String get serviceNameSummary => services.isEmpty
      ? ''
      : services.map((service) => service.name).join(', ');

  Set<String> get roomTypes => services
      .map((service) => service.roomType)
      .where((type) => type.isNotEmpty)
      .toSet();

  bool get hasMissingRoomType =>
      services.any((service) => service.roomType.isEmpty);

  String? get requiredRoomType =>
      roomTypes.length == 1 ? roomTypes.first : null;

  bool get hasMixedRoomTypes => roomTypes.length > 1;

  bool get isComplete =>
      services.isNotEmpty &&
      !hasMissingRoomType &&
      requiredRoomType != null &&
      preference.isComplete;

  CounterCapacityRequirement toRequirement(int paxIndex) {
    return CounterCapacityRequirement(
      paxIndex: paxIndex,
      serviceIds: services.map((service) => service.id).toList(),
      durationMinutes: duration,
      bufferAfterMinutes: bufferAfterMinutes,
      roomType: requiredRoomType!,
      assignmentSource: preference.assignmentSource,
      requestedGender: preference.requestedGender,
      requestedTherapistId: null,
    );
  }
}

class AppointmentEditAllocation {
  final String appointmentId;
  final List<String> serviceIds;
  final List<String> bookedServiceIds;
  final List<String> lockedServiceIds;
  final String therapistId;
  final String assignmentSource;
  final String? requestedGender;
  final String therapistAssignmentState;
  final String roomId;
  final String startTime;
  final String endTime;

  const AppointmentEditAllocation({
    required this.appointmentId,
    required this.serviceIds,
    this.bookedServiceIds = const [],
    this.lockedServiceIds = const [],
    required this.therapistId,
    this.assignmentSource = 'queue',
    this.requestedGender,
    this.therapistAssignmentState = 'confirmed',
    required this.roomId,
    required this.startTime,
    required this.endTime,
  });
}

class AppointmentEditPayload {
  final String? appointmentId;
  final String? appointmentGroupId;
  final DateTime date;
  final String customerId;
  final String customerName;
  final String customerPhone;
  final String notes;
  final List<AppointmentEditAllocation> allocations;
  final int activePaxIndex;
  final bool checkInMode;
  final bool hasPayment;

  const AppointmentEditPayload({
    this.appointmentId,
    this.appointmentGroupId,
    required this.date,
    required this.customerId,
    required this.customerName,
    required this.customerPhone,
    this.notes = '',
    required this.allocations,
    this.activePaxIndex = 0,
    this.checkInMode = false,
    this.hasPayment = false,
  });

  bool get isGroup => appointmentGroupId?.trim().isNotEmpty == true;
}

// ── Main Screen ───────────────────────────────────────────────────

class NewAppointmentScreen extends StatefulWidget {
  final String userRole;
  final AppointmentEditPayload? editPayload;
  const NewAppointmentScreen({
    super.key,
    required this.userRole,
    this.editPayload,
  });

  @override
  State<NewAppointmentScreen> createState() => _NewAppointmentScreenState();
}

class _NewAppointmentScreenState extends State<NewAppointmentScreen> {
  final _customerRepository = CustomerRepository();
  final _appointmentRepository = AppointmentRepository();
  final _roomRepository = RoomRepository();
  final _serviceRepository = ServiceRepository();
  final _therapistRepository = TherapistRepository();
  final _serviceCategoryTable = SupabaseTableService('service_categories');
  final _workingHoursTable = SupabaseTableService('therapist_working_hours');
  final _unavailabilityTable = SupabaseTableService('therapist_unavailability');

  // State
  DateTime _selectedDate = DateTime.now();
  _Customer? _selectedCustomer;
  final List<_Service> _selectedServices = [];
  _Therapist? _selectedTherapist;
  _RoomZone? _selectedRoom;
  _TimeSlot? _selectedSlot;
  _TimeSlot? _previousSlotReference;
  int _paxCount = 1;
  int _activePaxIndex = 0;
  final List<_BookingAllocation?> _paxAllocations = [null];
  final List<List<_Service>> _capacityPaxServices = [<_Service>[]];
  final List<_CapacityTherapistPreference> _capacityPaxPreferences = [
    const _CapacityTherapistPreference(),
  ];
  String _serviceTab = 'Services';
  bool _summaryExpanded = false;
  bool _isConfirming = false;
  bool _loadingSlots = false;
  String? _capacitySlotLoadError;
  bool _showAllStandardSlots = false;
  int _slotRequestSerial = 0;
  bool _didApplyEditPayload = false;

  // Data
  List<_Service> _services = [];
  List<String> _serviceCategories = const ['Services', 'Add-ons', 'Packages'];
  List<_Therapist> _therapists = [];
  List<_RoomZone> _rooms = [];
  List<RoomUnitAvailability> _roomUnitAvailability = const [];
  bool _loadingRoomUnits = false;
  List<_TimeSlot> _slots = [];
  List<CspScheduleBlock> _scheduleBlocks = [];
  List<_Customer> _customers = [];
  List<_Customer> _filteredCustomers = [];
  bool _loadingData = true;
  String? _serviceLoadError;

  final _customerSearchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadData();
    _customerSearchController.addListener(_filterCustomers);
  }

  @override
  void dispose() {
    _customerSearchController.dispose();
    super.dispose();
  }

  // ── Data Loading ───────────────────────────────────────────────

  Future<void> _loadData() async {
    setState(() => _loadingData = true);
    try {
      await Future.wait([
        _loadServices(),
        _loadTherapists(),
        _loadRooms(),
        _loadCustomers(),
      ]);
      _applyEditPayloadIfNeeded();
    } finally {
      setState(() => _loadingData = false);
    }
  }

  bool get _isEditing => widget.editPayload != null;
  bool get _isCapacityMode => widget.editPayload == null;
  bool get _isCheckInMode => widget.editPayload?.checkInMode == true;
  bool get _locksPaxCount => widget.editPayload?.hasPayment == true;

  Set<String> get _lockedServiceIds {
    final payload = widget.editPayload;
    if (payload == null || (!payload.hasPayment && !_isCheckInMode)) {
      return const {};
    }
    if (_activePaxIndex < 0 || _activePaxIndex >= payload.allocations.length) {
      return const {};
    }
    final allocation = payload.allocations[_activePaxIndex];
    return (allocation.lockedServiceIds.isEmpty
            ? allocation.serviceIds
            : allocation.lockedServiceIds)
        .toSet();
  }

  void _applyEditPayloadIfNeeded() {
    if (_didApplyEditPayload || widget.editPayload == null || !mounted) return;
    final payload = widget.editPayload!;
    final allocations = <_BookingAllocation?>[];

    for (final editAllocation in payload.allocations) {
      final services = editAllocation.serviceIds
          .map((id) => _services.where((service) => service.id == id))
          .where((matches) => matches.isNotEmpty)
          .map((matches) => matches.first)
          .toList();
      final therapistMatches = _therapists.where(
        (therapist) => therapist.id == editAllocation.therapistId,
      );
      final roomMatches = _rooms.where(
        (room) => room.id == editAllocation.roomId,
      );
      if (services.isEmpty || therapistMatches.isEmpty || roomMatches.isEmpty) {
        allocations.add(null);
        continue;
      }
      allocations.add(
        _BookingAllocation(
          appointmentId: editAllocation.appointmentId,
          services: services,
          therapist: therapistMatches.first.withAssignment(
            source: editAllocation.assignmentSource,
            requestedGender: editAllocation.requestedGender,
            therapistAssignmentState:
                editAllocation.therapistAssignmentState,
          ),
          room: roomMatches.first,
          slot: _TimeSlot(
            start: _bookingCleanTime(editAllocation.startTime),
            end: _bookingCleanTime(editAllocation.endTime),
            isRecommended: false,
            isAvailable: true,
          ),
        ),
      );
    }

    final matchedCustomers = _customers.where(
      (c) => c.id == payload.customerId,
    );
    final customer = matchedCustomers.isNotEmpty
        ? matchedCustomers.first
        : payload.customerId.trim().isEmpty ||
              payload.customerId == 'walk_in_guest'
        ? _Customer.guest
        : _Customer(
            id: payload.customerId,
            name: payload.customerName,
            phone: payload.customerPhone,
          );

    setState(() {
      _didApplyEditPayload = true;
      _selectedDate = _stripDate(payload.date);
      _selectedCustomer = customer;
      _customerSearchController.text = customer.isGuest ? '' : customer.name;
      _paxCount = allocations.isEmpty ? 1 : allocations.length;
      _paxAllocations
        ..clear()
        ..addAll(allocations.isEmpty ? [null] : allocations);
      _activePaxIndex = payload.activePaxIndex.clamp(0, _paxCount - 1);
      _loadAllocationIntoSelection(_paxAllocations[_activePaxIndex]);
    });
    // Re-resolve card availability for the edited booking's date.
    _loadTherapists();
    _loadRooms();
    if (_hasCurrentAllocation) _generateSlots();
  }

  Future<void> _loadServices() async {
    try {
      final rows = await _serviceRepository.getActiveServices();
      final services = <_Service>[];

      for (final d in rows) {
        final active = _isActiveDoc(d);

        if (active) {
          services.add(_Service.fromMap(d));
        }
      }

      var categoryRows = const <Map<String, dynamic>>[];
      try {
        categoryRows = await _serviceCategoryTable.list(orderBy: 'name');
      } catch (_) {
        // Existing service records still provide a safe category fallback.
      }
      const coreCategories = ['Services', 'Add-ons', 'Packages'];
      final categorySet = <String>{
        ...coreCategories,
        ...categoryRows
            .where(_isActiveDoc)
            .map((row) => row['name']?.toString().trim() ?? ''),
        ...services.map((service) => service.category.trim()),
      }..removeWhere((category) => category.isEmpty);
      final customCategories =
          categorySet
              .where((category) => !coreCategories.contains(category))
              .toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      final categories = [...coreCategories, ...customCategories];

      setState(() {
        _services = services;
        _serviceCategories = categories;
        if (!categories.contains(_serviceTab)) {
          _serviceTab = categories.first;
        }
        _serviceLoadError = null;
      });
    } catch (e) {
      setState(() {
        _services = [];
        _serviceLoadError = e.toString();
      });
    }
  }

  /// Availability shown on the therapist cards reflects the *selected booking
  /// date* (working hours, leave, and - for today - live busyness), not the
  /// current wall clock. The final validity of any slot is still decided by
  /// Supabase in [_generateSlots].
  Future<void> _loadTherapists() async {
    final rows = await _therapistRepository.getActiveTherapists();
    final date = _stripDate(_selectedDate);
    final dateKey = DateFormat('yyyy-MM-dd').format(date);
    final now = DateTime.now();
    final isToday = dateKey == DateFormat('yyyy-MM-dd').format(now);
    final nowMinutes = now.hour * 60 + now.minute;
    // Postgres day_of_week: Sunday = 0 .. Saturday = 6.
    final dayOfWeek = date.weekday % 7;
    final dayStart = date;
    final dayEnd = date.add(const Duration(days: 1));

    var hoursRows = const <Map<String, dynamic>>[];
    var leaveRows = const <Map<String, dynamic>>[];
    try {
      hoursRows = await _workingHoursTable.findBy('day_of_week', dayOfWeek);
    } catch (_) {
      hoursRows = const [];
    }
    try {
      leaveRows = await _unavailabilityTable.list(orderBy: 'starts_at');
    } catch (_) {
      leaveRows = const [];
    }

    final shiftsByTherapist = <String, List<List<int>>>{};
    for (final row in hoursRows) {
      final therapistId = row['therapistId']?.toString() ?? '';
      if (therapistId.isEmpty) continue;
      final start = _bookingTimeToMinutes(
        _bookingCleanTime(row['startTime']?.toString() ?? ''),
      );
      var end = _bookingTimeToMinutes(
        _bookingCleanTime(row['endTime']?.toString() ?? ''),
      );
      if (end <= start) end += 24 * 60;
      shiftsByTherapist.putIfAbsent(therapistId, () => []).add([start, end]);
    }

    final leaveByTherapist = <String, List<List<DateTime>>>{};
    for (final row in leaveRows) {
      final therapistId = row['therapistId']?.toString() ?? '';
      if (therapistId.isEmpty) continue;
      final startsAt = DateTime.tryParse(
        row['startsAt']?.toString() ?? '',
      )?.toLocal();
      final endsAt = DateTime.tryParse(
        row['endsAt']?.toString() ?? '',
      )?.toLocal();
      if (startsAt == null || endsAt == null) continue;
      if (!startsAt.isBefore(dayEnd) || !endsAt.isAfter(dayStart)) continue;
      leaveByTherapist.putIfAbsent(therapistId, () => []).add([
        startsAt,
        endsAt,
      ]);
    }

    final therapists = <_Therapist>[];
    for (final row in rows) {
      final therapistId = row['id']?.toString() ?? '';
      final isActive = _isActiveDoc({
        'isActive': row['availabilityStatus'] ?? true,
      });
      final shifts = [...?shiftsByTherapist[therapistId]]
        ..sort((a, b) => a[0].compareTo(b[0]));
      final leaves = leaveByTherapist[therapistId] ?? const [];

      DateTime shiftTime(int minutes) => date.add(Duration(minutes: minutes));
      bool shiftOnLeave(List<int> shift) => leaves.any(
        (leave) =>
            !leave[0].isAfter(shiftTime(shift[0])) &&
            !leave[1].isBefore(shiftTime(shift[1])),
      );
      final hasLeaveOverlap = leaves.any(
        (leave) => shifts.any(
          (shift) =>
              leave[0].isBefore(shiftTime(shift[1])) &&
              leave[1].isAfter(shiftTime(shift[0])),
        ),
      );

      var isFree = isActive;
      var busyUntil = '';
      var statusLabel = '';
      var statusTone = 'free';

      if (!isActive) {
        isFree = false;
        statusLabel = 'Unavailable';
        statusTone = 'off';
      } else if (shifts.isEmpty) {
        isFree = false;
        statusLabel = isToday
            ? 'Off today'
            : 'Off on ${DateFormat('EEE').format(date)}';
        statusTone = 'off';
      } else if (shifts.every(shiftOnLeave)) {
        isFree = false;
        statusLabel = 'On leave';
        statusTone = 'off';
      } else {
        // Live busyness only makes sense when booking for today.
        if (isToday) {
          final appointments = await _appointmentRepository
              .getActiveAppointmentsForTherapist(therapistId, dateKey);
          Map<String, dynamic>? nearestReservation;
          var nearestStart = 24 * 60 + 1;
          for (final appointment in appointments) {
            final start = _bookingTimeToMinutes(
              appointment['startTime']?.toString() ?? '00:00',
            );
            final end =
                _bookingTimeToMinutes(
                  appointment['endTime']?.toString() ?? '00:00',
                ) +
                _parseInt(appointment['bufferAfterMinutes'], fallback: 0);
            final hasStarted = appointment['actualStartedAt'] != null;
            if (hasStarted && end > nowMinutes) {
              isFree = false;
              busyUntil = _bookingMinutesToTime(end);
              break;
            }
            if (!hasStarted &&
                end > nowMinutes &&
                start < nearestStart &&
                start <= nowMinutes + 60) {
              nearestReservation = appointment;
              nearestStart = start;
            }
          }
          if (busyUntil.isEmpty && nearestReservation != null) {
            final reservedEnd =
                _bookingTimeToMinutes(
                  nearestReservation['endTime']?.toString() ?? '00:00',
                ) +
                _parseInt(
                  nearestReservation['bufferAfterMinutes'],
                  fallback: 0,
                );
            final range =
                '${_bookingTimeLabel(_bookingMinutesToTime(nearestStart))}–${_bookingTimeLabel(_bookingMinutesToTime(reservedEnd))}';
            statusLabel = 'Reserved $range';
            statusTone = 'reserved';
          }
        }
        if (busyUntil.isNotEmpty) {
          statusLabel = 'Busy until ${_bookingTimeLabel(busyUntil)}';
          statusTone = 'busy';
        } else if (statusLabel.isNotEmpty) {
          // Keep the explicit future reservation wording above.
        } else if (hasLeaveOverlap) {
          statusLabel = 'Limited availability';
          statusTone = 'busy';
        } else {
          statusLabel = 'Available';
          statusTone = 'free';
        }
      }

      therapists.add(
        _Therapist(
          id: therapistId,
          name: row['name']?.toString() ?? '',
          gender: row['gender']?.toString().trim().toLowerCase() ?? '',
          imageUrl:
              (row['imageUrl'] ?? row['photoUrl'] ?? row['profileImageUrl'])
                  ?.toString()
                  .trim() ??
              '',
          isFree: isFree,
          busyUntil: busyUntil,
          statusLabel: statusLabel,
          statusTone: statusTone,
        ),
      );
    }

    // Workable therapists first; off/leave sink to the bottom.
    const toneOrder = {'free': 0, 'busy': 1, 'off': 2};
    therapists.sort((a, b) {
      final byTone = (toneOrder[a.statusTone] ?? 1).compareTo(
        toneOrder[b.statusTone] ?? 1,
      );
      return byTone != 0 ? byTone : a.name.compareTo(b.name);
    });

    if (!mounted) return;
    setState(() {
      _therapists = therapists;
    });
  }

  Future<void> _loadRooms() async {
    final rows = await _roomRepository.getActiveRooms();
    final now = DateTime.now();
    final dateKey = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final isToday = dateKey == DateFormat('yyyy-MM-dd').format(now);
    final nowMinutes = now.hour * 60 + now.minute;

    final zones = <_RoomZone>[];
    for (final d in rows) {
      if (!_isActiveDoc(d)) continue;
      final totalSlots = _parseInt(d['totalSlots'], fallback: 1);
      // "Occupied right now" only applies when booking for today; for other
      // dates the per-slot capacity comes from Supabase in _generateSlots.
      var occupied = 0;
      if (isToday) {
        final appointments = await _appointmentRepository
            .getActiveAppointmentsForRoom(d['id']?.toString() ?? '', dateKey);
        occupied = appointments.where((appointment) {
          final start = _bookingTimeToMinutes(
            appointment['startTime']?.toString() ?? '00:00',
          );
          final end =
              _bookingTimeToMinutes(
                appointment['endTime']?.toString() ?? '00:00',
              ) +
              _parseInt(appointment['bufferAfterMinutes'], fallback: 0);
          return start <= nowMinutes && end > nowMinutes;
        }).length;
      }
      zones.add(
        _RoomZone(
          id: d['id']?.toString() ?? '',
          name: d['name'] ?? '',
          type: _normalizeRoomType(d['type'] ?? d['roomType']),
          floor: d['floor'] ?? '',
          imageUrl: (d['imageUrl'] ?? d['image'])?.toString().trim() ?? '',
          allocationMode:
              d['allocationMode']?.toString().trim().toLowerCase() ??
              d['allocation_mode']?.toString().trim().toLowerCase() ??
              'capacity',
          totalSlots: totalSlots,
          freeSlots: (totalSlots - occupied).clamp(0, totalSlots),
        ),
      );
    }
    setState(() => _rooms = zones);
  }

  int _parseInt(Object? value, {required int fallback}) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  Future<void> _loadCustomers() async {
    final rows = await _customerRepository.getCustomers();
    setState(() {
      _customers = rows.map((d) => _Customer.fromMap(d)).toList();
      _filteredCustomers = _customers;
    });
  }

  void _filterCustomers() {
    final q = _customerSearchController.text.trim().toLowerCase();
    setState(() {
      final selected = _selectedCustomer;
      final matchesSelected = selected != null &&
          (q == selected.name.toLowerCase() ||
              q == selected.phone.toLowerCase());
      if (selected != null && !matchesSelected) {
        _selectedCustomer = null;
      }
      _filteredCustomers = _customers
          .where(
            (c) =>
                c.name.toLowerCase().contains(q) ||
                c.phone.toLowerCase().contains(q),
          )
          .toList();
    });
  }

  String _todayString() => DateFormat('yyyy-MM-dd').format(DateTime.now());

  Future<void> _openAddCustomerDialog() async {
    final savedCustomer = await showDialog<_Customer>(
      context: context,
      builder: (context) => _QuickCustomerDialog(
        defaultJoinDate: _todayString(),
        customerBuilder: (id, data) => _Customer(
          id: id,
          name: data['name'] ?? '',
          phone: data['phone'] ?? '',
        ),
      ),
    );

    if (savedCustomer == null) return;

    _customerSearchController.text = savedCustomer.phone.isNotEmpty
        ? savedCustomer.phone
        : savedCustomer.name;
    setState(() {
      _customers = [..._customers, savedCustomer]
        ..sort((a, b) => a.name.compareTo(b.name));
      _filteredCustomers = _customers;
      _selectedCustomer = savedCustomer;
    });
  }

  void _selectCustomer(_Customer customer) {
    _customerSearchController.text = customer.phone.isNotEmpty
        ? customer.phone
        : customer.name;
    setState(() {
      _selectedCustomer = customer;
      _filteredCustomers = _customers;
    });
  }

  void _selectGuestCustomer() {
    FocusManager.instance.primaryFocus?.unfocus();
    // Clear first: the controller listener runs synchronously. Clearing after
    // assigning Guest made that listener immediately undo the first tap.
    _customerSearchController.clear();
    setState(() {
      _selectedCustomer = _Customer.guest;
      _filteredCustomers = _customers;
    });
  }

  void _clearCustomerSelection() {
    _customerSearchController.clear();
    setState(() {
      _selectedCustomer = null;
      _filteredCustomers = _customers;
    });
  }

  // ── CSP — Slot Generation ──────────────────────────────────────

  bool _isOriginalEditStart(int paxIndex, String start) {
    final payload = widget.editPayload;
    if (payload == null ||
        paxIndex < 0 ||
        paxIndex >= payload.allocations.length) {
      return false;
    }
    return _bookingCleanTime(payload.allocations[paxIndex].startTime) ==
        _bookingCleanTime(start);
  }

  Future<void> _generateCapacitySlots() async {
    if (!_isCapacityMode || !_capacityRequirementsComplete) return;

    final requestSerial = ++_slotRequestSerial;
    final requestedStart = _selectedSlot?.start;
    setState(() {
      _loadingSlots = true;
      _capacitySlotLoadError = null;
      _showAllStandardSlots = false;
      _scheduleBlocks = [];
    });

    try {
      final capacitySlots = await CspService.getCounterCapacitySlots(
        outletId: OutletContext.activeOutletId.value,
        date: DateFormat('yyyy-MM-dd').format(_selectedDate),
        requirements: _capacityRequirements,
      );
      if (!mounted || requestSerial != _slotRequestSerial) return;

      final slots = <_TimeSlot>[
        for (var index = 0; index < capacitySlots.length; index++)
          _TimeSlot(
            start: capacitySlots[index].startTime,
            end: capacitySlots[index].endTime,
            isRecommended:
                capacitySlots[index].isAvailable &&
                !capacitySlots
                    .take(index)
                    .any((candidate) => candidate.isAvailable),
            isAvailable: capacitySlots[index].isAvailable,
            reason: capacitySlots[index].isAvailable
                ? 'capacity_first_available'
                : '',
            unavailableDetail: capacitySlots[index].isAvailable
                ? ''
                : _capacityUnavailableDetail(capacitySlots[index]),
            roomAvailableSlots: capacitySlots[index].roomFree,
          ),
      ];
      final matching = requestedStart == null
          ? const <_TimeSlot>[]
          : slots.where((slot) => slot.start == requestedStart).toList();
      setState(() {
        _slots = slots;
        _selectedSlot = matching.isEmpty ? null : matching.first;
        _loadingSlots = false;
      });
    } catch (error) {
      if (!mounted || requestSerial != _slotRequestSerial) return;
      setState(() {
        _slots = [];
        _selectedSlot = null;
        _capacitySlotLoadError = friendlyErrorMessage(error);
        _loadingSlots = false;
      });
      AppToast.error(
        context,
        friendlyErrorMessage(error),
        title: 'Unable to load capacity',
      );
    }
  }

  Future<void> _generateSlots() async {
    if (_selectedServices.isEmpty) return;
    if (_selectedTherapist == null) return;
    if (_selectedRoom == null) return;
    if (_isEditing && !_isCheckInMode) {
      await _generateEditPreferenceSlots();
      return;
    }

    final requestSerial = ++_slotRequestSerial;
    final requestPaxIndex = _activePaxIndex;
    final requestedStart = _selectedSlot?.start;
    if (mounted) {
      setState(() {
        _loadingSlots = true;
        _showAllStandardSlots = false;
      });
    }

    final duration = _serviceDuration;
    final bufferAfterMinutes = _serviceBufferAfterMinutes;
    final date = DateFormat('yyyy-MM-dd').format(_selectedDate);

    try {
      final scheduleContextFuture = () async {
        try {
          return await CspService.getStaffBookingScheduleContext(
            date: date,
            therapistId: _selectedTherapist!.id,
            excludeId: _activeEditAppointmentId,
          );
        } catch (error) {
          debugPrint('Unable to load therapist schedule context: $error');
          return const <CspScheduleBlock>[];
        }
      }();
      final cspSlots = await CspService.getAvailableSlots(
        date: date,
        therapistId: _selectedTherapist!.id,
        roomId: _selectedRoom!.id,
        duration: duration,
        bufferAfterMinutes: bufferAfterMinutes,
        excludeId: _activeEditAppointmentId,
      );
      final scheduleBlocks = await scheduleContextFuture;
      final slots = _applyLocalPaxConstraints(
        cspSlots
            .map(
              (slot) => _TimeSlot(
                start: slot.startTime,
                end: slot.endTime,
                isRecommended: slot.isRecommended,
                isAvailable: slot.isAvailable,
                score: slot.score,
                reason: slot.reason,
                roomAvailableSlots: slot.roomAvailableSlots,
                previousBlockEnd: slot.previousBlockEnd,
                nextBlockStart: slot.nextBlockStart,
                gapBeforeMinutes: slot.gapBeforeMinutes,
                gapAfterMinutes: slot.gapAfterMinutes,
              ),
            )
            .toList(),
        requestPaxIndex,
      );
      if (!mounted ||
          requestSerial != _slotRequestSerial ||
          requestPaxIndex != _activePaxIndex) {
        return;
      }
      final matchingSlots = requestedStart == null
          ? const <_TimeSlot>[]
          : slots
                .where(
                  (slot) => slot.isAvailable && slot.start == requestedStart,
                )
                .toList();
      var matchingSlot = matchingSlots.isEmpty ? null : matchingSlots.first;
      if (matchingSlot == null &&
          requestedStart != null &&
          _isOriginalEditStart(requestPaxIndex, requestedStart)) {
        final requestedEnd = _bookingMinutesToTime(
          _bookingTimeToMinutes(requestedStart) + duration,
        );
        final requestedReservedEnd = _bookingMinutesToTime(
          _bookingTimeToMinutes(requestedStart) + duration + bufferAfterMinutes,
        );
        final validation = await CspService.validateSlot(
          date: DateFormat('yyyy-MM-dd').format(_selectedDate),
          startTime: requestedStart,
          endTime: requestedReservedEnd,
          therapistId: _selectedTherapist!.id,
          roomId: _selectedRoom!.id,
          excludeId: _activeEditAppointmentId,
        );
        if (!mounted ||
            requestSerial != _slotRequestSerial ||
            requestPaxIndex != _activePaxIndex) {
          return;
        }
        if (validation.therapistAvailable && !validation.roomFull) {
          matchingSlot = _TimeSlot(
            start: requestedStart,
            end: requestedEnd,
            isRecommended: false,
            isAvailable: true,
            reason: 'confirmed_booking',
          );
          slots.insert(0, matchingSlot);
        }
      }
      setState(() {
        _slots = slots;
        _scheduleBlocks = scheduleBlocks;
        if (requestedStart != null) {
          _selectedSlot = matchingSlot;
          if (matchingSlot == null) {
            _paxAllocations[requestPaxIndex] = null;
          }
        }
      });
      if (requestedStart != null && matchingSlot == null) {
        AppToast.error(
          context,
          'Pax ${requestPaxIndex + 1} no longer fits at the selected time. Choose another time, therapist, or room.',
          title: 'Time no longer available',
        );
      }
    } catch (e) {
      if (mounted &&
          requestSerial == _slotRequestSerial &&
          requestPaxIndex == _activePaxIndex) {
        setState(() {
          _slots = [];
          _scheduleBlocks = [];
        });
        AppToast.error(context, 'Unable to load available slots: $e');
      }
    } finally {
      if (mounted && requestSerial == _slotRequestSerial) {
        setState(() => _loadingSlots = false);
      }
    }
  }

  Future<void> _pickExactStartTime() async {
    if (_selectedServices.isEmpty ||
        _selectedTherapist == null ||
        _selectedRoom == null ||
        _loadingSlots) {
      return;
    }
    final now = DateTime.now();
    final initialMinutes = _selectedSlot == null
        ? (now.hour * 60 + now.minute + 4) ~/ 5 * 5
        : _bookingTimeToMinutes(_selectedSlot!.start);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: (initialMinutes ~/ 60) % 24,
        minute: initialMinutes % 60,
      ),
      helpText: 'Choose an exact start time',
      confirmText: 'Check Time',
    );
    if (picked == null || !mounted) return;

    final startMinutes = picked.hour * 60 + picked.minute;
    final selectedDay = _stripDate(_selectedDate);
    if (selectedDay == _stripDate(now) &&
        startMinutes <= now.hour * 60 + now.minute) {
      AppToast.info(context, 'Choose a time later than now');
      return;
    }

    final requestSerial = ++_slotRequestSerial;
    final start = _bookingMinutesToTime(startMinutes);
    final treatmentEnd = _bookingMinutesToTime(startMinutes + _serviceDuration);
    final reservedEnd = _bookingMinutesToTime(
      startMinutes + _serviceDuration + _serviceBufferAfterMinutes,
    );
    setState(() => _loadingSlots = true);
    try {
      final validation = await CspService.validateSlot(
        date: DateFormat('yyyy-MM-dd').format(_selectedDate),
        startTime: start,
        endTime: reservedEnd,
        therapistId: _selectedTherapist!.id,
        roomId: _selectedRoom!.id,
        excludeId: _activeEditAppointmentId,
      );
      if (!mounted || requestSerial != _slotRequestSerial) return;
      var exactSlot = _TimeSlot(
        start: start,
        end: treatmentEnd,
        isRecommended: false,
        isAvailable: validation.therapistAvailable && !validation.roomFull,
        reason: 'custom_time',
        roomAvailableSlots: validation.roomAvailableSlots,
      );
      exactSlot = _applyLocalPaxConstraints([exactSlot], _activePaxIndex).first;
      if (!exactSlot.isAvailable) {
        final details = <String>[
          if (!validation.therapistAvailable &&
              validation.therapistBusyUntil != null)
            'therapist busy until ${_bookingTimeLabel(validation.therapistBusyUntil!)}',
          if (validation.roomFull && validation.roomFullUntil != null)
            'room full until ${_bookingTimeLabel(validation.roomFullUntil!)}',
        ];
        AppToast.error(
          context,
          details.isEmpty
              ? 'The therapist or room is unavailable for the full treatment and cleanup period.'
              : details.join(' · '),
          title: 'Exact time is unavailable',
        );
        return;
      }
      setState(() {
        _slots = [
          exactSlot,
          ..._slots.where((slot) => slot.start != exactSlot.start),
        ];
      });
      _onSlotSelected(exactSlot);
      AppToast.success(context, 'Exact time is available');
    } catch (error) {
      if (mounted && requestSerial == _slotRequestSerial) {
        AppToast.error(context, 'Unable to check this time: $error');
      }
    } finally {
      if (mounted && requestSerial == _slotRequestSerial) {
        setState(() => _loadingSlots = false);
      }
    }
  }

  int _timeToMinutes(String t) {
    final p = t.split(':');
    return int.parse(p[0]) * 60 + int.parse(p[1]);
  }

  /// Supabase validates each slot against the database, but it cannot see the
  /// other pax picks that are still only in this screen's memory. Overlay
  /// those: the same therapist cannot serve two pax at once, and unsaved pax
  /// in the same room consume its remaining capacity.
  List<_TimeSlot> _applyLocalPaxConstraints(
    List<_TimeSlot> slots,
    int paxIndex,
  ) {
    final therapist = _selectedTherapist;
    final room = _selectedRoom;
    if (therapist == null || room == null) return slots;

    final others = <_BookingAllocation>[];
    for (var i = 0; i < _paxAllocations.length; i++) {
      if (i == paxIndex) continue;
      final allocation = _paxAllocations[i];
      if (allocation == null) continue;
      // Already-saved appointments are counted by Supabase itself.
      if (allocation.appointmentId.trim().isNotEmpty) continue;
      others.add(allocation);
    }
    if (others.isEmpty) return slots;

    final duration = _serviceDuration;
    final ownBuffer = _selectedServices.fold<int>(
      0,
      (buffer, service) => service.bufferAfterMinutes > buffer
          ? service.bufferAfterMinutes
          : buffer,
    );

    return slots.map((slot) {
      if (!slot.isAvailable) return slot;
      final start = _bookingTimeToMinutes(slot.start);
      final end = start + duration + ownBuffer;
      var roomTaken = 0;
      for (final other in others) {
        final otherStart = _bookingTimeToMinutes(other.slot.start);
        var otherEnd = _bookingTimeToMinutes(other.endTime);
        if (otherEnd <= otherStart) otherEnd += 24 * 60;
        otherEnd += other.services.fold<int>(
          0,
          (buffer, service) => service.bufferAfterMinutes > buffer
              ? service.bufferAfterMinutes
              : buffer,
        );
        final overlaps = start < otherEnd && end > otherStart;
        if (!overlaps) continue;
        if (other.therapist.id == therapist.id) {
          return _TimeSlot(
            start: slot.start,
            end: slot.end,
            isRecommended: false,
            isAvailable: false,
            reason: 'assigned_to_other_pax',
            roomAvailableSlots: slot.roomAvailableSlots,
          );
        }
        if (other.room.id == room.id) roomTaken++;
      }
      // Before migration 076 the RPC does not report per-slot capacity;
      // fall back to the room's total capacity so nothing is over-blocked.
      final capacity = slot.roomAvailableSlots > 0
          ? slot.roomAvailableSlots
          : room.totalSlots;
      if (roomTaken > 0 && roomTaken >= capacity) {
        return _TimeSlot(
          start: slot.start,
          end: slot.end,
          isRecommended: false,
          isAvailable: false,
          reason: 'room_full',
          roomAvailableSlots: 0,
        );
      }
      return slot;
    }).toList();
  }

  // ── Selection Handlers ─────────────────────────────────────────

  void _onServiceSelected(_Service s) {
    if (_isCapacityMode) {
      _slotRequestSerial++;
      setState(() {
        final existingIndex = _selectedServices.indexWhere(
          (service) => service.id == s.id,
        );
        if (existingIndex == -1) {
          _selectedServices.add(s);
        } else {
          _selectedServices.removeAt(existingIndex);
        }
        _syncActiveCapacityServices();
        _selectedSlot = null;
        _slots = [];
        _capacitySlotLoadError = null;
        _scheduleBlocks = [];
        _loadingSlots = false;
      });
      if (_capacityRequirementsComplete) {
        unawaited(_generateCapacitySlots());
      }
      return;
    }

    if (_lockedServiceIds.contains(s.id) &&
        _selectedServices.any((service) => service.id == s.id)) {
      AppToast.info(context, 'Booked services stay in this visit');
      return;
    }
    final isRemoving = _selectedServices.any((service) => service.id == s.id);
    _slotRequestSerial++;
    var shouldGenerateSlots = false;
    setState(() {
      final existingIndex = _selectedServices.indexWhere(
        (service) => service.id == s.id,
      );
      if (existingIndex == -1) {
        _selectedServices.add(s);
      } else {
        _selectedServices.removeAt(existingIndex);
      }
      if (_selectedSlot != null) {
        _previousSlotReference = _selectedSlot;
        _selectedSlot = _slotWithCurrentDuration(_selectedSlot!);
      }
      final requiredRoomType = _requiredRoomType;
      if (_selectedRoom != null &&
          (!_hasCompatibleRoomType ||
              _selectedRoom!.type != requiredRoomType)) {
        _selectedRoom = null;
        _selectedSlot = null;
      }
      _slots = [];
      _scheduleBlocks = [];
      _loadingSlots = false;
      _paxAllocations[_activePaxIndex] = null;
      shouldGenerateSlots =
          _selectedServices.isNotEmpty &&
          _selectedTherapist != null &&
          _selectedRoom != null;
    });
    if (shouldGenerateSlots) _generateSlots();
    if (!isRemoving && _selectedTherapist == null) {
      unawaited(_autoAssignProvisionalTherapist());
    }
  }

  _TimeSlot _slotWithCurrentDuration(_TimeSlot slot) {
    final start = _bookingCleanTime(slot.start);
    return _TimeSlot(
      start: start,
      end: _bookingMinutesToTime(
        _bookingTimeToMinutes(start) + _serviceDuration,
      ),
      isRecommended: slot.isRecommended,
      isAvailable: slot.isAvailable,
      score: slot.score,
      reason: slot.reason,
      roomAvailableSlots: slot.roomAvailableSlots,
      previousBlockEnd: slot.previousBlockEnd,
      nextBlockStart: slot.nextBlockStart,
      gapBeforeMinutes: slot.gapBeforeMinutes,
      gapAfterMinutes: slot.gapAfterMinutes,
    );
  }

  String? get _activeEditAppointmentId {
    final payload = widget.editPayload;
    if (payload == null) return null;
    if (_activePaxIndex < 0 || _activePaxIndex >= payload.allocations.length) {
      return payload.appointmentId;
    }
    final id = payload.allocations[_activePaxIndex].appointmentId.trim();
    return id.isEmpty ? payload.appointmentId : id;
  }

  void _onTherapistSelected(_Therapist t) {
    _slotRequestSerial++;
    setState(() {
      _selectedTherapist = t;
      _selectedSlot = null;
      _slots = [];
      _scheduleBlocks = [];
      _loadingSlots = false;
      _paxAllocations[_activePaxIndex] = null;
    });
    if (_selectedServices.isNotEmpty && _selectedRoom != null) _generateSlots();
  }

  Future<void> _generateEditPreferenceSlots() async {
    final payload = widget.editPayload;
    if (payload == null || _selectedTherapist == null) return;
    final requestSerial = ++_slotRequestSerial;
    final requestedStart = _selectedSlot?.start;
    setState(() => _loadingSlots = true);
    try {
      final requirements = <CounterCapacityRequirement>[];
      for (var index = 0; index < payload.allocations.length; index++) {
        final allocation = index == _activePaxIndex
            ? _BookingAllocation(
                appointmentId: _activeEditAppointmentId ?? '',
                services: List<_Service>.from(_selectedServices),
                therapist: _selectedTherapist!,
                room: _selectedRoom!,
                slot:
                    _selectedSlot ??
                    _TimeSlot(
                      start: payload.allocations[index].startTime,
                      end: payload.allocations[index].endTime,
                      isRecommended: false,
                      isAvailable: true,
                    ),
              )
            : _paxAllocations[index];
        if (allocation == null) return;
        final roomTypes = allocation.services
            .map((service) => service.roomType)
            .where((type) => type.isNotEmpty)
            .toSet();
        if (roomTypes.length != 1) return;
        requirements.add(
          CounterCapacityRequirement(
            paxIndex: index + 1,
            serviceIds: allocation.services
                .map((service) => service.id)
                .toList(),
            durationMinutes: allocation.duration,
            bufferAfterMinutes: allocation.services.fold<int>(
              0,
              (buffer, service) => service.bufferAfterMinutes > buffer
                  ? service.bufferAfterMinutes
                  : buffer,
            ),
            roomType: roomTypes.first,
            assignmentSource: allocation.therapist.assignmentSource,
            requestedGender: allocation.therapist.requestedGender,
            requestedTherapistId:
                allocation.therapist.assignmentSource ==
                    'specific_customer_request'
                ? allocation.therapist.id
                : null,
          ),
        );
      }
      final capacitySlots = await CspService.getCounterCapacitySlots(
        outletId: OutletContext.activeOutletId.value,
        date: DateFormat('yyyy-MM-dd').format(_selectedDate),
        requirements: requirements,
        excludeGroupId: payload.appointmentGroupId,
        excludeId: payload.isGroup ? null : _activeEditAppointmentId,
      );
      if (!mounted || requestSerial != _slotRequestSerial) return;
      final slots = [
        for (var index = 0; index < capacitySlots.length; index++)
          _TimeSlot(
            start: capacitySlots[index].startTime,
            end: capacitySlots[index].endTime,
            isRecommended:
                capacitySlots[index].isAvailable &&
                !capacitySlots
                    .take(index)
                    .any((candidate) => candidate.isAvailable),
            isAvailable: capacitySlots[index].isAvailable,
            reason: capacitySlots[index].isAvailable
                ? 'capacity_first_available'
                : '',
            unavailableDetail: capacitySlots[index].isAvailable
                ? ''
                : _capacityUnavailableDetail(capacitySlots[index]),
          ),
      ];
      final matching = requestedStart == null
          ? const <_TimeSlot>[]
          : slots
                .where(
                  (slot) => slot.isAvailable && slot.start == requestedStart,
                )
                .toList();
      setState(() {
        _slots = slots;
        _selectedSlot = matching.isEmpty ? null : matching.first;
      });
    } catch (error) {
      if (mounted && requestSerial == _slotRequestSerial) {
        setState(() {
          _slots = [];
          _selectedSlot = null;
        });
        AppToast.error(
          context,
          friendlyErrorMessage(error),
          title: 'Unable to load availability',
        );
      }
    } finally {
      if (mounted && requestSerial == _slotRequestSerial) {
        setState(() => _loadingSlots = false);
      }
    }
  }

  String _capacityUnavailableDetail(CounterCapacitySlot slot) {
    final conflictTherapist = _therapists.where(
      (therapist) => therapist.id == slot.conflictTherapistId,
    );
    final therapistName = conflictTherapist.isNotEmpty
        ? conflictTherapist.first.name
        : null;
    if (slot.conflictStart != null && slot.conflictEnd != null) {
      return 'Unavailable — ${therapistName ?? 'therapist'} is reserved from '
          '${_bookingTimeLabel(slot.conflictStart!)} to '
          '${_bookingTimeLabel(slot.conflictEnd!)}.';
    }
    if (slot.unavailableDimension == 'room') {
      return 'Unavailable — suitable room capacity is full.';
    }
    if (therapistName != null) {
      return 'Unavailable — $therapistName cannot cover the full service window.';
    }
    if (slot.unavailableDimension == 'therapist') {
      return 'Unavailable — no eligible therapist can cover the complete service and cleanup window at this time.';
    }
    return 'Unavailable';
  }

  String get _therapistQueueReferenceTime {
    if (_isCheckInMode) {
      return DateFormat('HH:mm:ss').format(DateTime.now());
    }
    final selectedStart = _selectedSlot?.start.trim() ?? '';
    if (selectedStart.isNotEmpty) return selectedStart;
    final payload = widget.editPayload;
    if (payload != null &&
        _activePaxIndex >= 0 &&
        _activePaxIndex < payload.allocations.length) {
      return _bookingCleanTime(payload.allocations[_activePaxIndex].startTime);
    }
    return DateFormat('HH:mm:ss').format(DateTime.now());
  }

  void _onQueueTherapistSelected(TherapistAssignmentPick pick) {
    final match = _therapists.where((t) => t.id == pick.therapistId);
    final base = match.isNotEmpty
        ? match.first
        : _Therapist(
            id: pick.therapistId,
            name: pick.therapistName,
            gender: '',
            imageUrl: '',
            isFree: true,
            busyUntil: '',
          );
    _onTherapistSelected(
      base.withAssignment(
        source: pick.assignmentSource,
        requestedGender: pick.requestedGender,
      ),
    );
  }

  /// Future appointments don't force staff to hand-pick a therapist at
  /// booking time -- the live queue recommendation is assigned provisionally,
  /// and the check-in picker (or a manual tap on a therapist card here) locks
  /// the real one later. Only applies to brand-new, non-check-in bookings;
  /// edits and check-in keep whatever the appointment already carries.
  Future<void> _autoAssignProvisionalTherapist() async {
    if (_isEditing || _selectedTherapist != null) return;
    if (_selectedServices.isEmpty || _therapists.isEmpty) return;
    final requestedTherapist = _selectedTherapist;
    List<TherapistQueueEntry> entries;
    try {
      entries = await CspService.getTherapistQueue(
        outletId: OutletContext.activeOutletId.value,
        date: DateFormat('yyyy-MM-dd').format(_selectedDate),
        nowTime: DateFormat('HH:mm:ss').format(DateTime.now()),
        duration: _serviceDuration,
      );
    } catch (_) {
      return;
    }
    if (!mounted || _selectedTherapist != requestedTherapist) return;

    final recommended = entries.where((e) => e.isFreeNow).toList();
    if (recommended.isEmpty) return;
    final pick = recommended.first;
    final match = _therapists.where((t) => t.id == pick.therapistId);
    if (match.isEmpty || !mounted || _selectedTherapist != requestedTherapist) {
      return;
    }
    _onTherapistSelected(
      match.first.withAssignment(
        source: 'queue',
        therapistAssignmentState: 'pending',
      ),
    );
  }

  void _onRoomSelected(_RoomZone r) {
    _slotRequestSerial++;
    setState(() {
      _selectedRoom = r;
      _roomUnitAvailability = const [];
      _selectedSlot = null;
      _slots = [];
      _scheduleBlocks = [];
      _loadingSlots = false;
      _paxAllocations[_activePaxIndex] = null;
    });
    if (_selectedServices.isNotEmpty && _selectedTherapist != null) {
      _generateSlots();
    }
  }

  Future<void> _loadRoomUnitAvailability() async {
    final room = _selectedRoom;
    final slot = _selectedSlot;
    if (room == null || slot == null || !room.usesSpecificRooms) return;
    final requestSerial = _slotRequestSerial;
    setState(() => _loadingRoomUnits = true);
    try {
      final units = await CspService.getRoomUnitAvailability(
        zoneId: room.id,
        date: DateFormat('yyyy-MM-dd').format(_selectedDate),
        startTime: slot.start,
        duration: _serviceDuration,
      );
      if (!mounted || requestSerial != _slotRequestSerial) return;
      setState(() => _roomUnitAvailability = units);
    } catch (error, stackTrace) {
      debugPrint('get_room_unit_availability failed: $error\n$stackTrace');
      if (!mounted || requestSerial != _slotRequestSerial) return;
      setState(() => _roomUnitAvailability = const []);
      AppToast.error(context, 'Unable to load individual room availability');
    } finally {
      if (mounted && requestSerial == _slotRequestSerial) {
        setState(() => _loadingRoomUnits = false);
      }
    }
  }

  void _onSlotSelected(_TimeSlot slot) {
    setState(() {
      _selectedSlot = slot;
      _roomUnitAvailability = const [];
      _paxAllocations[_activePaxIndex] = null;
    });
    unawaited(_loadRoomUnitAvailability());
  }

  void _setSelectedDate(DateTime date) {
    _slotRequestSerial++;
    setState(() {
      _selectedDate = _stripDate(date);
      _selectedSlot = null;
      _slots = [];
      _capacitySlotLoadError = null;
      _scheduleBlocks = [];
      _loadingSlots = false;
    });
    if (_isCapacityMode) {
      if (_capacityRequirementsComplete) {
        unawaited(_generateCapacitySlots());
      }
      return;
    }
    _loadTherapists();
    _loadRooms();
    if (_selectedServices.isNotEmpty &&
        _selectedTherapist != null &&
        _selectedRoom != null) {
      _generateSlots();
    }
  }

  int get _serviceDuration =>
      _selectedServices.fold(0, (total, service) => total + service.duration);

  int get _serviceBufferAfterMinutes => _selectedServices.fold<int>(
    0,
    (buffer, service) => service.bufferAfterMinutes > buffer
        ? service.bufferAfterMinutes
        : buffer,
  );

  double get _servicePrice =>
      _selectedServices.fold(0, (total, service) => total + service.price);

  String get _serviceNameSummary {
    if (_selectedServices.isEmpty) return '';
    if (_selectedServices.length == 1) return _selectedServices.first.name;
    return _selectedServices.map((service) => service.name).join(', ');
  }

  List<_CapacityPaxSelection> get _capacitySelections => [
    for (var index = 0; index < _capacityPaxServices.length; index++)
      _CapacityPaxSelection(
        services: List<_Service>.unmodifiable(_capacityPaxServices[index]),
        preference: _capacityPaxPreferences[index],
      ),
  ];

  int get _capacityConfiguredPax =>
      _capacitySelections.where((selection) => selection.isComplete).length;

  bool get _capacityRequirementsComplete =>
      _capacityPaxServices.length == _paxCount &&
      _capacityConfiguredPax == _paxCount;

  List<CounterCapacityRequirement> get _capacityRequirements => [
    for (var index = 0; index < _capacitySelections.length; index++)
      _capacitySelections[index].toRequirement(index + 1),
  ];

  double get _capacityTotalPrice => _capacitySelections.fold(
    0,
    (total, selection) => total + selection.price,
  );

  int get _capacityTotalDuration => _capacitySelections.fold(
    0,
    (total, selection) => total + selection.duration,
  );

  String get _capacityServiceNameSummary {
    final configured = _capacitySelections
        .where((selection) => selection.services.isNotEmpty)
        .toList();
    if (configured.isEmpty) return '';
    if (_paxCount == 1) return configured.first.serviceNameSummary;
    return '${configured.length} of $_paxCount pax configured';
  }

  void _syncActiveCapacityServices() {
    if (!_isCapacityMode ||
        _activePaxIndex < 0 ||
        _activePaxIndex >= _capacityPaxServices.length) {
      return;
    }
    _capacityPaxServices[_activePaxIndex] = List<_Service>.from(
      _selectedServices,
    );
  }

  void _loadCapacityPaxServices(int index) {
    _selectedServices
      ..clear()
      ..addAll(_capacityPaxServices[index]);
  }

  void _setCapacityPreference(_CapacityTherapistPreference preference) {
    if (!_isCapacityMode) return;
    _slotRequestSerial++;
    setState(() {
      _capacityPaxPreferences[_activePaxIndex] = preference;
      _selectedSlot = null;
      _slots = [];
      _capacitySlotLoadError = null;
    });
    if (_capacityRequirementsComplete) {
      unawaited(_generateCapacitySlots());
    }
  }

  bool get _hasCurrentAllocation =>
      _selectedServices.isNotEmpty &&
      _hasCompatibleRoomType &&
      _selectedTherapist != null &&
      _selectedRoom != null &&
      _selectedSlot != null;

  _BookingAllocation? get _currentAllocation {
    if (!_hasCurrentAllocation) return null;
    return _BookingAllocation(
      appointmentId: _activeEditAppointmentId ?? '',
      services: List<_Service>.from(_selectedServices),
      therapist: _selectedTherapist!,
      room: _selectedRoom!,
      slot: _selectedSlot!,
    );
  }

  List<_BookingAllocation?> get _allocationSlots {
    final allocations = List<_BookingAllocation?>.from(_paxAllocations);
    final current = _currentAllocation;
    if (current != null) allocations[_activePaxIndex] = current;
    return allocations;
  }

  List<_BookingAllocation> get _checkoutAllocations =>
      _allocationSlots.whereType<_BookingAllocation>().toList();

  bool _isTherapistReservedInBooking(String therapistId) {
    return _allocationSlots.whereType<_BookingAllocation>().any(
      (allocation) => allocation.therapist.id == therapistId,
    );
  }

  bool get _hasUnpaidAddOns {
    final payload = widget.editPayload;
    if (payload == null || !payload.hasPayment) return false;
    final paidIdsByAppointment = {
      for (final allocation in payload.allocations)
        allocation.appointmentId: allocation.lockedServiceIds.toSet(),
    };
    return _checkoutAllocations.any((allocation) {
      final paidIds =
          paidIdsByAppointment[allocation.appointmentId] ?? const <String>{};
      return allocation.services.any(
        (service) => !paidIds.contains(service.id),
      );
    });
  }

  double get _bookingTotalPrice => _checkoutAllocations.fold(
    0,
    (total, allocation) => total + allocation.price,
  );

  int get _bookingTotalDuration => _checkoutAllocations.fold(
    0,
    (total, allocation) => total + allocation.duration,
  );

  String get _bookingServiceNameSummary {
    final allocations = _checkoutAllocations;
    if (allocations.isEmpty) return '';
    if (allocations.length == 1) return allocations.first.serviceNameSummary;
    return '${allocations.length} pax booking';
  }

  void _clearCurrentAllocationSelection() {
    _slotRequestSerial++;
    _selectedServices.clear();
    _selectedTherapist = null;
    _selectedRoom = null;
    _selectedSlot = null;
    _previousSlotReference = null;
    _slots = [];
    _scheduleBlocks = [];
    _loadingSlots = false;
  }

  void _loadAllocationIntoSelection(_BookingAllocation? allocation) {
    if (allocation == null) {
      _clearCurrentAllocationSelection();
      return;
    }
    _selectedServices
      ..clear()
      ..addAll(allocation.services);
    _selectedTherapist = allocation.therapist;
    _selectedRoom = allocation.room;
    _selectedSlot = allocation.slot;
    _previousSlotReference = allocation.slot;
    _scheduleBlocks = [];
    _slots = [allocation.slot];
    _loadingSlots = false;
  }

  bool _timesOverlap(_BookingAllocation a, _BookingAllocation b) {
    final aStart = _bookingTimeToMinutes(a.slot.start);
    var aEnd = _bookingTimeToMinutes(a.endTime);
    final bStart = _bookingTimeToMinutes(b.slot.start);
    var bEnd = _bookingTimeToMinutes(b.endTime);
    if (aEnd <= aStart) aEnd += 24 * 60;
    if (bEnd <= bStart) bEnd += 24 * 60;
    aEnd += a.services.fold<int>(
      0,
      (buffer, service) => service.bufferAfterMinutes > buffer
          ? service.bufferAfterMinutes
          : buffer,
    );
    bEnd += b.services.fold<int>(
      0,
      (buffer, service) => service.bufferAfterMinutes > buffer
          ? service.bufferAfterMinutes
          : buffer,
    );
    return aStart < bEnd && aEnd > bStart;
  }

  String? _allocationConflictMessage(
    _BookingAllocation allocation, {
    required int index,
  }) {
    for (var i = 0; i < _paxAllocations.length; i++) {
      if (i == index) continue;
      final other = _paxAllocations[i];
      if (other == null) continue;
      if (other.therapist.id == allocation.therapist.id &&
          _timesOverlap(allocation, other)) {
        return 'Pax ${index + 1} overlaps Pax ${i + 1}. ${allocation.therapist.name} is already assigned at that time.';
      }
    }
    return null;
  }

  String? get _paxConflictMessage {
    final allocations = _allocationSlots;
    for (var i = 0; i < allocations.length; i++) {
      final allocation = allocations[i];
      if (allocation == null) continue;
      for (var j = i + 1; j < allocations.length; j++) {
        final other = allocations[j];
        if (other == null) continue;
        if (allocation.therapist.id == other.therapist.id &&
            _timesOverlap(allocation, other)) {
          return 'Pax ${i + 1} and Pax ${j + 1} use ${allocation.therapist.name} at overlapping times.';
        }
      }
    }
    return null;
  }

  bool _canStoreCurrentAllocation() {
    final current = _currentAllocation;
    if (current == null) return false;
    return _allocationConflictMessage(current, index: _activePaxIndex) == null;
  }

  void _showPaxConflict(String message) {
    AppToast.error(context, message, title: 'Pax conflict');
  }

  void _selectPax(int index) {
    if (_isCapacityMode) {
      if (index < 0 || index >= _capacityPaxServices.length) return;
      setState(() {
        _syncActiveCapacityServices();
        _activePaxIndex = index;
        _loadCapacityPaxServices(index);
      });
      return;
    }

    final current = _currentAllocation;
    if (current != null) {
      final conflict = _allocationConflictMessage(
        current,
        index: _activePaxIndex,
      );
      if (conflict != null) {
        _showPaxConflict(conflict);
        return;
      }
    }
    setState(() {
      if (current != null) _paxAllocations[_activePaxIndex] = current;
      _activePaxIndex = index;
      _loadAllocationIntoSelection(_paxAllocations[index]);
    });
    if (_selectedServices.isNotEmpty &&
        _selectedTherapist != null &&
        _selectedRoom != null) {
      _generateSlots();
    }
  }

  void _clearPax(int index) {
    if (_isCheckInMode) return;
    if (_isCapacityMode) {
      if (index < 0 || index >= _capacityPaxServices.length) return;
      _slotRequestSerial++;
      setState(() {
        _capacityPaxServices[index] = <_Service>[];
        _capacityPaxPreferences[index] =
            const _CapacityTherapistPreference();
        _activePaxIndex = index;
        _loadCapacityPaxServices(index);
        _selectedSlot = null;
        _slots = [];
        _capacitySlotLoadError = null;
        _loadingSlots = false;
      });
      return;
    }
    setState(() {
      _paxAllocations[index] = null;
      _activePaxIndex = index;
      _loadAllocationIntoSelection(null);
    });
  }

  void _setPaxCount(int count) {
    if (count < 1 || _isCheckInMode || _locksPaxCount) return;
    if (_isCapacityMode) {
      _slotRequestSerial++;
      setState(() {
        _syncActiveCapacityServices();
        _paxCount = count;
        while (_capacityPaxServices.length < count) {
          _capacityPaxServices.add(<_Service>[]);
          _capacityPaxPreferences.add(const _CapacityTherapistPreference());
        }
        while (_capacityPaxServices.length > count) {
          _capacityPaxServices.removeLast();
          _capacityPaxPreferences.removeLast();
        }
        while (_paxAllocations.length < count) {
          _paxAllocations.add(null);
        }
        while (_paxAllocations.length > count) {
          _paxAllocations.removeLast();
        }
        if (_activePaxIndex >= count) _activePaxIndex = count - 1;
        _loadCapacityPaxServices(_activePaxIndex);
        _selectedSlot = null;
        _slots = [];
        _capacitySlotLoadError = null;
        _loadingSlots = false;
      });
      if (_capacityRequirementsComplete) {
        unawaited(_generateCapacitySlots());
      }
      return;
    }
    setState(() {
      final current = _currentAllocation;
      if (current != null && _canStoreCurrentAllocation()) {
        _paxAllocations[_activePaxIndex] = current;
      }
      _paxCount = count;
      while (_paxAllocations.length < count) {
        _paxAllocations.add(null);
      }
      while (_paxAllocations.length > count) {
        _paxAllocations.removeLast();
      }
      if (_activePaxIndex >= count) _activePaxIndex = count - 1;
      _loadAllocationIntoSelection(_paxAllocations[_activePaxIndex]);
    });
  }

  String get _requiredRoomType {
    final types = _selectedRoomTypes;
    return types.length == 1 ? types.first : '';
  }

  Set<String> get _selectedRoomTypes => _selectedServices
      .map((service) => service.roomType)
      .where((type) => type.isNotEmpty)
      .toSet();

  bool get _hasMissingRoomType =>
      _selectedServices.any((service) => service.roomType.isEmpty);

  bool get _hasMixedRoomTypes => _selectedRoomTypes.length > 1;

  bool get _hasCompatibleRoomType =>
      _selectedServices.isNotEmpty &&
      !_hasMissingRoomType &&
      _selectedRoomTypes.length == 1;

  void _onDateChanged(int days) {
    _setSelectedDate(_selectedDate.add(Duration(days: days)));
  }

  Future<void> _openDatePicker() async {
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (context) =>
          _BookingMonthCalendarDialog(initialDate: _selectedDate),
    );
    if (picked != null) _setSelectedDate(picked);
  }

  // ── Confirm Appointment ────────────────────────────────────────

  bool get _canConfirm {
    if (_isCapacityMode) {
      return _selectedCustomer != null &&
          _capacityRequirementsComplete &&
          !_loadingSlots &&
          _selectedSlotIsAvailable;
    }
    return _selectedCustomer != null &&
        _checkoutAllocations.length == _paxCount &&
        !_loadingSlots &&
        _selectedSlotIsAvailable &&
        _paxConflictMessage == null;
  }

  bool get _selectedSlotIsAvailable {
    final selected = _selectedSlot;
    if (selected == null) return false;
    if (_slots.isEmpty || _loadingSlots) return true;
    return _slots.any(
      (slot) => slot.isAvailable && slot.start == selected.start,
    );
  }

  List<String> get _missingSlotRequirements {
    final missing = <String>[];
    if (_isCapacityMode) {
      if (_capacitySelections.any((selection) => selection.services.isEmpty)) {
        missing.add('services for every pax');
      }
      if (_capacitySelections.any(
        (selection) => selection.services.isNotEmpty && !selection.isComplete,
      )) {
        missing.add('one compatible room type per pax');
      }
      return missing;
    }
    if (_selectedServices.isEmpty) missing.add('service');
    if (_selectedServices.isNotEmpty && !_hasCompatibleRoomType) {
      missing.add('one compatible room type');
    }
    if (_selectedTherapist == null) missing.add('therapist');
    if (_selectedRoom == null) missing.add('room');
    return missing;
  }

  Future<void> _confirmCapacityAppointment() async {
    if (!_canConfirm || _selectedSlot == null) return;
    setState(() => _isConfirming = true);

    try {
      final date = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final provisional = await CspService.allocateProvisionalSlots(
        outletId: OutletContext.activeOutletId.value,
        date: date,
        startTime: _selectedSlot!.start,
        requirements: _capacityRequirements,
      );
      if (!mounted) return;

      final provisionalByPax = {
        for (final allocation in provisional) allocation.paxIndex: allocation,
      };
      if (provisionalByPax.length != _paxCount) {
        await _showCapacityNoLongerAvailable();
        return;
      }

      final allocations = <_BookingAllocation>[];
      for (var index = 0; index < _paxCount; index++) {
        final provisionalAllocation = provisionalByPax[index + 1];
        if (provisionalAllocation == null) {
          await _showCapacityNoLongerAvailable();
          return;
        }
        final therapistMatches = _therapists.where(
          (therapist) => therapist.id == provisionalAllocation.therapistId,
        );
        final roomMatches = _rooms.where(
          (room) => room.id == provisionalAllocation.roomId,
        );
        if (therapistMatches.isEmpty || roomMatches.isEmpty) {
          await _showCapacityNoLongerAvailable();
          return;
        }

        final services = List<_Service>.from(_capacityPaxServices[index]);
        final preference = _capacityPaxPreferences[index];
        final duration = services.fold<int>(
          0,
          (total, service) => total + service.duration,
        );
        allocations.add(
          _BookingAllocation(
            services: services,
            therapist: therapistMatches.first.withAssignment(
              source: preference.assignmentSource,
              requestedGender: preference.requestedGender,
              therapistAssignmentState: 'pending',
            ),
            room: roomMatches.first,
            slot: _TimeSlot(
              start: _selectedSlot!.start,
              end: _bookingMinutesToTime(
                _bookingTimeToMinutes(_selectedSlot!.start) + duration,
              ),
              isRecommended: false,
              isAvailable: true,
            ),
          ),
        );
      }

      // create_appointment*_with_csp performs the final conflict check. Its
      // appointment trigger takes an outlet/date transaction advisory lock,
      // so a concurrent booking either succeeds fully or rolls this RPC back;
      // a group cannot be partially inserted.
      final CspCreateResult result;
      if (allocations.length == 1) {
        final allocation = allocations.first;
        result = await CspService.createAppointment(
          customerId: _selectedCustomer!.id,
          therapistId: allocation.therapist.id,
          roomId: allocation.room.id,
          serviceId: allocation.primaryService.id,
          serviceName: allocation.serviceNameSummary,
          serviceItems: allocation.serviceItems,
          itemCount: allocation.services.length,
          date: date,
          startTime: allocation.slot.start,
          endTime: allocation.endTime,
          totalPrice: allocation.price,
          type: 'appointment',
          assignmentSource: allocation.therapist.assignmentSource,
          requestedTherapistId:
              allocation.therapist.assignmentSource ==
                  'specific_customer_request'
              ? allocation.therapist.id
              : null,
          requestedGender: allocation.therapist.requestedGender,
        );
      } else {
        result = await CspService.createAppointmentGroup(
          customerId: _selectedCustomer!.id,
          groupName: _selectedCustomer!.name,
          paxCount: allocations.length,
          date: date,
          allocations: allocations
              .asMap()
              .entries
              .map(
                (entry) => entry.value.toCspAllocation(
                  paxIndex: entry.key + 1,
                ),
              )
              .toList(),
          type: 'appointment',
        );
      }

      if (!mounted) return;
      if (!result.success) {
        await _showCapacityNoLongerAvailable();
        return;
      }

      AppToast.success(context, 'Appointment confirmed');
      Navigator.pop(context, true);
    } catch (_) {
      if (mounted) await _showCapacityNoLongerAvailable();
    } finally {
      if (mounted) setState(() => _isConfirming = false);
    }
  }

  Future<void> _showCapacityNoLongerAvailable() async {
    if (!mounted) return;
    AppToast.error(
      context,
      'This time is no longer available.',
      title: 'Choose another time',
    );
    setState(() => _selectedSlot = null);
    await _generateCapacitySlots();
  }

  Future<void> _confirmAppointment({Object? popResult}) async {
    if (!_canConfirm) return;
    if (_isCapacityMode) {
      await _confirmCapacityAppointment();
      return;
    }
    setState(() => _isConfirming = true);

    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final allocations = _checkoutAllocations;
      final conflict = _paxConflictMessage;
      if (conflict != null) {
        if (mounted) _showPaxConflict(conflict);
        return;
      }
      for (final allocation in allocations) {
        final slotStart = _timeToMinutes(allocation.slot.start);
        final slotEnd = _timeToMinutes(allocation.endTime);
        if (slotStart == slotEnd) {
          if (mounted) {
            AppToast.error(context, 'Invalid appointment time selected');
          }
          return;
        }
      }

      final CspCreateResult result;
      if (_isEditing && widget.editPayload!.isGroup) {
        final editAllocations = widget.editPayload!.allocations;
        final editAllocationsById = {
          for (final allocation in editAllocations)
            allocation.appointmentId: allocation,
        };
        result = await CspService.updateAppointmentGroup(
          appointmentGroupId: widget.editPayload!.appointmentGroupId!,
          customerId: _selectedCustomer!.id,
          groupName: _selectedCustomer!.name,
          paxCount: allocations.length,
          date: dateStr,
          allocations: [
            for (var index = 0; index < allocations.length; index++)
              {
                ...allocations[index].toCspAllocation(paxIndex: index + 1),
                'notes': widget.editPayload!.notes,
                if (_isCheckInMode || widget.editPayload!.hasPayment)
                  'service_items': allocations[index].serviceItems
                      .map(
                        (item) => {
                          ...item,
                          'lineType':
                              (editAllocationsById[allocations[index]
                                              .appointmentId]
                                          ?.bookedServiceIds ??
                                      const <String>[])
                                  .contains(item['id'])
                              ? 'booked'
                              : 'add_on',
                        },
                      )
                      .toList(),
              },
          ],
          type: 'appointment',
          notes: widget.editPayload!.notes,
        );
      } else if (_isEditing && widget.editPayload!.appointmentId != null) {
        final allocation = allocations.first;
        result = await CspService.updateAppointment(
          appointmentId: widget.editPayload!.appointmentId!,
          therapistId: allocation.therapist.id,
          roomId: allocation.room.id,
          date: dateStr,
          startTime: allocation.slot.start,
          endTime: allocation.endTime,
          assignmentSource: allocation.therapist.assignmentSource,
          requestedTherapistId:
              allocation.therapist.assignmentSource ==
                  'specific_customer_request'
              ? allocation.therapist.id
              : null,
          requestedGender: allocation.therapist.requestedGender,
        );
        if (result.success) {
          final editAllocation = widget.editPayload!.allocations.first;
          final bookedServiceIds =
              (editAllocation.bookedServiceIds.isEmpty
                      ? editAllocation.serviceIds
                      : editAllocation.bookedServiceIds)
                  .toSet();
          await _appointmentRepository.updateAppointment(
            widget.editPayload!.appointmentId!,
            {
              'customerId': _selectedCustomer!.id,
              'serviceId': allocation.primaryService.id,
              'serviceName': allocation.serviceNameSummary,
              'serviceItems': allocation.serviceItems
                  .map(
                    (item) => {
                      ...item,
                      if (_isCheckInMode || widget.editPayload!.hasPayment)
                        'lineType': bookedServiceIds.contains(item['id'])
                            ? 'booked'
                            : 'add_on',
                    },
                  )
                  .toList(),
              'itemCount': allocation.services.length,
              'totalPrice': allocation.price,
              'type': 'appointment',
            },
          );
        }
      } else if (allocations.length == 1) {
        final allocation = allocations.first;
        result = await CspService.createAppointment(
          customerId: _selectedCustomer!.id,
          therapistId: allocation.therapist.id,
          roomId: allocation.room.id,
          serviceId: allocation.primaryService.id,
          serviceName: allocation.serviceNameSummary,
          serviceItems: allocation.serviceItems,
          itemCount: allocation.services.length,
          date: dateStr,
          startTime: allocation.slot.start,
          endTime: allocation.endTime,
          totalPrice: allocation.price,
          type: 'appointment',
          assignmentSource: allocation.therapist.assignmentSource,
          requestedTherapistId:
              allocation.therapist.assignmentSource ==
                  'specific_customer_request'
              ? allocation.therapist.id
              : null,
          requestedGender: allocation.therapist.requestedGender,
        );
      } else {
        result = await CspService.createAppointmentGroup(
          customerId: _selectedCustomer!.id,
          groupName: _selectedCustomer!.name,
          paxCount: allocations.length,
          date: dateStr,
          allocations: allocations
              .asMap()
              .entries
              .map(
                (entry) => entry.value.toCspAllocation(
                  paxIndex: entry.key + 1,
                ),
              )
              .toList(),
          type: 'appointment',
        );
      }

      if (!result.success) {
        if (mounted) {
          AppToast.error(context, result.message, title: 'Could not book');
          await _generateSlots();
        }
        return;
      }

      if (mounted) {
        AppToast.success(
          context,
          _isEditing ? 'Appointment saved' : 'Appointment confirmed',
        );
        Navigator.pop(
          context,
          popResult ?? (_isCheckInMode ? 'checkInSaved' : true),
        );
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, friendlyErrorMessage(e));
      }
    } finally {
      if (mounted) setState(() => _isConfirming = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────

  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 900;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loadingData
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF1B6B72)),
            )
          : _isTablet(context)
          ? _buildTablet()
          : _buildPhone(),
    );
  }

  // ── TABLET BUILD ───────────────────────────────────────────────

  Widget _buildTablet() {
    return SafeArea(
      child: Column(
        children: [
          _TabletHeader(
            title: _isCheckInMode
                ? 'Check In Appointment'
                : _isEditing
                ? 'Edit Appointment'
                : 'New Appointment',
            onBack: () => Navigator.pop(context),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left — steps
                Expanded(
                  flex: 65,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        _StepCard(
                          number: 1,
                          title: _isCapacityMode
                              ? 'Customer & Pax'
                              : 'Date & Customer',
                          child: _buildDateCustomerSection(),
                        ),
                        const SizedBox(height: 16),
                        _StepCard(
                          number: 2,
                          title: _isCapacityMode
                              ? (_paxCount == 1
                                    ? 'Service Selection'
                                    : 'Services per Pax')
                              : 'Service Selection',
                          child: _buildServiceSection(),
                        ),
                        if (!_isCapacityMode) ...[
                          const SizedBox(height: 16),
                          _StepCard(
                            number: 3,
                            title: 'Therapist & Room',
                            child: _buildTherapistRoomSection(isTablet: true),
                          ),
                        ],
                        const SizedBox(height: 16),
                        _StepCard(
                          number: _isCapacityMode ? 3 : 4,
                          title: _isCapacityMode
                              ? 'Start Time'
                              : 'Available Time Slots',
                          child: _buildTimeSlotsSection(),
                        ),
                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
                ),
                // Right — summary
                Container(
                  width: MediaQuery.of(context).size.width * 0.35,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x0F000000),
                        blurRadius: 8,
                        offset: Offset(-2, 0),
                      ),
                    ],
                  ),
                  child: _buildSummaryPanel(isTablet: true),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── PHONE BUILD ────────────────────────────────────────────────

  Widget _buildPhone() {
    return SafeArea(
      child: Column(
        children: [
          _PhoneHeader(
            title: _isCheckInMode
                ? 'Check In Appointment'
                : _isEditing
                ? 'Edit Appointment'
                : 'New Appointment',
            onBack: () => Navigator.pop(context),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                children: [
                  _StepCard(
                    number: 1,
                    title: _isCapacityMode
                        ? 'Customer & Pax'
                        : 'Date & Customer',
                    child: _buildDateCustomerSection(),
                  ),
                  const SizedBox(height: 12),
                  _StepCard(
                    number: 2,
                    title: _isCapacityMode
                        ? (_paxCount == 1
                              ? 'Service Selection'
                              : 'Services per Pax')
                        : 'Service Selection',
                    child: _buildServiceSection(),
                  ),
                  if (!_isCapacityMode) ...[
                    const SizedBox(height: 12),
                    _StepCard(
                      number: 3,
                      title: 'Therapist & Room',
                      child: _buildTherapistRoomSection(isTablet: false),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _StepCard(
                    number: _isCapacityMode ? 3 : 4,
                    title: _isCapacityMode
                        ? 'Shared Start Time'
                        : 'Available Time Slots',
                    child: _buildTimeSlotsSection(),
                  ),
                  const SizedBox(height: 120),
                ],
              ),
            ),
          ),
          // Sticky bottom bar
          _PhoneBottomBar(
            serviceName: _isCapacityMode
                ? (_capacityServiceNameSummary.isEmpty
                      ? null
                      : _capacityServiceNameSummary)
                : (_checkoutAllocations.isEmpty
                      ? null
                      : _bookingServiceNameSummary),
            serviceDuration: _isCapacityMode
                ? _capacityTotalDuration
                : _bookingTotalDuration,
            servicePrice: _isCapacityMode
                ? _capacityTotalPrice
                : _bookingTotalPrice,
            isExpanded: _summaryExpanded,
            onToggle: () =>
                setState(() => _summaryExpanded = !_summaryExpanded),
            canConfirm: _canConfirm,
            isConfirming: _isConfirming,
            onConfirm: () => _confirmAppointment(),
            confirmLabel: _isCheckInMode
                ? 'Continue to Check In'
                : _isEditing
                ? 'Save Appointment'
                : 'Confirm Appointment',
            onSecondaryConfirm:
                _isEditing && !_isCheckInMode && _hasUnpaidAddOns
                ? _saveAndCollectAddOnPayment
                : null,
            selectedDate: _selectedDate,
            selectedCustomer: _selectedCustomer,
            selectedTherapist: _selectedTherapist,
            selectedRoom: _selectedRoom,
            selectedSlot: _selectedSlot,
            showResourceAssignment: !_isCapacityMode,
          ),
        ],
      ),
    );
  }

  // ── STEP SECTIONS ──────────────────────────────────────────────

  Widget _buildDateCustomerSection() {
    final formatted = DateFormat('EEE, d MMMM yyyy').format(_selectedDate);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Appointment Date',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Color(0xFF6B6B6B),
          ),
        ),
        const SizedBox(height: 8),
        // Date row
        Row(
          children: [
            _DateArrowBtn(
              icon: Icons.chevron_left,
              onTap: () => _onDateChanged(-1),
            ),
            Expanded(
              child: InkWell(
                onTap: _openDatePicker,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.calendar_today_outlined,
                        size: 16,
                        color: Color(0xFF1B6B72),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          formatted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1A1A2E),
                          ),
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
            ),
            _DateArrowBtn(
              icon: Icons.chevron_right,
              onTap: () => _onDateChanged(1),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // Customer search
        const Text(
          'Customer',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Color(0xFF6B6B6B),
          ),
        ),
        const SizedBox(height: 8),
        _CustomerSearchField(
          controller: _customerSearchController,
          customers: _filteredCustomers,
          selected: _selectedCustomer,
          onSelect: _selectCustomer,
          onClear: _clearCustomerSelection,
        ),
        const SizedBox(height: 12),
        const _CustomerOptionDivider(),
        const SizedBox(height: 12),
        _GuestPaxRow(
          isGuestSelected: _selectedCustomer?.isGuest ?? false,
          configuredCount: _isCapacityMode
              ? _capacityConfiguredPax
              : _checkoutAllocations.length,
          paxCount: _paxCount,
          onGuestTap: _selectGuestCustomer,
          onAddCustomer: _openAddCustomerDialog,
          onRemovePax: _paxCount <= 1 || _isCheckInMode || _locksPaxCount
              ? null
              : () => _setPaxCount(_paxCount - 1),
          onAddPax: _isCheckInMode || _locksPaxCount
              ? null
              : () => _setPaxCount(_paxCount + 1),
        ),
      ],
    );
  }

  Future<void> _saveAndCollectAddOnPayment() {
    return _confirmAppointment(popResult: 'collectAddOnPayment');
  }

  Widget _buildServiceSection() {
    final tabs = _serviceCategories;
    final filtered = _services.where((s) => s.category == _serviceTab).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_isCapacityMode) ...[
          const Text(
            'Choose a treatment for each person. The group shares one start, while duration and room capacity are checked separately.',
            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var index = 0; index < _paxCount; index++)
                ChoiceChip(
                  label: Text(
                    _capacityPaxServices[index].isEmpty
                        ? 'Pax ${index + 1}'
                        : 'Pax ${index + 1}  ✓',
                  ),
                  selected: index == _activePaxIndex,
                  onSelected: (_) => _selectPax(index),
                  selectedColor: const Color(0xFF1B6B72),
                  labelStyle: TextStyle(
                    color: index == _activePaxIndex
                        ? Colors.white
                        : const Color(0xFF1A1A2E),
                    fontWeight: FontWeight.w700,
                  ),
                  side: const BorderSide(color: Color(0xFFCBD5E1)),
                  showCheckmark: false,
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        // Tabs
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: tabs
                .map(
                  (tab) => GestureDetector(
                    onTap: () => setState(() => _serviceTab = tab),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 20, bottom: 12),
                      child: Column(
                        children: [
                          Text(
                            tab,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _serviceTab == tab
                                  ? const Color(0xFF1B6B72)
                                  : const Color(0xFF9E9E9E),
                            ),
                          ),
                          const SizedBox(height: 4),
                          if (_serviceTab == tab)
                            Container(
                              height: 2,
                              width: 40,
                              color: const Color(0xFF1B6B72),
                            ),
                        ],
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        if (filtered.isEmpty || _serviceLoadError != null) ...[
          _ServiceEmptyState(tab: _serviceTab, error: _serviceLoadError),
          const SizedBox(height: 12),
        ],
        // Service grid
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 600
                ? 3
                : constraints.maxWidth >= 430
                ? 2
                : 1;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: columns == 1 ? 4.2 : 2.6,
              ),
              itemCount: filtered.length,
              itemBuilder: (_, i) => _ServiceCard(
                service: filtered[i],
                isSelected: _selectedServices.any(
                  (service) => service.id == filtered[i].id,
                ),
                onTap: () => _onServiceSelected(filtered[i]),
              ),
            );
          },
        ),
        if (_selectedServices.isNotEmpty && !_hasCompatibleRoomType) ...[
          const SizedBox(height: 12),
          Text(
            _hasMixedRoomTypes
                ? 'This person has both body-room and foot-zone services. Split them into separate pax entries before choosing a time.'
                : 'One or more selected services has no room type. Configure its room requirement before choosing a time.',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFFB45309),
            ),
          ),
        ],
        if (_isCapacityMode) ...[
          const SizedBox(height: 20),
          _buildCapacityTherapistPreference(),
        ] else if (_isEditing && !_isCheckInMode) ...[
          const SizedBox(height: 20),
          _buildEditTherapistPreference(),
        ],
      ],
    );
  }

  Widget _buildCapacityTherapistPreference() {
    final preference = _capacityPaxPreferences[_activePaxIndex];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Therapist preference — Pax ${_activePaxIndex + 1}',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'The system assigns the best available therapist. Choose a gender only when the customer requests it.',
            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Auto assigned'),
                selected: preference.assignmentSource == 'queue',
                onSelected: (_) => _setCapacityPreference(
                  const _CapacityTherapistPreference(),
                ),
              ),
              ChoiceChip(
                label: const Text('Female'),
                selected: preference.assignmentSource == 'gender_preference' &&
                    preference.requestedGender?.toLowerCase() == 'female',
                onSelected: (_) => _setCapacityPreference(
                  const _CapacityTherapistPreference(
                    assignmentSource: 'gender_preference',
                    requestedGender: 'Female',
                  ),
                ),
              ),
              ChoiceChip(
                label: const Text('Male'),
                selected: preference.assignmentSource == 'gender_preference' &&
                    preference.requestedGender?.toLowerCase() == 'male',
                onSelected: (_) => _setCapacityPreference(
                  const _CapacityTherapistPreference(
                    assignmentSource: 'gender_preference',
                    requestedGender: 'Male',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEditTherapistPreference() {
    final source = _selectedTherapist?.assignmentSource ?? 'queue';
    final selectedId = _selectedTherapist?.id;

    void setSource(String nextSource, {String? gender}) {
      final current = _selectedTherapist;
      if (current == null) return;
      _onTherapistSelected(
        current.withAssignment(
          source: nextSource,
          requestedGender: gender,
          therapistAssignmentState: nextSource == 'specific_customer_request'
              ? 'confirmed'
              : 'pending',
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Therapist preference — Pax ${_activePaxIndex + 1}',
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: Color(0xFF1A1A2E),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('No preference'),
              selected: source == 'queue',
              onSelected: (_) => setSource('queue'),
            ),
            ChoiceChip(
              label: const Text('Gender preference'),
              selected: source == 'gender_preference',
              onSelected: (_) =>
                  setSource('gender_preference', gender: 'Female'),
            ),
            ChoiceChip(
              label: const Text('Request specific therapist'),
              selected: source == 'specific_customer_request',
              onSelected: (_) => setSource('specific_customer_request'),
            ),
          ],
        ),
        if (source == 'gender_preference') ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Female'),
                selected:
                    _selectedTherapist?.requestedGender?.toLowerCase() ==
                    'female',
                onSelected: (_) =>
                    setSource('gender_preference', gender: 'Female'),
              ),
              ChoiceChip(
                label: const Text('Male'),
                selected:
                    _selectedTherapist?.requestedGender?.toLowerCase() ==
                    'male',
                onSelected: (_) =>
                    setSource('gender_preference', gender: 'Male'),
              ),
            ],
          ),
        ],
        if (source == 'specific_customer_request') ...[
          const SizedBox(height: 12),
          ..._therapists.map(
            (therapist) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _TherapistCard(
                therapist: therapist,
                isSelected: selectedId == therapist.id,
                isReserved: _isTherapistReservedInBooking(therapist.id),
                isDisabled:
                    selectedId != therapist.id &&
                    _isTherapistReservedInBooking(therapist.id),
                onTap: () => _onTherapistSelected(
                  therapist.withAssignment(
                    source: 'specific_customer_request',
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTherapistRoomSection({required bool isTablet}) {
    final compatibleRooms = _rooms
        .where((r) => _requiredRoomType.isEmpty || r.type == _requiredRoomType)
        .toList();

    // Editing and check-in share the same live queue UI as walk-ins. Edits use
    // the appointment's scheduled start rather than the wall clock, while
    // check-in continues to follow live availability.
    final therapistSection = _isEditing && !_isCheckInMode
        ? const SizedBox.shrink()
        : _isCheckInMode
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TherapistQueuePicker(
                outletId: OutletContext.activeOutletId.value,
                date: DateFormat('yyyy-MM-dd').format(_selectedDate),
                startTime: _therapistQueueReferenceTime,
                durationMinutes: _serviceDuration,
                selectedTherapistId: _selectedTherapist?.id,
                initialRequestedGender: _selectedTherapist?.requestedGender,
                followLiveClock: _isCheckInMode,
                excludedTherapistIds: {
                  for (var i = 0; i < _paxAllocations.length; i++)
                    if (i != _activePaxIndex && _paxAllocations[i] != null)
                      _paxAllocations[i]!.therapist.id,
                },
                onSelected: _onQueueTherapistSelected,
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SubSectionLabel('Select Therapist'),
              const SizedBox(height: 10),
              if (isTablet)
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: 2.65,
                  ),
                  itemCount: _therapists.length,
                  itemBuilder: (_, i) {
                    final t = _therapists[i];
                    return _TherapistCard(
                      therapist: t,
                      isSelected: _selectedTherapist?.id == t.id,
                      isReserved: _isTherapistReservedInBooking(t.id),
                      isDisabled: false,
                      onTap: () => _onTherapistSelected(
                        t.withAssignment(
                          source: 'specific_customer_request',
                        ),
                      ),
                    );
                  },
                )
              else
                ..._therapists.map(
                  (t) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _TherapistCard(
                      therapist: t,
                      isSelected: _selectedTherapist?.id == t.id,
                      isReserved: _isTherapistReservedInBooking(t.id),
                      isDisabled: false,
                      onTap: () => _onTherapistSelected(
                        t.withAssignment(
                          source: 'specific_customer_request',
                        ),
                      ),
                    ),
                  ),
                ),
              if (_selectedTherapist?.therapistAssignmentState ==
                  'pending') ...[
                const SizedBox(height: 8),
                const Text(
                  'Capacity is protected. The live queue confirms the therapist near check-in.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
                ),
              ],
            ],
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        therapistSection,
        if (!(_isEditing && !_isCheckInMode))
          SizedBox(height: isTablet ? 18 : 16),
        const _SubSectionLabel('Select Room / Zone'),
        const SizedBox(height: 10),
        ...compatibleRooms.map(
          (r) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _RoomZoneCard(
              zone: r,
              isSelected: _selectedRoom?.id == r.id,
              onTap: () => _onRoomSelected(r),
            ),
          ),
        ),
        if (_selectedRoom?.usesSpecificRooms ?? false) ...[
          const SizedBox(height: 8),
          const _SubSectionLabel('Individual room availability'),
          const SizedBox(height: 6),
          if (_selectedSlot == null)
            const Text(
              'Choose a time to see individual room availability.',
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            )
          else if (_loadingRoomUnits)
            const Padding(
              padding: EdgeInsets.all(8),
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (_roomUnitAvailability.isEmpty)
            const Text(
              'No active individual rooms are available for this time.',
              style: TextStyle(fontSize: 12, color: Color(0xFFB42318)),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final unit in _roomUnitAvailability)
                  Chip(
                    label: Text(
                      unit.availableForRequestedTime
                          ? unit.name
                          : unit.availableAt == null
                          ? '${unit.name} · Busy'
                          : '${unit.name} · Until ${_bookingTimeLabel(unit.availableAt!)}',
                    ),
                    avatar: Icon(
                      unit.availableForRequestedTime
                          ? Icons.check_circle_outline_rounded
                          : Icons.schedule_rounded,
                      size: 17,
                      color: unit.availableForRequestedTime
                          ? const Color(0xFF0F766E)
                          : const Color(0xFF94A3B8),
                    ),
                    backgroundColor: unit.availableForRequestedTime
                        ? const Color(0xFFEAF8F5)
                        : const Color(0xFFF1F5F9),
                  ),
              ],
            ),
          const SizedBox(height: 4),
          const Text(
            'The system assigns an available individual room when service starts.',
            style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
          ),
        ],
      ],
    );
  }

  Widget _buildTimeSlotsSection() {
    if (_isCapacityMode) return _buildCapacityTimeSlotsSection();

    final missing = _missingSlotRequirements;
    if (missing.isNotEmpty) {
      return _LockedTimeSlotsPanel(missing: missing);
    }

    if (_loadingSlots) {
      return const _SlotsLoadingPanel();
    }

    final ranked =
        _slots.where((s) => s.isRecommended && s.isAvailable).toList()
          ..sort((left, right) {
            final byScore = right.score.compareTo(left.score);
            return byScore != 0 ? byScore : left.start.compareTo(right.start);
          });
    final recommended = ranked.take(3).toList();
    final recommendedStarts = recommended.map((slot) => slot.start).toSet();
    final standard = _slots
        .where((s) => s.isAvailable && !recommendedStarts.contains(s.start))
        .toList();
    final visibleStandard = _showAllStandardSlots
        ? standard
        : standard.take(12).toList();
    final unavailable = _slots.where((s) => !s.isAvailable).toList();

    if (_slots.isEmpty) {
      return const _NoTimeSlotsPanel();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Best Fit includes exact booking, cleanup, shift, and leave boundaries. Other times use a 10-minute staff grid.',
          style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
        ),
        if (_isEditing && _previousSlotReference != null) ...[
          const SizedBox(height: 12),
          _PreviousTimeReferenceCard(
            previousSlot: _previousSlotReference!,
            currentSlot: _selectedSlot,
            canSaveCurrent: _selectedSlotIsAvailable,
          ),
        ],
        const SizedBox(height: 14),

        if (_scheduleBlocks.isNotEmpty) ...[
          _ScheduleOverviewCard(
            blocks: _scheduleBlocks,
            selectedDate: _selectedDate,
          ),
          const SizedBox(height: 14),
        ],

        // Recommended
        if (recommended.isNotEmpty) ...[
          const Row(
            children: [
              Icon(Icons.schedule_outlined, size: 16, color: Color(0xFF1B6B72)),
              SizedBox(width: 7),
              Text(
                'Best Fit',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              Text(
                ' - ranked from nearby bookings',
                style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _SlotGrid(
            slots: recommended,
            selectedSlot: _selectedSlot,
            recommended: true,
            onSelect: _onSlotSelected,
          ),
          const SizedBox(height: 14),
        ],

        // Standard
        if (standard.isNotEmpty) ...[
          const Text(
            'Standard Availability',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Color(0xFF6B6B6B),
            ),
          ),
          const SizedBox(height: 10),
          _SlotGrid(
            slots: visibleStandard,
            selectedSlot: _selectedSlot,
            recommended: false,
            onSelect: _onSlotSelected,
          ),
          if (standard.length > visibleStandard.length)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _showAllStandardSlots = true),
                icon: const Icon(Icons.expand_more, size: 17),
                label: Text(
                  'Show ${standard.length - visibleStandard.length} more times',
                ),
              ),
            )
          else if (_showAllStandardSlots && standard.length > 12)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _showAllStandardSlots = false),
                icon: const Icon(Icons.expand_less, size: 17),
                label: const Text('Show fewer times'),
              ),
            ),
          const SizedBox(height: 14),
        ],

        if (unavailable.isNotEmpty) ...[
          const Text(
            'Unavailable times',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 10),
          ...unavailable.map(
            (slot) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _UnavailableCapacitySlot(slot: slot),
            ),
          ),
          const SizedBox(height: 6),
        ],

        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _loadingSlots ? null : _pickExactStartTime,
            icon: const Icon(Icons.edit_calendar_outlined, size: 17),
            label: const Text('Check exact time'),
          ),
        ),
        const SizedBox(height: 14),

        if (_scheduleBlocks.isNotEmpty)
          _BookedPeriodsPanel(
            blocks: _scheduleBlocks,
            excludedCandidateCount: unavailable.length,
          )
        else if (unavailable.isNotEmpty)
          Text(
            '${unavailable.length} conflicting candidate time${unavailable.length == 1 ? '' : 's'} excluded',
            style: const TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
          ),
      ],
    );
  }

  Widget _buildCapacityTimeSlotsSection() {
    final missing = _missingSlotRequirements;
    if (missing.isNotEmpty) {
      return _LockedTimeSlotsPanel(missing: missing);
    }
    if (_loadingSlots) return const _SlotsLoadingPanel();
    if (_capacitySlotLoadError != null) {
      return _CapacitySlotsErrorPanel(
        message: _capacitySlotLoadError!,
        onRetry: _generateCapacitySlots,
      );
    }
    if (_slots.isEmpty) return const _NoTimeSlotsPanel(capacityMode: true);

    final available = _slots.where((slot) => slot.isAvailable).toList();
    final unavailable = _slots.where((slot) => !slot.isAvailable).toList();
    final unavailableReasons = unavailable
        .map((slot) => slot.reasonLabel.trim())
        .where((reason) => reason.isNotEmpty && reason != 'Good schedule fit')
        .toSet();
    final allUnavailableMessage = unavailableReasons.length == 1
        ? unavailableReasons.first
        : 'No shared start has enough eligible therapist and room capacity for the complete service window.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (available.isEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7ED),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFED7AA)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 19,
                  color: Color(0xFFB45309),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    allUnavailableMessage,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF92400E),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        const Text(
          'The group shares one start. Availability checks each person’s service duration and required body room or foot zone separately.',
          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 14),
        if (available.isNotEmpty) const Row(
          children: [
            Icon(Icons.auto_awesome, size: 16, color: Color(0xFF1B6B72)),
            SizedBox(width: 7),
            Text(
              'Available times',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1A1A2E),
              ),
            ),
          ],
        ),
        if (available.isNotEmpty) const SizedBox(height: 10),
        if (available.isNotEmpty) _SlotGrid(
          slots: available,
          selectedSlot: _selectedSlot,
          recommended: true,
          startOnly: true,
          onSelect: (slot) => setState(() => _selectedSlot = slot),
        ),
        if (unavailable.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'Unavailable times',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B7280),
            ),
          ),
          const SizedBox(height: 10),
          if (available.isEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final slot in unavailable)
                  _UnavailableTimeChip(slot: slot),
              ],
            )
          else
            ...unavailable.map(
              (slot) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _UnavailableCapacitySlot(slot: slot),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildSummaryPanel({required bool isTablet}) {
    final dateStr = DateFormat('EEE, d MMMM yyyy').format(_selectedDate);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Booking Summary',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Review before confirming',
            style: TextStyle(fontSize: 13, color: Color(0xFF9E9E9E)),
          ),
          const SizedBox(height: 24),

          _SummaryRow(label: 'Date', value: dateStr),
          _SummaryRow(label: 'Customer', value: _selectedCustomer?.name ?? '—'),
          if (_isCapacityMode)
            _SummaryRow(
              label: 'Editing',
              value: _selectedServices.isEmpty
                  ? 'Pax ${_activePaxIndex + 1} — no service yet'
                  : 'Pax ${_activePaxIndex + 1}\n$_serviceNameSummary\n$_serviceDuration min — RM ${_servicePrice.toStringAsFixed(0)}',
            )
          else ...[
            _SummaryRow(
              label: 'Service',
              value: _selectedServices.isNotEmpty
                  ? '$_serviceNameSummary\n$_serviceDuration min - RM ${_servicePrice.toStringAsFixed(0)}'
                  : '—',
            ),
            _SummaryRow(
              label: 'Therapist',
              value: _selectedTherapist?.name ?? '—',
            ),
            _SummaryRow(
              label: 'Room / Zone',
              value: _selectedRoom?.name ?? '—',
            ),
          ],
          _SummaryRow(
            label: _isCapacityMode ? 'Shared start' : 'Time Slot',
            value: _selectedSlot == null
                ? '—'
                : _isCapacityMode
                ? _bookingTimeLabel(_selectedSlot!.start)
                : _selectedSlot!.label,
          ),

          if (_isCapacityMode) ...[
            const SizedBox(height: 8),
            Text(
              'Booking setup ($_capacityConfiguredPax/$_paxCount configured)',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 10),
            for (
              var index = 0;
              index < _capacitySelections.length;
              index++
            ) ...[
              _CapacityPaxSummaryCard(
                index: index + 1,
                selection: _capacitySelections[index],
                selected: index == _activePaxIndex,
                onTap: () => _selectPax(index),
                onClear: _capacityPaxServices[index].isEmpty
                    ? null
                    : () => _clearPax(index),
              ),
              const SizedBox(height: 8),
            ],
            const Divider(height: 28, color: Color(0xFFEEEEEE)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Estimated Total',
                  style: TextStyle(fontSize: 13, color: Color(0xFF9E9E9E)),
                ),
                Text(
                  'RM ${_capacityTotalPrice.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ],
            ),
          ] else if (_paxCount > 1 || _checkoutAllocations.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              'Booking setup (${_checkoutAllocations.length}/$_paxCount configured)',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < _allocationSlots.length; i++) ...[
              _BookingPaxSummaryCard(
                index: i + 1,
                allocation: _allocationSlots[i],
                selected: i == _activePaxIndex,
                onTap: () => _selectPax(i),
                onClear: _allocationSlots[i] == null
                    ? null
                    : () => _clearPax(i),
              ),
              const SizedBox(height: 8),
            ],
            if (_paxConflictMessage != null) ...[
              const SizedBox(height: 2),
              Text(
                _paxConflictMessage!,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFE53935),
                ),
              ),
              const SizedBox(height: 8),
            ],
            const Divider(height: 28, color: Color(0xFFEEEEEE)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Estimated Total',
                  style: TextStyle(fontSize: 13, color: Color(0xFF9E9E9E)),
                ),
                Text(
                  'RM ${_bookingTotalPrice.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '$_bookingServiceNameSummary - $_bookingTotalDuration min',
              style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
            ),
          ],

          const SizedBox(height: 28),

          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _canConfirm && !_isConfirming
                  ? () => _confirmAppointment()
                  : null,
              icon: _isConfirming
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.check, size: 18),
              label: Text(
                _isCheckInMode
                    ? 'Continue to Check In'
                    : _isEditing
                    ? 'Save Appointment'
                    : 'Confirm Appointment',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B6B72),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFBDBDBD),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
            ),
          ),

          if (_isEditing && !_isCheckInMode && _hasUnpaidAddOns) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: _canConfirm && !_isConfirming
                    ? _saveAndCollectAddOnPayment
                    : null,
                icon: const Icon(Icons.point_of_sale_outlined, size: 18),
                label: const Text(
                  'Save & Collect Add-on Payment',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF15803D),
                  side: const BorderSide(color: Color(0xFF15803D)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],

          if (!_canConfirm) ...[
            const SizedBox(height: 8),
            const Center(
              child: Text(
                'Complete all selections to confirm',
                style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// COMPONENT WIDGETS
// ─────────────────────────────────────────────────────────────────

class _TabletHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  const _TabletHeader({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          GestureDetector(
            onTap: onBack,
            child: const Icon(
              Icons.arrow_back_ios,
              size: 18,
              color: Color(0xFF1B6B72),
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A2E),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PhoneHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  const _PhoneHeader({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          GestureDetector(
            onTap: onBack,
            child: const Icon(
              Icons.arrow_back_ios,
              size: 18,
              color: Color(0xFF1B6B72),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickCustomerDialog<T> extends StatefulWidget {
  final String defaultJoinDate;
  final T Function(String id, Map<String, String> data) customerBuilder;

  const _QuickCustomerDialog({
    required this.defaultJoinDate,
    required this.customerBuilder,
  });

  @override
  State<_QuickCustomerDialog<T>> createState() =>
      _QuickCustomerDialogState<T>();
}

class _QuickCustomerDialogState<T> extends State<_QuickCustomerDialog<T>> {
  final _customerRepository = CustomerRepository();
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _genderController = TextEditingController();
  final _dobController = TextEditingController();
  final _notesController = TextEditingController();
  late final TextEditingController _joinDateController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _joinDateController = TextEditingController(text: widget.defaultJoinDate);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _genderController.dispose();
    _dobController.dispose();
    _joinDateController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _openFieldDatePicker(TextEditingController controller) async {
    final initialDate =
        DateTime.tryParse(controller.text.trim()) ?? DateTime.now();
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (context) =>
          _BookingMonthCalendarDialog(initialDate: initialDate),
    );
    if (picked == null) return;
    controller.text = DateFormat('yyyy-MM-dd').format(_stripDate(picked));
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    final dateOfBirth = _dobController.text.trim();
    final joinDate = _joinDateController.text.trim();
    final data = {
      'name': _nameController.text.trim(),
      'phone': _phoneController.text.trim(),
      'gender': _genderController.text.trim(),
      // date_of_birth/join_date are DATE columns — an empty string is not a
      // valid date and Postgres rejects it, so omit rather than send ''.
      if (dateOfBirth.isNotEmpty) 'dateOfBirth': dateOfBirth,
      if (joinDate.isNotEmpty) 'joinDate': joinDate,
      'notes': _notesController.text.trim(),
    };

    try {
      final savedRow = await _customerRepository.addCustomer(data);
      final customerId = savedRow['id']?.toString() ?? '';
      if (!mounted) return;
      Navigator.of(context).pop(widget.customerBuilder(customerId, data));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppToast.error(
        context,
        'Unable to save customer: ${friendlyErrorMessage(e)}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Add Customer',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _QuickCustomerField(
                  label: 'Name',
                  controller: _nameController,
                  requiredField: true,
                ),
                const SizedBox(height: 14),
                _QuickCustomerField(
                  label: 'Phone',
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  requiredField: true,
                ),
                const SizedBox(height: 14),
                _QuickGenderDropdown(
                  label: 'Gender',
                  controller: _genderController,
                ),
                const SizedBox(height: 14),
                _QuickCustomerField(
                  label: 'Date of Birth',
                  controller: _dobController,
                  hint: 'YYYY-MM-DD',
                  keyboardType: TextInputType.datetime,
                  onCalendarTap: () => _openFieldDatePicker(_dobController),
                ),
                const SizedBox(height: 14),
                _QuickCustomerField(
                  label: 'Join Date',
                  controller: _joinDateController,
                  hint: 'YYYY-MM-DD',
                  keyboardType: TextInputType.datetime,
                  onCalendarTap: () =>
                      _openFieldDatePicker(_joinDateController),
                ),
                const SizedBox(height: 14),
                _QuickCustomerField(
                  label: 'Notes',
                  controller: _notesController,
                  maxLines: 3,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).pop(),
                        style: TextButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          backgroundColor: const Color(0xFFF1F3F6),
                          foregroundColor: const Color(0xFF1A1A2E),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _saving ? null : _save,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          backgroundColor: const Color(0xFF1B6B72),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('Add Customer'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickCustomerField extends StatelessWidget {
  final String label;
  final String? hint;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final bool requiredField;
  final int maxLines;
  final VoidCallback? onCalendarTap;

  const _QuickCustomerField({
    required this.label,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.requiredField = false,
    this.maxLines = 1,
    this.onCalendarTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      validator: requiredField
          ? (value) => value == null || value.trim().isEmpty
                ? '$label is required'
                : null
          : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: onCalendarTap == null
            ? null
            : IconButton(
                onPressed: onCalendarTap,
                tooltip: 'Pick date',
                icon: const Icon(
                  Icons.calendar_today_outlined,
                  size: 18,
                  color: Color(0xFF1B6B72),
                ),
              ),
        filled: true,
        fillColor: const Color(0xFFF7F8FA),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF1B6B72), width: 1.4),
        ),
      ),
    );
  }
}

class _QuickGenderDropdown extends StatelessWidget {
  final String label;
  final TextEditingController controller;

  const _QuickGenderDropdown({required this.label, required this.controller});

  String? get _value {
    final normalized = controller.text.trim().toLowerCase();
    if (normalized.startsWith('f')) return 'Female';
    if (normalized.startsWith('m')) return 'Male';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: _value,
      items: const [
        DropdownMenuItem(value: 'Female', child: Text('Female')),
        DropdownMenuItem(value: 'Male', child: Text('Male')),
      ],
      onChanged: (value) => controller.text = value ?? '',
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: const Color(0xFFF7F8FA),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF1B6B72), width: 1.4),
        ),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final int number;
  final String title;
  final Widget child;

  const _StepCard({
    required this.number,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF1B6B72),
                ),
                child: Center(
                  child: Text(
                    '$number',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _PaxStepperButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _PaxStepperButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? Colors.white : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Icon(
          icon,
          size: 16,
          color: enabled ? const Color(0xFF1B6B72) : const Color(0xFFCBD5E1),
        ),
      ),
    );
  }
}

class _SubSectionLabel extends StatelessWidget {
  final String text;
  const _SubSectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Color(0xFF6B6B6B),
      ),
    );
  }
}

class _BookingMonthCalendarDialog extends StatefulWidget {
  final DateTime initialDate;

  const _BookingMonthCalendarDialog({required this.initialDate});

  @override
  State<_BookingMonthCalendarDialog> createState() =>
      _BookingMonthCalendarDialogState();
}

class _BookingMonthCalendarDialogState
    extends State<_BookingMonthCalendarDialog> {
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
                  _BookingWeekdayLabel('SUN'),
                  _BookingWeekdayLabel('MON'),
                  _BookingWeekdayLabel('TUE'),
                  _BookingWeekdayLabel('WED'),
                  _BookingWeekdayLabel('THU'),
                  _BookingWeekdayLabel('FRI'),
                  _BookingWeekdayLabel('SAT'),
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

                  return InkWell(
                    onTap: () => Navigator.pop(context, cleanDay),
                    borderRadius: BorderRadius.circular(18),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected
                            ? const Color(0xFF1B6B72)
                            : Colors.transparent,
                        border: isToday && !isSelected
                            ? Border.all(color: const Color(0xFF1B6B72))
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
                      foregroundColor: const Color(0xFF1B6B72),
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

class _BookingWeekdayLabel extends StatelessWidget {
  final String label;

  const _BookingWeekdayLabel(this.label);

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

class _DateArrowBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _DateArrowBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Container(
        width: 38,
        height: 38,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(10),
        ),
          child: Icon(icon, size: 18, color: const Color(0xFF1B6B72)),
        ),
      ),
    );
  }
}

class _CustomerOptionDivider extends StatelessWidget {
  const _CustomerOptionDivider();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: Divider(color: Color(0xFFEEEEEE))),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'or',
            style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
          ),
        ),
        Expanded(child: Divider(color: Color(0xFFEEEEEE))),
      ],
    );
  }
}

class _GuestPaxRow extends StatelessWidget {
  const _GuestPaxRow({
    required this.isGuestSelected,
    required this.configuredCount,
    required this.paxCount,
    required this.onGuestTap,
    required this.onAddCustomer,
    required this.onRemovePax,
    required this.onAddPax,
  });

  final bool isGuestSelected;
  final int configuredCount;
  final int paxCount;
  final VoidCallback onGuestTap;
  final VoidCallback onAddCustomer;
  final VoidCallback? onRemovePax;
  final VoidCallback? onAddPax;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 540;
        final sectionPadding = EdgeInsets.all(compact ? 12 : 16);

        final guestSection = Container(
          color: isGuestSelected
              ? const Color(0xFF1B6B72).withValues(alpha: 0.045)
              : Colors.transparent,
          padding: sectionPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onGuestTap,
                  borderRadius: BorderRadius.circular(10),
                  splashFactory: NoSplash.splashFactory,
                  splashColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Container(
                          width: compact ? 38 : 44,
                          height: compact ? 38 : 44,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE8F5F5),
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: const Icon(
                            Icons.person_outline,
                            size: 21,
                            color: Color(0xFF1B6B72),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Guest',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF1A1A2E),
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'No customer profile needed',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: Color(0xFF7C8798),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (isGuestSelected) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.check_circle,
                            color: Color(0xFF1B6B72),
                            size: 20,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );

        final paxIdentity = Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: compact ? 38 : 44,
              height: compact ? 38 : 44,
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5F5),
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(
                Icons.groups_2_outlined,
                size: 21,
                color: Color(0xFF1B6B72),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Pax',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$configuredCount configured',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );

        final paxControls = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PaxStepperButton(icon: Icons.remove, onTap: onRemovePax),
            SizedBox(
              width: compact ? 36 : 44,
              child: Text(
                '$paxCount',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1A1A2E),
                ),
              ),
            ),
            _PaxStepperButton(icon: Icons.add, onTap: onAddPax),
          ],
        );

        final paxSection = Padding(
          padding: sectionPadding,
          child: compact
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    paxIdentity,
                    const SizedBox(height: 12),
                    Align(alignment: Alignment.centerRight, child: paxControls),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: paxIdentity),
                    const SizedBox(width: 12),
                    paxControls,
                  ],
                ),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isGuestSelected
                      ? const Color(0xFF1B6B72).withValues(alpha: 0.55)
                      : const Color(0xFFE2E8F0),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.035),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: compact ? 11 : 10, child: guestSection),
                    Container(width: 1, color: const Color(0xFFE2E8F0)),
                    Expanded(flex: compact ? 9 : 10, child: paxSection),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            InkWell(
              onTap: onAddCustomer,
              borderRadius: BorderRadius.circular(6),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2, vertical: 7),
                child: Text(
                  '+ Add New Customer',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF1B6B72),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CustomerSearchField extends StatelessWidget {
  final TextEditingController controller;
  final List<_Customer> customers;
  final _Customer? selected;
  final Function(_Customer) onSelect;
  final VoidCallback onClear;

  const _CustomerSearchField({
    required this.controller,
    required this.customers,
    required this.selected,
    required this.onSelect,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: controller,
          style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A2E)),
          decoration: InputDecoration(
            hintText: 'Search by phone or name...',
            hintStyle: const TextStyle(color: Color(0xFFBDBDBD), fontSize: 14),
            prefixIcon: const Icon(
              Icons.search,
              color: Color(0xFF9E9E9E),
              size: 18,
            ),
            suffixIcon: controller.text.isNotEmpty || selected != null
                ? GestureDetector(
                    onTap: onClear,
                    child: const Icon(
                      Icons.close,
                      color: Color(0xFF9E9E9E),
                      size: 16,
                    ),
                  )
                : null,
            filled: true,
            fillColor: const Color(0xFFF5F5F5),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(
                color: Color(0xFF1B6B72),
                width: 1.5,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
          ),
        ),
        // Dropdown suggestions
        if (controller.text.isNotEmpty &&
            selected == null &&
            customers.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              children: customers
                  .take(5)
                  .map(
                    (c) => ListTile(
                      dense: true,
                      title: Text(
                        c.phone.isEmpty ? 'No phone number' : c.phone,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        c.name,
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () => onSelect(c),
                    ),
                  )
                  .toList(),
            ),
          ),
      ],
    );
  }
}

class _ServiceEmptyState extends StatelessWidget {
  final String tab;
  final String? error;

  const _ServiceEmptyState({required this.tab, required this.error});

  @override
  Widget build(BuildContext context) {
    final hasError = error != null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: hasError ? const Color(0xFFFFF1F2) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: hasError ? const Color(0xFFFECACA) : const Color(0xFFE5E7EB),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            hasError ? Icons.error_outline : Icons.inventory_2_outlined,
            color: hasError ? const Color(0xFFE53935) : const Color(0xFF6B7280),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              hasError
                  ? 'Unable to load services right now.'
                  : 'No $tab available right now.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: hasError
                    ? const Color(0xFFB91C1C)
                    : const Color(0xFF4B5563),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final _Service service;
  final bool isSelected;
  final VoidCallback onTap;

  const _ServiceCard({
    required this.service,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFE8F5F5) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF1B6B72)
                : const Color(0xFFEEEEEE),
            width: isSelected ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _ServiceImage(imageUrl: service.imageUrl, size: 44),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        service.name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1A1A2E),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _SmallBadge(
                            label: '${service.duration}m',
                            bg: const Color(0xFFE8F5F5),
                            color: const Color(0xFF1B6B72),
                          ),
                          _SmallBadge(
                            label: 'RM ${service.price.toStringAsFixed(0)}',
                            bg: const Color(0xFFF5F5F5),
                            color: const Color(0xFF6B6B6B),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (isSelected)
              const Positioned(
                top: 0,
                right: 0,
                child: Icon(
                  Icons.check_circle,
                  size: 18,
                  color: Color(0xFF1B6B72),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ServiceImage extends StatelessWidget {
  final String imageUrl;
  final double size;

  const _ServiceImage({required this.imageUrl, this.size = 38});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: size,
        height: size,
        color: const Color(0xFFE8F5F5),
        child: imageUrl.isEmpty
            ? const Icon(Icons.spa_outlined, color: Color(0xFF1B6B72), size: 26)
            : Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, error, stackTrace) => const Icon(
                  Icons.spa_outlined,
                  color: Color(0xFF1B6B72),
                  size: 26,
                ),
              ),
      ),
    );
  }
}

class _TherapistPhoto extends StatelessWidget {
  final _Therapist therapist;
  final double size;
  final bool isDisabled;

  const _TherapistPhoto({
    required this.therapist,
    required this.size,
    required this.isDisabled,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDisabled ? const Color(0xFFE5E7EB) : therapist.photoBg;
    final fg = isDisabled ? const Color(0xFF9CA3AF) : therapist.photoColor;

    return ClipOval(
      child: Container(
        width: size,
        height: size,
        color: bg,
        child: therapist.imageUrl.isEmpty
            ? Icon(therapist.photoIcon, color: fg, size: size * 0.5)
            : Image.network(
                therapist.imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, error, stackTrace) =>
                    Icon(therapist.photoIcon, color: fg, size: size * 0.5),
              ),
      ),
    );
  }
}

class _TherapistCard extends StatelessWidget {
  final _Therapist therapist;
  final bool isSelected;
  final bool isReserved;
  final bool isDisabled;
  final VoidCallback? onTap;

  const _TherapistCard({
    required this.therapist,
    required this.isSelected,
    required this.isReserved,
    required this.isDisabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width >= 900;

    return GestureDetector(
      onTap: isDisabled ? null : onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: isDisabled ? 0.4 : 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFFE8F5F5) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF1B6B72)
                  : const Color(0xFFEEEEEE),
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              _TherapistPhoto(
                therapist: therapist,
                size: isTablet ? 46 : 52,
                isDisabled: isDisabled,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      therapist.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1A2E),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 7),
                    Builder(
                      builder: (context) {
                        final tone = isReserved
                            ? 'reserved'
                            : therapist.statusTone;
                        final background = tone == 'free'
                            ? const Color(0xFFE8F5E9)
                            : tone == 'reserved'
                            ? const Color(0xFFE6F4F5)
                            : tone == 'busy'
                            ? const Color(0xFFFFF7ED)
                            : const Color(0xFFF3F4F6);
                        final dot = tone == 'free'
                            ? const Color(0xFF4CAF50)
                            : tone == 'reserved'
                            ? const Color(0xFF1B6B72)
                            : tone == 'busy'
                            ? const Color(0xFFF59E0B)
                            : const Color(0xFF9CA3AF);
                        final foreground = tone == 'free'
                            ? const Color(0xFF2E7D32)
                            : tone == 'reserved'
                            ? const Color(0xFF155E63)
                            : tone == 'busy'
                            ? const Color(0xFFC2410C)
                            : const Color(0xFF6B7280);
                        final label = isReserved
                            ? 'Reserved'
                            : therapist.statusLabel.isNotEmpty
                            ? therapist.statusLabel
                            : therapist.isFree
                            ? 'Free'
                            : therapist.busyUntil.isNotEmpty
                            ? 'Busy until ${therapist.busyUntil}'
                            : 'Busy';
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: background,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: dot,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: foreground,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              if (isSelected)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.check_circle,
                    size: 18,
                    color: Color(0xFF1B6B72),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoomZoneCard extends StatelessWidget {
  final _RoomZone zone;
  final bool isSelected;
  final VoidCallback onTap;

  const _RoomZoneCard({
    required this.zone,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFE8F5F5) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF1B6B72)
                : const Color(0xFFEEEEEE),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            _RoomImage(imageUrl: zone.imageUrl, roomType: zone.type),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    zone.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF4CAF50),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '${zone.freeSlots} of ${zone.totalSlots} free',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF4CAF50),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
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

class _RoomImage extends StatelessWidget {
  final String imageUrl;
  final String roomType;

  const _RoomImage({required this.imageUrl, required this.roomType});

  IconData get _fallbackIcon => roomType == 'foot_chair'
      ? Icons.chair_outlined
      : Icons.meeting_room_outlined;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 38,
        height: 38,
        color: const Color(0xFFEDE7F6),
        child: imageUrl.isEmpty
            ? Icon(_fallbackIcon, color: const Color(0xFF7C3AED), size: 22)
            : Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, error, stackTrace) => Icon(
                  _fallbackIcon,
                  color: const Color(0xFF7C3AED),
                  size: 22,
                ),
              ),
      ),
    );
  }
}

class _LockedTimeSlotsPanel extends StatelessWidget {
  final List<String> missing;

  const _LockedTimeSlotsPanel({required this.missing});

  bool _isMissing(String key) => missing.contains(key);

  @override
  Widget build(BuildContext context) {
    final capacityMode = missing.any(
      (item) => item.contains('every pax') || item.contains('per pax'),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5F5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.lock_clock_outlined,
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
                      capacityMode
                          ? 'Shared starts will appear here'
                          : 'Time slots will appear here',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      capacityMode
                          ? 'Finish every service choice first. A shared start can only be checked when each person has one compatible room type.'
                          : 'Select the required booking details first. Availability is calculated only after the service, therapist, and room are selected.',
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: capacityMode
                ? [
                    const _RequirementChip(
                      label: 'Date selected',
                      complete: true,
                    ),
                    _RequirementChip(
                      label: 'Every service selected',
                      complete: !_isMissing('services for every pax'),
                    ),
                    _RequirementChip(
                      label: 'Room type compatible',
                      complete: !_isMissing('one compatible room type per pax'),
                    ),
                  ]
                : [
                    const _RequirementChip(
                      label: 'Date selected',
                      complete: true,
                    ),
                    _RequirementChip(
                      label: 'Service',
                      complete: !_isMissing('service'),
                    ),
                    _RequirementChip(
                      label: 'Therapist',
                      complete: !_isMissing('therapist'),
                    ),
                    _RequirementChip(
                      label: 'Room',
                      complete: !_isMissing('room'),
                    ),
                  ],
          ),
          const SizedBox(height: 14),
          const Row(
            children: [
              Expanded(child: _DisabledSlotPreview()),
              SizedBox(width: 8),
              Expanded(child: _DisabledSlotPreview()),
            ],
          ),
        ],
      ),
    );
  }
}

class _RequirementChip extends StatelessWidget {
  final String label;
  final bool complete;

  const _RequirementChip({required this.label, required this.complete});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: complete ? const Color(0xFFE8F5F5) : Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: complete ? const Color(0xFFB8E0DE) : const Color(0xFFE5E7EB),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            complete ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 14,
            color: complete ? const Color(0xFF1B6B72) : const Color(0xFF9CA3AF),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: complete
                  ? const Color(0xFF1B6B72)
                  : const Color(0xFF6B7280),
            ),
          ),
        ],
      ),
    );
  }
}

class _DisabledSlotPreview extends StatelessWidget {
  const _DisabledSlotPreview();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: const Color(0xFFE5E7EB).withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      alignment: Alignment.center,
      child: const Text(
        '--:--',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFF9CA3AF),
        ),
      ),
    );
  }
}

class _SlotsLoadingPanel extends StatelessWidget {
  const _SlotsLoadingPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: const Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: Color(0xFF1B6B72),
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Checking therapist and room availability...',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A2E),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoTimeSlotsPanel extends StatelessWidget {
  const _NoTimeSlotsPanel({this.capacityMode = false});

  final bool capacityMode;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.event_busy_outlined,
            color: Color(0xFFB45309),
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              capacityMode
                  ? 'No start time is available. Try another date.'
                  : 'No available slots for this combination. Try another date, therapist, or room.',
              style: const TextStyle(
                fontSize: 13,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: Color(0xFF92400E),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CapacitySlotsErrorPanel extends StatelessWidget {
  const _CapacitySlotsErrorPanel({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFB91C1C), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Capacity could not be checked',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF991B1B),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: Color(0xFFB91C1C),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _PreviousTimeReferenceCard extends StatelessWidget {
  final _TimeSlot previousSlot;
  final _TimeSlot? currentSlot;
  final bool canSaveCurrent;

  const _PreviousTimeReferenceCard({
    required this.previousSlot,
    required this.currentSlot,
    required this.canSaveCurrent,
  });

  @override
  Widget build(BuildContext context) {
    final current = currentSlot;
    final hasChanged =
        current != null &&
        (current.start != previousSlot.start ||
            current.end != previousSlot.end);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFDE68A)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(
              Icons.history_outlined,
              color: Color(0xFFD97706),
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Previous selected time',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF92400E),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasChanged
                      ? '${previousSlot.label} -> ${current.label}'
                      : previousSlot.label,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF1A1A2E),
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (!canSaveCurrent) ...[
                  const SizedBox(height: 2),
                  const Text(
                    'Pick an available CSP slot below before saving.',
                    style: TextStyle(
                      fontSize: 11,
                      color: Color(0xFFB45309),
                      fontWeight: FontWeight.w700,
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

class _ScheduleOverviewCard extends StatelessWidget {
  const _ScheduleOverviewCard({
    required this.blocks,
    required this.selectedDate,
  });

  final List<CspScheduleBlock> blocks;
  final DateTime selectedDate;

  @override
  Widget build(BuildContext context) {
    final positions = _schedulePositions(blocks);
    if (positions.isEmpty) return const SizedBox.shrink();
    final now = DateTime.now();
    final isToday = _stripDate(now) == _stripDate(selectedDate);
    final referenceMinutes = isToday ? now.hour * 60 + now.minute : -1;
    final upcoming = positions
        .where((position) => position.blockedUntil > referenceMinutes)
        .toList();
    final next = upcoming.isEmpty ? null : upcoming.first;
    final last = positions.reduce(
      (left, right) => left.blockedUntil >= right.blockedUntil ? left : right,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1B6B72).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF1B6B72).withValues(alpha: 0.28),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.view_timeline_outlined,
                size: 17,
                color: Color(0xFF1B6B72),
              ),
              SizedBox(width: 7),
              Text(
                'Selected therapist schedule',
                style: TextStyle(
                  color: Color(0xFF1B6B72),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          LayoutBuilder(
            builder: (context, constraints) {
              final nextInfo = _ScheduleFact(
                label: 'Next blocked period',
                value: next == null
                    ? 'No more today'
                    : '${_scheduleRangeLabel(next)} · ${next.block.label}',
              );
              final lastInfo = _ScheduleFact(
                label: 'Schedule clears after',
                value: _scheduleMinuteLabel(last.blockedUntil),
              );
              if (constraints.maxWidth < 500) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [nextInfo, const SizedBox(height: 10), lastInfo],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 2, child: nextInfo),
                  const SizedBox(width: 18),
                  Expanded(child: lastInfo),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ScheduleFact extends StatelessWidget {
  const _ScheduleFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 10.5, color: Color(0xFF6B7280)),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF1A1A2E),
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _BookedPeriodsPanel extends StatelessWidget {
  const _BookedPeriodsPanel({
    required this.blocks,
    required this.excludedCandidateCount,
  });

  final List<CspScheduleBlock> blocks;
  final int excludedCandidateCount;

  @override
  Widget build(BuildContext context) {
    final positions = _schedulePositions(blocks);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          leading: const Icon(
            Icons.event_busy_outlined,
            size: 20,
            color: Color(0xFF6B7280),
          ),
          title: const Text(
            'Booked & unavailable periods',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
          ),
          subtitle: Text(
            excludedCandidateCount == 0
                ? 'View the selected therapist timeline'
                : '$excludedCandidateCount conflicting candidate time${excludedCandidateCount == 1 ? '' : 's'} excluded',
            style: const TextStyle(fontSize: 10.5),
          ),
          children: [
            ...positions.map(
              (position) => Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _scheduleBlockIcon(position.block.kind),
                      size: 17,
                      color: const Color(0xFF6B7280),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _scheduleRangeLabel(position),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1A1A2E),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            position.block.label,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF6B7280),
                            ),
                          ),
                          if (position.blockedUntil > position.end) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Cleanup until ${_scheduleMinuteLabel(position.blockedUntil)}',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: Color(0xFFB45309),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Suggestions also exclude periods when the selected room is full, active payment holds, working-hour breaks, and leave.',
                style: TextStyle(fontSize: 10.5, color: Color(0xFF9E9E9E)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScheduleBlockPosition {
  const _ScheduleBlockPosition({
    required this.block,
    required this.start,
    required this.end,
    required this.blockedUntil,
  });

  final CspScheduleBlock block;
  final int start;
  final int end;
  final int blockedUntil;
}

List<_ScheduleBlockPosition> _schedulePositions(List<CspScheduleBlock> blocks) {
  final positions = <_ScheduleBlockPosition>[];
  var previousStart = -1;
  for (final block in blocks) {
    var start = _bookingTimeToMinutes(block.startTime);
    while (start < previousStart) {
      start += 24 * 60;
    }
    var end = _bookingTimeToMinutes(block.endTime);
    while (end <= start) {
      end += 24 * 60;
    }
    var blockedUntil = _bookingTimeToMinutes(block.blockedUntil);
    while (blockedUntil < end) {
      blockedUntil += 24 * 60;
    }
    positions.add(
      _ScheduleBlockPosition(
        block: block,
        start: start,
        end: end,
        blockedUntil: blockedUntil,
      ),
    );
    previousStart = start;
  }
  return positions;
}

String _scheduleRangeLabel(_ScheduleBlockPosition position) =>
    '${_scheduleMinuteLabel(position.start)} - ${_scheduleMinuteLabel(position.end)}';

String _scheduleMinuteLabel(int minutes) {
  final label = _bookingTimeLabel(_bookingMinutesToTime(minutes));
  return minutes >= 24 * 60 ? '$label next day' : label;
}

IconData _scheduleBlockIcon(String kind) => switch (kind) {
  'hold' => Icons.hourglass_top_outlined,
  'leave' => Icons.person_off_outlined,
  _ => Icons.event_outlined,
};

class _SlotGrid extends StatelessWidget {
  final List<_TimeSlot> slots;
  final _TimeSlot? selectedSlot;
  final bool recommended;
  final bool startOnly;
  final ValueChanged<_TimeSlot> onSelect;

  const _SlotGrid({
    required this.slots,
    required this.selectedSlot,
    required this.recommended,
    this.startOnly = false,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900
            ? 3
            : constraints.maxWidth >= 520
            ? 2
            : 1;
        const spacing = 14.0;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: 10,
          children: slots.map((slot) {
            final isSelected = selectedSlot?.start == slot.start;
            return SizedBox(
              width: itemWidth,
              child: recommended
                  ? _SlotTile(
                      slot: slot,
                      isSelected: isSelected,
                      startOnly: startOnly,
                      onTap: () => onSelect(slot),
                    )
                  : _SlotChip(
                      slot: slot,
                      isSelected: isSelected,
                      startOnly: startOnly,
                      onTap: () => onSelect(slot),
                    ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _UnavailableTimeChip extends StatelessWidget {
  const _UnavailableTimeChip({required this.slot});

  final _TimeSlot slot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.block_outlined,
            size: 15,
            color: Color(0xFF94A3B8),
          ),
          const SizedBox(width: 6),
          Text(
            _bookingTimeLabel(slot.start),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: Color(0xFF64748B),
            ),
          ),
        ],
      ),
    );
  }
}

class _UnavailableCapacitySlot extends StatelessWidget {
  const _UnavailableCapacitySlot({required this.slot});

  final _TimeSlot slot;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.block_outlined,
            size: 18,
            color: Color(0xFF94A3B8),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _bookingTimeLabel(slot.start),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF475569),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  slot.reasonLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: Color(0xFF64748B),
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

class _SlotTile extends StatelessWidget {
  final _TimeSlot slot;
  final bool isSelected;
  final bool startOnly;
  final VoidCallback onTap;

  const _SlotTile({
    required this.slot,
    required this.isSelected,
    this.startOnly = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF1B6B72)
              : const Color(0xFF1B6B72).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFF1B6B72),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              startOnly ? _bookingTimeLabel(slot.start) : slot.label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: isSelected ? Colors.white : const Color(0xFF1B6B72),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              slot.reasonLabel,
              style: TextStyle(
                fontSize: 11,
                color: isSelected
                    ? Colors.white.withValues(alpha: 0.85)
                    : const Color(0xFF1B6B72),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlotChip extends StatelessWidget {
  final _TimeSlot slot;
  final bool isSelected;
  final bool startOnly;
  final VoidCallback onTap;

  const _SlotChip({
    required this.slot,
    required this.isSelected,
    this.startOnly = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF1B6B72) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF1B6B72)
                : const Color(0xFFDDDDDD),
          ),
        ),
        child: Text(
          startOnly ? _bookingTimeLabel(slot.start) : slot.label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: isSelected ? Colors.white : const Color(0xFF1A1A2E),
          ),
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label, value;
  const _SummaryRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF9E9E9E),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const Divider(height: 16, color: Color(0xFFF0F0F0)),
        ],
      ),
    );
  }
}

class _SmallBadge extends StatelessWidget {
  final String label;
  final Color bg, color;
  const _SmallBadge({
    required this.label,
    required this.bg,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }
}

class _BookingPaxSummaryCard extends StatelessWidget {
  final int index;
  final _BookingAllocation? allocation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const _BookingPaxSummaryCard({
    required this.index,
    required this.allocation,
    required this.selected,
    required this.onTap,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final item = allocation;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE8F5F5) : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? const Color(0xFF1B6B72) : const Color(0xFFE2E8F0),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5F5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$index',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1B6B72),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item?.serviceNameSummary ?? 'Pax $index',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item == null
                        ? 'Tap to configure service, therapist, room, and time'
                        : '${item.therapist.name} - ${item.room.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item == null
                        ? (selected ? 'Editing' : 'Not configured')
                        : '${item.slot.start} - ${item.endTime} - RM ${item.price.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1B6B72),
                    ),
                  ),
                ],
              ),
            ),
            if (onClear != null)
              IconButton(
                onPressed: onClear,
                icon: const Icon(Icons.close, size: 18),
                color: const Color(0xFFE53935),
                tooltip: 'Clear pax',
              ),
          ],
        ),
      ),
    );
  }
}

// ── Phone Bottom Bar ──────────────────────────────────────────────

class _CapacityPaxSummaryCard extends StatelessWidget {
  const _CapacityPaxSummaryCard({
    required this.index,
    required this.selection,
    required this.selected,
    required this.onTap,
    required this.onClear,
  });

  final int index;
  final _CapacityPaxSelection selection;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final roomLabel = switch (selection.requiredRoomType) {
      'body_room' => 'Body room',
      'foot_chair' => 'Foot zone',
      _ => selection.hasMixedRoomTypes ? 'Mixed room types' : 'Room required',
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE8F5F5) : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? const Color(0xFF1B6B72) : const Color(0xFFE2E8F0),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5F5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$index',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1B6B72),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selection.services.isEmpty
                        ? 'Pax $index'
                        : selection.serviceNameSummary,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    selection.services.isEmpty
                        ? (selected
                              ? 'Choose this pax’s service'
                              : 'Not configured')
                        : '${selection.duration} min · $roomLabel · RM ${selection.price.toStringAsFixed(2)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selection.hasMixedRoomTypes
                          ? const Color(0xFFB45309)
                          : const Color(0xFF64748B),
                    ),
                  ),
                  if (selection.services.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      'Therapist: ${selection.preference.label}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: selection.preference.isComplete
                            ? const Color(0xFF0F766E)
                            : const Color(0xFFB45309),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onClear != null)
              IconButton(
                onPressed: onClear,
                icon: const Icon(Icons.close, size: 18),
                color: const Color(0xFFE53935),
                tooltip: 'Clear pax',
              ),
          ],
        ),
      ),
    );
  }
}

class _PhoneBottomBar extends StatelessWidget {
  final String? serviceName;
  final int serviceDuration;
  final double servicePrice;
  final bool isExpanded;
  final VoidCallback onToggle;
  final bool canConfirm;
  final bool isConfirming;
  final VoidCallback onConfirm;
  final String confirmLabel;
  final VoidCallback? onSecondaryConfirm;
  final DateTime selectedDate;
  final _Customer? selectedCustomer;
  final _Therapist? selectedTherapist;
  final _RoomZone? selectedRoom;
  final _TimeSlot? selectedSlot;
  final bool showResourceAssignment;

  const _PhoneBottomBar({
    required this.serviceName,
    required this.serviceDuration,
    required this.servicePrice,
    required this.isExpanded,
    required this.onToggle,
    required this.canConfirm,
    required this.isConfirming,
    required this.onConfirm,
    required this.confirmLabel,
    this.onSecondaryConfirm,
    required this.selectedDate,
    required this.selectedCustomer,
    required this.selectedTherapist,
    required this.selectedRoom,
    required this.selectedSlot,
    this.showResourceAssignment = true,
  });

  @override
  Widget build(BuildContext context) {
    final dateStr = DateFormat('EEE, d MMM yyyy').format(selectedDate);
    final hasServices = serviceName?.trim().isNotEmpty == true;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Expanded summary
          if (isExpanded)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: const Color(0xFFF8F8F8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Booking Summary',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _MiniRow('Date', dateStr),
                  _MiniRow('Customer', selectedCustomer?.name ?? '—'),
                  _MiniRow(
                    'Service',
                    hasServices ? '$serviceName - $serviceDuration min' : '—',
                  ),
                  if (showResourceAssignment) ...[
                    _MiniRow('Therapist', selectedTherapist?.name ?? '—'),
                    _MiniRow('Zone', selectedRoom?.name ?? '—'),
                  ],
                  _MiniRow(
                    showResourceAssignment ? 'Time' : 'Shared start',
                    selectedSlot == null
                        ? '—'
                        : showResourceAssignment
                        ? selectedSlot!.label
                        : _bookingTimeLabel(selectedSlot!.start),
                  ),
                  if (hasServices) ...[
                    const Divider(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'SST (6%)',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF9E9E9E),
                          ),
                        ),
                        Text(
                          'RM ${(servicePrice * 0.06).toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF9E9E9E),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Total',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                        Text(
                          'RM ${(servicePrice * 1.06).toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1B6B72),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          // Bottom action row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              children: [
                // Summary toggle row
                GestureDetector(
                  onTap: onToggle,
                  child: Row(
                    children: [
                      Icon(
                        isExpanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_up,
                        size: 18,
                        color: const Color(0xFF1B6B72),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          hasServices
                              ? '$serviceName - $serviceDuration min'
                              : 'Select a service',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                      ),
                      Text(
                        hasServices
                            ? 'RM ${servicePrice.toStringAsFixed(2)}'
                            : '',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1B6B72),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: canConfirm && !isConfirming ? onConfirm : null,
                    icon: isConfirming
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.check, size: 16),
                    label: Text(
                      confirmLabel,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1B6B72),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFFBDBDBD),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                  ),
                ),
                if (onSecondaryConfirm != null) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: OutlinedButton.icon(
                      onPressed: canConfirm && !isConfirming
                          ? onSecondaryConfirm
                          : null,
                      icon: const Icon(Icons.point_of_sale_outlined, size: 16),
                      label: const Text(
                        'Save & Collect Add-on Payment',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF15803D),
                        side: const BorderSide(color: Color(0xFF15803D)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
                if (!canConfirm) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Complete all selections to confirm',
                    style: TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
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

class _MiniRow extends StatelessWidget {
  final String label, value;
  const _MiniRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Color(0xFF1A1A2E),
            ),
          ),
        ],
      ),
    );
  }
}
