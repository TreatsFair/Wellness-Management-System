import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

String _normalizeRoomType(Object? value) {
  final raw = value?.toString().trim().toLowerCase() ?? '';
  if (raw.isEmpty || raw == '-') return '';
  final normalized = raw.replaceAll(RegExp(r'[\s-]+'), '_');
  if (normalized.contains('body')) return 'body_room';
  if (normalized.contains('foot')) return 'foot_chair';
  return normalized;
}

String _normalizeServiceToken(Object? value) {
  return value?.toString().trim().toLowerCase().replaceAll(
        RegExp(r'[\s-]+'),
        '_',
      ) ??
      '';
}

List<String> _readSpecializations(Map<String, dynamic> data) {
  final raw = data['specializations'] ?? data['specialization'];
  if (raw is Iterable) {
    return raw.map(_normalizeServiceToken).where((s) => s.isNotEmpty).toList();
  }
  if (raw is String) {
    return raw
        .split(',')
        .map(_normalizeServiceToken)
        .where((s) => s.isNotEmpty)
        .toList();
  }
  return const [];
}

// ── Models ────────────────────────────────────────────────────────

class _Service {
  final String id, name, emoji, roomType, category;
  final int duration;
  final double price;

  const _Service({
    required this.id,
    required this.name,
    required this.emoji,
    required this.roomType,
    required this.category,
    required this.duration,
    required this.price,
  });

  factory _Service.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return _Service(
      id: doc.id,
      name: d['name']?.toString() ?? '',
      emoji: d['iconEmoji'] ?? '💆',
      roomType: _normalizeRoomType(d['roomType']),
      category: d['category']?.toString().trim() ?? 'Services',
      duration: _parseInt(d['duration'], fallback: 60),
      price: _parseDouble(d['price']),
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

class _Therapist {
  final String id, name;
  final bool isFree;
  final String busyUntil;
  final List<String> specializations;

  const _Therapist({
    required this.id,
    required this.name,
    required this.isFree,
    required this.busyUntil,
    required this.specializations,
  });

  factory _Therapist.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return _Therapist(
      id: doc.id,
      name: d['name'] ?? '',
      isFree: d['availabilityStatus'] ?? true,
      busyUntil: d['busyUntil'] ?? '',
      specializations: _readSpecializations(d),
    );
  }

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

  bool canDoService(String roomType) {
    final serviceRoomType = _normalizeRoomType(roomType);
    if (serviceRoomType.isEmpty) return true;
    final normalized = specializations.toSet();
    if (normalized.isEmpty) return true;
    if (serviceRoomType == 'body_room') {
      return normalized.contains('body_massage') ||
          normalized.contains('body_room');
    }
    if (serviceRoomType == 'foot_chair') {
      return normalized.contains('foot_therapy') ||
          normalized.contains('foot_massage') ||
          normalized.contains('foot_chair');
    }
    return false;
  }
}

class _RoomZone {
  final String id, name, type, floor;
  final int totalSlots, freeSlots;

  const _RoomZone({
    required this.id,
    required this.name,
    required this.type,
    required this.floor,
    required this.totalSlots,
    required this.freeSlots,
  });

  String get icon => type == 'foot_chair' ? '🪑' : '🛏';
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

  factory _Customer.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return _Customer(
      id: doc.id,
      name: d['name'] ?? '',
      phone: d['phone'] ?? '',
    );
  }
}

// ── Main Screen ───────────────────────────────────────────────────

class NewAppointmentScreen extends StatefulWidget {
  final String userRole;
  const NewAppointmentScreen({super.key, required this.userRole});

  @override
  State<NewAppointmentScreen> createState() => _NewAppointmentScreenState();
}

class _NewAppointmentScreenState extends State<NewAppointmentScreen> {
  // State
  DateTime _selectedDate = DateTime.now();
  _Customer? _selectedCustomer;
  _Service? _selectedService;
  _Therapist? _selectedTherapist;
  _RoomZone? _selectedRoom;
  _TimeSlot? _selectedSlot;
  String _serviceTab = 'Services';
  bool _summaryExpanded = false;
  bool _isConfirming = false;

