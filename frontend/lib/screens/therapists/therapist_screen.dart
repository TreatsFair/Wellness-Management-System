import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// ── Data model ────────────────────────────────────────────────────
class TherapistModel {
  final String id;
  final String name;
  final String phone;
  final String gender;
  final String employmentType;
  final String joinDate;
  final bool   availabilityStatus;
  final String notes;

  // Calculated
  final int    totalAppointments;

  const TherapistModel({
    required this.id,
    required this.name,
    required this.phone,
    required this.gender,
    required this.employmentType,
    required this.joinDate,
    required this.availabilityStatus,
    required this.notes,
    this.totalAppointments = 0,
  });

  static String _stringValue(dynamic value) {
    if (value == null) return '';
    if (value is Timestamp) {
      final date = value.toDate();
      final month = date.month.toString().padLeft(2, '0');
      final day = date.day.toString().padLeft(2, '0');
      return '${date.year}-$month-$day';
    }
    return value.toString();
  }

  static bool _boolValue(dynamic value) {
    if (value is bool) return value;
    if (value is String) return value.toLowerCase().trim() == 'true';
    return true;
  }

  factory TherapistModel.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return TherapistModel(
      id:                 doc.id,
      name:               _stringValue(d['name']),
      phone:              _stringValue(d['phone']),
      gender:             _stringValue(d['gender']),
      employmentType:     _stringValue(d['employmentType']),
      joinDate:           _stringValue(d['joinDate']),
      availabilityStatus: _boolValue(d['availabilityStatus']),
      notes:              _stringValue(d['notes']),
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
  }) {
    return TherapistModel(
      id:                 id,
      name:               name,
      phone:              phone,
      gender:             gender,
      employmentType:     employmentType,
      joinDate:           joinDate,
      availabilityStatus: availabilityStatus,
      notes:              notes,
      totalAppointments:  totalAppointments ?? this.totalAppointments,
    );
  }
}

// ── Main screen ───────────────────────────────────────────────────
class TherapistsScreen extends StatefulWidget {
  final String userRole;
  const TherapistsScreen({super.key, required this.userRole});

  @override
  State<TherapistsScreen> createState() => _TherapistsScreenState();
}

class _TherapistsScreenState extends State<TherapistsScreen> {
  List<TherapistModel> _therapists = [];
  List<TherapistModel> _filtered   = [];
  TherapistModel?      _selected;
  bool                 _loading    = true;
  final _searchController          = TextEditingController();

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
      final snapshot = await FirebaseFirestore.instance
          .collection('therapists')
          .orderBy('name')
          .get();

      final therapists = snapshot.docs
          .map((doc) => TherapistModel.fromFirestore(doc))
          .toList();

      final enriched = await Future.wait(
        therapists.map((t) => _enrichTherapist(t)),
      );

      setState(() {
        _therapists = enriched;
        _filtered   = enriched;
        _loading    = false;
        if (enriched.isNotEmpty) _selected = enriched.first;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  Future<TherapistModel> _enrichTherapist(TherapistModel t) async {
    try {
      // Total completed appointments
      final today = _todayString();
      final todaySnap = await FirebaseFirestore.instance
          .collection('appointments')
          .where('therapistId', isEqualTo: t.id)
          .where('status', isEqualTo: 'completed')
          .where('date', isEqualTo: today)
          .get();

      // This month


      // Last session — most recent appointment
      return t.copyWith(
        totalAppointments: todaySnap.docs.length,
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
      final existingIndex =
          _therapists.indexWhere((t) => t.id == savedTherapist.id);
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
               t.phone.toLowerCase().contains(query);
      }).toList();
      _selected = savedTherapist;
    });

    return savedTherapist;
  }

