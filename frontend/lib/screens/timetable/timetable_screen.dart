import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/appointment_repository.dart';
import '../../data/repositories/dashboard_repository.dart';
import '../../data/repositories/repository_utils.dart';
import '../../data/repositories/transaction_repository.dart';
import '../../data/services/supabase_table_service.dart';

class TimetableScreen extends StatefulWidget {
  final String userRole;

  const TimetableScreen({super.key, required this.userRole});

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  final _appointmentRepository = AppointmentRepository();
  final _dashboardRepository = DashboardRepository();
  final _transactionRepository = TransactionRepository();
  final _businessSettingsTable = SupabaseTableService('business_settings');
  final _search = TextEditingController();

  DateTime _selectedDate = _stripDate(DateTime.now());
  String _mode = 'all';
  bool _loading = true;
  String? _error;
  List<_TimetableEntry> _entries = [];
  int _openMinute = 9 * 60;
  int _closeMinute = 21 * 60;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _loadTimetable();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadTimetable() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final date = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final settings = await _loadBusinessSettings();
      final appointmentRows = await _appointmentRepository.getAppointmentsByDate(
        date,
      );
      final transactionRows = await _transactionRepository.getTransactionsByDate(
        _selectedDate,
      );

      final customerIds = appointmentRows
          .map((row) => asString(row['customerId']))
          .where((id) => id.isNotEmpty && id != 'walk_in_guest');
      final serviceIds = appointmentRows
          .map((row) => asString(row['serviceId']))
          .where((id) => id.isNotEmpty);
      final therapistIds = appointmentRows
          .map((row) => asString(row['therapistId']))
          .where((id) => id.isNotEmpty);
      final roomIds = appointmentRows
          .map((row) => asString(row['roomId']))
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
      final transactionsByAppointment = <String, Map<String, dynamic>>{};
      for (final transaction in transactionRows) {
        final appointmentId = asString(transaction['appointmentId']);
        if (appointmentId.isNotEmpty) {
          transactionsByAppointment[appointmentId] = transaction;
        }
      }

      final entries = appointmentRows
          .map(
            (row) => _TimetableEntry.fromMap(
              row,
              customers: customers,
              services: services,
              therapists: therapists,
              rooms: rooms,
              transaction: transactionsByAppointment[asString(row['id'])],
              selectedDate: _selectedDate,
            ),
          )
          .where((entry) => !entry.isCancelled)
          .toList()
        ..sort((a, b) => a.startMinutes.compareTo(b.startMinutes));

