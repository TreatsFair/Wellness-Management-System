import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/customer_repository.dart';
import '../../data/repositories/dashboard_repository.dart';
import '../../data/repositories/repository_utils.dart';
import '../../data/repositories/transaction_repository.dart';

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

class _CustomerOrder {
  final String id;
  final String receiptNumber;
  final String customerName;
  final String customerPhone;
  final String paymentMethod;
  final String source;
  final String appointmentId;
  final String appointmentGroupId;
  final String serviceName;
  final String therapistName;
  final String roomName;
  final int itemCount;
  final double servicePrice;
  final double sstAmount;
  final double totalAmount;
  final DateTime createdAt;
  final List<_CustomerOrderServiceGroup> serviceGroups;

  const _CustomerOrder({
    required this.id,
    required this.receiptNumber,
    required this.customerName,
    required this.customerPhone,
    required this.paymentMethod,
    required this.source,
    required this.appointmentId,
    required this.appointmentGroupId,
    required this.serviceName,
    required this.therapistName,
    required this.roomName,
    required this.itemCount,
    required this.servicePrice,
    required this.sstAmount,
    required this.totalAmount,
    required this.createdAt,
    required this.serviceGroups,
  });

  factory _CustomerOrder.fromTransaction(
    Map<String, dynamic> tx, {
    required Map<String, dynamic> customer,
    required Map<String, dynamic> appointment,
    required Map<String, dynamic> service,
    required Map<String, dynamic> therapist,
    required Map<String, dynamic> room,
  }) {
    final rawItems = _asMapList(
      tx['serviceItems'] ?? tx['service_items'] ?? tx['items'],
    );
    final customerName = asString(
      tx['customerName'],
      asString(customer['name'], 'Guest'),
    );
    final customerPhone = asString(
      tx['customerPhone'],
      asString(customer['phone'], '-'),
    );
    final serviceName = asString(
      tx['serviceName'],
      asString(service['name'], 'Service'),
    );
    final therapistName = asString(
      tx['therapistName'],
      asString(therapist['name'], '-'),
    );
    final roomName = asString(tx['roomName'], asString(room['name'], '-'));
    final servicePrice = asDouble(
      tx['servicePrice'],
      asDouble(appointment['totalPrice']),
    );
    final sstAmount = asDouble(tx['sstAmount']);
    final totalAmount = asDouble(tx['totalAmount'], servicePrice + sstAmount);
    final resolvedServicePrice = servicePrice == 0 && totalAmount > 0
        ? totalAmount - sstAmount
        : servicePrice;
    final itemCount = rawItems.isNotEmpty
        ? rawItems.length
        : asInt(tx['itemCount'], 1);

    return _CustomerOrder(
      id: asString(tx['id']),
      receiptNumber: asString(tx['receiptNumber'], asString(tx['id'])),
      customerName: customerName,
      customerPhone: customerPhone,
      paymentMethod: asString(tx['paymentMethod'], 'unknown'),
      source: asString(tx['source'], 'walkin').toLowerCase(),
      appointmentId: asString(tx['appointmentId']),
      appointmentGroupId: asString(tx['appointmentGroupId']),
      serviceName: serviceName,
      therapistName: therapistName,
      roomName: roomName,
      itemCount: itemCount <= 0 ? 1 : itemCount,
      servicePrice: resolvedServicePrice,
      sstAmount: sstAmount,
      totalAmount: totalAmount,
      createdAt:
          asDateTime(tx['paidAt']) ??
          asDateTime(tx['createdAt']) ??
          DateTime.now(),
      serviceGroups: _CustomerOrderServiceGroup.fromItems(
        rawItems,
        fallbackCustomerName: customerName,
        fallbackServiceName: serviceName,
        fallbackTherapistName: therapistName,
        fallbackRoomName: roomName,
        fallbackAmount: resolvedServicePrice,
      ),
    );
  }

  String get serviceSummary =>
      '$itemCount item${itemCount == 1 ? '' : 's'}';

  bool get isOnlineBooking => source == 'online_booking' || source == 'online';
  bool get isAddOnReceipt => source == 'appointment_addon';