  // Data
  List<_Service> _services = [];
  List<_Therapist> _therapists = [];
  List<_RoomZone> _rooms = [];
  List<_TimeSlot> _slots = [];
  List<_Customer> _customers = [];
  List<_Customer> _filteredCustomers = [];
  bool _loadingData = true;
  int _serviceDocCount = 0;
  int _serviceActiveCount = 0;
  String? _serviceLoadError;
  List<String> _serviceDebugLines = [];

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
      final snap = await FirebaseFirestore.instance
          .collection('services')
          .get(const GetOptions(source: Source.server));
      final services = <_Service>[];
      final debugLines = <String>[];

      for (final doc in snap.docs) {
        final d = doc.data();
        final active = d['isActive'];
        debugLines.add(
          '${doc.id}: isActive=${_debugValue(active)}, '
          'category=${_debugValue(d['category'])}, '
          'roomType=${_debugValue(d['roomType'])}, '
          'duration=${_debugValue(d['duration'])}, '
          'price=${_debugValue(d['price'])}',
        );

        if (active == true) {
          services.add(_Service.fromDoc(doc));
        }
      }

      debugPrint(
        'Quick Book services debug: ${snap.docs.length} docs, '
        '${services.length} active',
      );
      for (final line in debugLines) {
        debugPrint('Quick Book service: $line');
      }

