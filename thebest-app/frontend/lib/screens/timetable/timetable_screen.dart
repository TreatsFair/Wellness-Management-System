import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/services/csp_service.dart';
import '../../core/utils/error_message.dart';
import '../../data/repositories/appointment_repository.dart';
import '../../data/repositories/business_settings_repository.dart';
import '../../data/repositories/dashboard_repository.dart';
import '../../data/repositories/repository_utils.dart';
import '../../data/repositories/room_repository.dart';
import '../../data/repositories/transaction_repository.dart';
import '../../data/services/supabase_table_service.dart';

const Color _timetableAccent = Color(0xFF0F766E);
const double _timetableSidePanelBreakpoint = 900;

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
  final _roomRepository = RoomRepository();
  final _businessSettingsTable = SupabaseTableService('business_settings');
  final _roomUnitsTable = SupabaseTableService('room_units');
  final _search = TextEditingController();

  DateTime _selectedDate = _stripDate(DateTime.now());
  String _mode = 'staff';
  String _view = 'overview';
  bool _loading = true;
  String? _error;
  List<_TimetableEntry> _entries = [];
  List<_TimetableTherapist> _therapists = [];
  List<_TimetableRoom> _rooms = [];
  List<_TimetableRoomUnit> _roomUnits = [];
  final Set<String> _expandedBandKeys = {};
  // Resource ids the user has narrowed the timetable to (empty = show all).
  final Set<String> _selectedResourceIds = {};
  bool _resourceFilterExpanded = false;
  _TimetableEntry? _selectedEntry;
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
      _expandedBandKeys.clear();
    });

    try {
      final date = DateFormat('yyyy-MM-dd').format(_selectedDate);
      await _appointmentRepository.completeDueAppointments();
      await _appointmentRepository.markPastAppointmentsNoShow();
      final settings = await _loadBusinessSettings();
      final businessRules = settings.$3;
      final appointmentRows = await _appointmentRepository
          .getAppointmentsByDate(date);
      final transactionRows = await _transactionRepository
          .getTransactionsByDate(_selectedDate);
      final therapistRows = await _dashboardRepository.listTherapists();
      final roomRows = await _roomRepository.getActiveRooms();
      final roomUnitRows = await _roomUnitsTable.list(orderBy: 'unit_number');

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
      final allTherapists = {
        for (final row in therapistRows) asString(row['id']): row,
      };
      final linkedTherapists = await _dashboardRepository.loadByIds(
        'therapists',
        therapistIds.where((id) => !allTherapists.containsKey(id)),
      );
      final therapists = {...allTherapists, ...linkedTherapists};
      final rooms = await _dashboardRepository.loadByIds('rooms', roomIds);
      final transactionsByAppointment = <String, Map<String, dynamic>>{};
      final transactionsByGroup = <String, Map<String, dynamic>>{};
      for (final transaction in transactionRows) {
        final appointmentId = asString(transaction['appointmentId']);
        final appointmentGroupId = asString(transaction['appointmentGroupId']);
        if (appointmentId.isNotEmpty) {
          transactionsByAppointment[appointmentId] = transaction;
        }
        if (appointmentGroupId.isNotEmpty) {
          transactionsByGroup[appointmentGroupId] = transaction;
        }
      }

      final entries =
          appointmentRows
              .map(
                (row) => _TimetableEntry.fromMap(
                  row,
                  customers: customers,
                  services: services,
                  therapists: therapists,
                  rooms: rooms,
                  transaction:
                      transactionsByAppointment[asString(row['id'])] ??
                      transactionsByGroup[asString(row['appointmentGroupId'])],
                  selectedDate: _selectedDate,
                  lateGraceMinutes: businessRules.lateGraceMinutes,
                  delayWarningMinutes: businessRules.delayWarningMinutes,
                ),
              )
              .where((entry) => !entry.isCancelled)
              .toList()
            ..sort(
              (a, b) => a.serviceStartMinutes.compareTo(b.serviceStartMinutes),
            );

      if (!mounted) return;
      setState(() {
        _entries = entries;
        _therapists = _buildTherapistRows(therapistRows, entries);
        _rooms = _buildRoomRows(roomRows, entries);
        _roomUnits = roomUnitRows
            .map(_TimetableRoomUnit.fromMap)
            .where((unit) => unit.active)
            .toList();
        _openMinute = settings.$1;
        _closeMinute = settings.$2;
        final selectedId = _selectedEntry?.id;
        if (selectedId != null) {
          _selectedEntry = null;
          for (final entry in entries) {
            if (entry.id != selectedId) continue;
            _selectedEntry = entry;
            break;
          }
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<(int, int, BusinessRuleSettings)> _loadBusinessSettings() async {
    try {
      final rows = await _businessSettingsTable.list(limit: 1);
      final row = rows.isEmpty ? null : rows.first;
      final open = _timeToMinutes(asString(row?['openTime'], '09:00'));
      var close = _timeToMinutes(asString(row?['closeTime'], '21:00'));
      if (close <= open) close += 24 * 60;
      final rules = row == null
          ? BusinessRuleSettings.defaults()
          : BusinessRuleSettings.fromMap(row);
      return (open, close, rules);
    } catch (_) {
      return (9 * 60, 21 * 60, BusinessRuleSettings.defaults());
    }
  }

  List<_TimetableEntry> get _filteredEntries {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return _entries;
    return _entries.where((entry) {
      if (_mode == 'staff' && entry.staffName.toLowerCase().contains(query)) {
        return true;
      }
      if (_mode == 'rooms' && entry.roomName.toLowerCase().contains(query)) {
        return true;
      }
      return entry.matches(query);
    }).toList();
  }

  List<_TimetableResource> get _staffResources {
    final resources = _therapists
        .map(
          (t) => _TimetableResource(
            id: t.id,
            name: t.name,
            subtitle: t.role,
            capacity: 1,
            available: t.available,
            avatarText: t.initials,
            avatarIcon: null,
            resourceType: 'staff',
            accentColor: _avatarColor(t.name),
            matches: (e) => e.therapistId == t.id,
          ),
        )
        .toList();
    if (_entries.any((e) => e.therapistId.isEmpty)) {
      resources.add(
        _TimetableResource(
          id: '',
          name: 'Unassigned',
          subtitle: 'Needs assignment',
          capacity: 1,
          available: false,
          avatarText: '?',
          avatarIcon: null,
          resourceType: 'staff',
          accentColor: const Color(0xFF64748B),
          matches: (e) => e.therapistId.isEmpty,
        ),
      );
    }
    return resources;
  }

  List<_TimetableResource> get _roomResources {
    final roomById = {for (final room in _rooms) room.id: room};
    final unitZoneIds = _roomUnits.map((unit) => unit.zoneId).toSet();
    final resources = <_TimetableResource>[
      for (final unit in _roomUnits)
        if (roomById[unit.zoneId] case final zone?)
          _TimetableResource(
            id: unit.id,
            name: unit.name,
            subtitle: zone.name,
            capacity: 1,
            available: unit.active,
            avatarText: '',
            avatarIcon: Icons.meeting_room_outlined,
            resourceType: 'room',
            accentColor: _roomAccentColor(zone.roomType),
            matches: (e) => e.roomUnitId == unit.id,
          ),
      for (final r in _rooms)
        if (!unitZoneIds.contains(r.id))
          _TimetableResource(
            id: r.id,
            name: r.name,
            subtitle: _titleCase(r.roomType),
            capacity: r.totalSlots,
            available: r.active,
            avatarText: '',
            avatarIcon: _roomIcon(r.roomType),
            resourceType: 'room',
            accentColor: _roomAccentColor(r.roomType),
            matches: (e) => e.roomId == r.id,
          ),
    ];
    if (_entries.any((e) => e.roomId.isEmpty)) {
      resources.add(
        _TimetableResource(
          id: '',
          name: 'Unassigned',
          subtitle: 'No zone set',
          capacity: 1,
          available: false,
          avatarText: '',
          avatarIcon: Icons.meeting_room_outlined,
          resourceType: 'room',
          accentColor: const Color(0xFF64748B),
          matches: (e) => e.roomId.isEmpty,
        ),
      );
    }
    return resources;
  }

  List<_TimetableResource> get _visibleResources {
    final resources = _mode == 'rooms' ? _roomResources : _staffResources;
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return resources;
    return resources.where((r) {
      if (r.name.toLowerCase().contains(query)) return true;
      return _entries.where(r.matches).any((e) => e.matches(query));
    }).toList();
  }

  _TimetableStats get _stats => _TimetableStats.fromEntries(
    _entries,
    resources: _mode == 'rooms' ? _roomResources : _staffResources,
    selectedDate: _selectedDate,
  );

  void _onModeChanged(String value) {
    setState(() {
      _mode = value;
      _expandedBandKeys.clear();
      _selectedResourceIds.clear();
      _resourceFilterExpanded = false;
    });
  }

  void _toggleResourceSelection(String id) {
    setState(() {
      if (_selectedResourceIds.contains(id)) {
        _selectedResourceIds.remove(id);
      } else {
        _selectedResourceIds.add(id);
      }
    });
  }

  List<_TimetableResource> _applyResourceSelection(
    List<_TimetableResource> resources,
  ) {
    if (_selectedResourceIds.isEmpty) return resources;
    return resources.where((r) => _selectedResourceIds.contains(r.id)).toList();
  }

  void _onViewChanged(String value) {
    if (_view == value) return;
    setState(() {
      _view = value;
    });
  }

  void _openTimetable([String? mode]) {
    setState(() {
      _view = 'timetable';
      if (mode != null) _mode = mode;
    });
  }

  void _toggleBand(String key) {
    setState(() {
      if (_expandedBandKeys.contains(key)) {
        _expandedBandKeys.remove(key);
      } else {
        _expandedBandKeys.add(key);
      }
    });
  }

  void _shiftDate(int days) {
    setState(
      () => _selectedDate = _stripDate(_selectedDate.add(Duration(days: days))),
    );
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

  void _goToToday() {
    final today = _stripDate(DateTime.now());
    if (_selectedDate == today) return;
    setState(() => _selectedDate = today);
    _loadTimetable();
  }

  void _showTimetableSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _TimetableSettingsSheet(
        openMinute: _openMinute,
        closeMinute: _closeMinute,
      ),
    );
  }

  Future<bool> _startEntry(_TimetableEntry entry) async {
    try {
      await _appointmentRepository.startAppointment(
        entry.id,
        startedAt: DateTime.now(),
      );
      if (!mounted) return false;
      await _loadTimetable();
      if (!mounted) return false;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Service started')));
      return true;
    } catch (error) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unable to start service: ${friendlyErrorMessage(error)}',
          ),
          backgroundColor: const Color(0xFFB42318),
        ),
      );
      return false;
    }
  }

  Future<bool> _switchEntryTherapist(_TimetableEntry entry) async {
    final candidates = _therapists
        .where(
          (therapist) =>
              therapist.id != entry.therapistId &&
              therapist.role.toLowerCase().contains('therapist'),
        )
        .toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No replacement therapists available')),
      );
      return false;
    }

    final now = DateTime.now();
    final requiredStart = now.isAfter(entry._serviceStartDateTime)
        ? now
        : entry._serviceStartDateTime;
    final requiredEnd = entry._serviceEndDateTime;
    final requiredWindow =
        '${DateFormat('h:mm a').format(requiredStart)} - '
        '${DateFormat('h:mm a').format(requiredEnd)}';
    final options = await Future.wait(
      candidates.map((therapist) async {
        if (!therapist.available) {
          return _TimetableTherapistSwitchOption(
            therapist: therapist,
            isAvailable: false,
            statusLabel: 'Not available for assignment',
          );
        }
        if (!requiredEnd.isAfter(requiredStart)) {
          return _TimetableTherapistSwitchOption(
            therapist: therapist,
            isAvailable: false,
            statusLabel: 'Service window has ended',
          );
        }
        try {
          final availability = await CspService.validateSlot(
            date: DateFormat('yyyy-MM-dd').format(requiredStart),
            startTime: DateFormat('HH:mm:ss').format(requiredStart),
            endTime: DateFormat('HH:mm:ss').format(requiredEnd),
            therapistId: therapist.id,
            roomId: entry.roomId,
            excludeId: entry.id,
          );
          final busyUntil = availability.therapistBusyUntil;
          return _TimetableTherapistSwitchOption(
            therapist: therapist,
            isAvailable: availability.therapistAvailable,
            statusLabel: availability.therapistAvailable
                ? 'Available $requiredWindow'
                : busyUntil == null
                ? 'Conflicts during this service window'
                : 'Busy until ${_clockLabel(busyUntil)}',
          );
        } catch (_) {
          return _TimetableTherapistSwitchOption(
            therapist: therapist,
            isAvailable: false,
            statusLabel: 'Availability could not be confirmed',
          );
        }
      }),
    );
    options.sort((left, right) {
      if (left.isAvailable != right.isAvailable) {
        return left.isAvailable ? -1 : 1;
      }
      return left.therapist.name.compareTo(right.therapist.name);
    });
    if (!mounted) return false;

    final startedAt = entry.actualStartedAt?.toLocal();
    final receivesFullCommission =
        startedAt == null ||
        !DateTime.now().isAfter(startedAt.add(const Duration(minutes: 15)));
    final selection = await showDialog<_TimetableTherapistSwitchSelection>(
      context: context,
      builder: (context) => _TimetableTherapistSwitchDialog(
        currentTherapistName: entry.staffName,
        requiredWindow: requiredWindow,
        options: options,
        receivesFullCommission: receivesFullCommission,
      ),
    );
    if (selection == null || !mounted) return false;

    try {
      final result = await _appointmentRepository.switchTherapist(
        appointmentId: entry.id,
        newTherapistId: selection.therapistId,
        splitMethod: selection.splitMethod,
        reason: selection.reason,
      );
      if (!mounted) return false;
      await _loadTimetable();
      if (!mounted) return false;
      final method =
          result['commission_method']?.toString() ?? selection.splitMethod;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            method == 'early_replacement'
                ? 'Therapist switched - replacement receives 100% commission'
                : method == 'half'
                ? 'Therapist switched - commission split 50 / 50'
                : 'Therapist switched - commission split by service time',
          ),
        ),
      );
      return true;
    } catch (error) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(friendlyErrorMessage(error)),
          backgroundColor: const Color(0xFFB42318),
        ),
      );
      return false;
    }
  }

  void _showEntry(_TimetableEntry entry) {
    if (MediaQuery.of(context).size.width >= _timetableSidePanelBreakpoint) {
      setState(() => _selectedEntry = entry);
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _TimetableDetailSheet(
        entry: entry,
        onStart: () async {
          final changed = await _startEntry(entry);
          if (changed && sheetContext.mounted) Navigator.pop(sheetContext);
          return changed;
        },
        onSwitchTherapist: () async {
          final changed = await _switchEntryTherapist(entry);
          if (changed && sheetContext.mounted) Navigator.pop(sheetContext);
          return changed;
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isTabletLayout = screenWidth >= 900;
    final isWideLayout = screenWidth >= 1200;
    final showSidePanel = screenWidth >= _timetableSidePanelBreakpoint;
    final entries = _filteredEntries;
    final resources = _applyResourceSelection(_visibleResources);
    final modeResources = _mode == 'rooms' ? _roomResources : _staffResources;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FA),
      body: SafeArea(
        child: Column(
          children: [
            _TimetableHeader(
              selectedDate: _selectedDate,
              onBack: () => Navigator.maybePop(context),
              onPrevious: () => _shiftDate(-1),
              onNext: () => _shiftDate(1),
              onPickDate: _pickDate,
              onToday: _goToToday,
              onRefresh: _loadTimetable,
              onSettings: _showTimetableSettings,
            ),
            Container(
              color: Colors.white,
              padding: EdgeInsets.fromLTRB(
                isWideLayout ? 24 : 14,
                10,
                isWideLayout ? 24 : 14,
                14,
              ),
              child: Column(
                children: [
                  _StatsRow(
                    stats: _stats,
                    mode: _mode,
                    compact: !isTabletLayout,
                    selectedDate: _selectedDate,
                  ),
                  const SizedBox(height: 12),
                  _ViewToggle(view: _view, onChanged: _onViewChanged),
                  if (_view == 'timetable') ...[
                    const SizedBox(height: 10),
                    _TimetableControls(
                      mode: _mode,
                      controller: _search,
                      onModeChanged: _onModeChanged,
                      resources: modeResources,
                      entries: _entries,
                      selectedDate: _selectedDate,
                      selectedIds: _selectedResourceIds,
                      filterExpanded: _resourceFilterExpanded,
                      onToggleFilter: () => setState(
                        () =>
                            _resourceFilterExpanded = !_resourceFilterExpanded,
                      ),
                      onToggleResource: _toggleResourceSelection,
                      onClearResources: () =>
                          setState(_selectedResourceIds.clear),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  RefreshIndicator(
                    onRefresh: _loadTimetable,
                    notificationPredicate: (notification) =>
                        notification.metrics.axis == Axis.vertical,
                    child: _view == 'overview'
                        ? _TimetableOverview(
                            loading: _loading,
                            error: _error,
                            entries: _entries,
                            therapists: _therapists,
                            rooms: _rooms,
                            roomUnits: _roomUnits,
                            selectedDate: _selectedDate,
                            onTapEntry: _showEntry,
                            onOpenTimetable: _openTimetable,
                          )
                        : _buildBody(isTabletLayout, entries, resources),
                  ),
                  if (showSidePanel)
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      top: 18,
                      right: _selectedEntry == null ? -390 : 18,
                      bottom: 18,
                      width: 360,
                      child: IgnorePointer(
                        ignoring: _selectedEntry == null,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 140),
                          opacity: _selectedEntry == null ? 0 : 1,
                          child: _selectedEntry == null
                              ? const SizedBox.shrink()
                              : _TimetableDetailCard(
                                  entry: _selectedEntry!,
                                  onClose: () =>
                                      setState(() => _selectedEntry = null),
                                  onStart: () => _startEntry(_selectedEntry!),
                                  onSwitchTherapist: () =>
                                      _switchEntryTherapist(_selectedEntry!),
                                ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    bool isTablet,
    List<_TimetableEntry> entries,
    List<_TimetableResource> resources,
  ) {
    if (_loading) {
      return ListView(
        padding: const EdgeInsets.all(14),
        children: const [
          _TimetableStateCard(
            icon: Icons.hourglass_empty,
            title: 'Loading timetable',
            message: "Checking today's services and resource usage.",
          ),
        ],
      );
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _TimetableStateCard(
            icon: Icons.error_outline,
            title: 'Unable to load timetable',
            message: _error!,
          ),
        ],
      );
    }
    if (resources.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _TimetableStateCard(
            icon: _mode == 'staff'
                ? Icons.people_outline
                : Icons.meeting_room_outlined,
            title: _mode == 'staff' ? 'No therapists found' : 'No rooms found',
            message:
                'Add ${_mode == 'staff' ? 'therapists' : 'rooms'} or check the selected outlet.',
          ),
        ],
      );
    }
    if (isTablet) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 28),
        children: [
          _ResourceTimetableGrid(
            resources: resources,
            entries: entries,
            selectedDate: _selectedDate,
            openMinute: _openMinute,
            closeMinute: _closeMinute,
            mode: _mode,
            onTap: _showEntry,
          ),
        ],
      );
    }
    return _MobileTimetable(
      entries: entries,
      bottomResources: resources,
      mode: _mode,
      selectedDate: _selectedDate,
      openMinute: _openMinute,
      closeMinute: _closeMinute,
      expandedBandKeys: _expandedBandKeys,
      onToggleBand: _toggleBand,
      onTap: _showEntry,
    );
  }
}

class _TimetableEntry {
  final String id;
  final String therapistId;
  final String roomId;
  final String roomUnitId;
  final String customerName;
  final String customerPhone;
  final String serviceName;
  final int serviceCount;
  final String staffName;
  final String roomName;
  final String roomUnitName;
  final String type;
  final String status;
  final String startTime;
  final String endTime;
  final DateTime? startAt;
  final DateTime? endAt;
  final String bookedStartTime;
  final String bookedEndTime;
  final DateTime? actualStartedAt;
  final DateTime? actualCompletedAt;
  final int bufferAfterMinutes;
  final double price;
  final String receiptNumber;
  final String paymentMethod;
  final String paymentStatus;
  final double paidAmount;
  final DateTime selectedDate;
  final int lateGraceMinutes;
  final int delayWarningMinutes;

  const _TimetableEntry({
    required this.id,
    required this.therapistId,
    required this.roomId,
    required this.roomUnitId,
    required this.customerName,
    required this.customerPhone,
    required this.serviceName,
    required this.serviceCount,
    required this.staffName,
    required this.roomName,
    required this.roomUnitName,
    required this.type,
    required this.status,
    required this.startTime,
    required this.endTime,
    required this.startAt,
    required this.endAt,
    required this.bookedStartTime,
    required this.bookedEndTime,
    required this.actualStartedAt,
    required this.actualCompletedAt,
    required this.bufferAfterMinutes,
    required this.price,
    required this.receiptNumber,
    required this.paymentMethod,
    required this.paymentStatus,
    required this.paidAmount,
    required this.selectedDate,
    required this.lateGraceMinutes,
    required this.delayWarningMinutes,
  });

  factory _TimetableEntry.fromMap(
    Map<String, dynamic> row, {
    required Map<String, Map<String, dynamic>> customers,
    required Map<String, Map<String, dynamic>> services,
    required Map<String, Map<String, dynamic>> therapists,
    required Map<String, Map<String, dynamic>> rooms,
    required Map<String, dynamic>? transaction,
    required DateTime selectedDate,
    required int lateGraceMinutes,
    required int delayWarningMinutes,
  }) {
    final customer = customers[asString(row['customerId'])];
    final service = services[asString(row['serviceId'])];
    final therapist = therapists[asString(row['therapistId'])];
    final room = rooms[asString(row['roomId'])];
    final serviceName = asString(row['serviceName']).isNotEmpty
        ? asString(row['serviceName'])
        : asString(service?['name'], 'Service');
    return _TimetableEntry(
      id: asString(row['id']),
      therapistId: asString(row['therapistId']),
      roomId: asString(row['roomId']),
      roomUnitId: asString(row['roomUnitId']),
      customerName: _displayCustomerName(
        asString(row['customerName']).isNotEmpty
            ? asString(row['customerName'])
            : asString(customer?['name']),
      ),
      customerPhone: asString(row['customerPhone']).isNotEmpty
          ? asString(row['customerPhone'])
          : asString(customer?['phone'], '-'),
      serviceName: serviceName,
      serviceCount: _readServiceCount(row['serviceItems'], serviceName),
      staffName: asString(row['therapistName']).isNotEmpty
          ? asString(row['therapistName'])
          : asString(therapist?['name'], 'Unassigned'),
      roomName: asString(row['roomName']).isNotEmpty
          ? asString(row['roomName'])
          : asString(room?['name'], 'Room'),
      roomUnitName: asString(row['roomUnitName']),
      type: asString(row['type']).toLowerCase(),
      status: asString(row['status']).toLowerCase(),
      startTime: _cleanTime(asString(row['startTime'], '09:00')),
      endTime: _cleanTime(asString(row['endTime'], '10:00')),
      startAt: asDateTime(row['startAt']),
      endAt: asDateTime(row['endAt']),
      bookedStartTime: _cleanTime(
        asString(row['bookedStartTime'], asString(row['startTime'], '09:00')),
      ),
      bookedEndTime: _cleanTime(
        asString(row['bookedEndTime'], asString(row['endTime'], '10:00')),
      ),
      actualStartedAt: asDateTime(row['actualStartedAt']),
      actualCompletedAt: asDateTime(row['actualCompletedAt']),
      bufferAfterMinutes: asInt(row['bufferAfterMinutes'], 0),
      price: asDouble(row['totalPrice']),
      receiptNumber: asString(transaction?['receiptNumber']),
      paymentMethod: asString(transaction?['paymentMethod']),
      paymentStatus: asString(row['paymentStatus'], 'unpaid'),
      paidAmount: asDouble(transaction?['totalAmount']),
      selectedDate: selectedDate,
      lateGraceMinutes: lateGraceMinutes,
      delayWarningMinutes: delayWarningMinutes,
    );
  }

  String get roomDisplayName =>
      roomUnitName.isEmpty ? roomName : '$roomName · $roomUnitName';

  int get _rowStartMinutes =>
      _minutesFromSelectedDate(startAt, selectedDate) ??
      _timeToMinutes(startTime);
  int get _rowEndMinutes {
    final fromTimestamp = _minutesFromSelectedDate(endAt, selectedDate);
    if (fromTimestamp != null) return fromTimestamp;
    final start = _rowStartMinutes;
    var end = _timeToMinutes(endTime);
    if (end <= start) end += 24 * 60;
    return end;
  }

  int get bookedStartMinutes => _timeToMinutes(bookedStartTime);
  int get bookedEndMinutes {
    final start = bookedStartMinutes;
    var end = _timeToMinutes(bookedEndTime);
    if (end <= start) end += 24 * 60;
    return end;
  }

  bool get hasActualTiming => actualStartedAt != null;
  int get startMinutes =>
      !isWalkIn && hasActualTiming ? bookedStartMinutes : _rowStartMinutes;
  int get endMinutes =>
      !isWalkIn && hasActualTiming ? bookedEndMinutes : _rowEndMinutes;
  int get durationMinutes => (endMinutes - startMinutes).clamp(0, 1440);
  int get scheduledServiceMinutes {
    final booked = bookedEndMinutes - bookedStartMinutes;
    return booked > 0 ? booked.clamp(0, 1440) : durationMinutes;
  }

  DateTime? get actualServiceEndAt {
    final actualStart = actualStartedAt?.toLocal();
    if (actualStart == null) return null;
    final completedAt = actualCompletedAt?.toLocal();
    if (completedAt != null && completedAt.isAfter(actualStart)) {
      return completedAt;
    }
    final expectedEnd = endAt?.toLocal();
    if (expectedEnd != null && expectedEnd.isAfter(actualStart)) {
      return expectedEnd;
    }
    return actualStart.add(Duration(minutes: scheduledServiceMinutes));
  }
  int get serviceStartMinutes {
    final actualStart = actualStartedAt?.toLocal();
    if (actualStart == null) return startMinutes;
    return _minutesFromSelectedDate(actualStart, selectedDate) ?? startMinutes;
  }

  int get serviceEndMinutes {
    final actualEnd = actualServiceEndAt;
    if (actualEnd == null) return endMinutes;
    return _minutesFromSelectedDate(actualEnd, selectedDate) ?? endMinutes;
  }

  int get cleanupEndMinutes =>
      serviceEndMinutes + bufferAfterMinutes.clamp(0, 240);
  int get blockDurationMinutes =>
      (cleanupEndMinutes - serviceStartMinutes).clamp(0, 1440);
  bool get isWalkIn =>
      type == 'walkin' || type == 'walk_in' || type == 'walk-in';
  bool get isCancelled => status == 'cancelled' || status == 'canceled';
  bool get isVoided => paymentStatus.toLowerCase() == 'voided';
  bool get isNoShow => status == 'no_show';
  bool get isCompleted => operationalStatus == 'Completed';
  bool get isInProgress => operationalStatus == 'In Progress';
  bool get isUpcoming =>
      operationalStatus == 'Awaiting Arrival' ||
      operationalStatus == 'Ready to Start';
  bool get hasPayment => paymentStatus.toLowerCase() == 'paid';
  bool get isServiceDateToday =>
      _stripDate(selectedDate) == _stripDate(DateTime.now());
  bool get canStartService =>
      isServiceDateToday &&
      hasPayment &&
      actualStartedAt == null &&
      (status == 'pending' || status == 'confirmed');
  bool get canSwitchTherapist =>
      therapistId.isNotEmpty &&
      !isCancelled &&
      !isVoided &&
      !isNoShow &&
      !isCompleted &&
      !serviceWindowEnded;

  bool isHappeningNow(DateTime now) {
    if (!isInProgress) return false;
    if (_stripDate(selectedDate) != _stripDate(now)) return false;
    final minutes = now.hour * 60 + now.minute;
    return minutes >= serviceStartMinutes && minutes < serviceEndMinutes;
  }

  /// Real-world moment this service is scheduled to finish (prefers the
  /// timestamptz `endAt`, falls back to the day + end-of-service minutes).
  DateTime get _serviceEndDateTime {
    final actualEnd = actualServiceEndAt;
    if (actualEnd != null) return actualEnd;
    final resolved = endAt?.toLocal();
    if (resolved != null) return resolved;
    return DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
    ).add(Duration(minutes: endMinutes));
  }

  bool get serviceWindowEnded => DateTime.now().isAfter(_serviceEndDateTime);
  bool get isServiceStartDue => !DateTime.now().isBefore(_serviceStartDateTime);

  DateTime get _serviceStartDateTime {
    final resolved = startAt?.toLocal();
    if (resolved != null) return resolved;
    return DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
    ).add(Duration(minutes: startMinutes));
  }

  bool get shouldTrackArrivalDelay =>
      !isWalkIn &&
      !isCancelled &&
      !isVoided &&
      !isNoShow &&
      status != 'completed' &&
      status != 'in_progress' &&
      actualStartedAt == null &&
      (status == 'confirmed' || status == 'pending');

  int get arrivalDelayMinutes {
    if (!shouldTrackArrivalDelay) return 0;
    final delay = DateTime.now().difference(_serviceStartDateTime).inMinutes;
    return delay < 0 ? 0 : delay;
  }

  bool get hasDelayWarning =>
      delayWarningMinutes > 0 && arrivalDelayMinutes >= delayWarningMinutes;
  bool get isLateArrival =>
      lateGraceMinutes > 0 && arrivalDelayMinutes > lateGraceMinutes;

  String get arrivalDelayLabel {
    final minutes = arrivalDelayMinutes;
    if (minutes <= 0) return '';
    if (isLateArrival) return 'Late $minutes min';
    if (hasDelayWarning) return 'Delayed $minutes min';
    return '';
  }

  // Payment can reserve a later walk-in. Only the explicit service-start
  // transition makes it operationally in progress.
  bool get isPaidWalkInInProgress =>
      isWalkIn &&
      status == 'in_progress' &&
      hasPayment &&
      !isCancelled &&
      !isVoided &&
      !serviceWindowEnded;
  bool get isWalkInCompletedByTime =>
      isWalkIn &&
      status == 'in_progress' &&
      hasPayment &&
      !isCancelled &&
      !isVoided &&
      serviceWindowEnded;
  bool get isBookingCompletedByTime =>
      !isWalkIn &&
      hasPayment &&
      status == 'in_progress' &&
      !isCancelled &&
      !isVoided &&
      serviceWindowEnded;
  String get typeLabel => isWalkIn ? 'Walk-in' : 'Booking';
  String get priceLabel => 'RM ${price.toStringAsFixed(0)}';
  String get paidLabel => 'RM ${paidAmount.toStringAsFixed(2)}';
  String get displayStartTime =>
      !isWalkIn && hasActualTiming ? bookedStartTime : startTime;
  String get displayEndTime =>
      !isWalkIn && hasActualTiming ? bookedEndTime : endTime;
  String get operationalStartTime =>
      hasActualTiming ? _minutesToTime(serviceStartMinutes) : displayStartTime;
  String get operationalEndTime =>
      hasActualTiming ? _minutesToTime(serviceEndMinutes) : displayEndTime;
  String get timeRange =>
      '${_clockLabel(displayStartTime)} - ${_clockLabel(displayEndTime)}';
  String get bookedTimeRange =>
      '${_clockLabel(bookedStartTime)} - ${_clockLabel(bookedEndTime)}';
  String get actualServiceTimeRange {
    final started = actualStartedAt?.toLocal();
    final ended = actualServiceEndAt;
    if (started == null || ended == null) return '';
    return '${DateFormat('h:mm a').format(started)} - '
        '${DateFormat('h:mm a').format(ended)}';
  }

  String get operationalTimeRange =>
      hasActualTiming && actualServiceTimeRange.isNotEmpty
      ? actualServiceTimeRange
      : timeRange;
  String get actualStartLabel => actualStartedAt == null
      ? 'Not started'
      : DateFormat('h:mm a').format(actualStartedAt!.toLocal());
  String get actualCompletedLabel => actualCompletedAt == null
      ? 'Not completed'
      : DateFormat('h:mm a').format(actualCompletedAt!.toLocal());
  String? get actualServiceCompletionLabel {
    if (actualCompletedAt != null) return 'Completed $actualCompletedLabel';
    return null;
  }

  String get durationLabel => '$timeRange ($durationMinutes min)';
  String get cleanupUntilLabel => bufferAfterMinutes <= 0
      ? 'No cleanup buffer'
      : 'Cleanup until ${_clockLabel(_minutesToTime(cleanupEndMinutes))} '
            '(+$bufferAfterMinutes min)';
  String get blockDurationLabel => bufferAfterMinutes <= 0
      ? durationLabel
      : '$timeRange ($durationMinutes min) + $bufferAfterMinutes min cleanup';

  String get operationalStatus {
    if (isVoided) return 'Voided';
    if (isCancelled) return 'Cancelled';
    if (isNoShow) return 'No Show';
    if (status == 'completed' ||
        isWalkInCompletedByTime ||
        isBookingCompletedByTime) {
      return 'Completed';
    }
    if (status == 'in_progress' || isPaidWalkInInProgress) {
      return 'In Progress';
    }
    if (arrivalDelayLabel.isNotEmpty) return arrivalDelayLabel;
    if (hasPayment && isServiceStartDue) return 'Ready to Start';
    return 'Awaiting Arrival';
  }

  bool matches(String query) {
    return customerName.toLowerCase().contains(query) ||
        serviceName.toLowerCase().contains(query) ||
        staffName.toLowerCase().contains(query) ||
        roomName.toLowerCase().contains(query) ||
        receiptNumber.toLowerCase().contains(query);
  }
}

class _TimetableTherapist {
  final String id;
  final String name;
  final String role;
  final bool available;

  const _TimetableTherapist({
    required this.id,
    required this.name,
    required this.role,
    required this.available,
  });

  factory _TimetableTherapist.fromMap(Map<String, dynamic> row) {
    return _TimetableTherapist(
      id: asString(row['id']),
      name: asString(row['name'], 'Therapist'),
      role: asString(row['role'], 'Therapist'),
      available: asBool(row['availabilityStatus'], true),
    );
  }

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isEmpty ? '?' : name[0].toUpperCase();
  }
}