  String get appointmentLinkKey {
    if (appointmentGroupId.isNotEmpty) return 'group:$appointmentGroupId';
    if (appointmentId.isNotEmpty) return 'appointment:$appointmentId';
    return 'receipt:$id';
  }

  String get sourceLabel {
    if (source == 'appointment_addon') return 'Appointment add-on';
    if (isOnlineBooking) return 'Online Booking';
    if (source == 'appointment') return 'Appointment booking';
    if (source == 'walkin' || source == 'walk_in') return 'Walk-in';
    return source.isEmpty ? 'Walk-in' : source;
  }

  String get paymentLabel {
    switch (paymentMethod) {
      case 'cash':
        return 'Cash';
      case 'qr_code':
        return 'QR Code';
      case 'credit_card':
      case 'card':
        return 'Credit Card';
      case 'debit_card':
        return 'Debit Card';
      case 'billplz':
      case 'online':
        return 'Online';
      default:
        return paymentMethod.isEmpty ? 'Payment' : paymentMethod;
    }
  }

  IconData get paymentIcon {
    switch (paymentMethod) {
      case 'cash':
        return Icons.payments_outlined;
      case 'qr_code':
        return Icons.qr_code_2_outlined;
      case 'credit_card':
      case 'card':
        return Icons.credit_card_outlined;
      case 'debit_card':
        return Icons.credit_card;
      default:
        return Icons.receipt_long_outlined;
    }
  }
}

class _CustomerOrderBundle {
  final _CustomerOrder primary;
  final List<_CustomerOrder> linkedReceipts;

  const _CustomerOrderBundle({
    required this.primary,
    required this.linkedReceipts,
  });

  List<_CustomerOrder> get receipts => [primary, ...linkedReceipts];

  DateTime get latestAt => receipts
      .map((receipt) => receipt.createdAt)
      .reduce((left, right) => left.isAfter(right) ? left : right);

  double get appointmentTotal => receipts.fold<double>(
    0,
    (total, receipt) => total + receipt.totalAmount,
  );

  bool get isLinked => linkedReceipts.isNotEmpty;
}

List<_CustomerOrderBundle> _bundleCustomerOrders(
  Iterable<_CustomerOrder> orders,
) {
  final grouped = <String, List<_CustomerOrder>>{};
  for (final order in orders) {
    grouped.putIfAbsent(order.appointmentLinkKey, () => []).add(order);
  }

  final bundles = grouped.values.map((receipts) {
    receipts.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final originalIndex = receipts.indexWhere(
      (receipt) => receipt.isOnlineBooking && !receipt.isAddOnReceipt,
    );
    final nonAddOnIndex = receipts.indexWhere(
      (receipt) => !receipt.isAddOnReceipt,
    );
    final primaryIndex = originalIndex >= 0
        ? originalIndex
        : nonAddOnIndex >= 0
        ? nonAddOnIndex
        : 0;
    final primary = receipts[primaryIndex];
    return _CustomerOrderBundle(
      primary: primary,
      linkedReceipts: [
        for (var index = 0; index < receipts.length; index++)
          if (index != primaryIndex) receipts[index],
      ],
    );
  }).toList()..sort((a, b) => b.latestAt.compareTo(a.latestAt));

  return bundles;
}

class _CustomerOrderServiceGroup {
  final int paxNumber;
  final String customerName;
  final List<String> services;
  final String therapistName;
  final String roomName;
  final String startTime;
  final String endTime;
  final double amount;

  const _CustomerOrderServiceGroup({
    required this.paxNumber,
    required this.customerName,
    required this.services,
    required this.therapistName,
    required this.roomName,
    required this.startTime,
    required this.endTime,
    required this.amount,
  });

  String get serviceLabel =>
      services.isEmpty ? 'Service' : services.join(', ');

  String get timeLabel {
    if (startTime.isEmpty && endTime.isEmpty) return '';
    if (endTime.isEmpty) return startTime;
    return '$startTime - $endTime';
  }