  Future<bool> _deleteTherapist(TherapistModel therapist) async {
    final firstConfirm = await _confirmDeleteTherapist(
      title: 'Remove Therapist',
      message: 'This will remove ${therapist.name} from the therapist list.',
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
      await FirebaseFirestore.instance
          .collection('therapists')
          .doc(therapist.id)
          .delete();

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
          content: Text('Unable to remove therapist'),
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
               t.phone.toLowerCase().contains(query);
      }).toList();
    });
  }

  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 600;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F0F0),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF1B6B72),
                ))
            : _isTablet(context)
                ? _TabletLayout(
                    therapists:       _filtered,
                    selected:         _selected,
                    searchController: _searchController,
                    isAdmin:          _isAdmin,
                    onSelect:         (t) => setState(() => _selected = t),
                    onRefresh:        _loadTherapists,
                    onAdd:            () => _openTherapistForm(),
                    onEdit:           (t) => _openTherapistForm(therapist: t),
                    onDelete:         _deleteTherapist,
                  )
                : _PhoneLayout(
                    therapists:       _filtered,
                    searchController: _searchController,
                    isAdmin:          _isAdmin,
                    onRefresh:        _loadTherapists,
                    onAdd:            () => _openTherapistForm(),
                    onEdit:           (t) => _openTherapistForm(therapist: t),
                    onDelete:         _deleteTherapist,
                  ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// TABLET LAYOUT
// ─────────────────────────────────────────────────────────────────
class _TabletLayout extends StatelessWidget {
  final List<TherapistModel> therapists;
  final TherapistModel?      selected;
  final TextEditingController searchController;
  final bool                 isAdmin;
  final Function(TherapistModel) onSelect;
  final VoidCallback         onRefresh;
  final VoidCallback         onAdd;
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
          width: 320,
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
                      child: Text('Therapists',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize:   18,
                          fontWeight: FontWeight.bold,
                          color:      Color(0xFF1A1A2E),
                        )),
                    ),
                    const SizedBox(width: 36, height: 36),
                  ],
                ),
              ),

              // Search
              Padding(
                padding: const EdgeInsets.all(12),
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
                      therapist:  therapists[i],
                      isSelected: selected?.id == therapists[i].id,
                      onTap:      () => onSelect(therapists[i]),
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
                title: 'Therapist Details',
                addLabel: 'Add Therapist',
                onAdd: onAdd,
              ),
              Expanded(
                child: selected == null
                    ? const Center(
                        child: Text(
                          'Select a therapist to view details',
                          style: TextStyle(color: Color(0xFF9E9E9E)),
                        ),
                      )
                    : _DetailPanel(
                        therapist: selected!,
                        isAdmin:   isAdmin,
                        onEdit:    () => onEdit(selected!),
                        onDelete:  () => onDelete(selected!),
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
  final bool           isSelected;
  final VoidCallback   onTap;

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
        margin:  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                  Text(therapist.name,
                    style: const TextStyle(
                      fontSize:   14,
                      fontWeight: FontWeight.w600,
                      color:      Color(0xFF1A1A2E),
                    )),
                  Row(children: [
                    Container(
                      width: 7, height: 7,
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
                      )),
                  ]),
                ],
              ),
            ),
            Text('${therapist.totalAppointments} done today',
              style: const TextStyle(
                fontSize: 11,
                color:    Color(0xFF9E9E9E),
              )),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// PHONE LAYOUT
// ─────────────────────────────────────────────────────────────────
class _PhoneLayout extends StatelessWidget {
  final List<TherapistModel>  therapists;
  final TextEditingController searchController;
  final bool                  isAdmin;
  final VoidCallback          onRefresh;
  final VoidCallback          onAdd;
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
    final horizontalPadding =
        MediaQuery.of(context).size.width < 360 ? 12.0 : 16.0;