List<_TimetableTherapist> _buildTherapistRows(
  List<Map<String, dynamic>> rows,
  List<_TimetableEntry> entries,
) {
  final therapists =
      rows
          .where((row) {
            final role = asString(row['role'], 'Therapist').toLowerCase();
            return role.contains('therapist');
          })
          .map(_TimetableTherapist.fromMap)
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  final knownIds = therapists.map((therapist) => therapist.id).toSet();
  final missing = <_TimetableTherapist>[];
  for (final entry in entries) {
    if (entry.therapistId.isEmpty || knownIds.contains(entry.therapistId)) {
      continue;
    }
    knownIds.add(entry.therapistId);
    missing.add(
      _TimetableTherapist(
        id: entry.therapistId,
        name: entry.staffName,
        role: 'Therapist',
        available: true,
      ),
    );
  }
  return [...therapists, ...missing];
}

class _TimetableRoom {
  final String id;
  final String name;
  final String roomType;
  final int totalSlots;
  final bool active;
  final String allocationMode;

  const _TimetableRoom({
    required this.id,
    required this.name,
    required this.roomType,
    required this.totalSlots,
    required this.active,
    required this.allocationMode,
  });

  factory _TimetableRoom.fromMap(Map<String, dynamic> row) {
    return _TimetableRoom(
      id: asString(row['id']),
      name: asString(row['name'], 'Room'),
      roomType: asString(row['roomType'], 'body_room'),
      totalSlots: asInt(row['totalSlots'], 1).clamp(1, 99),
      active: asBool(row['isActive'], true),
      allocationMode: asString(row['allocationMode'], 'capacity'),
    );
  }
}

class _TimetableRoomUnit {
  final String id;
  final String zoneId;
  final String name;
  final int unitNumber;
  final bool active;

  const _TimetableRoomUnit({
    required this.id,
    required this.zoneId,
    required this.name,
    required this.unitNumber,
    required this.active,
  });

  factory _TimetableRoomUnit.fromMap(Map<String, dynamic> row) {
    return _TimetableRoomUnit(
      id: asString(row['id']),
      zoneId: asString(row['zoneId']),
      name: asString(row['name'], 'Room'),
      unitNumber: asInt(row['unitNumber'], 1),
      active: asBool(row['isActive'], true),
    );
  }
}