  static List<_CustomerOrderServiceGroup> fromItems(
    List<Map<String, dynamic>> items, {
    required String fallbackCustomerName,
    required String fallbackServiceName,
    required String fallbackTherapistName,
    required String fallbackRoomName,
    required double fallbackAmount,
  }) {
    if (items.isEmpty) {
      return [
        _CustomerOrderServiceGroup(
          paxNumber: 1,
          customerName: fallbackCustomerName,
          services: [fallbackServiceName],
          therapistName: fallbackTherapistName,
          roomName: fallbackRoomName,
          startTime: '',
          endTime: '',
          amount: fallbackAmount,
        ),
      ];
    }

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final item in items) {
      final key = [
        asString(item['assignedTherapistId']),
        asString(item['assignedTherapistName']),
        asString(item['assignedRoomId']),
        asString(item['assignedRoomName']),
        asString(item['startTime']),
        asString(item['endTime']),
      ].join('|');
      grouped.putIfAbsent(key, () => []).add(item);
    }

    var paxNumber = 0;
    return grouped.values.map((groupItems) {
      paxNumber += 1;
      final first = groupItems.first;
      final services = groupItems
          .map((item) => asString(item['name'], 'Service'))
          .where((name) => name.trim().isNotEmpty)
          .toList();
      final amount = groupItems.fold<double>(
        0,
        (total, item) => total + asDouble(item['price']),
      );
      return _CustomerOrderServiceGroup(
        paxNumber: paxNumber,
        customerName: paxNumber == 1 ? fallbackCustomerName : 'Guest',
        services: services.isEmpty ? [fallbackServiceName] : services,
        therapistName: asString(
          first['assignedTherapistName'],
          fallbackTherapistName,
        ),
        roomName: asString(first['assignedRoomName'], fallbackRoomName),
        startTime: asString(first['startTime']),
        endTime: asString(first['endTime']),
        amount: amount == 0 ? fallbackAmount : amount,
      );
    }).toList();
  }
}

List<Map<String, dynamic>> _asMapList(Object? value) {
  if (value is List) {
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }
  return const [];
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
      appBar: AppBar(
        elevation: 0,
        leading: const BackButton(),
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

  void _openOrderHistory(BuildContext context) {
    showCustomerOrdersSheet(context, customer: customer);
  }

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
                        icon: Icons.receipt_long_outlined,
                        iconBg: const Color(0xFFE8F5E9),
                        iconColor: const Color(0xFF1B6B72),
                        label: 'Orders',
                        value: '${customer.appointmentCount}',
                        onTap: () => _openOrderHistory(context),
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
                        icon: Icons.receipt_long_outlined,
                        iconBg: const Color(0xFFE8F5E9),
                        iconColor: const Color(0xFF1B6B72),
                        label: 'Orders',
                        value: '${customer.appointmentCount}',
                        onTap: () => _openOrderHistory(context),
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
  final VoidCallback? onTap;

  const _StatCard({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
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
              if (onTap != null) ...[
                const Spacer(),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: Color(0xFF9CA3AF),
                ),
              ],
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
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: card,
      ),
    );
  }
}

Future<void> showCustomerOrdersSheet(
  BuildContext context, {
  required CustomerModel customer,
  bool groupLatestBill = false,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CustomerOrdersSheet(
      customer: customer,
      groupLatestBill: groupLatestBill,
    ),
  );
}

Future<void> showTransactionOrderDetailSheet(
  BuildContext context, {
  required String receiptNumber,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _TransactionOrderDetailLoader(
      receiptNumber: receiptNumber,
    ),
  );
}

class _TransactionOrderDetailLoader extends StatefulWidget {
  final String receiptNumber;

  const _TransactionOrderDetailLoader({required this.receiptNumber});

  @override
  State<_TransactionOrderDetailLoader> createState() =>
      _TransactionOrderDetailLoaderState();
}

