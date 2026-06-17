import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/appointment_repository.dart';
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

// ── Models ────────────────────────────────────────────────────────

class _Service {
  final String id, name, imageUrl, roomType, category;
  final int duration;
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

  const _Therapist({
    required this.id,
    required this.name,
    required this.gender,
    required this.imageUrl,
    required this.isFree,
    required this.busyUntil,
  });

  factory _Therapist.fromMap(Map<String, dynamic> d) {
    return _Therapist(
      id: d['id']?.toString() ?? '',
      name: d['name']?.toString() ?? '',
      gender: d['gender']?.toString().trim().toLowerCase() ?? '',
      imageUrl:
          (d['imageUrl'] ?? d['photoUrl'] ?? d['profileImageUrl'])
              ?.toString()
              .trim() ??
          '',
      isFree: _isActiveDoc({'isActive': d['availabilityStatus'] ?? true}),
      busyUntil: d['busyUntil']?.toString() ?? '',
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
  final String id, name, type, floor, imageUrl;
  final int totalSlots, freeSlots;

  const _RoomZone({
    required this.id,
    required this.name,
    required this.type,
    required this.floor,
    required this.imageUrl,
    required this.totalSlots,
    required this.freeSlots,
  });
}

class _TimeSlot {
  final String start, end;
  final bool isRecommended, isAvailable;

  const _TimeSlot({
    required this.start,
    required this.end,
    required this.isRecommended,
    required this.isAvailable,
  });

  String get label => '$start–$end';
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

// ── Main Screen ───────────────────────────────────────────────────

class NewAppointmentScreen extends StatefulWidget {
  final String userRole;
  const NewAppointmentScreen({super.key, required this.userRole});

  @override
  State<NewAppointmentScreen> createState() => _NewAppointmentScreenState();
}

class _NewAppointmentScreenState extends State<NewAppointmentScreen> {
  final _appointmentRepository = AppointmentRepository();
  final _customerRepository = CustomerRepository();
  final _roomRepository = RoomRepository();
  final _serviceRepository = ServiceRepository();
  final _therapistRepository = TherapistRepository();

  // State
  DateTime _selectedDate = DateTime.now();
  _Customer? _selectedCustomer;
  final List<_Service> _selectedServices = [];
  _Therapist? _selectedTherapist;
  _RoomZone? _selectedRoom;
  _TimeSlot? _selectedSlot;
  String _serviceTab = 'Services';
  bool _summaryExpanded = false;
  bool _isConfirming = false;
  bool _loadingSlots = false;

  // Data
  List<_Service> _services = [];
  List<_Therapist> _therapists = [];
  List<_RoomZone> _rooms = [];
  List<_TimeSlot> _slots = [];
  List<_Customer> _customers = [];
  List<_Customer> _filteredCustomers = [];
  bool _loadingData = true;
  String? _serviceLoadError;

  final _customerSearchController = TextEditingController();

  // CSP — operating hours
  static const int _openHour = 9;
  static const int _closeHour = 21;
  static const int _slotStep = 30; // minutes

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
    } finally {
      setState(() => _loadingData = false);
    }
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

  Future<void> _loadTherapists() async {
    final rows = await _therapistRepository.getActiveTherapists();
    setState(() {
      _therapists = rows.map((d) => _Therapist.fromMap(d)).toList();
    });
  }

  Future<void> _loadRooms() async {
    final rows = await _roomRepository.getActiveRooms();

    final zones = <_RoomZone>[];
    for (final d in rows) {
      if (!_isActiveDoc(d)) continue;
      final totalSlots = _parseInt(d['totalSlots'], fallback: 1);
      zones.add(
        _RoomZone(
          id: d['id']?.toString() ?? '',
          name: d['name'] ?? '',
          type: _normalizeRoomType(d['type'] ?? d['roomType']),
          floor: d['floor'] ?? '',
          imageUrl: (d['imageUrl'] ?? d['image'])?.toString().trim() ?? '',
          totalSlots: totalSlots,
          freeSlots: totalSlots,
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

    setState(() {
      _customers = [..._customers, savedCustomer]
        ..sort((a, b) => a.name.compareTo(b.name));
      _filteredCustomers = _customers;
      _selectedCustomer = savedCustomer;
      _customerSearchController.text = savedCustomer.name;
    });
  }

  void _selectCustomer(_Customer customer) {
    setState(() {
      _selectedCustomer = customer;
      _customerSearchController.text = customer.name;
      _filteredCustomers = _customers;
    });
  }

  void _selectGuestCustomer() {
    setState(() {
      _selectedCustomer = _Customer.guest;
      _customerSearchController.clear();
      _filteredCustomers = _customers;
    });
  }

  void _clearCustomerSelection() {
    setState(() {
      _selectedCustomer = null;
      _customerSearchController.clear();
      _filteredCustomers = _customers;
    });
  }

  // ── CSP — Slot Generation ──────────────────────────────────────

  Future<void> _generateSlots() async {
    if (_selectedServices.isEmpty) return;
    if (_selectedTherapist == null) return;
    if (_selectedRoom == null) return;

    if (mounted) {
      setState(() => _loadingSlots = true);
    }

    final duration = _serviceDuration;

    try {
      final open = _openHour * 60;
      final close = _closeHour * 60;
      final slots = <_TimeSlot>[];
      var cursor = open;
      var recommendedCount = 0;

      while (cursor + duration <= close) {
        final slotEnd = cursor + duration;
        slots.add(
          _TimeSlot(
            start: _minutesToTime(cursor),
            end: _minutesToTime(slotEnd),
            isRecommended: recommendedCount < 3,
            isAvailable: true,
          ),
        );
        recommendedCount++;
        cursor += _slotStep;
      }

      if (mounted) setState(() => _slots = slots);
    } finally {
      if (mounted) setState(() => _loadingSlots = false);
    }
  }

  int _timeToMinutes(String t) {
    final p = t.split(':');
    return int.parse(p[0]) * 60 + int.parse(p[1]);
  }

  String _minutesToTime(int m) {
    final h = (m ~/ 60).toString().padLeft(2, '0');
    final min = (m % 60).toString().padLeft(2, '0');
    return '$h:$min';
  }

  // ── Selection Handlers ─────────────────────────────────────────

  void _onServiceSelected(_Service s) {
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
      _selectedRoom = null;
      _selectedSlot = null;
      _slots = [];
      _loadingSlots = false;
    });
  }

  void _onTherapistSelected(_Therapist t) {
    setState(() {
      _selectedTherapist = t;
      _selectedSlot = null;
      _slots = [];
      _loadingSlots = false;
    });
    if (_selectedServices.isNotEmpty && _selectedRoom != null) _generateSlots();
  }

  void _onRoomSelected(_RoomZone r) {
    setState(() {
      _selectedRoom = r;
      _selectedSlot = null;
      _slots = [];
      _loadingSlots = false;
    });
    if (_selectedServices.isNotEmpty && _selectedTherapist != null) {
      _generateSlots();
    }
  }

  void _setSelectedDate(DateTime date) {
    setState(() {
      _selectedDate = _stripDate(date);
      _selectedSlot = null;
      _slots = [];
      _loadingSlots = false;
    });
    _loadRooms();
    if (_selectedServices.isNotEmpty &&
        _selectedTherapist != null &&
        _selectedRoom != null) {
      _generateSlots();
    }
  }

  _Service? get _primaryService =>
      _selectedServices.isEmpty ? null : _selectedServices.first;

  int get _serviceDuration => _selectedServices.fold(
    0,
    (total, service) => total + service.duration,
  );

  double get _servicePrice =>
      _selectedServices.fold(0, (total, service) => total + service.price);

  String get _serviceNameSummary {
    if (_selectedServices.isEmpty) return '';
    if (_selectedServices.length == 1) return _selectedServices.first.name;
    return _selectedServices.map((service) => service.name).join(', ');
  }

  List<Map<String, dynamic>> get _serviceItems => _selectedServices
      .map(
        (service) => {
          'id': service.id,
          'name': service.name,
          'category': service.category,
          'duration': service.duration,
          'price': service.price,
          'therapistCommission': service.therapistCommission,
          'counterCommission': service.counterCommission,
        },
      )
      .toList();

  String get _requiredRoomType {
    final types = _selectedServices
        .map((service) => service.roomType)
        .where((type) => type.isNotEmpty)
        .toSet();
    return types.length == 1 ? types.first : '';
  }

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

  bool get _canConfirm =>
      _selectedCustomer != null &&
      _selectedServices.isNotEmpty &&
      _selectedTherapist != null &&
      _selectedRoom != null &&
      _selectedSlot != null;

  List<String> get _missingSlotRequirements {
    final missing = <String>[];
    if (_selectedServices.isEmpty) missing.add('service');
    if (_selectedTherapist == null) missing.add('therapist');
    if (_selectedRoom == null) missing.add('room');
    return missing;
  }

  Future<void> _confirmAppointment() async {
    if (!_canConfirm) return;
    setState(() => _isConfirming = true);

    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final endTime = _minutesToTime(
        _timeToMinutes(_selectedSlot!.start) + _serviceDuration,
      );

      final slotStart = _timeToMinutes(_selectedSlot!.start);
      final slotEnd = _timeToMinutes(endTime);
      if (slotStart >= slotEnd) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Invalid appointment time selected'),
              backgroundColor: Color(0xFFE53935),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }

      await _appointmentRepository.createAppointment({
        'customerId': _selectedCustomer!.id,
        'therapistId': _selectedTherapist!.id,
        'roomId': _selectedRoom!.id,
        'serviceId': _primaryService!.id,
        'serviceName': _serviceNameSummary,
        'serviceItems': _serviceItems,
        'itemCount': _selectedServices.length,
        'date': dateStr,
        'startTime': _selectedSlot!.start,
        'endTime': endTime,
        'status': 'pending',
        'totalPrice': _servicePrice,
        'type': 'appointment',
        'createdAt': DateTime.now().toIso8601String(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Appointment created as pending'),
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
            content: Text('Error: $e'),
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

  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 900;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F0F0),
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
          _TabletHeader(onBack: () => Navigator.pop(context)),
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
                          title: 'Date & Customer',
                          child: _buildDateCustomerSection(),
                        ),
                        const SizedBox(height: 16),
                        _StepCard(
                          number: 2,
                          title: 'Service Selection',
                          child: _buildServiceSection(),
                        ),
                        const SizedBox(height: 16),
                        _StepCard(
                          number: 3,
                          title: 'Therapist & Room',
                          child: _buildTherapistRoomSection(isTablet: true),
                        ),
                        const SizedBox(height: 16),
                        _StepCard(
                          number: 4,
                          title: 'Recommended Time Slots',
                          badge: _AiBadge(),
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
          _PhoneHeader(onBack: () => Navigator.pop(context)),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                children: [
                  _StepCard(
                    number: 1,
                    title: 'Date & Customer',
                    child: _buildDateCustomerSection(),
                  ),
                  const SizedBox(height: 12),
                  _StepCard(
                    number: 2,
                    title: 'Service Selection',
                    child: _buildServiceSection(),
                  ),
                  const SizedBox(height: 12),
                  _StepCard(
                    number: 3,
                    title: 'Therapist & Room',
                    child: _buildTherapistRoomSection(isTablet: false),
                  ),
                  const SizedBox(height: 12),
                  _StepCard(
                    number: 4,
                    title: 'Recommended Time Slots',
                    badge: _AiBadge(),
                    child: _buildTimeSlotsSection(),
                  ),
                  const SizedBox(height: 120),
                ],
              ),
            ),
          ),
          // Sticky bottom bar
          _PhoneBottomBar(
            serviceName: _selectedServices.isEmpty ? null : _serviceNameSummary,
            serviceDuration: _serviceDuration,
            servicePrice: _servicePrice,
            isExpanded: _summaryExpanded,
            onToggle: () =>
                setState(() => _summaryExpanded = !_summaryExpanded),
            canConfirm: _canConfirm,
            isConfirming: _isConfirming,
            onConfirm: _confirmAppointment,
            selectedDate: _selectedDate,
            selectedCustomer: _selectedCustomer,
            selectedTherapist: _selectedTherapist,
            selectedRoom: _selectedRoom,
            selectedSlot: _selectedSlot,
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
        _GuestCustomerOption(
          isSelected: _selectedCustomer?.isGuest ?? false,
          onTap: _selectGuestCustomer,
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
      ],
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
      ],
    );
  }