List<_TimetableRoom> _buildRoomRows(
  List<Map<String, dynamic>> rows,
  List<_TimetableEntry> entries,
) {
  final rooms = rows.map(_TimetableRoom.fromMap).toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  final knownIds = rooms.map((room) => room.id).toSet();
  final missing = <_TimetableRoom>[];
  for (final entry in entries) {
    if (entry.roomId.isEmpty || knownIds.contains(entry.roomId)) continue;
    knownIds.add(entry.roomId);
    missing.add(
      _TimetableRoom(
        id: entry.roomId,
        name: entry.roomName,
        roomType: 'body_room',
        totalSlots: 1,
        active: true,
        allocationMode: 'capacity',
      ),
    );
  }
  return [...rooms, ...missing];
}

class _TimetableResource {
  final String id;
  final String name;
  final String subtitle;
  final int capacity;
  final bool available;
  final String avatarText;
  final IconData? avatarIcon;
  final String resourceType;
  final Color accentColor;
  final bool Function(_TimetableEntry entry) matches;

  const _TimetableResource({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.capacity,
    required this.available,
    required this.avatarText,
    required this.avatarIcon,
    required this.resourceType,
    required this.accentColor,
    required this.matches,
  });

  bool get isRoom => resourceType == 'room';
}

class _ResourceStatus {
  final String label;
  final Color color;

  const _ResourceStatus(this.label, this.color);
}

_ResourceStatus _resourceStatus({
  required _TimetableResource resource,
  required List<_TimetableEntry> entries,
  required int nowMinutes,
  required bool selectedToday,
}) {
  if (!resource.available) {
    return const _ResourceStatus('Unavailable', Color(0xFF6B7280));
  }
  if (!selectedToday) {
    return const _ResourceStatus('Scheduled', Color(0xFF6B7280));
  }
  final active = entries
      .where(
        (e) =>
            !e.isVoided &&
            nowMinutes >= e.serviceStartMinutes &&
            nowMinutes < e.cleanupEndMinutes,
      )
      .toList();
  if (resource.capacity <= 1) {
    if (active.isEmpty) {
      return const _ResourceStatus('Available now', Color(0xFF10B981));
    }
    final entry = active.first;
    if (nowMinutes >= entry.serviceEndMinutes) {
      return _ResourceStatus(
        'Cleaning until ${_clockLabel(_minutesToTime(entry.cleanupEndMinutes))}',
        const Color(0xFFF59E0B),
      );
    }
    return _ResourceStatus(
      'Busy until ${_clockLabel(_minutesToTime(entry.serviceEndMinutes))}',
      const Color(0xFFF97316),
    );
  }
  final used = active.length;
  final cleaning = active
      .where((entry) => nowMinutes >= entry.serviceEndMinutes)
      .length;
  final freeSlots = (resource.capacity - used).clamp(0, resource.capacity);
  if (used == 0) {
    return const _ResourceStatus('Available now', Color(0xFF10B981));
  }
  if (cleaning == used) {
    return _ResourceStatus('$cleaning cleaning', const Color(0xFFF59E0B));
  }
  if (freeSlots > 0) {
    return _ResourceStatus('$freeSlots available now', const Color(0xFF10B981));
  }
  final nextFree = active
      .map((entry) => entry.serviceEndMinutes)
      .reduce((a, b) => a < b ? a : b);
  return _ResourceStatus(
    'Full until ${_clockLabel(_minutesToTime(nextFree))}',
    const Color(0xFFF97316),
  );
}

class _TimetableStats {
  final int inProgress;
  final int upcoming;
  final int completed;
  final int busy;
  final int free;

  const _TimetableStats({
    required this.inProgress,
    required this.upcoming,
    required this.completed,
    required this.busy,
    required this.free,
  });

  factory _TimetableStats.fromEntries(
    List<_TimetableEntry> entries, {
    required List<_TimetableResource> resources,
    required DateTime selectedDate,
  }) {
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final selectedToday = _stripDate(selectedDate) == _stripDate(now);
    final active = selectedToday
        ? entries.where((entry) => entry.isHappeningNow(now)).toList()
        : <_TimetableEntry>[];
    var busy = 0;
    var free = 0;
    for (final resource in resources) {
      if (!resource.available) continue;
      final used = selectedToday
          ? entries
                .where(
                  (e) =>
                      !e.isVoided &&
                      resource.matches(e) &&
                      nowMinutes >= e.serviceStartMinutes &&
                      nowMinutes < e.cleanupEndMinutes,
                )
                .length
          : 0;
      if (used > 0) busy++;
      if (used < resource.capacity) free++;
    }
    return _TimetableStats(
      inProgress: active.length,
      upcoming: entries.where((entry) => entry.isUpcoming).length,
      completed: entries.where((entry) => entry.isCompleted).length,
      busy: busy,
      free: free,
    );
  }
}

class _TimetableHeader extends StatelessWidget {
  final DateTime selectedDate;
  final VoidCallback onBack;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onPickDate;
  final VoidCallback onToday;
  final VoidCallback onRefresh;
  final VoidCallback onSettings;

  const _TimetableHeader({
    required this.selectedDate,
    required this.onBack,
    required this.onPrevious,
    required this.onNext,
    required this.onPickDate,
    required this.onToday,
    required this.onRefresh,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.of(context).size.width < 900;
    final isToday = _stripDate(selectedDate) == _stripDate(DateTime.now());
    final dateLabel = compact
        ? DateFormat('EEE, d MMM yyyy').format(selectedDate)
        : DateFormat('EEEE, d MMMM yyyy').format(selectedDate);

    final menuButton = _SquareIconButton.menu(
      tooltip: 'More timetable actions',
      onSelected: (value) {
        if (value == 'refresh') onRefresh();
        if (value == 'settings') onSettings();
      },
    );
    final backButton = _SquareIconButton(
      icon: Icons.arrow_back_rounded,
      tooltip: 'Back',
      onPressed: onBack,
    );
    final dateText = Text(
      isToday ? 'Today · $dateLabel' : dateLabel,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
        color: isToday ? const Color(0xFF0F766E) : const Color(0xFF6B7280),
      ),
    );

    if (compact) {
      // Two rows on phones: title row, then the date controls. A single
      // row truncates both the title and the date.
      return Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xFFEEF1F4))),
        ),
        child: Column(
          children: [
            Row(
              children: [
                backButton,
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Daily Timetable',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF0F172A),
                      height: 1.05,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                menuButton,
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _SquareIconButton(
                  icon: Icons.chevron_left,
                  tooltip: 'Previous day',
                  onPressed: onPrevious,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: InkWell(
                    onTap: onPickDate,
                    borderRadius: BorderRadius.circular(11),
                    child: Container(
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.calendar_today_outlined,
                            size: 15,
                            color: Color(0xFF334155),
                          ),
                          const SizedBox(width: 8),
                          Flexible(child: dateText),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                _SquareIconButton(
                  icon: Icons.chevron_right,
                  tooltip: 'Next day',
                  onPressed: onNext,
                ),
                if (!isToday) ...[
                  const SizedBox(width: 7),
                  _TodayButton(onPressed: onToday),
                ],
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFEEF1F4))),
      ),
      child: Row(
        children: [
          backButton,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Daily Timetable',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0F172A),
                    height: 1.05,
                  ),
                ),
                const SizedBox(height: 2),
                dateText,
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (!isToday) ...[
            _TodayButton(onPressed: onToday),
            const SizedBox(width: 7),
          ],
          _SquareIconButton(
            icon: Icons.calendar_today_outlined,
            iconSize: 17,
            tooltip: 'Pick date',
            onPressed: onPickDate,
          ),
          const SizedBox(width: 7),
          _SquareIconButton(
            icon: Icons.chevron_left,
            tooltip: 'Previous day',
            onPressed: onPrevious,
          ),
          const SizedBox(width: 7),
          _SquareIconButton(
            icon: Icons.chevron_right,
            tooltip: 'Next day',
            onPressed: onNext,
          ),
          const SizedBox(width: 7),
          menuButton,
        ],
      ),
    );
  }
}

/// One-tap jump back to today, shown only while browsing another day.
class _TodayButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _TodayButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(11),
          side: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(11),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Text(
                'Today',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F766E),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Standardised outlined square icon button used across the timetable header.
class _SquareIconButton extends StatelessWidget {
  final IconData? icon;
  final double iconSize;
  final String tooltip;
  final VoidCallback? onPressed;
  final ValueChanged<String>? onSelected;

  const _SquareIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 20,
  }) : onSelected = null;

  const _SquareIconButton.menu({
    required this.tooltip,
    required this.onSelected,
  }) : icon = null,
       iconSize = 20,
       onPressed = null;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(11),
      side: const BorderSide(color: Color(0xFFE2E8F0)),
    );
    if (onSelected != null) {
      return SizedBox(
        width: 40,
        height: 40,
        child: Material(
          color: Colors.white,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: PopupMenuButton<String>(
            tooltip: tooltip,
            onSelected: onSelected,
            icon: const Icon(
              Icons.more_vert,
              size: 20,
              color: Color(0xFF334155),
            ),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'refresh',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('Refresh'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'settings',
                child: ListTile(
                  leading: Icon(Icons.settings_outlined),
                  title: Text('Settings'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      width: 40,
      height: 40,
      child: Material(
        color: Colors.white,
        shape: shape,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(11),
          child: Tooltip(
            message: tooltip,
            child: Icon(icon, size: iconSize, color: const Color(0xFF334155)),
          ),
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final _TimetableStats stats;
  final String mode;
  final bool compact;
  final DateTime selectedDate;

  const _StatsRow({
    required this.stats,
    required this.mode,
    required this.compact,
    required this.selectedDate,
  });

  @override
  Widget build(BuildContext context) {
    final busyLabel = mode == 'rooms' ? 'Zones Busy' : 'Staff Busy';
    final freeLabel = mode == 'rooms' ? 'Zones Free' : 'Free Now';
    if (compact) {
      final cards = [
        _OverviewStatCard(
          label: 'In Progress',
          value: stats.inProgress,
          color: const Color(0xFF2563EB),
          icon: Icons.access_time_filled_rounded,
        ),
        _OverviewStatCard(
          label: 'Awaiting',
          value: stats.upcoming,
          color: const Color(0xFFF59E0B),
          icon: Icons.hourglass_bottom_rounded,
        ),
        _OverviewStatCard(
          label: 'Completed',
          value: stats.completed,
          color: const Color(0xFF059669),
          icon: Icons.check_circle_rounded,
        ),
        _OverviewStatCard(
          label: mode == 'rooms' ? 'Zones Free' : 'Free Now',
          value: stats.free,
          color: const Color(0xFF64748B),
          icon: mode == 'rooms'
              ? Icons.meeting_room_outlined
              : Icons.sentiment_satisfied_alt_rounded,
        ),
      ];
      return Row(
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            Expanded(child: cards[i]),
            if (i != cards.length - 1) const SizedBox(width: 8),
          ],
        ],
      );
    }
    final cards = [
      _StatChip(
        'In Progress',
        stats.inProgress,
        const Color(0xFF0EA5E9),
        icon: Icons.schedule_outlined,
      ),
      _StatChip(
        'Awaiting Arrival',
        stats.upcoming,
        const Color(0xFF2563EB),
        icon: Icons.event_note_outlined,
      ),
      _StatChip(
        'Completed',
        stats.completed,
        const Color(0xFF059669),
        icon: Icons.check_circle_outline,
      ),
      _StatChip(
        busyLabel,
        stats.busy,
        const Color(0xFFF97316),
        icon: mode == 'rooms'
            ? Icons.meeting_room_outlined
            : Icons.person_off_outlined,
      ),
      _StatChip(
        freeLabel,
        stats.free,
        const Color(0xFF10B981),
        icon: mode == 'rooms'
            ? Icons.meeting_room_outlined
            : Icons.person_outline,
      ),
    ];
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

class _OverviewStatCard extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  final IconData icon;

  const _OverviewStatCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE6EAEF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 14, color: color),
              ),
              const SizedBox(width: 7),
              Text(
                '$value',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF0F172A),
                  height: 1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF64748B),
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

// Top-level Overview | Timetable segmented toggle.
class _ViewToggle extends StatelessWidget {
  final String view;
  final ValueChanged<String> onChanged;

  const _ViewToggle({required this.view, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          _ViewToggleButton(
            label: 'Overview',
            icon: Icons.grid_view_rounded,
            active: view == 'overview',
            onTap: () => onChanged('overview'),
          ),
          _ViewToggleButton(
            label: 'Timetable',
            icon: Icons.calendar_view_week_rounded,
            active: view == 'timetable',
            onTap: () => onChanged('timetable'),
          ),
        ],
      ),
    );
  }
}

class _ViewToggleButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _ViewToggleButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? _timetableAccent : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: active
                ? const [
                    BoxShadow(
                      color: Color(0x260F766E),
                      blurRadius: 8,
                      offset: Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: active ? Colors.white : const Color(0xFF64748B),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: active ? Colors.white : const Color(0xFF64748B),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResourceFilterPanel extends StatelessWidget {
  final String mode;
  final List<_TimetableResource> resources;
  final List<_TimetableEntry> entries;
  final DateTime selectedDate;
  final Set<String> selectedIds;
  final VoidCallback onHide;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  const _ResourceFilterPanel({
    required this.mode,
    required this.resources,
    required this.entries,
    required this.selectedDate,
    required this.selectedIds,
    required this.onHide,
    required this.onToggle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final isRoom = mode == 'rooms';
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final selectedToday = _stripDate(selectedDate) == _stripDate(now);
    final allSelected = selectedIds.isEmpty;
    final title = isRoom ? 'Zones' : 'Therapists';
    final allLabel = isRoom ? 'All Zones' : 'All Staff';
    final allSubtitle = isRoom
        ? '${resources.length} zones'
        : '${resources.length} staff';
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFEEF1F4))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                isRoom ? Icons.spa_outlined : Icons.groups_2_outlined,
                size: 18,
                color: _timetableAccent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: allSelected ? onHide : onClear,
                icon: Icon(
                  allSelected
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.chevron_right_rounded,
                  size: 18,
                ),
                label: Text(allSelected ? 'Hide' : 'View all'),
                style: TextButton.styleFrom(
                  foregroundColor: _timetableAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 34),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 86,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: resources.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _ResourceFilterCard(
                    icon: isRoom ? Icons.spa_outlined : null,
                    avatarText: isRoom ? '' : 'A',
                    title: allLabel,
                    subtitle: allSubtitle,
                    color: _timetableAccent,
                    selected: allSelected,
                    onTap: onClear,
                  );
                }
                final resource = resources[index - 1];
                final resourceEntries = entries
                    .where(resource.matches)
                    .toList();
                final status = _resourceStatus(
                  resource: resource,
                  entries: resourceEntries,
                  nowMinutes: nowMinutes,
                  selectedToday: selectedToday,
                );
                final statusLabel = isRoom
                    ? '${resource.capacity} lanes'
                    : status.label.contains('Busy')
                    ? 'Busy'
                    : status.label.contains('Cleaning')
                    ? 'Cleaning'
                    : resource.available
                    ? 'Available'
                    : 'Unavailable';
                return _ResourceFilterCard(
                  icon: resource.avatarIcon,
                  avatarText: resource.avatarText,
                  title: resource.name,
                  subtitle: statusLabel,
                  color: resource.accentColor,
                  statusColor: status.color,
                  selected: selectedIds.contains(resource.id),
                  onTap: () => onToggle(resource.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ResourceFilterCard extends StatelessWidget {
  final IconData? icon;
  final String avatarText;
  final String title;
  final String subtitle;
  final Color color;
  final Color? statusColor;
  final bool selected;
  final VoidCallback onTap;

  const _ResourceFilterCard({
    required this.icon,
    required this.avatarText,
    required this.title,
    required this.subtitle,
    required this.color,
    this.statusColor,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dotColor = statusColor ?? color;
    return SizedBox(
      width: 136,
      child: Material(
        color: selected ? color.withValues(alpha: 0.08) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected
                ? color.withValues(alpha: 0.75)
                : const Color(0xFFE2E8F0),
            width: selected ? 1.4 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: icon == null
                      ? Text(
                          avatarText.isEmpty ? '?' : avatarText[0],
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            color: color,
                          ),
                        )
                      : Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (statusColor != null) ...[
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: dotColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                          ],
                          Expanded(
                            child: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF64748B),
                              ),
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
        ),
      ),
    );
  }
}

String _overviewDuration(int minutes) {
  if (minutes <= 0) return 'now';
  if (minutes < 60) return '$minutes min${minutes == 1 ? '' : 's'}';
  final hours = minutes ~/ 60;
  final mins = minutes % 60;
  if (mins == 0) return '$hours hr${hours == 1 ? '' : 's'}';
  return '$hours hr $mins min${mins == 1 ? '' : 's'}';
}

// "Running status at a glance" page — the Overview tab.
class _TimetableOverview extends StatelessWidget {
  final bool loading;
  final String? error;
  final List<_TimetableEntry> entries;
  final List<_TimetableTherapist> therapists;
  final List<_TimetableRoom> rooms;
  final List<_TimetableRoomUnit> roomUnits;
  final DateTime selectedDate;
  final ValueChanged<_TimetableEntry> onTapEntry;
  final void Function([String? mode]) onOpenTimetable;

  const _TimetableOverview({
    required this.loading,
    required this.error,
    required this.entries,
    required this.therapists,
    required this.rooms,
    required this.roomUnits,
    required this.selectedDate,
    required this.onTapEntry,
    required this.onOpenTimetable,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return ListView(
        padding: const EdgeInsets.all(14),
        children: const [
          _TimetableStateCard(
            icon: Icons.hourglass_empty,
            title: 'Loading overview',
            message: "Checking today's live status.",
          ),
        ],
      );
    }
    if (error != null) {
      return ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _TimetableStateCard(
            icon: Icons.error_outline,
            title: 'Unable to load overview',
            message: error!,
          ),
        ],
      );
    }

    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final selectedToday = _stripDate(selectedDate) == _stripDate(now);

    final inProgress =
        (selectedToday
              ? entries.where((e) => e.isHappeningNow(now)).toList()
              : <_TimetableEntry>[])
          ..sort((a, b) => a.serviceEndMinutes.compareTo(b.serviceEndMinutes));
    final upNext = entries.where((e) => e.isUpcoming).toList()
      ..sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
    final busyTherapistIds = inProgress
        .map((e) => e.therapistId)
        .where((id) => id.isNotEmpty)
        .toSet();
    final freeTherapists = therapists
        .where((t) => t.available && !busyTherapistIds.contains(t.id))
        .toList();

    void showMore(
      String title,
      List<_TimetableEntry> items,
      Widget Function(BuildContext sheetContext, _TimetableEntry entry)
      rowBuilder, {
      bool contained = false,
    }) {
      _showOverviewMoreSheet(
        context: context,
        title: title,
        itemCount: items.length,
        contained: contained,
        itemBuilder: (sheetContext, index) =>
            rowBuilder(sheetContext, items[index]),
      );
    }

    void showAllInProgress() => showMore(
      'In Progress Now',
      inProgress,
      (sheetContext, entry) => _OverviewInProgressCard(
        entry: entry,
        selectedToday: selectedToday,
        nowMinutes: nowMinutes,
        onTap: () {
          Navigator.of(sheetContext).pop();
          onTapEntry(entry);
        },
      ),
    );

    Widget inProgressSection({int? cap, bool useSheetForViewAll = false}) {
      final visible = cap == null ? inProgress : inProgress.take(cap).toList();
      final hidden = inProgress.length - visible.length;
      return _OverviewPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _OverviewSectionHeader(
              title: 'In Progress Now (${inProgress.length})',
              onViewAll: useSheetForViewAll && inProgress.isNotEmpty
                  ? showAllInProgress
                  : () => onOpenTimetable('staff'),
            ),
            const SizedBox(height: 10),
            if (inProgress.isEmpty)
              const _OverviewEmptyHint(
                icon: Icons.timelapse_outlined,
                message: 'No services are in progress right now.',
              )
            else ...[
              for (var i = 0; i < visible.length; i++) ...[
                _OverviewInProgressCard(
                  entry: visible[i],
                  selectedToday: selectedToday,
                  nowMinutes: nowMinutes,
                  onTap: () => onTapEntry(visible[i]),
                ),
                if (i != visible.length - 1) const SizedBox(height: 8),
              ],
              if (hidden > 0) ...[
                const SizedBox(height: 8),
                _OverviewMoreRow(count: hidden, onTap: showAllInProgress),
              ],
            ],
          ],
        ),
      );
    }

    Widget freeTherapistsSection() => _OverviewPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _OverviewSectionHeader(
            title: 'Therapist Availability (${freeTherapists.length})',
            onViewAll: () => onOpenTimetable('staff'),
          ),
          const SizedBox(height: 10),
          if (freeTherapists.isEmpty)
            const _OverviewEmptyHint(
              icon: Icons.people_outline,
              message: 'Every therapist is currently busy.',
            )
          else
            LayoutBuilder(
              builder: (context, chipConstraints) {
                const gap = 10.0;
                final columns = (chipConstraints.maxWidth / 190).floor().clamp(
                  1,
                  4,
                );
                final width =
                    (chipConstraints.maxWidth - gap * (columns - 1)) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final therapist in freeTherapists)
                      SizedBox(
                        width: width,
                        child: _OverviewFreeChip(
                          therapist: therapist,
                          compact: true,
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );

    Widget zonesSection() {
      final zonesWithUnits =
          rooms
              .where((room) => roomUnits.any((unit) => unit.zoneId == room.id))
              .toList()
            ..sort((a, b) {
              int rank(_TimetableRoom room) {
                final name = room.name.toLowerCase();
                if (name.contains('ground')) return 0;
                if (name.contains('upper')) return 1;
                return 2;
              }

              final byRank = rank(a).compareTo(rank(b));
              return byRank != 0 ? byRank : a.name.compareTo(b.name);
            });
      final capacityZones =
          rooms
              .where((room) => !roomUnits.any((unit) => unit.zoneId == room.id))
              .toList()
            ..sort((a, b) {
              int rank(_TimetableRoom room) =>
                  room.name.toLowerCase().contains('ground') ? 0 : 1;
              final byRank = rank(a).compareTo(rank(b));
              return byRank != 0 ? byRank : a.name.compareTo(b.name);
            });

      Widget groupLabel(String label) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: Color(0xFF64748B),
          ),
        ),
      );

      Widget roomUnitRow(_TimetableRoom zone) {
        final units = roomUnits.where((unit) => unit.zoneId == zone.id).toList()
          ..sort((a, b) => a.unitNumber.compareTo(b.unitNumber));
        return LayoutBuilder(
          builder: (context, constraints) {
            const gap = 8.0;
            final width = (constraints.maxWidth - gap * 2) / 3;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < units.length; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  SizedBox(
                    width: width,
                    child: _OverviewRoomUnitCard(
                      zone: zone,
                      unit: units[i],
                      entries: entries,
                      nowMinutes: nowMinutes,
                      selectedToday: selectedToday,
                    ),
                  ),
                ],
              ],
            );
          },
        );
      }

      Widget capacityZoneRow() => LayoutBuilder(
        builder: (context, constraints) {
          const gap = 10.0;
          final width = (constraints.maxWidth - gap) / 2;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final room in capacityZones)
                SizedBox(
                  width: width,
                  child: _OverviewZoneCard(
                    room: room,
                    compact: true,
                    occupied: entries
                        .where(
                          (entry) =>
                              entry.roomId == room.id &&
                              entry.isHappeningNow(now),
                        )
                        .length,
                  ),
                ),
            ],
          );
        },
      );

      return _OverviewPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _OverviewSectionHeader(
              title: 'Zones Live Status',
              onViewAll: () => onOpenTimetable('rooms'),
            ),
            const SizedBox(height: 10),
            if (rooms.isEmpty)
              const _OverviewEmptyHint(
                icon: Icons.meeting_room_outlined,
                message: 'No zones found.',
              )
            else ...[
              for (var i = 0; i < zonesWithUnits.length; i++) ...[
                groupLabel(
                  zonesWithUnits[i].name.toLowerCase().contains('ground')
                      ? 'Ground Massage Rooms'
                      : zonesWithUnits[i].name.toLowerCase().contains('upper')
                      ? 'Upper Massage Rooms'
                      : zonesWithUnits[i].name,
                ),
                roomUnitRow(zonesWithUnits[i]),
                if (i != zonesWithUnits.length - 1 || capacityZones.isNotEmpty)
                  const SizedBox(height: 12),
              ],
              if (capacityZones.isNotEmpty) ...[
                groupLabel('Foot Zones'),
                capacityZoneRow(),
              ],
            ],
          ],
        ),
      );
    }

    Widget upNextSection({int? cap}) {
      final visible = cap == null ? upNext : upNext.take(cap).toList();
      final hidden = upNext.length - visible.length;
      return _OverviewPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _OverviewSectionHeader(
              title: 'Up Next (${upNext.length})',
              onViewAll: () => onOpenTimetable('staff'),
            ),
            const SizedBox(height: 10),
            if (upNext.isEmpty)
              const _OverviewEmptyHint(
                icon: Icons.event_available_outlined,
                message: 'No upcoming bookings for this day.',
              )
            else
              _OverviewContainedList(
                itemCount: visible.length,
                itemBuilder: (index) => _OverviewUpNextRow(
                  entry: visible[index],
                  selectedToday: selectedToday,
                  nowMinutes: nowMinutes,
                  onTap: () => onTapEntry(visible[index]),
                ),
                trailingBuilder: hidden > 0
                    ? () => _OverviewMoreRow(
                        count: hidden,
                        onTap: () => showMore(
                          'Up Next',
                          upNext,
                          (sheetContext, entry) => _OverviewUpNextRow(
                            entry: entry,
                            selectedToday: selectedToday,
                            nowMinutes: nowMinutes,
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              onTapEntry(entry);
                            },
                          ),
                          contained: true,
                        ),
                      )
                    : null,
              ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final tablet = constraints.maxWidth >= 900;
        if (!tablet) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 28),
            children: [
              inProgressSection(cap: 3, useSheetForViewAll: true),
              const SizedBox(height: 14),
              zonesSection(),
              const SizedBox(height: 14),
              upNextSection(),
              const SizedBox(height: 14),
              freeTherapistsSection(),
            ],
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: inProgressSection(cap: 3)),
                  const SizedBox(width: 16),
                  Expanded(child: zonesSection()),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: upNextSection(cap: 4)),
                  const SizedBox(width: 16),
                  Expanded(child: freeTherapistsSection()),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _OverviewContainedList extends StatelessWidget {
  final int itemCount;
  final Widget Function(int index) itemBuilder;
  final Widget Function()? trailingBuilder;

  const _OverviewContainedList({
    required this.itemCount,
    required this.itemBuilder,
    this.trailingBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE6EAEF)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < itemCount; i++) ...[
            itemBuilder(i),
            if (i != itemCount - 1 || trailingBuilder != null)
              const Divider(height: 1, color: Color(0xFFEEF1F4)),
          ],
          if (trailingBuilder != null) trailingBuilder!(),
        ],
      ),
    );
  }
}