      if (!mounted) return;
      setState(() {
        _entries = entries;
        _openMinute = settings.$1;
        _closeMinute = settings.$2;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<(int, int)> _loadBusinessSettings() async {
    try {
      final row = await _businessSettingsTable.getById('1');
      final open = _timeToMinutes(asString(row?['openTime'], '09:00'));
      var close = _timeToMinutes(asString(row?['closeTime'], '21:00'));
      if (close <= open) close += 24 * 60;
      return (open, close);
    } catch (_) {
      return (9 * 60, 21 * 60);
    }
  }

  List<_TimetableEntry> get _filteredEntries {
    final query = _search.text.trim().toLowerCase();
    return _entries.where((entry) {
      if (query.isEmpty) return true;
      if (_mode == 'staff') return entry.staffName.toLowerCase().contains(query);
      if (_mode == 'rooms') return entry.roomName.toLowerCase().contains(query);
      return entry.matches(query);
    }).toList();
  }

  _TimetableStats get _stats => _TimetableStats.fromEntries(
    _entries,
    selectedDate: _selectedDate,
  );

  void _shiftDate(int days) {
    setState(() => _selectedDate = _stripDate(_selectedDate.add(Duration(days: days))));
    _loadTimetable();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked == null) return;
    setState(() => _selectedDate = _stripDate(picked));
    _loadTimetable();
  }

  void _showEntry(_TimetableEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _TimetableDetailSheet(entry: entry),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 760;
    final entries = _filteredEntries;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FA),
      body: SafeArea(
        child: Column(
          children: [
            _TimetableHeader(
              selectedDate: _selectedDate,
              onBack: () => Navigator.pop(context),
              onPrevious: () => _shiftDate(-1),
              onNext: () => _shiftDate(1),
              onPickDate: _pickDate,
              onRefresh: _loadTimetable,
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadTimetable,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    isWide ? 24 : 14,
                    12,
                    isWide ? 24 : 14,
                    28,
                  ),
                  children: [
                    _StatsRow(stats: _stats, compact: !isWide),
                    const SizedBox(height: 14),
                    _TimetableControls(
                      mode: _mode,
                      controller: _search,
                      onModeChanged: (value) => setState(() => _mode = value),
                    ),
                    const SizedBox(height: 14),
                    if (_loading)
                      const _TimetableStateCard(
                        icon: Icons.hourglass_empty,
                        title: 'Loading timetable',
                        message: 'Checking today’s services and resource usage.',
                      )
                    else if (_error != null)
                      _TimetableStateCard(
                        icon: Icons.error_outline,
                        title: 'Unable to load timetable',
                        message: _error!,
                      )
                    else if (entries.isEmpty)
                      const _TimetableStateCard(
                        icon: Icons.event_available_outlined,
                        title: 'No services found',
                        message: 'There are no visible services for this day.',
                      )
                    else
                      _TimetableTimeline(
                        entries: entries,
                        selectedDate: _selectedDate,
                        openMinute: _openMinute,
                        closeMinute: _closeMinute,
                        isWide: isWide,
                        onTap: _showEntry,
                      ),
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

class _TimetableEntry {
  final String id;
  final String customerName;
  final String customerPhone;
  final String serviceName;
  final String staffName;
  final String roomName;
  final String type;
  final String status;
  final String startTime;
  final String endTime;
  final DateTime? startAt;
  final DateTime? endAt;
  final double price;
  final String receiptNumber;
  final String paymentMethod;
  final double paidAmount;
  final DateTime selectedDate;

  const _TimetableEntry({
    required this.id,
    required this.customerName,
    required this.customerPhone,
    required this.serviceName,
    required this.staffName,
    required this.roomName,
    required this.type,
    required this.status,
    required this.startTime,
    required this.endTime,
    required this.startAt,
    required this.endAt,
    required this.price,
    required this.receiptNumber,
    required this.paymentMethod,
    required this.paidAmount,
    required this.selectedDate,
  });

  factory _TimetableEntry.fromMap(
    Map<String, dynamic> row, {
    required Map<String, Map<String, dynamic>> customers,
    required Map<String, Map<String, dynamic>> services,
    required Map<String, Map<String, dynamic>> therapists,
    required Map<String, Map<String, dynamic>> rooms,
    required Map<String, dynamic>? transaction,
    required DateTime selectedDate,
  }) {
    final customer = customers[asString(row['customerId'])];
    final service = services[asString(row['serviceId'])];
    final therapist = therapists[asString(row['therapistId'])];
    final room = rooms[asString(row['roomId'])];
    return _TimetableEntry(
      id: asString(row['id']),
      customerName: _displayCustomerName(
        asString(row['customerName']).isNotEmpty
            ? asString(row['customerName'])
            : asString(customer?['name']),
      ),
      customerPhone: asString(row['customerPhone']).isNotEmpty
          ? asString(row['customerPhone'])
          : asString(customer?['phone'], '-'),
      serviceName: asString(row['serviceName']).isNotEmpty
          ? asString(row['serviceName'])
          : asString(service?['name'], 'Service'),
      staffName: asString(row['therapistName']).isNotEmpty
          ? asString(row['therapistName'])
          : asString(therapist?['name'], 'Unassigned'),
      roomName: asString(row['roomName']).isNotEmpty
          ? asString(row['roomName'])
          : asString(room?['name'], 'Room'),
      type: asString(row['type']).toLowerCase(),
      status: asString(row['status']).toLowerCase(),
      startTime: _cleanTime(asString(row['startTime'], '09:00')),
      endTime: _cleanTime(asString(row['endTime'], '10:00')),
      startAt: asDateTime(row['startAt']),
      endAt: asDateTime(row['endAt']),
      price: asDouble(row['totalPrice']),
      receiptNumber: asString(transaction?['receiptNumber']),
      paymentMethod: asString(transaction?['paymentMethod']),
      paidAmount: asDouble(transaction?['totalAmount']),
      selectedDate: selectedDate,
    );
  }

  int get startMinutes =>
      _minutesFromSelectedDate(startAt, selectedDate) ?? _timeToMinutes(startTime);
  int get endMinutes {
    final fromTimestamp = _minutesFromSelectedDate(endAt, selectedDate);
    if (fromTimestamp != null) return fromTimestamp;
    final start = _timeToMinutes(startTime);
    var end = _timeToMinutes(endTime);
    if (end <= start) end += 24 * 60;
    return end;
  }
  int get durationMinutes => (endMinutes - startMinutes).clamp(0, 1440);
  bool get isWalkIn => type == 'walkin' || type == 'walk_in' || type == 'walk-in';
  bool get isCancelled => status == 'cancelled' || status == 'canceled';
  bool get isCompleted => operationalStatus == 'Completed';
  bool get isInProgress => operationalStatus == 'In Progress';
  bool get isUpcoming => operationalStatus == 'Upcoming';
  bool get hasPayment => receiptNumber.isNotEmpty || paidAmount > 0;
  String get typeLabel => isWalkIn ? 'Walk-in' : 'Booking';
  String get priceLabel => 'RM ${price.toStringAsFixed(0)}';
  String get paidLabel => 'RM ${paidAmount.toStringAsFixed(2)}';
  String get timeRange => '${_clockLabel(startTime)} - ${_clockLabel(endTime)}';

  String get operationalStatus {
    if (status == 'completed') return 'Completed';
    final today = _stripDate(DateTime.now());
    final selected = _stripDate(selectedDate);
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    if (selected.isBefore(today)) return 'Completed';
    if (selected.isAfter(today)) return 'Upcoming';
    if ((status == 'confirmed' || status == 'in_progress') &&
        nowMinutes >= startMinutes &&
        nowMinutes < endMinutes) {
      return 'In Progress';
    }
    if (nowMinutes >= endMinutes && (hasPayment || isWalkIn)) return 'Completed';
    return 'Upcoming';
  }

  bool matches(String query) {
    return customerName.toLowerCase().contains(query) ||
        serviceName.toLowerCase().contains(query) ||
        staffName.toLowerCase().contains(query) ||
        roomName.toLowerCase().contains(query) ||
        receiptNumber.toLowerCase().contains(query);
  }
}

class _TimetableStats {
  final int inProgress;
  final int upcoming;
  final int completed;
  final int staffBusy;
  final int roomsInUse;

  const _TimetableStats({
    required this.inProgress,
    required this.upcoming,
    required this.completed,
    required this.staffBusy,
    required this.roomsInUse,
  });

  factory _TimetableStats.fromEntries(
    List<_TimetableEntry> entries, {
    required DateTime selectedDate,
  }) {
    final active = entries.where((entry) => entry.isInProgress).toList();
    return _TimetableStats(
      inProgress: active.length,
      upcoming: entries.where((entry) => entry.isUpcoming).length,
      completed: entries.where((entry) => entry.isCompleted).length,
      staffBusy: active.map((entry) => entry.staffName).toSet().length,
      roomsInUse: active.map((entry) => entry.roomName).toSet().length,
    );
  }
}

class _TimetableHeader extends StatelessWidget {
  final DateTime selectedDate;
  final VoidCallback onBack;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onPickDate;
  final VoidCallback onRefresh;

  const _TimetableHeader({
    required this.selectedDate,
    required this.onBack,
    required this.onPrevious,
    required this.onNext,
    required this.onPickDate,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      color: Colors.white,
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, color: Color(0xFF111827)),
            tooltip: 'Back',
          ),
          Expanded(
            child: GestureDetector(
              onTap: onPickDate,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Daily Timetable',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF111827),
                    ),
                  ),
                  Text(
                    DateFormat('EEEE, d MMMM yyyy').format(selectedDate),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: onPrevious,
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous day',
          ),
          IconButton(
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next day',
          ),
          IconButton(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final _TimetableStats stats;
  final bool compact;

  const _StatsRow({required this.stats, required this.compact});

  @override
  Widget build(BuildContext context) {
    final cards = [
      _StatChip('In Progress', stats.inProgress, const Color(0xFF0EA5E9)),
      _StatChip('Upcoming', stats.upcoming, const Color(0xFF2563EB)),
      _StatChip('Completed', stats.completed, const Color(0xFF059669)),
      _StatChip('Staff Busy', stats.staffBusy, const Color(0xFFF59E0B)),
      _StatChip('Rooms In Use', stats.roomsInUse, const Color(0xFF7C3AED)),
    ];
    if (compact) {
      return Wrap(spacing: 8, runSpacing: 8, children: cards);
    }
    return Row(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          Expanded(child: cards[i]),
          if (i != cards.length - 1) const SizedBox(width: 10),
        ],
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _StatChip(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            '$value',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF6B7280),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimetableControls extends StatelessWidget {
  final String mode;
  final TextEditingController controller;
  final ValueChanged<String> onModeChanged;

  const _TimetableControls({
    required this.mode,
    required this.controller,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 640;
        final filters = _ModeSelector(mode: mode, onChanged: onModeChanged);
        final search = TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: mode == 'staff'
                ? 'Search staff...'
                : mode == 'rooms'
                    ? 'Search rooms...'
                    : 'Search customer, service, staff, room...',
            prefixIcon: const Icon(Icons.search),
            filled: true,
            fillColor: const Color(0xFFEAF0F5),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFD5DEE8)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFD5DEE8)),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        );
        if (narrow) {
          return Column(
            children: [filters, const SizedBox(height: 10), search],
          );
        }
        return Row(
          children: [
            SizedBox(width: 310, child: filters),
            const SizedBox(width: 12),
            Expanded(child: search),
          ],
        );
      },
    );
  }
}

class _ModeSelector extends StatelessWidget {
  final String mode;
  final ValueChanged<String> onChanged;

  const _ModeSelector({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF0F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _ModeButton('All', 'all', mode, onChanged),
          _ModeButton('Staff', 'staff', mode, onChanged),
          _ModeButton('Rooms', 'rooms', mode, onChanged),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final String value;
  final String selected;
  final ValueChanged<String> onChanged;

  const _ModeButton(this.label, this.value, this.selected, this.onChanged);

  @override
  Widget build(BuildContext context) {
    final active = value == selected;
    return Expanded(
      child: InkWell(
        onTap: () => onChanged(value),
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              color: active ? const Color(0xFF1B6B72) : const Color(0xFF6B7280),
            ),
          ),
        ),
      ),
    );
  }
}

class _TimetableTimeline extends StatelessWidget {
  final List<_TimetableEntry> entries;
  final DateTime selectedDate;
  final int openMinute;
  final int closeMinute;
  final bool isWide;
  final ValueChanged<_TimetableEntry> onTap;

  const _TimetableTimeline({
    required this.entries,
    required this.selectedDate,
    required this.openMinute,
    required this.closeMinute,
    required this.isWide,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hourHeight = isWide ? 82.0 : 76.0;
    final labelWidth = isWide ? 58.0 : 42.0;
    final earliestEntryStart = entries.fold<int>(
      openMinute,
      (earliest, entry) => entry.startMinutes < earliest ? entry.startMinutes : earliest,
    );
    final latestEntryEnd = entries.fold<int>(
      closeMinute,
      (latest, entry) => entry.endMinutes > latest ? entry.endMinutes : latest,
    );
    final canvasStartMinute = _floorToHour(earliestEntryStart);
    final canvasEndMinute = _ceilToHour(latestEntryEnd);
    final totalHeight =
        ((canvasEndMinute - canvasStartMinute) / 60 * hourHeight)
            .clamp(120.0, 2600.0);
    final placements = _assignLanes(entries);

    return Container(
      padding: EdgeInsets.fromLTRB(isWide ? 18 : 10, 16, isWide ? 18 : 10, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: SizedBox(
        height: totalHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final canvasLeft = labelWidth + 12;
            final canvasWidth = constraints.maxWidth - canvasLeft;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                _TimetableGrid(
                  canvasStartMinute: canvasStartMinute,
                  canvasEndMinute: canvasEndMinute,
                  hourHeight: hourHeight,
                  labelWidth: labelWidth,
                  showNowLine: _stripDate(selectedDate) == _stripDate(DateTime.now()),
                ),
                for (final placement in placements)
                  _PositionedTimetableCard(
                    placement: placement,
                    canvasStartMinute: canvasStartMinute,
                    hourHeight: hourHeight,
                    canvasLeft: canvasLeft,
                    canvasWidth: canvasWidth,
                    compact: !isWide,
                    onTap: onTap,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TimetableGrid extends StatelessWidget {
  final int canvasStartMinute;
  final int canvasEndMinute;
  final double hourHeight;
  final double labelWidth;
  final bool showNowLine;

  const _TimetableGrid({
    required this.canvasStartMinute,
    required this.canvasEndMinute,
    required this.hourHeight,
    required this.labelWidth,
    required this.showNowLine,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final showNow =
        showNowLine &&
        nowMinutes >= canvasStartMinute &&
        nowMinutes <= canvasEndMinute;
    final firstHour = canvasStartMinute ~/ 60;
    final lastHour = (canvasEndMinute / 60).ceil();

    return Stack(
      children: [
        for (var hour = firstHour; hour <= lastHour; hour++) ...[
          Positioned(
            top: ((hour * 60 - canvasStartMinute) / 60) * hourHeight,
            left: 0,
            width: labelWidth,
            child: Text(
              _hourLabel(hour),
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: Color(0xFF4B5563),
              ),
            ),
          ),
          Positioned(
            top: ((hour * 60 - canvasStartMinute) / 60) * hourHeight,
            left: labelWidth + 12,
            right: 0,
            child: const Divider(height: 1, color: Color(0xFFE5E7EB)),
          ),
        ],
        if (showNow)
          Positioned(
            top: ((nowMinutes - canvasStartMinute) / 60) * hourHeight,
            left: labelWidth + 12,
            right: 0,
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE11D48),
                    shape: BoxShape.circle,
                  ),
                ),
                const Expanded(
                  child: Divider(height: 1, color: Color(0xFFE11D48)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PositionedTimetableCard extends StatelessWidget {
  final _LanePlacement placement;
  final int canvasStartMinute;
  final double hourHeight;
  final double canvasLeft;
  final double canvasWidth;
  final bool compact;
  final ValueChanged<_TimetableEntry> onTap;

  const _PositionedTimetableCard({
    required this.placement,
    required this.canvasStartMinute,
    required this.hourHeight,
    required this.canvasLeft,
    required this.canvasWidth,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const spacing = 8.0;
    final entry = placement.entry;
    final laneWidth =
        (canvasWidth - spacing * (placement.laneCount - 1)) / placement.laneCount;
    final left = canvasLeft + placement.lane * (laneWidth + spacing);
    final top = ((entry.startMinutes - canvasStartMinute) / 60) * hourHeight;
    final height =
        (((entry.endMinutes - entry.startMinutes) / 60) * hourHeight)
            .clamp(54.0, 240.0)
            .toDouble();

    return Positioned(
      top: top,
      left: left,
      width: laneWidth,
      height: height,
      child: _TimetableCard(
        entry: entry,
        compact: compact || laneWidth < 230 || height < 76,
        dotOnly: laneWidth < 150 || height < 72,
        showDetails: height >= 96 && laneWidth >= 260,
        onTap: () => onTap(entry),
      ),
    );
  }
}

class _TimetableCard extends StatelessWidget {
  final _TimetableEntry entry;
  final bool compact;
  final bool dotOnly;
  final bool showDetails;
  final VoidCallback onTap;

  const _TimetableCard({
    required this.entry,
    required this.compact,
    required this.dotOnly,
    required this.showDetails,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = _statusStyle(entry);
    final dense = compact || !showDetails;
    final serviceLabel = dotOnly && dense
        ? entry.priceLabel
        : '${entry.serviceName} - ${entry.priceLabel}';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 8 : 12,
            vertical: dense ? 6 : 10,
          ),
          decoration: BoxDecoration(
            color: style.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: style.border),
            boxShadow: const [
              BoxShadow(
                color: Color(0x10000000),
                blurRadius: 10,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 4,
                height: double.infinity,
                decoration: BoxDecoration(
                  color: style.color,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              SizedBox(width: dense ? 8 : 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment:
                      dense ? MainAxisAlignment.center : MainAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.customerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: dense ? 13 : 15,
                              fontWeight: FontWeight.w900,
                              color: const Color(0xFF111827),
                            ),
                          ),
                        ),
                        _TinyBadge(
                          label: dotOnly ? '' : entry.operationalStatus,
                          color: style.color,
                        ),
                      ],
                    ),
                    SizedBox(height: dense ? 2 : 5),
                    Text(
                      serviceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: dense ? 11 : 12,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF4B5563),
                      ),
                    ),
                    if (showDetails) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${entry.timeRange} · ${entry.staffName} · ${entry.roomName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF6B7280),
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
    );
  }
}

class _TinyBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _TinyBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: label.isEmpty ? 5 : 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          if (label.isNotEmpty) ...[
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TimetableDetailSheet extends StatelessWidget {
  final _TimetableEntry entry;

  const _TimetableDetailSheet({required this.entry});

  @override
  Widget build(BuildContext context) {
    final style = _statusStyle(entry);
    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      builder: (context, controller) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD1D5DB),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  _TinyBadge(label: entry.operationalStatus, color: style.color),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                entry.customerName,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF111827),
                ),
              ),
              Text(
                entry.customerPhone.isEmpty ? '-' : entry.customerPhone,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF6B7280),
                ),
              ),
              const SizedBox(height: 24),
              _DetailRow(Icons.spa_outlined, 'Service', entry.serviceName),
              _DetailRow(Icons.person_outline, 'Staff', entry.staffName),
              _DetailRow(Icons.meeting_room_outlined, 'Room / Zone', entry.roomName),
              _DetailRow(Icons.schedule_outlined, 'Time', entry.timeRange),
              _DetailRow(Icons.payments_outlined, 'Price', entry.priceLabel),
              _DetailRow(Icons.category_outlined, 'Type', entry.typeLabel),
              if (entry.hasPayment) ...[
                const Divider(height: 30),
                _DetailRow(Icons.receipt_long_outlined, 'Receipt', entry.receiptNumber),
                _DetailRow(Icons.credit_card_outlined, 'Payment', entry.paymentMethod),
                _DetailRow(Icons.account_balance_wallet_outlined, 'Paid', entry.paidLabel),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailRow(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFF526071), size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF6B7280),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value.isEmpty ? '-' : value,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111827),
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

class _TimetableStateCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _TimetableStateCard({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 34, color: const Color(0xFF1B6B72)),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFF6B7280),
            ),
          ),
        ],
      ),
    );
  }
}