    return Column(
      children: [
        // Header
        Container(
          color:   Colors.white,
          padding: EdgeInsets.fromLTRB(4, 12, horizontalPadding, 12),
          child: Row(
            children: [
              const BackButton(),
              const Expanded(
                child: Text('Therapists',
                  textAlign: TextAlign.start,
                  style: TextStyle(
                    fontSize:   18,
                    fontWeight: FontWeight.w700,
                    color:      Color(0xFF1A1A2E),
                  )),
              ),
              Container(
                  width: 36, height: 36,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFF1B6B72),
                  ),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.add,
                      color: Colors.white, size: 20),
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
            12,
            horizontalPadding,
            12,
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
                      isAdmin:   isAdmin,
                      onEdit:    onEdit,
                      onDelete:  onDelete,
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
  final VoidCallback   onTap;

  const _PhoneListCard({
    required this.therapist,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin:  const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color:        Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color:      Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset:     const Offset(0, 2),
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
                      Text(therapist.name,
                        style: const TextStyle(
                          fontSize:   15,
                          fontWeight: FontWeight.w600,
                          color:      Color(0xFF1A1A2E),
                        )),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${therapist.totalAppointments} done today',
                      style: const TextStyle(
                        fontSize:   13,
                        fontWeight: FontWeight.bold,
                        color:      Color(0xFF1B6B72),
                      )),
                    const SizedBox(height: 4),
                    Row(children: [
                      Container(
                        width: 7, height: 7,
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
                        )),
                    ]),
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
  final bool           isAdmin;
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
      backgroundColor: const Color(0xFFF0F0F0),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation:       0,
        leading:         const BackButton(color: Color(0xFF1A1A2E)),
        centerTitle: true,
        title: const Text('Therapist Details',
          style: TextStyle(
            fontSize:   18,
            fontWeight: FontWeight.w700,
            color:      Color(0xFF1A1A2E),
          )),
        actions: [
          _CircleIconButton(
            icon: Icons.edit_outlined,
            tooltip: 'Edit therapist',
            onPressed: _editAndReturn,
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(MediaQuery.of(context).size.width < 360 ? 12 : 16),
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

// ─────────────────────────────────────────────────────────────────
// DETAIL PANEL — shared between tablet and phone
// ─────────────────────────────────────────────────────────────────
class _DetailPanel extends StatelessWidget {
  final TherapistModel therapist;
  final bool           isAdmin;
  final VoidCallback   onEdit;
  final VoidCallback   onDelete;
  final bool           showTabletHeader;
  final bool           showInlineEdit;

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
    final isTablet = MediaQuery.of(context).size.width >= 600;

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
                  const Text('Therapist Details',
                    style: TextStyle(
                      fontSize:   22,
                      fontWeight: FontWeight.bold,
                      color:      Color(0xFF1A1A2E),
                    )),
                  OutlinedButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined,
                      size: 16, color: Color(0xFF1B6B72)),
                    label: const Text('Edit',
                      style: TextStyle(color: Color(0xFF1B6B72))),
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

          // ── Profile card ────────────────────────────────────
          _Card(
            child: Row(
              children: [
                _Avatar(therapist: therapist, radius: 32),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(therapist.name,
                        style: const TextStyle(
                          fontSize:   20,
                          fontWeight: FontWeight.bold,
                          color:      Color(0xFF1A1A2E),
                        )),
                      const SizedBox(height: 6),
                      Row(children: [
                        const Icon(Icons.transgender,
                          size: 14, color: Color(0xFF9E9E9E)),
                        const SizedBox(width: 4),
                        Text(therapist.gender,
                          style: const TextStyle(
                            fontSize: 13,
                            color:    Color(0xFF9E9E9E),
                          )),
                        const SizedBox(width: 12),
                        // Availability badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: therapist.availabilityStatus
                                ? const Color(0xFF4CAF50).withValues(alpha: 0.1)
                                : const Color(0xFFF59E0B).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(children: [
                            Container(
                              width: 6, height: 6,
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
                                fontSize:   11,
                                fontWeight: FontWeight.w600,
                                color: therapist.availabilityStatus
                                    ? const Color(0xFF4CAF50)
                                    : const Color(0xFFF59E0B),
                              )),
                          ]),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      Row(children: [
                        const Icon(Icons.phone_outlined,
                          size: 14, color: Color(0xFF9E9E9E)),
                        const SizedBox(width: 4),
                        Text(therapist.phone,
                          style: const TextStyle(
                            fontSize: 13,
                            color:    Color(0xFF9E9E9E),
                          )),
                      ]),
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

          // ── Stats row ──────────────────────────────────────
          Row(children: [
            Expanded(child: _StatCard(
              icon:      Icons.check_circle_outline,
              iconBg:    const Color(0xFFE8F5E9),
              iconColor: const Color(0xFF4CAF50),
              label:     'Done Today',
              value:     '${therapist.totalAppointments}',
            )),
          ]),

          const SizedBox(height: 12),

          // ── Therapist info ─────────────────────────────────
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Therapist Information',
                  style: TextStyle(
                    fontSize:   16,
                    fontWeight: FontWeight.bold,
                    color:      Color(0xFF1A1A2E),
                  )),
                const SizedBox(height: 16),
                _InfoRow(
                  label: 'Join Date',
                  value: therapist.joinDate,
                ),
                _InfoRow(
                  label: 'Employment',
                  value: therapist.employmentType,
                ),
                _InfoRow(
                  label: 'Phone Number',
                  value: therapist.phone,
                ),
                _InfoRow(
                  label: 'Gender',
                  value: therapist.gender,
                  isLast: true,
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── Notes ──────────────────────────────────────────
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: const [
                  Icon(Icons.article_outlined,
                    size: 18, color: Color(0xFF9E9E9E)),
                  SizedBox(width: 8),
                  Text('Notes',
                    style: TextStyle(
                      fontSize:   16,
                      fontWeight: FontWeight.bold,
                      color:      Color(0xFF1A1A2E),
                    )),
                ]),
                const SizedBox(height: 10),
                Text(
                  therapist.notes.isEmpty
                      ? 'No notes added.'
                      : therapist.notes,
                  style: const TextStyle(
                    fontSize: 14,
                    color:    Color(0xFF6B6B6B),
                    height:   1.5,
                  )),
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
                icon: const Icon(Icons.delete_outline,
                  color: Color(0xFFE53935), size: 18),
                label: const Text('Remove Therapist',
                  style: TextStyle(
                    color:      Color(0xFFE53935),
                    fontWeight: FontWeight.w500,
                  )),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side:    const BorderSide(color: Color(0xFFE53935)),
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

// ─────────────────────────────────────────────────────────────────
// SHARED SMALL WIDGETS
// ─────────────────────────────────────────────────────────────────
class _TherapistFormDialog extends StatefulWidget {
  final TherapistModel? therapist;
  final String defaultJoinDate;

  const _TherapistFormDialog({
    this.therapist,
    required this.defaultJoinDate,
  });

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
        border: Border(
          bottom: BorderSide(color: Color(0xFFE6E8EB)),
        ),
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
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _genderController;
  late final TextEditingController _employmentTypeController;
  late final TextEditingController _joinDateController;
  late final TextEditingController _notesController;
  late bool _availabilityStatus;
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
    _employmentTypeController = TextEditingController(
      text: therapist?.employmentType ?? '',
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
    _employmentTypeController.dispose();
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
      'employmentType': _employmentTypeController.text.trim(),
      'joinDate': _joinDateController.text.trim(),
      'availabilityStatus': _availabilityStatus,
      'notes': _notesController.text.trim(),
    };

    try {
      late final String therapistId;
      if (_isEditing) {
        therapistId = widget.therapist!.id;
        await FirebaseFirestore.instance
            .collection('therapists')
            .doc(therapistId)
            .set(data, SetOptions(merge: true));
      } else {
        final docRef = await FirebaseFirestore.instance
            .collection('therapists')
            .add(data);
        therapistId = docRef.id;
      }

      final savedTherapist = TherapistModel(
        id: therapistId,
        name: data['name']! as String,
        phone: data['phone']! as String,
        gender: data['gender']! as String,
        employmentType: data['employmentType']! as String,
        joinDate: data['joinDate']! as String,
        availabilityStatus: data['availabilityStatus']! as bool,
        notes: data['notes']! as String,
        totalAppointments: widget.therapist?.totalAppointments ?? 0,
      );

      _close(savedTherapist);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to save therapist'),
          backgroundColor: Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
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
                          _isEditing ? 'Edit Therapist' : 'Add Therapist',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed:
                            _saving ? null : () => _close(),
                        icon: const Icon(Icons.close),
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
                  _TherapistFormField(
                    label: 'Gender',
                    controller: _genderController,
                    hint: 'Female / Male',
                  ),
                  const SizedBox(height: 14),
                  _TherapistFormField(
                    label: 'Employment Type',
                    controller: _employmentTypeController,
                    hint: 'Full Time / Part Time',
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
                          onPressed: _saving
                              ? null
                              : () => _close(),
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
                              : Text(
                                  _isEditing
                                      ? 'Save Changes'
                                      : 'Add Therapist',
                                ),
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
          ? (value) =>
              value == null || value.trim().isEmpty ? '$label is required' : null
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

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  const _SearchBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A2E)),
      decoration: InputDecoration(
        hintText:   'Search therapists...',
        hintStyle:  const TextStyle(color: Color(0xFFBDBDBD), fontSize: 14),
        prefixIcon: const Icon(Icons.search,
          color: Color(0xFF9E9E9E), size: 20),
        filled:    true,
        fillColor: const Color(0xFFF5F5F5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:   BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16, vertical: 12,
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final TherapistModel therapist;
  final double         radius;
  const _Avatar({required this.therapist, required this.radius});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius:          radius,
      backgroundColor: therapist.avatarColor,
      child: Text(
        therapist.initials,
        style: TextStyle(
          color:      Colors.white,
          fontWeight: FontWeight.bold,
          fontSize:   radius * 0.7,
        )),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width:   double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset:     const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final Color    iconBg;
  final Color    iconColor;
  final String   label;
  final String   value;

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
        color:        Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color:      Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset:     const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color:        iconBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: iconColor, size: 16),
            ),
            const SizedBox(width: 8),
            Text(label,
              style: const TextStyle(
                fontSize: 12,
                color:    Color(0xFF9E9E9E),
              )),
          ]),
          const SizedBox(height: 8),
          Text(value,
            style: const TextStyle(
              fontSize:   18,
              fontWeight: FontWeight.bold,
              color:      Color(0xFF1A1A2E),
            )),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool   isLast;

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
              Text(label,
                style: const TextStyle(
                  fontSize: 14,
                  color:    Color(0xFF9E9E9E),
                )),
              Flexible(
                child: Text(value,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize:   14,
                    fontWeight: FontWeight.w500,
                    color:      Color(0xFF1A1A2E),
                  )),
              ),
            ],
          ),
        ),
        if (!isLast)
          const Divider(height: 1, color: Color(0xFFF0F0F0)),
      ],
    );
  }
}