class _OverviewMoreRow extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _OverviewMoreRow({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              '+$count more',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F766E),
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.chevron_right, size: 16, color: Color(0xFF0F766E)),
          ],
        ),
      ),
    );
  }
}

/// Opens a right-side sheet listing the complete set of items for a section
/// (used by the overview "+X more" rows), so the dashboard itself stays
/// compact instead of expanding.
Future<void> _showOverviewMoreSheet({
  required BuildContext context,
  required String title,
  required int itemCount,
  required Widget Function(BuildContext sheetContext, int index) itemBuilder,
  bool contained = false,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: const Color(0x33000000),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) {
      final width = MediaQuery.of(context).size.width;
      final sheetWidth = width < 520 ? width : 440.0;
      return Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: Colors.white,
          child: SizedBox(
            width: sheetWidth,
            height: double.infinity,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 8, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded),
                          color: const Color(0xFF334155),
                          tooltip: 'Close',
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFFEEF1F4)),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.all(14),
                      itemCount: itemCount,
                      separatorBuilder: (_, _) => contained
                          ? const Divider(height: 1, color: Color(0xFFEEF1F4))
                          : const SizedBox(height: 10),
                      itemBuilder: itemBuilder,
                    ),
                  ),
                ],
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
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
  );
}

class _OverviewPanel extends StatelessWidget {
  final Widget child;

  const _OverviewPanel({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE6EAEF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x05000000),
            blurRadius: 14,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _OverviewSectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback onViewAll;

  const _OverviewSectionHeader({required this.title, required this.onViewAll});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: Color(0xFF0F172A),
            ),
          ),
        ),
        InkWell(
          onTap: onViewAll,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: const [
                Text(
                  'View all',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F766E),
                  ),
                ),
                SizedBox(width: 2),
                Icon(Icons.chevron_right, size: 17, color: Color(0xFF0F766E)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _OverviewEmptyHint extends StatelessWidget {
  final IconData icon;
  final String message;

  const _OverviewEmptyHint({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE6EAEF)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFF94A3B8)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF64748B),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewPill extends StatelessWidget {
  final String label;
  final Color color;

  const _OverviewPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

class _OverviewInProgressCard extends StatelessWidget {
  final _TimetableEntry entry;
  final bool selectedToday;
  final int nowMinutes;
  final VoidCallback onTap;

  const _OverviewInProgressCard({
    required this.entry,
    required this.selectedToday,
    required this.nowMinutes,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = const Color(0xFF0F766E);
    final total = (entry.serviceEndMinutes - entry.serviceStartMinutes).clamp(
      1,
      1440,
    );
    final elapsed = selectedToday
        ? (nowMinutes - entry.serviceStartMinutes).clamp(0, total)
        : 0;
    final remaining = (total - elapsed).clamp(0, total);
    final progress = elapsed / total;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE6EAEF)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.person_outline, color: accent, size: 21),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                entry.customerName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                            ),
                            const SizedBox(width: 7),
                            const _OverviewPill(
                              label: 'In Progress',
                              color: Color(0xFF0F766E),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${entry.serviceName} / ${entry.roomDisplayName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Ends ${_clockLabel(_minutesToTime(entry.serviceEndMinutes))}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${_overviewDuration(total)} service',
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  const Icon(
                    Icons.badge_outlined,
                    size: 13,
                    color: Color(0xFF64748B),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      entry.staffName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF475569),
                      ),
                    ),
                  ),
                  Text(
                    'Started ${_clockLabel(_minutesToTime(entry.serviceStartMinutes))} / ${_overviewDuration(elapsed)} elapsed',
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 5,
                        backgroundColor: const Color(0xFFE2E8F0),
                        valueColor: const AlwaysStoppedAnimation(
                          Color(0xFF0F9D8A),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${_overviewDuration(remaining)} left',
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F766E),
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

class _OverviewFreeChip extends StatelessWidget {
  final _TimetableTherapist therapist;
  final bool compact;

  const _OverviewFreeChip({required this.therapist, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final accent = _avatarColor(therapist.name);
    final avatarSize = compact ? 28.0 : 34.0;
    return Container(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 7)
          : const EdgeInsets.fromLTRB(10, 9, 16, 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE6EAEF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: avatarSize,
            height: avatarSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Text(
              therapist.initials,
              style: TextStyle(
                fontSize: compact ? 11.5 : 13,
                fontWeight: FontWeight.w900,
                color: accent,
              ),
            ),
          ),
          SizedBox(width: compact ? 7 : 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _shortCustomerName(therapist.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 12 : 13.5,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF0F172A),
                  ),
                ),
                SizedBox(height: compact ? 1 : 3),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _StatusDot(color: Color(0xFF10B981)),
                    const SizedBox(width: 5),
                    Text(
                      compact ? 'Free' : 'Free now',
                      style: TextStyle(
                        fontSize: compact ? 10.5 : 11.5,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF059669),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final Color color;

  const _StatusDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _OverviewRoomUnitCard extends StatelessWidget {
  final _TimetableRoom zone;
  final _TimetableRoomUnit unit;
  final List<_TimetableEntry> entries;
  final int nowMinutes;
  final bool selectedToday;

  const _OverviewRoomUnitCard({
    required this.zone,
    required this.unit,
    required this.entries,
    required this.nowMinutes,
    required this.selectedToday,
  });

  @override
  Widget build(BuildContext context) {
    final active = entries
        .where(
          (entry) =>
              !entry.isVoided &&
              entry.roomUnitId == unit.id &&
              selectedToday &&
              nowMinutes >= entry.serviceStartMinutes &&
              nowMinutes < entry.cleanupEndMinutes,
        )
        .toList();
    final entry = active.isEmpty ? null : active.first;
    final cleaning = entry != null && nowMinutes >= entry.serviceEndMinutes;
    final status = !selectedToday
        ? 'Scheduled'
        : cleaning
        ? 'Cleaning'
        : entry != null
        ? 'Occupied'
        : 'Available';
    final color = !selectedToday
        ? const Color(0xFF64748B)
        : cleaning
        ? const Color(0xFFF59E0B)
        : entry != null
        ? const Color(0xFFF97316)
        : const Color(0xFF059669);
    final detail = entry == null
        ? (selectedToday ? 'Ready now' : 'View schedule')
        : cleaning
        ? 'Until ${_clockLabel(_minutesToTime(entry.cleanupEndMinutes))}'
        : '${entry.customerName} until ${_clockLabel(_minutesToTime(entry.serviceEndMinutes))}';

    return Container(
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE6EAEF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.meeting_room_outlined,
                  size: 15,
                  color: color,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  unit.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            zone.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _StatusDot(color: color),
              const SizedBox(width: 5),
              Text(
                status,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w900,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Color(0xFF64748B),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewZoneCard extends StatelessWidget {
  final _TimetableRoom room;
  final int occupied;
  final bool compact;

  const _OverviewZoneCard({
    required this.room,
    required this.occupied,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = _roomAccentColor(room.roomType);
    final capacity = room.totalSlots.clamp(1, 99);
    final used = occupied.clamp(0, capacity);
    final free = capacity - used;
    final fullyOccupied = free <= 0;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 12,
        vertical: compact ? 6 : 14,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE6EAEF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: compact ? 28 : 40,
            height: compact ? 28 : 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _roomIcon(room.roomType),
              size: compact ? 15 : 20,
              color: accent,
            ),
          ),
          SizedBox(height: compact ? 4 : 8),
          SizedBox(
            height: compact ? 28 : 34,
            child: Center(
              child: Text(
                room.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 10.5 : 12.5,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF0F172A),
                  height: 1.15,
                ),
              ),
            ),
          ),
          SizedBox(height: compact ? 3 : 8),
          Text(
            '$used used · $free free',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 10 : 11.5,
              fontWeight: FontWeight.w800,
              color: fullyOccupied ? const Color(0xFFDC2626) : accent,
            ),
          ),
          SizedBox(height: compact ? 3 : 8),
          _OverviewCapacityDots(
            used: used,
            capacity: capacity,
            activeColor: fullyOccupied ? const Color(0xFFDC2626) : accent,
          ),
          if (!compact) ...[
            const SizedBox(height: 8),
            _OverviewPill(
              label: '$capacity total capacity',
              color: fullyOccupied ? const Color(0xFFDC2626) : accent,
            ),
          ],
        ],
      ),
    );
  }
}

class _OverviewCapacityDots extends StatelessWidget {
  final int used;
  final int capacity;
  final Color activeColor;

  const _OverviewCapacityDots({
    required this.used,
    required this.capacity,
    required this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final visible = capacity.clamp(1, 8).toInt();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < visible; i++) ...[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: i < used ? activeColor : const Color(0xFFCBD5E1),
              shape: BoxShape.circle,
            ),
          ),
          if (i != visible - 1) const SizedBox(width: 7),
        ],
      ],
    );
  }
}

class _OverviewUpNextRow extends StatelessWidget {
  final _TimetableEntry entry;
  final bool selectedToday;
  final int nowMinutes;
  final VoidCallback onTap;

  const _OverviewUpNextRow({
    required this.entry,
    required this.selectedToday,
    required this.nowMinutes,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final untilStart = entry.startMinutes - nowMinutes;
    final inLabel = selectedToday && untilStart > 0
        ? 'In ${_overviewDuration(untilStart)}'
        : null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 76,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _clockLabel(entry.displayStartTime),
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFF59E0B),
                    ),
                  ),
                  if (inLabel != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      inLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.customerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const Icon(
                        Icons.place_outlined,
                        size: 12,
                        color: Color(0xFF94A3B8),
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          '${entry.serviceName} / ${entry.roomDisplayName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const _OverviewPill(label: 'Awaiting', color: Color(0xFFF59E0B)),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  final IconData icon;

  const _StatChip(this.label, this.value, this.color, {required this.icon});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.22)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x07000000),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 22, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$value',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111827),
                      height: 1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF475569),
                          ),
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