      setState(() {
        _services = services;
        _serviceDocCount = snap.docs.length;
        _serviceActiveCount = services.length;
        _serviceLoadError = null;
        _serviceDebugLines = debugLines;
      });
    } catch (e) {
      debugPrint('Quick Book services load failed: $e');
      setState(() {
        _services = [];
        _serviceDocCount = 0;
        _serviceActiveCount = 0;
        _serviceLoadError = e.toString();
        _serviceDebugLines = [];
      });
    }
  }

  String _debugValue(Object? value) {
    if (value == null) return 'null';
    return '"$value" (${value.runtimeType})';
  }

  Future<void> _loadTherapists() async {
    final snap = await FirebaseFirestore.instance
        .collection('therapists')
        .get();
    setState(() {
      _therapists = snap.docs.map((d) => _Therapist.fromDoc(d)).toList();
    });
  }

  Future<void> _loadRooms() async {
    final snap = await FirebaseFirestore.instance
        .collection('rooms')
        .where('isActive', isEqualTo: true)
        .get();

    final zones = <_RoomZone>[];
    for (final doc in snap.docs) {
      final d = doc.data();
      final totalSlots = _parseInt(d['totalSlots'], fallback: 1);
      final freeSlots = await _countFreeSlots(
        doc.id,
        totalSlots,
        _selectedDate,
      );
      zones.add(
        _RoomZone(
          id: doc.id,
          name: d['name'] ?? '',
          type: _normalizeRoomType(d['type'] ?? d['roomType']),
          floor: d['floor'] ?? '',
          totalSlots: totalSlots,
          freeSlots: freeSlots,
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

  Future<int> _countFreeSlots(
    String roomId,
    int totalSlots,
    DateTime date,
  ) async {
    final dateStr = DateFormat('yyyy-MM-dd').format(date);
    final snap = await FirebaseFirestore.instance
        .collection('appointments')
        .where('roomId', isEqualTo: roomId)
        .where('date', isEqualTo: dateStr)
        .where('status', whereIn: ['confirmed', 'in_progress'])
        .get();
    return (totalSlots - snap.docs.length).clamp(0, totalSlots);
  }

  Future<void> _loadCustomers() async {
    final snap = await FirebaseFirestore.instance
        .collection('customers')
        .orderBy('name')
        .get();
    setState(() {
      _customers = snap.docs.map((d) => _Customer.fromDoc(d)).toList();
      _filteredCustomers = _customers;
    });
  }

  void _filterCustomers() {
    final q = _customerSearchController.text.toLowerCase();
    setState(() {
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

  // ── CSP — Slot Generation ──────────────────────────────────────

  Future<void> _generateSlots() async {
    if (_selectedService == null) return;
    if (_selectedTherapist == null) return;
    if (_selectedRoom == null) return;

    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
    final duration = _selectedService!.duration;

    // Fetch existing appointments for therapist and room on date
    final therapistSnap = await FirebaseFirestore.instance
        .collection('appointments')
        .where('therapistId', isEqualTo: _selectedTherapist!.id)
        .where('date', isEqualTo: dateStr)
        .where('status', whereIn: ['confirmed', 'in_progress'])
        .get();

    final roomSnap = await FirebaseFirestore.instance
        .collection('appointments')
        .where('roomId', isEqualTo: _selectedRoom!.id)
        .where('date', isEqualTo: dateStr)
        .where('status', whereIn: ['confirmed', 'in_progress'])
        .get();

    // Build blocked intervals
    final blocked = <Map<String, int>>[];
    for (final doc in [...therapistSnap.docs, ...roomSnap.docs]) {
      final d = doc.data();
      final start = _timeToMinutes(d['startTime'] ?? '09:00');
      final end = _timeToMinutes(d['endTime'] ?? '10:00');
      blocked.add({'start': start, 'end': end});
    }

    // Generate candidate slots
    final open = _openHour * 60;
    final close = _closeHour * 60;
    final slots = <_TimeSlot>[];
    var cursor = open;

    while (cursor + duration <= close) {
      final slotEnd = cursor + duration;
      final available = !_hasOverlap(cursor, slotEnd, blocked);

      if (available) {
        // Heuristic: slot is "recommended" if it starts right after
        // an existing booking (minimises gap)
        final isRecommended =
            blocked.any((b) => b['end'] == cursor) ||
            blocked.isEmpty && cursor == open;

        slots.add(
          _TimeSlot(
            start: _minutesToTime(cursor),
            end: _minutesToTime(slotEnd),
            isRecommended: isRecommended,
            isAvailable: true,
          ),
        );
      } else {
        // Show as unavailable
        slots.add(
          _TimeSlot(
            start: _minutesToTime(cursor),
            end: _minutesToTime(cursor + duration),
            isRecommended: false,
            isAvailable: false,
          ),
        );
      }
      cursor += _slotStep;
    }

    // If no recommended slots, mark first 3 available as recommended
    final hasRecommended = slots.any((s) => s.isRecommended && s.isAvailable);
    if (!hasRecommended) {
      int count = 0;
      for (var i = 0; i < slots.length && count < 3; i++) {
        if (slots[i].isAvailable) {
          slots[i] = _TimeSlot(
            start: slots[i].start,
            end: slots[i].end,
            isRecommended: true,
            isAvailable: true,
          );
          count++;
        }
      }
    }

    setState(() => _slots = slots);
  }

  bool _hasOverlap(int start, int end, List<Map<String, int>> blocked) {
    for (final b in blocked) {
      if (start < b['end']! && end > b['start']!) return true;
    }
    return false;
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
      _selectedService = s;
      _selectedTherapist = null;
      _selectedRoom = null;
      _selectedSlot = null;
      _slots = [];
    });
  }

  void _onTherapistSelected(_Therapist t) {
    setState(() {
      _selectedTherapist = t;
      _selectedSlot = null;
      _slots = [];
    });
    if (_selectedRoom != null) _generateSlots();
  }

  void _onRoomSelected(_RoomZone r) {
    setState(() {
      _selectedRoom = r;
      _selectedSlot = null;
      _slots = [];
    });
    if (_selectedTherapist != null) _generateSlots();
  }

  void _onDateChanged(int days) {
    setState(() {
      _selectedDate = _selectedDate.add(Duration(days: days));
      _selectedSlot = null;
      _slots = [];
    });
    _loadRooms();
    if (_selectedTherapist != null && _selectedRoom != null) {
      _generateSlots();
    }
  }

  // ── Confirm Appointment ────────────────────────────────────────

  bool get _canConfirm =>
      _selectedCustomer != null &&
      _selectedService != null &&
      _selectedTherapist != null &&
      _selectedRoom != null &&
      _selectedSlot != null;

  Future<void> _confirmAppointment() async {
    if (!_canConfirm) return;
    setState(() => _isConfirming = true);

    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final endTime = _minutesToTime(
        _timeToMinutes(_selectedSlot!.start) + _selectedService!.duration,
      );

      // CSP final validation before saving
      final therapistSnap = await FirebaseFirestore.instance
          .collection('appointments')
          .where('therapistId', isEqualTo: _selectedTherapist!.id)
          .where('date', isEqualTo: dateStr)
          .where('status', whereIn: ['confirmed', 'in_progress'])
          .get();

      final blocked = therapistSnap.docs.map((doc) {
        final d = doc.data();
        return {
          'start': _timeToMinutes(d['startTime'] ?? '09:00'),
          'end': _timeToMinutes(d['endTime'] ?? '10:00'),
        };
      }).toList();

      final slotStart = _timeToMinutes(_selectedSlot!.start);
      final slotEnd = _timeToMinutes(endTime);

      if (_hasOverlap(slotStart, slotEnd, blocked)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Conflict detected — slot no longer available'),
              backgroundColor: Color(0xFFE53935),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        await _generateSlots();
        return;
      }

      // Save to Firestore
      await FirebaseFirestore.instance.collection('appointments').add({
        'customerId': _selectedCustomer!.id,
        'therapistId': _selectedTherapist!.id,
        'roomId': _selectedRoom!.id,
        'serviceId': _selectedService!.id,
        'date': dateStr,
        'startTime': _selectedSlot!.start,
        'endTime': endTime,
        'status': 'confirmed',
        'totalPrice': _selectedService!.price,
        'type': 'appointment',
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Appointment confirmed successfully'),
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
      MediaQuery.of(context).size.width >= 600;

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
                          child: _buildServiceSection(isTablet: true),
                        ),
                        const SizedBox(height: 16),
                        _StepCard(
                          number: 3,
                          title: 'Therapist & Room',
                          child: _buildTherapistRoomSection(isTablet: true),
                        ),
                        if (_slots.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          _StepCard(
                            number: 4,
                            title: 'Recommended Time Slots',
                            badge: _AiBadge(),
                            child: _buildTimeSlotsSection(),
                          ),
                        ],
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
                    child: _buildServiceSection(isTablet: false),
                  ),
                  const SizedBox(height: 12),
                  _StepCard(
                    number: 3,
                    title: 'Therapist & Room',
                    child: _buildTherapistRoomSection(isTablet: false),
                  ),
                  if (_slots.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _StepCard(
                      number: 4,
                      title: 'Recommended Time Slots',
                      badge: _AiBadge(),
                      child: _buildTimeSlotsSection(),
                    ),
                  ],
                  const SizedBox(height: 120),
                ],
              ),
            ),
          ),
          // Sticky bottom bar
          _PhoneBottomBar(
            service: _selectedService,
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
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.calendar_today_outlined,
                      size: 16,
                      color: Color(0xFF1B6B72),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      formatted,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                  ],
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
          onSelect: (c) => setState(() {
            _selectedCustomer = c;
            _customerSearchController.text = c.name;
            _filteredCustomers = _customers;
          }),
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

  Widget _buildServiceSection({required bool isTablet}) {
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
          _ServiceDebugPanel(
            totalDocs: _serviceDocCount,
            activeDocs: _serviceActiveCount,
            visibleDocs: filtered.length,
            selectedTab: _serviceTab,
            error: _serviceLoadError,
            lines: _serviceDebugLines,
          ),
          const SizedBox(height: 12),
        ],
        // Service grid
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: isTablet ? 3 : 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: isTablet ? 1.6 : 1.3,
          ),
          itemCount: filtered.length,
          itemBuilder: (_, i) => _ServiceCard(
            service: filtered[i],
            isSelected: _selectedService?.id == filtered[i].id,
            showEmoji: isTablet,
            onTap: () => _onServiceSelected(filtered[i]),
          ),
        ),
      ],
    );
  }

  Widget _buildTherapistRoomSection({required bool isTablet}) {
    final compatibleTherapists = _therapists
        .where(
          (t) =>
              _selectedService == null ||
              t.canDoService(_selectedService!.roomType),
        )
        .toList();

    final incompatibleTherapists = _therapists
        .where(
          (t) =>
              _selectedService != null &&
              !t.canDoService(_selectedService!.roomType),
        )
        .toList();

    final compatibleRooms = _rooms
        .where(
          (r) =>
              _selectedService == null ||
              _selectedService!.roomType.isEmpty ||
              r.type == _selectedService!.roomType,
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
            itemCount:
                compatibleTherapists.length + incompatibleTherapists.length,
            itemBuilder: (_, i) {
              final isCompat = i < compatibleTherapists.length;
              final t = isCompat
                  ? compatibleTherapists[i]
                  : incompatibleTherapists[i - compatibleTherapists.length];
              return _TherapistCard(
                therapist: t,
                isSelected: _selectedTherapist?.id == t.id,
                isDisabled: !isCompat,
                onTap: isCompat ? () => _onTherapistSelected(t) : null,
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
        ...compatibleTherapists.map(
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
        ...incompatibleTherapists.map(
          (t) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _TherapistCard(
              therapist: t,
              isSelected: false,
              isDisabled: true,
              onTap: null,
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
    final recommended = _slots
        .where((s) => s.isRecommended && s.isAvailable)
        .toList();
    final standard = _slots
        .where((s) => !s.isRecommended && s.isAvailable)
        .toList();
    final unavailable = _slots.where((s) => !s.isAvailable).toList();

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
            value: _selectedService != null
                ? '${_selectedService!.name}\n${_selectedService!.duration} min · RM ${_selectedService!.price.toStringAsFixed(0)}'
                : '—',
          ),
          _SummaryRow(
            label: 'Therapist',
            value: _selectedTherapist?.name ?? '—',
          ),
          _SummaryRow(label: 'Room / Zone', value: _selectedRoom?.name ?? '—'),
          _SummaryRow(label: 'Time Slot', value: _selectedSlot?.label ?? '—'),

          if (_selectedService != null) ...[
            const Divider(height: 28, color: Color(0xFFEEEEEE)),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Estimated Total',
                  style: TextStyle(fontSize: 13, color: Color(0xFF9E9E9E)),
                ),
                Text(
                  'RM ${_selectedService!.price.toStringAsFixed(2)}',
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
              '${_selectedService!.name} · ${_selectedService!.duration} min',
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
      final docRef = await FirebaseFirestore.instance
          .collection('customers')
          .add(data);
      if (!mounted) return;
      Navigator.of(context).pop(widget.customerBuilder(docRef.id, data));
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
                _QuickCustomerField(
                  label: 'Gender',
                  controller: _genderController,
                  hint: 'Female / Male',
                ),
                const SizedBox(height: 14),
                _QuickCustomerField(
                  label: 'Date of Birth',
                  controller: _dobController,
                  hint: 'YYYY-MM-DD',
                  keyboardType: TextInputType.datetime,
                ),
                const SizedBox(height: 14),
                _QuickCustomerField(
                  label: 'Join Date',
                  controller: _joinDateController,
                  hint: 'YYYY-MM-DD',
                  keyboardType: TextInputType.datetime,
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

  const _QuickCustomerField({
    required this.label,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.requiredField = false,
    this.maxLines = 1,
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

class _CustomerSearchField extends StatelessWidget {
  final TextEditingController controller;
  final List<_Customer> customers;
  final _Customer? selected;
  final Function(_Customer) onSelect;

  const _CustomerSearchField({
    required this.controller,
    required this.customers,
    required this.selected,
    required this.onSelect,
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

class _ServiceDebugPanel extends StatelessWidget {
  final int totalDocs;
  final int activeDocs;
  final int visibleDocs;
  final String selectedTab;
  final String? error;
  final List<String> lines;

  const _ServiceDebugPanel({
    required this.totalDocs,
    required this.activeDocs,
    required this.visibleDocs,
    required this.selectedTab,
    required this.error,
    required this.lines,
  });

  @override
  Widget build(BuildContext context) {
    final preview = lines.take(5).toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFD54F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Service Debug',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Firestore docs: $totalDocs | isActive true: $activeDocs | '
            'visible in "$selectedTab": $visibleDocs',
            style: const TextStyle(fontSize: 12, color: Color(0xFF5F6B7A)),
          ),
          if (error != null) ...[
            const SizedBox(height: 6),
            Text(
              'Load error: $error',
              style: const TextStyle(fontSize: 12, color: Color(0xFFE53935)),
            ),
          ],
          if (preview.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final line in preview)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  line,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF5F6B7A),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final _Service service;
  final bool isSelected;
  final bool showEmoji;
  final VoidCallback onTap;

  const _ServiceCard({
    required this.service,
    required this.isSelected,
    required this.showEmoji,
    required this.onTap,
  });

  Color get _chipColor => service.roomType == 'body_room'
      ? const Color(0xFFEDE7F6)
      : service.roomType.isEmpty
      ? const Color(0xFFE8F5F5)
      : const Color(0xFFFFF9E6);

  Color get _chipTextColor => service.roomType == 'body_room'
      ? const Color(0xFF7C3AED)
      : service.roomType.isEmpty
      ? const Color(0xFF1B6B72)
      : const Color(0xFFC8963E);

  String get _chipLabel => service.roomType == 'body_room'
      ? 'Body Room'
      : service.roomType.isEmpty
      ? 'Any Room'
      : 'Foot Chair';

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showEmoji) ...[
                  Text(service.emoji, style: const TextStyle(fontSize: 22)),
                  const SizedBox(height: 6),
                ],
                Text(
                  service.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    _SmallBadge(
                      label: '${service.duration}m',
                      bg: const Color(0xFFE8F5F5),
                      color: const Color(0xFF1B6B72),
                    ),
                    const SizedBox(width: 6),
                    _SmallBadge(
                      label: 'RM ${service.price.toStringAsFixed(0)}',
                      bg: const Color(0xFFF5F5F5),
                      color: const Color(0xFF6B6B6B),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _SmallBadge(
                  label: _chipLabel,
                  bg: _chipColor,
                  color: _chipTextColor,
                ),
              ],
            ),
          ],
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
    final isTablet = MediaQuery.of(context).size.width >= 600;

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
              CircleAvatar(
                radius: isTablet ? 20 : 22,
                backgroundColor: isDisabled
                    ? const Color(0xFFBDBDBD)
                    : therapist.avatarColor,
                child: Text(
                  therapist.initials,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: isTablet ? 12 : 13,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      therapist.name,
                      style: const TextStyle(
                        fontSize: 13,
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
                            color: therapist.isFree
                                ? const Color(0xFF4CAF50)
                                : const Color(0xFFF59E0B),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    _SmallBadge(
                      label: therapist.specializations.contains('body_massage')
                          ? 'Body Massage'
                          : 'Foot Therapy',
                      bg: const Color(0xFFEDE7F6),
                      color: const Color(0xFF7C3AED),
                    ),
                  ],
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
            Text(zone.icon, style: const TextStyle(fontSize: 22)),
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
  final _Service? service;
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
    required this.service,
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
                    service != null
                        ? '${service!.name} · ${service!.duration} min'
                        : '—',
                  ),
                  _MiniRow('Therapist', selectedTherapist?.name ?? '—'),
                  _MiniRow('Zone', selectedRoom?.name ?? '—'),
                  _MiniRow('Time', selectedSlot?.label ?? '—'),
                  if (service != null) ...[
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
                          'RM ${(service!.price * 0.06).toStringAsFixed(2)}',
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
                          'RM ${(service!.price * 1.06).toStringAsFixed(2)}',
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
                          service != null
                              ? '${service!.name} · ${service!.duration} min'
                              : 'Select a service',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                      ),
                      Text(
                        service != null
                            ? 'RM ${service!.price.toStringAsFixed(2)}'
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