class _LanePlacement {
  final _TimetableEntry entry;
  final int lane;
  final int laneCount;

  const _LanePlacement({
    required this.entry,
    required this.lane,
    required this.laneCount,
  });
}

List<_LanePlacement> _assignLanes(List<_TimetableEntry> entries) {
  final sorted = [...entries]
    ..sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
  final placements = <_LanePlacement>[];
  var group = <_TimetableEntry>[];
  var groupEnd = 0;

  void flush() {
    if (group.isEmpty) return;
    final laneEnds = <int>[];
    final laneById = <String, int>{};
    for (final entry in group) {
      var lane = laneEnds.indexWhere((end) => entry.startMinutes >= end);
      if (lane == -1) {
        lane = laneEnds.length;
        laneEnds.add(entry.endMinutes);
      } else {
        laneEnds[lane] = entry.endMinutes;
      }
      laneById[entry.id] = lane;
    }
    for (final entry in group) {
      placements.add(
        _LanePlacement(
          entry: entry,
          lane: laneById[entry.id] ?? 0,
          laneCount: laneEnds.length,
        ),
      );
    }
  }

  for (final entry in sorted) {
    if (group.isEmpty || entry.startMinutes < groupEnd) {
      group.add(entry);
      if (entry.endMinutes > groupEnd) groupEnd = entry.endMinutes;
    } else {
      flush();
      group = [entry];
      groupEnd = entry.endMinutes;
    }
  }
  flush();
  return placements;
}

