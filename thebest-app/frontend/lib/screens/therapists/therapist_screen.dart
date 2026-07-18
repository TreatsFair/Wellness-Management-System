import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../data/repositories/image_upload_repository.dart';
import '../../data/repositories/service_repository.dart';
import '../../data/repositories/therapist_repository.dart';

String _normalizeStaffRole(Object? value) {
  final raw = value?.toString().trim().toLowerCase() ?? '';
  if (raw.contains('counter') || raw.contains('cashier')) return 'Counter';
  return 'Therapist';
}

// -- Data model ----------------------------------------------------
class TherapistModel {
  final String id;
  final String name;
  final String phone;
  final String gender;
  final String role;
  final String joinDate;
  final bool availabilityStatus;
  final String notes;
  final String profileImageUrl;
  final Map<String, double> serviceCommissions;

  // Calculated
  final int totalAppointments;

  const TherapistModel({
    required this.id,
    required this.name,
    required this.phone,
    required this.gender,
    required this.role,
    required this.joinDate,
    required this.availabilityStatus,
    required this.notes,
    required this.profileImageUrl,
    required this.serviceCommissions,
    this.totalAppointments = 0,
  });

  static String _stringValue(dynamic value) {
    if (value == null) return '';
    return value.toString();
  }

  static bool _boolValue(dynamic value) {
    if (value is bool) return value;
    if (value is String) return value.toLowerCase().trim() == 'true';
    return true;
  }

  static Map<String, double> _commissionMap(dynamic value) {
    if (value is! Map) return {};
    return value.map((key, item) {
      final amount = item is num
          ? item.toDouble()
          : double.tryParse(item?.toString() ?? '') ?? 0;
      return MapEntry(key.toString(), amount);
    });
  }

  factory TherapistModel.fromMap(Map<String, dynamic> d) {
    return TherapistModel(
      id: _stringValue(d['id']),
      name: _stringValue(d['name']),
      phone: _stringValue(d['phone']),
      gender: _stringValue(d['gender']),
      role: _normalizeStaffRole(
        d['role'] ?? d['staffRole'] ?? d['employmentType'],
      ),
      joinDate: _stringValue(d['joinDate']),
      availabilityStatus: _boolValue(d['availabilityStatus']),
      notes: _stringValue(d['notes']),
      profileImageUrl: _stringValue(d['profileImageUrl']),
      serviceCommissions: _commissionMap(d['serviceCommissions']),
    );
  }

  String get initials {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
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

  TherapistModel copyWith({
    int? totalAppointments,
    String? profileImageUrl,
    Map<String, double>? serviceCommissions,
  }) {
    return TherapistModel(
      id: id,
      name: name,
      phone: phone,
      gender: gender,
      role: role,
      joinDate: joinDate,
      availabilityStatus: availabilityStatus,
      notes: notes,
      profileImageUrl: profileImageUrl ?? this.profileImageUrl,
      serviceCommissions: serviceCommissions ?? this.serviceCommissions,
      totalAppointments: totalAppointments ?? this.totalAppointments,
    );
  }
}

// -- Main screen ---------------------------------------------------
class TherapistsScreen extends StatefulWidget {
  final String userRole;
  const TherapistsScreen({super.key, required this.userRole});

  @override
  State<TherapistsScreen> createState() => _TherapistsScreenState();
}

class _TherapistsScreenState extends State<TherapistsScreen> {
  final _therapistRepository = TherapistRepository();
  List<TherapistModel> _therapists = [];
  List<TherapistModel> _filtered = [];
  TherapistModel? _selected;
  bool _loading = true;
  final _searchController = TextEditingController();

  bool get _isAdmin => widget.userRole == 'admin';

