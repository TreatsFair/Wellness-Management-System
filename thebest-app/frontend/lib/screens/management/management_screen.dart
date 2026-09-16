import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../core/accessibility/accessibility_settings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/staff_initials.dart';
import '../../data/repositories/appointment_repository.dart';
import '../../data/repositories/image_upload_repository.dart';
import '../../data/repositories/room_repository.dart';
import '../../data/repositories/service_repository.dart';
import '../../data/repositories/therapist_repository.dart';
import '../../data/services/supabase_table_service.dart';
import '../../widgets/adaptive_detail_surface.dart';
import '../../widgets/management_catalogue_shell.dart';
import '../therapists/therapist_screen.dart';
import 'accessibility_screen.dart';
import 'business_settings_screen.dart';
import 'online_booking_screen.dart';
import 'payment_refunds_screen.dart';
import 'service_management_screen.dart';

const _teal = Color(0xFF1B6B72);
const _ink = Color(0xFF1A1A2E);
const _muted = Color(0xFF6B7280);
const _page = Color(0xFFF4F5F7);
const _roomFloorOptions = ['Ground', 'Upper'];

String _asString(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  return value.toString();
}

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

double _asDouble(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

bool _asBool(Object? value, [bool fallback = true]) {
  if (value is bool) return value;
  if (value is String) return value.toLowerCase().trim() == 'true';
  return fallback;
}

String _normalizeStaffRole(Object? value) {
  final raw = value?.toString().trim().toLowerCase() ?? '';
  if (raw.contains('counter') || raw.contains('cashier')) return 'Counter';
  return 'Therapist';
}

String _normalizeRoomType(Object? value) {
  final raw = value?.toString().trim().toLowerCase() ?? '';
  if (raw.isEmpty || raw == '-') return '';
  final normalized = raw.replaceAll(RegExp(r'[\s-]+'), '_');
  if (normalized.contains('body')) return 'body_room';
  if (normalized.contains('foot')) return 'foot_chair';
  return normalized;
}

String _roomTypeLabel(String value) {
  switch (_normalizeRoomType(value)) {
    case 'body_room':
      return 'Body Room';
    case 'foot_chair':
      return 'Foot Chair';
    default:
      return value.isEmpty ? 'Any Room' : value;
  }
}

String _normalizeRoomFloor(Object? value) {
  final floor = value?.toString().trim().toLowerCase() ?? '';
  if (floor == 'upper' ||
      floor == 'first' ||
      floor == 'second' ||
      floor == 'third' ||
      floor == 'both') {
    return 'Upper';
  }
  return 'Ground';
}

String _today() => DateFormat('yyyy-MM-dd').format(DateTime.now());

int _timeToMinutes(String value) {
  final parts = value.split(':');
  if (parts.length < 2) return 0;
  return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
}

String _minutesToClock(int minutes) {
  final normalized = minutes % (24 * 60);
  return '${(normalized ~/ 60).toString().padLeft(2, '0')}:'
      '${(normalized % 60).toString().padLeft(2, '0')}';
}

String _friendlyTime(String value) {
  final minutes = _timeToMinutes(value);
  return DateFormat(
    'h:mm a',
  ).format(DateTime(2026, 1, 1, minutes ~/ 60, minutes % 60));
}

bool _isPendingAppointmentStatus(String status) {
  return status == 'pending' ||
      status == 'confirmed' ||
      status == 'in_progress';
}

String _initials(String name) => staffInitials(name);

Color _avatarColor(String seed) {
  final colors = [
    _teal,
    const Color(0xFFD19A33),
    const Color(0xFF8B5CF6),
    const Color(0xFFE83E8C),
    const Color(0xFF2563EB),
    const Color(0xFF10B981),
  ];
  return colors[seed.length % colors.length];
}

class ManagementScreen extends StatelessWidget {
  final String userRole;

  const ManagementScreen({super.key, this.userRole = 'staff'});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const _ManagementHeader(
              title: 'Management',
              subtitle: 'Manage services, staff, and resources',
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                children: [
                  _ManagementOption(
                    icon: Icons.content_cut_rounded,
                    color: AppColors.primary,
                    title: 'Services',
                    subtitle: userRole.trim().toLowerCase() == 'admin'
                        ? 'Manage service offerings and pricing'
                        : 'View service offerings and pricing',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            ServiceManagementScreen(userRole: userRole),
                      ),
                    ),
                  ),
                  _ManagementOption(
                    icon: Icons.groups_rounded,
                    color: AppColors.accent,
                    title: 'Staff',
                    subtitle: 'Manage staff roles, schedules, and availability',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TherapistsScreen(userRole: userRole),
                      ),
                    ),
                  ),
                  _ManagementOption(
                    icon: Icons.meeting_room_rounded,
                    color: AppColors.info,
                    title: 'Rooms',
                    subtitle: 'Manage room availability and equipment',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _ServiceRoomScreen(
                          type: _ResourceType.room,
                          userRole: userRole,
                        ),
                      ),
                    ),
                  ),
                  if (userRole == 'admin')
                    _ManagementOption(
                      icon: Icons.tune_rounded,
                      color: AppColors.info,
                      title: 'Business Settings',
                      subtitle:
                          'Outlet SST, rounding, late arrival, and no-show rules',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const BusinessSettingsScreen(),
                        ),
                      ),
                    ),
                  _ManagementOption(
                    icon: Icons.accessibility_new_rounded,
                    color: AppColors.primary,
                    title: 'Accessibility',
                    subtitle: 'Adjust text, controls, cards, and display size',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AccessibilityScreen(),
                      ),
                    ),
                  ),
                  if (userRole.trim().toLowerCase() == 'admin')
                    _ManagementOption(
                      icon: Icons.language_rounded,
                      color: AppColors.accent,
                      title: 'Online Booking',
                      subtitle:
                          'Control public services, schedules, rooms, closures, and promotions',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => OnlineBookingScreen(
                            userRole: userRole,
                          ),
                        ),
                      ),
                    ),
                  if (userRole.trim().toLowerCase() == 'admin')
                    _ManagementOption(
                      icon: Icons.payments_outlined,
                      color: AppColors.warning,
                      title: 'Payments & Refunds',
                      subtitle:
                          'Read-only Fiuu payment, refund, and review status',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const PaymentRefundsScreen(),
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
}