class _TransactionOrderDetailLoaderState
    extends State<_TransactionOrderDetailLoader> {
  final _transactionRepository = TransactionRepository();
  final _dashboardRepository = DashboardRepository();
  late final Future<(_CustomerOrder, List<_CustomerOrder>)> _orderFuture;

  @override
  void initState() {
    super.initState();
    _orderFuture = _loadOrder();
  }

  Future<(_CustomerOrder, List<_CustomerOrder>)> _loadOrder() async {
    final transaction = await _transactionRepository
        .getTransactionByReceiptNumber(widget.receiptNumber);
    if (transaction == null) {
      throw StateError('Bill ${widget.receiptNumber} could not be found.');
    }

    final linkedRows = await _transactionRepository
        .getLinkedAppointmentTransactions(
          appointmentId: asString(transaction['appointmentId']),
          appointmentGroupId: asString(transaction['appointmentGroupId']),
        );
    final rowsById = <String, Map<String, dynamic>>{};
    for (final row in [transaction, ...linkedRows]) {
      rowsById[asString(row['id'], asString(row['receiptNumber']))] = row;
    }
    final rows = rowsById.values.toList();
    final appointmentIds = rows
        .map((row) => asString(row['appointmentId']))
        .where((id) => id.isNotEmpty);
    final customerIds = rows
        .map((row) => asString(row['customerId']))
        .where((id) => id.isNotEmpty && id != 'walk_in_guest');
    final appointments = await _dashboardRepository.loadByIds(
      'appointments',
      appointmentIds,
    );
    final appointmentRows = appointments.values;
    final customers = await _dashboardRepository.loadByIds(
      'customers',
      [
        ...customerIds,
        ...appointmentRows.map((row) => asString(row['customerId'])),
      ],
    );
    final services = await _dashboardRepository.loadByIds('services', [
      ...rows.map((row) => asString(row['serviceId'])),
      ...appointmentRows.map((row) => asString(row['serviceId'])),
    ]);
    final therapists = await _dashboardRepository.loadByIds('therapists', [
      ...rows.map((row) => asString(row['therapistId'])),
      ...appointmentRows.map((row) => asString(row['therapistId'])),
    ]);
    final rooms = await _dashboardRepository.loadByIds('rooms', [
      ...rows.map((row) => asString(row['roomId'])),
      ...appointmentRows.map((row) => asString(row['roomId'])),
    ]);

    final orders = rows.map((row) {
      final appointmentId = asString(row['appointmentId']);
      final appointment = appointments[appointmentId] ?? {};
      final customerId = asString(row['customerId']).isNotEmpty
          ? asString(row['customerId'])
          : asString(appointment['customerId']);
      final serviceId = asString(row['serviceId']).isNotEmpty
          ? asString(row['serviceId'])
          : asString(appointment['serviceId']);
      final therapistId = asString(row['therapistId']).isNotEmpty
          ? asString(row['therapistId'])
          : asString(appointment['therapistId']);
      final roomId = asString(row['roomId']).isNotEmpty
          ? asString(row['roomId'])
          : asString(appointment['roomId']);
      return _CustomerOrder.fromTransaction(
        row,
        customer: customers[customerId] ?? {},
        appointment: appointment,
        service: services[serviceId] ?? {},
        therapist: therapists[therapistId] ?? {},
        room: rooms[roomId] ?? {},
      );
    }).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final selectedId = asString(transaction['id']);
    final selected = orders.firstWhere(
      (order) => order.id == selectedId,
      orElse: () => orders.first,
    );
    final related = orders
        .where((order) => order.id != selected.id)
        .toList();
    return (selected, related);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(_CustomerOrder, List<_CustomerOrder>)>(
      future: _orderFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _OrderDetailLoadState(
            icon: Icons.error_outline_rounded,
            message: snapshot.error.toString().replaceFirst(
              'Bad state: ',
              '',
            ),
          );
        }
        if (!snapshot.hasData) {
          return const _OrderDetailLoadState(
            icon: Icons.receipt_long_outlined,
            message: 'Loading bill details...',
            loading: true,
          );
        }
        final result = snapshot.data!;
        return _CustomerOrderDetailSheet(
          order: result.$1,
          relatedOrders: result.$2,
        );
      },
    );
  }
}

class _OrderDetailLoadState extends StatelessWidget {
  final IconData icon;
  final String message;
  final bool loading;

