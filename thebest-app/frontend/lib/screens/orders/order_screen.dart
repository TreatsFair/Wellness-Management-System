import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/outlets/outlet_context.dart';
import '../../core/services/csp_service.dart';
import '../../core/services/payment_service.dart';
import '../../core/utils/error_message.dart';
import '../../data/repositories/commission_repository.dart';
import '../../data/repositories/business_settings_repository.dart';
import '../../data/repositories/customer_repository.dart';
import '../../data/repositories/room_repository.dart';
import '../../data/repositories/service_repository.dart';
import '../../data/repositories/therapist_repository.dart';

DateTime _stripDate(DateTime date) => DateTime(date.year, date.month, date.day);

String _normalizeRoomType(Object? value) {
  final raw = value?.toString().trim().toLowerCase() ?? '';
  if (raw.isEmpty || raw == '-') return '';
  final normalized = raw.replaceAll(RegExp(r'[\s-]+'), '_');
  if (normalized.contains('body')) return 'body_room';
  if (normalized.contains('foot')) return 'foot_chair';
  return normalized;
}

int _orderTimeToMinutes(String time) {
  final parts = time.split(':');
  if (parts.length < 2) return 0;
  return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
}

String _orderMinutesToTime(int minutes) {
  final normalized = minutes % (24 * 60);
  final hour = (normalized ~/ 60).toString().padLeft(2, '0');
  final minute = (normalized % 60).toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _databaseTimeFromLabel(String label) {
  final parsed = DateFormat('h:mm a').parse(label);
  return DateFormat('HH:mm').format(parsed);
}

// ── Models (reuse same pattern as appointment) ────────────────────

class _WalkInService {
  final String id, name, imageUrl, roomType, category;
  final int duration;
  final int bufferAfterMinutes;
  final double price;
  final double therapistCommission;
  final double counterCommission;

  const _WalkInService({
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

  factory _WalkInService.fromMap(Map<String, dynamic> d) {
    return _WalkInService(
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

class _WalkInTherapist {
  final String id, name;
  final bool isFree;
  final String availabilityStatus;
  final String busyUntil;
  final int freeInMinutes;
  final Map<String, double> serviceCommissions;

  const _WalkInTherapist({
    required this.id,
    required this.name,
    required this.isFree,
    required this.availabilityStatus,
    required this.busyUntil,
    required this.freeInMinutes,
    required this.serviceCommissions,
  });

  factory _WalkInTherapist.fromMap(
    Map<String, dynamic> d, {
    bool isFree = true,
    String availabilityStatus = 'free_now',
    String busyUntil = '',
    int freeInMinutes = 0,
  }) {
    return _WalkInTherapist(
      id: d['id']?.toString() ?? '',
      name: d['name'] ?? '',
      isFree: isFree,
      availabilityStatus: availabilityStatus,
      busyUntil: busyUntil,
      freeInMinutes: freeInMinutes,
      serviceCommissions: _commissionMap(d['serviceCommissions']),
    );
  }

  Map<String, dynamic> get commissionData => {
    'id': id,
    'name': name,
    'serviceCommissions': serviceCommissions,
  };

  String get initials {
    final p = name.trim().split(' ');
    return p.length >= 2
        ? '${p[0][0]}${p[1][0]}'.toUpperCase()
        : name.isNotEmpty
        ? name[0].toUpperCase()
        : '?';
  }

  Color get avatarColor {
    final colors = [
      const Color(0xFF1B6B72),
      const Color(0xFF7C3AED),
      const Color(0xFF2196F3),
      const Color(0xFF4CAF50),
      const Color(0xFFE91E8C),
      const Color(0xFFFF5722),
    ];
    return colors[name.length % colors.length];
  }
}

Map<String, double> _commissionMap(Object? value) {
  if (value is! Map) return {};
  final result = <String, double>{};
  value.forEach((key, item) {
    result[key.toString()] = _WalkInService._parseDouble(item);
  });
  return result;
}

class _WalkInZone {
  final String id, name, type, floor, imageUrl;
  final int totalSlots, freeSlots;
  final String freeAt;

  const _WalkInZone({
    required this.id,
    required this.name,
    required this.type,
    required this.floor,
    required this.imageUrl,
    required this.totalSlots,
    required this.freeSlots,
    this.freeAt = '',
  });

  bool get isAvailableNow => freeSlots > 0;
}

class _WalkInCustomer {
  final String id, name, phone;
  const _WalkInCustomer({
    required this.id,
    required this.name,
    required this.phone,
  });

  factory _WalkInCustomer.fromMap(Map<String, dynamic> d) {
    return _WalkInCustomer(
      id: d['id']?.toString() ?? '',
      name: d['name'] ?? '',
      phone: d['phone'] ?? '',
    );
  }

  static _WalkInCustomer get anonymous =>
      const _WalkInCustomer(id: 'walk_in_guest', name: 'Guest', phone: '');
}

// ── Start Time Option ─────────────────────────────────────────────
class _StartTimeOption {
  final bool isNow;
  final String timeLabel;
  final String subtitle;

  const _StartTimeOption({
    required this.isNow,
    required this.timeLabel,
    required this.subtitle,
  });
}

class _WalkInAllocation {
  final List<_WalkInService> services;
  final _WalkInTherapist therapist;
  final _WalkInZone zone;
  final RoomUnitAvailability? roomUnit;
  final _StartTimeOption startTime;

  const _WalkInAllocation({
    required this.services,
    required this.therapist,
    required this.zone,
    required this.roomUnit,
    required this.startTime,
  });

  _WalkInService get primaryService => services.first;

  double get servicePrice =>
      services.fold(0, (total, service) => total + service.price);

  int get duration =>
      services.fold(0, (total, service) => total + service.duration);

  String get serviceNameSummary {
    if (services.length == 1) return services.first.name;
    return services.map((service) => service.name).join(', ');
  }

  String get startTimeValue => _databaseTimeFromLabel(startTime.timeLabel);

  String get endTimeValue =>
      _orderMinutesToTime(_orderTimeToMinutes(startTimeValue) + duration);

  List<Map<String, dynamic>> get serviceItems => services
      .map(
        (service) => {
          'id': service.id,
          'name': service.name,
          'category': service.category,
          'duration': service.duration,
          'bufferAfterMinutes': service.bufferAfterMinutes,
          'price': service.price,
          'therapistCommission': service.therapistCommission,
          'counterCommission': service.counterCommission,
          'assignedTherapistId': therapist.id,
          'assignedTherapistName': therapist.name,
          'assignedRoomId': zone.id,
          'assignedRoomName': zone.name,
          'assignedRoomUnitId': roomUnit?.id,
          'assignedRoomUnitName': roomUnit?.name,
          'startTime': startTimeValue,
          'endTime': endTimeValue,
        },
      )
      .toList();

  Map<String, dynamic> toCspAllocation({required String notes}) {
    return {
      'therapist_id': therapist.id,
      'room_id': zone.id,
      'room_unit_id': roomUnit?.id,
      'service_id': primaryService.id,
      'start_time': startTimeValue,
      'end_time': endTimeValue,
      'total_price': servicePrice,
      'service_name': serviceNameSummary,
      'service_items': serviceItems,
      'item_count': services.length,
      'notes': notes,
    };
  }
}

// ── Main Screen ───────────────────────────────────────────────────

class WalkInPosScreen extends StatefulWidget {
  const WalkInPosScreen({super.key});

  @override
  State<WalkInPosScreen> createState() => _WalkInPosScreenState();
}

class _WalkInPosScreenState extends State<WalkInPosScreen> {
  final _customerRepository = CustomerRepository();
  final _roomRepository = RoomRepository();
  final _serviceRepository = ServiceRepository();
  final _therapistRepository = TherapistRepository();
  final _commissionRepository = CommissionRepository();
  final _businessSettingsRepository = BusinessSettingsRepository();

  // Step tracking
  bool _showPayment = false;

  // Selections
  _WalkInCustomer? _selectedCustomer;
  final List<_WalkInService> _selectedServices = [];
  _WalkInTherapist? _selectedTherapist;
  _WalkInZone? _selectedZone;
  RoomUnitAvailability? _selectedRoomUnit;
  _StartTimeOption? _selectedStartTime;
  int _paxCount = 1;
  int _activePaxIndex = 0;
  final List<_WalkInAllocation?> _paxAllocations = [null];
  String _serviceTab = 'Services';
  String? _paymentMethod;
  bool _isConfirming = false;
  late final String _draftSessionId;
  final Set<int> _heldPaxIndexes = <int>{};

  // Data
  List<_WalkInService> _services = [];
  List<_WalkInTherapist> _therapists = [];
  List<_WalkInZone> _zones = [];
  List<RoomUnitAvailability> _roomUnits = [];
  bool _loadingRoomUnits = false;
  List<_WalkInCustomer> _customers = [];
  List<_WalkInCustomer> _filteredCustomers = [];
  List<_StartTimeOption> _startOptions = [];
  bool _loadingData = true;
  String? _serviceLoadError;
  BusinessRuleSettings _businessSettings = BusinessRuleSettings.defaults();

  final _searchController = TextEditingController();
  final _transactionNotesController = TextEditingController();

  // Receipt number
  late final String _receiptNumber;

  @override
  void initState() {
    super.initState();
    _draftSessionId =
        'staff-${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
    _receiptNumber = _generateReceiptNumber();
    _loadData();
    _searchController.addListener(_filterCustomers);
  }

  @override
  void dispose() {
    unawaited(
      CspService.releaseStaffWalkInDraft(
        draftSessionId: _draftSessionId,
      ).catchError((_) {}),
    );
    _searchController.dispose();
    _transactionNotesController.dispose();
    super.dispose();
  }

  String _generateReceiptNumber() {
    final now = DateTime.now();
    return 'TXN-${DateFormat('yyyyMMdd').format(now)}-'
        '${now.millisecondsSinceEpoch.toString().substring(8)}';
  }

  // ── Data Loading ───────────────────────────────────────────────

  Future<void> _loadData() async {
    setState(() => _loadingData = true);
    try {
      await Future.wait([
        _loadBusinessSettings(),
        _loadServices(),
        _loadTherapistsLive(),
        _loadZonesLive(),
        _loadCustomers(),
      ]);
    } finally {
      setState(() => _loadingData = false);
    }
  }

  Future<void> _loadBusinessSettings() async {
    try {
      final settings = await _businessSettingsRepository.getActiveSettings();
      if (mounted) setState(() => _businessSettings = settings);
    } catch (_) {
      if (mounted) {
        setState(() => _businessSettings = BusinessRuleSettings.defaults());
      }
    }
  }

  Future<void> _loadServices() async {
    try {
      final rows = await _serviceRepository.getActiveServices();
      final services = <_WalkInService>[];

      for (final d in rows) {
        final active = _isActiveDoc(d);

        if (active) {
          services.add(_WalkInService.fromMap(d));
        }
      }

      setState(() {
        _services = services;
        _serviceLoadError = null;
      });
    } catch (e) {
      setState(() {
        _services = [];
        _serviceLoadError = e.toString();
      });
    }
  }

  /// Total minutes of the currently selected service(s) -- the window a
  /// candidate therapist/room must be free for, not just free "right now".
  int get _selectedDurationMinutes =>
      _selectedServices.fold(0, (total, service) => total + service.duration);

  int get _selectedRoomBlockMinutes =>
      _selectedDurationMinutes +
      _selectedServices.fold<int>(
        0,
        (buffer, service) => service.bufferAfterMinutes > buffer
            ? service.bufferAfterMinutes
            : buffer,
      );

  Future<void> _loadTherapistsLive() async {
    final now = DateTime.now();
    final today = DateFormat('yyyy-MM-dd').format(now);
    final therapistRows = await _therapistRepository.getActiveTherapists();

    // Duration-aware: checks the whole [now, now + duration] window against
    // today's bookings, not just whether the therapist is busy this instant.
    // A therapist free right now but booked again before the service would
    // finish must show as busy, not "Available immediately".
    final availability = await CspService.getWalkinTherapistAvailability(
      today: today,
      nowTime: DateFormat('HH:mm:ss').format(now),
      duration: _selectedDurationMinutes,
    );
    final availabilityById = {for (final a in availability) a.therapistId: a};

    final therapists = therapistRows.map((row) {
      final id = row['id']?.toString() ?? '';
      final a = availabilityById[id];
      final isFree = a?.isFreeNow ?? false;
      final availabilityStatus = a?.status ?? 'unavailable';
      final freeInMinutes = a?.freeInMinutes ?? 0;
      final busyUntil = a?.freeAt ?? '';

      return _WalkInTherapist.fromMap(
        row,
        isFree: isFree,
        availabilityStatus: availabilityStatus,
        busyUntil: busyUntil,
        freeInMinutes: freeInMinutes,
      );
    }).toList();

    // Sort: free first, then by freeInMinutes ascending
    therapists.sort((a, b) {
      if (a.isFree && !b.isFree) return -1;
      if (!a.isFree && b.isFree) return 1;
      return a.freeInMinutes.compareTo(b.freeInMinutes);
    });

    setState(() => _therapists = therapists);
  }

  int _parseInt(Object? value, {required int fallback}) {
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  Future<void> _loadZonesLive() async {
    final now = DateTime.now();
    final today = DateFormat('yyyy-MM-dd').format(now);
    final nowTime = DateFormat('HH:mm:ss').format(now);
    final duration = _selectedRoomBlockMinutes;

    final roomRows = await _roomRepository.getActiveRooms();

    // Duration-aware, same fix as _loadTherapistsLive: a room free right now
    // but booked again before the service would finish must not show as
    // available.
    final zones = await Future.wait(
      roomRows.where(_isActiveDoc).map((d) async {
        final totalSlots = _parseInt(d['totalSlots'], fallback: 1);
        final roomId = d['id']?.toString() ?? '';
        final availability = await CspService.getWalkinRoomAvailability(
          today: today,
          nowTime: nowTime,
          duration: duration,
          roomId: roomId,
        );

        return _WalkInZone(
          id: roomId,
          name: d['name'] ?? '',
          type: _normalizeRoomType(d['type'] ?? d['roomType']),
          floor: d['floor'] ?? '',
          imageUrl: (d['imageUrl'] ?? d['image'])?.toString().trim() ?? '',
          totalSlots: totalSlots,
          freeSlots: availability.freeSlots,
          freeAt: availability.freeAt ?? '',
        );
      }),
    );

    setState(() => _zones = zones);
  }

  Future<void> _loadCustomers() async {
    final rows = await _customerRepository.getCustomers();
    setState(() {
      _customers = rows.map((d) => _WalkInCustomer.fromMap(d)).toList();
      _filteredCustomers = _customers;
    });
  }

  void _filterCustomers() {
    final q = _searchController.text.trim().toLowerCase();
    setState(() {
      if (_selectedCustomer != null &&
          q != _selectedCustomer!.name.toLowerCase()) {
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
    final savedCustomer = await showDialog<_WalkInCustomer>(
      context: context,
      builder: (context) => _QuickCustomerDialog(
        defaultJoinDate: _todayString(),
        customerBuilder: (id, data) => _WalkInCustomer(
          id: id,
          name: data['name'] ?? '',
          phone: data['phone'] ?? '',
        ),
      ),
    );

    if (savedCustomer == null) {
      return;
    }

    setState(() {
      _customers = [..._customers, savedCustomer]
        ..sort((a, b) => a.name.compareTo(b.name));
      _filteredCustomers = _customers;
      _selectedCustomer = savedCustomer;
      _searchController.text = savedCustomer.name;
    });
  }

  // ── Start Time Logic ───────────────────────────────────────────

  void _computeStartOptions() {
    if (_selectedTherapist == null ||
        _selectedZone == null ||
        _selectedServices.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final nowLabel = DateFormat('h:mm a').format(now);
    final options = <_StartTimeOption>[];
    final selectedUnit = _selectedRoomUnit;
    final roomAvailableNow = selectedUnit == null
        ? _selectedZone!.isAvailableNow
        : selectedUnit.availableForRequestedTime;

    DateTime? parseToday(String? value) {
      if (value == null || value.isEmpty) return null;
      final parts = value.split(':');
      if (parts.length < 2) return null;
      final hour = int.tryParse(parts[0]);
      final minute = int.tryParse(parts[1]);
      if (hour == null || minute == null) return null;
      var result = DateTime(now.year, now.month, now.day, hour, minute);
      if (result.isBefore(now)) result = result.add(const Duration(days: 1));
      return result;
    }

    // Check if we can start now
    if (_selectedTherapist!.isFree && roomAvailableNow) {
      options.add(
        _StartTimeOption(
          isNow: true,
          timeLabel: nowLabel,
          subtitle: 'Immediate start',
        ),
      );
    }

    // Next available — therapist free time
    if (!_selectedTherapist!.isFree && _selectedTherapist!.freeInMinutes > 0) {
      var nextTime =
          parseToday(_selectedTherapist!.busyUntil) ??
          now.add(Duration(minutes: _selectedTherapist!.freeInMinutes));
      final roomFree = roomAvailableNow
          ? null
          : parseToday(selectedUnit?.availableAt ?? _selectedZone!.freeAt);
      if (roomFree != null && roomFree.isAfter(nextTime)) nextTime = roomFree;
      options.add(
        _StartTimeOption(
          isNow: false,
          timeLabel: DateFormat('h:mm a').format(nextTime),
          subtitle: selectedUnit == null
              ? 'Next room and therapist opening'
              : '${selectedUnit.name} available',
        ),
      );
    } else if (_selectedTherapist!.isFree && !roomAvailableNow) {
      // Room unavailable — suggest 30 min later
      final nextTime = parseToday(
        selectedUnit?.availableAt ?? _selectedZone!.freeAt,
      );
      if (nextTime == null) {
        setState(() {
          _startOptions = options;
          _selectedStartTime = options.isNotEmpty ? options.first : null;
        });
        return;
      }
      options.add(
        _StartTimeOption(
          isNow: false,
          timeLabel: DateFormat('h:mm a').format(nextTime),
          subtitle: selectedUnit == null
              ? 'Next room opening'
              : '${selectedUnit.name} available',
        ),
      );
    }

    setState(() {
      _startOptions = options;
      _selectedStartTime = options.isNotEmpty ? options.first : null;
    });
  }

  // ── Selection Handlers ─────────────────────────────────────────

  Future<void> _releaseActivePaxHold() async {
    if (!_heldPaxIndexes.contains(_activePaxIndex)) return;
    await CspService.releaseStaffWalkInDraft(
      draftSessionId: _draftSessionId,
      paxIndex: _activePaxIndex,
    );
    _heldPaxIndexes.remove(_activePaxIndex);
  }

  Future<void> _onServiceSelected(_WalkInService s) async {
    await _releaseActivePaxHold();
    if (!mounted) return;
    setState(() {
      final existingIndex = _selectedServices.indexWhere(
        (service) => service.id == s.id,
      );
      if (existingIndex == -1) {
        _selectedServices.add(s);
      } else {
        _selectedServices.removeAt(existingIndex);
      }
      _selectedTherapist = null;
      _selectedZone = null;
      _selectedRoomUnit = null;
      _roomUnits = [];
      _selectedStartTime = null;
      _startOptions = [];
      _paxAllocations[_activePaxIndex] = null;
    });
    // Therapist/room availability depends on the total selected duration, not
    // just "who's busy right now" -- recompute against the new window.
    _loadTherapistsLive();
    _loadZonesLive();
  }

  Future<void> _onTherapistSelected(_WalkInTherapist t) async {
    await _releaseActivePaxHold();
    if (!mounted) return;
    setState(() {
      _selectedTherapist = t;
      _paxAllocations[_activePaxIndex] = null;
    });
    if (_selectedZone != null) _computeStartOptions();
  }

  Future<void> _onZoneSelected(_WalkInZone z) async {
    await _releaseActivePaxHold();
    if (!mounted) return;
    setState(() {
      _selectedZone = z;
      _selectedRoomUnit = null;
      _roomUnits = [];
      _paxAllocations[_activePaxIndex] = null;
    });
    await _loadRoomUnits(z);
    if (mounted && _selectedTherapist != null) _computeStartOptions();
  }

  Future<void> _loadRoomUnits(_WalkInZone zone) async {
    if (zone.type != 'body_room') return;
    setState(() => _loadingRoomUnits = true);
    try {
      final now = DateTime.now();
      final units = await CspService.getRoomUnitAvailability(
        zoneId: zone.id,
        date: DateFormat('yyyy-MM-dd').format(now),
        startTime: DateFormat('HH:mm:ss').format(now),
        duration: _selectedRoomBlockMinutes,
      );
      if (!mounted || _selectedZone?.id != zone.id) return;
      final available = units.where((unit) => unit.availableForRequestedTime);
      setState(() {
        _roomUnits = units;
        _selectedRoomUnit = available.isNotEmpty
            ? available.first
            : units.isNotEmpty
            ? units.first
            : null;
      });
    } catch (_) {
      if (mounted && _selectedZone?.id == zone.id) {
        setState(() => _roomUnits = []);
      }
    } finally {
      if (mounted) setState(() => _loadingRoomUnits = false);
    }
  }

  void _onRoomUnitSelected(RoomUnitAvailability unit) {
    setState(() {
      _selectedRoomUnit = unit;
      _selectedStartTime = null;
      _startOptions = [];
      _paxAllocations[_activePaxIndex] = null;
    });
    if (_selectedTherapist != null) _computeStartOptions();
  }

  bool get _hasCurrentAllocation =>
      _selectedServices.isNotEmpty &&
      _selectedTherapist != null &&
      _selectedZone != null &&
      _selectedStartTime != null;

  _WalkInAllocation? get _currentAllocation {
    if (!_hasCurrentAllocation) return null;
    return _WalkInAllocation(
      services: List<_WalkInService>.from(_selectedServices),
      therapist: _selectedTherapist!,
      zone: _selectedZone!,
      roomUnit: _selectedRoomUnit,
      startTime: _selectedStartTime!,
    );
  }

  List<_WalkInAllocation?> get _allocationSlots {
    final current = _currentAllocation;
    final allocations = List<_WalkInAllocation?>.from(_paxAllocations);
    if (current != null) allocations[_activePaxIndex] = current;
    return allocations;
  }

  List<_WalkInAllocation> get _checkoutAllocations =>
      _allocationSlots.whereType<_WalkInAllocation>().toList();

  void _clearCurrentAllocationSelection() {
    _selectedServices.clear();
    _selectedTherapist = null;
    _selectedZone = null;
    _selectedRoomUnit = null;
    _roomUnits = [];
    _selectedStartTime = null;
    _startOptions = [];
  }

  void _loadAllocationIntoSelection(_WalkInAllocation? allocation) {
    if (allocation == null) {
      _clearCurrentAllocationSelection();
      return;
    }
    _selectedServices
      ..clear()
      ..addAll(allocation.services);
    _selectedTherapist = allocation.therapist;
    _selectedZone = allocation.zone;
    _selectedRoomUnit = allocation.roomUnit;
    _roomUnits = allocation.roomUnit == null ? [] : [allocation.roomUnit!];
    _selectedStartTime = allocation.startTime;
    _startOptions = [allocation.startTime];
  }

  bool _timesOverlap(_WalkInAllocation a, _WalkInAllocation b) {
    final aStart = _orderTimeToMinutes(a.startTimeValue);
    var aEnd = _orderTimeToMinutes(a.endTimeValue);
    final bStart = _orderTimeToMinutes(b.startTimeValue);
    var bEnd = _orderTimeToMinutes(b.endTimeValue);
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
    _WalkInAllocation allocation, {
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
      if (allocation.roomUnit != null &&
          allocation.roomUnit!.id == other.roomUnit?.id &&
          _timesOverlap(allocation, other)) {
        return 'Pax ${index + 1} overlaps Pax ${i + 1}. ${allocation.roomUnit!.name} is already assigned at that time.';
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
        if (allocation.roomUnit != null &&
            allocation.roomUnit!.id == other.roomUnit?.id &&
            _timesOverlap(allocation, other)) {
          return 'Pax ${i + 1} and Pax ${j + 1} use ${allocation.roomUnit!.name} at overlapping times.';
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

  Future<void> _pickCustomStartTime() async {
    if (_selectedTherapist == null ||
        _selectedZone == null ||
        _selectedServices.isEmpty) {
      return;
    }
    final now = DateTime.now();
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (picked == null || !mounted) return;
    final start = DateTime(
      now.year,
      now.month,
      now.day,
      picked.hour,
      picked.minute,
    );
    final end = start.add(Duration(minutes: _selectedDurationMinutes));
    if (!start.isAfter(now) ||
        end.hour > 21 ||
        (end.hour == 21 && end.minute > 0)) {
      _showPaxConflict('Choose a future time that finishes by 9:00 PM.');
      return;
    }
    final option = _StartTimeOption(
      isNow: false,
      timeLabel: DateFormat('h:mm a').format(start),
      subtitle: 'Scheduled later',
    );
    setState(() {
      _startOptions = [..._startOptions, option];
      _selectedStartTime = option;
      _paxAllocations[_activePaxIndex] = null;
    });
    final allocation = _currentAllocation;
    if (allocation == null) return;
    final reserved = await _reserveAllocation(
      allocation,
      index: _activePaxIndex,
    );
    if (!reserved && mounted) {
      setState(() => _selectedStartTime = null);
    }
  }

  int? _reservedPaxForTherapist(String therapistId) {
    for (var i = 0; i < _paxAllocations.length; i++) {
      if (i == _activePaxIndex) continue;
      final allocation = _paxAllocations[i];
      if (allocation?.therapist.id == therapistId) return i + 1;
    }
    return null;
  }

  Future<bool> _reserveAllocation(
    _WalkInAllocation allocation, {
    required int index,
  }) async {
    final customer = _selectedCustomer;
    if (customer == null) return true;
    try {
      final result = await CspService.reserveStaffWalkInAllocation(
        draftSessionId: _draftSessionId,
        paxIndex: index,
        outletId: OutletContext.activeOutletId.value,
        customerId: customer.id,
        customerName: customer.name,
        customerPhone: customer.phone,
        therapistId: allocation.therapist.id,
        roomId: allocation.zone.id,
        roomUnitId: allocation.roomUnit?.id,
        serviceItems: allocation.serviceItems,
        date: _todayString(),
        startTime: allocation.startTimeValue,
        endTime: allocation.endTimeValue,
        totalAmount: allocation.servicePrice,
      );
      if (!result.success) {
        if (mounted) _showPaxConflict(result.message);
        return false;
      }
      _heldPaxIndexes.add(index);
      return true;
    } catch (error) {
      if (mounted) {
        _showPaxConflict(
          'Unable to reserve ${allocation.therapist.name}: '
          '${friendlyErrorMessage(error)}',
        );
      }
      return false;
    }
  }

  void _showPaxConflict(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFE53935),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _selectPax(int index) async {
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
      if (!await _reserveAllocation(current, index: _activePaxIndex)) return;
    }
    if (!mounted) return;
    setState(() {
      if (current != null) _paxAllocations[_activePaxIndex] = current;
      _activePaxIndex = index;
      _loadAllocationIntoSelection(_paxAllocations[index]);
    });
  }

  Future<void> _clearPax(int index) async {
    await CspService.releaseStaffWalkInDraft(
      draftSessionId: _draftSessionId,
      paxIndex: index,
    );
    _heldPaxIndexes.remove(index);
    if (!mounted) return;
    setState(() {
      _paxAllocations[index] = null;
      _activePaxIndex = index;
      _loadAllocationIntoSelection(null);
    });
  }

  Future<void> _setPaxCount(int count) async {
    if (count < 1) return;
    if (count < _paxAllocations.length) {
      for (var index = count; index < _paxAllocations.length; index++) {
        await CspService.releaseStaffWalkInDraft(
          draftSessionId: _draftSessionId,
          paxIndex: index,
        );
        _heldPaxIndexes.remove(index);
      }
    }
    if (!mounted) return;
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

  // ── Computed Values ────────────────────────────────────────────

  int get _serviceDuration =>
      _selectedServices.fold(0, (total, service) => total + service.duration);

  String get _serviceNameSummary {
    if (_selectedServices.isEmpty) return '';
    if (_selectedServices.length == 1) return _selectedServices.first.name;
    return _selectedServices.map((service) => service.name).join(', ');
  }

  String get _requiredRoomType {
    final types = _selectedServices
        .map((service) => service.roomType)
        .where((type) => type.isNotEmpty)
        .toSet();
    return types.length == 1 ? types.first : '';
  }

  double get _orderServicePrice => _checkoutAllocations.fold(
    0,
    (total, allocation) => total + allocation.servicePrice,
  );

  PriceBreakdown get _orderPriceBreakdown =>
      _businessSettings.priceBreakdown(_orderServicePrice);

  double get _orderNetServicePrice => _orderPriceBreakdown.servicePrice;
  double get _orderSstAmount => _orderPriceBreakdown.sstAmount;
  double get _orderTotalAmount => _orderPriceBreakdown.totalAmount;

  String get _orderServiceNameSummary {
    final allocations = _checkoutAllocations;
    if (allocations.isEmpty) return '';
    if (allocations.length == 1) return allocations.first.serviceNameSummary;
    return '${allocations.length} pax services';
  }

  bool get _canCheckout =>
      _selectedCustomer != null &&
      _checkoutAllocations.length == _paxCount &&
      _paxConflictMessage == null;

  bool get _canConfirmPayment => _paymentMethod != null;

  // ── Confirm Payment ────────────────────────────────────────────

  Future<void> _confirmPayment() async {
    if (!_canConfirmPayment) return;
    setState(() => _isConfirming = true);

    try {
      final allocations = _checkoutAllocations;
      final conflict = _paxConflictMessage;
      if (conflict != null) {
        if (mounted) _showPaxConflict(conflict);
        return;
      }
      final date = DateFormat('yyyy-MM-dd').format(DateTime.now());
      final startImmediately = allocations.every(
        (allocation) => allocation.startTime.isNow,
      );

      final counterStaff = await _commissionRepository
          .getAvailableCounterStaff();
      final notes = _transactionNotesController.text.trim();
      PaymentResult paymentResult;

      if (allocations.length == 1) {
        final allocation = allocations.first;
        paymentResult = await PaymentService.createWalkInAppointmentWithPayment(
          customerId: _selectedCustomer!.id,
          therapistId: allocation.therapist.id,
          roomId: allocation.zone.id,
          serviceId: allocation.primaryService.id,
          date: date,
          startTime: allocation.startTimeValue,
          endTime: allocation.endTimeValue,
          servicePrice: _orderNetServicePrice,
          serviceName: allocation.serviceNameSummary,
          serviceItems: allocation.serviceItems,
          itemCount: allocation.services.length,
          notes: notes,
          customerName: _selectedCustomer!.name,
          customerPhone: _selectedCustomer!.phone,
          counterStaffId: counterStaff?['id']?.toString(),
          counterStaffName: counterStaff?['name']?.toString(),
          sstAmount: _orderSstAmount,
          totalAmount: _orderTotalAmount,
          paymentMethod: _paymentMethod!,
          receiptNumber: _receiptNumber,
          transactionNotes: notes,
          startImmediately: startImmediately,
          draftSessionId: _draftSessionId,
        );
      } else {
        paymentResult =
            await PaymentService.createWalkInAppointmentGroupWithPayment(
              customerId: _selectedCustomer!.id,
              groupName: _selectedCustomer!.name,
              paxCount: allocations.length,
              date: date,
              allocations: allocations
                  .map((allocation) => allocation.toCspAllocation(notes: notes))
                  .toList(),
              notes: notes,
              customerName: _selectedCustomer!.name,
              customerPhone: _selectedCustomer!.phone,
              counterStaffId: counterStaff?['id']?.toString(),
              counterStaffName: counterStaff?['name']?.toString(),
              servicePrice: _orderNetServicePrice,
              sstAmount: _orderSstAmount,
              totalAmount: _orderTotalAmount,
              paymentMethod: _paymentMethod!,
              receiptNumber: _receiptNumber,
              transactionNotes: notes,
              startImmediately: startImmediately,
              draftSessionId: _draftSessionId,
            );
      }

      if (!paymentResult.success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(paymentResult.message),
              backgroundColor: const Color(0xFFE53935),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              startImmediately
                  ? 'Payment confirmed - service started'
                  : 'Payment confirmed - booking reserved',
            ),
            backgroundColor: Color(0xFF1B6B72),
            behavior: SnackBarBehavior.floating,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${friendlyErrorMessage(e)}'),
            backgroundColor: const Color(0xFFE53935),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isConfirming = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _loadingData
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF1B6B72)),
              )
            : _showPayment
            ? _buildPaymentScreen()
            : _buildOrderScreen(),
      ),
    );
  }

  // ── ORDER SCREEN ───────────────────────────────────────────────

  Widget _buildOrderScreen() {
    final screenWidth = MediaQuery.of(context).size.width;
    if (screenWidth < 900) {
      return _buildPhoneOrderScreen();
    }
    final isCompactTablet = screenWidth < 1100;
    final contentPadding = isCompactTablet ? 14.0 : 20.0;
    final gap = isCompactTablet ? 12.0 : 16.0;

    return Column(
      children: [
        _buildOrderHeader(),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left — steps
              Expanded(
                flex: 65,
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(contentPadding),
                  child: Column(
                    children: [
                      // Step 1
                      _WalkInStepCard(
                        number: 1,
                        title: 'Walk-in Customer',
                        child: _buildCustomerSection(),
                      ),
                      SizedBox(height: gap),
                      // Step 2
                      _WalkInStepCard(
                        number: 2,
                        title: 'Service Selection',
                        child: _buildServiceSection(),
                      ),
                      SizedBox(height: gap),
                      // Step 3
                      _WalkInStepCard(
                        number: 3,
                        title: 'Current Availability',
                        badge: _LiveBadge(),
                        child: _buildAvailabilitySection(),
                      ),
                      if (_startOptions.isNotEmpty) ...[
                        SizedBox(height: gap),
                        _WalkInStepCard(
                          number: 4,
                          title: 'Start Time',
                          child: _buildStartTimeSection(),
                        ),
                      ],
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
              // Right — summary
              Container(
                width: MediaQuery.of(context).size.width * 0.32,
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
                child: _buildSummaryPanel(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPhoneOrderScreen() {
    return Column(
      children: [
        _buildPhoneOrderHeader(),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 118),
                  child: Column(
                    children: [
                      _WalkInStepCard(
                        number: 1,
                        title: 'Walk-in Customer',
                        child: _buildCustomerSection(),
                      ),
                      const SizedBox(height: 16),
                      _WalkInStepCard(
                        number: 2,
                        title: 'Service Selection',
                        child: _buildServiceSection(),
                      ),
                      const SizedBox(height: 16),
                      _WalkInStepCard(
                        number: 3,
                        title: 'Current Availability',
                        badge: _LiveBadge(),
                        child: _buildAvailabilitySection(),
                      ),
                      if (_startOptions.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _WalkInStepCard(
                          number: 4,
                          title: 'Start Time',
                          child: _buildStartTimeSection(),
                        ),
                      ],
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _PhoneCheckoutBar(
                  customerName: _selectedCustomer?.name,
                  serviceName: _checkoutAllocations.isEmpty
                      ? null
                      : _orderServiceNameSummary,
                  totalAmount: _orderTotalAmount,
                  canCheckout: _canCheckout,
                  onCheckout: () => setState(() => _showPayment = true),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPhoneOrderHeader() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: const Icon(
              Icons.arrow_back_ios,
              size: 18,
              color: Color(0xFF1B6B72),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Walk-in Order',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A2E),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _StepPill(number: 1, label: 'Order', isActive: true),
        ],
      ),
    );
  }

  Widget _buildOrderHeader() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
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
              const Text(
                'Walk-in Order',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              const Text(
                'Step 1 of 2 — Order Entry',
                style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
              ),
            ],
          ),
          const Spacer(),
          // Step progress pills
          Row(
            children: [
              _StepPill(number: 1, label: 'Order', isActive: true),
              const SizedBox(width: 4),
              Container(width: 20, height: 1, color: const Color(0xFFDDDDDD)),
              const SizedBox(width: 4),
              _StepPill(number: 2, label: 'Payment', isActive: false),
            ],
          ),
        ],
      ),
    );
  }

  // ── Step Sections ──────────────────────────────────────────────

  Widget _buildCustomerSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Search field
        _WalkInCustomerSearch(
          controller: _searchController,
          customers: _filteredCustomers,
          selected: _selectedCustomer,
          onSelect: (c) => setState(() {
            _selectedCustomer = c;
            _searchController.text = c.name;
            _filteredCustomers = _customers;
          }),
          onClear: () => setState(() {
            _selectedCustomer = null;
            _searchController.clear();
          }),
        ),
        const SizedBox(height: 12),
        const _OrDivider(),
        const SizedBox(height: 12),
        // Walk-in no account option
        GestureDetector(
          onTap: () => setState(() {
            _selectedCustomer = _WalkInCustomer.anonymous;
            _searchController.clear();
          }),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _selectedCustomer?.id == 'walk_in_guest'
                  ? const Color(0xFF1B6B72).withValues(alpha: 0.06)
                  : const Color(0xFFF8F8F8),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _selectedCustomer?.id == 'walk_in_guest'
                    ? const Color(0xFF1B6B72)
                    : const Color(0xFFEEEEEE),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F0F0),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.person_outline,
                    size: 18,
                    color: Color(0xFF9E9E9E),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Walk-in (No Account)',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                      const Text(
                        'Anonymous guest — no customer profile needed',
                        style: TextStyle(
                          fontSize: 12,
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
        const SizedBox(height: 8),
        GestureDetector(
          onTap: _openAddCustomerDialog,
          child: const Text(
            '+ Add New Customer',
            style: TextStyle(
              fontSize: 13,
              color: Color(0xFF1B6B72),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(height: 16),
        _buildPaxCountControl(),
      ],
    );
  }

  Widget _buildPaxCountControl() {
    final configuredCount = _checkoutAllocations.length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5F5),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  Icons.groups_2_outlined,
                  size: 18,
                  color: Color(0xFF1B6B72),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pax',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$configuredCount of $_paxCount configured',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              _PaxStepperButton(
                icon: Icons.remove,
                onTap: _paxCount <= 1
                    ? null
                    : () => _setPaxCount(_paxCount - 1),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '$_paxCount',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
              _PaxStepperButton(
                icon: Icons.add,
                onTap: () => _setPaxCount(_paxCount + 1),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildServiceSection() {
    final tabs = ['Services', 'Packages', 'Add-ons'];
    final filtered = _services.where((s) => s.category == _serviceTab).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Tabs
        Row(
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
        if (filtered.isEmpty || _serviceLoadError != null) ...[
          _ServiceEmptyState(tab: _serviceTab, error: _serviceLoadError),
          const SizedBox(height: 12),
        ],
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
              itemBuilder: (_, i) => _WalkInServiceCard(
                service: filtered[i],
                isSelected: _selectedServices.any(
                  (service) => service.id == filtered[i].id,
                ),
                onTap: () => _onServiceSelected(filtered[i]),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildAvailabilitySection() {
    final compatibleZones = _zones
        .where((z) => _requiredRoomType.isEmpty || z.type == _requiredRoomType)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Based on real-time therapist and room availability',
          style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
        ),
        const SizedBox(height: 14),

        const _WalkInSubLabel('Available Therapists Now'),
        const SizedBox(height: 10),
        ..._therapists.map((t) {
          final reservedByPax = _reservedPaxForTherapist(t.id);
          final unavailable = !t.isFree && t.freeInMinutes <= 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _WalkInTherapistRow(
              therapist: t,
              isSelected: _selectedTherapist?.id == t.id,
              isDisabled: unavailable || reservedByPax != null,
              reservedByPax: reservedByPax,
              onTap: unavailable || reservedByPax != null
                  ? null
                  : () => _onTherapistSelected(t),
            ),
          );
        }),
        const SizedBox(height: 18),
        const _WalkInSubLabel('Room / Zone Availability'),
        const SizedBox(height: 10),
        ...compatibleZones.map(
          (z) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _WalkInZoneCard(
              zone: z,
              isSelected: _selectedZone?.id == z.id,
              onTap: () => _onZoneSelected(z),
            ),
          ),
        ),
        if (_selectedZone != null && _loadingRoomUnits) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(minHeight: 2),
        ],
        if (_roomUnits.isNotEmpty) ...[
          const SizedBox(height: 18),
          const _WalkInSubLabel('Specific Massage Room'),
          const SizedBox(height: 10),
          ..._roomUnits.map(
            (unit) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _WalkInRoomUnitCard(
                unit: unit,
                isSelected: _selectedRoomUnit?.id == unit.id,
                onTap: () => _onRoomUnitSelected(unit),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildStartTimeSection() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stackCards = constraints.maxWidth < 520;
        final cards = _startOptions.map((option) {
          final isSelected = _selectedStartTime?.timeLabel == option.timeLabel;
          return GestureDetector(
            onTap: () async {
              setState(() {
                _selectedStartTime = option;
                _paxAllocations[_activePaxIndex] = null;
              });
              final allocation = _currentAllocation;
              if (allocation != null) {
                final reserved = await _reserveAllocation(
                  allocation,
                  index: _activePaxIndex,
                );
                if (!reserved && mounted) {
                  setState(() {
                    _selectedStartTime = null;
                    _startOptions = [];
                  });
                }
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFFE8F5F5) : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFF1B6B72)
                      : const Color(0xFFEEEEEE),
                  width: isSelected ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isSelected
                          ? const Color(0xFFD4EEEE)
                          : option.isNow
                          ? const Color(0xFFE8F5E9)
                          : const Color(0xFFFFF3E0),
                    ),
                    child: Icon(
                      option.isNow
                          ? Icons.play_circle_outline
                          : Icons.schedule_outlined,
                      color: isSelected
                          ? const Color(0xFF1B6B72)
                          : option.isNow
                          ? const Color(0xFF4CAF50)
                          : const Color(0xFFF59E0B),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          option.isNow ? 'Start Now' : 'Next Available',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          option.timeLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: isSelected
                                ? const Color(0xFF1B6B72)
                                : option.isNow
                                ? const Color(0xFF4CAF50)
                                : const Color(0xFFF59E0B),
                          ),
                        ),
                        Text(
                          option.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: isSelected
                                ? const Color(0xFF5F6B7A)
                                : const Color(0xFF9E9E9E),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList();

        final optionLayout = stackCards
            ? Column(
                children: [
                  for (var i = 0; i < cards.length; i++) ...[
                    cards[i],
                    if (i != cards.length - 1) const SizedBox(height: 10),
                  ],
                ],
              )
            : Row(
                children: [
                  for (var i = 0; i < cards.length; i++) ...[
                    Expanded(child: cards[i]),
                    if (i != cards.length - 1) const SizedBox(width: 12),
                  ],
                ],
              );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            optionLayout,
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _pickCustomStartTime,
              icon: const Icon(Icons.schedule_outlined),
              label: const Text('Choose Another Time'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSummaryPanel() {
    final startLabel = _selectedStartTime != null
        ? '${_selectedStartTime!.isNow ? 'Now' : 'Next'} — ${_selectedStartTime!.timeLabel}'
        : '—';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Walk-in Summary',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Review order before checkout',
            style: TextStyle(fontSize: 13, color: Color(0xFF9E9E9E)),
          ),
          const SizedBox(height: 24),

          _WalkInSummaryRow(
            label: 'Customer',
            value: _selectedCustomer?.name ?? '—',
          ),
          _WalkInSummaryRow(
            label: 'Service',
            value: _selectedServices.isEmpty ? '-' : _serviceNameSummary,
          ),
          _WalkInSummaryRow(
            label: 'Duration',
            value: _selectedServices.isNotEmpty ? '$_serviceDuration min' : '—',
          ),
          _WalkInSummaryRow(
            label: 'Therapist',
            value: _selectedTherapist != null
                ? '● ${_selectedTherapist!.name}'
                : '—',
            valueColor: _selectedTherapist != null
                ? const Color(0xFF4CAF50)
                : null,
          ),
          _WalkInSummaryRow(label: 'Zone', value: _selectedZone?.name ?? '—'),
          if (_selectedRoomUnit != null)
            _WalkInSummaryRow(label: 'Room', value: _selectedRoomUnit!.name),
          _WalkInSummaryRow(label: 'Start Time', value: startLabel),

          if (_paxCount > 1 || _checkoutAllocations.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              'Pax in this order (${_checkoutAllocations.length}/$_paxCount)',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < _allocationSlots.length; i++) ...[
              _WalkInPaxSummaryCard(
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
            const SizedBox(height: 8),
            const Divider(color: Color(0xFFEEEEEE)),
            const SizedBox(height: 12),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Service',
                  style: TextStyle(fontSize: 13, color: Color(0xFF6B6B6B)),
                ),
                Text(
                  'RM ${_orderNetServicePrice.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _businessSettings.sstLabel,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF6B6B6B),
                  ),
                ),
                Text(
                  'RM ${_orderSstAmount.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(color: Color(0xFFEEEEEE)),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Total',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                Text(
                  'RM ${_orderTotalAmount.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1B6B72),
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 28),

          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _canCheckout
                  ? () => setState(() => _showPayment = true)
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B6B72),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFBDBDBD),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Checkout',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(width: 6),
                  Icon(Icons.arrow_forward, size: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── PAYMENT SCREEN ─────────────────────────────────────────────

  Widget _buildPaymentScreen() {
    final isPhone = MediaQuery.of(context).size.width < 900;

    return Center(
      child: Container(
        width: isPhone ? double.infinity : 620,
        margin: EdgeInsets.all(isPhone ? 12 : 32),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(isPhone ? 16 : 20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 24,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(isPhone ? 18 : 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Payment header
              if (isPhone)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _PaymentBackButton(
                          onTap: () => setState(() => _showPayment = false),
                        ),
                        const Spacer(),
                        _StepPill(number: 2, label: 'Payment', isActive: true),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Payment',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '#$_receiptNumber',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF9E9E9E),
                      ),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    _PaymentBackButton(
                      onTap: () => setState(() => _showPayment = false),
                    ),
                    const Spacer(),
                    Column(
                      children: [
                        const Text(
                          'Payment',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                        Text(
                          '#$_receiptNumber',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF9E9E9E),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    _StepPill(number: 2, label: 'Payment', isActive: true),
                  ],
                ),
              const SizedBox(height: 24),

              // Order recap
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F8F8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            '${_selectedCustomer?.name ?? 'Guest'} - ${_orderServiceNameSummary.isEmpty ? '-' : _orderServiceNameSummary}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1A1A2E),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE8F5F5),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${_checkoutAllocations.length} pax',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1B6B72),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _checkoutAllocations.length == 1
                          ? '${_checkoutAllocations.first.therapist.name} - ${_checkoutAllocations.first.zone.name}'
                          : '${_checkoutAllocations.length} staff - ${_checkoutAllocations.length} resources',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF6B6B6B),
                      ),
                    ),
                    Text(
                      _checkoutAllocations.length == 1
                          ? 'Start: ${_checkoutAllocations.first.startTime.isNow ? 'Now' : 'Next'} - ${_checkoutAllocations.first.startTime.timeLabel}'
                          : 'Group walk-in with ${_checkoutAllocations.length} allocations',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF6B6B6B),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // Price breakdown
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFEEEEEE)),
                ),
                child: Column(
                  children: [
                    _PaymentRow(
                      'Service',
                      'RM ${_orderNetServicePrice.toStringAsFixed(2)}',
                    ),
                    const SizedBox(height: 8),
                    _PaymentRow(
                      _businessSettings.sstLabel,
                      'RM ${_orderSstAmount.toStringAsFixed(2)}',
                    ),
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
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                        Text(
                          'RM ${_orderTotalAmount.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1B6B72),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              TextField(
                controller: _transactionNotesController,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: 'Notes',
                  alignLabelWithHint: true,
                  filled: true,
                  fillColor: const Color(0xFFFAFAFA),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: Color(0xFF1B6B72)),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Payment method
              const Text(
                'Select Payment Method',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final compactMethods = isPhone && constraints.maxWidth < 430;
                  final itemWidth = compactMethods
                      ? constraints.maxWidth
                      : (constraints.maxWidth - 36) / 4;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: itemWidth,
                        child: _PaymentMethodCard(
                          icon: Icons.attach_money_outlined,
                          label: 'Cash',
                          isSelected: _paymentMethod == 'cash',
                          onTap: () => setState(() => _paymentMethod = 'cash'),
                        ),
                      ),
                      SizedBox(
                        width: itemWidth,
                        child: _PaymentMethodCard(
                          icon: Icons.qr_code_2_outlined,
                          label: 'QR Code',
                          isSelected: _paymentMethod == 'qr_code',
                          onTap: () =>
                              setState(() => _paymentMethod = 'qr_code'),
                        ),
                      ),
                      SizedBox(
                        width: itemWidth,
                        child: _PaymentMethodCard(
                          icon: Icons.credit_card_outlined,
                          label: 'Credit Card',
                          isSelected: _paymentMethod == 'credit_card',
                          onTap: () =>
                              setState(() => _paymentMethod = 'credit_card'),
                        ),
                      ),
                      SizedBox(
                        width: itemWidth,
                        child: _PaymentMethodCard(
                          icon: Icons.credit_card,
                          label: 'Debit Card',
                          isSelected: _paymentMethod == 'debit_card',
                          onTap: () =>
                              setState(() => _paymentMethod = 'debit_card'),
                        ),
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 24),

              // Confirm button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: _canConfirmPayment && !_isConfirming
                      ? _confirmPayment
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
                    _checkoutAllocations.isNotEmpty &&
                            _checkoutAllocations.every(
                              (allocation) => allocation.startTime.isNow,
                            )
                        ? 'Pay & Start Service'
                        : 'Pay & Reserve',
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

              const SizedBox(height: 12),
              const Center(
                child: Text(
                  'Select a payment method to continue\n'
                  'A receipt will be recorded automatically',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// COMPONENT WIDGETS
// ─────────────────────────────────────────────────────────────────

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
          _WalkInMonthCalendarDialog(initialDate: initialDate),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to save customer: ${friendlyErrorMessage(e)}'),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
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

class _WalkInMonthCalendarDialog extends StatefulWidget {
  final DateTime initialDate;

  const _WalkInMonthCalendarDialog({required this.initialDate});

  @override
  State<_WalkInMonthCalendarDialog> createState() =>
      _WalkInMonthCalendarDialogState();
}

class _WalkInMonthCalendarDialogState
    extends State<_WalkInMonthCalendarDialog> {
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
                  _WalkInWeekdayLabel('SUN'),
                  _WalkInWeekdayLabel('MON'),
                  _WalkInWeekdayLabel('TUE'),
                  _WalkInWeekdayLabel('WED'),
                  _WalkInWeekdayLabel('THU'),
                  _WalkInWeekdayLabel('FRI'),
                  _WalkInWeekdayLabel('SAT'),
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

class _WalkInWeekdayLabel extends StatelessWidget {
  final String label;

  const _WalkInWeekdayLabel(this.label);

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

class _WalkInStepCard extends StatelessWidget {
  final int number;
  final String title;
  final Widget child;
  final Widget? badge;

  const _WalkInStepCard({
    required this.number,
    required this.title,
    required this.child,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final isCompactTablet = MediaQuery.of(context).size.width < 1100;
    final padding = isCompactTablet ? 14.0 : 20.0;
    final markerSize = isCompactTablet ? 24.0 : 28.0;
    final titleSize = isCompactTablet ? 15.0 : 16.0;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(isCompactTablet ? 12 : 16),
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
                width: markerSize,
                height: markerSize,
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
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
              SizedBox(width: isCompactTablet ? 8 : 10),
              Text(
                title,
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF1A1A2E),
                ),
              ),
              if (badge != null) ...[const SizedBox(width: 8), badge!],
            ],
          ),
          SizedBox(height: isCompactTablet ? 12 : 16),
          child,
        ],
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF4CAF50),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 6, color: Colors.white),
          SizedBox(width: 4),
          Text(
            'Live',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _PaymentBackButton extends StatelessWidget {
  final VoidCallback onTap;

  const _PaymentBackButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chevron_left, size: 18, color: Color(0xFF1B6B72)),
          Text(
            'Back to Order',
            style: TextStyle(
              fontSize: 13,
              color: Color(0xFF1B6B72),
              fontWeight: FontWeight.w500,
            ),
          ),
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

class _StepPill extends StatelessWidget {
  final int number;
  final String label;
  final bool isActive;

  const _StepPill({
    required this.number,
    required this.label,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFF1B6B72) : const Color(0xFFF0F0F0),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive
                  ? Colors.white.withValues(alpha: 0.25)
                  : const Color(0xFFDDDDDD),
            ),
            child: Center(
              child: Text(
                '$number',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isActive ? Colors.white : const Color(0xFF9E9E9E),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isActive ? Colors.white : const Color(0xFF9E9E9E),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhoneCheckoutBar extends StatelessWidget {
  final String? customerName;
  final String? serviceName;
  final double totalAmount;
  final bool canCheckout;
  final VoidCallback onCheckout;

  const _PhoneCheckoutBar({
    required this.customerName,
    required this.serviceName,
    required this.totalAmount,
    required this.canCheckout,
    required this.onCheckout,
  });

  @override
  Widget build(BuildContext context) {
    final title = serviceName?.trim().isNotEmpty == true
        ? serviceName!.trim()
        : 'Select service';
    final subtitle = customerName?.trim().isNotEmpty == true
        ? customerName!.trim()
        : 'Choose customer';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 14,
            offset: const Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9E9E9E),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'RM ${totalAmount.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1B6B72),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              height: 46,
              child: ElevatedButton(
                onPressed: canCheckout ? onCheckout : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B6B72),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFBDBDBD),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Checkout',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(width: 6),
                    Icon(Icons.arrow_forward, size: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WalkInSubLabel extends StatelessWidget {
  final String text;
  const _WalkInSubLabel(this.text);

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

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Divider(color: Color(0xFFEEEEEE))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'or',
            style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
          ),
        ),
        const Expanded(child: Divider(color: Color(0xFFEEEEEE))),
      ],
    );
  }
}

class _WalkInCustomerSearch extends StatelessWidget {
  final TextEditingController controller;
  final List<_WalkInCustomer> customers;
  final _WalkInCustomer? selected;
  final Function(_WalkInCustomer) onSelect;
  final VoidCallback onClear;

  const _WalkInCustomerSearch({
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
            hintText: 'Search existing customer...',
            hintStyle: const TextStyle(color: Color(0xFFBDBDBD), fontSize: 14),
            prefixIcon: const Icon(
              Icons.search,
              color: Color(0xFF9E9E9E),
              size: 18,
            ),
            suffixIcon: controller.text.isNotEmpty
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
                      leading: CircleAvatar(
                        radius: 16,
                        backgroundColor: const Color(0xFF1B6B72),
                        child: Text(
                          c.name.isNotEmpty ? c.name[0].toUpperCase() : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      title: Text(
                        c.name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        c.phone,
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

class _WalkInServiceCard extends StatelessWidget {
  final _WalkInService service;
  final bool isSelected;
  final VoidCallback onTap;

  const _WalkInServiceCard({
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
                _WalkInServiceImage(imageUrl: service.imageUrl, size: 44),
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
                          _SmallBadge2(
                            label: '${service.duration}m',
                            bg: const Color(0xFFE8F5F5),
                            color: const Color(0xFF1B6B72),
                          ),
                          _SmallBadge2(
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

class _WalkInServiceImage extends StatelessWidget {
  final String imageUrl;
  final double size;

  const _WalkInServiceImage({required this.imageUrl, this.size = 38});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: size,
        height: size,
        color: const Color(0xFFE8F5F5),
        child: imageUrl.isEmpty
            ? const Icon(Icons.spa_outlined, color: Color(0xFF1B6B72), size: 21)
            : Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, error, stackTrace) => const Icon(
                  Icons.spa_outlined,
                  color: Color(0xFF1B6B72),
                  size: 21,
                ),
              ),
      ),
    );
  }
}

class _WalkInTherapistRow extends StatelessWidget {
  final _WalkInTherapist therapist;
  final bool isSelected;
  final bool isDisabled;
  final int? reservedByPax;
  final VoidCallback? onTap;

  const _WalkInTherapistRow({
    required this.therapist,
    required this.isSelected,
    required this.isDisabled,
    this.reservedByPax,
    required this.onTap,
  });

  String get _statusLabel {
    if (reservedByPax != null) return 'Reserved by Pax $reservedByPax';
    if (therapist.availabilityStatus == 'on_leave') return 'On leave';
    if (therapist.isFree) return 'Available immediately';
    if (therapist.freeInMinutes > 0) {
      return 'Free in ${therapist.freeInMinutes} min';
    }
    return 'Unavailable';
  }

  Color get _statusColor {
    if (reservedByPax != null) return const Color(0xFF1B6B72);
    if (therapist.isFree) return const Color(0xFF4CAF50);
    if (therapist.freeInMinutes > 0) return const Color(0xFFF59E0B);
    return const Color(0xFF9E9E9E);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isDisabled ? null : onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: isDisabled ? 0.4 : 1.0,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
              CircleAvatar(
                radius: 20,
                backgroundColor: isDisabled
                    ? const Color(0xFFBDBDBD)
                    : therapist.avatarColor,
                child: Text(
                  therapist.initials,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          therapist.name,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _statusColor,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _statusLabel,
                          style: TextStyle(
                            fontSize: 12,
                            color: _statusColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!therapist.isFree && therapist.freeInMinutes > 0)
                Icon(
                  Icons.schedule_outlined,
                  size: 16,
                  color: const Color(0xFFF59E0B),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WalkInZoneCard extends StatelessWidget {
  final _WalkInZone zone;
  final bool isSelected;
  final VoidCallback onTap;

  const _WalkInZoneCard({
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _WalkInRoomImage(imageUrl: zone.imageUrl, roomType: zone.type),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    zone.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${zone.freeSlots} of ${zone.totalSlots} free',
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B6B6B)),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: zone.isAvailableNow
                        ? const Color(0xFF4CAF50)
                        : const Color(0xFFE53935),
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  zone.isAvailableNow ? 'Available Now' : 'Fully Occupied',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: zone.isAvailableNow
                        ? const Color(0xFF4CAF50)
                        : const Color(0xFFE53935),
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

class _WalkInRoomUnitCard extends StatelessWidget {
  final RoomUnitAvailability unit;
  final bool isSelected;
  final VoidCallback onTap;

  const _WalkInRoomUnitCard({
    required this.unit,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = switch (unit.status) {
      'occupied' => const Color(0xFFDC2626),
      'cleaning' => const Color(0xFFF59E0B),
      _ when !unit.availableForRequestedTime => const Color(0xFFF59E0B),
      _ => const Color(0xFF059669),
    };
    var availableLabel = 'Available now';
    if (unit.status != 'available' || !unit.availableForRequestedTime) {
      final raw = unit.availableAt;
      if (raw != null && raw.isNotEmpty) {
        try {
          final state = unit.status == 'cleaning'
              ? 'Cleaning'
              : unit.status == 'occupied'
              ? 'Occupied'
              : 'Next opening';
          availableLabel =
              '$state ${unit.status == 'available' ? 'at' : 'until'} ${DateFormat('h:mm a').format(DateFormat('HH:mm').parse(raw))}';
        } catch (_) {
          availableLabel = 'Next opening at $raw';
        }
      } else {
        availableLabel = unit.status == 'cleaning'
            ? 'Cleaning'
            : unit.status == 'occupied'
            ? 'Occupied'
            : 'Unavailable for this service window';
      }
    }
    return Material(
      color: isSelected ? const Color(0xFFE8F5F5) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isSelected ? const Color(0xFF1B6B72) : const Color(0xFFE5E7EB),
          width: isSelected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          child: Row(
            children: [
              Icon(Icons.meeting_room_outlined, color: color, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      unit.name,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      availableLabel,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                const Icon(Icons.check_circle, color: Color(0xFF1B6B72)),
            ],
          ),
        ),
      ),
    );
  }
}

class _WalkInRoomImage extends StatelessWidget {
  final String imageUrl;
  final String roomType;

  const _WalkInRoomImage({required this.imageUrl, required this.roomType});

  IconData get _fallbackIcon => roomType == 'foot_chair'
      ? Icons.chair_outlined
      : Icons.meeting_room_outlined;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 36,
        height: 36,
        color: const Color(0xFFEDE7F6),
        child: imageUrl.isEmpty
            ? Icon(_fallbackIcon, color: const Color(0xFF7C3AED), size: 21)
            : Image.network(
                imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, error, stackTrace) => Icon(
                  _fallbackIcon,
                  color: const Color(0xFF7C3AED),
                  size: 21,
                ),
              ),
      ),
    );
  }
}

class _WalkInSummaryRow extends StatelessWidget {
  final String label, value;
  final Color? valueColor;

  const _WalkInSummaryRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
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
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: valueColor ?? const Color(0xFF1A1A2E),
            ),
          ),
          const Divider(height: 14, color: Color(0xFFF0F0F0)),
        ],
      ),
    );
  }
}

class _WalkInPaxSummaryCard extends StatelessWidget {
  final int index;
  final _WalkInAllocation? allocation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const _WalkInPaxSummaryCard({
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
                        ? 'Tap to configure service, staff, zone, and time'
                        : '${item.therapist.name} - ${item.zone.name}',
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
                        : '${item.startTime.timeLabel} - RM ${item.servicePrice.toStringAsFixed(2)}',
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

class _PaymentRow extends StatelessWidget {
  final String label, value;
  const _PaymentRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, color: Color(0xFF6B6B6B)),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A2E)),
        ),
      ],
    );
  }
}

class _PaymentMethodCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _PaymentMethodCard({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 20),
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
              size: 28,
              color: isSelected ? Colors.white : const Color(0xFF6B6B6B),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isSelected ? Colors.white : const Color(0xFF1A1A2E),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallBadge2 extends StatelessWidget {
  final String label;
  final Color bg, color;

  const _SmallBadge2({
    required this.label,
    required this.bg,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }
}
