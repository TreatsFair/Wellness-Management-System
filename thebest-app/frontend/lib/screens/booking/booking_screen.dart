import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/outlets/outlet_context.dart';
import '../../core/services/csp_service.dart';
import '../../core/utils/error_message.dart';
import '../../data/repositories/appointment_repository.dart';
import '../../data/repositories/business_settings_repository.dart';
import '../../data/repositories/customer_repository.dart';
import '../../data/repositories/room_repository.dart';
import '../../data/repositories/service_repository.dart';
import '../../data/repositories/therapist_repository.dart';
import '../../data/services/supabase_table_service.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/checkout_guest_card.dart';
import '../../widgets/room_unit_grid.dart';
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

String _bookingDisplayTimeFromMinutes(int minutes) {
  final normalized = minutes % (24 * 60);
  return DateFormat('h:mm a').format(
    DateTime(2000, 1, 1, normalized ~/ 60, normalized % 60),
  );
}

String _bookingLineTypeLabel(String category) {
  final normalized = category.trim().toLowerCase();
  if (normalized.contains('add')) return 'Add-on';
  if (normalized.contains('package')) return 'Package';
  return 'Main Service';
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

Map<String, double> _bookingCommissionMap(Object? value) {
  if (value is! Map) return {};
  return {
    for (final entry in value.entries)
      entry.key.toString(): _Service._parseDouble(entry.value),
  };
}

class _Therapist {
  final String id, name, gender, imageUrl;
  final bool isFree;
  final String busyUntil;
  final Map<String, double> serviceCommissions;

  /// Availability summary for the booking's selected date (not "right now"):
  /// e.g. 'Available', 'On leave', 'Off today', 'Reserved 2:30 PM–3:30 PM',
  /// 'Busy 2:00 PM–3:00 PM'. Reservations are always reported as an
  /// explicit from–to window, because a therapist who is booked later is still
  /// bookable for a non-overlapping service now. [statusTone] drives the badge
  /// color: 'free' (green), 'reserved' (teal), 'busy' (amber), 'off' (gray).
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
    this.serviceCommissions = const {},
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
      serviceCommissions: serviceCommissions,
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
        return 'Shared start with available staff and room';
      case 'capacity_best_fit':
        // Best Fit candidates are generated from the edges of real bookings —
        // they slot in without leaving an unusable gap behind.
        return 'Slots in against a nearby booking without leaving a gap';
      case 'capacity_earliest':
        return 'Earliest start with available staff and room';
      case 'late_start_now':
        return 'Start now';
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

  /// Staff's explicit numbered-room choice, only ever set from View
  /// Appointment. Null means the assign_appointment_room_unit trigger picks.
  final RoomUnitAvailability? roomUnit;

  /// A multi-pax booking picks its service, therapist and room per person and
  /// then one shared start for everyone. Until that start is chosen the pax is
  /// resource-complete but carries [pendingSlot], and must be excluded from
  /// any time-based comparison.
  bool get hasRealSlot => slot.start.isNotEmpty;

  static const pendingSlot = _TimeSlot(
    start: '',
    end: '',
    isRecommended: false,
    isAvailable: false,
  );

  const _BookingAllocation({
    this.appointmentId = '',
    required this.services,
    required this.therapist,
    required this.room,
    required this.slot,
    this.roomUnit,
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

  /// Re-stamps this pax onto the booking's shared start, keeping its own
  /// duration.
  _BookingAllocation withSharedStart(String start) {
    return _BookingAllocation(
      appointmentId: appointmentId,
      services: services,
      therapist: therapist,
      room: room,
      roomUnit: roomUnit,
      slot: _TimeSlot(
        start: start,
        end: _bookingMinutesToTime(_bookingTimeToMinutes(start) + duration),
        isRecommended: slot.isRecommended,
        isAvailable: true,
      ),
    );
  }

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
      'room_unit_id': roomUnit?.id,
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
      'room_assignment_state': 'confirmed',
    };
  }
}

class _CapacityTherapistPreference {
  const _CapacityTherapistPreference({
    this.assignmentSource = 'queue',
    this.requestedGender,
    this.requestedTherapistId,
    this.requestedTherapistName,
  });

  final String assignmentSource;
  final String? requestedGender;
  final String? requestedTherapistId;
  final String? requestedTherapistName;

  bool get isComplete {
    if (assignmentSource == 'gender_preference') {
      return requestedGender != null;
    }
    if (assignmentSource == 'specific_customer_request' ||
        assignmentSource == 'manual_override') {
      return requestedTherapistId?.trim().isNotEmpty == true;
    }
    return true;
  }

  String get label => switch (assignmentSource) {
    'gender_preference' => requestedGender ?? 'Gender preference',
    'specific_customer_request' =>
      requestedTherapistName ?? 'Specific therapist',
    'manual_override' => requestedTherapistName ?? 'Manual selection',
    _ => 'No preference',
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
      requestedTherapistId: preference.requestedTherapistId,
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

  /// The numbered room currently locked on this appointment, if any. Lets
  /// View Appointment show which room is held before staff change it.
  final String roomUnitId;
  final String roomUnitName;
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
    this.roomUnitId = '',
    this.roomUnitName = '',
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
  final bool isNoShow;

  /// Whether the booking can still be taken to checkout — i.e. it hasn't been
  /// cancelled, no-showed or already completed. View Appointment offers Save
  /// Appointment always, and Checkout only when this is true.
  final bool canCheckout;

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
    this.isNoShow = false,
    this.canCheckout = true,
  });

  bool get isGroup => appointmentGroupId?.trim().isNotEmpty == true;
}

// ── Main Screen ───────────────────────────────────────────────────

class NewAppointmentScreen extends StatefulWidget {
  final String userRole;
  final AppointmentEditPayload? editPayload;

  /// Opens the checkout page directly on top of this screen after an in-place
  /// save. Supplied by the appointment list, which owns the checkout sheet and
  /// the appointment data it needs. When null, Checkout falls back to popping
  /// with a 'checkout' result and letting the caller reopen it.
  final Future<void> Function()? onRequestCheckout;

  const NewAppointmentScreen({
    super.key,
    required this.userRole,
    this.editPayload,
    this.onRequestCheckout,
  });

  @override
  State<NewAppointmentScreen> createState() => _NewAppointmentScreenState();
}