class _TimetableControls extends StatefulWidget {
  final String mode;
  final TextEditingController controller;
  final ValueChanged<String> onModeChanged;
  final List<_TimetableResource> resources;
  final List<_TimetableEntry> entries;
  final DateTime selectedDate;
  final Set<String> selectedIds;
  final bool filterExpanded;
  final VoidCallback onToggleFilter;
  final ValueChanged<String> onToggleResource;
  final VoidCallback onClearResources;

  const _TimetableControls({
    required this.mode,
    required this.controller,
    required this.onModeChanged,
    required this.resources,
    required this.entries,
    required this.selectedDate,
    required this.selectedIds,
    required this.filterExpanded,
    required this.onToggleFilter,
    required this.onToggleResource,
    required this.onClearResources,
  });

  @override
  State<_TimetableControls> createState() => _TimetableControlsState();
}

class _TimetableControlsState extends State<_TimetableControls> {
  bool _searchExpanded = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 620;
        final modes = _ModeSelector(
          mode: widget.mode,
          onChanged: widget.onModeChanged,
        );
        final search = TextField(
          controller: widget.controller,
          autofocus: narrow && _searchExpanded,
          decoration: InputDecoration(
            hintText: widget.mode == 'rooms'
                ? 'Search customer, service, room...'
                : 'Search customer, service, staff...',
            prefixIcon: const Icon(Icons.search, size: 21),
            suffixIcon: widget.controller.text.isEmpty
                ? null
                : IconButton(
                    onPressed: widget.controller.clear,
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Clear search',
                  ),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFD5DEE8)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFD5DEE8)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF1B6B72)),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 11),
          ),
        );
        final filterButton = _FilterMenuButton(
          expanded: widget.filterExpanded,
          selectedCount: widget.selectedIds.length,
          onTap: widget.resources.isEmpty ? null : widget.onToggleFilter,
        );
        final filterPanel = _ResourceFilterPanel(
          mode: widget.mode,
          resources: widget.resources,
          entries: widget.entries,
          selectedDate: widget.selectedDate,
          selectedIds: widget.selectedIds,
          onHide: widget.onToggleFilter,
          onToggle: widget.onToggleResource,
          onClear: widget.onClearResources,
        );
        if (narrow) {
          return AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: modes),
                    const SizedBox(width: 8),
                    filterButton,
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: () {
                        setState(() => _searchExpanded = !_searchExpanded);
                        if (_searchExpanded) return;
                        widget.controller.clear();
                        FocusScope.of(context).unfocus();
                      },
                      icon: Icon(_searchExpanded ? Icons.close : Icons.search),
                      tooltip: _searchExpanded ? 'Close search' : 'Search',
                    ),
                  ],
                ),
                if (_searchExpanded) ...[const SizedBox(height: 8), search],
                if (widget.filterExpanded) ...[
                  const SizedBox(height: 10),
                  filterPanel,
                ],
              ],
            ),
          );
        }
        return Column(
          children: [
            Row(
              children: [
                SizedBox(width: 248, child: modes),
                const SizedBox(width: 14),
                Expanded(child: search),
                const SizedBox(width: 10),
                filterButton,
              ],
            ),
            if (widget.filterExpanded) ...[
              const SizedBox(height: 10),
              filterPanel,
            ],
          ],
        );
      },
    );
  }
}

class _FilterMenuButton extends StatelessWidget {
  final bool expanded;
  final int selectedCount;
  final VoidCallback? onTap;

  const _FilterMenuButton({
    required this.expanded,
    required this.selectedCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasSelection = selectedCount > 0;
    return Material(
      color: hasSelection
          ? _timetableAccent.withValues(alpha: 0.1)
          : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: hasSelection ? _timetableAccent : const Color(0xFFD5DEE8),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.tune_rounded,
                  size: 19,
                  color: hasSelection
                      ? _timetableAccent
                      : const Color(0xFF334155),
                ),
                const SizedBox(width: 7),
                Text(
                  hasSelection ? 'Filter ($selectedCount)' : 'Filter',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: hasSelection
                        ? _timetableAccent
                        : const Color(0xFF334155),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 19,
                  color: hasSelection
                      ? _timetableAccent
                      : const Color(0xFF64748B),
                ),
              ],
            ),
          ),
        ),
      ),
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
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
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
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: active
                ? const [
                    BoxShadow(
                      color: Color(0x0F000000),
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                value == 'rooms'
                    ? Icons.meeting_room_outlined
                    : Icons.people_alt_outlined,
                size: 15,
                color: active
                    ? const Color(0xFF0F766E)
                    : const Color(0xFF64748B),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: active
                      ? const Color(0xFF0F766E)
                      : const Color(0xFF64748B),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResourceTimetableGrid extends StatefulWidget {
  final List<_TimetableResource> resources;
  final List<_TimetableEntry> entries;
  final DateTime selectedDate;
  final int openMinute;
  final int closeMinute;
  final String mode;
  final bool compact;
  final ValueChanged<_TimetableEntry> onTap;

  const _ResourceTimetableGrid({
    required this.resources,
    required this.entries,
    required this.selectedDate,
    required this.openMinute,
    required this.closeMinute,
    required this.mode,
    this.compact = false,
    required this.onTap,
  });

  @override
  State<_ResourceTimetableGrid> createState() => _ResourceTimetableGridState();
}

class _ResourceTimetableGridState extends State<_ResourceTimetableGrid> {
  static const double hourWidth = 136.0;
  static const double minuteWidth = hourWidth / 60;
  static const double laneHeight = 84;
  static const double laneGap = 8;
  static const double rowTopPad = 14;
  static const double rowBottomPad = 14;

  late final ScrollController _scrollController;
  bool _scrolled = false;

  int get _canvasStartMinute => _floorToHour(widget.openMinute);
  int get _canvasEndMinute => _timetableCanvasEndMinute(
    closeMinute: widget.closeMinute,
    entries: widget.entries,
    selectedDate: widget.selectedDate,
  );

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(initialScrollOffset: _initialOffset());
    _scrolled = _scrollController.initialScrollOffset > 2;
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant _ResourceTimetableGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_stripDate(widget.selectedDate) != _stripDate(oldWidget.selectedDate)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        _scrollController.animateTo(
          _initialOffset().clamp(
            0.0,
            _scrollController.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final scrolled = _scrollController.offset > 2;
    if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
  }

  double _initialOffset() {
    final nowMinutes = _timetableNowMinute(
      selectedDate: widget.selectedDate,
      canvasEndMinute: _canvasEndMinute,
    );
    if (nowMinutes == null) return 0;
    if (nowMinutes <= _canvasStartMinute) return 0;
    final timelineWidth = (_canvasEndMinute - _canvasStartMinute) * minuteWidth;
    final target = (nowMinutes - _canvasStartMinute) * minuteWidth - 220;
    return target.clamp(
      0.0,
      (timelineWidth - hourWidth).clamp(0.0, timelineWidth),
    );
  }

  double _rowHeightFor(List<_TimetableEntry> entries) {
    final visibleEntries = entries
        .where(
          (entry) => _entryIntersectsTimeline(
            entry,
            _canvasStartMinute,
            _canvasEndMinute,
          ),
        )
        .toList();
    final lanes = _assignLanesFlat(visibleEntries);
    final laneCount = lanes.isEmpty
        ? 1
        : lanes.map((l) => l.lane).reduce((a, b) => a > b ? a : b) + 1;
    final height =
        rowTopPad +
        laneCount * laneHeight +
        (laneCount - 1) * laneGap +
        rowBottomPad;
    if (widget.mode == 'rooms') {
      return height.clamp(132.0, double.infinity).toDouble();
    }
    return height;
  }

  @override
  Widget build(BuildContext context) {
    final canvasStartMinute = _canvasStartMinute;
    final canvasEndMinute = _canvasEndMinute;
    // Sticky resource column, sized just wide enough for a name + role/label.
    // The timeline starts at `resourceWidth`, so trimming this hands the
    // recovered horizontal space straight to the schedule. Responsive via the
    // compact breakpoint; staff stays ~100px (mobile) / ~132px (tablet).
    final resourceWidth = widget.compact
        ? (widget.mode == 'rooms' ? 112.0 : 100.0)
        : (widget.mode == 'rooms' ? 156.0 : 132.0);
    final timelineWidth = (canvasEndMinute - canvasStartMinute) * minuteWidth;
    final now = DateTime.now();
    final timelineNowMinute = _timetableNowMinute(
      selectedDate: widget.selectedDate,
      canvasEndMinute: canvasEndMinute,
    );
    final nowMinutes = timelineNowMinute ?? 0;
    final selectedToday = timelineNowMinute != null;
    final showNow =
        selectedToday &&
        nowMinutes >= canvasStartMinute &&
        nowMinutes <= canvasEndMinute;
    final nowLeft = (nowMinutes - canvasStartMinute) * minuteWidth;

    final rowEntries = [
      for (final resource in widget.resources)
        widget.entries.where(resource.matches).toList(),
    ];
    final rowHeights = [for (final list in rowEntries) _rowHeightFor(list)];
    final contentHeight =
        50.0 + rowHeights.fold<double>(0, (total, height) => total + height);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFDDE5EE)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0A000000),
                blurRadius: 8,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                // Scrollable timeline. Padded so it starts after the pinned
                // resource column, which stays put while hours scroll.
                Padding(
                  padding: EdgeInsets.only(left: resourceWidth),
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: timelineWidth,
                      height: contentHeight,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _TimelineHoursHeader(
                                timelineWidth: timelineWidth,
                                canvasStartMinute: canvasStartMinute,
                                canvasEndMinute: canvasEndMinute,
                                minuteWidth: minuteWidth,
                              ),
                              for (var i = 0; i < widget.resources.length; i++)
                                _ResourceRowTimeline(
                                  entries: rowEntries[i],
                                  selectedDate: widget.selectedDate,
                                  rowHeight: rowHeights[i],
                                  timelineWidth: timelineWidth,
                                  canvasStartMinute: canvasStartMinute,
                                  canvasEndMinute: canvasEndMinute,
                                  openMinute: widget.openMinute,
                                  closeMinute: widget.closeMinute,
                                  onTap: widget.onTap,
                                  isLast: i == widget.resources.length - 1,
                                ),
                            ],
                          ),
                          if (showNow)
                            Positioned(
                              left: (nowLeft - 32).clamp(
                                4.0,
                                timelineWidth - 68,
                              ),
                              top: 9,
                              child: _TimelineNowPill(
                                label: _shortClockLabel(
                                  _minutesToTime(nowMinutes),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Pinned resource column, painted above the timeline with a
                // soft edge shadow once the timeline has scrolled.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: resourceWidth,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFCFDFE),
                      boxShadow: _scrolled
                          ? const [
                              BoxShadow(
                                color: Color(0x1A0F172A),
                                blurRadius: 8,
                                offset: Offset(2, 0),
                              ),
                            ]
                          : const [],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ResourceColumnHeader(
                          titleLabel: widget.mode == 'rooms'
                              ? 'Room / Zone'
                              : 'Therapist',
                        ),
                        for (var i = 0; i < widget.resources.length; i++)
                          _ResourceCell(
                            resource: widget.resources[i],
                            occupied: rowEntries[i]
                                .where(
                                  (entry) =>
                                      selectedToday &&
                                      entry.isHappeningNow(now),
                                )
                                .length,
                            width: resourceWidth,
                            height: rowHeights[i],
                            isLast: i == widget.resources.length - 1,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        const _TimetableLegend(),
      ],
    );
  }
}

class _ResourceColumnHeader extends StatelessWidget {
  final String titleLabel;

  const _ResourceColumnHeader({required this.titleLabel});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xFFFBFCFD),
        border: Border(
          bottom: BorderSide(color: Color(0xFFDDE5EE)),
          right: BorderSide(color: Color(0xFFDDE5EE)),
        ),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          titleLabel,
          style: const TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111827),
          ),
        ),
      ),
    );
  }
}

class _TimelineNowPill extends StatelessWidget {
  final String label;

