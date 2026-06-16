import 'package:flutter/material.dart';

import '../../data/repositories/customer_repository.dart';

DateTime _stripDate(DateTime date) => DateTime(date.year, date.month, date.day);

String _formatDate(DateTime date) {
  final clean = _stripDate(date);
  final month = clean.month.toString().padLeft(2, '0');
  final day = clean.day.toString().padLeft(2, '0');
  return '${clean.year}-$month-$day';
}

String _genderLabel(String gender) {
  final normalized = gender.trim().toLowerCase();
  if (normalized.startsWith('f')) return 'Female';
  if (normalized.startsWith('m')) return 'Male';
  return gender.trim();
}

// ── Data model ────────────────────────────────────────────────────
class CustomerModel {
  final String id;
  final String name;
  final String phone;
  final String gender;
  final String dateOfBirth;
  final String joinDate;
  final String notes;

  // Calculated fields — fetched separately
  final double totalSales;
  final int appointmentCount;
  final String lastVisit;

  const CustomerModel({
    required this.id,
    required this.name,
    required this.phone,
    required this.gender,
    required this.dateOfBirth,
    required this.joinDate,
    required this.notes,
    this.totalSales = 0,
    this.appointmentCount = 0,
    this.lastVisit = '-',
  });

  factory CustomerModel.fromMap(Map<String, dynamic> d) {
    return CustomerModel(
      id: d['id']?.toString() ?? '',
      name: d['name'] ?? '',
      phone: d['phone'] ?? '',
      gender: d['gender'] ?? '',
      dateOfBirth: d['dateOfBirth'] ?? '',
      joinDate: d['joinDate'] ?? '',
      notes: d['notes'] ?? '',
    );
  }

  int get age {
    if (dateOfBirth.isEmpty) return 0;
    try {
      final parts = dateOfBirth.split('-');
      final dob = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
      final now = DateTime.now();
      int age = now.year - dob.year;
      if (now.month < dob.month ||
          (now.month == dob.month && now.day < dob.day)) {
        age--;
      }
      return age;
    } catch (_) {
      return 0;
    }
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
      const Color(0xFFE91E8C),
      const Color(0xFF9C27B0),
      const Color(0xFF2196F3),
      const Color(0xFF4CAF50),
      const Color(0xFFFF5722),
      const Color(0xFF795548),
    ];
    return colors[name.length % colors.length];
  }

  CustomerModel copyWith({
    double? totalSales,
    int? appointmentCount,
    String? lastVisit,
  }) {
    return CustomerModel(
      id: id,
      name: name,
      phone: phone,
      gender: gender,
      dateOfBirth: dateOfBirth,
      joinDate: joinDate,
      notes: notes,
      totalSales: totalSales ?? this.totalSales,
      appointmentCount: appointmentCount ?? this.appointmentCount,
      lastVisit: lastVisit ?? this.lastVisit,
    );
  }
}

// ── Main screen — decides tablet vs phone ─────────────────────────
class CustomerScreen extends StatefulWidget {
  const CustomerScreen({super.key});

  @override
  State<CustomerScreen> createState() => _CustomerScreenState();
}