  @override
  void initState() {
    super.initState();
    _loadTherapists();
    _searchController.addListener(_onSearch);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadTherapists() async {
    setState(() => _loading = true);
    try {
      final rows = await _therapistRepository.getTherapists();
      final therapists = rows.map(TherapistModel.fromMap).toList();

      final enriched = await Future.wait(
        therapists.map((t) => _enrichTherapist(t)),
      );

      setState(() {
        _therapists = enriched;
        _filtered = enriched;
        _loading = false;
        if (enriched.isNotEmpty) _selected = enriched.first;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  Future<TherapistModel> _enrichTherapist(TherapistModel t) async {
    try {
      // Total completed appointments
      final stats = await _therapistRepository.getTherapistAppointmentStats(
        t.id,
        date: DateTime.now(),
      );

      // This month

      // Last session — most recent appointment
      return t.copyWith(
        totalAppointments: stats['completedAppointments'] as int? ?? 0,
      );
    } catch (_) {
      return t;
    }
  }

  String _todayString() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }

  Future<TherapistModel?> _openTherapistForm({
    TherapistModel? therapist,
  }) async {
    final savedTherapist = await showDialog<TherapistModel>(
      context: context,
      builder: (context) => _TherapistFormDialog(
        therapist: therapist,
        defaultJoinDate: _todayString(),
      ),
    );

    if (savedTherapist == null) return null;

    setState(() {
      final existingIndex = _therapists.indexWhere(
        (t) => t.id == savedTherapist.id,
      );
      if (existingIndex == -1) {
        _therapists = [..._therapists, savedTherapist];
      } else {
        _therapists = [
          ..._therapists.take(existingIndex),
          savedTherapist,
          ..._therapists.skip(existingIndex + 1),
        ];
      }
      _therapists.sort((a, b) => a.name.compareTo(b.name));

      final query = _searchController.text.toLowerCase();
      _filtered = _therapists.where((t) {
        return t.name.toLowerCase().contains(query) ||
            t.phone.toLowerCase().contains(query) ||
            t.role.toLowerCase().contains(query);
      }).toList();
      _selected = savedTherapist;
    });

    return savedTherapist;
  }

  Future<bool> _deleteTherapist(TherapistModel therapist) async {
    final firstConfirm = await _confirmDeleteTherapist(
      title: 'Remove Staff',
      message: 'This will remove ${therapist.name} from the staff list.',
      buttonLabel: 'Continue',
    );
    if (firstConfirm != true) return false;

    final secondConfirm = await _confirmDeleteTherapist(
      title: 'Confirm Delete',
      message: 'Press delete again to permanently remove ${therapist.name}.',
      buttonLabel: 'Delete',
    );
    if (secondConfirm != true) return false;

    try {
      await _therapistRepository.deleteTherapist(therapist.id);

      if (!mounted) return false;
      setState(() {
        _therapists = _therapists
            .where((existing) => existing.id != therapist.id)
            .toList();
        final query = _searchController.text.toLowerCase();
        _filtered = _therapists.where((t) {
          return t.name.toLowerCase().contains(query) ||
              t.phone.toLowerCase().contains(query);
        }).toList();

        if (_selected?.id == therapist.id) {
          _selected = _filtered.isNotEmpty ? _filtered.first : null;
        }
      });
      return true;
    } catch (_) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to remove staff'),
          backgroundColor: Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return false;
    }
  }

  Future<bool?> _confirmDeleteTherapist({
    required String title,
    required String message,
    required String buttonLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
              foregroundColor: Colors.white,
            ),
            child: Text(buttonLabel),
          ),
        ],
      ),
    );
  }

  void _onSearch() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filtered = _therapists.where((t) {
        return t.name.toLowerCase().contains(query) ||
            t.phone.toLowerCase().contains(query) ||
            t.role.toLowerCase().contains(query);
      }).toList();
    });
  }

  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 900;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF1B6B72)),
              )
            : _isTablet(context)
            ? _TabletLayout(
                therapists: _filtered,
                selected: _selected,
                searchController: _searchController,
                isAdmin: _isAdmin,
                onSelect: (t) => setState(() => _selected = t),
                onRefresh: _loadTherapists,
                onAdd: () => _openTherapistForm(),
                onEdit: (t) => _openTherapistForm(therapist: t),
                onDelete: _deleteTherapist,
              )
            : _PhoneLayout(
                therapists: _filtered,
                searchController: _searchController,
                isAdmin: _isAdmin,
                onRefresh: _loadTherapists,
                onAdd: () => _openTherapistForm(),
                onEdit: (t) => _openTherapistForm(therapist: t),
                onDelete: _deleteTherapist,
              ),
      ),
    );
  }
}

// -----------------------------------------------------------------
// TABLET LAYOUT
// -----------------------------------------------------------------
class _TabletLayout extends StatelessWidget {
  final List<TherapistModel> therapists;
  final TherapistModel? selected;
  final TextEditingController searchController;
  final bool isAdmin;
  final Function(TherapistModel) onSelect;
  final VoidCallback onRefresh;
  final VoidCallback onAdd;
  final Future<TherapistModel?> Function(TherapistModel) onEdit;
  final Future<bool> Function(TherapistModel) onDelete;