  const _TimelineNowPill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _timetableAccent,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x330F766E),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w900,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _TimelineHoursHeader extends StatelessWidget {
  final double timelineWidth;
  final int canvasStartMinute;
  final int canvasEndMinute;
  final double minuteWidth;

  const _TimelineHoursHeader({
    required this.timelineWidth,
    required this.canvasStartMinute,
    required this.canvasEndMinute,
    required this.minuteWidth,
  });

  @override
  Widget build(BuildContext context) {
    final firstHour = canvasStartMinute ~/ 60;
    final lastHour = (canvasEndMinute / 60).ceil();
    return Container(
      height: 50,
      width: timelineWidth,
      decoration: const BoxDecoration(
        color: Color(0xFFFBFCFD),
        border: Border(bottom: BorderSide(color: Color(0xFFDDE5EE))),
      ),
      child: Stack(
        children: [
          for (var hour = firstHour; hour <= lastHour; hour++)
            Positioned(
              left: (hour * 60 - canvasStartMinute) * minuteWidth,
              top: 0,
              bottom: 0,
              child: Container(width: 1, color: const Color(0xFFEFF3F7)),
            ),
          for (var hour = firstHour; hour < lastHour; hour++)
            Positioned(
              left: (hour * 60 - canvasStartMinute) * minuteWidth + 14,
              top: 18,
              child: Text(
                _hourLabel(hour),
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF334155),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ResourceRowTimeline extends StatelessWidget {
  final List<_TimetableEntry> entries;
  final DateTime selectedDate;
  final double rowHeight;
  final double timelineWidth;
  final int canvasStartMinute;
  final int canvasEndMinute;
  final int openMinute;
  final int closeMinute;
  final ValueChanged<_TimetableEntry> onTap;
  final bool isLast;

  const _ResourceRowTimeline({
    required this.entries,
    required this.selectedDate,
    required this.rowHeight,
    required this.timelineWidth,
    required this.canvasStartMinute,
    required this.canvasEndMinute,
    required this.openMinute,
    required this.closeMinute,
    required this.onTap,
    required this.isLast,
  });

  static const double laneHeight = _ResourceTimetableGridState.laneHeight;
  static const double laneGap = _ResourceTimetableGridState.laneGap;
  static const double topPad = _ResourceTimetableGridState.rowTopPad;
  static const double minuteWidth = _ResourceTimetableGridState.minuteWidth;

  @override
  Widget build(BuildContext context) {
    final sorted = [...entries]
      ..sort((a, b) => a.serviceStartMinutes.compareTo(b.serviceStartMinutes));
    final visibleEntries = sorted
        .where(
          (entry) => _entryIntersectsTimeline(
            entry,
            canvasStartMinute,
            canvasEndMinute,
          ),
        )
        .toList();
    final blockingEntries = visibleEntries
        .where((entry) => !entry.isVoided && !entry.isNoShow)
        .toList();
    final lanes = _assignLanesFlat(visibleEntries);
    final now = DateTime.now();
    final selectedToday = _stripDate(selectedDate) == _stripDate(now);
    final selectedBeforeToday = _stripDate(
      selectedDate,
    ).isBefore(_stripDate(now));
    final nowMinutes = now.hour * 60 + now.minute;

    return Container(
      height: rowHeight,
      width: timelineWidth,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(
            color: isLast ? Colors.transparent : const Color(0xFFE5E7EB),
          ),
        ),
      ),
      child: Stack(
        children: [
          _RowTimeGrid(
            canvasStartMinute: canvasStartMinute,
            canvasEndMinute: canvasEndMinute,
            minuteWidth: minuteWidth,
          ),
          for (final segment in _freeSegments(
            blockingEntries,
            openMinute,
            closeMinute,
          ))
            _FreeAvailabilitySegment(
              segment: segment,
              closeMinute: closeMinute,
              canvasStartMinute: canvasStartMinute,
              minuteWidth: minuteWidth,
              top: topPad,
              height: laneHeight,
              selectedToday: selectedToday,
              selectedBeforeToday: selectedBeforeToday,
              nowMinutes: nowMinutes,
            ),
          for (final lane in lanes)
            _ResourceAppointmentBlock(
              entry: lane.entry,
              canvasStartMinute: canvasStartMinute,
              minuteWidth: minuteWidth,
              top: topPad + lane.lane * (laneHeight + laneGap),
              cardHeight: laneHeight,
              onTap: () => onTap(lane.entry),
            ),
          if (selectedToday &&
              nowMinutes >= canvasStartMinute &&
              nowMinutes <= canvasEndMinute)
            Positioned(
              left: (nowMinutes - canvasStartMinute) * minuteWidth - 3,
              top: 6,
              bottom: 6,
              width: 7,
              child: const _DashedNowLine(),
            ),
        ],
      ),
    );
  }
}

class _ResourceCell extends StatelessWidget {
  final _TimetableResource resource;
  final int occupied;
  final double width;
  final double height;
  final bool isLast;

  const _ResourceCell({
    required this.resource,
    required this.occupied,
    required this.width,
    required this.height,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final isRoom = resource.isRoom;
    final used = occupied.clamp(0, resource.capacity);
    final compact = width <= 120;
    return Container(
      width: width,
      height: height,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFFCFDFE),
        border: Border(
          right: const BorderSide(color: Color(0xFFDDE5EE)),
          bottom: BorderSide(
            color: isLast ? Colors.transparent : const Color(0xFFE5E7EB),
          ),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            resource.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            softWrap: true,
            style: TextStyle(
              fontSize: compact ? 12.5 : 13.5,
              fontWeight: FontWeight.w900,
              color: const Color(0xFF0F172A),
              height: 1.2,
            ),
          ),
          if (isRoom) ...[
            // Zones show a compact "used / capacity" occupancy pill and no
            // subtitle, matching the reference on both mobile and tablet.
            SizedBox(height: compact ? 8 : 10),
            _ResourcePill(
              label: '$used / ${resource.capacity}',
              color: resource.accentColor,
            ),
          ] else ...[
            SizedBox(height: compact ? 2 : 3),
            Text(
              resource.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: compact ? 10.5 : 11.5,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF64748B),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ResourcePill extends StatelessWidget {
  final String label;
  final Color color;

  const _ResourcePill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 136),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 112),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResourceAppointmentBlock extends StatelessWidget {
  final _TimetableEntry entry;
  final int canvasStartMinute;
  final double minuteWidth;
  final double top;
  final double cardHeight;
  final VoidCallback onTap;

  const _ResourceAppointmentBlock({
    required this.entry,
    required this.canvasStartMinute,
    required this.minuteWidth,
    required this.top,
    required this.cardHeight,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = _statusStyle(entry);
    final left = (entry.serviceStartMinutes - canvasStartMinute) * minuteWidth;
    final serviceWidth =
        (entry.serviceEndMinutes - entry.serviceStartMinutes) * minuteWidth;
    final cleanupMinutes = entry.bufferAfterMinutes.clamp(0, 240);
    final cleanupLeft =
        (entry.serviceEndMinutes - canvasStartMinute) * minuteWidth;
    final bufferWidth = cleanupMinutes * minuteWidth;
    final large = serviceWidth >= 154;
    final medium = serviceWidth >= 108 && serviceWidth < 154;
    final small = serviceWidth < 96;
    final showTinyIcon = serviceWidth >= 76;
    final displayName = small
        ? serviceWidth >= 50
              ? _shortCustomerName(entry.customerName)
              : _compactInitials(entry.customerName)
        : medium
        ? _shortCustomerName(entry.customerName)
        : entry.customerName;
    final timeLabel = small
        ? _compactDurationLabel(
            (entry.serviceEndMinutes - entry.serviceStartMinutes).clamp(
              0,
              1440,
            ),
          )
        : serviceWidth >= 130
        ? _meridiemRangeLabel(
            entry.operationalStartTime,
            entry.operationalEndTime,
          )
        : '${_shortClockLabel(entry.operationalStartTime)} - ${_shortClockLabel(entry.operationalEndTime)}';
    final serviceLabel = _timelineServiceLabel(entry, serviceWidth);

    return Stack(
      children: [
        if (cleanupMinutes > 0)
          Positioned(
            left: cleanupLeft + 3,
            top: top,
            width: (bufferWidth - 3).clamp(0.0, double.infinity),
            height: cardHeight,
            child: _BufferBlock(
              minutes: cleanupMinutes,
              rangeLabel:
                  '${_shortClockLabel(_minutesToTime(entry.serviceEndMinutes))} - ${_clockLabel(_minutesToTime(entry.cleanupEndMinutes))}',
              showRange: bufferWidth >= 70,
              label: 'Cleanup',
            ),
          ),
        Positioned(
          left: left,
          top: top,
          width: serviceWidth,
          height: cardHeight,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: small ? 7 : 10,
                  vertical: small
                      ? 5
                      : medium
                      ? 6
                      : 7,
                ),
                decoration: BoxDecoration(
                  color: style.background,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: style.border),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x08000000),
                      blurRadius: 8,
                      offset: Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: small
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (!small || showTinyIcon) ...[
                          Container(
                            width: small ? 16 : 18,
                            height: small ? 16 : 18,
                            decoration: BoxDecoration(
                              color: style.color.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              entry.isVoided
                                  ? Icons.block_rounded
                                  : entry.isCompleted
                                  ? Icons.check_rounded
                                  : entry.isInProgress
                                  ? Icons.timer_outlined
                                  : Icons.event_note_outlined,
                              size: small ? 11 : 13,
                              color: style.color,
                            ),
                          ),
                          SizedBox(width: small ? 5 : 6),
                        ],
                        Expanded(
                          child: Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: small
                                  ? 12.5
                                  : medium
                                  ? 13.5
                                  : 14,
                              fontWeight: FontWeight.w800,
                              color: const Color(0xFF111827),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (!small && large && entry.isInProgress) ...[
                      const SizedBox(height: 3),
                      Text(
                        'In Progress',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                          color: style.color,
                        ),
                      ),
                    ],
                    if (!small && large && !entry.isInProgress) ...[
                      const SizedBox(height: 3),
                      Text(
                        serviceLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF374151),
                        ),
                      ),
                    ],
                    if (!small && medium) ...[
                      const SizedBox(height: 4),
                      Text(
                        serviceLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF374151),
                        ),
                      ),
                    ],
                    SizedBox(
                      height: small
                          ? 2
                          : medium
                          ? 4
                          : 3,
                    ),
                    Text(
                      timeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: small
                            ? 11.5
                            : medium
                            ? 12
                            : 12.5,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF4B5563),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BufferBlock extends StatelessWidget {
  final int minutes;
  final String rangeLabel;
  final bool showRange;
  final String label;

  const _BufferBlock({
    required this.minutes,
    required this.rangeLabel,
    required this.showRange,
    this.label = 'Cleanup',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cleaning_services_outlined,
            size: showRange ? 13 : 12,
            color: const Color(0xFF9AA1AB),
          ),
          SizedBox(height: showRange ? 3 : 2),
          Text(
            showRange ? label : '${minutes}m',
            textAlign: TextAlign.center,
            maxLines: 1,
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: Color(0xFF6B7280),
            ),
          ),
          if (showRange) ...[
            const SizedBox(height: 2),
            Text(
              '$minutes min\n$rangeLabel',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: Color(0xFF9AA1AB),
                height: 1.15,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FreeAvailabilitySegment extends StatelessWidget {
  final _ScheduleSegment segment;
  final int closeMinute;
  final int canvasStartMinute;
  final double minuteWidth;
  final double top;
  final double height;
  final bool selectedToday;
  final bool selectedBeforeToday;
  final int nowMinutes;

  const _FreeAvailabilitySegment({
    required this.segment,
    required this.closeMinute,
    required this.canvasStartMinute,
    required this.minuteWidth,
    required this.top,
    required this.height,
    required this.selectedToday,
    required this.selectedBeforeToday,
    required this.nowMinutes,
  });

  @override
  Widget build(BuildContext context) {
    final isPastGap =
        selectedBeforeToday || (selectedToday && segment.end <= nowMinutes);
    final visibleStart =
        selectedToday &&
            nowMinutes > segment.start &&
            nowMinutes < segment.end
        ? nowMinutes
        : segment.start;
    if (visibleStart >= segment.end) return const SizedBox.shrink();
    final left = (visibleStart - canvasStartMinute) * minuteWidth;
    final width = (segment.end - visibleStart) * minuteWidth;
    if (width < 8) return const SizedBox.shrink();
    final finalSlotAvailable =
        segment.isFinalAfterBusy &&
        selectedToday &&
        nowMinutes >= segment.start;
    final isBoundedGap = segment.end < closeMinute;
    final shouldLabel = !isPastGap && segment.afterBusy && width >= 72;
    final useCompactLabel = width < 150;
    final labelTime = _clockLabel(
      _minutesToTime(
        segment.isFinalAfterBusy ? segment.labelStart : segment.end,
      ),
    );
    final label = finalSlotAvailable
        ? 'Free'
        : segment.isFinalAfterBusy
        ? useCompactLabel
              ? 'Free after\n$labelTime'
              : 'Free after $labelTime'
        : isBoundedGap
        ? useCompactLabel
              ? 'Free until\n$labelTime'
              : 'Free until $labelTime'
        : '';
    final showSubtitle =
        shouldLabel &&
        width >= 150 &&
        (!segment.isFinalAfterBusy || finalSlotAvailable);
    final subtitle = isBoundedGap
        ? '${_clockLabel(_minutesToTime(visibleStart))} - ${_clockLabel(_minutesToTime(segment.end))}'
        : 'Available';
    final alignLabelStart =
        segment.isFinalAfterBusy && !finalSlotAvailable && !useCompactLabel;
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: Container(
        alignment: alignLabelStart
            ? Alignment.centerLeft
            : Alignment.center,
        padding: EdgeInsets.symmetric(
          horizontal: alignLabelStart ? 14 : 8,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFFF7FFFC),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: const Color(0xFFC7EBDD),
            style: BorderStyle.solid,
          ),
        ),
        child: shouldLabel
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: alignLabelStart
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.center,
                children: [
                  Text(
                    label,
                    textAlign: alignLabelStart
                        ? TextAlign.left
                        : TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF166534),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                  if (showSubtitle) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF475569),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

class _RowTimeGrid extends StatelessWidget {
  final int canvasStartMinute;
  final int canvasEndMinute;
  final double minuteWidth;

  const _RowTimeGrid({
    required this.canvasStartMinute,
    required this.canvasEndMinute,
    required this.minuteWidth,
  });

  @override
  Widget build(BuildContext context) {
    final firstHour = canvasStartMinute ~/ 60;
    final lastHour = (canvasEndMinute / 60).ceil();
    return Stack(
      children: [
        for (var hour = firstHour; hour <= lastHour; hour++)
          Positioned(
            left: (hour * 60 - canvasStartMinute) * minuteWidth,
            top: 0,
            bottom: 0,
            child: Container(width: 1, color: const Color(0xFFE8EEF5)),
          ),
      ],
    );
  }
}

class _TimetableLegend extends StatelessWidget {
  const _TimetableLegend();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 16,
      runSpacing: 8,
      children: const [
        _LegendDot(color: Color(0xFF2563EB), label: 'Awaiting arrival'),
        _LegendDot(color: Color(0xFF0EA5E9), label: 'In progress'),
        _LegendDot(color: Color(0xFF059669), label: 'Completed'),
        _LegendDot(color: Color(0xFF9CA3AF), label: 'Buffer'),
        _LegendSwatch(color: Color(0xFFDDF6EA), label: 'Free capacity'),
      ],
    );
  }
}

class _LegendSwatch extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendSwatch({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: const Color(0xFFBFE5D6)),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Color(0xFF6B7280),
          ),
        ),
      ],
    );
  }
}

class _DashedNowLine extends StatelessWidget {
  const _DashedNowLine();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedLinePainter(_timetableAccent.withValues(alpha: 0.85)),
      size: Size.infinite,
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  final Color color;

  const _DashedLinePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    const dashHeight = 3.0;
    const dashSpace = 4.0;
    final x = size.width / 2;
    var y = 0.0;
    while (y < size.height) {
      canvas.drawLine(
        Offset(x, y),
        Offset(x, (y + dashHeight).clamp(0, size.height)),
        paint,
      );
      y += dashHeight + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) =>
      oldDelegate.color != color;
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Color(0xFF6B7280),
          ),
        ),
      ],
    );
  }
}

class _ScheduleSegment {
  final int start;
  final int end;
  final int labelStart;
  final bool afterBusy;
  final bool isFinalAfterBusy;

  const _ScheduleSegment(
    this.start,
    this.end, {
    int? labelStart,
    this.afterBusy = false,
    this.isFinalAfterBusy = false,
  }) : labelStart = labelStart ?? start;
}

List<_ScheduleSegment> _freeSegments(
  List<_TimetableEntry> entries,
  int openMinute,
  int closeMinute,
) {
  final busy =
      entries
          .map(
            (entry) => _ScheduleSegment(
              entry.serviceStartMinutes.clamp(openMinute, closeMinute).toInt(),
              entry.cleanupEndMinutes.clamp(openMinute, closeMinute),
              labelStart: entry.cleanupEndMinutes.clamp(
                openMinute,
                closeMinute,
              ),
            ),
          )
          .where((segment) => segment.end > segment.start)
          .toList()
        ..sort((a, b) => a.start.compareTo(b.start));

  final free = <_ScheduleSegment>[];
  var cursor = openMinute;
  var labelCursor = openMinute;
  var passedBusy = false;
  for (final segment in busy) {
    if (segment.start > cursor) {
      free.add(
        _ScheduleSegment(
          cursor,
          segment.start,
          labelStart: labelCursor,
          afterBusy: passedBusy,
        ),
      );
    }
    if (segment.end > cursor) {
      cursor = segment.end;
      if (segment.labelStart > labelCursor) labelCursor = segment.labelStart;
    }
    passedBusy = true;
  }
  if (cursor < closeMinute) {
    free.add(
      _ScheduleSegment(
        cursor,
        closeMinute,
        labelStart: labelCursor,
        afterBusy: passedBusy,
        isFinalAfterBusy: passedBusy,
      ),
    );
  }
  return free.where((segment) => segment.end - segment.start >= 30).toList();
}

/// Overlap grouping and lane assignment. [endOf] decides where an entry's
/// occupied span ends; the default is the real cleanup end. Back-to-back
/// bookings (next start == previous end) stay in the same lane because the
/// comparison is strict.
List<List<_TimetableEntry>> _groupOverlapping(
  List<_TimetableEntry> entries, {
  int Function(_TimetableEntry entry)? endOf,
}) {
  final end = endOf ?? (entry) => entry.cleanupEndMinutes;
  final sorted = [...entries]
    ..sort((a, b) => a.serviceStartMinutes.compareTo(b.serviceStartMinutes));
  final groups = <List<_TimetableEntry>>[];
  var current = <_TimetableEntry>[];
  var groupEnd = 0;
  for (final entry in sorted) {
    if (current.isEmpty || entry.serviceStartMinutes < groupEnd) {
      current.add(entry);
      if (end(entry) > groupEnd) groupEnd = end(entry);
    } else {
      groups.add(current);
      current = [entry];
      groupEnd = end(entry);
    }
  }
  if (current.isNotEmpty) groups.add(current);
  return groups;
}

class _EntryLane {
  final _TimetableEntry entry;
  final int lane;

  const _EntryLane(this.entry, this.lane);
}

List<_EntryLane> _assignLanesFlat(
  List<_TimetableEntry> entries, {
  int Function(_TimetableEntry entry)? endOf,
}) {
  final end = endOf ?? (entry) => entry.cleanupEndMinutes;
  final result = <_EntryLane>[];
  for (final group in _groupOverlapping(entries, endOf: endOf)) {
    final laneEnds = <int>[];
    for (final entry in group) {
      var lane = laneEnds.indexWhere(
        (laneEnd) => entry.serviceStartMinutes >= laneEnd,
      );
      if (lane == -1) {
        lane = laneEnds.length;
        laneEnds.add(end(entry));
      } else {
        laneEnds[lane] = end(entry);
      }
      result.add(_EntryLane(entry, lane));
    }
  }
  return result;
}

bool _entryIntersectsTimeline(
  _TimetableEntry entry,
  int canvasStartMinute,
  int canvasEndMinute,
) {
  final start = entry.serviceStartMinutes;
  final end = entry.serviceEndMinutes;
  return end > start && end > canvasStartMinute && start < canvasEndMinute;
}

int _timetableCanvasEndMinute({
  required int closeMinute,
  required List<_TimetableEntry> entries,
  required DateTime selectedDate,
}) {
  var latestMinute = closeMinute;

  for (final entry in entries) {
    if (entry.isCancelled || entry.isVoided || entry.isNoShow) continue;
    if (entry.serviceEndMinutes <= entry.serviceStartMinutes) continue;
    if (entry.cleanupEndMinutes > latestMinute) {
      latestMinute = entry.cleanupEndMinutes;
    }
  }

  final now = DateTime.now();
  final dayOffset = _stripDate(now).difference(_stripDate(selectedDate)).inDays;
  if (dayOffset == 0) {
    final nowMinute = now.hour * 60 + now.minute;
    if (nowMinute > latestMinute) latestMinute = nowMinute;
  }

  return _ceilToHour(latestMinute);
}

int? _timetableNowMinute({
  required DateTime selectedDate,
  required int canvasEndMinute,
}) {
  final now = DateTime.now();
  final dayOffset = _stripDate(now).difference(_stripDate(selectedDate)).inDays;
  if (dayOffset == 0) return now.hour * 60 + now.minute;
  if (dayOffset == 1 && canvasEndMinute > 24 * 60) {
    final minute = 24 * 60 + now.hour * 60 + now.minute;
    if (minute <= canvasEndMinute) return minute;
  }
  return null;
}

class _MobileTimetable extends StatefulWidget {
  final List<_TimetableEntry> entries;
  final List<_TimetableResource> bottomResources;
  final String mode;
  final DateTime selectedDate;
  final int openMinute;
  final int closeMinute;
  final Set<String> expandedBandKeys;
  final ValueChanged<String> onToggleBand;
  final ValueChanged<_TimetableEntry> onTap;

  const _MobileTimetable({
    required this.entries,
    required this.bottomResources,
    required this.mode,
    required this.selectedDate,
    required this.openMinute,
    required this.closeMinute,
    required this.expandedBandKeys,
    required this.onToggleBand,
    required this.onTap,
  });

  @override
  State<_MobileTimetable> createState() => _MobileTimetableState();
}

class _MobileTimetableState extends State<_MobileTimetable> {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 24),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        _ResourceTimetableGrid(
          resources: widget.bottomResources,
          entries: widget.entries,
          mode: widget.mode,
          selectedDate: widget.selectedDate,
          openMinute: widget.openMinute,
          closeMinute: widget.closeMinute,
          compact: true,
          onTap: widget.onTap,
        ),
      ],
    );
  }
}

// ignore: unused_element
class _MobileResourceNavigator extends StatelessWidget {
  final List<_TimetableResource> resources;
  final List<_TimetableEntry> entries;
  final String selectedId;
  final String mode;
  final int nowMinutes;
  final bool selectedToday;
  final ValueChanged<String> onSelected;