  Widget _buildTherapistRoomSection({required bool isTablet}) {
    final compatibleRooms = _rooms
        .where(
          (r) => _requiredRoomType.isEmpty || r.type == _requiredRoomType,
        )
        .toList();

    if (isTablet) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SubSectionLabel('Select Therapist'),
          const SizedBox(height: 10),
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
                isDisabled: false,
                onTap: () => _onTherapistSelected(t),
              );
            },
          ),
          const SizedBox(height: 18),
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
        ],
      );
    }

    // Phone — stacked
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SubSectionLabel('Select Therapist'),
        const SizedBox(height: 10),
        ..._therapists.map(
          (t) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _TherapistCard(
              therapist: t,
              isSelected: _selectedTherapist?.id == t.id,
              isDisabled: false,
              onTap: () => _onTherapistSelected(t),
            ),
          ),
        ),
        const SizedBox(height: 16),
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
      ],
    );
  }

  Widget _buildTimeSlotsSection() {
    final missing = _missingSlotRequirements;
    if (missing.isNotEmpty) {
      return _LockedTimeSlotsPanel(missing: missing);
    }

    if (_loadingSlots) {
      return const _SlotsLoadingPanel();
    }

    final recommended = _slots
        .where((s) => s.isRecommended && s.isAvailable)
        .toList();
    final standard = _slots
        .where((s) => !s.isRecommended && s.isAvailable)
        .toList();
    final unavailable = _slots.where((s) => !s.isAvailable).toList();

    if (_slots.isEmpty) {
      return const _NoTimeSlotsPanel();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Slots filtered based on therapist and room availability',
          style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
        ),
        const SizedBox(height: 14),

        // Recommended
        if (recommended.isNotEmpty) ...[
          Row(
            children: const [
              Text('⭐ ', style: TextStyle(fontSize: 14)),
              Text(
                'Recommended',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              Text(
                ' — Minimizes Schedule Gaps',
                style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _SlotGrid(
            slots: recommended,
            selectedSlot: _selectedSlot,
            recommended: true,
            onSelect: (s) => setState(() => _selectedSlot = s),
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
            slots: standard,
            selectedSlot: _selectedSlot,
            recommended: false,
            onSelect: (s) => setState(() => _selectedSlot = s),
          ),
          const SizedBox(height: 14),
        ],

        // Unavailable
        if (unavailable.isNotEmpty) ...[
          const Text(
            'Unavailable',
            style: TextStyle(fontSize: 13, color: Color(0xFF9E9E9E)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: unavailable
                .map((s) => _UnavailableChip(label: s.label))
                .toList(),
          ),
          const SizedBox(height: 8),
          const Text(
            'Therapist or room already booked at these times',
            style: TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
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
          _SummaryRow(label: 'Room / Zone', value: _selectedRoom?.name ?? '—'),
          _SummaryRow(label: 'Time Slot', value: _selectedSlot?.label ?? '—'),

          if (_selectedServices.isNotEmpty) ...[
            const Divider(height: 28, color: Color(0xFFEEEEEE)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Estimated Total',
                  style: TextStyle(fontSize: 13, color: Color(0xFF9E9E9E)),
                ),
                Text(
                  'RM ${_servicePrice.toStringAsFixed(2)}',
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
              '$_serviceNameSummary - $_serviceDuration min',
              style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
            ),
          ],

          const SizedBox(height: 28),

          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _canConfirm && !_isConfirming
                  ? _confirmAppointment
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
              label: const Text(
                'Confirm Appointment',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
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
  final VoidCallback onBack;
  const _TabletHeader({required this.onBack});

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
              const Text(
                'New Appointment',
                style: TextStyle(
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
  final VoidCallback onBack;
  const _PhoneHeader({required this.onBack});

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
          const Text(
            'New Appointment',
            style: TextStyle(
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
    final data = {
      'name': _nameController.text.trim(),
      'phone': _phoneController.text.trim(),
      'gender': _genderController.text.trim(),
      'dateOfBirth': _dobController.text.trim(),
      'joinDate': _joinDateController.text.trim(),
      'notes': _notesController.text.trim(),
    };

    try {
      final savedRow = await _customerRepository.addCustomer(data);
      final customerId = savedRow['id']?.toString() ?? '';
      if (!mounted) return;
      Navigator.of(context).pop(widget.customerBuilder(customerId, data));
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to save customer'),
          backgroundColor: Color(0xFFE53935),
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

  const _QuickGenderDropdown({
    required this.label,
    required this.controller,
  });

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
  final Widget? badge;

  const _StepCard({
    required this.number,
    required this.title,
    required this.child,
    this.badge,
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
              if (badge != null) ...[const SizedBox(width: 8), badge!],
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _AiBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF59E0B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('⚡ ', style: TextStyle(fontSize: 11)),
          Text(
            'AI',
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
  final VoidCallback onTap;
  const _DateArrowBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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

class _GuestCustomerOption extends StatelessWidget {
  final bool isSelected;
  final VoidCallback onTap;

  const _GuestCustomerOption({required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF1B6B72).withValues(alpha: 0.06)
                : const Color(0xFFF8F8F8),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
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
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Guest',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'No customer profile needed',
                      style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                const Icon(
                  Icons.check_circle,
                  color: Color(0xFF1B6B72),
                  size: 20,
                ),
            ],
          ),
        ),
      ),
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
            hintText: 'Search customer...',
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
  final bool isDisabled;
  final VoidCallback? onTap;

  const _TherapistCard({
    required this.therapist,
    required this.isSelected,
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
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: therapist.isFree
                            ? const Color(0xFFE8F5E9)
                            : const Color(0xFFFFF7ED),
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
                              color: therapist.isFree
                                  ? const Color(0xFF4CAF50)
                                  : const Color(0xFFF59E0B),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            therapist.isFree
                                ? 'Free'
                                : therapist.busyUntil.isNotEmpty
                                ? 'Busy until ${therapist.busyUntil}'
                                : 'Busy',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: therapist.isFree
                                  ? const Color(0xFF2E7D32)
                                  : const Color(0xFFC2410C),
                            ),
                          ),
                        ],
                      ),
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
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Time slots will appear here',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Select the required booking details first. Availability is calculated only after the service, therapist, and room are selected.',
                      style: TextStyle(
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
            children: [
              _RequirementChip(label: 'Date selected', complete: true),
              _RequirementChip(
                label: 'Service',
                complete: !_isMissing('service'),
              ),
              _RequirementChip(
                label: 'Therapist',
                complete: !_isMissing('therapist'),
              ),
              _RequirementChip(label: 'Room', complete: !_isMissing('room')),
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
  const _NoTimeSlotsPanel();

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
      child: const Row(
        children: [
          Icon(Icons.event_busy_outlined, color: Color(0xFFB45309), size: 22),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'No available slots for this combination. Try another date, therapist, or room.',
              style: TextStyle(
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

class _SlotGrid extends StatelessWidget {
  final List<_TimeSlot> slots;
  final _TimeSlot? selectedSlot;
  final bool recommended;
  final ValueChanged<_TimeSlot> onSelect;

  const _SlotGrid({
    required this.slots,
    required this.selectedSlot,
    required this.recommended,
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
                      onTap: () => onSelect(slot),
                    )
                  : _SlotChip(
                      slot: slot,
                      isSelected: isSelected,
                      onTap: () => onSelect(slot),
                    ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _SlotTile extends StatelessWidget {
  final _TimeSlot slot;
  final bool isSelected;
  final VoidCallback onTap;

  const _SlotTile({
    required this.slot,
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
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              slot.label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: isSelected ? Colors.white : const Color(0xFF1B6B72),
              ),
            ),
            Text(
              'Best Fit',
              style: TextStyle(
                fontSize: 12,
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
  final VoidCallback onTap;

  const _SlotChip({
    required this.slot,
    required this.isSelected,
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
          slot.label,
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

class _UnavailableChip extends StatelessWidget {
  final String label;
  const _UnavailableChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFFBDBDBD),
              decoration: TextDecoration.lineThrough,
            ),
          ),
          const SizedBox(width: 4),
          const Text(
            '✕',
            style: TextStyle(fontSize: 10, color: Color(0xFFBDBDBD)),
          ),
        ],
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

// ── Phone Bottom Bar ──────────────────────────────────────────────

class _PhoneBottomBar extends StatelessWidget {
  final String? serviceName;
  final int serviceDuration;
  final double servicePrice;
  final bool isExpanded;
  final VoidCallback onToggle;
  final bool canConfirm;
  final bool isConfirming;
  final VoidCallback onConfirm;
  final DateTime selectedDate;
  final _Customer? selectedCustomer;
  final _Therapist? selectedTherapist;
  final _RoomZone? selectedRoom;
  final _TimeSlot? selectedSlot;

  const _PhoneBottomBar({
    required this.serviceName,
    required this.serviceDuration,
    required this.servicePrice,
    required this.isExpanded,
    required this.onToggle,
    required this.canConfirm,
    required this.isConfirming,
    required this.onConfirm,
    required this.selectedDate,
    required this.selectedCustomer,
    required this.selectedTherapist,
    required this.selectedRoom,
    required this.selectedSlot,
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
                    hasServices
                        ? '$serviceName - $serviceDuration min'
                        : '—',
                  ),
                  _MiniRow('Therapist', selectedTherapist?.name ?? '—'),
                  _MiniRow('Zone', selectedRoom?.name ?? '—'),
                  _MiniRow('Time', selectedSlot?.label ?? '—'),
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
                    label: const Text(
                      'Confirm Appointment',
                      style: TextStyle(
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