class _CustomerScreenState extends State<CustomerScreen> {
  final _customerRepository = CustomerRepository();
  List<CustomerModel> _customers = [];
  List<CustomerModel> _filtered = [];
  CustomerModel? _selected;
  bool _loading = true;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCustomers();
    _searchController.addListener(_onSearch);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ── Supabase fetch ──────────────────────────────────────────────
  Future<void> _loadCustomers() async {
    setState(() => _loading = true);
    try {
      final selectedId = _selected?.id;
      final rows = await _customerRepository.getCustomers();
      final customers = rows.map(CustomerModel.fromMap).toList();

      // Fetch calculated fields for each customer
      final enriched = await Future.wait(
        customers.map((c) => _enrichCustomer(c)),
      );

      setState(() {
        _customers = enriched;
        _filtered = enriched;
        _loading = false;
        if (enriched.isEmpty) {
          _selected = null;
        } else {
          _selected = enriched.firstWhere(
            (c) => c.id == selectedId,
            orElse: () => enriched.first,
          );
        }
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  // Fetch total sales, appointment count, last visit per customer
  Future<CustomerModel> _enrichCustomer(CustomerModel c) async {
    try {
      final stats = await _customerRepository.getCustomerAppointmentStats(c.id);

      return c.copyWith(
        totalSales: (stats['totalSales'] as num?)?.toDouble() ?? 0,
        appointmentCount: stats['appointmentCount'] as int? ?? 0,
        lastVisit: stats['lastVisit']?.toString() ?? '-',
      );
    } catch (_) {
      return c;
    }
  }

  void _onSearch() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filtered = _customers.where((c) {
        return c.name.toLowerCase().contains(query) ||
            c.phone.toLowerCase().contains(query);
      }).toList();
    });
  }

  void _selectCustomer(CustomerModel customer) {
    setState(() => _selected = customer);
  }

  String _todayString() {
    return _formatDate(DateTime.now());
  }

  Future<CustomerModel?> _openCustomerForm({CustomerModel? customer}) async {
    final savedCustomer = await showDialog<CustomerModel>(
      context: context,
      builder: (context) => _CustomerFormDialog(
        customer: customer,
        defaultJoinDate: _todayString(),
      ),
    );

    if (savedCustomer == null) return null;

    setState(() {
      final existingIndex = _customers.indexWhere(
        (c) => c.id == savedCustomer.id,
      );
      if (existingIndex == -1) {
        _customers = [..._customers, savedCustomer];
      } else {
        _customers = [
          ..._customers.take(existingIndex),
          savedCustomer,
          ..._customers.skip(existingIndex + 1),
        ];
      }
      _customers.sort((a, b) => a.name.compareTo(b.name));

      final query = _searchController.text.toLowerCase();
      _filtered = _customers.where((c) {
        return c.name.toLowerCase().contains(query) ||
            c.phone.toLowerCase().contains(query);
      }).toList();
      _selected = savedCustomer;
    });

    return savedCustomer;
  }

  bool _isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 900;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F0F0),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF1B6B72)),
              )
            : _isTablet(context)
            ? _TabletLayout(
                customers: _filtered,
                selected: _selected,
                searchController: _searchController,
                onSelect: _selectCustomer,
                onRefresh: _loadCustomers,
                onAdd: () => _openCustomerForm(),
                onEdit: (c) => _openCustomerForm(customer: c),
              )
            : _PhoneLayout(
                customers: _filtered,
                searchController: _searchController,
                onRefresh: _loadCustomers,
                onAdd: () => _openCustomerForm(),
                onEdit: (c) => _openCustomerForm(customer: c),
              ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// TABLET LAYOUT — left list, right detail panel
// ─────────────────────────────────────────────────────────────────
class _TabletLayout extends StatelessWidget {
  final List<CustomerModel> customers;
  final CustomerModel? selected;
  final TextEditingController searchController;
  final Function(CustomerModel) onSelect;
  final VoidCallback onRefresh;
  final VoidCallback onAdd;
  final Future<CustomerModel?> Function(CustomerModel) onEdit;

  const _TabletLayout({
    required this.customers,
    required this.selected,
    required this.searchController,
    required this.onSelect,
    required this.onRefresh,
    required this.onAdd,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left — member list
        Container(
          width: 320,
          color: Colors.white,
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    const BackButton(),
                    const Expanded(
                      child: Text(
                        'Members',
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
                padding: const EdgeInsets.all(12),
                child: _SearchBar(controller: searchController),
              ),

              // List
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async => onRefresh(),
                  color: const Color(0xFF1B6B72),
                  child: ListView.builder(
                    itemCount: customers.length,
                    itemBuilder: (_, i) => _TabletListItem(
                      customer: customers[i],
                      isSelected: selected?.id == customers[i].id,
                      onTap: () => onSelect(customers[i]),
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
                title: 'Member Details',
                addLabel: 'Add Member',
                onAdd: onAdd,
              ),
              Expanded(
                child: selected == null
                    ? const Center(
                        child: Text(
                          'Select a member to view details',
                          style: TextStyle(color: Color(0xFF9E9E9E)),
                        ),
                      )
                    : _DetailPanel(
                        customer: selected!,
                        onEdit: () => onEdit(selected!),
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
  final CustomerModel customer;
  final bool isSelected;
  final VoidCallback onTap;

  const _TabletListItem({
    required this.customer,
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
            _Avatar(customer: customer, radius: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        fit: FlexFit.loose,
                        child: Text(
                          customer.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                      ),
                      _GenderChip(gender: customer.gender),
                    ],
                  ),
                  Text(
                    customer.phone,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF9E9E9E),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    customer.lastVisit == '-'
                        ? 'No visits yet'
                        : customer.lastVisit,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9E9E9E),
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

// ─────────────────────────────────────────────────────────────────
// PHONE LAYOUT — list screen, tap to navigate to detail screen
// ─────────────────────────────────────────────────────────────────
class _PhoneLayout extends StatelessWidget {
  final List<CustomerModel> customers;
  final TextEditingController searchController;
  final VoidCallback onRefresh;
  final VoidCallback onAdd;
  final Future<CustomerModel?> Function(CustomerModel) onEdit;

  const _PhoneLayout({
    required this.customers,
    required this.searchController,
    required this.onRefresh,
    required this.onAdd,
    required this.onEdit,
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
                  'Members',
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
              itemCount: customers.length,
              itemBuilder: (_, i) => _PhoneListCard(
                customer: customers[i],
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => _PhoneDetailScreen(
                      customer: customers[i],
                      onEdit: onEdit,
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
  final CustomerModel customer;
  final VoidCallback onTap;

  const _PhoneListCard({required this.customer, required this.onTap});

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
                _Avatar(customer: customer, radius: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            fit: FlexFit.loose,
                            child: Text(
                              customer.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF1A1A2E),
                              ),
                            ),
                          ),
                          _GenderChip(gender: customer.gender),
                        ],
                      ),
                      Text(
                        customer.phone,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF9E9E9E),
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'RM ${customer.totalSales.toStringAsFixed(0)}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1B6B72),
                      ),
                    ),
                    Text(
                      '${customer.appointmentCount} visits',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF9E9E9E),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              customer.lastVisit == '-'
                  ? 'No visits yet'
                  : 'Last visit: ${customer.lastVisit}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
            ),
          ],
        ),
      ),
    );
  }
}

// Phone detail — separate full screen
class _PhoneDetailScreen extends StatefulWidget {
  final CustomerModel customer;
  final Future<CustomerModel?> Function(CustomerModel) onEdit;

  const _PhoneDetailScreen({required this.customer, required this.onEdit});

  @override
  State<_PhoneDetailScreen> createState() => _PhoneDetailScreenState();
}

class _PhoneDetailScreenState extends State<_PhoneDetailScreen> {
  late CustomerModel _customer;

  @override
  void initState() {
    super.initState();
    _customer = widget.customer;
  }

  Future<void> _editAndReturn(BuildContext context) async {
    final updatedCustomer = await widget.onEdit(_customer);
    if (updatedCustomer != null && mounted) {
      setState(() => _customer = updatedCustomer);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F0F0),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: const BackButton(color: Color(0xFF1A1A2E)),
        centerTitle: true,
        title: const Text(
          'Member Details',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A2E),
          ),
        ),
        actions: [
          _CircleIconButton(
            onPressed: () => _editAndReturn(context),
            icon: Icons.edit_outlined,
            tooltip: 'Edit member',
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(
          MediaQuery.of(context).size.width < 360 ? 12 : 16,
        ),
        child: _DetailPanel(
          customer: _customer,
          onEdit: () => _editAndReturn(context),
          showInlineEdit: false,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
// DETAIL PANEL — shared between tablet and phone detail screen
// ─────────────────────────────────────────────────────────────────
class _DetailPanel extends StatelessWidget {
  final CustomerModel customer;
  final VoidCallback? onEdit;
  final bool showTabletHeader;
  final bool showInlineEdit;

  const _DetailPanel({
    required this.customer,
    this.onEdit,
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
          if (isTablet && showTabletHeader)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Member Details',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                    color: const Color(0xFF1B6B72),
                    tooltip: 'Edit member',
                  ),
                ],
              ),
            ),

          // ── Profile card ──────────────────────────────────────
          _Card(
            child: Row(
              children: [
                _Avatar(customer: customer, radius: 32),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            fit: FlexFit.loose,
                            child: Text(
                              customer.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1A1A2E),
                              ),
                            ),
                          ),
                          _GenderChip(gender: customer.gender),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(
                            'Age: ${customer.age}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF9E9E9E),
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
                            customer.phone,
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

          // ── Stats row ─────────────────────────────────────────
          isTablet
              ? Row(
                  children: [
                    Expanded(
                      child: _StatCard(
                        icon: Icons.shopping_cart_outlined,
                        iconBg: const Color(0xFFE3F2FD),
                        iconColor: const Color(0xFF1B6B72),
                        label: 'Total Sales',
                        value: 'RM ${customer.totalSales.toStringAsFixed(0)}',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        icon: Icons.calendar_today_outlined,
                        iconBg: const Color(0xFFE8F5E9),
                        iconColor: const Color(0xFF1B6B72),
                        label: 'Appointments',
                        value: '${customer.appointmentCount}',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        icon: Icons.calendar_month_outlined,
                        iconBg: const Color(0xFFFFF3E0),
                        iconColor: const Color(0xFFF59E0B),
                        label: 'Last Visit',
                        value: customer.lastVisit,
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: _StatCard(
                        icon: Icons.shopping_cart_outlined,
                        iconBg: const Color(0xFFE3F2FD),
                        iconColor: const Color(0xFF1B6B72),
                        label: 'Total Sales',
                        value: 'RM ${customer.totalSales.toStringAsFixed(0)}',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        icon: Icons.calendar_today_outlined,
                        iconBg: const Color(0xFFE8F5E9),
                        iconColor: const Color(0xFF1B6B72),
                        label: 'Appointments',
                        value: '${customer.appointmentCount}',
                      ),
                    ),
                  ],
                ),

          const SizedBox(height: 12),

          // ── Member info ───────────────────────────────────────
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Member Information',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                const SizedBox(height: 16),
                _InfoRow(label: 'Join Date', value: customer.joinDate),
                _InfoRow(label: 'Last Visit', value: customer.lastVisit),
                _InfoRow(label: 'Phone Number', value: customer.phone),
                _InfoRow(label: 'Gender', value: _genderLabel(customer.gender)),
                _InfoRow(
                  label: 'Age',
                  value: '${customer.age} years',
                  isLast: true,
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── Notes ─────────────────────────────────────────────
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
                  customer.notes.isEmpty ? 'No notes added.' : customer.notes,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF6B6B6B),
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
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

// ─────────────────────────────────────────────────────────────────
// SHARED SMALL WIDGETS
// ─────────────────────────────────────────────────────────────────

class _CustomerFormDialog extends StatefulWidget {
  final CustomerModel? customer;
  final String defaultJoinDate;

  const _CustomerFormDialog({this.customer, required this.defaultJoinDate});

  @override
  State<_CustomerFormDialog> createState() => _CustomerFormDialogState();
}

class _CustomerFormDialogState extends State<_CustomerFormDialog> {
  final _customerRepository = CustomerRepository();
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _genderController;
  late final TextEditingController _dobController;
  late final TextEditingController _joinDateController;
  late final TextEditingController _notesController;
  bool _saving = false;
  bool _closing = false;

  bool get _isEditing => widget.customer != null;

  @override
  void initState() {
    super.initState();
    final customer = widget.customer;
    _nameController = TextEditingController(text: customer?.name ?? '');
    _phoneController = TextEditingController(text: customer?.phone ?? '');
    _genderController = TextEditingController(text: customer?.gender ?? '');
    _dobController = TextEditingController(text: customer?.dateOfBirth ?? '');
    _joinDateController = TextEditingController(
      text: customer?.joinDate ?? widget.defaultJoinDate,
    );
    _notesController = TextEditingController(text: customer?.notes ?? '');
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

  Future<void> _openFieldDatePicker(
    TextEditingController controller, {
    bool allowFutureDates = true,
  }) async {
    final today = _stripDate(DateTime.now());
    final initialDate = DateTime.tryParse(controller.text.trim()) ?? today;
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate.isAfter(today) && !allowFutureDates
          ? today
          : initialDate,
      firstDate: DateTime(1900),
      lastDate: allowFutureDates ? DateTime(today.year + 5, 12, 31) : today,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
              primary: const Color(0xFF1B6B72),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;
    controller.text = _formatDate(picked);
  }

  Future<void> _save() async {
    if (_saving || _closing) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    final dateOfBirth = _dobController.text.trim();
    final data = {
      'name': _nameController.text.trim(),
      'phone': _phoneController.text.trim(),
      'gender': _genderController.text.trim(),
      if (dateOfBirth.isNotEmpty) 'dateOfBirth': dateOfBirth,
      'joinDate': _joinDateController.text.trim(),
      'notes': _notesController.text.trim(),
    };

    try {
      late final String customerId;
      late final Map<String, dynamic> savedRow;
      if (_isEditing) {
        customerId = widget.customer!.id;
        savedRow = await _customerRepository.updateCustomer(customerId, data);
      } else {
        savedRow = await _customerRepository.addCustomer(data);
        customerId = savedRow['id']?.toString() ?? '';
      }

      final savedCustomer = CustomerModel(
        id: customerId,
        name: (savedRow['name'] ?? data['name'])!.toString(),
        phone: (savedRow['phone'] ?? data['phone'])!.toString(),
        gender: (savedRow['gender'] ?? data['gender'])!.toString(),
        dateOfBirth: (savedRow['dateOfBirth'] ?? dateOfBirth).toString(),
        joinDate: (savedRow['joinDate'] ?? data['joinDate'])!.toString(),
        notes: (savedRow['notes'] ?? data['notes'])!.toString(),
        totalSales: widget.customer?.totalSales ?? 0,
        appointmentCount: widget.customer?.appointmentCount ?? 0,
        lastVisit: widget.customer?.lastVisit ?? '-',
      );

      _close(savedCustomer);
    } catch (e) {
      debugPrint('Unable to save member: $e');
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to save member: $e'),
          backgroundColor: const Color(0xFFE53935),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _close([CustomerModel? result]) {
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
                          _isEditing ? 'Edit Member' : 'Add Member',
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
                  _CustomerFormField(
                    label: 'Name',
                    controller: _nameController,
                    requiredField: true,
                  ),
                  const SizedBox(height: 14),
                  _CustomerFormField(
                    label: 'Phone',
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    requiredField: true,
                  ),
                  const SizedBox(height: 14),
                  _CustomerGenderDropdown(
                    label: 'Gender',
                    controller: _genderController,
                  ),
                  const SizedBox(height: 14),
                  _CustomerFormField(
                    label: 'Date of Birth',
                    controller: _dobController,
                    hint: 'YYYY-MM-DD',
                    keyboardType: TextInputType.datetime,
                    onCalendarTap: () => _openFieldDatePicker(
                      _dobController,
                      allowFutureDates: false,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _CustomerFormField(
                    label: 'Join Date',
                    controller: _joinDateController,
                    hint: 'YYYY-MM-DD',
                    keyboardType: TextInputType.datetime,
                    onCalendarTap: () =>
                        _openFieldDatePicker(_joinDateController),
                  ),
                  const SizedBox(height: 14),
                  _CustomerFormField(
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
                              : Text(
                                  _isEditing ? 'Save Changes' : 'Add Member',
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

class _CustomerFormField extends StatelessWidget {
  final String label;
  final String? hint;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final bool requiredField;
  final int maxLines;
  final VoidCallback? onCalendarTap;

  const _CustomerFormField({
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

class _CustomerGenderDropdown extends StatelessWidget {
  final String label;
  final TextEditingController controller;

  const _CustomerGenderDropdown({
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

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  const _SearchBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A2E)),
      decoration: InputDecoration(
        hintText: 'Search members...',
        hintStyle: const TextStyle(color: Color(0xFFBDBDBD), fontSize: 14),
        prefixIcon: const Icon(
          Icons.search,
          color: Color(0xFF9E9E9E),
          size: 20,
        ),
        filled: true,
        fillColor: const Color(0xFFF5F5F5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final CustomerModel customer;
  final double radius;
  const _Avatar({required this.customer, required this.radius});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: customer.avatarColor,
      child: Text(
        customer.initials,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: radius * 0.7,
        ),
      ),
    );
  }
}

class _GenderChip extends StatelessWidget {
  final String gender;

  const _GenderChip({required this.gender});

  @override
  Widget build(BuildContext context) {
    final label = _genderLabel(gender);
    if (label.isEmpty) return const SizedBox.shrink();
    final isFemale = label == 'Female';
    final color = isFemale ? const Color(0xFFE91E63) : const Color(0xFF2563EB);
    final bg = isFemale ? const Color(0xFFFCE7F3) : const Color(0xFFEFF6FF);
    final border = isFemale
        ? const Color(0xFFF9A8D4)
        : const Color(0xFFBFDBFE);

    return Tooltip(
      message: label,
      child: Container(
        width: 24,
        height: 24,
        margin: const EdgeInsets.only(left: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
        ),
        child: Icon(
          isFemale ? Icons.female : Icons.male,
          size: 16,
          color: color,
        ),
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
              Text(
                value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A2E),
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