_StatusStyle _statusStyle(_TimetableEntry entry) {
  if (entry.isInProgress) {
    return const _StatusStyle(
      color: Color(0xFF0EA5E9),
      background: Color(0xFFEFF8FF),
      border: Color(0xFF7DD3FC),
    );
  }
  if (entry.isCompleted) {
    return const _StatusStyle(
      color: Color(0xFF059669),
      background: Color(0xFFF0FDF4),
      border: Color(0xFF86EFAC),
    );
  }
  return const _StatusStyle(
    color: Color(0xFF2563EB),
    background: Color(0xFFEFF6FF),
    border: Color(0xFF93C5FD),
  );
}

class _StatusStyle {
  final Color color;
  final Color background;
  final Color border;

  const _StatusStyle({
    required this.color,
    required this.background,
    required this.border,
  });
}

DateTime _stripDate(DateTime date) => DateTime(date.year, date.month, date.day);

String _displayCustomerName(String raw) {
  final normalized = raw.trim().toLowerCase();
  if (normalized.isEmpty ||
      normalized == 'guest' ||
      normalized == 'guest account' ||
      normalized == 'walk-in guest') {
    return 'Guest';
  }
  return raw.trim();
}

String _cleanTime(String value) {
  final raw = value.trim();
  return raw.length >= 5 ? raw.substring(0, 5) : raw;
}

int _timeToMinutes(String time) {
  final parts = time.split(':');
  if (parts.length < 2) return 0;
  return (int.tryParse(parts[0]) ?? 0) * 60 +
      (int.tryParse(parts[1]) ?? 0);
}

int _floorToHour(int minutes) => (minutes ~/ 60) * 60;

int _ceilToHour(int minutes) => ((minutes + 59) ~/ 60) * 60;

int? _minutesFromSelectedDate(DateTime? value, DateTime selectedDate) {
  if (value == null) return null;
  final base = _stripDate(selectedDate);
  return value.difference(base).inMinutes;
}

String _clockLabel(String time) {
  final minutes = _timeToMinutes(time);
  final hour = minutes ~/ 60;
  final minute = minutes % 60;
  return DateFormat('h:mm a').format(DateTime(2026, 1, 1, hour, minute));
}

String _hourLabel(int hour) {
  return DateFormat('ha').format(DateTime(2026, 1, 1, hour)).toLowerCase();
}