  const _MobileResourceNavigator({
    required this.resources,
    required this.entries,
    required this.selectedId,
    required this.mode,
    required this.nowMinutes,
    required this.selectedToday,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                mode == 'rooms'
                    ? Icons.meeting_room_outlined
                    : Icons.people_alt_outlined,
                size: 17,
                color: const Color(0xFF176B68),
              ),
              const SizedBox(width: 7),
              Text(
                mode == 'rooms' ? 'Choose room or zone' : 'Choose staff',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF475467),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 68,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: resources.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final resource = resources[index];
                return _MobileResourceChip(
                  resource: resource,
                  entries: entries,
                  nowMinutes: nowMinutes,
                  selectedToday: selectedToday,
                  selected: resource.id == selectedId,
                  onTap: () => onSelected(resource.id),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _MobileSelectedResourceHeader extends StatelessWidget {
  final _TimetableResource resource;
  final _ResourceStatus status;
  final int appointmentCount;

  const _MobileSelectedResourceHeader({
    required this.resource,
    required this.status,
    required this.appointmentCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFB),
        border: Border(
          top: BorderSide(color: Color(0xFFE4E7EC)),
          bottom: BorderSide(color: Color(0xFFE4E7EC)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  resource.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF17202A),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$appointmentCount ${appointmentCount == 1 ? 'booking' : 'bookings'} today',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF667085),
                  ),
                ),
              ],
            ),
          ),
          Container(
            constraints: const BoxConstraints(maxWidth: 170),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              color: status.color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: status.color.withValues(alpha: 0.24)),
            ),
            child: Text(
              status.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: status.color,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileTimelineBoard extends StatefulWidget {
  final List<_TimetableEntry> entries;
  final String mode;
  final DateTime selectedDate;
  final int openMinute;
  final int closeMinute;
  final Set<String> expandedBandKeys;
  final ValueChanged<String> onToggleBand;
  final ValueChanged<_TimetableEntry> onTap;

  const _MobileTimelineBoard({
    required this.entries,
    required this.mode,
    required this.selectedDate,
    required this.openMinute,
    required this.closeMinute,
    required this.expandedBandKeys,
    required this.onToggleBand,
    required this.onTap,
  });

  @override
  State<_MobileTimelineBoard> createState() => _MobileTimelineBoardState();
}

class _MobileTimelineBoardState extends State<_MobileTimelineBoard> {
  static const double hourHeight = 92.0;
  static const double minuteHeight = hourHeight / 60;
  static const double topPad = 10.0;
  static const double bottomPad = 22.0;
  static const double timeWidth = 44.0;
  static const double laneGap = 8.0;

  /// The shortest card is 46px, which equals exactly 30 minutes at this
  /// scale. Lane assignment inflates every entry to at least that visual
  /// span so shorter bookings can never paint over the next card; exact
  /// back-to-back bookings still share a lane.
  static const int minVisualMinutes = 30;

  late final ScrollController _scrollController;

  int get _canvasStartMinute => _floorToHour(widget.openMinute);
  int get _canvasEndMinute => _timetableCanvasEndMinute(
    closeMinute: widget.closeMinute,
    entries: widget.entries,
    selectedDate: widget.selectedDate,
  );

  static int _visualEnd(_TimetableEntry entry) {
    final min = entry.serviceStartMinutes + minVisualMinutes;
    return entry.cleanupEndMinutes > min ? entry.cleanupEndMinutes : min;
  }

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(initialScrollOffset: _initialOffset());
  }

  @override
  void didUpdateWidget(covariant _MobileTimelineBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_stripDate(widget.selectedDate) != _stripDate(oldWidget.selectedDate)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        _scrollController.animateTo(
          _initialOffset().clamp(
            0.0,
            _scrollController.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  double _initialOffset() {
    final nowMinutes = _timetableNowMinute(
      selectedDate: widget.selectedDate,
      canvasEndMinute: _canvasEndMinute,
    );
    if (nowMinutes == null) return 0;
    if (nowMinutes <= _canvasStartMinute) return 0;
    final target =
        topPad + (nowMinutes - _canvasStartMinute) * minuteHeight - 150;
    final maxOffset =
        topPad +
        (_canvasEndMinute - _canvasStartMinute) * minuteHeight +
        bottomPad;
    return target.clamp(0.0, maxOffset);
  }

  @override
  Widget build(BuildContext context) {
    final canvasStartMinute = _canvasStartMinute;
    final canvasEndMinute = _canvasEndMinute;
    final groups = _groupOverlapping(widget.entries, endOf: _visualEnd);
    var maxLanes = 1;
    for (final group in groups) {
      final key = _mobileBandKey(group);
      final collapsed =
          group.length > 3 && !widget.expandedBandKeys.contains(key);
      if (collapsed) continue;
      final lanes = _assignLanesFlat(group, endOf: _visualEnd);
      final laneCount = lanes.isEmpty
          ? 1
          : lanes.map((lane) => lane.lane).reduce((a, b) => a > b ? a : b) + 1;
      if (laneCount > maxLanes) maxLanes = laneCount;
    }
    final boardHeight =
        topPad +
        (canvasEndMinute - canvasStartMinute) * minuteHeight +
        bottomPad;
    final timelineNowMinute = _timetableNowMinute(
      selectedDate: widget.selectedDate,
      canvasEndMinute: canvasEndMinute,
    );
    final nowMinutes = timelineNowMinute ?? 0;
    final selectedToday = timelineNowMinute != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Fill the viewport when the lanes fit; scroll only when they don't.
        final available = constraints.maxWidth - 6 - 8 - timeWidth;
        final fitted = (available - 22 - (maxLanes - 1) * laneGap) / maxLanes;
        final laneWidth = fitted.clamp(206.0, 340.0);
        final timelineWidth =
            (10 + maxLanes * laneWidth + (maxLanes - 1) * laneGap + 12)
                .clamp(available, double.infinity)
                .toDouble();
        return ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(6, 4, 8, 10),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: boardHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: timeWidth,
                    height: boardHeight,
                    child: _MobileTimelineTimeRail(
                      canvasStartMinute: canvasStartMinute,
                      canvasEndMinute: canvasEndMinute,
                      minuteHeight: minuteHeight,
                      topPad: topPad,
                      nowMinutes: selectedToday ? nowMinutes : null,
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: timelineWidth,
                        height: boardHeight,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            _MobileTimelineGrid(
                              canvasStartMinute: canvasStartMinute,
                              canvasEndMinute: canvasEndMinute,
                              minuteHeight: minuteHeight,
                              topPad: topPad,
                              timeWidth: 0,
                              contentWidth: timelineWidth,
                            ),
                            if (widget.entries.isEmpty)
                              const _MobileEmptyDayHint(),
                            for (final group in groups)
                              ..._buildGroup(
                                group: group,
                                canvasStartMinute: canvasStartMinute,
                                laneWidth: laneWidth,
                              ),
                            if (selectedToday &&
                                nowMinutes >= canvasStartMinute &&
                                nowMinutes <= canvasEndMinute)
                              _MobileTimelineNowLine(
                                top:
                                    topPad +
                                    (nowMinutes - canvasStartMinute) *
                                        minuteHeight,
                                contentWidth: timelineWidth,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _buildGroup({
    required List<_TimetableEntry> group,
    required int canvasStartMinute,
    required double laneWidth,
  }) {
    final key = _mobileBandKey(group);
    final start = _groupStart(group);
    final end = _groupEnd(group);
    final top = topPad + (start - canvasStartMinute) * minuteHeight;
    final collapsed =
        group.length > 3 && !widget.expandedBandKeys.contains(key);
    if (collapsed) {
      return [
        Positioned(
          left: 10,
          top: top,
          width: laneWidth,
          height: ((end - start) * minuteHeight).clamp(64.0, 96.0).toDouble(),
          child: _MobileTimelineCollapsedBand(
            band: group,
            startMinutes: start,
            endMinutes: end,
            onExpand: () => widget.onToggleBand(key),
          ),
        ),
      ];
    }

    final lanes = _assignLanesFlat(group, endOf: _visualEnd);
    return [
      for (final lane in lanes)
        Positioned(
          left: 10 + lane.lane * (laneWidth + laneGap),
          top:
              topPad +
              (lane.entry.serviceStartMinutes - canvasStartMinute) *
                  minuteHeight,
          width: laneWidth,
          height: _cardHeight(lane.entry),
          child: _MobileTimelineEntryCard(
            entry: lane.entry,
            mode: widget.mode,
            compact: _cardHeight(lane.entry) < 68,
            onTap: () => widget.onTap(lane.entry),
          ),
        ),
      if (group.length > 3)
        Positioned(
          left: 10,
          top: topPad + (end - canvasStartMinute) * minuteHeight + 4,
          child: _MobileCollapseHandle(onTap: () => widget.onToggleBand(key)),
        ),
    ];
  }

  double _cardHeight(_TimetableEntry entry) {
    final raw =
        (entry.serviceEndMinutes - entry.serviceStartMinutes) * minuteHeight;
    return raw < 46.0 ? 46.0 : raw;
  }
}

class _MobileEmptyDayHint extends StatelessWidget {
  const _MobileEmptyDayHint();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: const Alignment(0, -0.55),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.event_available_outlined,
                  size: 17,
                  color: Color(0xFF0F766E),
                ),
                SizedBox(width: 8),
                Text(
                  'No bookings on this day',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF334155),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileTimelineGrid extends StatelessWidget {
  final int canvasStartMinute;
  final int canvasEndMinute;
  final double minuteHeight;
  final double topPad;
  final double timeWidth;
  final double contentWidth;

  const _MobileTimelineGrid({
    required this.canvasStartMinute,
    required this.canvasEndMinute,
    required this.minuteHeight,
    required this.topPad,
    required this.timeWidth,
    required this.contentWidth,
  });

  @override
  Widget build(BuildContext context) {
    final firstHour = canvasStartMinute ~/ 60;
    final lastHour = canvasEndMinute ~/ 60;
    return Stack(
      children: [
        Positioned(
          left: timeWidth + 10,
          top: topPad,
          bottom: 0,
          child: Container(width: 1, color: const Color(0xFFE7EDF3)),
        ),
        for (var hour = firstHour; hour <= lastHour; hour++)
          Positioned(
            left: 0,
            top: topPad + (hour * 60 - canvasStartMinute) * minuteHeight,
            width: contentWidth,
            child: const Divider(height: 1, color: Color(0xFFE5EAF0)),
          ),
      ],
    );
  }
}

class _MobileTimelineTimeRail extends StatelessWidget {
  final int canvasStartMinute;
  final int canvasEndMinute;
  final double minuteHeight;
  final double topPad;
  final int? nowMinutes;

  const _MobileTimelineTimeRail({
    required this.canvasStartMinute,
    required this.canvasEndMinute,
    required this.minuteHeight,
    required this.topPad,
    this.nowMinutes,
  });

  @override
  Widget build(BuildContext context) {
    final firstHour = canvasStartMinute ~/ 60;
    final lastHour = canvasEndMinute ~/ 60;
    final now = nowMinutes;
    final showNow =
        now != null && now >= canvasStartMinute && now <= canvasEndMinute;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          right: 0,
          top: topPad,
          bottom: 0,
          child: Container(width: 1, color: const Color(0xFFE1E7EF)),
        ),
        for (var hour = firstHour; hour <= lastHour; hour++)
          // Hide the hour label when the "now" chip would sit on top of it.
          if (!showNow || ((hour * 60 - now).abs() > 14 / minuteHeight))
            Positioned(
              left: 0,
              right: 5,
              top: topPad + (hour * 60 - canvasStartMinute) * minuteHeight - 7,
              child: Text(
                _hourLabel(hour % 24).toUpperCase(),
                textAlign: TextAlign.right,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF111827),
                ),
              ),
            ),
        if (showNow)
          Positioned(
            left: 0,
            right: 3,
            top: topPad + (now - canvasStartMinute) * minuteHeight - 8,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: _timetableAccent,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  _shortClockLabel(_minutesToTime(now)),
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    height: 1.1,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _MobileTimelineNowLine extends StatelessWidget {
  final double top;
  final double contentWidth;

  const _MobileTimelineNowLine({required this.top, required this.contentWidth});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      top: top - 4,
      width: contentWidth,
      child: IgnorePointer(
        child: Row(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                color: _timetableAccent,
                shape: BoxShape.circle,
              ),
            ),
            const Expanded(
              child: Divider(
                height: 1,
                thickness: 1.4,
                color: _timetableAccent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileTimelineEntryCard extends StatelessWidget {
  final _TimetableEntry entry;
  final String mode;
  final bool compact;
  final VoidCallback onTap;

  const _MobileTimelineEntryCard({
    required this.entry,
    required this.mode,
    this.compact = false,
    required this.onTap,
  });

  String get _resourceLabel =>
      mode == 'rooms' ? entry.roomDisplayName : entry.staffName;

  @override
  Widget build(BuildContext context) {
    final style = _statusStyle(entry);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          alignment: compact ? Alignment.centerLeft : null,
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 10, vertical: 5)
              : const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: style.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: style.border),
            boxShadow: const [
              BoxShadow(
                color: Color(0x0D000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: compact ? _buildCompact(style) : _buildFull(style),
        ),
      ),
    );
  }

  /// One-line layout for bookings too short to fit the full card.
  Widget _buildCompact(_StatusStyle style) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: style.color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            '${entry.customerName} · ${entry.serviceName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111827),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _meridiemRangeLabel(
            entry.operationalStartTime,
            entry.operationalEndTime,
          ),
          maxLines: 1,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: Color(0xFF4B5563),
          ),
        ),
      ],
    );
  }

  Widget _buildFull(_StatusStyle style) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: style.color.withValues(alpha: 0.13),
          child: Text(
            _compactInitials(entry.customerName),
            style: TextStyle(
              color: style.color,
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      entry.customerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _MobileStatusPill(entry: entry),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                entry.serviceName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF374151),
                ),
              ),
              const SizedBox(height: 5),
              _MobileMetaLine(
                icon: Icons.schedule_outlined,
                label:
                    '${_meridiemRangeLabel(entry.operationalStartTime, entry.operationalEndTime)}  -  $_resourceLabel',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MobileStatusPill extends StatelessWidget {
  final _TimetableEntry entry;

  const _MobileStatusPill({required this.entry});

  @override
  Widget build(BuildContext context) {
    final style = _statusStyle(entry);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: style.color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: style.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            entry.operationalStatus,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              color: style.color,
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileMetaLine extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MobileMetaLine({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: const Color(0xFF6B7280)),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Color(0xFF4B5563),
            ),
          ),
        ),
      ],
    );
  }
}

class _MobileTimelineCollapsedBand extends StatelessWidget {
  final List<_TimetableEntry> band;
  final int startMinutes;
  final int endMinutes;
  final VoidCallback onExpand;

  const _MobileTimelineCollapsedBand({
    required this.band,
    required this.startMinutes,
    required this.endMinutes,
    required this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final inProgress = band.where((entry) => entry.isHappeningNow(now)).length;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onExpand,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFCBD5E1)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x10000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFF0F766E).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  '${band.length}',
                  style: const TextStyle(
                    color: Color(0xFF0F766E),
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${_meridiemRangeLabel(_minutesToTime(startMinutes), _minutesToTime(endMinutes))} collapsed',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF111827),
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      inProgress > 0
                          ? '$inProgress in progress - tap to expand'
                          : '${band.length} orders at this time - tap to expand',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.expand_more, color: Color(0xFF64748B)),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileCollapseHandle extends StatelessWidget {
  final VoidCallback onTap;

  const _MobileCollapseHandle({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.expand_less, size: 16),
      label: const Text('Collapse group'),
      style: TextButton.styleFrom(
        foregroundColor: const Color(0xFF0F766E),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
      ),
    );
  }
}

String _mobileBandKey(List<_TimetableEntry> band) =>
    band.map((e) => e.id).join(',');

int _groupStart(List<_TimetableEntry> group) =>
    group.map((e) => e.serviceStartMinutes).reduce((a, b) => a < b ? a : b);

int _groupEnd(List<_TimetableEntry> group) =>
    group.map((e) => e.cleanupEndMinutes).reduce((a, b) => a > b ? a : b);

// ignore: unused_element
class _MobileHourDivider extends StatelessWidget {
  final int hour;