class _ManagementHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? action;

  const _ManagementHeader({
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final horizontalPadding = width < 360 ? 14.0 : 20.0;
    final isCompact = width < 600;

    return Container(
      width: double.infinity,
      color: context.appSurface,
      padding: EdgeInsets.fromLTRB(4, 14, horizontalPadding, 14),
      child: Row(
        children: [
          const BackButton(color: _teal),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: context.appText,
                    fontSize: isCompact ? 18 : 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (!isCompact) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(color: context.appMuted, fontSize: 14),
                  ),
                ],
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _ManagementOption extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ManagementOption({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final metrics = context.uiScale;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: context.appSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.appBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: metrics.cardPadding,
              vertical: metrics.cardPadding + 6,
            ),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: color.withValues(alpha: 0.14)),
                  ),
                  child: Icon(icon, color: color, size: 29),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          color: context.appText,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 14,
                          color: context.appMuted,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: context.appMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _ResourceType { service, room }

class _ResourceItem {
  final String id;
  final String name;
  final String subtitle;
  final String detail;
  final String statusText;
  final bool active;
  final Color color;
  final Map<String, dynamic> raw;

  const _ResourceItem({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.detail,
    required this.statusText,
    required this.active,
    required this.color,
    required this.raw,
  });

  factory _ResourceItem.fromService(Map<String, dynamic> d) {
    final name = _asString(d['name']);
    final duration = _asInt(d['duration'], 60);
    final price = _asDouble(d['price']);
    final therapistCommission = _asDouble(d['therapistCommission']);
    final counterCommission = _asDouble(d['counterCommission']);
    final bufferAfter = _asInt(d['bufferAfterMinutes'], 0);
    final active = _asBool(d['active'] ?? d['isActive'], true);
    final durationLabel = bufferAfter > 0
        ? '$duration min + $bufferAfter min cleanup'
        : '$duration min';
    return _ResourceItem(
      id: _asString(d['id']),
      name: name,
      subtitle: _asString(d['category'], 'Services'),
      detail:
          '$durationLabel | RM ${price.toStringAsFixed(0)} | Comm RM ${therapistCommission.toStringAsFixed(0)}/${counterCommission.toStringAsFixed(0)}',
      statusText: active ? 'Active' : 'Inactive',
      active: active,
      color: _teal,
      raw: d,
    );
  }

  factory _ResourceItem.fromRoom(Map<String, dynamic> d) {
    final name = _asString(d['name']);
    final totalSlots = _asInt(d['totalSlots'], 1);
    final active = _asBool(d['active'] ?? d['isActive'], true);
    final busySlots = _asInt(d['currentBusySlots']);
    final freeSlots = (totalSlots - busySlots).clamp(0, totalSlots);
    final busyUntil = _asString(d['currentBusyUntil']);
    final status = !active
        ? 'Unavailable'
        : busySlots == 0
        ? 'Available'
        : freeSlots == 0
        ? 'Fully occupied until ${_friendlyTime(busyUntil)}'
        : '$busySlots/$totalSlots occupied until ${_friendlyTime(busyUntil)}';
    return _ResourceItem(
      id: _asString(d['id']),
      name: name,
      subtitle: _roomTypeLabel(_asString(d['type'] ?? d['roomType'])),
      detail:
          '${_asString(d['floor'], 'Main Floor')} | $freeSlots of $totalSlots slot${totalSlots == 1 ? '' : 's'} available',
      statusText: status,
      active: active,
      color: const Color(0xFF8B5CF6),
      raw: d,
    );
  }
}

class _ServiceRoomScreen extends StatefulWidget {
  final _ResourceType type;
  final String userRole;

  const _ServiceRoomScreen({required this.type, required this.userRole});

  @override
  State<_ServiceRoomScreen> createState() => _ServiceRoomScreenState();
}

class _ServiceRoomScreenState extends State<_ServiceRoomScreen> {
  final _serviceRepository = ServiceRepository();
  final _roomRepository = RoomRepository();
  final _appointmentRepository = AppointmentRepository();
  final _searchController = TextEditingController();
  List<_ResourceItem> _items = [];
  List<_ResourceItem> _filtered = [];
  _ResourceItem? _selected;
  bool _loading = true;
  String _resourceFilter = 'all';
  String _resourceSort = 'newest';
  bool _gridView = true;

  String get _title =>
      widget.type == _ResourceType.service ? 'Services' : 'Rooms';
  String get _subtitle => widget.type == _ResourceType.service
      ? 'Manage service offerings and pricing'
      : 'Manage room availability and equipment';
  bool get _isAdmin => widget.userRole == 'admin';
  bool get _canDeleteCurrentType => _isAdmin;

  List<_ResourceItem> get _visibleItems {
    final visible = _filtered.where((item) {
      if (_resourceFilter == 'available') {
        return item.active && _asInt(item.raw['currentBusySlots']) == 0;
      }
      if (_resourceFilter == 'occupied') {
        return item.active && _asInt(item.raw['currentBusySlots']) > 0;
      }
      if (_resourceFilter == 'inactive') return !item.active;
      if (_resourceFilter.startsWith('type:')) {
        return _normalizeRoomType(item.raw['type'] ?? item.raw['roomType']) ==
            _resourceFilter.substring(5);
      }
      return true;
    }).toList();
    visible.sort((left, right) {
      return switch (_resourceSort) {
        'name' => left.name.compareTo(right.name),
        'capacity' => _asInt(
          right.raw['totalSlots'],
          1,
        ).compareTo(_asInt(left.raw['totalSlots'], 1)),
        _ =>
          (DateTime.tryParse(
                    _asString(
                      right.raw['createdAt'] ?? right.raw['created_at'],
                    ),
                  ) ??
                  DateTime(1970))
              .compareTo(
                DateTime.tryParse(
                      _asString(
                        left.raw['createdAt'] ?? left.raw['created_at'],
                      ),
                    ) ??
                    DateTime(1970),
              ),
      };
    });
    return visible;
  }

  @override
  void initState() {
    super.initState();
    _load();
    _searchController.addListener(_filter);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      var rows = widget.type == _ResourceType.service
          ? await _serviceRepository.getServices()
          : await _roomRepository.getRooms();
      if (widget.type == _ResourceType.room) {
        rows = await _withLiveRoomStatus(rows);
      }
      final items = rows
          .map(
            (row) => widget.type == _ResourceType.service
                ? _ResourceItem.fromService(row)
                : _ResourceItem.fromRoom(row),
          )
          .toList();
      if (!mounted) return;
      setState(() {
        _items = items;
        _filtered = items;
        _selected = _selected == null
            ? null
            : items.cast<_ResourceItem?>().firstWhere(
                (item) => item?.id == _selected?.id,
                orElse: () => null,
              );
        _loading = false;
      });
      _filter();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<Map<String, dynamic>>> _withLiveRoomStatus(
    List<Map<String, dynamic>> rooms,
  ) async {
    final now = DateTime.now();
    final today = DateFormat('yyyy-MM-dd').format(now);
    final yesterday = DateFormat(
      'yyyy-MM-dd',
    ).format(now.subtract(const Duration(days: 1)));
    final appointments = await _appointmentRepository
        .getAppointmentsInDateRange(yesterday, today);
    final activeByRoom = <String, List<DateTime>>{};

    for (final appointment in appointments) {
      final status = _asString(appointment['status']).toLowerCase();
      if (!_isPendingAppointmentStatus(status)) continue;
      final roomId = _asString(appointment['roomId']);
      if (roomId.isEmpty) continue;
      final date = DateTime.tryParse(_asString(appointment['date'])) ?? now;
      final start =
          DateTime.tryParse(_asString(appointment['startAt']))?.toLocal() ??
          DateTime(date.year, date.month, date.day).add(
            Duration(
              minutes: _timeToMinutes(_asString(appointment['startTime'])),
            ),
          );
      var end = DateTime.tryParse(_asString(appointment['endAt']))?.toLocal();
      if (end == null) {
        var endMinutes = _timeToMinutes(_asString(appointment['endTime']));
        if (endMinutes <= _timeToMinutes(_asString(appointment['startTime']))) {
          endMinutes += 24 * 60;
        }
        end = DateTime(
          date.year,
          date.month,
          date.day,
        ).add(Duration(minutes: endMinutes));
      }
      final blockedUntil = end.add(
        Duration(minutes: _asInt(appointment['bufferAfterMinutes'])),
      );
      if (!now.isBefore(start) && now.isBefore(blockedUntil)) {
        activeByRoom.putIfAbsent(roomId, () => []).add(blockedUntil);
      }
    }

    return rooms.map((room) {
      final occupied =
          activeByRoom[_asString(room['id'])] ?? const <DateTime>[];
      DateTime? latest;
      for (final end in occupied) {
        if (latest == null || end.isAfter(latest)) latest = end;
      }
      return {
        ...room,
        'currentBusySlots': occupied.length,
        'currentBusyUntil': latest == null
            ? ''
            : DateFormat('HH:mm').format(latest),
      };
    }).toList();
  }

  void _filter() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      _filtered = _items.where((item) {
        return item.name.toLowerCase().contains(query) ||
            item.subtitle.toLowerCase().contains(query) ||
            item.detail.toLowerCase().contains(query);
      }).toList();
      if (_filtered.isEmpty) {
        _selected = null;
      } else if (_selected == null ||
          !_filtered.any((item) => item.id == _selected!.id)) {
        _selected = null;
      }
    });
  }

  Future<void> _openResourceDetail(_ResourceItem item) async {
    setState(() => _selected = item);
    final editRequested = await showAdaptiveDetailSurface<bool>(
      context: context,
      barrierLabel: 'Close ${_title.toLowerCase()} details',
      builder: (detailContext, isFullScreen) =>
          ManagementCatalogueDetailSurface(
            title: 'Room Details',
            subtitle: item.name,
            isFullScreen: isFullScreen,
            footer: CatalogueDetailEditButton(
              label: 'Edit Room',
              onPressed: () => Navigator.of(detailContext).pop(true),
            ),
            child: _ResourceDetailCard(
              item: item,
              title: _title,
              onEdit: () => Navigator.of(detailContext).pop(true),
              onDelete: () async {
                final deleted = await _delete(item);
                if (deleted && detailContext.mounted) {
                  Navigator.of(detailContext).pop(false);
                }
              },
              showInlineEdit: false,
              canDelete: false,
            ),
          ),
    );
    if (!mounted) return;
    setState(() => _selected = null);
    if (editRequested == true) await _openForm(item: item);
  }

  List<String> get _roomTypes {
    final types =
        _items
            .map(
              (item) =>
                  _normalizeRoomType(item.raw['type'] ?? item.raw['roomType']),
            )
            .where((type) => type.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return types;
  }

  Widget _resourceNavigation() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 24),
      children: [
        CatalogueSidebarTile(
          icon: Icons.meeting_room_outlined,
          title: 'All Rooms',
          subtitle: 'Every treatment room',
          count: _items.length,
          selected: _resourceFilter == 'all',
          onTap: () => setState(() => _resourceFilter = 'all'),
          color: const Color(0xFF8B5CF6),
        ),
        ..._roomTypes.map((type) {
          final id = 'type:$type';
          return CatalogueSidebarTile(
            icon: Icons.grid_view_outlined,
            title: _roomTypeLabel(type),
            subtitle: 'Browse this room type',
            count: _items
                .where(
                  (item) =>
                      _normalizeRoomType(
                        item.raw['type'] ?? item.raw['roomType'],
                      ) ==
                      type,
                )
                .length,
            selected: _resourceFilter == id,
            onTap: () => setState(() => _resourceFilter = id),
            color: const Color(0xFF8B5CF6),
          );
        }),
      ],
    );
  }

  Widget _resourceMobileNavigation() {
    return CatalogueMobileNavigation(
      children: [
        CatalogueNavigationChip(
          label: 'All',
          selected: _resourceFilter == 'all',
          onTap: () => setState(() => _resourceFilter = 'all'),
        ),
        for (final type in _roomTypes)
          CatalogueNavigationChip(
            label: _roomTypeLabel(type),
            selected: _resourceFilter == 'type:$type',
            onTap: () => setState(() => _resourceFilter = 'type:$type'),
          ),
      ],
    );
  }

  // ignore: unused_element
  Widget _resourceFilterMenu() {
    return PopupMenuButton<String>(
      initialValue: _resourceFilter.startsWith('type:')
          ? 'all'
          : _resourceFilter,
      onSelected: (value) => setState(() => _resourceFilter = value),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'all', child: Text('All rooms')),
        PopupMenuItem(value: 'available', child: Text('Available')),
        PopupMenuItem(value: 'occupied', child: Text('Occupied')),
        PopupMenuItem(value: 'inactive', child: Text('Inactive')),
      ],
      child: CatalogueToolbarButton(
        icon: Icons.filter_list,
        label: switch (_resourceFilter) {
          'available' => 'Available',
          'occupied' => 'Occupied',
          'inactive' => 'Inactive',
          _ => 'All',
        },
      ),
    );
  }

  // ignore: unused_element
  Widget _resourceSortMenu() {
    return PopupMenuButton<String>(
      initialValue: _resourceSort,
      onSelected: (value) => setState(() => _resourceSort = value),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'newest', child: Text('Newest')),
        PopupMenuItem(value: 'name', child: Text('Name')),
        PopupMenuItem(value: 'capacity', child: Text('Capacity')),
      ],
      child: CatalogueToolbarButton(
        icon: Icons.swap_vert,
        label: switch (_resourceSort) {
          'name' => 'Name',
          'capacity' => 'Capacity',
          _ => 'Newest',
        },
      ),
    );
  }

  Widget _resourceCatalogue() {
    final visible = _visibleItems;
    if (visible.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: const [
            SizedBox(height: 150),
            Center(child: Text('No rooms match these filters.')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final padding = constraints.maxWidth >= 900 ? 24.0 : 16.0;
          final cardHeight =
              context.managementCatalogueCardHeight +
              (constraints.maxWidth < 600 ? 16 : 0);
          if (!_gridView) {
            return ListView.separated(
              padding: EdgeInsets.fromLTRB(padding, 16, padding, 28),
              itemCount: visible.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) => SizedBox(
                height: context.managementCatalogueListHeight,
                child: _RoomCatalogueCard(
                  item: visible[index],
                  compact: true,
                  selected: _selected?.id == visible[index].id,
                  onTap: () => _openResourceDetail(visible[index]),
                ),
              ),
            );
          }
          return GridView.builder(
            padding: EdgeInsets.fromLTRB(padding, 16, padding, 28),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 330,
              mainAxisExtent: cardHeight,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: visible.length,
            itemBuilder: (context, index) => _RoomCatalogueCard(
              item: visible[index],
              selected: _selected?.id == visible[index].id,
              onTap: () => _openResourceDetail(visible[index]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openForm({_ResourceItem? item}) async {
    final saved = await showAdaptiveDetailSurface<bool>(
      context: context,
      barrierLabel: item == null ? 'Close new room' : 'Close room editor',
      builder: (_, isFullScreen) => _ResourceEditorSurface(
        type: widget.type,
        item: item,
        isAdmin: _isAdmin,
        isFullScreen: isFullScreen,
      ),
    );
    if (saved == true) await _load();
  }

  Future<bool> _delete(_ResourceItem item) async {
    if (!_isAdmin) {
      final resourceName = widget.type == _ResourceType.service
          ? 'services'
          : 'rooms';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Only admins can delete $resourceName'),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return false;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Remove ${widget.type == _ResourceType.service ? 'Service' : 'Room'}',
        ),
        content: Text('Remove ${item.name} from $_title?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
              foregroundColor: Colors.white,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    if (widget.type == _ResourceType.service) {
      await _serviceRepository.deleteService(item.id);
    } else {
      await _roomRepository.deleteRoom(item.id);
    }
    await _load();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: _teal)),
      );
    }
    final visible = _visibleItems;
    final compact = MediaQuery.sizeOf(context).width < 900;
    return ManagementCatalogueShell(
      moduleTitle: _title,
      moduleSubtitle: _subtitle,
      contentTitle: switch (_resourceFilter) {
        'available' => 'Available Rooms',
        'occupied' => 'Occupied Rooms',
        'inactive' => 'Inactive Rooms',
        _ when _resourceFilter.startsWith('type:') => _roomTypeLabel(
          _resourceFilter.substring(5),
        ),
        _ => 'All Rooms',
      },
      itemCountLabel: '${visible.length} room${visible.length == 1 ? '' : 's'}',
      addLabel: 'Add Room',
      onAdd: () => _openForm(),
      navigation: _resourceNavigation(),
      mobileNavigation: compact
          ? const SizedBox.shrink()
          : _resourceMobileNavigation(),
      headerActions: compact
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CatalogueHeaderChip(
                  label: 'All',
                  selected: _resourceFilter == 'all',
                  onTap: () => setState(() => _resourceFilter = 'all'),
                ),
                for (final type in _roomTypes)
                  CatalogueHeaderChip(
                    label: _roomTypeLabel(type),
                    selected: _resourceFilter == 'type:$type',
                    onTap: () => setState(() => _resourceFilter = 'type:$type'),
                  ),
                CatalogueViewSwitch(
                  gridView: _gridView,
                  onChanged: (value) => setState(() => _gridView = value),
                ),
              ],
            )
          : CatalogueViewSwitch(
              gridView: _gridView,
              onChanged: (value) => setState(() => _gridView = value),
            ),
      content: _resourceCatalogue(),
    );
  }

  // Kept temporarily for the legacy compact resource detail route.
  // ignore: unused_element
  Widget _resourceListPane({bool phone = false}) {
    final horizontalPadding = MediaQuery.of(context).size.width < 360
        ? 12.0
        : 16.0;
    return Container(
      color: phone ? _page : Colors.white,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              phone ? horizontalPadding : 14,
              14,
              phone ? horizontalPadding : 14,
              14,
            ),
            child: _SearchBar(
              controller: _searchController,
              hint: 'Search ${_title.toLowerCase()}...',
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              color: _teal,
              child: ListView.builder(
                padding: EdgeInsets.fromLTRB(
                  phone ? horizontalPadding : 10,
                  0,
                  phone ? horizontalPadding : 10,
                  18,
                ),
                itemCount: _filtered.length,
                itemBuilder: (_, index) {
                  final item = _filtered[index];
                  return _ResourceListCard(
                    item: item,
                    selected: !phone && _selected?.id == item.id,
                    onTap: () {
                      if (phone) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => _ResourcePhoneDetail(
                              title: _title,
                              item: item,
                              onEdit: () => _openForm(item: item),
                              onDelete: () => _delete(item),
                              canDelete: _canDeleteCurrentType,
                            ),
                          ),
                        );
                      } else {
                        setState(() => _selected = item);
                      }
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _resourceDetailPane() {
    final item = _selected;
    if (item == null) {
      return Center(
        child: Text(
          'Select ${_title.toLowerCase()} to view details',
          style: const TextStyle(color: _muted),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(18),
      child: _ResourceDetailCard(
        item: item,
        title: _title,
        onEdit: () => _openForm(item: item),
        onDelete: () => _delete(item),
        canDelete: _canDeleteCurrentType,
      ),
    );
  }
}

class _RoomCatalogueCard extends StatelessWidget {
  const _RoomCatalogueCard({
    required this.item,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final _ResourceItem item;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF8B5CF6);
    final narrowGrid = !compact && MediaQuery.sizeOf(context).width < 600;
    final totalSlots = _asInt(item.raw['totalSlots'], 1);
    final busySlots = _asInt(item.raw['currentBusySlots']);
    final freeSlots = (totalSlots - busySlots).clamp(0, totalSlots);
    final statusColor = !item.active
        ? const Color(0xFF64748B)
        : busySlots == 0
        ? const Color(0xFF059669)
        : const Color(0xFFD97706);
    final statusLabel = !item.active
        ? 'Inactive'
        : busySlots == 0
        ? 'Available'
        : 'Occupied';
    final identity = Row(
      children: [
        Container(
          width: compact
              ? 46
              : narrowGrid
              ? 40
              : 50,
          height: compact
              ? 46
              : narrowGrid
              ? 40
              : 50,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.11),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(
            Icons.meeting_room_outlined,
            color: accent,
            size: 24,
          ),
        ),
        SizedBox(width: narrowGrid ? 8 : 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: item.subtitle),
                    const TextSpan(text: ' · '),
                    TextSpan(
                      text: statusLabel,
                      style: TextStyle(
                        color: statusColor,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF64748B),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return Material(
      color: selected ? accent.withValues(alpha: 0.07) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? accent : const Color(0xFFE2E8F0),
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(narrowGrid ? 12 : 14),
          child: compact
              ? Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.11),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.meeting_room_outlined,
                              color: accent,
                              size: 23,
                            ),
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _ink,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text:
                                            '${item.subtitle} · $freeSlots/$totalSlots free slots · ${_asString(item.raw['floor'], 'Main Floor')} · ',
                                      ),
                                      TextSpan(
                                        text: statusLabel,
                                        style: TextStyle(
                                          color: statusColor,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFF64748B),
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 5),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: Color(0xFF64748B),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    identity,
                    const SizedBox(height: 10),
                    const Divider(height: 1),
                    const SizedBox(height: 8),
                    _RoomCardMetric(
                      icon: Icons.layers_outlined,
                      label: '$freeSlots/$totalSlots free slots',
                    ),
                    const SizedBox(height: 6),
                    _RoomCardMetric(
                      icon: Icons.map_outlined,
                      label: _asString(item.raw['floor'], 'Main Floor'),
                    ),
                    const Spacer(),
                    if (_asString(item.raw['equipment']).trim().isNotEmpty)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _asString(item.raw['equipment']),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF475569),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFF64748B),
                          ),
                        ],
                      )
                    else
                      const Align(
                        alignment: Alignment.centerRight,
                        child: Icon(
                          Icons.chevron_right_rounded,
                          color: Color(0xFF64748B),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _RoomCardMetric extends StatelessWidget {
  const _RoomCardMetric({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: const Color(0xFF64748B)),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF475569),
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _ResourceListCard extends StatelessWidget {
  final _ResourceItem item;
  final bool selected;
  final VoidCallback onTap;

  const _ResourceListCard({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected ? _teal.withValues(alpha: 0.08) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? _teal : const Color(0xFFE5E7EB),
              ),
            ),
            child: Row(
              children: [
                _ResourceAvatar(item: item, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: const TextStyle(
                          color: _ink,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.subtitle,
                        style: const TextStyle(color: _muted, fontSize: 12),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        item.detail,
                        style: const TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusDot(active: item.active, label: item.statusText),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResourceAvatar extends StatelessWidget {
  final _ResourceItem item;
  final double size;
  final SelectedImage? preview;

  const _ResourceAvatar({required this.item, required this.size, this.preview});

  @override
  Widget build(BuildContext context) {
    final imageUrl = _asString(item.raw['imageUrl']).trim();
    final hasImage = preview != null || imageUrl.isNotEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: Container(
        width: size,
        height: size,
        color: hasImage ? Colors.transparent : item.color,
        alignment: Alignment.center,
        child: preview != null
            ? Image.memory(
                preview!.bytes,
                width: size,
                height: size,
                fit: BoxFit.cover,
              )
            : imageUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: imageUrl,
                width: size,
                height: size,
                fit: BoxFit.cover,
                placeholder: (_, _) => _ResourceInitial(item: item),
                errorWidget: (_, _, _) => _ResourceInitial(item: item),
              )
            : _ResourceInitial(item: item),
      ),
    );
  }
}

class _ResourceInitial extends StatelessWidget {
  final _ResourceItem item;

  const _ResourceInitial({required this.item});

  @override
  Widget build(BuildContext context) {
    return Text(
      _initials(item.name),
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
    );
  }
}

class _ResourcePhoneDetail extends StatelessWidget {
  final String title;
  final _ResourceItem item;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool canDelete;

  const _ResourcePhoneDetail({
    required this.title,
    required this.item,
    required this.onEdit,
    required this.onDelete,
    required this.canDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _page,
      body: SafeArea(
        child: Column(
          children: [
            _ManagementHeader(
              title: item.name,
              subtitle: title,
              action: _CircleIconButton(
                icon: Icons.edit_outlined,
                tooltip: 'Edit',
                onPressed: onEdit,
              ),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.all(
                  MediaQuery.of(context).size.width < 360 ? 12 : 16,
                ),
                child: _ResourceDetailCard(
                  item: item,
                  title: title,
                  onEdit: onEdit,
                  onDelete: onDelete,
                  showInlineEdit: false,
                  canDelete: canDelete,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResourceDetailCard extends StatelessWidget {
  final _ResourceItem item;
  final String title;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool showInlineEdit;
  final bool canDelete;

  const _ResourceDetailCard({
    required this.item,
    required this.title,
    required this.onEdit,
    required this.onDelete,
    this.showInlineEdit = true,
    this.canDelete = true,
  });

  @override
  Widget build(BuildContext context) {
    final isService = title == 'Services';
    if (!isService) return _buildRoomReadOnly();
    return ListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _ResourceAvatar(item: item, size: 60),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.name,
                          style: const TextStyle(
                            fontSize: 20,
                            color: _ink,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.subtitle,
                          style: const TextStyle(color: _muted),
                        ),
                      ],
                    ),
                  ),
                  if (showInlineEdit) ...[
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Edit'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _teal,
                        side: const BorderSide(color: _teal),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const Divider(height: 30),
              if (isService) ...[
                _InfoRow('Category', item.subtitle),
                _InfoRow(
                  'Duration',
                  '${_asInt(item.raw['duration'], 60)} minutes',
                ),
                _InfoRow(
                  'Price',
                  'RM ${_asDouble(item.raw['price']).toStringAsFixed(2)}',
                ),
                _InfoRow(
                  'Therapist Commission',
                  'RM ${_asDouble(item.raw['therapistCommission']).toStringAsFixed(2)}',
                ),
                _InfoRow(
                  'Counter Commission',
                  'RM ${_asDouble(item.raw['counterCommission']).toStringAsFixed(2)}',
                ),
                _InfoRow(
                  'Room Type',
                  _roomTypeLabel(_asString(item.raw['roomType'])),
                ),
                _InfoRow('Status', item.statusText, isLast: true),
              ] else ...[
                _InfoRow('Room Type', item.subtitle),
                _InfoRow('Floor', _asString(item.raw['floor'], 'Main Floor')),
                _InfoRow(
                  'Capacity',
                  '${_asInt(item.raw['totalSlots'], 1)} slot(s)',
                ),
                _InfoRow(
                  'Equipment',
                  _asString(item.raw['equipment'], 'Not specified'),
                ),
                _InfoRow('Status', item.statusText, isLast: true),
              ],
            ],
          ),
        ),
        if (canDelete) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: Text('Remove ${isService ? 'Service' : 'Room'}'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFE53935),
              side: const BorderSide(color: Color(0xFFE53935)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRoomReadOnly() {
    final totalSlots = _asInt(item.raw['totalSlots'], 1);
    final busySlots = _asInt(item.raw['currentBusySlots']);
    final freeSlots = (totalSlots - busySlots).clamp(0, totalSlots);
    final statusLabel = !item.active
        ? 'Inactive'
        : busySlots == 0
        ? 'Available'
        : 'Occupied';
    final statusColor = !item.active
        ? const Color(0xFF64748B)
        : busySlots == 0
        ? const Color(0xFF059669)
        : const Color(0xFFD97706);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Panel(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.meeting_room_outlined,
                  color: Color(0xFF8B5CF6),
                  size: 28,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      item.subtitle,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.11),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        statusLabel,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: Color(0xFF8B5CF6)),
                  SizedBox(width: 8),
                  Text(
                    'Room information',
                    style: TextStyle(
                      color: _ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _InfoRow('Room type', item.subtitle),
              _InfoRow('Floor', _asString(item.raw['floor'], 'Main Floor')),
              _InfoRow(
                'Capacity',
                '$totalSlots slot${totalSlots == 1 ? '' : 's'}',
              ),
              _InfoRow(
                'Available now',
                '$freeSlots of $totalSlots slots',
                isLast: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.handyman_outlined,
                    size: 18,
                    color: Color(0xFF8B5CF6),
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Equipment and setup',
                    style: TextStyle(
                      color: _ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _asString(item.raw['equipment'], 'No equipment listed'),
                style: const TextStyle(
                  color: Color(0xFF475569),
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ResourceEditorSurface extends StatefulWidget {
  final _ResourceType type;
  final _ResourceItem? item;
  final bool isAdmin;
  final bool isFullScreen;

  const _ResourceEditorSurface({
    required this.type,
    required this.isAdmin,
    required this.isFullScreen,
    this.item,
  });

  @override
  State<_ResourceEditorSurface> createState() => _ResourceEditorSurfaceState();
}

class _ResourceEditorSurfaceState extends State<_ResourceEditorSurface> {
  final _serviceRepository = ServiceRepository();
  final _roomRepository = RoomRepository();
  final _imageUploadRepository = ImageUploadRepository();
  final _categoryTable = SupabaseTableService('service_categories');
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _category;
  late final TextEditingController _duration;
  late final TextEditingController _price;
  late final TextEditingController _bufferAfter;
  late final TextEditingController _therapistCommission;
  late final TextEditingController _counterCommission;
  late final TextEditingController _roomType;
  late final TextEditingController _floor;
  late final TextEditingController _slots;
  late final TextEditingController _equipment;
  late bool _usesSpecificRooms;
  SelectedImage? _imagePreview;
  bool _active = true;
  bool _imageRemoved = false;
  bool _saving = false;
  bool _closing = false;
  int _tab = 0;
  List<String> _categoryOptions = const ['Services', 'Packages', 'Add-ons'];

  bool get _isService => widget.type == _ResourceType.service;
  bool get _isEditing => widget.item != null;
  bool get _canEditAdminFields => widget.isAdmin;

  @override
  void initState() {
    super.initState();
    final raw = widget.item?.raw ?? {};
    _name = TextEditingController(text: _asString(raw['name']));
    _category = TextEditingController(
      text: _asString(raw['category'], 'Services'),
    );
    _duration = TextEditingController(
      text: _asInt(raw['duration'], 60).toString(),
    );
    _price = TextEditingController(
      text: _asDouble(raw['price']).toStringAsFixed(0),
    );
    _bufferAfter = TextEditingController(
      text: _asInt(raw['bufferAfterMinutes'], 0).toString(),
    );
    _therapistCommission = TextEditingController(
      text: _asDouble(raw['therapistCommission']).toStringAsFixed(0),
    );
    _counterCommission = TextEditingController(
      text: _asDouble(raw['counterCommission']).toStringAsFixed(0),
    );
    _roomType = TextEditingController(
      text: _asString(
        raw['roomType'] ?? raw['type'],
        _isService ? 'body_room' : 'body_room',
      ),
    );
    _floor = TextEditingController(text: _normalizeRoomFloor(raw['floor']));
    _slots = TextEditingController(
      text: _asInt(raw['totalSlots'], 1).toString(),
    );
    _equipment = TextEditingController(text: _asString(raw['equipment']));
    _usesSpecificRooms =
        _asString(
          raw['allocationMode'] ?? raw['allocation_mode'],
          'capacity',
        ) ==
        'specific_room';
    _active = _asBool(raw['active'] ?? raw['isActive'], true);
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    if (!_isService) return;
    try {
      final rows = await _categoryTable.list(orderBy: 'name');
      final categories = <String>{
        'Services',
        'Packages',
        'Add-ons',
        _category.text.trim(),
        ...rows
            .where((row) => _asBool(row['isActive'], true))
            .map((row) => _asString(row['name']).trim()),
      }..removeWhere((category) => category.isEmpty);
      if (!mounted) return;
      setState(() => _categoryOptions = categories.toList());
    } catch (_) {
      // Keep the built-in categories until the category table is available.
    }
  }

  Future<void> _addCategory() async {
    if (!widget.isAdmin || _saving) return;
    final controller = TextEditingController();
    final category = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add service category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Category name',
            hintText: 'Example: Wellness Programs',
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.of(dialogContext).pop(value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isNotEmpty) Navigator.of(dialogContext).pop(value);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (category == null || category.trim().isEmpty || !mounted) return;

    final normalizedName = category.trim();
    final existing = _categoryOptions.where(
      (item) => item.toLowerCase() == normalizedName.toLowerCase(),
    );
    if (existing.isNotEmpty) {
      setState(() => _category.text = existing.first);
      return;
    }

    final code = normalizedName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    try {
      await _categoryTable.create({
        'code': code,
        'name': normalizedName,
        'isActive': true,
      });
      if (!mounted) return;
      setState(() {
        _categoryOptions = [..._categoryOptions, normalizedName];
        _category.text = normalizedName;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Unable to add category: $e')));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _duration.dispose();
    _price.dispose();
    _bufferAfter.dispose();
    _therapistCommission.dispose();
    _counterCommission.dispose();
    _roomType.dispose();
    _floor.dispose();
    _slots.dispose();
    _equipment.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || _closing) return;
    if (!_isService && _tab != 0) setState(() => _tab = 0);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final roomAllocationMode =
        _normalizeRoomType(_roomType.text) == 'body_room' &&
            _usesSpecificRooms
        ? 'specific_room'
        : 'capacity';
    final data = _isService
        ? {
            'name': _name.text.trim(),
            'category': _category.text.trim().isEmpty
                ? 'Services'
                : _category.text.trim(),
            'duration': int.tryParse(_duration.text.trim()) ?? 60,
            'price': double.tryParse(_price.text.trim()) ?? 0,
            'bufferAfterMinutes': int.tryParse(_bufferAfter.text.trim()) ?? 0,
            if (_canEditAdminFields) ...{
              'therapistCommission':
                  double.tryParse(_therapistCommission.text.trim()) ?? 0,
              'counterCommission':
                  double.tryParse(_counterCommission.text.trim()) ?? 0,
              if (_imageRemoved) 'imageUrl': '',
            },
            'roomType': _normalizeRoomType(_roomType.text),
            'isActive': _active,
          }
        : {
            'name': _name.text.trim(),
            'type': _normalizeRoomType(_roomType.text),
            'roomType': _normalizeRoomType(_roomType.text),
            'floor': _normalizeRoomFloor(_floor.text),
            'totalSlots': int.tryParse(_slots.text.trim()) ?? 1,
            'equipment': _equipment.text.trim(),
            'allocationMode': roomAllocationMode,
            'isActive': _active,
          };
    try {
      Map<String, dynamic>? savedRow;
      if (_isEditing) {
        if (_isService) {
          savedRow = await _serviceRepository.updateService(
            widget.item!.id,
            data,
          );
        } else {
          await _roomRepository.updateRoom(widget.item!.id, data);
        }
      } else {
        if (_isService) {
          savedRow = await _serviceRepository.addService(data);
        } else {
          await _roomRepository.createRoom(data);
        }
      }
      if (_isService && savedRow != null && _canEditAdminFields) {
        final serviceId = _asString(savedRow['id'], widget.item?.id ?? '');
        final previousUrl = _asString(widget.item?.raw['imageUrl']);
        if (_imagePreview != null && serviceId.isNotEmpty) {
          final imageUrl = await _imageUploadRepository.uploadImage(
            image: _imagePreview!,
            folder: 'services',
            id: serviceId,
            previousUrl: previousUrl,
          );
          await _serviceRepository.updateService(serviceId, {
            'imageUrl': imageUrl,
          });
        } else if (_imageRemoved && previousUrl.trim().isNotEmpty) {
          await _imageUploadRepository.removePublicUrl(previousUrl);
        }
      }
      _close(true);
    } catch (e) {
      debugPrint('Unable to save ${_isService ? 'service' : 'room'}: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unable to save ${_isService ? 'service' : 'room'}: $e',
          ),
        ),
      );
    }
  }

  Future<void> _deleteCurrentRoom() async {
    if (_isService || !_isEditing || !widget.isAdmin || _saving || _closing) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_outline, color: Color(0xFFE53935)),
        title: const Text('Delete this room?'),
        content: Text(
          '${widget.item!.name} will be permanently removed. If it is linked to bookings, deletion may be blocked; setting it to Inactive is safer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
            ),
            child: const Text('Delete Room'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await _roomRepository.deleteRoom(widget.item!.id);
      if (!mounted) return;
      _close(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unable to delete this room. Set it to Inactive instead.\n$error',
          ),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _pickImage() async {
    if (!_canEditAdminFields) return;
    try {
      final image = await _imageUploadRepository.pickImage();
      if (image == null || !mounted) return;
      setState(() {
        _imagePreview = image;
        _imageRemoved = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _removeImage() {
    if (!_canEditAdminFields) return;
    setState(() {
      _imagePreview = null;
      _imageRemoved = true;
    });
  }

  void _close([bool? result]) {
    if (_closing || !mounted) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isService) return _legacyBuild(context);
    return Material(
      color: Colors.white,
      child: SafeArea(
        top: widget.isFullScreen,
        bottom: widget.isFullScreen,
        child: Column(
          children: [
            _RoomEditorHeader(
              editing: _isEditing,
              saving: _saving,
              active: _active,
              roomName: _name.text.trim().isEmpty ? 'Room' : _name.text.trim(),
              roomType: _roomTypeLabel(_normalizeRoomType(_roomType.text)),
              isFullScreen: widget.isFullScreen,
              onActiveChanged: (value) => setState(() => _active = value),
              onClose: () => _close(),
            ),
            _RoomEditorTabs(
              selected: _tab,
              onChanged: (value) => setState(() => _tab = value),
            ),
            Expanded(
              child: Form(
                key: _formKey,
                child: IndexedStack(
                  index: _tab,
                  children: [_buildRoomDetails(), _buildRoomEquipment()],
                ),
              ),
            ),
            _RoomEditorFooter(
              saving: _saving,
              editing: _isEditing,
              onCancel: () => _close(),
              onSave: _save,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoomDetails() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _RoomEditorSectionTitle('Basic information'),
          const SizedBox(height: 12),
          _FormField(
            label: 'Room name',
            controller: _name,
            requiredField: true,
          ),
          const SizedBox(height: 22),
          const _RoomEditorSectionTitle('Room type and capacity'),
          const SizedBox(height: 12),
          _ControllerDropdown(
            label: 'Room type',
            controller: _roomType,
            options: const ['body_room', 'foot_chair'],
            optionLabel: _roomTypeLabel,
            onChanged: (value) {
              setState(() {
                if (_normalizeRoomType(value) != 'body_room') {
                  _usesSpecificRooms = false;
                }
              });
            },
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _ControllerDropdown(
                  label: 'Floor',
                  controller: _floor,
                  options: _roomFloorOptions,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _FormField(
                  label: 'Available slots',
                  controller: _slots,
                  keyboardType: TextInputType.number,
                  requiredField: true,
                ),
              ),
            ],
          ),
          if (_normalizeRoomType(_roomType.text) == 'body_room') ...[
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: _usesSpecificRooms
                    ? const Color(0xFFEFF9F8)
                    : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _usesSpecificRooms
                      ? const Color(0xFF9FD5D1)
                      : const Color(0xFFE2E8F0),
                ),
              ),
              child: SwitchListTile.adaptive(
                value: _usesSpecificRooms,
                onChanged: (value) =>
                    setState(() => _usesSpecificRooms = value),
                activeTrackColor: const Color(0xFF1B7C80),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                title: const Text(
                  'Treat slots as specific rooms',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  _usesSpecificRooms
                      ? 'Each slot becomes Room 1, Room 2, and so on, and one room is assigned to every booking.'
                      : 'Slots are shared capacity only; bookings are not assigned an individual room.',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 18, color: Color(0xFF64748B)),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Slots control how many bookings this room can handle at the same time.',
                    style: TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_isEditing && widget.isAdmin) ...[
            const SizedBox(height: 28),
            const Divider(),
            const SizedBox(height: 14),
            const _RoomEditorSectionTitle('Danger zone'),
            const SizedBox(height: 6),
            const Text(
              'Use Inactive if this room may be needed again. Delete is permanent.',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _saving ? null : _deleteCurrentRoom,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete Room'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFE53935),
                side: const BorderSide(color: Color(0xFFE53935)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRoomEquipment() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _RoomEditorSectionTitle('Equipment and setup'),
          const SizedBox(height: 6),
          const Text(
            'Record the fixed equipment or special setup staff should expect in this room.',
            style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
          ),
          const SizedBox(height: 16),
          _FormField(
            label: 'Equipment',
            controller: _equipment,
            maxLines: 6,
            hint: 'Example: massage bed, hot stone heater, sink',
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F3FF),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFDDD6FE)),
            ),
            child: const Text(
              'Keep this concise so staff can scan it quickly while assigning rooms.',
              style: TextStyle(
                color: Color(0xFF6D28D9),
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legacyBuild(BuildContext context) {
    final label = _isService ? 'Service' : 'Room';
    final imageItem = _ResourceItem(
      id: widget.item?.id ?? '',
      name: _name.text.trim().isEmpty ? label : _name.text.trim(),
      subtitle: '',
      detail: '',
      statusText: '',
      active: true,
      color: _teal,
      raw: {
        'imageUrl': _imageRemoved
            ? ''
            : _asString(widget.item?.raw['imageUrl']),
      },
    );
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _isEditing ? 'Edit $label' : 'Add $label',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: _ink,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _saving ? null : () => _close(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_isService) ...[
                  Row(
                    children: [
                      _ResourceAvatar(
                        item: imageItem,
                        size: 72,
                        preview: _imagePreview,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _saving || !_canEditAdminFields
                                  ? null
                                  : _pickImage,
                              icon: const Icon(Icons.upload_outlined),
                              label: Text(
                                _imagePreview == null &&
                                        _asString(
                                          widget.item?.raw['imageUrl'],
                                        ).trim().isEmpty
                                    ? 'Upload Image'
                                    : 'Replace Image',
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed:
                                  !_saving &&
                                      _canEditAdminFields &&
                                      !_imageRemoved &&
                                      (_imagePreview != null ||
                                          _asString(
                                            widget.item?.raw['imageUrl'],
                                          ).trim().isNotEmpty)
                                  ? _removeImage
                                  : null,
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('Remove Image'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                _FormField(
                  label: 'Name',
                  controller: _name,
                  requiredField: true,
                ),
                const SizedBox(height: 12),
                if (_isService) ...[
                  _ControllerDropdown(
                    label: 'Category',
                    controller: _category,
                    options: _categoryOptions,
                  ),
                  if (_canEditAdminFields)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _saving ? null : _addCategory,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add category'),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _FormField(
                          label: 'Duration',
                          controller: _duration,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _FormField(
                          label: 'Price',
                          controller: _price,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _FormField(
                          label: 'Cleanup buffer',
                          controller: _bufferAfter,
                          hint: 'Minutes after service',
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _FormField(
                          label: 'Therapist Commission',
                          controller: _therapistCommission,
                          hint: 'RM per service',
                          keyboardType: TextInputType.number,
                          enabled: _canEditAdminFields,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _FormField(
                          label: 'Counter Commission',
                          controller: _counterCommission,
                          hint: 'RM per service',
                          keyboardType: TextInputType.number,
                          enabled: _canEditAdminFields,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _ControllerDropdown(
                    label: 'Room Type',
                    controller: _roomType,
                    options: const ['body_room', 'foot_chair'],
                    optionLabel: _roomTypeLabel,
                  ),
                ] else ...[
                  _ControllerDropdown(
                    label: 'Room Type',
                    controller: _roomType,
                    options: const ['body_room', 'foot_chair'],
                    optionLabel: _roomTypeLabel,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _ControllerDropdown(
                          label: 'Floor',
                          controller: _floor,
                          options: _roomFloorOptions,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _FormField(
                          label: 'Slots',
                          controller: _slots,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _FormField(
                    label: 'Equipment',
                    controller: _equipment,
                    maxLines: 3,
                  ),
                ],
                const SizedBox(height: 12),
                SwitchListTile(
                  value: _active,
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _active = value),
                  activeThumbColor: Colors.white,
                  activeTrackColor: const Color(0xFF10B981),
                  contentPadding: EdgeInsets.zero,
                  title: Text(_isService ? 'Active' : 'Available'),
                ),
                const SizedBox(height: 20),
                _DialogActions(
                  saving: _saving,
                  saveLabel: _isEditing ? 'Save Changes' : 'Add $label',
                  onCancel: () => _close(),
                  onSave: _save,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoomEditorHeader extends StatelessWidget {
  const _RoomEditorHeader({
    required this.editing,
    required this.saving,
    required this.active,
    required this.roomName,
    required this.roomType,
    required this.isFullScreen,
    required this.onActiveChanged,
    required this.onClose,
  });

  final bool editing;
  final bool saving;
  final bool active;
  final String roomName;
  final String roomType;
  final bool isFullScreen;
  final ValueChanged<bool> onActiveChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE4E7EC))),
      ),
      child: Row(
        children: [
          if (isFullScreen) ...[
            IconButton(
              tooltip: 'Back',
              onPressed: saving ? null : onClose,
              icon: const Icon(Icons.arrow_back),
            ),
            const SizedBox(width: 2),
          ],
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF8B5CF6).withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.meeting_room_outlined,
              color: Color(0xFF8B5CF6),
              size: 24,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  editing ? 'Edit Room' : 'Add Room',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  roomName == 'Room' ? roomType : '$roomName · $roomType',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Text(
            active ? 'Active' : 'Inactive',
            style: TextStyle(
              color: active ? const Color(0xFF047857) : const Color(0xFF64748B),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          Transform.scale(
            scale: 0.82,
            child: Switch(
              value: active,
              onChanged: saving ? null : onActiveChanged,
              activeTrackColor: const Color(0xFF10B981),
            ),
          ),
          if (!isFullScreen)
            IconButton(
              tooltip: 'Close',
              onPressed: saving ? null : onClose,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }
}

class _RoomEditorTabs extends StatelessWidget {
  const _RoomEditorTabs({required this.selected, required this.onChanged});

  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE4E7EC))),
      ),
      child: Row(
        children: [
          _RoomEditorTab(
            label: 'Details',
            selected: selected == 0,
            onTap: () => onChanged(0),
          ),
          _RoomEditorTab(
            label: 'Equipment',
            selected: selected == 1,
            onTap: () => onChanged(1),
          ),
        ],
      ),
    );
  }
}

class _RoomEditorTab extends StatelessWidget {
  const _RoomEditorTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    color: selected
                        ? const Color(0xFF1B6B72)
                        : const Color(0xFF64748B),
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            Container(
              height: 2,
              color: selected ? const Color(0xFF1B6B72) : Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomEditorFooter extends StatelessWidget {
  const _RoomEditorFooter({
    required this.saving,
    required this.editing,
    required this.onCancel,
    required this.onSave,
  });

  final bool saving;
  final bool editing;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE4E7EC))),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: saving ? null : onCancel,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: saving ? null : onSave,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                backgroundColor: const Color(0xFF1B6B72),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(editing ? 'Save Changes' : 'Add Room'),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoomEditorSectionTitle extends StatelessWidget {
  const _RoomEditorSectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: Color(0xFF344054),
        fontSize: 12,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _ManagedTherapist {
  final String id;
  final String name;
  final String phone;
  final String role;
  final bool available;
  final bool onLeave;
  final String busyUntil;
  final int doneToday;
  final Map<String, dynamic> raw;

  const _ManagedTherapist({
    required this.id,
    required this.name,
    required this.phone,
    required this.role,
    required this.available,
    this.onLeave = false,
    required this.busyUntil,
    required this.doneToday,
    required this.raw,
  });

  factory _ManagedTherapist.fromMap(Map<String, dynamic> d) {
    return _ManagedTherapist(
      id: _asString(d['id']),
      name: _asString(d['name']),
      phone: _asString(d['phone']),
      role: _normalizeStaffRole(
        d['role'] ?? d['staffRole'] ?? d['employmentType'],
      ),
      available: _asBool(d['availabilityStatus'], true),
      busyUntil: _asString(d['busyUntil']),
      doneToday: 0,
      raw: d,
    );
  }

  _ManagedTherapist copyWith({
    bool? available,
    bool? onLeave,
    String? busyUntil,
    int? doneToday,
  }) {
    return _ManagedTherapist(
      id: id,
      name: name,
      phone: phone,
      role: role,
      available: available ?? this.available,
      onLeave: onLeave ?? this.onLeave,
      busyUntil: busyUntil ?? this.busyUntil,
      doneToday: doneToday ?? this.doneToday,
      raw: raw,
    );
  }
}

class TherapistAvailabilityScreen extends StatefulWidget {
  const TherapistAvailabilityScreen({super.key});

  @override
  State<TherapistAvailabilityScreen> createState() =>
      _TherapistAvailabilityScreenState();
}

class _TherapistAvailabilityScreenState
    extends State<TherapistAvailabilityScreen> {
  final _appointmentRepository = AppointmentRepository();
  final _therapistRepository = TherapistRepository();
  final _unavailabilityTable = SupabaseTableService('therapist_unavailability');
  final _searchController = TextEditingController();
  List<_ManagedTherapist> _therapists = [];
  List<_ManagedTherapist> _filtered = [];
  _ManagedTherapist? _selected;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _searchController.addListener(_filter);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _therapistRepository.getTherapists(),
        _unavailabilityTable.list(orderBy: 'starts_at'),
      ]);
      final rows = results[0];
      final leaveRows = results[1];
      final loaded = await Future.wait(
        rows.map(
          (row) async => _enrich(_ManagedTherapist.fromMap(row), leaveRows),
        ),
      );
      if (!mounted) return;
      setState(() {
        _therapists = loaded;
        _filtered = loaded;
        _selected = loaded.isEmpty
            ? null
            : loaded.firstWhere(
                (item) => item.id == _selected?.id,
                orElse: () => loaded.first,
              );
        _loading = false;
      });
      _filter();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<_ManagedTherapist> _enrich(
    _ManagedTherapist therapist,
    List<Map<String, dynamic>> leaveRows,
  ) async {
    final today = _today();
    final appointments = await _appointmentRepository
        .getAppointmentsByTherapist(
          therapist.id,
          date: DateTime.tryParse(today),
        );

    var done = 0;
    var busyUntil = '';
    final now = TimeOfDay.now();
    final nowMinutes = now.hour * 60 + now.minute;

    for (final d in appointments) {
      final status = _asString(d['status']).toLowerCase();
      if (status == 'completed') {
        final items = d['serviceItems'] ?? d['service_items'];
        done += items is List && items.isNotEmpty ? items.length : 1;
      }
      if (_isPendingAppointmentStatus(status)) {
        final start = _timeToMinutes(_asString(d['startTime'], '00:00'));
        final end =
            _timeToMinutes(_asString(d['endTime'], '00:00')) +
            _asInt(d['bufferAfterMinutes']);
        if (start <= nowMinutes && end > nowMinutes) {
          busyUntil = _minutesToClock(end);
        }
      }
    }

    final current = DateTime.now().toUtc();
    final onLeave = leaveRows.any((row) {
      if (_asString(row['therapistId'] ?? row['therapist_id']) !=
          therapist.id) {
        return false;
      }
      final starts = DateTime.tryParse(
        _asString(row['startsAt'] ?? row['starts_at']),
      );
      final ends = DateTime.tryParse(
        _asString(row['endsAt'] ?? row['ends_at']),
      );
      return starts != null &&
          ends != null &&
          starts.isBefore(current) &&
          ends.isAfter(current);
    });
    return therapist.copyWith(
      doneToday: done,
      busyUntil: busyUntil,
      onLeave: onLeave,
    );
  }

  void _filter() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      _filtered = _therapists.where((therapist) {
        return therapist.name.toLowerCase().contains(query) ||
            therapist.phone.toLowerCase().contains(query) ||
            therapist.role.toLowerCase().contains(query);
      }).toList();
      if (_filtered.isNotEmpty &&
          !_filtered.any((item) => item.id == _selected?.id)) {
        _selected = _filtered.first;
      }
    });
  }

  Future<void> _setAvailability(_ManagedTherapist therapist, bool value) async {
    if (therapist.onLeave) return;
    await _therapistRepository.updateTherapist(therapist.id, {
      'availabilityStatus': value,
    });
    setState(() {
      _therapists = _therapists
          .map(
            (item) => item.id == therapist.id
                ? item.copyWith(available: value)
                : item,
          )
          .toList();
      if (_selected?.id == therapist.id) {
        _selected = _selected!.copyWith(available: value);
      }
    });
    _filter();
  }

  Future<void> _openForm({_ManagedTherapist? therapist}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _TherapistFormDialog(therapist: therapist),
    );
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 900;
    final horizontalPadding = MediaQuery.of(context).size.width < 360
        ? 12.0
        : 16.0;

    return Scaffold(
      backgroundColor: _page,
      body: SafeArea(
        child: Column(
          children: [
            _ManagementHeader(
              title: 'Staff',
              subtitle: 'Manage staff roles, availability, and daily activity',
            ),
            Expanded(
              child: isWide
                  ? Row(
                      children: [
                        SizedBox(
                          width: 304,
                          child: _staffListPane(
                            horizontalPadding: 14,
                            listPadding: 10,
                            paneColor: Colors.white,
                          ),
                        ),
                        Expanded(
                          child: _selected == null
                              ? const _StaffScheduleEmptyState()
                              : _StaffScheduleDetail(
                                  key: ValueKey(_selected!.id),
                                  therapist: _selected!,
                                  onChanged: _load,
                                  onEdit: () => _openForm(therapist: _selected),
                                  onAvailabilityChanged: (value) =>
                                      _setAvailability(_selected!, value),
                                ),
                        ),
                      ],
                    )
                  : _staffListPane(
                      horizontalPadding: horizontalPadding,
                      listPadding: horizontalPadding,
                      paneColor: _page,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _staffListPane({
    required double horizontalPadding,
    required double listPadding,
    required Color paneColor,
  }) {
    return Container(
      color: paneColor,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              14,
              horizontalPadding,
              14,
            ),
            child: _SearchBar(
              controller: _searchController,
              hint: 'Search staff...',
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _teal))
                : RefreshIndicator(
                    onRefresh: _load,
                    color: _teal,
                    child: ListView.builder(
                      padding: EdgeInsets.fromLTRB(
                        listPadding,
                        0,
                        listPadding,
                        20,
                      ),
                      itemCount: _filtered.length,
                      itemBuilder: (_, index) {
                        final therapist = _filtered[index];
                        return _TherapistAvailabilityCard(
                          therapist: therapist,
                          selected: therapist.id == _selected?.id,
                          onTap: () {
                            if (MediaQuery.of(context).size.width >= 900) {
                              setState(() => _selected = therapist);
                              return;
                            }
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => _StaffSchedulePage(
                                  therapist: therapist,
                                  onChanged: _load,
                                  onEdit: () => _openForm(therapist: therapist),
                                  onAvailabilityChanged: (value) =>
                                      _setAvailability(therapist, value),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _StaffScheduleEmptyState extends StatelessWidget {
  const _StaffScheduleEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Select a therapist to manage working hours and leave.',
        style: TextStyle(color: _muted),
      ),
    );
  }
}

class _StaffSchedulePage extends StatelessWidget {
  final _ManagedTherapist therapist;
  final Future<void> Function() onChanged;
  final VoidCallback onEdit;
  final ValueChanged<bool> onAvailabilityChanged;

  const _StaffSchedulePage({
    required this.therapist,
    required this.onChanged,
    required this.onEdit,
    required this.onAvailabilityChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _page,
      appBar: AppBar(
        title: Text(therapist.name),
        backgroundColor: Colors.white,
        foregroundColor: _ink,
        elevation: 0,
      ),
      body: _StaffScheduleDetail(
        therapist: therapist,
        onChanged: onChanged,
        onEdit: onEdit,
        onAvailabilityChanged: onAvailabilityChanged,
      ),
    );
  }
}

class _StaffScheduleDetail extends StatefulWidget {
  final _ManagedTherapist therapist;
  final Future<void> Function() onChanged;
  final VoidCallback onEdit;
  final ValueChanged<bool> onAvailabilityChanged;

  const _StaffScheduleDetail({
    super.key,
    required this.therapist,
    required this.onChanged,
    required this.onEdit,
    required this.onAvailabilityChanged,
  });

  @override
  State<_StaffScheduleDetail> createState() => _StaffScheduleDetailState();
}

class _StaffScheduleDetailState extends State<_StaffScheduleDetail> {
  static const _days = [
    'Sunday',
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
  ];

  final _hoursTable = SupabaseTableService('therapist_working_hours');
  final _leaveTable = SupabaseTableService('therapist_unavailability');
  final _businessHoursTable = SupabaseTableService('business_hours');
  List<Map<String, dynamic>> _hours = [];
  List<Map<String, dynamic>> _leaves = [];
  List<Map<String, dynamic>> _businessHours = [];
  bool? _availableOverride;
  bool _savingLeave = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _hoursTable.findBy(
          'therapist_id',
          widget.therapist.id,
          orderBy: 'day_of_week',
        ),
        _leaveTable.findBy(
          'therapist_id',
          widget.therapist.id,
          orderBy: 'starts_at',
        ),
        _businessHoursTable.list(orderBy: 'day_of_week'),
      ]);
      final settings = results[2];
      if (!mounted) return;
      setState(() {
        _hours = results[0];
        _leaves = results[1];
        _businessHours = settings;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage('Unable to load this schedule.');
    }
  }

  String _shortTime(Object? value, String fallback) {
    final text = _asString(value, fallback);
    return text.length >= 5 ? text.substring(0, 5) : fallback;
  }

  Map<String, dynamic>? _hoursFor(int day) {
    for (final row in _hours) {
      if (_asInt(row['dayOfWeek'] ?? row['day_of_week'], -1) == day) return row;
    }
    return null;
  }

  Map<String, dynamic>? _businessHoursFor(int day) {
    for (final row in _businessHours) {
      if (_asInt(row['dayOfWeek'] ?? row['day_of_week'], -1) == day) {
        return row;
      }
    }
    return null;
  }

  bool _businessClosed(int day) {
    final row = _businessHoursFor(day);
    return row?['isClosed'] == true || row?['is_closed'] == true;
  }

  String _businessOpen(int day) => _shortTime(
    _businessHoursFor(day)?['openTime'] ?? _businessHoursFor(day)?['open_time'],
    '09:00',
  );

  String _businessClose(int day) => _shortTime(
    _businessHoursFor(day)?['closeTime'] ??
        _businessHoursFor(day)?['close_time'],
    '21:00',
  );

  TimeOfDay _parseTime(String value) {
    final parts = value.split(':');
    return TimeOfDay(
      hour: parts.isNotEmpty ? int.tryParse(parts[0]) ?? 9 : 9,
      minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
    );
  }

  String _storageTime(TimeOfDay time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  String _displayTime(BuildContext context, String value) =>
      _parseTime(value).format(context);

  Future<void> _editDay(int day) async {
    if (_businessClosed(day)) {
      _showMessage(
        'The outlet is closed on ${_days[day]}. Reopen it in Business Settings first.',
      );
      return;
    }
    final row = _hoursFor(day);
    var start = _parseTime(
      _shortTime(row?['startTime'] ?? row?['start_time'], _businessOpen(day)),
    );
    var end = _parseTime(
      _shortTime(row?['endTime'] ?? row?['end_time'], _businessClose(day)),
    );
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('${_days[day]} working hours'),
          content: Row(
            children: [
              Expanded(
                child: _CompactTimeButton(
                  label: 'Starts',
                  value: start.format(context),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: start,
                    );
                    if (picked != null) setDialogState(() => start = picked);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _CompactTimeButton(
                  label: 'Ends',
                  value: end.format(context),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: end,
                    );
                    if (picked != null) setDialogState(() => end = picked);
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'inherit'),
              child: const Text('Use business hours'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'custom'),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (action == 'inherit') {
      start = _parseTime(_businessOpen(day));
      end = _parseTime(_businessClose(day));
    }
    final startMinutes = start.hour * 60 + start.minute;
    final endMinutes = end.hour * 60 + end.minute;
    if (startMinutes == endMinutes) {
      _showMessage('Start and end time must be different.');
      return;
    }
    final existing = _hours.where(
      (item) => _asInt(item['dayOfWeek'] ?? item['day_of_week'], -1) == day,
    );
    for (final item in existing) {
      await _hoursTable.delete(_asString(item['id']));
    }
    await _hoursTable.create({
      'therapistId': widget.therapist.id,
      'dayOfWeek': day,
      'startTime': _storageTime(start),
      'endTime': _storageTime(end),
      'isCustom': action == 'custom',
    });
    await _load();
    await widget.onChanged();
  }

  Future<void> _addLeave() async {
    if (_savingLeave) return;
    final now = DateTime.now();
    final range = await showDialog<DateTimeRange>(
      context: context,
      builder: (_) => _LeaveDateRangeDialog(
        firstDate: DateTime(now.year, now.month, now.day),
        lastDate: DateTime(now.year + 2, 12, 31),
      ),
    );
    if (range == null) return;
    if (!mounted) return;
    final starts = DateTime(
      range.start.year,
      range.start.month,
      range.start.day,
    );
    final ends = DateTime(
      range.end.year,
      range.end.month,
      range.end.day,
    ).add(const Duration(days: 1));
    setState(() => _savingLeave = true);
    try {
      await _leaveTable.create({
        'therapistId': widget.therapist.id,
        'startsAt': starts.toUtc().toIso8601String(),
        'endsAt': ends.toUtc().toIso8601String(),
        'internalReason': 'Leave',
      });
      await _load();
      await widget.onChanged();
      _showMessage('Leave saved successfully.');
    } catch (error) {
      _showMessage('Could not save leave: $error');
    } finally {
      if (mounted) setState(() => _savingLeave = false);
    }
  }

  Future<void> _deleteLeave(Map<String, dynamic> row) async {
    await _leaveTable.delete(_asString(row['id']));
    await _load();
    await widget.onChanged();
  }

  DateTime? _leaveDate(Map<String, dynamic> row, String camel, String snake) {
    return DateTime.tryParse(_asString(row[camel] ?? row[snake]))?.toLocal();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _changeAvailability(bool value) {
    setState(() => _availableOverride = value);
    widget.onAvailabilityChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _teal));
    }
    final isBusy = widget.therapist.busyUntil.isNotEmpty;
    final effectivelyAvailable =
        (_availableOverride ?? widget.therapist.available) &&
        !widget.therapist.onLeave &&
        !isBusy;
    final statusColor = widget.therapist.onLeave
        ? const Color(0xFFD97706)
        : isBusy
        ? const Color(0xFFDC6B19)
        : effectivelyAvailable
        ? const Color(0xFF10B981)
        : const Color(0xFF94A3B8);
    final statusLabel = widget.therapist.onLeave
        ? 'On Leave'
        : isBusy
        ? 'Busy until ${_friendlyTime(widget.therapist.busyUntil)}'
        : effectivelyAvailable
        ? 'Available'
        : 'Unavailable';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StaffProfileBanner(
                therapist: widget.therapist,
                statusColor: statusColor,
                statusLabel: statusLabel,
                effectivelyAvailable: effectivelyAvailable,
                onAvailabilityChanged: widget.therapist.onLeave || isBusy
                    ? null
                    : _changeAvailability,
                onEdit: widget.onEdit,
              ),
              const SizedBox(height: 12),
              _StaffSection(
                icon: Icons.calendar_month_outlined,
                title: 'Weekly Schedule',
                subtitle: 'Set this therapist’s regular working hours.',
                child: Column(
                  children: [
                    const _ScheduleTableHeader(),
                    ...List.generate(7, (day) {
                      final row = _hoursFor(day);
                      final closed = _businessClosed(day);
                      final start = _shortTime(
                        row?['startTime'] ?? row?['start_time'],
                        _businessOpen(day),
                      );
                      final end = _shortTime(
                        row?['endTime'] ?? row?['end_time'],
                        _businessClose(day),
                      );
                      return _ScheduleDayCard(
                        day: _days[day],
                        time: closed
                            ? 'Outlet closed'
                            : '${_displayTime(context, start)} – ${_displayTime(context, end)}',
                        onEdit: () => _editDay(day),
                        isLast: day == 6,
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _StaffSection(
                icon: Icons.beach_access_outlined,
                title: 'Leave',
                subtitle:
                    'Planned leave automatically blocks availability and bookings.',
                action: FilledButton.icon(
                  onPressed: _savingLeave ? null : _addLeave,
                  icon: _savingLeave
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.add, size: 17),
                  label: Text(_savingLeave ? 'Saving...' : 'Add Leave'),
                  style: FilledButton.styleFrom(
                    backgroundColor: _teal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                child: _leaves.isEmpty
                    ? const _EmptyLeaveCard()
                    : Column(
                        children: _leaves.reversed.map((row) {
                          final start = _leaveDate(
                            row,
                            'startsAt',
                            'starts_at',
                          );
                          final endExclusive = _leaveDate(
                            row,
                            'endsAt',
                            'ends_at',
                          );
                          final end = endExclusive?.subtract(
                            const Duration(days: 1),
                          );
                          return _LeaveRow(
                            dates: start == null || end == null
                                ? 'Leave dates unavailable'
                                : '${DateFormat('d MMM yyyy').format(start)} – ${DateFormat('d MMM yyyy').format(end)}',
                            reason: _asString(
                              row['internalReason'] ?? row['internal_reason'],
                              'Leave',
                            ),
                            onDelete: () => _deleteLeave(row),
                          );
                        }).toList(),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StaffProfileBanner extends StatelessWidget {
  final _ManagedTherapist therapist;
  final Color statusColor;
  final String statusLabel;
  final bool effectivelyAvailable;
  final ValueChanged<bool>? onAvailabilityChanged;
  final VoidCallback onEdit;

  const _StaffProfileBanner({
    required this.therapist,
    required this.statusColor,
    required this.statusLabel,
    required this.effectivelyAvailable,
    required this.onAvailabilityChanged,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          return Row(
            children: [
              CircleAvatar(
                radius: compact ? 27 : 34,
                backgroundColor: _avatarColor(therapist.name),
                child: Text(
                  _initials(therapist.name),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 20 : 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      therapist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 20 : 24,
                        fontWeight: FontWeight.w800,
                        color: _ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      therapist.role,
                      style: const TextStyle(
                        color: _teal,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          statusLabel,
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 25,
                          child: Transform.scale(
                            scale: 0.72,
                            child: Switch(
                              value: effectivelyAvailable,
                              onChanged: onAvailabilityChanged,
                              activeThumbColor: Colors.white,
                              activeTrackColor: _teal,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!compact)
                OutlinedButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: const Text('Edit Profile'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _teal,
                    side: const BorderSide(color: Color(0xFFCBD5E1)),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                  ),
                )
              else
                IconButton(
                  onPressed: onEdit,
                  tooltip: 'Edit profile',
                  icon: const Icon(Icons.edit_outlined, color: _teal),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _StaffSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? action;

  const _StaffSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 13),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5F5),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 18, color: _teal),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                if (action != null) ...[const SizedBox(width: 10), action!],
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          Padding(padding: const EdgeInsets.all(14), child: child),
        ],
      ),
    );
  }
}

class _ScheduleTableHeader extends StatelessWidget {
  const _ScheduleTableHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      child: const Row(
        children: [
          Expanded(flex: 3, child: Text('Day', style: _scheduleHeaderStyle)),
          Expanded(
            flex: 4,
            child: Text('Working Hours', style: _scheduleHeaderStyle),
          ),
          SizedBox(width: 42, child: Text('Edit', style: _scheduleHeaderStyle)),
        ],
      ),
    );
  }
}

const _scheduleHeaderStyle = TextStyle(
  color: Color(0xFF64748B),
  fontSize: 11,
  fontWeight: FontWeight.w700,
);

class _ScheduleDayCard extends StatelessWidget {
  final String day;
  final String time;
  final VoidCallback onEdit;
  final bool isLast;
  const _ScheduleDayCard({
    required this.day,
    required this.time,
    required this.onEdit,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    decoration: BoxDecoration(
      border: isLast
          ? null
          : const Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
    ),
    child: Row(
      children: [
        Expanded(
          flex: 3,
          child: Text(
            day,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              color: _ink,
            ),
          ),
        ),
        Expanded(
          flex: 4,
          child: Text(
            time,
            style: const TextStyle(fontSize: 12, color: _muted),
          ),
        ),
        SizedBox(
          width: 42,
          height: 34,
          child: IconButton(
            onPressed: onEdit,
            tooltip: 'Edit $day',
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.edit_outlined, size: 17, color: _teal),
          ),
        ),
      ],
    ),
  );
}

class _LeaveDateRangeDialog extends StatefulWidget {
  final DateTime firstDate;
  final DateTime lastDate;

  const _LeaveDateRangeDialog({
    required this.firstDate,
    required this.lastDate,
  });

  @override
  State<_LeaveDateRangeDialog> createState() => _LeaveDateRangeDialogState();
}

class _LeaveDateRangeDialogState extends State<_LeaveDateRangeDialog> {
  late DateTime _visibleMonth;
  DateTime? _start;
  DateTime? _end;

  @override
  void initState() {
    super.initState();
    _visibleMonth = DateTime(widget.firstDate.year, widget.firstDate.month);
  }

  DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  bool _sameDate(DateTime? first, DateTime second) =>
      first != null &&
      first.year == second.year &&
      first.month == second.month &&
      first.day == second.day;

  bool _isSelectable(DateTime day) {
    final clean = _dateOnly(day);
    return !clean.isBefore(_dateOnly(widget.firstDate)) &&
        !clean.isAfter(_dateOnly(widget.lastDate));
  }

  void _select(DateTime day) {
    if (!_isSelectable(day)) return;
    final clean = _dateOnly(day);
    setState(() {
      if (_start == null || _end != null) {
        _start = clean;
        _end = null;
      } else if (clean.isBefore(_start!)) {
        _start = clean;
      } else {
        _end = clean;
      }
    });
  }

  void _moveMonth(int offset) {
    final next = DateTime(_visibleMonth.year, _visibleMonth.month + offset);
    final earliest = DateTime(widget.firstDate.year, widget.firstDate.month);
    final latest = DateTime(widget.lastDate.year, widget.lastDate.month);
    if (next.isBefore(earliest) || next.isAfter(latest)) return;
    setState(() => _visibleMonth = next);
  }

  bool get _canMoveBack {
    final earliest = DateTime(widget.firstDate.year, widget.firstDate.month);
    return _visibleMonth.isAfter(earliest);
  }

  bool get _canMoveForward {
    final latest = DateTime(widget.lastDate.year, widget.lastDate.month);
    return _visibleMonth.isBefore(latest);
  }

  String get _rangeLabel {
    if (_start == null) return 'Choose a start date';
    if (_end == null) {
      return '${DateFormat('d MMM yyyy').format(_start!)} – choose end date';
    }
    return '${DateFormat('d MMM yyyy').format(_start!)} – ${DateFormat('d MMM yyyy').format(_end!)}';
  }

  @override
  Widget build(BuildContext context) {
    final firstDay = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    final gridStart = firstDay.subtract(Duration(days: firstDay.weekday % 7));
    final days = List.generate(
      42,
      (index) => gridStart.add(Duration(days: index)),
    );

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 390),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
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
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.event_available_outlined,
                      color: _teal,
                      size: 19,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Select leave dates',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 8, bottom: 13),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _rangeLabel,
                  style: TextStyle(
                    color: _start == null ? _muted : _teal,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      DateFormat('MMMM yyyy').format(_visibleMonth),
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _canMoveBack ? () => _moveMonth(-1) : null,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  IconButton(
                    onPressed: _canMoveForward ? () => _moveMonth(1) : null,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Row(
                children: [
                  _LeaveWeekdayLabel('SUN'),
                  _LeaveWeekdayLabel('MON'),
                  _LeaveWeekdayLabel('TUE'),
                  _LeaveWeekdayLabel('WED'),
                  _LeaveWeekdayLabel('THU'),
                  _LeaveWeekdayLabel('FRI'),
                  _LeaveWeekdayLabel('SAT'),
                ],
              ),
              const SizedBox(height: 7),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisSpacing: 5,
                  crossAxisSpacing: 3,
                ),
                itemCount: days.length,
                itemBuilder: (context, index) {
                  final day = _dateOnly(days[index]);
                  final selectable = _isSelectable(day);
                  final inMonth = day.month == _visibleMonth.month;
                  final isStart = _sameDate(_start, day);
                  final isEnd = _sameDate(_end, day);
                  final inRange =
                      _start != null &&
                      _end != null &&
                      day.isAfter(_start!) &&
                      day.isBefore(_end!);
                  final selected = isStart || isEnd;

                  return InkWell(
                    onTap: selectable ? () => _select(day) : null,
                    borderRadius: BorderRadius.circular(20),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: selected
                            ? _teal
                            : inRange
                            ? const Color(0xFFD9EEEE)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${day.day}',
                        style: TextStyle(
                          color: selected
                              ? Colors.white
                              : !selectable || !inMonth
                              ? const Color(0xFFCBD5E1)
                              : _ink,
                          fontSize: 12,
                          fontWeight: selected || inRange
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 13),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _start != null && _end != null
                        ? () => Navigator.pop(
                            context,
                            DateTimeRange(start: _start!, end: _end!),
                          )
                        : null,
                    style: FilledButton.styleFrom(backgroundColor: _teal),
                    child: const Text('Continue'),
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

class _LeaveWeekdayLabel extends StatelessWidget {
  final String label;
  const _LeaveWeekdayLabel(this.label);

  @override
  Widget build(BuildContext context) => Expanded(
    child: Text(
      label,
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: Color(0xFF94A3B8),
        fontSize: 9,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _CompactTimeButton extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;
  const _CompactTimeButton({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      child: Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
    ),
  );
}

class _EmptyLeaveCard extends StatelessWidget {
  const _EmptyLeaveCard();
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
    decoration: BoxDecoration(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    child: const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: Color(0xFFE8F5F5),
          child: Icon(Icons.beach_access_outlined, color: _teal, size: 22),
        ),
        SizedBox(width: 13),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'No planned leave yet.',
                style: TextStyle(
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'Add leave to automatically mark this staff member unavailable.',
                style: TextStyle(color: _muted, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _LeaveRow extends StatelessWidget {
  final String dates;
  final String reason;
  final VoidCallback onDelete;
  const _LeaveRow({
    required this.dates,
    required this.reason,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE5E7EB)),
    ),
    child: Row(
      children: [
        const Icon(
          Icons.event_busy_outlined,
          color: Color(0xFFD97706),
          size: 20,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                dates,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: _ink,
                ),
              ),
              if (reason.isNotEmpty)
                Text(
                  reason,
                  style: const TextStyle(fontSize: 12, color: _muted),
                ),
            ],
          ),
        ),
        IconButton(
          onPressed: onDelete,
          tooltip: 'Delete leave',
          icon: const Icon(
            Icons.delete_outline,
            color: Color(0xFFB91C1C),
            size: 20,
          ),
        ),
      ],
    ),
  );
}

class _TherapistAvailabilityCard extends StatelessWidget {
  final _ManagedTherapist therapist;
  final bool selected;
  final VoidCallback onTap;

  const _TherapistAvailabilityCard({
    required this.therapist,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isBusy = therapist.busyUntil.isNotEmpty;
    final effectivelyAvailable =
        therapist.available && !therapist.onLeave && !isBusy;
    final statusColor = therapist.onLeave
        ? const Color(0xFFD97706)
        : isBusy
        ? const Color(0xFFDC6B19)
        : effectivelyAvailable
        ? const Color(0xFF10B981)
        : const Color(0xFF9CA3AF);
    final isCompact = MediaQuery.of(context).size.width < 600;
    final avatarRadius = isCompact ? 20.0 : 21.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? const Color(0xFFF0FDFA) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? _teal : const Color(0xFFE5E7EB),
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: avatarRadius,
                      backgroundColor: _avatarColor(therapist.name),
                      child: Text(
                        _initials(therapist.name),
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: isCompact ? 15 : 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            therapist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: isCompact ? 15 : 16,
                              color: _ink,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            therapist.role,
                            style: const TextStyle(
                              color: _muted,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${therapist.doneToday} services today',
                            style: const TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        therapist.onLeave
                            ? 'On Leave'
                            : isBusy
                            ? 'Busy until ${_friendlyTime(therapist.busyUntil)}'
                            : effectivelyAvailable
                            ? 'Available'
                            : 'Unavailable',
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: Color(0xFF94A3B8),
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

class _TherapistFormDialog extends StatefulWidget {
  final _ManagedTherapist? therapist;

  const _TherapistFormDialog({this.therapist});

  @override
  State<_TherapistFormDialog> createState() => _TherapistFormDialogState();
}

class _TherapistFormDialogState extends State<_TherapistFormDialog> {
  final _therapistRepository = TherapistRepository();
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _role;
  late final TextEditingController _busyUntil;
  bool _available = true;
  bool _saving = false;
  bool _closing = false;

  bool get _isEditing => widget.therapist != null;

  @override
  void initState() {
    super.initState();
    final therapist = widget.therapist;
    _name = TextEditingController(text: therapist?.name ?? '');
    _phone = TextEditingController(text: therapist?.phone ?? '');
    _role = TextEditingController(text: therapist?.role ?? 'Therapist');
    _busyUntil = TextEditingController(text: therapist?.busyUntil ?? '');
    _available = therapist?.available ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _role.dispose();
    _busyUntil.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || _closing) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final data = {
      'name': _name.text.trim(),
      'phone': _phone.text.trim(),
      'role': _normalizeStaffRole(_role.text),
      'availabilityStatus': _available,
      'busyUntil': _busyUntil.text.trim(),
    };
    try {
      if (_isEditing) {
        await _therapistRepository.updateTherapist(widget.therapist!.id, data);
      } else {
        await _therapistRepository.addTherapist({
          ...data,
          'createdAt': DateTime.now().toIso8601String(),
        });
      }
      _close(true);
    } catch (e) {
      debugPrint('Unable to save staff: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Unable to save staff: $e')));
    }
  }

  void _close([bool? result]) {
    if (_closing || !mounted) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _isEditing ? 'Edit Staff' : 'Add Staff',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: _ink,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: _saving ? null : () => _close(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _FormField(
                  label: 'Name',
                  controller: _name,
                  requiredField: true,
                ),
                const SizedBox(height: 12),
                _FormField(
                  label: 'Phone',
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 12),
                _StaffRoleDropdown(label: 'Role', controller: _role),
                const SizedBox(height: 12),
                _FormField(
                  label: 'Free At',
                  controller: _busyUntil,
                  hint: 'Example: 14:30',
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  value: _available,
                  onChanged: _saving
                      ? null
                      : (value) => setState(() => _available = value),
                  activeThumbColor: Colors.white,
                  activeTrackColor: const Color(0xFF10B981),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Available'),
                ),
                const SizedBox(height: 20),
                _DialogActions(
                  saving: _saving,
                  saveLabel: _isEditing ? 'Save Changes' : 'Add Staff',
                  onCancel: () => _close(),
                  onSave: _save,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Kept for older management forms that still use the legacy header.
// ignore: unused_element
class _AddButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _AddButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.of(context).size.width < 600;
    if (isCompact) {
      return _CircleIconButton(
        icon: Icons.add,
        tooltip: label,
        onPressed: onTap,
        filled: true,
      );
    }

    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.add, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: _teal,
        side: const BorderSide(color: _teal),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  final bool filled;

  const _CircleIconButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      height: 38,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        icon: Icon(icon, size: 20),
        color: filled ? Colors.white : _teal,
        style: IconButton.styleFrom(
          backgroundColor: filled ? _teal : const Color(0xFFE8F5F5),
          shape: const CircleBorder(),
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final String hint;

  const _SearchBar({required this.controller, required this.hint});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: const Color(0xFFE8EEF3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD4DEE8)),
      ),
      child: TextField(
        controller: controller,
        style: const TextStyle(
          color: _ink,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
            color: Color(0xFF64748B),
            fontWeight: FontWeight.w700,
          ),
          prefixIcon: const Icon(
            Icons.search,
            color: Color(0xFF475569),
            size: 20,
          ),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  final Widget child;

  const _Panel({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isLast;

  const _InfoRow(this.label, this.value, {this.isLast = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 4,
                child: Text(label, style: const TextStyle(color: _muted)),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 6,
                child: Text(
                  value.isEmpty ? '-' : value,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: _ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!isLast) const Divider(height: 1, color: Color(0xFFE5E7EB)),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool active;
  final String label;

  const _StatusDot({required this.active, required this.label});

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFF10B981) : const Color(0xFF9CA3AF);
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
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _FormField extends StatelessWidget {
  final String label;
  final String? hint;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final bool requiredField;
  final bool enabled;
  final int maxLines;

  const _FormField({
    required this.label,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.requiredField = false,
    this.enabled = true,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
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
        fillColor: enabled ? const Color(0xFFF7F8FA) : const Color(0xFFEDEFF2),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _teal, width: 1.4),
        ),
      ),
    );
  }
}

class _ControllerDropdown extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final List<String> options;
  final String Function(String)? optionLabel;
  final ValueChanged<String>? onChanged;

  const _ControllerDropdown({
    required this.label,
    required this.controller,
    required this.options,
    this.optionLabel,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final current = controller.text.trim();
    final available = <String>{
      ...options,
      if (current.isNotEmpty) current,
    }.toList();
    final selected = current.isEmpty
        ? (available.isEmpty ? null : available.first)
        : current;
    if (controller.text.isEmpty && selected != null) controller.text = selected;

    return DropdownButtonFormField<String>(
      key: ValueKey('$label|$selected|${available.join('|')}'),
      initialValue: selected,
      isExpanded: true,
      items: available
          .map(
            (value) => DropdownMenuItem<String>(
              value: value,
              child: Text(optionLabel?.call(value) ?? value),
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value != null) {
          controller.text = value;
          onChanged?.call(value);
        }
      },
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: const Color(0xFFF7F8FA),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _teal, width: 1.4),
        ),
      ),
    );
  }
}

class _StaffRoleDropdown extends StatelessWidget {
  final String label;
  final TextEditingController controller;

  const _StaffRoleDropdown({required this.label, required this.controller});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: _normalizeStaffRole(controller.text),
      items: const [
        DropdownMenuItem(value: 'Therapist', child: Text('Therapist')),
        DropdownMenuItem(value: 'Counter', child: Text('Counter')),
      ],
      onChanged: (value) => controller.text = value ?? 'Therapist',
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: const Color(0xFFF7F8FA),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _teal, width: 1.4),
        ),
      ),
    );
  }
}

class _DialogActions extends StatelessWidget {
  final bool saving;
  final String saveLabel;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  const _DialogActions({
    required this.saving,
    required this.saveLabel,
    required this.onCancel,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextButton(
            onPressed: saving ? null : onCancel,
            style: TextButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: const Color(0xFFF1F3F6),
              foregroundColor: _ink,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Cancel'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton(
            onPressed: saving ? null : onSave,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: _teal,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(saveLabel),
          ),
        ),
      ],
    );
  }
}