  const _OrderDetailLoadState({
    required this.icon,
    required this.message,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.all(28),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Row(
            children: [
              if (loading)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              else
                Icon(icon, color: const Color(0xFFB42318)),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Color(0xFF374151),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (!loading)
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Close',
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CustomerOrdersSheet extends StatefulWidget {
  final CustomerModel customer;
  final bool groupLatestBill;

  const _CustomerOrdersSheet({
    required this.customer,
    this.groupLatestBill = false,
  });

  @override
  State<_CustomerOrdersSheet> createState() => _CustomerOrdersSheetState();
}

class _CustomerOrdersSheetState extends State<_CustomerOrdersSheet> {
  final _customerRepository = CustomerRepository();
  final _dashboardRepository = DashboardRepository();
  late final Future<List<_CustomerOrder>> _ordersFuture;

  @override
  void initState() {
    super.initState();
    _ordersFuture = _loadOrders();
  }

  Future<List<_CustomerOrder>> _loadOrders() async {
    final rows = await _customerRepository.getCustomerOrders(widget.customer.id);
    final appointmentIds = rows
        .map((row) => asString(row['appointmentId']))
        .where((id) => id.isNotEmpty);
    final serviceIds = rows
        .map((row) => asString(row['serviceId']))
        .where((id) => id.isNotEmpty);
    final therapistIds = rows
        .map((row) => asString(row['therapistId']))
        .where((id) => id.isNotEmpty);
    final roomIds = rows
        .map((row) => asString(row['roomId']))
        .where((id) => id.isNotEmpty);

    final appointments = await _dashboardRepository.loadByIds(
      'appointments',
      appointmentIds,
    );
    final appointmentRows = appointments.values;
    final services = await _dashboardRepository.loadByIds('services', [
      ...serviceIds,
      ...appointmentRows.map((row) => asString(row['serviceId'])),
    ]);
    final therapists = await _dashboardRepository.loadByIds('therapists', [
      ...therapistIds,
      ...appointmentRows.map((row) => asString(row['therapistId'])),
    ]);
    final rooms = await _dashboardRepository.loadByIds('rooms', [
      ...roomIds,
      ...appointmentRows.map((row) => asString(row['roomId'])),
    ]);

    final orders = rows.map((row) {
      final appointmentId = asString(row['appointmentId']);
      final appointment = appointments[appointmentId] ?? {};
      final serviceId = asString(row['serviceId']).isNotEmpty
          ? asString(row['serviceId'])
          : asString(appointment['serviceId']);
      final therapistId = asString(row['therapistId']).isNotEmpty
          ? asString(row['therapistId'])
          : asString(appointment['therapistId']);
      final roomId = asString(row['roomId']).isNotEmpty
          ? asString(row['roomId'])
          : asString(appointment['roomId']);
      return _CustomerOrder.fromTransaction(
        row,
        customer: {
          'name': widget.customer.name,
          'phone': widget.customer.phone,
        },
        appointment: appointment,
        service: services[serviceId] ?? {},
        therapist: therapists[therapistId] ?? {},
        room: rooms[roomId] ?? {},
      );
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return orders;
  }

  void _openOrder(_CustomerOrder order, _CustomerOrderBundle bundle) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CustomerOrderDetailSheet(
        order: order,
        relatedOrders: bundle.receipts
            .where((receipt) => receipt.id != order.id)
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      minChildSize: 0.45,
      maxChildSize: 0.94,
      builder: (context, controller) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF7F8FA),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: FutureBuilder<List<_CustomerOrder>>(
            future: _ordersFuture,
            builder: (context, snapshot) {
              final orders = snapshot.data ?? const <_CustomerOrder>[];
              final bundles = _bundleCustomerOrders(orders);
              final total = orders.fold<double>(
                0,
                (sum, order) => sum + order.totalAmount,
              );
              return ListView(
                controller: controller,
                padding: EdgeInsets.fromLTRB(18, 12, 18, bottomInset + 24),
                children: [
                  Center(
                    child: Container(
                      width: 42,
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
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.groupLatestBill
                                  ? '${widget.customer.name} Bills'
                                  : '${widget.customer.name} Orders',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF1A1A2E),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.groupLatestBill
                                  ? '${orders.length} bill${orders.length == 1 ? '' : 's'} · ${_money(total)}'
                                  : '${orders.length} previous order${orders.length == 1 ? '' : 's'} · ${_money(total)}',
                              style: const TextStyle(
                                fontSize: 13,
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
                  const SizedBox(height: 16),
                  if (snapshot.connectionState == ConnectionState.waiting)
                    const _OrdersLoadingCard()
                  else if (snapshot.hasError)
                    _OrdersEmptyCard(
                      icon: Icons.error_outline,
                      title: 'Unable to load orders',
                      message: snapshot.error.toString(),
                    )
                  else if (orders.isEmpty)
                    _OrdersEmptyCard(
                      icon: Icons.receipt_long_outlined,
                      title: widget.groupLatestBill
                          ? 'No bills yet'
                          : 'No previous orders',
                      message: widget.groupLatestBill
                          ? 'Paid bills for this customer will appear here.'
                          : 'Paid orders for this member will appear here.',
                    )
                  else if (widget.groupLatestBill) ...[
                    const _OrderListSectionTitle('Latest Bill'),
                    const SizedBox(height: 10),
                    _CustomerOrderBundleView(
                      bundle: bundles.first,
                      onOpen: (order) => _openOrder(order, bundles.first),
                    ),
                    if (bundles.length > 1) ...[
                      const SizedBox(height: 22),
                      const _OrderListSectionTitle('Previous Bills'),
                      const SizedBox(height: 10),
                      for (final bundle in bundles.skip(1)) ...[
                        _CustomerOrderBundleView(
                          bundle: bundle,
                          onOpen: (order) => _openOrder(order, bundle),
                        ),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ]
                  else
                    for (final bundle in bundles) ...[
                      _CustomerOrderBundleView(
                        bundle: bundle,
                        onOpen: (order) => _openOrder(order, bundle),
                      ),
                      const SizedBox(height: 10),
                    ],
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _OrderListSectionTitle extends StatelessWidget {
  final String label;

  const _OrderListSectionTitle(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w900,
        color: Color(0xFF1A1A2E),
      ),
    );
  }
}

class _CustomerOrderCard extends StatelessWidget {
  final _CustomerOrder order;
  final VoidCallback onTap;
  final String? label;
  final bool grouped;

  const _CustomerOrderCard({
    required this.order,
    required this.onTap,
    this.label,
    this.grouped = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: grouped ? Colors.transparent : Colors.white,
      borderRadius: BorderRadius.circular(grouped ? 8 : 14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(grouped ? 8 : 14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: grouped ? const Color(0xFFF8FAFC) : null,
            borderRadius: BorderRadius.circular(grouped ? 8 : 14),
            border: Border.all(
              color: grouped
                  ? const Color(0xFFEDF1F4)
                  : const Color(0xFFE5E7EB),
            ),
            boxShadow: grouped
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.035),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5F5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  order.paymentIcon,
                  color: const Color(0xFF1B6B72),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (label != null) ...[
                      Text(
                        label!,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF1B6B72),
                        ),
                      ),
                      const SizedBox(height: 3),
                    ],
                    Text(
                      order.receiptNumber,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      DateFormat('h:mm a, d MMM yyyy').format(order.createdAt),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${order.serviceName} · ${order.serviceSummary}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF374151),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _money(order.totalAmount),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF2563EB),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: Color(0xFFCBD5E1),
                    size: 24,
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

class _CustomerOrderBundleView extends StatelessWidget {
  final _CustomerOrderBundle bundle;
  final ValueChanged<_CustomerOrder> onOpen;

  const _CustomerOrderBundleView({
    required this.bundle,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    if (!bundle.isLinked) {
      return _CustomerOrderCard(
        order: bundle.primary,
        onTap: () => onOpen(bundle.primary),
      );
    }

    final receiptCount = 1 + bundle.linkedReceipts.length;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDDE5E7)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
            child: Row(
              children: [
                const Icon(
                  Icons.link_rounded,
                  size: 18,
                  color: Color(0xFF1B6B72),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Appointment receipts',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                ),
                Text(
                  '$receiptCount receipts',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ],
            ),
          ),
          _CustomerOrderCard(
            order: bundle.primary,
            grouped: true,
            label: bundle.primary.isOnlineBooking
                ? 'ORIGINAL BOOKING RECEIPT'
                : 'MAIN RECEIPT',
            onTap: () => onOpen(bundle.primary),
          ),
          for (final receipt in bundle.linkedReceipts) ...[
            const _LinkedReceiptConnector(),
            _CustomerOrderCard(
              order: receipt,
              grouped: true,
              label: receipt.isAddOnReceipt
                  ? 'ADD-ON RECEIPT'
                  : 'RELATED RECEIPT',
              onTap: () => onOpen(receipt),
            ),
          ],
          const SizedBox(height: 10),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Total paid across $receiptCount receipts',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF4B5563),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _money(bundle.appointmentTotal),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF11875D),
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

class _LinkedReceiptConnector extends StatelessWidget {
  const _LinkedReceiptConnector();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const SizedBox(width: 17),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: const Color(0xFFE8F5F5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.arrow_downward_rounded,
              size: 17,
              color: Color(0xFF1B6B72),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Add-on to this booking',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: Color(0xFF64748B),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomerOrderDetailSheet extends StatelessWidget {
  final _CustomerOrder order;
  final List<_CustomerOrder> relatedOrders;

  const _CustomerOrderDetailSheet({
    required this.order,
    this.relatedOrders = const [],
  });

  void _openRelated(BuildContext context, _CustomerOrder target) {
    final allReceipts = [order, ...relatedOrders];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CustomerOrderDetailSheet(
        order: target,
        relatedOrders: allReceipts
            .where((receipt) => receipt.id != target.id)
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      minChildSize: 0.42,
      maxChildSize: 0.94,
      builder: (context, controller) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD1D5DB),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              _CustomerBillReceiptHeader(order: order),
              if (relatedOrders.isNotEmpty) ...[
                const SizedBox(height: 18),
                const _OrderSectionTitle(
                  'Linked Receipts',
                  icon: Icons.link_rounded,
                ),
                const SizedBox(height: 10),
                _CustomerOrderInfoCard(
                  children: [
                    for (final related in relatedOrders)
                      _LinkedReceiptRow(
                        order: related,
                        onTap: () => _openRelated(context, related),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              const _OrderSectionTitle(
                'Source & Customer',
                icon: Icons.person_outline,
              ),
              const SizedBox(height: 10),
              _CustomerOrderInfoCard(
                children: [
                  _OrderDetailRow('Source', order.sourceLabel),
                  _OrderDetailRow('Customer', order.customerName),
                  _OrderDetailRow('Phone', order.customerPhone),
                ],
              ),
              if (!order.isOnlineBooking) ...[
                const SizedBox(height: 18),
                const _OrderSectionTitle(
                  'Service Details',
                  icon: Icons.spa_outlined,
                ),
                const SizedBox(height: 10),
                for (var i = 0; i < order.serviceGroups.length; i++) ...[
                  _OrderServiceGroupCard(
                    group: order.serviceGroups[i],
                    expanded: order.serviceGroups.length == 1,
                  ),
                  if (i != order.serviceGroups.length - 1)
                    const SizedBox(height: 8),
                ],
              ],
              const SizedBox(height: 18),
              const _OrderSectionTitle(
                'Payment Details',
                icon: Icons.payments_outlined,
              ),
              const SizedBox(height: 10),
              _CustomerOrderInfoCard(
                children: [
                  _OrderDetailRow('Payment', order.paymentLabel),
                  _OrderDetailRow(
                    'Service Net',
                    _money(order.servicePrice),
                  ),
                  _OrderDetailRow('SST', _money(order.sstAmount)),
                  _OrderDetailRow(
                    'Total',
                    _money(order.totalAmount),
                    strong: true,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LinkedReceiptRow extends StatelessWidget {
  final _CustomerOrder order;
  final VoidCallback onTap;

  const _LinkedReceiptRow({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Icon(order.paymentIcon, size: 18, color: const Color(0xFF1B6B72)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    order.isAddOnReceipt
                        ? 'Add-on receipt'
                        : 'Original booking receipt',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    order.receiptNumber,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                ],
              ),
            ),
            Text(
              _money(order.totalAmount),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: Color(0xFF1B6B72),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: Color(0xFFCBD5E1),
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomerBillReceiptHeader extends StatelessWidget {
  final _CustomerOrder order;

  const _CustomerBillReceiptHeader({required this.order});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF8F7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFBFE2DE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.receipt_long_outlined,
                size: 17,
                color: Color(0xFF1B6B72),
              ),
              SizedBox(width: 7),
              Text(
                'BILL RECEIPT',
                style: TextStyle(
                  color: Color(0xFF1B6B72),
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  order.receiptNumber,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                _money(order.totalAmount),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1B6B72),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            'Paid ${DateFormat('EEEE, d MMM yyyy · h:mm a').format(order.createdAt)}',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF6B7280),
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomerOrderInfoCard extends StatelessWidget {
  final List<Widget> children;

  const _CustomerOrderInfoCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        children: [
          for (var index = 0; index < children.length; index++) ...[
            children[index],
            if (index != children.length - 1)
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
          ],
        ],
      ),
    );
  }
}

class _OrderServiceGroupCard extends StatelessWidget {
  final _CustomerOrderServiceGroup group;
  final bool expanded;

  const _OrderServiceGroupCard({
    required this.group,
    required this.expanded,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: expanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          title: Text(
            'Pax ${group.paxNumber} · ${group.customerName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              color: Color(0xFF1A1A2E),
            ),
          ),
          subtitle: Text(
            '${group.serviceLabel} · ${_money(group.amount)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF6B7280),
            ),
          ),
          children: [
            _OrderServiceLine(
              icon: Icons.spa_outlined,
              label: 'Service',
              value: group.serviceLabel,
            ),
            _OrderServiceLine(
              icon: Icons.person_outline,
              label: 'Therapist',
              value: group.therapistName,
            ),
            _OrderServiceLine(
              icon: Icons.meeting_room_outlined,
              label: 'Room / Zone',
              value: group.roomName,
            ),
            if (group.timeLabel.isNotEmpty)
              _OrderServiceLine(
                icon: Icons.schedule_outlined,
                label: 'Time',
                value: group.timeLabel,
              ),
            _OrderServiceLine(
              icon: Icons.payments_outlined,
              label: 'Amount',
              value: _money(group.amount),
              strong: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderServiceLine extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool strong;

  const _OrderServiceLine({
    required this.icon,
    required this.label,
    required this.value,
    this.strong = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: const Color(0xFF6B7280)),
          const SizedBox(width: 8),
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF6B7280),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: strong ? FontWeight.w900 : FontWeight.w700,
                color: strong
                    ? const Color(0xFF1B6B72)
                    : const Color(0xFF1A1A2E),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderDetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool strong;

  const _OrderDetailRow(this.label, this.value, {this.strong = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF6B7280),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: strong ? 15 : 13,
                fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
                color: strong
                    ? const Color(0xFF1B6B72)
                    : const Color(0xFF1A1A2E),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderSectionTitle extends StatelessWidget {
  final String label;
  final IconData? icon;

  const _OrderSectionTitle(this.label, {this.icon});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: const Color(0xFF1B6B72)),
          const SizedBox(width: 8),
        ],
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            color: Color(0xFF1A1A2E),
          ),
        ),
      ],
    );
  }
}

class _OrdersLoadingCard extends StatelessWidget {
  const _OrdersLoadingCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Center(
        child: CircularProgressIndicator(color: Color(0xFF1B6B72)),
      ),
    );
  }
}

class _OrdersEmptyCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _OrdersEmptyCard({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        children: [
          Icon(icon, color: const Color(0xFF9CA3AF), size: 34),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w900,
              color: Color(0xFF1A1A2E),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B7280),
            ),
          ),
        ],
      ),
    );
  }
}

String _money(double value) => 'RM ${value.toStringAsFixed(2)}';

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