  const _MobileHourDivider({required this.hour});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 10),
      child: Row(
        children: [
          Text(
            _hourLabel(hour).toUpperCase(),
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF9CA3AF),
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(child: Divider(height: 1, color: Color(0xFFE5E7EB))),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _MobileNowMarker extends StatelessWidget {
  const _MobileNowMarker();

  @override
  Widget build(BuildContext context) {
    final label = DateFormat('h:mm a').format(DateTime.now());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: _timetableAccent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: _timetableAccent,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Divider(height: 1, color: _timetableAccent, thickness: 1),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _MobileBandRow extends StatelessWidget {
  final List<_TimetableEntry> band;
  final String mode;
  final VoidCallback? onCollapse;
  final ValueChanged<_TimetableEntry> onTap;

  const _MobileBandRow({
    required this.band,
    required this.mode,
    required this.onCollapse,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (band.length == 1) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _MobileEntryCard(
          entry: band.first,
          mode: mode,
          width: double.infinity,
          onTap: () => onTap(band.first),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.groups_outlined,
                size: 14,
                color: Color(0xFF6B7280),
              ),
              const SizedBox(width: 6),
              Text(
                '${band.length} running at once',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF6B7280),
                ),
              ),
              const Spacer(),
              if (onCollapse != null)
                GestureDetector(
                  onTap: onCollapse,
                  child: const Text(
                    'Collapse',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1B6B72),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 152,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: band.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, i) => _MobileEntryCard(
                entry: band[i],
                mode: mode,
                width: 250,
                onTap: () => onTap(band[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element
class _MobileCollapsedBand extends StatelessWidget {
  final List<_TimetableEntry> band;
  final int startMinutes;
  final VoidCallback onExpand;

  const _MobileCollapsedBand({
    required this.band,
    required this.startMinutes,
    required this.onExpand,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final inProgress = band.where((e) => e.isHappeningNow(now)).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onExpand,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B6B72).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${band.length}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1B6B72),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_clockLabel(_minutesToTime(startMinutes))} - ${band.length} services running',
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        inProgress > 0
                            ? '$inProgress in progress now'
                            : 'Tap to view all',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.expand_more, color: Color(0xFF6B7280)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileEntryCard extends StatelessWidget {
  final _TimetableEntry entry;
  final String mode;
  final double width;
  final VoidCallback onTap;

  const _MobileEntryCard({
    required this.entry,
    required this.mode,
    required this.width,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = _statusStyle(entry);
    final secondary = mode == 'staff' ? entry.roomDisplayName : entry.staffName;
    return SizedBox(
      width: width,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: style.background,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: style.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.customerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _MobileStatusPill(entry: entry),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  entry.serviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF4B5563),
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  '${_shortClockLabel(entry.operationalStartTime)} - ${_clockLabel(entry.operationalEndTime)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF4B5563),
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(
                      mode == 'staff'
                          ? Icons.meeting_room_outlined
                          : Icons.person_outline,
                      size: 13,
                      color: const Color(0xFF9CA3AF),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        secondary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ),
                  ],
                ),
                if (entry.bufferAfterMinutes > 0) ...[
                  const SizedBox(height: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F3F5),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFD8DCE1)),
                    ),
                    child: Text(
                      '+${entry.bufferAfterMinutes} min buffer until ${_clockLabel(_minutesToTime(entry.cleanupEndMinutes))}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileResourceChip extends StatelessWidget {
  final _TimetableResource resource;
  final List<_TimetableEntry> entries;
  final int nowMinutes;
  final bool selectedToday;
  final bool selected;
  final VoidCallback? onTap;

  const _MobileResourceChip({
    required this.resource,
    required this.entries,
    required this.nowMinutes,
    required this.selectedToday,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final matched = entries
        .where((entry) => !entry.isVoided && resource.matches(entry))
        .toList();
    final status = _resourceStatus(
      resource: resource,
      entries: matched,
      nowMinutes: nowMinutes,
      selectedToday: selectedToday,
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 128,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFEDF7F6) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? const Color(0xFF176B68)
                  : const Color(0xFFDCE3E7),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 15,
                    backgroundColor: status.color.withValues(alpha: 0.13),
                    child: resource.avatarIcon != null
                        ? Icon(
                            resource.avatarIcon,
                            size: 15,
                            color: status.color,
                          )
                        : Text(
                            resource.avatarText,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              color: status.color,
                            ),
                          ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      resource.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF111827),
                      ),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: status.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      status.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: status.color,
                      ),
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

class _TimetableTherapistSwitchOption {
  final _TimetableTherapist therapist;
  final bool isAvailable;
  final String statusLabel;

  const _TimetableTherapistSwitchOption({
    required this.therapist,
    required this.isAvailable,
    required this.statusLabel,
  });
}

class _TimetableTherapistSwitchSelection {
  final String therapistId;
  final String splitMethod;
  final String reason;

  const _TimetableTherapistSwitchSelection({
    required this.therapistId,
    required this.splitMethod,
    required this.reason,
  });
}

class _TimetableTherapistSwitchDialog extends StatefulWidget {
  final String currentTherapistName;
  final String requiredWindow;
  final List<_TimetableTherapistSwitchOption> options;
  final bool receivesFullCommission;

  const _TimetableTherapistSwitchDialog({
    required this.currentTherapistName,
    required this.requiredWindow,
    required this.options,
    required this.receivesFullCommission,
  });

  @override
  State<_TimetableTherapistSwitchDialog> createState() =>
      _TimetableTherapistSwitchDialogState();
}

class _TimetableTherapistSwitchDialogState
    extends State<_TimetableTherapistSwitchDialog> {
  final _reasonController = TextEditingController();
  String? _selectedId;
  String _splitMethod = 'service_time';

  @override
  void initState() {
    super.initState();
    for (final option in widget.options) {
      if (!option.isAvailable) continue;
      _selectedId = option.therapist.id;
      break;
    }
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _confirm() {
    final selectedId = _selectedId;
    if (selectedId == null) return;
    Navigator.pop(
      context,
      _TimetableTherapistSwitchSelection(
        therapistId: selectedId,
        splitMethod: _splitMethod,
        reason: _reasonController.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('Switch Therapist'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.currentTherapistName} will be released from the remaining service time.',
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(
                    Icons.schedule_outlined,
                    size: 18,
                    color: Color(0xFF6B7280),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Coverage needed: ${widget.requiredWindow}',
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Replacement therapist',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.options.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final option = widget.options[index];
                    final therapist = option.therapist;
                    final selected = _selectedId == therapist.id;
                    final statusColor = option.isAvailable
                        ? _timetableAccent
                        : const Color(0xFFB45309);
                    return Material(
                      color: option.isAvailable
                          ? selected
                                ? const Color(0xFFEAF5EF)
                                : Colors.white
                          : const Color(0xFFF8FAFC),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(
                          color: selected
                              ? _timetableAccent
                              : const Color(0xFFE5E7EB),
                          width: selected ? 1.5 : 1,
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: option.isAvailable
                            ? () => setState(() => _selectedId = therapist.id)
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 20,
                                backgroundColor: option.isAvailable
                                    ? const Color(0xFFDDF2E7)
                                    : const Color(0xFFE2E8F0),
                                foregroundColor: option.isAvailable
                                    ? _timetableAccent
                                    : const Color(0xFF6B7280),
                                child: Text(
                                  therapist.initials,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      therapist.name,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: option.isAvailable
                                            ? const Color(0xFF0F172A)
                                            : const Color(0xFF6B7280),
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      option.statusLabel,
                                      style: TextStyle(
                                        color: statusColor,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (selected)
                                const Icon(
                                  Icons.check_circle,
                                  color: _timetableAccent,
                                )
                              else
                                Icon(
                                  option.isAvailable
                                      ? Icons.radio_button_unchecked
                                      : Icons.block_outlined,
                                  color: option.isAvailable
                                      ? const Color(0xFF6B7280)
                                      : const Color(0xFFB45309),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_selectedId == null) ...[
                const SizedBox(height: 10),
                const Text(
                  'No therapist can cover the remaining service without a conflict.',
                  style: TextStyle(
                    color: Color(0xFFB45309),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (widget.receivesFullCommission)
                const Text(
                  'The replacement receives 100% commission because the switch is before or within 15 minutes of service start.',
                  style: TextStyle(fontWeight: FontWeight.w600),
                )
              else ...[
                const Text(
                  'Commission split',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'service_time',
                      label: Text('By time'),
                      icon: Icon(Icons.schedule_outlined),
                    ),
                    ButtonSegment(
                      value: 'half',
                      label: Text('50 / 50'),
                      icon: Icon(Icons.balance_outlined),
                    ),
                  ],
                  selected: {_splitMethod},
                  onSelectionChanged: (selection) =>
                      setState(() => _splitMethod = selection.first),
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: _reasonController,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
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
        FilledButton(
          onPressed: _selectedId == null ? null : _confirm,
          child: const Text('Switch'),
        ),
      ],
    );
  }
}

class _TimetableDetailSheet extends StatelessWidget {
  final _TimetableEntry entry;
  final Future<bool> Function()? onStart;
  final Future<bool> Function()? onSwitchTherapist;

  const _TimetableDetailSheet({
    required this.entry,
    this.onStart,
    this.onSwitchTherapist,
  });

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    final maxHeight = height * 0.82;
    final style = _statusStyle(entry);
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: style.color.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                Flexible(
                  child: _TimetableDetailCard(
                    entry: entry,
                    onClose: () => Navigator.pop(context),
                    onStart: onStart,
                    onSwitchTherapist: onSwitchTherapist,
                    compact: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TimetableDetailCard extends StatefulWidget {
  final _TimetableEntry entry;
  final VoidCallback onClose;
  final Future<bool> Function()? onStart;
  final Future<bool> Function()? onSwitchTherapist;
  final bool compact;

  const _TimetableDetailCard({
    required this.entry,
    required this.onClose,
    this.onStart,
    this.onSwitchTherapist,
    this.compact = false,
  });

  @override
  State<_TimetableDetailCard> createState() => _TimetableDetailCardState();
}

class _TimetableDetailCardState extends State<_TimetableDetailCard> {
  bool _saving = false;

  Future<void> _run(Future<bool> Function()? action) async {
    if (_saving || action == null) return;
    setState(() => _saving = true);
    await action();
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final style = _statusStyle(entry);
    return Container(
      padding: EdgeInsets.all(widget.compact ? 20 : 22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
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
                _PanelStatusBadge(
                  label: entry.operationalStatus,
                  color: style.color,
                ),
                const Spacer(),
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: style.color.withValues(alpha: 0.78),
                  child: Text(
                    _initials(entry.customerName),
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
                        entry.customerName,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entry.customerPhone.isEmpty ? '-' : entry.customerPhone,
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
            _DetailRow(
              icon: Icons.spa_outlined,
              label: 'Service',
              title: entry.serviceName,
              subtitle: entry.typeLabel,
            ),
            _DetailRow(
              icon: Icons.person_outline,
              label: 'Therapist',
              title: entry.staffName,
            ),
            _DetailRow(
              icon: Icons.meeting_room_outlined,
              label: 'Room / Zone',
              title: entry.roomDisplayName,
            ),
            _DetailRow(
              icon: Icons.calendar_today_outlined,
              label: 'Date',
              title: DateFormat('EEEE, d MMMM yyyy').format(entry.selectedDate),
            ),
            _DetailRow(
              icon: Icons.schedule_outlined,
              label: 'Booked time',
              title: entry.bookedTimeRange,
              subtitle: entry.bufferAfterMinutes > 0
                  ? entry.cleanupUntilLabel
                  : null,
            ),
            if (entry.actualStartedAt != null)
              _DetailRow(
                icon: Icons.play_circle_outline,
                label: 'Actual service time',
                title: entry.actualServiceTimeRange,
                subtitle:
                    'Service duration: ${_compactDurationLabel(entry.scheduledServiceMinutes)}',
              ),
            _DetailRow(
              icon: Icons.payments_outlined,
              label: 'Price',
              title: entry.priceLabel,
            ),
            if (entry.hasPayment) ...[
              const Divider(height: 26),
              _DetailRow(
                icon: Icons.receipt_long_outlined,
                label: 'Receipt',
                title: entry.receiptNumber,
              ),
              _DetailRow(
                icon: Icons.credit_card_outlined,
                label: 'Payment',
                title: entry.paymentMethod.isEmpty
                    ? 'Paid'
                    : entry.paymentMethod,
                subtitle: entry.paymentStatus.isEmpty
                    ? null
                    : entry.paymentStatus.toUpperCase(),
              ),
              _DetailRow(
                icon: Icons.account_balance_wallet_outlined,
                label: 'Paid',
                title: entry.paidLabel,
              ),
            ],
            if (entry.canStartService || entry.canSwitchTherapist) ...[
              const Divider(height: 26),
              if (entry.canStartService)
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : () => _run(widget.onStart),
                    icon: _saving
                        ? const SizedBox(
                            width: 17,
                            height: 17,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.play_arrow_rounded),
                    label: const Text('Start Service'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _timetableAccent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              if (entry.canSwitchTherapist)
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton.icon(
                    onPressed: _saving
                        ? null
                        : () => _run(widget.onSwitchTherapist),
                    icon: _saving
                        ? const SizedBox(
                            width: 17,
                            height: 17,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.swap_horiz_rounded),
                    label: const Text('Switch Therapist'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _timetableAccent,
                      side: const BorderSide(color: _timetableAccent),
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

class _PanelStatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _PanelStatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String title;
  final String? subtitle;

  const _DetailRow({
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
          Icon(icon, color: const Color(0xFF4B5563), size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  title.isEmpty ? '-' : title,
                  style: const TextStyle(
                    color: Color(0xFF111827),
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontSize: 12,
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

class _TimetableSettingsSheet extends StatelessWidget {
  final int openMinute;
  final int closeMinute;

  const _TimetableSettingsSheet({
    required this.openMinute,
    required this.closeMinute,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 460),
          margin: const EdgeInsets.all(14),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [
              BoxShadow(
                color: Color(0x26000000),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F5F5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.settings_outlined,
                      color: Color(0xFF0F766E),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Timetable settings',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF111827),
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Daily grid display rules',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF6B7280),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _SettingsInfoRow(
                icon: Icons.access_time,
                title: 'Displayed hours',
                value:
                    '${_clockLabel(_minutesToTime(openMinute))} - ${_clockLabel(_minutesToTime(closeMinute))}',
              ),
              const _SettingsInfoRow(
                icon: Icons.people_alt_outlined,
                title: 'Rows',
                value: 'Every therapist or room is shown, even when free.',
              ),
              const _SettingsInfoRow(
                icon: Icons.cleaning_services_outlined,
                title: 'Cleanup buffer',
                value:
                    'Shown as a separate block after the service, but still blocks staff and room availability.',
              ),
              const _SettingsInfoRow(
                icon: Icons.meeting_room_outlined,
                title: 'Room / zone capacity',
                value:
                    'Zones with more than one slot can host multiple bookings at once, shown stacked side by side.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsInfoRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;

  const _SettingsInfoRow({
    required this.icon,
    required this.title,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF0F766E)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6B7280),
                    height: 1.35,
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
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 34, color: const Color(0xFF1B6B72)),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
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

_StatusStyle _statusStyle(_TimetableEntry entry) {
  if (entry.isVoided || entry.isCancelled) {
    return const _StatusStyle(
      color: Color(0xFF6B7280),
      background: Color(0xFFF3F4F6),
      border: Color(0xFFD1D5DB),
    );
  }
  if (entry.isNoShow) {
    return const _StatusStyle(
      color: Color(0xFFB91C1C),
      background: Color(0xFFFEF2F2),
      border: Color(0xFFFCA5A5),
    );
  }
  if (entry.isInProgress) {
    return const _StatusStyle(
      color: Color(0xFFF97316),
      background: Color(0xFFFFF7ED),
      border: Color(0xFFFED7AA),
    );
  }
  if (entry.isCompleted) {
    return const _StatusStyle(
      color: Color(0xFF047857),
      background: Color(0xFFE7F8EF),
      border: Color(0xFF34D399),
    );
  }
  if (entry.isLateArrival) {
    return const _StatusStyle(
      color: Color(0xFFB91C1C),
      background: Color(0xFFFEF2F2),
      border: Color(0xFFFCA5A5),
    );
  }
  if (entry.hasDelayWarning) {
    return const _StatusStyle(
      color: Color(0xFFD97706),
      background: Color(0xFFFFFBEB),
      border: Color(0xFFFCD34D),
    );
  }
  return const _StatusStyle(
    color: Color(0xFF2563EB),
    background: Color(0xFFEFF6FF),
    border: Color(0xFF93C5FD),
  );
}

String _initials(String value) {
  final parts = value
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty);
  final letters = parts.take(2).map((part) => part[0]).join();
  return letters.isEmpty ? '?' : letters.toUpperCase();
}

String _compactInitials(String value) {
  final display = _displayCustomerName(value);
  if (display.toLowerCase() == 'guest') return 'G';
  final parts = display
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first[0].toUpperCase();
  return '${parts.first[0]}.${parts.last[0]}'.toUpperCase();
}

int _readServiceCount(Object? raw, String fallbackLabel) {
  final names = <String>{};

  void addName(Object? value) {
    if (value == null) return;
    if (value is Map) {
      final name = asString(value['name']).isNotEmpty
          ? asString(value['name'])
          : asString(value['serviceName']);
      if (name.trim().isNotEmpty) names.add(name.trim().toLowerCase());
      return;
    }
    final name = value.toString().trim();
    if (name.isNotEmpty) names.add(name.toLowerCase());
  }

  if (raw is Iterable) {
    for (final item in raw) {
      addName(item);
    }
  } else if (raw is String && raw.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Iterable) {
        for (final item in decoded) {
          addName(item);
        }
      } else {
        addName(decoded);
      }
    } catch (_) {
      addName(raw);
    }
  }

  if (names.isNotEmpty) return names.length;
  final fallbackParts = fallbackLabel
      .split(RegExp(r'\s*(?:,|\+|/)\s*'))
      .where((part) => part.trim().isNotEmpty)
      .toList();
  return fallbackParts.length > 1 ? fallbackParts.length : 1;
}

String _serviceCountLabel(int count) {
  return count == 1 ? '1 service' : '$count services';
}

String _compactDurationLabel(int minutes) {
  final safe = minutes.clamp(0, 24 * 60).toInt();
  if (safe < 60) return '${safe}m';
  final hours = safe ~/ 60;
  final mins = safe % 60;
  if (mins == 0) return '${hours}h';
  return '${hours}h ${mins}m';
}

String _timelineServiceLabel(_TimetableEntry entry, double width) {
  if (entry.serviceCount > 1 &&
      (width < 180 || entry.serviceName.length > 26)) {
    return _serviceCountLabel(entry.serviceCount);
  }
  return entry.serviceName;
}

String _shortCustomerName(String value) {
  final display = _displayCustomerName(value);
  if (display.length <= 10) return display;
  final parts = display
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.length >= 2) return '${parts.first} ${parts.last[0]}.';
  return display;
}

String _titleCase(String value) {
  final words = value
      .split(RegExp(r'[_\s]+'))
      .where((word) => word.isNotEmpty)
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}');
  final joined = words.join(' ');
  return joined.isEmpty ? 'Room' : joined;
}

Color _avatarColor(String value) {
  const colors = [
    Color(0xFF2563EB),
    Color(0xFF0F766E),
    Color(0xFF7C3AED),
    Color(0xFFDB2777),
    Color(0xFF0891B2),
    Color(0xFF059669),
  ];
  if (value.trim().isEmpty) return colors.first;
  final hash = value.codeUnits.fold<int>(0, (total, unit) => total + unit);
  return colors[hash % colors.length];
}

IconData _roomIcon(String value) {
  final type = value.toLowerCase();
  if (type.contains('foot')) return Icons.directions_walk_outlined;
  if (type.contains('face')) return Icons.face_retouching_natural_outlined;
  if (type.contains('couple') || type.contains('group')) {
    return Icons.groups_outlined;
  }
  if (type.contains('vip')) return Icons.stars_outlined;
  if (type.contains('body') || type.contains('massage')) {
    return Icons.spa_outlined;
  }
  return Icons.meeting_room_outlined;
}

Color _roomAccentColor(String value) {
  final type = value.toLowerCase();
  if (type.contains('foot')) return const Color(0xFF059669);
  if (type.contains('upper')) return const Color(0xFF2563EB);
  if (type.contains('lower')) return const Color(0xFF7C3AED);
  if (type.contains('face')) return const Color(0xFFDB2777);
  if (type.contains('vip')) return const Color(0xFFF97316);
  return const Color(0xFF0F766E);
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
  return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
}

String _minutesToTime(int minutes) {
  final normalized = minutes % (24 * 60);
  final hour = (normalized ~/ 60).toString().padLeft(2, '0');
  final minute = (normalized % 60).toString().padLeft(2, '0');
  return '$hour:$minute';
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

String _shortClockLabel(String time) {
  final minutes = _timeToMinutes(time);
  final hour = minutes ~/ 60;
  final minute = minutes % 60;
  return DateFormat('h:mm').format(DateTime(2026, 1, 1, hour, minute));
}

/// Renders a start-end range with AM/PM markers, dropping the leading
/// marker when both ends share the same period (e.g. "3:22 - 4:22 PM")
/// so the range stays compact instead of repeating "PM" twice.
String _meridiemRangeLabel(String start, String end) {
  final startMinutes = _timeToMinutes(start) % (24 * 60);
  final endMinutes = _timeToMinutes(end) % (24 * 60);
  final startPeriod = startMinutes < 720 ? 'AM' : 'PM';
  final endPeriod = endMinutes < 720 ? 'AM' : 'PM';
  final startDigits = _shortClockLabel(start);
  final endDigits = _shortClockLabel(end);
  if (startPeriod == endPeriod) {
    return '$startDigits - $endDigits $endPeriod';
  }
  return '$startDigits $startPeriod - $endDigits $endPeriod';
}

String _hourLabel(int hour) {
  return DateFormat('ha').format(DateTime(2026, 1, 1, hour)).toLowerCase();
}