class _NewAppointmentScreenState extends State<NewAppointmentScreen> {
  final _customerRepository = CustomerRepository();
  final _appointmentRepository = AppointmentRepository();
  final _businessSettingsRepository = BusinessSettingsRepository();
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
  /// Therapist preference chip state for the concrete-assignment interface.
  /// This is the counter's *intent*; `_selectedTherapist` is the therapist the
  /// intent resolved to. They are tracked separately because an automatic
  /// preference has to re-run the live queue rather than retag whoever happens
  /// to be selected.
  String _assignmentSource = 'queue';
  String? _requestedGender;
  int _assignmentRequestSerial = 0;
  bool _autoAssignInFlight = false;
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
  RoomUnitAvailability? _selectedRoomUnit;
  bool _loadingRoomUnits = false;
  List<_TimeSlot> _slots = [];
  List<CspScheduleBlock> _scheduleBlocks = [];
  List<_Customer> _customers = [];
  List<_Customer> _filteredCustomers = [];
  bool _loadingData = true;
  String? _serviceLoadError;
  BusinessRuleSettings _businessSettings = BusinessRuleSettings.defaults();

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
        _loadBusinessSettings(),
      ]);
      _applyEditPayloadIfNeeded();
    } finally {
      setState(() => _loadingData = false);
    }
  }

  Future<void> _loadBusinessSettings() async {
    try {
      final settings = await _businessSettingsRepository.getActiveSettings();
      if (mounted) _businessSettings = settings;
    } catch (_) {
      // The summary can safely use the documented defaults when settings
      // cannot be loaded; checkout remains database-authoritative.
    }
  }

  /// New appointments use anonymous capacity until confirmation, when the
  /// database atomically locks a therapist and exact room for every pax.
  /// Existing appointments retain the manual edit controls.
  final bool _capacityFirstUiEnabled = true;

  bool get _isEditing => widget.editPayload != null;
  bool get _isNoShowEdit => widget.editPayload?.isNoShow == true;
  bool get _isCapacityMode =>
      _capacityFirstUiEnabled && widget.editPayload == null;

  /// The shared concrete-assignment interface: therapist preference chips plus
  /// an explicit therapist lock. Used by both new and edit; check-in keeps the
  /// live queue picker because it follows the wall clock.
  bool get _usesConcreteAssignmentUi => !_isCapacityMode && !_isCheckInMode;
  bool get _isCheckInMode => widget.editPayload?.checkInMode == true;
  bool get _locksPaxCount => widget.editPayload?.hasPayment == true;

  /// Checkout is offered on View Appointment for any live booking. Cancelled,
  /// no-showed and completed bookings can still be opened and saved, but have
  /// nothing left to check out.
  bool get _canOfferCheckout =>
      _isEditing &&
      !_isCheckInMode &&
      widget.editPayload!.canCheckout;

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
          roomUnit: editAllocation.roomUnitId.trim().isEmpty
              ? null
              : RoomUnitAvailability(
                  id: editAllocation.roomUnitId,
                  name: editAllocation.roomUnitName.trim().isEmpty
                      ? 'Room'
                      : editAllocation.roomUnitName,
                  status: 'available',
                  availableForRequestedTime: true,
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
    if (_isLateArrival && _hasCurrentAllocation) {
      final startNow = _projectedStartNowSlot;
      setState(() {
        _selectedSlot = startNow;
        for (var i = 0; i < _paxAllocations.length; i++) {
          final stored = _paxAllocations[i];
          if (stored == null) continue;
          _paxAllocations[i] = stored.withSharedStart(startNow.start);
        }
      });
      // Only a still-pending assignment gets re-resolved. A late arrival whose
      // therapist is already locked in must NOT be re-auctioned just because
      // the counter opened View Appointment: nobody is free "right now" while
      // the floor is busy, so the queue walk would drop the confirmed
      // therapist, blank the slot and leave the booking unsaveable.
      final assignmentPending =
          _selectedTherapist == null ||
          _selectedTherapist!.therapistAssignmentState != 'confirmed';
      if (assignmentPending &&
          (_assignmentSource == 'queue' ||
              _assignmentSource == 'gender_preference')) {
        unawaited(
          _autoAssignFromQueue(
            source: _assignmentSource,
            gender: _requestedGender,
            preserveSlot: true,
          ),
        );
      } else {
        _generateSlots();
      }
    } else if (_hasCurrentAllocation) {
      _generateSlots();
    }
    // The booking already has a time, so show that slot's numbered-room
    // availability straight away instead of making staff re-pick the time.
    unawaited(_loadRoomUnitAvailability());
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
        //
        // A therapist is only "not free" while a reservation is actually
        // covering the wall clock. An earlier version marked anyone with a
        // started appointment busy for the rest of the day, which blocked
        // non-overlapping short walk-ins that fit before or after the booked
        // window. Every reservation is now reported as an explicit from–to
        // range so the counter can see the gap; the real overlap decision
        // still happens server-side in the CSP check.
        if (isToday) {
          final appointments = await _appointmentRepository
              .getActiveAppointmentsForTherapist(therapistId, dateKey);
          Map<String, dynamic>? nextBlock;
          var nextStart = 24 * 60 + 1;
          var nextEnd = 0;
          var nextHasStarted = false;
          for (final appointment in appointments) {
            final start = _bookingTimeToMinutes(
              appointment['startTime']?.toString() ?? '00:00',
            );
            final end =
                _bookingTimeToMinutes(
                  appointment['endTime']?.toString() ?? '00:00',
                ) +
                _parseInt(appointment['bufferAfterMinutes'], fallback: 0);
            if (end <= nowMinutes) continue;
            final coversNow = start <= nowMinutes;
            // Prefer whatever is running now; otherwise the soonest upcoming
            // reservation within the next hour.
            final isCandidate = coversNow || start <= nowMinutes + 60;
            if (!isCandidate) continue;
            if (nextBlock != null && !(coversNow && !nextHasStarted)) {
              if (start >= nextStart) continue;
            }
            nextBlock = appointment;
            nextStart = start;
            nextEnd = end;
            nextHasStarted =
                coversNow && appointment['actualStartedAt'] != null;
          }
          if (nextBlock != null) {
            final range =
                '${_bookingTimeLabel(_bookingMinutesToTime(nextStart))}–'
                '${_bookingTimeLabel(_bookingMinutesToTime(nextEnd))}';
            busyUntil = _bookingMinutesToTime(nextEnd);
            if (nextStart <= nowMinutes) {
              // Currently covered: not free right now, but still bookable
              // outside this window.
              isFree = false;
              statusLabel = nextHasStarted
                  ? 'Busy $range'
                  : 'Reserved $range';
              statusTone = 'busy';
            } else {
              statusLabel = 'Reserved $range';
              statusTone = 'reserved';
            }
          }
        }
        if (statusLabel.isNotEmpty) {
          // Keep the explicit reservation window wording above.
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
          serviceCommissions: _bookingCommissionMap(
            row['serviceCommissions'],
          ),
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
      barrierColor: Theme.of(context).scaffoldBackgroundColor,
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
                capacitySlots[index].isBestFit,
            isAvailable: capacitySlots[index].isAvailable,
            reason: !capacitySlots[index].isAvailable
                ? ''
                : capacitySlots[index].isEarliest
                ? 'capacity_earliest'
                : capacitySlots[index].isBestFit
                ? 'capacity_best_fit'
                : 'capacity_first_available',
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
    if (_usesConcreteAssignmentUi) {
      await _generateConcretePreferenceSlots();
      return;
    }

    final requestSerial = ++_slotRequestSerial;
    final requestPaxIndex = _activePaxIndex;
    final requestedStart = _selectedSlot?.start;
    final requestedIsLateStartNow =
        _selectedSlot?.reason == 'late_start_now';
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
          (_isOriginalEditStart(requestPaxIndex, requestedStart) ||
              requestedIsLateStartNow)) {
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
            isRecommended: requestedIsLateStartNow,
            isAvailable: true,
            reason: requestedIsLateStartNow
                ? 'late_start_now'
                : 'confirmed_booking',
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
      if (requestedStart != null &&
          matchingSlot == null &&
          !requestedIsLateStartNow) {
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
    // An automatic preference has to be re-resolved whenever the service set
    // changes: eligibility and the required window both moved. An add-on on an
    // existing appointment is the exception — its therapist is already locked
    // in, and the longer window is validated against that same therapist by
    // _generateSlots instead.
    if (!isRemoving &&
        !_therapistLockedToThisAppointment &&
        _usesConcreteAssignmentUi &&
        (_assignmentSource == 'queue' ||
            _assignmentSource == 'gender_preference')) {
      unawaited(
        _autoAssignFromQueue(
          source: _assignmentSource,
          gender: _requestedGender,
        ),
      );
    }
  }

  /// This appointment already owns its therapist: they are held FOR it, so any
  /// re-run of the queue would find them "busy" with this very booking and
  /// report nobody eligible. Reassignment is a deliberate act through the
  /// therapist picker, never a side effect of editing the time or services.
  bool get _therapistLockedToThisAppointment =>
      _activeEditAppointmentId != null &&
      _selectedTherapist?.therapistAssignmentState == 'confirmed';

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

  /// Swaps in a replacement therapist while KEEPING the time the counter
  /// already chose. Unlike [_onTherapistSelected] this does not blank the slot:
  /// the whole point of the clash recovery is "same time, different person", so
  /// the chosen start is re-validated against the replacement instead.
  Future<void> _switchTherapistKeepingSlot(TherapistAssignmentPick pick) async {
    final matches = _therapists.where(
      (therapist) => therapist.id == pick.therapistId,
    );
    if (matches.isEmpty) return;
    setState(() {
      // An explicit replacement is a counter decision, even when the picker was
      // opened from a queue-assigned booking.
      _assignmentSource = 'manual_override';
      _requestedGender = null;
      _selectedTherapist = matches.first.withAssignment(
        source: 'manual_override',
        therapistAssignmentState: 'confirmed',
      );
      _paxAllocations[_activePaxIndex] = null;
    });
    await _generateSlots();
  }

  /// Whether a refused save was refused because of the therapist specifically.
  /// Keyed on the RPC's error_code rather than its prose, which varies across
  /// the create / update / group / reactivate paths.
  bool _isTherapistClash(CspCreateResult result) {
    const therapistCodes = {
      'THERAPIST_UNAVAILABLE',
      'THERAPIST_BUSY',
      'INVALID_THERAPIST',
      'OUTSIDE_WORKING_HOURS',
    };
    if (therapistCodes.contains(result.errorCode?.toUpperCase())) return true;
    final message = result.message.toLowerCase();
    return message.contains('staff is booked until') ||
        message.contains('therapist is unavailable');
  }

  /// Offers the swap-therapist route out of a save that the database refused
  /// because the assigned therapist is taken at the requested time.
  Future<void> _handleTherapistClash(String message) async {
    final action = await showDialog<_BookingClashAction>(
      context: context,
      builder: (_) => _TherapistClashDialog(
        therapistName: _selectedTherapist?.name ?? 'The assigned therapist',
        windowLabel: _selectedSlot == null
            ? 'the requested time'
            : '${_bookingTimeLabel(_selectedSlot!.start)} – '
                  '${_bookingTimeLabel(_selectedSlot!.end)}',
        detail: message,
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _BookingClashAction.switchTherapist:
        final slot = _selectedSlot;
        final pick = await showDialog<TherapistAssignmentPick>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Choose another therapist'),
            content: SizedBox(
              width: 520,
              height: 520,
              child: SingleChildScrollView(
                child: TherapistQueuePicker(
                  outletId: OutletContext.activeOutletId.value,
                  date: DateFormat('yyyy-MM-dd').format(_selectedDate),
                  // Availability is judged at the booked start, not "now" —
                  // this is a scheduled appointment, not a walk-in.
                  startTime: slot?.start ??
                      DateFormat('HH:mm:ss').format(DateTime.now()),
                  durationMinutes: _serviceDuration +
                      _serviceBufferAfterMinutes,
                  eligibleTherapistIds: _serviceEligibleTherapistIds,
                  selectedTherapistId: _selectedTherapist?.id,
                  excludedTherapistIds: {
                    for (var i = 0; i < _paxAllocations.length; i++)
                      if (i != _activePaxIndex && _paxAllocations[i] != null)
                        _paxAllocations[i]!.therapist.id,
                  },
                  followLiveClock: false,
                  allowFutureReservation: true,
                  onSelected: (pick) => Navigator.pop(dialogContext, pick),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
        if (!mounted || pick == null) return;
        await _switchTherapistKeepingSlot(pick);
        if (!mounted) return;
        AppToast.info(
          context,
          _selectedSlot == null
              ? '${pick.therapistName} is not free then either — choose another time.'
              : 'Switched to ${pick.therapistName}. Save to confirm.',
        );
      case _BookingClashAction.pickAnotherTime:
      case _BookingClashAction.dismiss:
      case null:
        break;
    }
  }

  /// Builds one pax's capacity requirement for `get_counter_capacity_slots`.
  ///
  /// `manual_override` is deliberately sent as `specific_customer_request`:
  /// the availability RPC only accepts queue / gender_preference /
  /// specific_customer_request (migration 122r), and a manual selection is
  /// availability-identical to a named request — a concrete, already-chosen
  /// therapist. The appointment row still stores `manual_override`; only this
  /// read-only probe is translated.
  CounterCapacityRequirement _capacityRequirementFor({
    required int paxIndex,
    required _BookingAllocation allocation,
    required String roomType,
  }) {
    final source = allocation.therapist.assignmentSource;
    final isConcrete =
        source == 'specific_customer_request' || source == 'manual_override';
    return CounterCapacityRequirement(
      paxIndex: paxIndex,
      serviceIds: allocation.services.map((service) => service.id).toList(),
      durationMinutes: allocation.duration,
      bufferAfterMinutes: allocation.services.fold<int>(
        0,
        (buffer, service) =>
            service.bufferAfterMinutes > buffer
            ? service.bufferAfterMinutes
            : buffer,
      ),
      roomType: roomType,
      assignmentSource: isConcrete ? 'specific_customer_request' : source,
      requestedGender: source == 'gender_preference'
          ? allocation.therapist.requestedGender
          : null,
      requestedTherapistId: isConcrete ? allocation.therapist.id : null,
    );
  }

  /// Best Fit slot ranking for the shared concrete interface. Used by both
  /// New Appointment and View Appointment so a new booking gets the same
  /// capacity-ranked "Best Fit" list an edit does, instead of the plain
  /// 10-minute grid.
  Future<void> _generateConcretePreferenceSlots() async {
    if (_selectedTherapist == null || _selectedRoom == null) return;
    // A shared start needs every pax's resources first.
    if (!_allPaxResourcesReady) return;
    final payload = widget.editPayload;
    final requestSerial = ++_slotRequestSerial;
    final requestedStart = _selectedSlot?.start;
    final requestedIsLateStartNow = _selectedSlot?.reason == 'late_start_now';
    setState(() => _loadingSlots = true);
    try {
      final requirements = <CounterCapacityRequirement>[];
      for (var index = 0; index < _paxCount; index++) {
        final _BookingAllocation? allocation;
        if (index == _activePaxIndex) {
          final fallbackSlot = payload != null && index < payload.allocations.length
              ? _TimeSlot(
                  start: payload.allocations[index].startTime,
                  end: payload.allocations[index].endTime,
                  isRecommended: false,
                  isAvailable: true,
                )
              : null;
          final slot = _selectedSlot ?? fallbackSlot;
          // A brand-new pax has no slot yet — that's exactly what this call is
          // being asked to find, so probe with the service duration from
          // "now" and let the RPC rank the real openings.
          allocation = _BookingAllocation(
            appointmentId: _activeEditAppointmentId ?? '',
            services: List<_Service>.from(_selectedServices),
            therapist: _selectedTherapist!,
            room: _selectedRoom!,
            slot:
                slot ??
                _TimeSlot(
                  start: DateFormat('HH:mm:ss').format(DateTime.now()),
                  end: DateFormat('HH:mm:ss').format(DateTime.now()),
                  isRecommended: false,
                  isAvailable: true,
                ),
          );
        } else {
          allocation = index < _paxAllocations.length
              ? _paxAllocations[index]
              : null;
        }
        if (allocation == null) return;
        final roomTypes = allocation.services
            .map((service) => service.roomType)
            .where((type) => type.isNotEmpty)
            .toSet();
        if (roomTypes.length != 1) return;
        requirements.add(
          _capacityRequirementFor(
            paxIndex: index + 1,
            allocation: allocation,
            roomType: roomTypes.first,
          ),
        );
      }
      final capacitySlots = await CspService.getCounterCapacitySlots(
        outletId: OutletContext.activeOutletId.value,
        date: DateFormat('yyyy-MM-dd').format(_selectedDate),
        requirements: requirements,
        excludeGroupId: payload?.appointmentGroupId,
        excludeId: payload != null && payload.isGroup
            ? null
            : _activeEditAppointmentId,
      );
      if (!mounted || requestSerial != _slotRequestSerial) return;
      final slots = [
        for (var index = 0; index < capacitySlots.length; index++)
          _TimeSlot(
            start: capacitySlots[index].startTime,
            end: capacitySlots[index].endTime,
            isRecommended:
                capacitySlots[index].isAvailable &&
                capacitySlots[index].isBestFit,
            isAvailable: capacitySlots[index].isAvailable,
            reason: !capacitySlots[index].isAvailable
                ? ''
                : capacitySlots[index].isEarliest
                ? 'capacity_earliest'
                : capacitySlots[index].isBestFit
                ? 'capacity_best_fit'
                : 'capacity_first_available',
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
      var selected = matching.isEmpty ? null : matching.first;
      // A late arrival starting now is an auto-extension of a booking that
      // already owns its therapist and room, not a bid for free capacity. The
      // capacity grid never offers "now" as a candidate, so the projected start
      // has to be validated against the locked resources directly — excluding
      // this appointment, which would otherwise block itself.
      if (selected == null &&
          requestedStart != null &&
          (requestedIsLateStartNow ||
              _isOriginalEditStart(_activePaxIndex, requestedStart))) {
        final duration = _serviceDuration;
        final reservedEnd = _bookingMinutesToTime(
          _bookingTimeToMinutes(requestedStart) +
              duration +
              _serviceBufferAfterMinutes,
        );
        final validation = await CspService.validateSlot(
          date: DateFormat('yyyy-MM-dd').format(_selectedDate),
          startTime: requestedStart,
          endTime: reservedEnd,
          therapistId: _selectedTherapist!.id,
          roomId: _selectedRoom!.id,
          excludeId: _activeEditAppointmentId,
        );
        if (!mounted || requestSerial != _slotRequestSerial) return;
        if (validation.therapistAvailable && !validation.roomFull) {
          selected = _TimeSlot(
            start: requestedStart,
            end: _bookingMinutesToTime(
              _bookingTimeToMinutes(requestedStart) + duration,
            ),
            isRecommended: true,
            isAvailable: true,
            reason: requestedIsLateStartNow
                ? 'late_start_now'
                : 'confirmed_booking',
          );
          slots.insert(0, selected);
        }
      }
      setState(() {
        _slots = slots;
        _selectedSlot = selected;
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

  /// Resolves an automatic therapist preference against the live queue and
  /// locks the winner onto the active pax.
  ///
  /// MVP concrete locking: queue order is the recommendation order, so this
  /// walks the queue and takes the first therapist that is free for the whole
  /// service + cleanup window, can perform the selected services, matches the
  /// requested gender when one is asked for, and isn't already used by another
  /// pax in this booking. Reading the queue never rotates it — only an actual
  /// service start does.
  ///
  /// [preserveSlot] is used after the counter picks a time: the queue is
  /// re-read against that start so the locked therapist is the one who is
  /// actually free then, without discarding the chosen slot.
  Future<void> _autoAssignFromQueue({
    required String source,
    String? gender,
    bool preserveSlot = false,
  }) async {
    if (_isCheckInMode) return;
    if (_selectedServices.isEmpty || _therapists.isEmpty) return;

    final requestSerial = ++_assignmentRequestSerial;
    setState(() => _autoAssignInFlight = true);
    List<TherapistQueueEntry> entries;
    try {
      entries = await CspService.getTherapistQueue(
        outletId: OutletContext.activeOutletId.value,
        date: DateFormat('yyyy-MM-dd').format(_selectedDate),
        nowTime: _therapistQueueReferenceTime,
        duration: _serviceDuration + _serviceBufferAfterMinutes,
      );
    } catch (_) {
      if (mounted && requestSerial == _assignmentRequestSerial) {
        setState(() => _autoAssignInFlight = false);
      }
      return;
    }
    if (!mounted || requestSerial != _assignmentRequestSerial) return;
    // NOTE: _autoAssignInFlight deliberately stays true through the candidate
    // loop below. Clearing it here made every probed therapist render as the
    // committed pick, so staff watched the name flip through the whole queue
    // one round-trip at a time. Only the settled result should be shown.

    final wantedGender = gender?.trim().toLowerCase();
    final eligibleIds = _serviceEligibleTherapistIds;
    final usedByOtherPax = {
      for (var i = 0; i < _paxAllocations.length; i++)
        if (i != _activePaxIndex && _paxAllocations[i] != null)
          _paxAllocations[i]!.therapist.id,
    };

    for (final entry in entries) {
      if (!entry.isFreeNow) continue;
      if (!eligibleIds.contains(entry.therapistId)) continue;
      if (usedByOtherPax.contains(entry.therapistId)) continue;
      if (wantedGender != null && !_genderMatches(entry.gender, wantedGender)) {
        continue;
      }
      final match = _therapists.where((t) => t.id == entry.therapistId);
      if (match.isEmpty) continue;
      final locked = match.first.withAssignment(
        source: source,
        requestedGender: source == 'gender_preference' ? gender : null,
        therapistAssignmentState: 'confirmed',
      );
      if (preserveSlot) {
        if (_selectedTherapist?.id != locked.id) {
          setState(() => _selectedTherapist = locked);
        }
        await _generateSlots();
        if (!mounted || requestSerial != _assignmentRequestSerial) return;
        if (_selectedSlot == null) continue;
        setState(() => _autoAssignInFlight = false);
      } else {
        setState(() => _autoAssignInFlight = false);
        _onTherapistSelected(locked);
      }
      return;
    }

    // Nothing eligible: leave the pax unassigned rather than locking someone
    // who fails a real constraint. Confirm stays disabled until it resolves.
    setState(() {
      _autoAssignInFlight = false;
      _selectedTherapist = null;
      _selectedSlot = null;
      _slots = [];
      _scheduleBlocks = [];
      _paxAllocations[_activePaxIndex] = null;
    });
    if (mounted) {
      AppToast.info(
        context,
        wantedGender == null
            ? 'No eligible therapist is free for this service window.'
            : 'No eligible $gender therapist is free for this service window.',
      );
    }
  }

  static bool _genderMatches(String value, String wanted) {
    final gender = value.trim().toLowerCase();
    return gender == wanted ||
        (wanted == 'female' && gender == 'f') ||
        (wanted == 'male' && gender == 'm');
  }

  void _onRoomSelected(_RoomZone r) {
    _slotRequestSerial++;
    setState(() {
      _selectedRoom = r;
      _roomUnitAvailability = const [];
      _selectedRoomUnit = null;
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

  /// New Appointment auto assigns the numbered room; View Appointment is
  /// where staff finalise or change it, so only that flow can pick.
  bool get _canChooseRoomUnit => _isEditing && !_isCheckInMode;

  void _onRoomUnitSelected(RoomUnitAvailability unit) {
    setState(() {
      // Tapping the locked room again releases it back to auto assignment.
      _selectedRoomUnit = _selectedRoomUnit?.id == unit.id ? null : unit;
      _paxAllocations[_activePaxIndex] = null;
    });
  }

  Future<void> _loadRoomUnitAvailability() async {
    // Only View Appointment renders this list, so a new booking would be
    // paying for a round-trip per slot tap that nothing displays.
    if (!_canChooseRoomUnit) return;
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
      setState(() {
        _roomUnitAvailability = units;
        // Re-point the locked unit at the freshly loaded row so its status
        // label reflects the slot being viewed.
        final lockedId = _selectedRoomUnit?.id;
        if (lockedId != null) {
          final match = units.where((unit) => unit.id == lockedId);
          _selectedRoomUnit = match.isEmpty ? null : match.first;
        }
      });
    } catch (error, stackTrace) {
      debugPrint('get_room_unit_availability failed: $error\n$stackTrace');
      if (!mounted || requestSerial != _slotRequestSerial) return;
      setState(() {
        _roomUnitAvailability = const [];
        _selectedRoomUnit = null;
      });
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
      _selectedRoomUnit = null;
      _paxAllocations[_activePaxIndex] = null;
      // One shared start for the whole booking: stamp it onto every stored
      // pax, each ending after its own duration.
      for (var i = 0; i < _paxAllocations.length; i++) {
        final stored = _paxAllocations[i];
        if (stored == null) continue;
        _paxAllocations[i] = stored.withSharedStart(slot.start);
      }
    });
    // Best Fit ranks times for any eligible therapist, so an automatic
    // preference has to be re-resolved against the time that was actually
    // picked — otherwise the locked therapist may not be the one free then.
    //
    // Except when this appointment already owns a confirmed therapist: they are
    // held FOR this booking, so re-running the queue would find them "busy"
    // with their own appointment and report nobody eligible. A deliberate
    // reassignment goes through the therapist picker, not through picking a
    // time.
    if (_usesConcreteAssignmentUi &&
        !_therapistLockedToThisAppointment &&
        (_assignmentSource == 'queue' ||
            _assignmentSource == 'gender_preference')) {
      unawaited(
        _autoAssignFromQueue(
          source: _assignmentSource,
          gender: _requestedGender,
          preserveSlot: true,
        ),
      );
    }
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

  bool _therapistCanPerformServices(
    _Therapist therapist,
    Iterable<_Service> services,
  ) {
    return therapist.serviceCommissions.isEmpty ||
        services.every(
          (service) => therapist.serviceCommissions.containsKey(service.id),
        );
  }

  Set<String> get _serviceEligibleTherapistIds => {
    for (final therapist in _therapists)
      if (_therapistCanPerformServices(therapist, _selectedServices))
        therapist.id,
  };

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

  /// A pax is complete once it has a service, therapist and room. The start
  /// time is deliberately NOT part of this: for a multi-pax booking the time
  /// is shared and picked once, after every pax has its resources. Requiring a
  /// slot here used to deadlock multi-pax — pax 1 could not be stored without
  /// a time, and the time list could not load until every pax was stored.
  bool get _hasCurrentAllocation =>
      _selectedServices.isNotEmpty &&
      _hasCompatibleRoomType &&
      _selectedTherapist != null &&
      _selectedRoom != null;

  _BookingAllocation? get _currentAllocation {
    if (!_hasCurrentAllocation) return null;
    return _BookingAllocation(
      appointmentId: _activeEditAppointmentId ?? '',
      services: List<_Service>.from(_selectedServices),
      therapist: _selectedTherapist!,
      room: _selectedRoom!,
      slot: _selectedSlot ?? _BookingAllocation.pendingSlot,
      roomUnit: _selectedRoomUnit,
    );
  }

  /// A same-day booking whose scheduled start has passed but which has not
  /// been started yet. The service auto-extends from the real arrival time at
  /// Confirm Payment & Start Service, so the counter must NOT be pushed into
  /// rescheduling onto the next 30-minute grid slot -- the booked schedule
  /// stays as-is and the actual window is set at start.
  bool get _isLateArrival {
    final payload = widget.editPayload;
    if (payload == null || payload.isNoShow || _isCheckInMode) return false;
    if (!_isSameDay(_selectedDate, DateTime.now())) return false;
    final scheduled = _previousSlotReference;
    if (scheduled == null || scheduled.start.isEmpty) return false;
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    return _bookingTimeToMinutes(scheduled.start) < nowMinutes;
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// now -> now + full service duration + add-ons, i.e. what the service will
  /// actually run if it is started right now.
  _TimeSlot get _projectedStartNowSlot {
    final clock = DateTime.now();
    final now = DateTime(
      clock.year,
      clock.month,
      clock.day,
      clock.hour,
      clock.minute,
    );
    final start = DateFormat('HH:mm:ss').format(now);
    return _TimeSlot(
      start: start,
      end: _bookingMinutesToTime(
        _bookingTimeToMinutes(start) + _serviceDuration,
      ),
      isRecommended: true,
      isAvailable: true,
      reason: 'late_start_now',
    );
  }

  /// Every pax has its resources, so a shared start can be searched for.
  bool get _allPaxResourcesReady =>
      _allocationSlots.every((allocation) => allocation != null);

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

  /// Service lines a recorded payment already covers, for one appointment.
  /// `lockedServiceIds` is the paid set — without consulting it every summary
  /// line rendered as "Unpaid", including a fully settled booking.
  Set<String> _paidServiceIdsFor(String? appointmentId) {
    final payload = widget.editPayload;
    if (payload == null ||
        !payload.hasPayment ||
        appointmentId == null ||
        appointmentId.trim().isEmpty) {
      return const <String>{};
    }
    for (final allocation in payload.allocations) {
      if (allocation.appointmentId == appointmentId) {
        return allocation.lockedServiceIds.toSet();
      }
    }
    return const <String>{};
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

  /// Splits the booking into what has already been settled and what is still
  /// chargeable. `lockedServiceIds` are the lines a recorded payment covers.
  ({double paid, double unpaid}) get _summaryPaidSplit {
    final payload = widget.editPayload;
    if (payload == null || !payload.hasPayment) {
      return (paid: 0, unpaid: _bookingTotalPrice);
    }
    final paidIdsByAppointment = {
      for (final allocation in payload.allocations)
        allocation.appointmentId: allocation.lockedServiceIds.toSet(),
    };
    var paid = 0.0;
    var unpaid = 0.0;
    for (final allocation in _checkoutAllocations) {
      final paidIds =
          paidIdsByAppointment[allocation.appointmentId] ?? const <String>{};
      for (final service in allocation.services) {
        if (paidIds.contains(service.id)) {
          paid += service.price;
        } else {
          unpaid += service.price;
        }
      }
    }
    return (paid: paid, unpaid: unpaid);
  }

  /// Summary panel money.
  ///
  /// An already-settled booking must not have SST recomputed on top of what
  /// was collected. Online (Billplz) prices are nett, so charging counter SST
  /// over a paid RM149 booking inflated the preview to RM157.90 while checkout
  /// correctly showed RM0.00 due. The paid portion is now carried through at
  /// the amount actually taken, and SST applies only to unpaid add-ons under
  /// the add-on rule — the same split the checkout sheet uses.
  PriceBreakdown get _summaryPriceBreakdown {
    if (_isCapacityMode) {
      return _businessSettings.priceBreakdown(
        _capacityTotalPrice,
        origin: PaymentOrigin.counter,
      );
    }
    final split = _summaryPaidSplit;
    if (split.paid <= 0.005) {
      return _businessSettings.priceBreakdown(
        _bookingTotalPrice,
        origin: PaymentOrigin.counter,
      );
    }
    final addOns = _businessSettings.priceBreakdown(
      split.unpaid,
      origin: PaymentOrigin.appointmentAddon,
    );
    return PriceBreakdown(
      servicePrice: split.paid + addOns.servicePrice,
      sstAmount: addOns.sstAmount,
      totalAmount: split.paid + addOns.totalAmount,
    );
  }

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
    _selectedRoomUnit = null;
    _roomUnitAvailability = const [];
    _previousSlotReference = null;
    _slots = [];
    _scheduleBlocks = [];
    _loadingSlots = false;
  }

  void _loadAllocationIntoSelection(_BookingAllocation? allocation) {
    if (allocation == null) {
      _clearCurrentAllocationSelection();
      _syncPreferenceFromSelection();
      return;
    }
    _selectedServices
      ..clear()
      ..addAll(allocation.services);
    _selectedTherapist = allocation.therapist;
    _selectedRoom = allocation.room;
    _selectedSlot = allocation.slot;
    _selectedRoomUnit = allocation.roomUnit;
    _previousSlotReference = allocation.slot;
    _scheduleBlocks = [];
    _slots = [allocation.slot];
    _loadingSlots = false;
    _syncPreferenceFromSelection();
  }

  /// Mirrors the active pax's locked therapist back onto the preference chips
  /// so switching pax shows that person's actual preference. Call inside
  /// setState.
  void _syncPreferenceFromSelection() {
    final therapist = _selectedTherapist;
    if (therapist == null) {
      _assignmentSource = 'queue';
      _requestedGender = null;
      return;
    }
    _assignmentSource = therapist.assignmentSource.isEmpty
        ? 'queue'
        : therapist.assignmentSource;
    _requestedGender = _assignmentSource == 'gender_preference'
        ? therapist.requestedGender
        : null;
  }

  bool _timesOverlap(_BookingAllocation a, _BookingAllocation b) {
    // Neither pax has a start yet, so there is nothing to compare.
    if (!a.hasRealSlot || !b.hasRealSlot) return false;
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

  /// Whether a pax chip should show its "done" tick. Capacity-first only needs
  /// services picked; the concrete interface needs a full therapist/room/time
  /// allocation.
  bool _isPaxConfigured(int index) {
    if (_isCapacityMode) {
      return index < _capacityPaxServices.length &&
          _capacityPaxServices[index].isNotEmpty;
    }
    if (index == _activePaxIndex) return _currentAllocation != null;
    return index < _paxAllocations.length && _paxAllocations[index] != null;
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
    unawaited(_loadRoomUnitAvailability());
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
        _checkoutAllocations.every((allocation) => allocation.hasRealSlot) &&
        !_loadingSlots &&
        // A late arrival keeps its booked schedule; the real window is set at
        // Confirm Payment & Start Service, so a past slot must not block Save.
        (_selectedSlotIsAvailable || _isLateArrival) &&
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
    // The start is shared, so it can only be searched for once every pax has
    // its resources. Say so instead of showing an empty time list.
    if (missing.isEmpty && _paxCount > 1 && !_allPaxResourcesReady) {
      missing.add('a service, therapist and room for every pax');
    }
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
              therapistAssignmentState: 'confirmed',
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

  bool get _hasNoShowRescheduleChange {
    final payload = widget.editPayload;
    if (!_isNoShowEdit ||
        payload == null ||
        payload.allocations.length != 1 ||
        _checkoutAllocations.length != 1) {
      return false;
    }
    final original = payload.allocations.first;
    final current = _checkoutAllocations.first;
    return !_isSameDay(_selectedDate, payload.date) ||
        _bookingCleanTime(current.slot.start) !=
            _bookingCleanTime(original.startTime) ||
        _bookingCleanTime(current.endTime) !=
            _bookingCleanTime(original.endTime);
  }

  Future<bool> _confirmNoShowReactivation() async {
    if (!_hasNoShowRescheduleChange) {
      AppToast.info(
        context,
        'Choose a new date or time before reactivating this no-show.',
      );
      return false;
    }
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 24,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: const BoxDecoration(
                            color: Color(0xFFEAF5F5),
                            shape: BoxShape.circle,
                          ),
                          child: const Stack(
                            alignment: Alignment.center,
                            children: [
                              Icon(
                                Icons.calendar_month_outlined,
                                size: 32,
                                color: Color(0xFF1B6B72),
                              ),
                              Positioned(
                                right: 6,
                                bottom: 6,
                                child: Icon(
                                  Icons.refresh_rounded,
                                  size: 23,
                                  color: Color(0xFFD97706),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 18),
                        const Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(top: 9),
                            child: Text(
                              'Reschedule Appointment',
                              style: TextStyle(
                                fontSize: 23,
                                height: 1.2,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF16252A),
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () =>
                              Navigator.pop(dialogContext, false),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'This appointment is currently marked as No Show. Rescheduling '
                      'will validate and lock the new therapist and room '
                      'before returning it to Confirmed.',
                      style: TextStyle(
                        fontSize: 16,
                        height: 1.55,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Payment and transaction history will stay unchanged.',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Divider(height: 1, color: Color(0xFFE2E8F0)),
                    const SizedBox(height: 20),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final stackButtons = constraints.maxWidth < 520;
                        final buttons = <Widget>[
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: const Text('Keep No Show'),
                          ),
                          FilledButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, true),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF1B6B72),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 22,
                                vertical: 15,
                              ),
                            ),
                            child: const Text('Reschedule'),
                          ),
                        ];
                        if (stackButtons) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (
                                var index = 0;
                                index < buttons.length;
                                index++
                              ) ...[
                                buttons[index],
                                if (index != buttons.length - 1)
                                  const SizedBox(height: 10),
                              ],
                            ],
                          );
                        }
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            for (
                              var index = 0;
                              index < buttons.length;
                              index++
                            ) ...[
                              buttons[index],
                              if (index != buttons.length - 1)
                                const SizedBox(width: 12),
                            ],
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ) ==
        true;
  }

  /// Writes staff's explicit numbered-room choice after the CSP save.
  ///
  /// There is no room-unit parameter on create/update_appointment_with_csp,
  /// but `assign_appointment_room_unit` is a BEFORE trigger that honours an
  /// already-set `room_unit_id` — it passes it to `allocate_specific_room_unit`
  /// as the requested unit — so a plain column update locks the choice and
  /// still runs the full occupancy check. If the room was taken in the
  /// meantime the trigger raises and only this step fails; the appointment
  /// itself is already saved, so it keeps its auto assigned room and staff are
  /// told rather than losing the save.
  /// Returns whether the booking was saved. [closeOnSuccess] is false when the
  /// caller wants to keep this screen mounted and stack something on top of it
  /// (the in-place checkout hand-off).
  Future<bool> _confirmAppointment({
    Object? popResult,
    bool closeOnSuccess = true,
  }) async {
    if (!_canConfirm) return false;
    if (_isNoShowEdit && !await _confirmNoShowReactivation()) return false;
    if (_isCapacityMode) {
      await _confirmCapacityAppointment();
      return false;
    }
    setState(() => _isConfirming = true);

    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final allocations = _checkoutAllocations;
      final conflict = _paxConflictMessage;
      if (conflict != null) {
        if (mounted) _showPaxConflict(conflict);
        return false;
      }
      for (final allocation in allocations) {
        final slotStart = _timeToMinutes(allocation.slot.start);
        final slotEnd = _timeToMinutes(allocation.endTime);
        if (slotStart == slotEnd) {
          if (mounted) {
            AppToast.error(context, 'Invalid appointment time selected');
          }
          return false;
        }
      }

      final CspCreateResult result;
      if (_isNoShowEdit) {
        final allocation = allocations.single;
        final row = await _appointmentRepository
            .reactivateNoShowAppointment(
          appointmentId: widget.editPayload!.appointmentId!,
          date: dateStr,
          startTime: allocation.slot.start,
          endTime: allocation.endTime,
          therapistId: allocation.therapist.id,
          roomId: allocation.room.id,
          roomUnitId: allocation.roomUnit?.id,
          updates: {
            'service_id': allocation.primaryService.id,
            'service_name': allocation.serviceNameSummary,
            'service_items': allocation.serviceItems,
            'item_count': allocation.services.length,
            'total_price': allocation.price,
            'assignment_source': allocation.therapist.assignmentSource,
            'requested_gender': allocation.therapist.requestedGender,
          },
        );
        result = CspCreateResult(
          success: row['id']?.toString().isNotEmpty == true,
          appointmentId: row['id']?.toString(),
          errorMessage: row['id'] == null
              ? 'The no-show could not be reactivated.'
              : null,
        );
      } else if (_isEditing && widget.editPayload!.isGroup) {
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
                if (_isEditing)
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
          roomUnitId: allocation.roomUnit?.id,
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
                      if (_isEditing)
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
          // Refresh availability first so whichever route the counter takes is
          // judged against the current schedule.
          await _generateSlots();
          if (!mounted) return false;
          if (_isTherapistClash(result)) {
            await _handleTherapistClash(result.message);
          } else {
            AppToast.error(context, result.message, title: 'Could not book');
          }
        }
        return false;
      }

      if (mounted) {
        AppToast.success(
          context,
          _isNoShowEdit
              ? 'Appointment rescheduled and reactivated'
              : _isEditing
              ? 'Appointment saved'
              : 'Appointment confirmed',
        );
        if (closeOnSuccess) {
          Navigator.pop(
            context,
            popResult ?? (_isCheckInMode ? 'checkInSaved' : true),
          );
        }
      }
      return true;
    } catch (e) {
      if (mounted) {
        // The update paths throw rather than returning a result row, so the
        // same clash gets the same recovery dialog instead of a dead-end toast.
        final message = friendlyErrorMessage(e);
        final code = e is AppointmentOperationException ? e.code : '';
        if (_isTherapistClash(
          CspCreateResult(
            success: false,
            errorCode: code,
            errorMessage: message,
          ),
        )) {
          await _generateSlots();
          if (!mounted) return false;
          await _handleTherapistClash(message);
        } else {
          AppToast.error(context, message);
        }
      }
      return false;
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
                ? 'View Appointment'
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
                            title: 'Room',
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
                ? 'View Appointment'
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
                      title: 'Room',
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
            sstLabel: _businessSettings.sstLabel,
            priceBreakdown: _summaryPriceBreakdown,
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
                : _isNoShowEdit
                ? 'Reschedule Appointment'
                : _isEditing
                ? 'Save Appointment'
                : 'Confirm Appointment',
            onSecondaryConfirm: _canOfferCheckout ? _saveAndCheckout : null,
            // Always "Checkout", exactly like the walk-in flow: adding an
            // add-on does not change what this button does, only what the
            // checkout page then collects.
            secondaryConfirmLabel: 'Checkout',
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

  /// Save, then hand off to the checkout page. View Appointment owns editing
  /// and add-ons; payment — and therefore the actual service start — only
  /// happens on checkout. An already-paid appointment routes to the add-on
  /// payment sheet instead, which settles just the unpaid lines.
  Future<void> _saveAndCheckout() async {
    if (_hasUnpaidAddOns) {
      await _confirmAppointment(popResult: 'collectAddOnPayment');
      return;
    }
    final openCheckout = widget.onRequestCheckout;
    if (openCheckout == null) {
      await _confirmAppointment(popResult: 'checkout');
      return;
    }
    // Save without closing, then let the caller stack checkout on top. Staff
    // never see this screen close and the appointment list reload in between.
    final saved = await _confirmAppointment(closeOnSuccess: false);
    if (!saved || !mounted) return;
    await openCheckout();
    if (mounted) Navigator.pop(context, true);
  }

  Widget _buildServiceSection() {
    final tabs = _serviceCategories;
    final filtered = _services.where((s) => s.category == _serviceTab).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Pax chips. Only shown once the booking has more than one person —
        // a single-pax booking has nothing to switch between.
        if (_paxCount > 1) ...[
          if (!_isCheckInMode) ...[
            Text(
              _isCapacityMode
                  ? 'Choose a treatment for each person. The group shares one start, while duration and room capacity are checked separately.'
                  : 'Set the treatment, therapist, room and time for each person. Use the chips to switch between them.',
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var index = 0; index < _paxCount; index++)
                ChoiceChip(
                  label: Text(
                    _isPaxConfigured(index)
                        ? 'Pax ${index + 1}  ✓'
                        : 'Pax ${index + 1}',
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
        ] else if (_usesConcreteAssignmentUi) ...[
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
            'The first eligible therapist in the live queue is selected and locked when this appointment is confirmed.',
            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('No preference'),
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
              ChoiceChip(
                label: const Text('Request specific'),
                selected:
                    preference.assignmentSource ==
                    'specific_customer_request',
                onSelected: (_) => _setCapacityPreference(
                  const _CapacityTherapistPreference(
                    assignmentSource: 'specific_customer_request',
                  ),
                ),
              ),
              ChoiceChip(
                label: const Text('Manual selection'),
                selected: preference.assignmentSource == 'manual_override',
                onSelected: (_) => _setCapacityPreference(
                  const _CapacityTherapistPreference(
                    assignmentSource: 'manual_override',
                  ),
                ),
              ),
            ],
          ),
          if (preference.assignmentSource == 'specific_customer_request' ||
              preference.assignmentSource == 'manual_override') ...[
            const SizedBox(height: 12),
            Text(
              preference.assignmentSource == 'specific_customer_request'
                  ? 'Choose the therapist requested by the customer.'
                  : 'Choose any eligible therapist. Queue position does not restrict a manual selection.',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 8),
            for (final therapist in _therapists)
              Builder(
                builder: (context) {
                  final isDisabled =
                      therapist.statusTone == 'off' ||
                      !_therapistCanPerformServices(
                        therapist,
                        _capacityPaxServices[_activePaxIndex],
                      );
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _TherapistCard(
                      therapist: therapist,
                      isSelected:
                          preference.requestedTherapistId == therapist.id,
                      isReserved: false,
                      isDisabled: isDisabled,
                      onTap: isDisabled
                          ? null
                          : () => _setCapacityPreference(
                              _CapacityTherapistPreference(
                                assignmentSource:
                                    preference.assignmentSource,
                                requestedTherapistId: therapist.id,
                                requestedTherapistName: therapist.name,
                              ),
                            ),
                    ),
                  );
                },
              ),
          ],
        ],
      ),
    );
  }

  /// The single therapist-preference interface for New Appointment and Edit
  /// Appointment. MVP concrete locking: queue order only *recommends*; an
  /// automatic preference locks the first eligible therapist in queue order,
  /// and the counter may lock anyone eligible and available regardless of
  /// queue position. Nothing here rotates the queue — only an actual service
  /// start does that.
  Widget _buildEditTherapistPreference() {
    final source = _assignmentSource;
    final selectedId = _selectedTherapist?.id;
    final picksExplicitTherapist =
        source == 'specific_customer_request' || source == 'manual_override';

    void setSource(String nextSource, {String? gender}) {
      if (nextSource == 'queue' || nextSource == 'gender_preference') {
        setState(() {
          _assignmentSource = nextSource;
          _requestedGender = nextSource == 'gender_preference'
              ? gender
              : null;
        });
        unawaited(_autoAssignFromQueue(source: nextSource, gender: gender));
        return;
      }
      setState(() {
        _assignmentSource = nextSource;
        _requestedGender = null;
      });
      final current = _selectedTherapist;
      if (current == null) return;
      _onTherapistSelected(
        current.withAssignment(
          source: nextSource,
          therapistAssignmentState: 'confirmed',
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
        const SizedBox(height: 4),
        const Text(
          'An automatic preference auto assigns the first eligible therapist '
          'in queue order and locks them on this appointment.',
          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
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
              onSelected: (_) => setSource(
                'gender_preference',
                gender: _requestedGender ?? 'Female',
              ),
            ),
            ChoiceChip(
              label: const Text('Request specific therapist'),
              selected: source == 'specific_customer_request',
              onSelected: (_) => setSource('specific_customer_request'),
            ),
            // Reaches assignment_source = manual_override: a counter choice
            // that is not a customer request and is not restricted by queue
            // position.
            ChoiceChip(
              label: const Text('Manual selection'),
              selected: source == 'manual_override',
              onSelected: (_) => setSource('manual_override'),
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
                selected: _requestedGender?.toLowerCase() == 'female',
                onSelected: (_) =>
                    setSource('gender_preference', gender: 'Female'),
              ),
              ChoiceChip(
                label: const Text('Male'),
                selected: _requestedGender?.toLowerCase() == 'male',
                onSelected: (_) =>
                    setSource('gender_preference', gender: 'Male'),
              ),
            ],
          ),
        ],
        if (_autoAssignInFlight && !picksExplicitTherapist) ...[
          const SizedBox(height: 10),
          const Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Text(
                'Auto assigning from the live queue…',
                style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
            ],
          ),
        ] else if (!picksExplicitTherapist && _selectedTherapist != null) ...[
          const SizedBox(height: 10),
          Text(
            '${_selectedTherapist!.name} · Auto assigned',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF155E63),
            ),
          ),
        ],
        if (picksExplicitTherapist) ...[
          const SizedBox(height: 12),
          Text(
            source == 'specific_customer_request'
                ? 'Choose the therapist requested by the customer.'
                : 'Choose any eligible therapist. Queue position does not '
                      'restrict a manual selection.',
            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 8),
          ..._therapists.map((therapist) {
            // Only real constraints disable a row: the therapist cannot do the
            // selected services, is off/on leave, or is already used by
            // another pax in this same booking. Queue position never does.
            final isIneligible =
                therapist.statusTone == 'off' ||
                !_therapistCanPerformServices(therapist, _selectedServices);
            final isUsedByAnotherPax =
                selectedId != therapist.id &&
                _isTherapistReservedInBooking(therapist.id);
            final isDisabled = isIneligible || isUsedByAnotherPax;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _TherapistCard(
                therapist: therapist,
                isSelected: selectedId == therapist.id,
                isReserved: _isTherapistReservedInBooking(therapist.id),
                isDisabled: isDisabled,
                onTap: isDisabled
                    ? null
                    : () => _onTherapistSelected(
                        therapist.withAssignment(source: source),
                      ),
              ),
            );
          }),
        ],
      ],
    );
  }

  Widget _buildTherapistRoomSection({required bool isTablet}) {
    final compatibleRooms = _rooms
        .where((r) => _requiredRoomType.isEmpty || r.type == _requiredRoomType)
        .toList();

    // New and edit both resolve the therapist in the shared preference block
    // inside the service step (`_buildEditTherapistPreference`), so this step
    // only owns the room. Check-in keeps the live queue picker because it
    // follows the wall clock rather than a scheduled start.
    final therapistSection = !_isCheckInMode
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TherapistQueuePicker(
                outletId: OutletContext.activeOutletId.value,
                date: DateFormat('yyyy-MM-dd').format(_selectedDate),
                startTime: _therapistQueueReferenceTime,
                durationMinutes:
                    _serviceDuration + _serviceBufferAfterMinutes,
                eligibleTherapistIds: _serviceEligibleTherapistIds,
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
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        therapistSection,
        if (_isCheckInMode) SizedBox(height: isTablet ? 18 : 16),
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
          // A new booking never picks the numbered room — the
          // assign_appointment_room_unit trigger locks one on save. Showing an
          // untappable list of rooms at that point is just noise, so New
          // Appointment gets the note only. View Appointment is where staff
          // finalise or change the room once the customer has arrived.
          if (!_canChooseRoomUnit)
            const Text(
              'A numbered room is auto assigned when the appointment is '
              'saved. It can be changed later from View Appointment.',
              style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
            )
          else ...[
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
              // Same card layout as the walk-in room picker, two per row.
              // Availability is always for the selected slot.
              RoomUnitGrid(
                units: _roomUnitAvailability,
                selectedUnitId: _selectedRoomUnit?.id,
                onSelected: _onRoomUnitSelected,
              ),
            const SizedBox(height: 6),
            const Text(
              'Leave unselected to keep the auto assigned room. Choosing one '
              'locks it when you save.',
              style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
            ),
          ],
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
    // A late arrival leads with the window the service will actually run in if
    // it is started now. The 30-minute grid stays below it for genuine
    // reschedules.
    // `_projectedStartNowSlot` is recomputed from the wall clock on every
    // build, so re-deriving it here would change its start each minute and the
    // already-selected tile would stop matching (and look unselected). Once a
    // start-now slot is held, that exact slot is the one shown.
    final startNowSlot = _selectedSlot?.reason == 'late_start_now'
        ? _selectedSlot!
        : _projectedStartNowSlot;
    final recommended = _isLateArrival
        ? [
            startNowSlot,
            ...ranked
                .where((slot) => slot.start != startNowSlot.start)
                .take(2),
          ]
        : ranked.take(3).toList();
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
          'Best Available Times',
          style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
        ),
        if (_isEditing && _previousSlotReference != null) ...[
          const SizedBox(height: 12),
          _PreviousTimeReferenceCard(
            previousSlot: _previousSlotReference!,
            currentSlot: _selectedSlot,
            canSaveCurrent: _selectedSlotIsAvailable,
            isLateArrival: _isLateArrival,
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
    // Same two-tier shape as View Appointment: a short ranked Best Fit strip,
    // then the rest as plain chips — not every open start as a big tile.
    final bestFit = available.where((slot) => slot.isRecommended).take(3).toList();
    final bestFitStarts = bestFit.map((slot) => slot.start).toSet();
    final standard = available
        .where((slot) => !bestFitStarts.contains(slot.start))
        .toList();
    final visibleStandard = _showAllStandardSlots
        ? standard
        : standard.take(12).toList();
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
        if (bestFit.isNotEmpty) ...[
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
            slots: bestFit,
            selectedSlot: _selectedSlot,
            recommended: true,
            startOnly: true,
            onSelect: (slot) => setState(() => _selectedSlot = slot),
          ),
          const SizedBox(height: 14),
        ],
        if (standard.isNotEmpty) ...[
          Text(
            bestFit.isEmpty ? 'Available times' : 'Standard Availability',
            style: const TextStyle(
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
            startOnly: true,
            onSelect: (slot) => setState(() => _selectedSlot = slot),
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
        ],
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
    final allocationSlots = _allocationSlots;
    // A pax that still carries `pendingSlot` has no start yet. Its empty time
    // string parses to 0 minutes, which rendered as a real "12:00 AM – 1:00 AM"
    // booking; `hasRealSlot` exists precisely to keep it out of time maths.
    final allocations = allocationSlots
        .whereType<_BookingAllocation>()
        .where((allocation) => allocation.hasRealSlot)
        .toList();
    final capacitySelections = _capacitySelections;
    final customerName = _selectedCustomer?.name.trim() ?? '';
    final guestLabel = customerName.isEmpty || customerName == 'Guest'
        ? '$_paxCount ${_paxCount == 1 ? 'guest' : 'guests'}'
        : '$_paxCount ${_paxCount == 1 ? 'guest' : 'guests'} · $customerName';
    var startLabel = '$dateStr · —';
    if (_isCapacityMode && _selectedSlot != null) {
      final start = _bookingTimeToMinutes(_selectedSlot!.start);
      final end = start + capacitySelections.fold<int>(
        0,
        (longest, selection) =>
            selection.duration > longest ? selection.duration : longest,
      );
      startLabel =
          '$dateStr · ${_bookingDisplayTimeFromMinutes(start)} – '
          '${_bookingDisplayTimeFromMinutes(end)}';
    } else if (allocations.isNotEmpty) {
      final starts = allocations
          .map((allocation) => _bookingTimeToMinutes(allocation.slot.start))
          .toList();
      final earliestStart = starts.reduce((a, b) => a < b ? a : b);
      final ends = allocations.map((allocation) {
        var end = _bookingTimeToMinutes(allocation.endTime);
        final start = _bookingTimeToMinutes(allocation.slot.start);
        if (end <= start) end += 24 * 60;
        if (end < earliestStart) end += 24 * 60;
        return end;
      }).toList();
      final latestEnd = ends.reduce((a, b) => a > b ? a : b);
      startLabel =
          '$dateStr · ${_bookingDisplayTimeFromMinutes(earliestStart)} – '
          '${_bookingDisplayTimeFromMinutes(latestEnd)}';
    }
    final priceBreakdown = _summaryPriceBreakdown;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Summary Card',
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

          _SummaryRow(
            label: 'Guest',
            value: guestLabel,
          ),
          const SizedBox(height: 14),
          Text(
            'Guest Services ($_paxCount)',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 10),
          if (_isCapacityMode)
            for (var i = 0; i < capacitySelections.length; i++) ...[
              CheckoutGuestCard(
                index: i,
                storageKey: 'appointment-capacity-summary-$i',
                guestName: customerName,
                showGuestNameInTitle: false,
                therapistLabel: capacitySelections[i].services.isEmpty
                    ? ''
                    : capacitySelections[i].preference.label,
                roomLabel:
                    capacitySelections[i].requiredRoomType == 'body_room'
                    ? 'Body room'
                    : capacitySelections[i].requiredRoomType == 'foot_chair'
                    ? 'Foot zone'
                    : '',
                lines: [
                  for (final service in capacitySelections[i].services)
                    CheckoutGuestLine(
                      name: service.name,
                      durationMinutes: service.duration,
                      price: service.price,
                      imageUrl: service.imageUrl,
                      typeLabel: _bookingLineTypeLabel(service.category),
                    ),
                ],
              ),
              if (i != capacitySelections.length - 1)
                const SizedBox(height: 10),
            ]
          else
            for (var i = 0; i < allocationSlots.length; i++) ...[
              CheckoutGuestCard(
                index: i,
                storageKey: 'appointment-summary-$i',
                guestName: customerName,
                showGuestNameInTitle: false,
                therapistLabel: allocationSlots[i]?.therapist.name ?? '',
                roomLabel: allocationSlots[i] == null
                    ? ''
                    : allocationSlots[i]!.roomUnit?.name ??
                          allocationSlots[i]!.room.name,
                lines: [
                  for (final service
                      in allocationSlots[i]?.services ?? const <_Service>[])
                    CheckoutGuestLine(
                      name: service.name,
                      durationMinutes: service.duration,
                      price: service.price,
                      imageUrl: service.imageUrl,
                      typeLabel: _bookingLineTypeLabel(service.category),
                      isPaid: _paidServiceIdsFor(
                        allocationSlots[i]?.appointmentId,
                      ).contains(service.id),
                    ),
                ],
              ),
              if (i != allocationSlots.length - 1)
                const SizedBox(height: 10),
            ],
          if (_paxConflictMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              _paxConflictMessage!,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFFE53935),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _SummaryRow(label: 'Start Time', value: startLabel),
          const SizedBox(height: 8),
          const Divider(color: Color(0xFFEEEEEE)),
          const SizedBox(height: 12),
          _SummaryAmountRow(
            label: 'Service',
            amount: priceBreakdown.servicePrice,
          ),
          const SizedBox(height: 8),
          _SummaryAmountRow(
            label: _businessSettings.sstLabel,
            amount: priceBreakdown.sstAmount,
          ),
          const SizedBox(height: 10),
          const Divider(color: Color(0xFFEEEEEE)),
          const SizedBox(height: 10),
          _SummaryAmountRow(
            label: 'Total',
            amount: priceBreakdown.totalAmount,
            isTotal: true,
          ),

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
                    : _isNoShowEdit
                    ? 'Reschedule Appointment'
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

          // View Appointment always offers Save Appointment followed by
          // Checkout. Checkout is where payment is taken and where the service
          // actually starts.
          if (_canOfferCheckout) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton.icon(
                onPressed: _canConfirm && !_isConfirming
                    ? _saveAndCheckout
                    : null,
                icon: const Icon(Icons.point_of_sale_outlined, size: 18),
                label: Text(
                  'Checkout',
                  style: const TextStyle(
                    fontSize: 15,
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
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _genderController.dispose();
    _dobController.dispose();
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
    final data = {
      'name': _nameController.text.trim(),
      'phone': _phoneController.text.trim(),
      'gender': _genderController.text.trim(),
      // date_of_birth/join_date are DATE columns — an empty string is not a
      // valid date and Postgres rejects it, so omit rather than send ''.
      if (dateOfBirth.isNotEmpty) 'dateOfBirth': dateOfBirth,
      'joinDate': widget.defaultJoinDate,
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
  final VoidCallback? onCalendarTap;

  const _QuickCustomerField({
    required this.label,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.requiredField = false,
    this.onCalendarTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
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
        final sectionPadding = EdgeInsets.all(compact ? 14 : 16);

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
                          width: compact ? 42 : 44,
                          height: compact ? 42 : 44,
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
              width: compact ? 42 : 44,
              height: compact ? 42 : 44,
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
                  Text(
                    compact ? 'Number of guests' : 'Pax',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    compact
                        ? '$configuredCount of $paxCount configured'
                        : '$configuredCount configured',
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
          child: Row(
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
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        guestSection,
                        Container(height: 1, color: const Color(0xFFE2E8F0)),
                        paxSection,
                      ],
                    )
                  : IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: guestSection),
                          Container(width: 1, color: const Color(0xFFE2E8F0)),
                          Expanded(child: paxSection),
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
                            ? 'Reserved until ${_bookingTimeLabel(therapist.busyUntil)}'
                            : 'Reserved';
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

  /// A same-day booking that is late but not started. Nothing has to be
  /// re-picked -- the booked schedule is kept and the real window is set at
  /// Confirm Payment & Start Service.
  final bool isLateArrival;

  const _PreviousTimeReferenceCard({
    required this.previousSlot,
    required this.currentSlot,
    required this.canSaveCurrent,
    this.isLateArrival = false,
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
                Text(
                  isLateArrival ? 'Scheduled time' : 'Previous selected time',
                  style: const TextStyle(
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
                if (isLateArrival) ...[
                  const SizedBox(height: 2),
                  const Text(
                    'Late',
                    style: TextStyle(
                      fontSize: 11,
                      color: Color(0xFFB45309),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ] else if (!canSaveCurrent) ...[
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

enum _BookingClashAction { switchTherapist, pickAnotherTime, dismiss }

/// Explains a save the database refused because the assigned therapist is
/// already taken at the requested time, and offers the two real routes out:
/// keep the time and swap the person, or keep the person and move the time.
///
/// Deliberately has no "save anyway": the database is the authority on
/// double-booking.
class _TherapistClashDialog extends StatelessWidget {
  const _TherapistClashDialog({
    required this.therapistName,
    required this.windowLabel,
    required this.detail,
  });

  final String therapistName;
  final String windowLabel;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text('Therapist is not free at this time'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$therapistName is already booked during $windowLabel, so this '
            'appointment cannot be saved onto that time.',
            style: const TextStyle(fontSize: 13.5, height: 1.45),
          ),
          if (detail.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              detail.trim(),
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
          ],
        ],
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, _BookingClashAction.pickAnotherTime),
          child: const Text('Pick another time'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, _BookingClashAction.switchTherapist),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1B6B72),
          ),
          child: const Text('Choose another therapist'),
        ),
      ],
    );
  }
}

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

class _SummaryAmountRow extends StatelessWidget {
  const _SummaryAmountRow({
    required this.label,
    required this.amount,
    this.isTotal = false,
  });

  final String label;
  final double amount;
  final bool isTotal;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: isTotal ? 16 : 13,
            fontWeight: isTotal ? FontWeight.w700 : FontWeight.w500,
            color: const Color(0xFF1A1A2E),
          ),
        ),
        Text(
          'RM ${amount.toStringAsFixed(2)}',
          style: TextStyle(
            fontSize: isTotal ? 20 : 13,
            fontWeight: isTotal ? FontWeight.w800 : FontWeight.w500,
            color: isTotal
                ? const Color(0xFF1B6B72)
                : const Color(0xFF1A1A2E),
          ),
        ),
      ],
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

// Dormant rollback component for the previous editable summary-card layout.
// ignore: unused_element
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

// Dormant rollback component for the capacity-first summary layout.
// ignore: unused_element
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
  final String secondaryConfirmLabel;
  final DateTime selectedDate;
  final _Customer? selectedCustomer;
  final _Therapist? selectedTherapist;
  final _RoomZone? selectedRoom;
  final _TimeSlot? selectedSlot;
  final bool showResourceAssignment;

  /// Tax comes from the active outlet's business_settings (rate, and whether
  /// the counter price is SST-inclusive) — never a hard-coded percentage.
  final String sstLabel;
  final PriceBreakdown priceBreakdown;

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
    this.secondaryConfirmLabel = 'Checkout',
    required this.selectedDate,
    required this.selectedCustomer,
    required this.selectedTherapist,
    required this.selectedRoom,
    required this.selectedSlot,
    this.showResourceAssignment = true,
    required this.sstLabel,
    required this.priceBreakdown,
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
                        Text(
                          sstLabel,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF9E9E9E),
                          ),
                        ),
                        Text(
                          'RM ${priceBreakdown.sstAmount.toStringAsFixed(2)}',
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
                          'RM ${priceBreakdown.totalAmount.toStringAsFixed(2)}',
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
                      label: Text(
                        secondaryConfirmLabel,
                        style: const TextStyle(
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