  const _TabletLayout({
    required this.therapists,
    required this.selected,
    required this.searchController,
    required this.isAdmin,
    required this.onSelect,
    required this.onRefresh,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left — therapist list
        Container(
          width: 360,
          color: Colors.white,
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 16, 0),
                child: Row(
                  children: [
                    const BackButton(),
                    const Expanded(
                      child: Text(
                        'Staff',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                    ),
                    const SizedBox(width: 36, height: 36),
                  ],
                ),
              ),

              // Search
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                child: _SearchBar(controller: searchController),
              ),

              // List
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async => onRefresh(),
                  color: const Color(0xFF1B6B72),
                  child: ListView.builder(
                    itemCount: therapists.length,
                    itemBuilder: (_, i) => _TabletListItem(
                      therapist: therapists[i],
                      isSelected: selected?.id == therapists[i].id,
                      onTap: () => onSelect(therapists[i]),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // Right — detail panel
        Expanded(
          child: Column(
            children: [
              _TabletDetailHeader(
                title: 'Staff Details',
                addLabel: 'Add Staff',
                onAdd: onAdd,
              ),
              Expanded(
                child: selected == null
                    ? const Center(
                        child: Text(
                          'Select a staff member to view details',
                          style: TextStyle(color: Color(0xFF9E9E9E)),
                        ),
                      )
                    : _DetailPanel(
                        therapist: selected!,
                        isAdmin: isAdmin,
                        onEdit: () => onEdit(selected!),
                        onDelete: () => onDelete(selected!),
                        showTabletHeader: false,
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabletListItem extends StatelessWidget {
  final TherapistModel therapist;
  final bool isSelected;
  final VoidCallback onTap;

  const _TabletListItem({
    required this.therapist,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF1B6B72).withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: isSelected
              ? Border.all(color: const Color(0xFF1B6B72), width: 1.5)
              : null,
        ),
        child: Row(
          children: [
            _Avatar(therapist: therapist, radius: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    therapist.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    therapist.role,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9E9E9E),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: therapist.availabilityStatus
                              ? const Color(0xFF4CAF50)
                              : const Color(0xFFF59E0B),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        therapist.availabilityStatus
                            ? 'Available'
                            : 'Unavailable',
                        style: TextStyle(
                          fontSize: 11,
                          color: therapist.availabilityStatus
                              ? const Color(0xFF4CAF50)
                              : const Color(0xFFF59E0B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Text(
              '${therapist.totalAppointments} done today',
              style: const TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------
// PHONE LAYOUT
// -----------------------------------------------------------------
class _PhoneLayout extends StatelessWidget {
  final List<TherapistModel> therapists;
  final TextEditingController searchController;
  final bool isAdmin;
  final VoidCallback onRefresh;
  final VoidCallback onAdd;
  final Future<TherapistModel?> Function(TherapistModel) onEdit;
  final Future<bool> Function(TherapistModel) onDelete;

  const _PhoneLayout({
    required this.therapists,
    required this.searchController,
    required this.isAdmin,
    required this.onRefresh,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = MediaQuery.of(context).size.width < 360
        ? 12.0
        : 16.0;

    return Column(
      children: [
        // Header
        Container(
          color: Colors.white,
          padding: EdgeInsets.fromLTRB(4, 12, horizontalPadding, 12),
          child: Row(
            children: [
              const BackButton(),
              const Expanded(
                child: Text(
                  'Staff',
                  textAlign: TextAlign.start,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
              Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF1B6B72),
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.add, color: Colors.white, size: 20),
                  onPressed: onAdd,
                ),
              ),
            ],
          ),
        ),

        // Search
        Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            14,
            horizontalPadding,
            14,
          ),
          child: _SearchBar(controller: searchController),
        ),

        // List
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => onRefresh(),
            color: const Color(0xFF1B6B72),
            child: ListView.builder(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                0,
                horizontalPadding,
                20,
              ),
              itemCount: therapists.length,
              itemBuilder: (_, i) => _PhoneListCard(
                therapist: therapists[i],
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _PhoneDetailScreen(
                      therapist: therapists[i],
                      isAdmin: isAdmin,
                      onEdit: onEdit,
                      onDelete: onDelete,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PhoneListCard extends StatelessWidget {
  final TherapistModel therapist;
  final VoidCallback onTap;

  const _PhoneListCard({required this.therapist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Avatar(therapist: therapist, radius: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        therapist.name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        therapist.role,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF9E9E9E),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${therapist.totalAppointments} done today',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1B6B72),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: therapist.availabilityStatus
                                ? const Color(0xFF4CAF50)
                                : const Color(0xFFF59E0B),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          therapist.availabilityStatus
                              ? 'Available'
                              : 'Unavailable',
                          style: TextStyle(
                            fontSize: 11,
                            color: therapist.availabilityStatus
                                ? const Color(0xFF4CAF50)
                                : const Color(0xFFF59E0B),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PhoneDetailScreen extends StatefulWidget {
  final TherapistModel therapist;
  final bool isAdmin;
  final Future<TherapistModel?> Function(TherapistModel) onEdit;
  final Future<bool> Function(TherapistModel) onDelete;

  const _PhoneDetailScreen({
    required this.therapist,
    required this.isAdmin,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_PhoneDetailScreen> createState() => _PhoneDetailScreenState();
}

class _PhoneDetailScreenState extends State<_PhoneDetailScreen> {
  late TherapistModel _therapist;

  @override
  void initState() {
    super.initState();
    _therapist = widget.therapist;
  }

  Future<void> _editAndReturn() async {
    final updatedTherapist = await widget.onEdit(_therapist);
    if (updatedTherapist != null && mounted) {
      setState(() => _therapist = updatedTherapist);
    }
  }

  Future<void> _deleteAndReturn() async {
    final deleted = await widget.onDelete(_therapist);
    if (deleted && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        leading: const BackButton(),
        centerTitle: true,
        title: const Text(
          'Staff Details',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A2E),
          ),
        ),
        actions: [
          _CircleIconButton(
            icon: Icons.edit_outlined,
            tooltip: 'Edit staff',
            onPressed: _editAndReturn,
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(
          MediaQuery.of(context).size.width < 360 ? 12 : 16,
        ),
        child: _DetailPanel(
          therapist: _therapist,
          isAdmin: widget.isAdmin,
          onEdit: _editAndReturn,
          onDelete: _deleteAndReturn,
          showInlineEdit: false,
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------
// DETAIL PANEL — shared between tablet and phone
// -----------------------------------------------------------------
class _DetailPanel extends StatelessWidget {
  final TherapistModel therapist;
  final bool isAdmin;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool showTabletHeader;
  final bool showInlineEdit;

  const _DetailPanel({
    required this.therapist,
    required this.isAdmin,
    required this.onEdit,
    required this.onDelete,
    this.showTabletHeader = true,
    this.showInlineEdit = true,
  });

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width >= 900;

    return SingleChildScrollView(
      padding: EdgeInsets.all(isTablet ? 24 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tablet title + edit button row
          if (isTablet && showTabletHeader)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Staff Details',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(
                      Icons.edit_outlined,
                      size: 16,
                      color: Color(0xFF1B6B72),
                    ),
                    label: const Text(
                      'Edit',
                      style: TextStyle(color: Color(0xFF1B6B72)),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF1B6B72)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // -- Profile card ------------------------------------
          _Card(
            child: Row(
              children: [
                _Avatar(therapist: therapist, radius: 32),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        therapist.name,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(
                            Icons.transgender,
                            size: 14,
                            color: Color(0xFF9E9E9E),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            therapist.gender,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF9E9E9E),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Availability badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: therapist.availabilityStatus
                                  ? const Color(
                                      0xFF4CAF50,
                                    ).withValues(alpha: 0.1)
                                  : const Color(
                                      0xFFF59E0B,
                                    ).withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: therapist.availabilityStatus
                                        ? const Color(0xFF4CAF50)
                                        : const Color(0xFFF59E0B),
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  therapist.availabilityStatus
                                      ? 'Available'
                                      : 'Unavailable',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: therapist.availabilityStatus
                                        ? const Color(0xFF4CAF50)
                                        : const Color(0xFFF59E0B),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.phone_outlined,
                            size: 14,
                            color: Color(0xFF9E9E9E),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            therapist.phone,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF9E9E9E),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (showInlineEdit) ...[
                  const SizedBox(width: 16),
                  OutlinedButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(
                      Icons.edit_outlined,
                      size: 16,
                      color: Color(0xFF1B6B72),
                    ),
                    label: const Text(
                      'Edit',
                      style: TextStyle(color: Color(0xFF1B6B72)),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF1B6B72)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 12),

          // -- Stats row --------------------------------------
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  icon: Icons.check_circle_outline,
                  iconBg: const Color(0xFFE8F5E9),
                  iconColor: const Color(0xFF4CAF50),
                  label: 'Done Today',
                  value: '${therapist.totalAppointments}',
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // -- Therapist info ---------------------------------
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Staff Information',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                const SizedBox(height: 16),
                _InfoRow(label: 'Join Date', value: therapist.joinDate),
                _InfoRow(label: 'Role', value: therapist.role),
                _InfoRow(label: 'Phone Number', value: therapist.phone),
                _InfoRow(
                  label: 'Gender',
                  value: therapist.gender,
                  isLast: true,
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // -- Notes ------------------------------------------
          _StaffCommissionSection(staff: therapist),

          const SizedBox(height: 12),

          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Icon(
                      Icons.article_outlined,
                      size: 18,
                      color: Color(0xFF9E9E9E),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Notes',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  therapist.notes.isEmpty ? 'No notes added.' : therapist.notes,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF6B6B6B),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),

          // Delete button — admin only
          if (isAdmin) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: onDelete,
                icon: const Icon(
                  Icons.delete_outline,
                  color: Color(0xFFE53935),
                  size: 18,
                ),
                label: const Text(
                  'Remove Staff',
                  style: TextStyle(
                    color: Color(0xFFE53935),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: Color(0xFFE53935)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------
// SHARED SMALL WIDGETS
// -----------------------------------------------------------------
class _StaffServiceCommission {
  final String id;
  final String name;
  final String category;
  final int duration;
  final double price;
  final double therapistCommission;
  final double counterCommission;

  const _StaffServiceCommission({
    required this.id,
    required this.name,
    required this.category,
    required this.duration,
    required this.price,
    required this.therapistCommission,
    required this.counterCommission,
  });

  factory _StaffServiceCommission.fromMap(Map<String, dynamic> data) {
    return _StaffServiceCommission(
      id: data['id']?.toString() ?? '',
      name: data['name']?.toString() ?? 'Service',
      category: _normalizeServiceCategory(data['category']?.toString() ?? ''),
      duration: _intValue(data['duration'], 60),
      price: _doubleValue(data['price']),
      therapistCommission: _doubleValue(data['therapistCommission']),
      counterCommission: _doubleValue(data['counterCommission']),
    );
  }

  double defaultCommissionFor(String staffRole) {
    return _normalizeStaffRole(staffRole) == 'Counter'
        ? counterCommission
        : therapistCommission;
  }
}

int _intValue(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

double _doubleValue(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

String _normalizeServiceCategory(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.contains('package')) return 'Packages';
  if (normalized.contains('add')) return 'Add-ons';
  return 'Services';
}

class _StaffCommissionSection extends StatefulWidget {
  final TherapistModel staff;

  const _StaffCommissionSection({required this.staff});

  @override
  State<_StaffCommissionSection> createState() =>
      _StaffCommissionSectionState();
}

class _StaffCommissionSectionState extends State<_StaffCommissionSection> {
  final _serviceRepository = ServiceRepository();
  final _therapistRepository = TherapistRepository();
  final _tabs = const ['Services', 'Packages', 'Add-ons'];
  var _selectedTab = 'Services';
  var _services = <_StaffServiceCommission>[];
  late Map<String, double> _overrides;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _overrides = {...widget.staff.serviceCommissions};
    _loadServices();
  }

  @override
  void didUpdateWidget(covariant _StaffCommissionSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.staff.id != widget.staff.id) {
      _overrides = {...widget.staff.serviceCommissions};
      _selectedTab = 'Services';
      _loadServices();
    }
  }

  Future<void> _loadServices() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _serviceRepository.getServices();
      final staffRow = await _therapistRepository.getTherapist(widget.staff.id);
      final services =
          rows
              .map(_StaffServiceCommission.fromMap)
              .where((service) => service.id.isNotEmpty)
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      if (!mounted) return;
      setState(() {
        _services = services;
        _overrides = staffRow == null
            ? {...widget.staff.serviceCommissions}
            : TherapistModel._commissionMap(staffRow['serviceCommissions']);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  double _commissionFor(_StaffServiceCommission service) {
    return _overrides[service.id] ??
        service.defaultCommissionFor(widget.staff.role);
  }

  Future<void> _openCommissionEditor(_StaffServiceCommission service) async {
    final result = await showDialog<_CommissionEditResult>(
      context: context,
      builder: (context) => _CommissionEditorDialog(
        service: service,
        staff: widget.staff,
        currentCommission: _commissionFor(service),
        hasOverride: _overrides.containsKey(service.id),
      ),
    );
    if (result == null) return;

    final updated = {..._overrides};
    if (result.useDefault) {
      updated.remove(service.id);
    } else {
      updated[service.id] = result.commission;
    }

    await _therapistRepository.updateTherapist(widget.staff.id, {
      'serviceCommissions': updated,
    });
    if (!mounted) return;
    setState(() => _overrides = updated);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _services
        .where((service) => service.category == _selectedTab)
        .toList();

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Commission',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: _tabs
                .map(
                  (tab) => _CommissionTabButton(
                    label: tab,
                    selected: _selectedTab == tab,
                    onTap: () => setState(() => _selectedTab = tab),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 10),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFF1B6B72)),
              ),
            )
          else if (_error != null)
            Text(
              'Unable to load services',
              style: TextStyle(
                color: Colors.red.shade600,
                fontWeight: FontWeight.w600,
              ),
            )
          else if (filtered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text(
                'No services in this category.',
                style: TextStyle(color: Color(0xFF9E9E9E)),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 540
                    ? 3
                    : constraints.maxWidth >= 360
                    ? 2
                    : 1;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: columns == 1 ? 4.8 : 3.25,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (_, index) {
                    final service = filtered[index];
                    return _StaffCommissionServiceCard(
                      service: service,
                      commission: _commissionFor(service),
                      hasOverride: _overrides.containsKey(service.id),
                      onTap: () => _openCommissionEditor(service),
                    );
                  },
                );
              },
            ),
        ],
      ),
    );
  }
}

class _CommissionTabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CommissionTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 18),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected
                      ? const Color(0xFF1B6B72)
                      : const Color(0xFF9E9E9E),
                ),
              ),
              const SizedBox(height: 4),
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 2,
                width: selected ? 36 : 0,
                color: const Color(0xFF1B6B72),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StaffCommissionServiceCard extends StatelessWidget {
  final _StaffServiceCommission service;
  final double commission;
  final bool hasOverride;
  final VoidCallback onTap;

  const _StaffCommissionServiceCard({
    required this.service,
    required this.commission,
    required this.hasOverride,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5F5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.spa_outlined,
                  color: Color(0xFF1B6B72),
                  size: 16,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      service.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${service.duration}m - RM ${service.price.toStringAsFixed(0)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF9E9E9E),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'RM ${commission.toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1B6B72),
                    ),
                  ),
                  if (hasOverride)
                    const Text(
                      'Custom',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFD19A33),
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

class _CommissionEditResult {
  final double commission;
  final bool useDefault;

  const _CommissionEditResult({
    required this.commission,
    this.useDefault = false,
  });
}

class _CommissionEditorDialog extends StatefulWidget {
  final _StaffServiceCommission service;
  final TherapistModel staff;
  final double currentCommission;
  final bool hasOverride;

  const _CommissionEditorDialog({
    required this.service,
    required this.staff,
    required this.currentCommission,
    required this.hasOverride,
  });

  @override
  State<_CommissionEditorDialog> createState() =>
      _CommissionEditorDialogState();
}

class _CommissionEditorDialogState extends State<_CommissionEditorDialog> {
  late final TextEditingController _commission;

  @override
  void initState() {
    super.initState();
    _commission = TextEditingController(
      text: widget.currentCommission.toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _commission.dispose();
    super.dispose();
  }

  void _save() {
    final value = double.tryParse(_commission.text.trim()) ?? 0;
    Navigator.of(context).pop(_CommissionEditResult(commission: value));
  }

  void _useDefault() {
    Navigator.of(context).pop(
      _CommissionEditResult(
        commission: widget.service.defaultCommissionFor(widget.staff.role),
        useDefault: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final defaultCommission = widget.service.defaultCommissionFor(
      widget.staff.role,
    );
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.service.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _InfoRow(
                label: 'Price',
                value: 'RM ${widget.service.price.toStringAsFixed(2)}',
              ),
              _InfoRow(
                label: 'Time',
                value: '${widget.service.duration} minutes',
              ),
              _InfoRow(
                label: 'Service Default',
                value: 'RM ${defaultCommission.toStringAsFixed(2)}',
              ),
              _InfoRow(
                label: 'Staff',
                value: '${widget.staff.name} - ${widget.staff.role}',
                isLast: true,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _commission,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Staff Commission',
                  prefixText: 'RM ',
                  filled: true,
                  fillColor: const Color(0xFFF7F8FA),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: Color(0xFF1B6B72),
                      width: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (widget.hasOverride) ...[
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: _useDefault,
                    child: const Text('Use Service Default'),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: const Color(0xFFF1F3F6),
                        foregroundColor: const Color(0xFF1A1A2E),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _save,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: const Color(0xFF1B6B72),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('Save'),
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

class _TherapistFormDialog extends StatefulWidget {
  final TherapistModel? therapist;
  final String defaultJoinDate;

  const _TherapistFormDialog({this.therapist, required this.defaultJoinDate});

  @override
  State<_TherapistFormDialog> createState() => _TherapistFormDialogState();
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  const _CircleIconButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
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
        color: const Color(0xFF1B6B72),
        style: IconButton.styleFrom(
          backgroundColor: const Color(0xFFE8F5F5),
          shape: const CircleBorder(),
        ),
      ),
    );
  }
}

class _TabletDetailHeader extends StatelessWidget {
  final String title;
  final String addLabel;
  final VoidCallback onAdd;

  const _TabletDetailHeader({
    required this.title,
    required this.addLabel,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 76,
      padding: const EdgeInsets.symmetric(horizontal: 30),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE6E8EB))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A2E),
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: Text(addLabel),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF1B6B72),
              side: const BorderSide(color: Color(0xFF1B6B72)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TherapistFormDialogState extends State<_TherapistFormDialog> {
  final _therapistRepository = TherapistRepository();
  final _imageUploadRepository = ImageUploadRepository();
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _genderController;
  late final TextEditingController _roleController;
  late final TextEditingController _joinDateController;
  late final TextEditingController _notesController;
  late bool _availabilityStatus;
  SelectedImage? _imagePreview;
  bool _imageRemoved = false;
  bool _saving = false;
  bool _closing = false;

  bool get _isEditing => widget.therapist != null;

  @override
  void initState() {
    super.initState();
    final therapist = widget.therapist;
    _nameController = TextEditingController(text: therapist?.name ?? '');
    _phoneController = TextEditingController(text: therapist?.phone ?? '');
    _genderController = TextEditingController(text: therapist?.gender ?? '');
    _roleController = TextEditingController(
      text: therapist?.role ?? 'Therapist',
    );
    _joinDateController = TextEditingController(
      text: therapist?.joinDate ?? widget.defaultJoinDate,
    );
    _notesController = TextEditingController(text: therapist?.notes ?? '');
    _availabilityStatus = therapist?.availabilityStatus ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _genderController.dispose();
    _roleController.dispose();
    _joinDateController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || _closing) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    final data = {
      'name': _nameController.text.trim(),
      'phone': _phoneController.text.trim(),
      'gender': _genderController.text.trim(),
      'role': _normalizeStaffRole(_roleController.text),
      'joinDate': _joinDateController.text.trim(),
      'availabilityStatus': _availabilityStatus,
      'notes': _notesController.text.trim(),
      if (_imageRemoved) 'profileImageUrl': '',
    };

    try {
      late final String therapistId;
      late Map<String, dynamic> savedRow;
      if (_isEditing) {
        therapistId = widget.therapist!.id;
        savedRow = await _therapistRepository.updateTherapist(
          therapistId,
          data,
        );
      } else {
        savedRow = await _therapistRepository.addTherapist(data);
        therapistId = savedRow['id']?.toString() ?? '';
      }

      var profileImageUrl =
          (savedRow['profileImageUrl'] ??
                  widget.therapist?.profileImageUrl ??
                  '')
              .toString();
      final previousUrl = widget.therapist?.profileImageUrl ?? '';
      if (_imagePreview != null && therapistId.isNotEmpty) {
        profileImageUrl = await _imageUploadRepository.uploadImage(
          image: _imagePreview!,
          folder: 'therapists',
          id: therapistId,
          previousUrl: previousUrl,
        );
        savedRow = await _therapistRepository.updateTherapist(therapistId, {
          'profileImageUrl': profileImageUrl,
        });
      } else if (_imageRemoved && previousUrl.trim().isNotEmpty) {
        await _imageUploadRepository.removePublicUrl(previousUrl);
      }

      final savedCommissions = savedRow.containsKey('serviceCommissions')
          ? TherapistModel._commissionMap(savedRow['serviceCommissions'])
          : widget.therapist?.serviceCommissions ?? {};
      final savedTherapist = TherapistModel(
        id: therapistId,
        name: (savedRow['name'] ?? data['name'])!.toString(),
        phone: (savedRow['phone'] ?? data['phone'])!.toString(),
        gender: (savedRow['gender'] ?? data['gender'])!.toString(),
        role: _normalizeStaffRole(savedRow['role'] ?? data['role']),
        joinDate: (savedRow['joinDate'] ?? data['joinDate'])!.toString(),
        availabilityStatus: TherapistModel._boolValue(
          savedRow['availabilityStatus'] ?? data['availabilityStatus'],
        ),
        notes: (savedRow['notes'] ?? data['notes'])!.toString(),
        profileImageUrl: profileImageUrl,
        serviceCommissions: savedCommissions,
        totalAppointments: widget.therapist?.totalAppointments ?? 0,
      );

      _close(savedTherapist);
    } catch (e) {
      debugPrint('Unable to save staff: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to save staff: $e'),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _pickImage() async {
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
    setState(() {
      _imagePreview = null;
      _imageRemoved = true;
    });
  }

  void _close([TherapistModel? result]) {
    if (_closing || !mounted) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final previewTherapist = TherapistModel(
      id: widget.therapist?.id ?? '',
      name: _nameController.text.trim().isEmpty
          ? 'Staff'
          : _nameController.text.trim(),
      phone: _phoneController.text.trim(),
      gender: _genderController.text.trim(),
      role: _normalizeStaffRole(_roleController.text),
      joinDate: _joinDateController.text.trim(),
      availabilityStatus: _availabilityStatus,
      notes: _notesController.text.trim(),
      profileImageUrl: _imageRemoved
          ? ''
          : widget.therapist?.profileImageUrl ?? '',
      serviceCommissions: widget.therapist?.serviceCommissions ?? {},
    );
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
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
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _saving ? null : () => _close(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      _Avatar(
                        therapist: previewTherapist,
                        radius: 36,
                        preview: _imagePreview,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _saving ? null : _pickImage,
                              icon: const Icon(Icons.upload_outlined),
                              label: Text(
                                _imagePreview == null &&
                                        (widget.therapist?.profileImageUrl ??
                                                '')
                                            .trim()
                                            .isEmpty
                                    ? 'Upload Photo'
                                    : 'Replace Photo',
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed:
                                  !_saving &&
                                      !_imageRemoved &&
                                      (_imagePreview != null ||
                                          (widget.therapist?.profileImageUrl ??
                                                  '')
                                              .trim()
                                              .isNotEmpty)
                                  ? _removeImage
                                  : null,
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('Remove Photo'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _TherapistFormField(
                    label: 'Name',
                    controller: _nameController,
                    requiredField: true,
                  ),
                  const SizedBox(height: 14),
                  _TherapistFormField(
                    label: 'Phone',
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    requiredField: true,
                  ),
                  const SizedBox(height: 14),
                  _TherapistGenderDropdown(
                    label: 'Gender',
                    controller: _genderController,
                  ),
                  const SizedBox(height: 14),
                  _StaffRoleDropdown(
                    label: 'Role',
                    controller: _roleController,
                  ),
                  const SizedBox(height: 14),
                  _TherapistFormField(
                    label: 'Join Date',
                    controller: _joinDateController,
                    hint: 'YYYY-MM-DD',
                    keyboardType: TextInputType.datetime,
                  ),
                  const SizedBox(height: 14),
                  CheckboxListTile(
                    value: _availabilityStatus,
                    onChanged: _saving
                        ? null
                        : (value) => setState(
                            () => _availabilityStatus = value ?? true,
                          ),
                    contentPadding: EdgeInsets.zero,
                    activeColor: const Color(0xFF1B6B72),
                    title: const Text('Available'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                  const SizedBox(height: 14),
                  _TherapistFormField(
                    label: 'Notes',
                    controller: _notesController,
                    maxLines: 4,
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: _saving ? null : () => _close(),
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
                              : Text(_isEditing ? 'Save Changes' : 'Add Staff'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TherapistFormField extends StatelessWidget {
  final String label;
  final String? hint;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final bool requiredField;
  final int maxLines;

  const _TherapistFormField({
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

class _TherapistGenderDropdown extends StatelessWidget {
  final String label;
  final TextEditingController controller;

  const _TherapistGenderDropdown({
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

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  const _SearchBar({required this.controller});

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
          color: Color(0xFF1A1A2E),
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
        decoration: const InputDecoration(
          hintText: 'Search staff...',
          hintStyle: TextStyle(
            color: Color(0xFF64748B),
            fontWeight: FontWeight.w700,
          ),
          prefixIcon: Icon(Icons.search, color: Color(0xFF475569), size: 20),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final TherapistModel therapist;
  final double radius;
  final SelectedImage? preview;

  const _Avatar({required this.therapist, required this.radius, this.preview});

  @override
  Widget build(BuildContext context) {
    final imageUrl = therapist.profileImageUrl.trim();
    final hasImage = preview != null || imageUrl.isNotEmpty;
    return ClipOval(
      child: Container(
        width: radius * 2,
        height: radius * 2,
        color: hasImage ? Colors.transparent : therapist.avatarColor,
        alignment: Alignment.center,
        child: preview != null
            ? Image.memory(
                preview!.bytes,
                width: radius * 2,
                height: radius * 2,
                fit: BoxFit.cover,
              )
            : imageUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: imageUrl,
                width: radius * 2,
                height: radius * 2,
                fit: BoxFit.cover,
                placeholder: (_, _) =>
                    _AvatarInitials(therapist: therapist, radius: radius),
                errorWidget: (_, _, _) =>
                    _AvatarInitials(therapist: therapist, radius: radius),
              )
            : _AvatarInitials(therapist: therapist, radius: radius),
      ),
    );
  }
}

class _AvatarInitials extends StatelessWidget {
  final TherapistModel therapist;
  final double radius;

  const _AvatarInitials({required this.therapist, required this.radius});

  @override
  Widget build(BuildContext context) {
    return Text(
      therapist.initials,
      style: TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.bold,
        fontSize: radius * 0.7,
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
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
      child: child,
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String label;
  final String value;

  const _StatCard({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
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
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: iconColor, size: 16),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A2E),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isLast;

  const _InfoRow({
    required this.label,
    required this.value,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 14, color: Color(0xFF9E9E9E)),
              ),
              Flexible(
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!isLast) const Divider(height: 1, color: Color(0xFFF0F0F0)),
      ],
    );
  }
}
