import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/appointment_repository.dart';
import '../../data/repositories/room_repository.dart';
import '../../data/repositories/service_repository.dart';
import '../../data/repositories/therapist_repository.dart';
import '../therapists/therapist_screen.dart';

const _teal = Color(0xFF1B6B72);
const _ink = Color(0xFF1A1A2E);
const _muted = Color(0xFF6B7280);
const _page = Color(0xFFF4F5F7);

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

String _today() => DateFormat('yyyy-MM-dd').format(DateTime.now());

int _timeToMinutes(String value) {
  final parts = value.split(':');
  if (parts.length < 2) return 0;
  return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
}

bool _isPendingAppointmentStatus(String status) {
  return status == 'pending' || status == 'confirmed' || status == 'in_progress';
}

String _initials(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length >= 2) return '${parts.first[0]}${parts[1][0]}'.toUpperCase();
  return name.isNotEmpty ? name[0].toUpperCase() : '?';
}

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
      backgroundColor: _page,
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
                    icon: Icons.content_cut,
                    color: _teal,
                    title: 'Services',
                    subtitle: 'Manage service offerings and pricing',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _ServiceRoomScreen(
                          type: _ResourceType.service,
                          userRole: userRole,
                        ),
                      ),
                    ),
                  ),
                  _ManagementOption(
                    icon: Icons.group_outlined,
                    color: const Color(0xFFD19A33),
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
                    icon: Icons.meeting_room_outlined,
                    color: const Color(0xFF8B5CF6),
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
      color: Colors.white,
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
                    color: _ink,
                    fontSize: isCompact ? 18 : 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (!isCompact) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(color: _muted, fontSize: 14),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: 0.12),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: Colors.white, size: 27),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          color: _ink,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 14,
                          color: _muted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Color(0xFFCBD5E1)),
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
    final active = _asBool(d['active'] ?? d['isActive'], true);
    return _ResourceItem(
      id: _asString(d['id']),
      name: name,
      subtitle: _asString(d['category'], 'Services'),
      detail:
          '$duration min | RM ${price.toStringAsFixed(0)} | Comm RM ${therapistCommission.toStringAsFixed(0)}/${counterCommission.toStringAsFixed(0)}',
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
    return _ResourceItem(
      id: _asString(d['id']),
      name: name,
      subtitle: _roomTypeLabel(_asString(d['type'] ?? d['roomType'])),
      detail:
          '${_asString(d['floor'], 'Main Floor')} | $totalSlots slot${totalSlots == 1 ? '' : 's'}',
      statusText: active ? 'Available' : 'Unavailable',
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
  final _searchController = TextEditingController();
  List<_ResourceItem> _items = [];
  List<_ResourceItem> _filtered = [];
  _ResourceItem? _selected;
  bool _loading = true;

  String get _title =>
      widget.type == _ResourceType.service ? 'Services' : 'Rooms';
  String get _subtitle => widget.type == _ResourceType.service
      ? 'Manage service offerings and pricing'
      : 'Manage room availability and equipment';
  bool get _isAdmin => widget.userRole == 'admin';
  bool get _canDeleteCurrentType => _isAdmin;

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
      final rows = widget.type == _ResourceType.service
          ? await _serviceRepository.getServices()
          : await _roomRepository.getRooms();
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
        _selected = items.isEmpty
            ? null
            : items.firstWhere(
                (item) => item.id == _selected?.id,
                orElse: () => items.first,
              );
        _loading = false;
      });
      _filter();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
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
        _selected = _filtered.first;
      }
    });
  }

  Future<void> _openForm({_ResourceItem? item}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ResourceFormDialog(type: widget.type, item: item),
    );
    if (saved == true) await _load();
  }

  Future<void> _delete(_ResourceItem item) async {
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
      return;
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
    if (confirmed != true) return;
    if (widget.type == _ResourceType.service) {
      await _serviceRepository.deleteService(item.id);
    } else {
      await _roomRepository.deleteRoom(item.id);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 900;
    return Scaffold(
      backgroundColor: _page,
      body: SafeArea(
        child: Column(
          children: [
            _ManagementHeader(
              title: _title,
              subtitle: _subtitle,
              action: _AddButton(
                label: widget.type == _ResourceType.service
                    ? 'Add Service'
                    : 'Add Room',
                onTap: () => _openForm(),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: _teal))
                  : isWide
                  ? Row(
                      children: [
                        SizedBox(width: 360, child: _resourceListPane()),
                        Expanded(child: _resourceDetailPane()),
                      ],
                    )
                  : _resourceListPane(phone: true),
            ),
          ],
        ),
      ),
    );
  }

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
                CircleAvatar(
                  backgroundColor: item.color,
                  child: Text(
                    _initials(item.name),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
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
    return ListView(
      children: [
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: item.color,
                    child: Text(
                      _initials(item.name),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
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
}

class _ResourceFormDialog extends StatefulWidget {
  final _ResourceType type;
  final _ResourceItem? item;

  const _ResourceFormDialog({required this.type, this.item});

  @override
  State<_ResourceFormDialog> createState() => _ResourceFormDialogState();
}

class _ResourceFormDialogState extends State<_ResourceFormDialog> {
  final _serviceRepository = ServiceRepository();
  final _roomRepository = RoomRepository();
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _category;
  late final TextEditingController _duration;
  late final TextEditingController _price;
  late final TextEditingController _therapistCommission;
  late final TextEditingController _counterCommission;
  late final TextEditingController _roomType;
  late final TextEditingController _floor;
  late final TextEditingController _slots;
  late final TextEditingController _equipment;
  bool _active = true;
  bool _saving = false;
  bool _closing = false;

  bool get _isService => widget.type == _ResourceType.service;
  bool get _isEditing => widget.item != null;

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
    _floor = TextEditingController(text: _asString(raw['floor'], 'Main Floor'));
    _slots = TextEditingController(
      text: _asInt(raw['totalSlots'], 1).toString(),
    );
    _equipment = TextEditingController(text: _asString(raw['equipment']));
    _active = _asBool(raw['active'] ?? raw['isActive'], true);
  }

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _duration.dispose();
    _price.dispose();
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
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final data = _isService
        ? {
            'name': _name.text.trim(),
            'category': _category.text.trim().isEmpty
                ? 'Services'
                : _category.text.trim(),
            'duration': int.tryParse(_duration.text.trim()) ?? 60,
            'price': double.tryParse(_price.text.trim()) ?? 0,
            'therapistCommission':
                double.tryParse(_therapistCommission.text.trim()) ?? 0,
            'counterCommission':
                double.tryParse(_counterCommission.text.trim()) ?? 0,
            'roomType': _normalizeRoomType(_roomType.text),
            'isActive': _active,
          }
        : {
            'name': _name.text.trim(),
            'type': _normalizeRoomType(_roomType.text),
            'roomType': _normalizeRoomType(_roomType.text),
            'floor': _floor.text.trim(),
            'totalSlots': int.tryParse(_slots.text.trim()) ?? 1,
            'equipment': _equipment.text.trim(),
            'isActive': _active,
          };
    try {
      if (_isEditing) {
        if (_isService) {
          await _serviceRepository.updateService(widget.item!.id, data);
        } else {
          await _roomRepository.updateRoom(widget.item!.id, data);
        }
      } else {
        if (_isService) {
          await _serviceRepository.addService(data);
        } else {
          await _roomRepository.createRoom(data);
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

  void _close([bool? result]) {
    if (_closing || !mounted) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = _isService ? 'Service' : 'Room';
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
                _FormField(
                  label: 'Name',
                  controller: _name,
                  requiredField: true,
                ),
                const SizedBox(height: 12),
                if (_isService) ...[
                  _FormField(
                    label: 'Category',
                    controller: _category,
                    hint: 'Services / Packages / Add-ons',
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
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _FormField(
                          label: 'Counter Commission',
                          controller: _counterCommission,
                          hint: 'RM per service',
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _FormField(
                    label: 'Room Type',
                    controller: _roomType,
                    hint: 'body_room / foot_chair',
                  ),
                ] else ...[
                  _FormField(
                    label: 'Room Type',
                    controller: _roomType,
                    hint: 'body_room / foot_chair',
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _FormField(label: 'Floor', controller: _floor),
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

class _ManagedTherapist {
  final String id;
  final String name;
  final String phone;
  final String role;
  final bool available;
  final String busyUntil;
  final int doneToday;
  final Map<String, dynamic> raw;

  const _ManagedTherapist({
    required this.id,
    required this.name,
    required this.phone,
    required this.role,
    required this.available,
    required this.busyUntil,
    required this.doneToday,
    required this.raw,
  });

  factory _ManagedTherapist.fromMap(Map<String, dynamic> d) {
    return _ManagedTherapist(
      id: _asString(d['id']),
      name: _asString(d['name']),
      phone: _asString(d['phone']),
      role: _normalizeStaffRole(d['role'] ?? d['staffRole'] ?? d['employmentType']),
      available: _asBool(d['availabilityStatus'], true),
      busyUntil: _asString(d['busyUntil']),
      doneToday: 0,
      raw: d,
    );
  }

  _ManagedTherapist copyWith({
    bool? available,
    String? busyUntil,
    int? doneToday,
  }) {
    return _ManagedTherapist(
      id: id,
      name: name,
      phone: phone,
      role: role,
      available: available ?? this.available,
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
  final _searchController = TextEditingController();
  List<_ManagedTherapist> _therapists = [];
  List<_ManagedTherapist> _filtered = [];
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
      final rows = await _therapistRepository.getTherapists();
      final loaded = await Future.wait(
        rows.map((row) async => _enrich(_ManagedTherapist.fromMap(row))),
      );
      if (!mounted) return;
      setState(() {
        _therapists = loaded;
        _filtered = loaded;
        _loading = false;
      });
      _filter();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<_ManagedTherapist> _enrich(_ManagedTherapist therapist) async {
    final today = _today();
    final appointments = await _appointmentRepository
        .getAppointmentsByTherapist(
          therapist.id,
          date: DateTime.tryParse(today),
        );

    var done = 0;
    var busyUntil = therapist.busyUntil;
    final now = TimeOfDay.now();
    final nowMinutes = now.hour * 60 + now.minute;

    for (final d in appointments) {
      final status = _asString(d['status']).toLowerCase();
      if (status == 'completed') done++;
      if (_isPendingAppointmentStatus(status)) {
        final start = _timeToMinutes(_asString(d['startTime'], '00:00'));
        final end = _timeToMinutes(_asString(d['endTime'], '00:00'));
        if (start <= nowMinutes && end > nowMinutes) {
          busyUntil = _asString(d['endTime']);
        }
      }
    }

    return therapist.copyWith(doneToday: done, busyUntil: busyUntil);
  }

  void _filter() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      _filtered = _therapists.where((therapist) {
        return therapist.name.toLowerCase().contains(query) ||
            therapist.phone.toLowerCase().contains(query) ||
            therapist.role.toLowerCase().contains(query);
      }).toList();
    });
  }

  Future<void> _setAvailability(_ManagedTherapist therapist, bool value) async {
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
            Padding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                16,
                horizontalPadding,
                8,
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
                          horizontalPadding,
                          0,
                          horizontalPadding,
                          20,
                        ),
                        itemCount: _filtered.length,
                        itemBuilder: (_, index) {
                          final therapist = _filtered[index];
                          return _TherapistAvailabilityCard(
                            therapist: therapist,
                            onChanged: (value) =>
                                _setAvailability(therapist, value),
                            onEdit: () => _openForm(therapist: therapist),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TherapistAvailabilityCard extends StatelessWidget {
  final _ManagedTherapist therapist;
  final ValueChanged<bool> onChanged;
  final VoidCallback onEdit;

  const _TherapistAvailabilityCard({
    required this.therapist,
    required this.onChanged,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final statusColor = therapist.available
        ? const Color(0xFF10B981)
        : const Color(0xFF9CA3AF);
    final freeText = therapist.available
        ? 'Free now'
        : therapist.busyUntil.isNotEmpty
        ? 'Free at ${therapist.busyUntil}'
        : 'Unavailable';
    final isCompact = MediaQuery.of(context).size.width < 600;
    final avatarRadius = isCompact ? 22.0 : 24.0;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(isCompact ? 12 : 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
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
              SizedBox(width: isCompact ? 12 : 14),
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
                    const SizedBox(height: 4),
                    if (therapist.phone.isNotEmpty)
                      Text(
                        therapist.phone,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _muted, fontSize: 12),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _TherapistMiniPill(therapist.role),
                        _TherapistMiniPill(
                          '${therapist.doneToday} appts today',
                        ),
                        _TherapistMiniPill(freeText),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 34,
                height: 34,
                child: IconButton(
                  onPressed: onEdit,
                  tooltip: 'Edit staff',
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  color: _teal,
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFFE8F5F5),
                    shape: const CircleBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
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
                  therapist.available ? 'Available' : 'Unavailable',
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SizedBox(
                width: 52,
                height: 32,
                child: Transform.scale(
                  scale: 0.82,
                  child: Switch(
                    value: therapist.available,
                    onChanged: onChanged,
                    activeThumbColor: Colors.white,
                    activeTrackColor: const Color(0xFF10B981),
                    inactiveThumbColor: Colors.white,
                    inactiveTrackColor: const Color(0xFFD1D5DB),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TherapistMiniPill extends StatelessWidget {
  final String label;

  const _TherapistMiniPill(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: _muted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
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
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(
          Icons.search,
          color: Color(0xFF9CA3AF),
          size: 20,
        ),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
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
            children: [
              Text(label, style: const TextStyle(color: _muted)),
              const SizedBox(width: 16),
              Expanded(
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
  final int maxLines;

  const _FormField({
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
