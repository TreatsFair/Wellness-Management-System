import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/appointment_repository.dart';
import '../../data/repositories/customer_repository.dart';
import '../../data/repositories/room_repository.dart';
import '../../data/repositories/service_repository.dart';
import '../../data/repositories/therapist_repository.dart';
import '../../data/repositories/transaction_repository.dart';

DateTime _stripDate(DateTime date) => DateTime(date.year, date.month, date.day);

String _normalizeRoomType(Object? value) {
  final raw = value?.toString().trim().toLowerCase() ?? '';
  if (raw.isEmpty || raw == '-') return '';
  final normalized = raw.replaceAll(RegExp(r'[\s-]+'), '_');
  if (normalized.contains('body')) return 'body_room';
  if (normalized.contains('foot')) return 'foot_chair';
  return normalized;
}

// ── Models (reuse same pattern as appointment) ────────────────────

class _WalkInService {
  final String id, name, imageUrl, roomType, category;
  final int duration;
  final double price;

  const _WalkInService({
    required this.id,
    required this.name,
    required this.imageUrl,
    required this.roomType,
    required this.category,
    required this.duration,
    required this.price,
  });

  factory _WalkInService.fromMap(Map<String, dynamic> d) {
    return _WalkInService(
      id: d['id']?.toString() ?? '',
      name: d['name']?.toString() ?? '',
      imageUrl: (d['imageUrl'] ?? d['image'])?.toString().trim() ?? '',
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

bool _isActiveDoc(Map<String, dynamic> data) {
  final value = data['isActive'] ?? data['active'];
  if (value is bool) return value;
  if (value is String) return value.toLowerCase().trim() == 'true';
  return true;
}

class _WalkInTherapist {
  final String id, name;
  final bool isFree;
  final String busyUntil;
  final int freeInMinutes;

  const _WalkInTherapist({
    required this.id,
    required this.name,
    required this.isFree,
    required this.busyUntil,
    required this.freeInMinutes,
  });

  factory _WalkInTherapist.fromMap(
    Map<String, dynamic> d, {
    bool isFree = true,
    String busyUntil = '',
    int freeInMinutes = 0,
  }) {
    return _WalkInTherapist(
      id: d['id']?.toString() ?? '',
      name: d['name'] ?? '',
      isFree: isFree,
      busyUntil: busyUntil,
      freeInMinutes: freeInMinutes,
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
}

class _WalkInZone {
  final String id, name, type, floor, imageUrl;
  final int totalSlots, freeSlots;

  const _WalkInZone({
    required this.id,
    required this.name,
    required this.type,
    required this.floor,
    required this.imageUrl,
    required this.totalSlots,
    required this.freeSlots,
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

  static _WalkInCustomer get anonymous => const _WalkInCustomer(
    id: 'walk_in_guest',
    name: 'Guest',
    phone: '',
  );
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

// ── Main Screen ───────────────────────────────────────────────────

class WalkInPosScreen extends StatefulWidget {
  const WalkInPosScreen({super.key});

  @override
  State<WalkInPosScreen> createState() => _WalkInPosScreenState();
}

class _WalkInPosScreenState extends State<WalkInPosScreen> {
  final _appointmentRepository = AppointmentRepository();
  final _customerRepository = CustomerRepository();
  final _roomRepository = RoomRepository();
  final _serviceRepository = ServiceRepository();
  final _therapistRepository = TherapistRepository();
  final _transactionRepository = TransactionRepository();

  // Step tracking
  bool _showPayment = false;

  // Selections
  _WalkInCustomer? _selectedCustomer;
  _WalkInService? _selectedService;
  _WalkInTherapist? _selectedTherapist;
  _WalkInZone? _selectedZone;
  _StartTimeOption? _selectedStartTime;
  String _serviceTab = 'Services';
  String? _paymentMethod;
  bool _isConfirming = false;

  // Data
  List<_WalkInService> _services = [];
  List<_WalkInTherapist> _therapists = [];
  List<_WalkInZone> _zones = [];
  List<_WalkInCustomer> _customers = [];
  List<_WalkInCustomer> _filteredCustomers = [];
  List<_StartTimeOption> _startOptions = [];
  bool _loadingData = true;
  String? _serviceLoadError;

  final _searchController = TextEditingController();
  final _transactionNotesController = TextEditingController();

  // Receipt number
  late final String _receiptNumber;

  @override
  void initState() {
    super.initState();
    _receiptNumber = _generateReceiptNumber();
    _loadData();
    _searchController.addListener(_filterCustomers);
  }

  @override
  void dispose() {
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
        _loadServices(),
        _loadTherapistsLive(),
        _loadZonesLive(),
        _loadCustomers(),
      ]);
    } finally {
      setState(() => _loadingData = false);
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

  Future<void> _loadTherapistsLive() async {
    final now = DateTime.now();
    final today = DateFormat('yyyy-MM-dd').format(now);
    final nowTime =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';

    final therapistRows = await _therapistRepository.getActiveTherapists();

    final therapists = <_WalkInTherapist>[];

    for (final row in therapistRows) {
      // Check for current active appointment
      final activeAppointments = await _appointmentRepository
          .getActiveAppointmentsForTherapist(
            row['id']?.toString() ?? '',
            today,
          );

      bool isFree = true;
      String busyUntil = '';
      int freeInMinutes = 0;

      for (final d in activeAppointments) {
        final startTime = d['startTime'] as String? ?? '00:00';
        final endTime = d['endTime'] as String? ?? '00:00';

        if (startTime.compareTo(nowTime) <= 0 &&
            endTime.compareTo(nowTime) > 0) {
          isFree = false;
          busyUntil = endTime;

          // Calculate minutes until free
          final endParts = endTime.split(':');
          final endDateTime = DateTime(
            now.year,
            now.month,
            now.day,
            int.parse(endParts[0]),
            int.parse(endParts[1]),
          );
          freeInMinutes = endDateTime.difference(now).inMinutes;
          break;
        }
      }

      therapists.add(
        _WalkInTherapist.fromMap(
          row,
          isFree: isFree,
          busyUntil: busyUntil,
          freeInMinutes: freeInMinutes,
        ),
      );
    }

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
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());

    final roomRows = await _roomRepository.getActiveRooms();

    final zones = <_WalkInZone>[];

    for (final d in roomRows) {
      if (!_isActiveDoc(d)) continue;
      final totalSlots = _parseInt(d['totalSlots'], fallback: 1);

      final activeAppointments = await _appointmentRepository
          .getActiveAppointmentsForRoom(d['id']?.toString() ?? '', today);

      final freeSlots = (totalSlots - activeAppointments.length).clamp(
        0,
        totalSlots,
      );

      zones.add(
        _WalkInZone(
          id: d['id']?.toString() ?? '',
          name: d['name'] ?? '',
          type: _normalizeRoomType(d['type'] ?? d['roomType']),
          floor: d['floor'] ?? '',
          imageUrl: (d['imageUrl'] ?? d['image'])?.toString().trim() ?? '',
          totalSlots: totalSlots,
          freeSlots: freeSlots,
        ),
      );
    }

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
        _selectedService == null) {
      return;
    }

    final now = DateTime.now();
    final nowLabel = DateFormat('h:mm a').format(now);
    final options = <_StartTimeOption>[];

    // Check if we can start now
    if (_selectedTherapist!.isFree && _selectedZone!.isAvailableNow) {
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
      final nextTime = now.add(
        Duration(minutes: _selectedTherapist!.freeInMinutes),
      );
      options.add(
        _StartTimeOption(
          isNow: false,
          timeLabel: DateFormat('h:mm a').format(nextTime),
          subtitle: 'Queue slot',
        ),
      );
    } else if (_selectedTherapist!.isFree && !_selectedZone!.isAvailableNow) {
      // Room unavailable — suggest 30 min later
      final nextTime = now.add(const Duration(minutes: 30));
      options.add(
        _StartTimeOption(
          isNow: false,
          timeLabel: DateFormat('h:mm a').format(nextTime),
          subtitle: 'Queue slot',
        ),
      );
    }

    setState(() {
      _startOptions = options;
      _selectedStartTime = options.isNotEmpty ? options.first : null;
    });
  }

  // ── Selection Handlers ─────────────────────────────────────────

  void _onServiceSelected(_WalkInService s) {
    setState(() {
      _selectedService = s;
      _selectedTherapist = null;
      _selectedZone = null;
      _selectedStartTime = null;
      _startOptions = [];
    });
  }

  void _onTherapistSelected(_WalkInTherapist t) {
    setState(() => _selectedTherapist = t);
    if (_selectedZone != null) _computeStartOptions();
  }

  void _onZoneSelected(_WalkInZone z) {
    setState(() => _selectedZone = z);
    if (_selectedTherapist != null) _computeStartOptions();
  }

  // ── Computed Values ────────────────────────────────────────────

  double get _servicePrice => _selectedService?.price ?? 0;
  double get _sstAmount => _servicePrice * 0.06;
  double get _totalAmount => _servicePrice + _sstAmount;

  bool get _canCheckout =>
      _selectedCustomer != null &&
      _selectedService != null &&
      _selectedTherapist != null &&
      _selectedZone != null &&
      _selectedStartTime != null;

  bool get _canConfirmPayment => _paymentMethod != null;

  // ── Confirm Payment ────────────────────────────────────────────

  Future<void> _confirmPayment() async {
    if (!_canConfirmPayment) return;
    setState(() => _isConfirming = true);

    try {
      await _transactionRepository.createTransaction({
        'customerId': _selectedCustomer!.id,
        'customerName': _selectedCustomer!.name,
        'customerPhone': _selectedCustomer!.phone,
        'serviceId': _selectedService!.id,
        'serviceName': _selectedService!.name,
        'therapistId': _selectedTherapist!.id,
        'therapistName': _selectedTherapist!.name,
        'roomId': _selectedZone!.id,
        'roomName': _selectedZone!.name,
        'servicePrice': _servicePrice,
        'sstAmount': _sstAmount,
        'totalAmount': _totalAmount,
        'paymentMethod': _paymentMethod,
        'paymentStatus': 'paid',
        'receiptNumber': _receiptNumber,
        'notes': _transactionNotesController.text.trim(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Payment confirmed — service started'),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F0F0),
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
                  serviceName: _selectedService?.name,
                  totalAmount: _totalAmount,
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
                Column(
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
                      style: TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
                    ),
                  ],
                ),
                const Spacer(),
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
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 820
                ? 3
                : constraints.maxWidth >= 520
                ? 2
                : 1;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: columns == 1 ? 3.4 : 2.2,
              ),
              itemCount: filtered.length,
              itemBuilder: (_, i) => _WalkInServiceCard(
                service: filtered[i],
                isSelected: _selectedService?.id == filtered[i].id,
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
        .where(
          (z) =>
              _selectedService == null ||
              _selectedService!.roomType.isEmpty ||
              z.type == _selectedService!.roomType,
        )
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
        ..._therapists.map(
          (t) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _WalkInTherapistRow(
              therapist: t,
              isSelected: _selectedTherapist?.id == t.id,
              isDisabled: false,
              onTap: () => _onTherapistSelected(t),
            ),
          ),
        ),
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
            onTap: () => setState(() => _selectedStartTime = option),
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

        if (stackCards) {
          return Column(
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                cards[i],
                if (i != cards.length - 1) const SizedBox(height: 10),
              ],
            ],
          );
        }

        return Row(
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              Expanded(child: cards[i]),
              if (i != cards.length - 1) const SizedBox(width: 12),
            ],
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
            value: _selectedService?.name ?? '—',
          ),
          _WalkInSummaryRow(
            label: 'Duration',
            value: _selectedService != null
                ? '${_selectedService!.duration} min'
                : '—',
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
          _WalkInSummaryRow(label: 'Start Time', value: startLabel),

          if (_selectedService != null) ...[
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
                  'RM ${_servicePrice.toStringAsFixed(2)}',
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
                const Text(
                  'SST (6%)',
                  style: TextStyle(fontSize: 13, color: Color(0xFF6B6B6B)),
                ),
                Text(
                  'RM ${_sstAmount.toStringAsFixed(2)}',
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
                  'RM ${_totalAmount.toStringAsFixed(2)}',
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
                            '${_selectedCustomer?.name ?? 'Guest'} - ${_selectedService?.name ?? ''}',
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
                            '${_selectedService?.duration ?? 0} min',
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
                      '${_selectedTherapist?.name ?? ''} - ${_selectedZone?.name ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF6B6B6B),
                      ),
                    ),
                    Text(
                      'Start: ${_selectedStartTime?.isNow == true ? 'Now' : 'Next'} - ${_selectedStartTime?.timeLabel ?? ''}',
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
                      'RM ${_servicePrice.toStringAsFixed(2)}',
                    ),
                    const SizedBox(height: 8),
                    _PaymentRow(
                      'SST (6%)',
                      'RM ${_sstAmount.toStringAsFixed(2)}',
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
                          'RM ${_totalAmount.toStringAsFixed(2)}',
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
                      : (constraints.maxWidth - 24) / 3;
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
                          label: 'Card',
                          isSelected: _paymentMethod == 'card',
                          onTap: () => setState(() => _paymentMethod = 'card'),
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
                  label: const Text(
                    'Confirm Payment & Complete',
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

  Color get _chipBg => service.roomType == 'body_room'
      ? const Color(0xFFEDE7F6)
      : service.roomType.isEmpty
      ? const Color(0xFFE8F5F5)
      : const Color(0xFFFFF9E6);

  Color get _chipColor => service.roomType == 'body_room'
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _WalkInServiceImage(imageUrl: service.imageUrl, size: 58),
                const SizedBox(width: 12),
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
                      const SizedBox(height: 8),
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
                          _SmallBadge2(
                            label: _chipLabel,
                            bg: _chipBg,
                            color: _chipColor,
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
  final VoidCallback? onTap;

  const _WalkInTherapistRow({
    required this.therapist,
    required this.isSelected,
    required this.isDisabled,
    required this.onTap,
  });

  String get _statusLabel {
    if (therapist.isFree) return 'Available immediately';
    if (therapist.freeInMinutes > 0) {
      return 'Free in ${therapist.freeInMinutes} min';
    }
    return 'Unavailable';
  }

  Color get _statusColor {
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
