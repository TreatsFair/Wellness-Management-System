import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/dashboard_repository.dart';
import '../../data/repositories/transaction_repository.dart';

const _teal = Color(0xFF1B6B72);
const _ink = Color(0xFF1A1A2E);
const _muted = Color(0xFF6B7280);
const _page = Color(0xFFF4F5F7);
const _line = Color(0xFFE5E7EB);

DateTime _stripDate(DateTime date) => DateTime(date.year, date.month, date.day);

String _asString(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  final text = value.toString();
  return text.trim().isEmpty ? fallback : text;
}

double _asDouble(Object? value, [double fallback = 0]) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

DateTime _asDateTime(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value) ?? DateTime.now();
  return DateTime.now();
}

class SalesHistoryScreen extends StatefulWidget {
  final String userRole;

  const SalesHistoryScreen({super.key, required this.userRole});

  @override
  State<SalesHistoryScreen> createState() => _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends State<SalesHistoryScreen> {
  final _dashboardRepository = DashboardRepository();
  final _transactionRepository = TransactionRepository();
  DateTime _selectedDate = _stripDate(DateTime.now());
  List<_HistoryOrder> _orders = [];
  _HistorySummary _summary = _HistorySummary.empty;
  bool _loading = true;
  String? _error;
  bool _showOrdersOnPhone = false;

  bool get _isAdmin => widget.userRole.toLowerCase().trim() == 'admin';
  bool get _canGoNextDay => _selectedDate.isBefore(_stripDate(DateTime.now()));

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<Map<String, Map<String, dynamic>>> _loadDocMap(
    String collection,
    Iterable<String> ids,
  ) async {
    return _dashboardRepository.loadByIds(collection, ids);
  }

  Future<void> _loadHistory() async {
    setState(() {
      _loading = true;
      _error = null;
      if (!_isAdmin) _selectedDate = _stripDate(DateTime.now());
    });

    try {
      final transactionRows = await _transactionRepository.getSalesHistory(
        _selectedDate,
      );

      final transactionDocs = transactionRows.where((row) {
        final status = _asString(row['paymentStatus']).toLowerCase();
        return status.isEmpty || status == 'paid';
      }).toList();

      final transactionData = transactionDocs;
      final appointmentIds = transactionData
          .map((d) => _asString(d['appointmentId']))
          .where((id) => id.isNotEmpty);
      final customerIds = transactionData
          .map((d) => _asString(d['customerId']))
          .where((id) => id.isNotEmpty);

      final appointments = await _loadDocMap('appointments', appointmentIds);
      final linkedCustomerIds = appointments.values
          .map((d) => _asString(d['customerId']))
          .where((id) => id.isNotEmpty);
      final serviceIds = [
        ...transactionData.map((d) => _asString(d['serviceId'])),
        ...appointments.values.map((d) => _asString(d['serviceId'])),
      ].where((id) => id.isNotEmpty);
      final therapistIds = [
        ...transactionData.map((d) => _asString(d['therapistId'])),
        ...appointments.values.map((d) => _asString(d['therapistId'])),
      ].where((id) => id.isNotEmpty);
      final roomIds = [
        ...transactionData.map((d) => _asString(d['roomId'])),
        ...appointments.values.map((d) => _asString(d['roomId'])),
      ].where((id) => id.isNotEmpty);

      final customers = await _loadDocMap('customers', [
        ...customerIds,
        ...linkedCustomerIds,
      ]);
      final services = await _loadDocMap('services', serviceIds);
      final therapists = await _loadDocMap('therapists', therapistIds);
      final rooms = await _loadDocMap('rooms', roomIds);

      final orders = transactionDocs
          .map(
            (transaction) => _HistoryOrder.fromTransaction(
              transaction,
              appointments: appointments,
              customers: customers,
              services: services,
              therapists: therapists,
              rooms: rooms,
            ),
          )
          .toList();

      if (!mounted) return;
      setState(() {
        _orders = orders;
        _summary = _HistorySummary.fromOrders(orders);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _orders = [];
        _summary = _HistorySummary.empty;
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _openDatePicker() async {
    if (!_isAdmin) return;
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (context) => _HistoryCalendarDialog(initialDate: _selectedDate),
    );
    if (picked == null) return;
    final today = _stripDate(DateTime.now());
    final cleanPicked = _stripDate(picked);
    setState(() {
      _selectedDate = cleanPicked.isAfter(today) ? today : cleanPicked;
    });
    await _loadHistory();
  }

  Future<void> _moveDate(int days) async {
    if (!_isAdmin) return;
    final nextDate = _selectedDate.add(Duration(days: days));
    final today = _stripDate(DateTime.now());
    setState(() {
      _selectedDate = nextDate.isAfter(today) ? today : nextDate;
    });
    await _loadHistory();
  }

  void _openOrderDetail(_HistoryOrder order) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _OrderDetailSheet(order: order),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.of(context).size.width >= 900;
    return Scaffold(
      backgroundColor: _page,
      body: SafeArea(
        child: isTablet
            ? _buildTablet()
            : _showOrdersOnPhone
            ? _buildPhoneOrders()
            : _buildPhoneSummary(),
      ),
    );
  }

  Widget _buildTablet() {
    return Row(
      children: [
        SizedBox(
          width: 292,
          child: _HistorySidePanel(
            selectedDate: _selectedDate,
            summary: _summary,
            loading: _loading,
            isAdmin: _isAdmin,
            onBack: () => Navigator.pop(context),
            onPickDate: _openDatePicker,
            onPreviousDate: () => _moveDate(-1),
            onNextDate: () => _moveDate(1),
            canGoNextDate: _canGoNextDay,
            onOpenOrders: null,
          ),
        ),
        const VerticalDivider(width: 1, color: _line),
        Expanded(
          child: _HistoryOrderPane(
            selectedDate: _selectedDate,
            orders: _orders,
            summary: _summary,
            loading: _loading,
            error: _error,
            onRefresh: _loadHistory,
            onTapOrder: _openOrderDetail,
          ),
        ),
      ],
    );
  }

  Widget _buildPhoneSummary() {
    return _HistorySidePanel(
      selectedDate: _selectedDate,
      summary: _summary,
      loading: _loading,
      isAdmin: _isAdmin,
      onBack: () => Navigator.pop(context),
      onPickDate: _openDatePicker,
      onPreviousDate: () => _moveDate(-1),
      onNextDate: () => _moveDate(1),
      canGoNextDate: _canGoNextDay,
      onOpenOrders: () => setState(() => _showOrdersOnPhone = true),
    );
  }

  Widget _buildPhoneOrders() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(4, 10, 16, 12),
          color: Colors.white,
          child: Row(
            children: [
              BackButton(
                color: _teal,
                onPressed: () => setState(() => _showOrdersOnPhone = false),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Order History',
                      style: TextStyle(
                        color: _ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      DateFormat('EEE, d MMM yyyy').format(_selectedDate),
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              _IconAction(
                icon: Icons.refresh,
                tooltip: 'Refresh history',
                onTap: _loadHistory,
              ),
            ],
          ),
        ),
        Expanded(
          child: _HistoryOrderPane(
            selectedDate: _selectedDate,
            orders: _orders,
            summary: _summary,
            loading: _loading,
            error: _error,
            onRefresh: _loadHistory,
            onTapOrder: _openOrderDetail,
            compact: true,
          ),
        ),
      ],
    );
  }
}

class _HistoryOrder {
  final String id;
  final String receiptNumber;
  final String appointmentId;
  final String customerId;
  final String customerName;
  final String customerPhone;
  final String serviceName;
  final String therapistName;
  final String roomName;
  final String paymentMethod;
  final int itemCount;
  final double servicePrice;
  final double sstAmount;
  final double totalAmount;
  final DateTime createdAt;

  const _HistoryOrder({
    required this.id,
    required this.receiptNumber,
    required this.appointmentId,
    required this.customerId,
    required this.customerName,
    required this.customerPhone,
    required this.serviceName,
    required this.therapistName,
    required this.roomName,
    required this.paymentMethod,
    required this.itemCount,
    required this.servicePrice,
    required this.sstAmount,
    required this.totalAmount,
    required this.createdAt,
  });

  factory _HistoryOrder.fromTransaction(
    Map<String, dynamic> tx, {
    required Map<String, Map<String, dynamic>> appointments,
    required Map<String, Map<String, dynamic>> customers,
    required Map<String, Map<String, dynamic>> services,
    required Map<String, Map<String, dynamic>> therapists,
    required Map<String, Map<String, dynamic>> rooms,
  }) {
    final appointmentId = _asString(tx['appointmentId']);
    final appointment = appointments[appointmentId] ?? {};
    final customerId = _asString(tx['customerId']).isNotEmpty
        ? _asString(tx['customerId'])
        : _asString(appointment['customerId']);
    final customer = customers[customerId] ?? {};
    final serviceId = _asString(tx['serviceId']).isNotEmpty
        ? _asString(tx['serviceId'])
        : _asString(appointment['serviceId']);
    final therapistId = _asString(tx['therapistId']).isNotEmpty
        ? _asString(tx['therapistId'])
        : _asString(appointment['therapistId']);
    final roomId = _asString(tx['roomId']).isNotEmpty
        ? _asString(tx['roomId'])
        : _asString(appointment['roomId']);
    final service = services[serviceId] ?? {};
    final therapist = therapists[therapistId] ?? {};
    final room = rooms[roomId] ?? {};
    final rawItems = tx['items'];
    final itemCount = rawItems is List
        ? rawItems.length
        : _asInt(tx['itemCount'], 1);

    return _HistoryOrder(
      id: _asString(tx['id']),
      receiptNumber: _asString(tx['receiptNumber'], _asString(tx['id'])),
      appointmentId: appointmentId,
      customerId: customerId,
      customerName: _asString(
        tx['customerName'],
        _asString(customer['name'], 'Guest'),
      ),
      customerPhone: _asString(
        tx['customerPhone'],
        _asString(customer['phone'], '-'),
      ),
      serviceName: _asString(
        tx['serviceName'],
        _asString(service['name'], 'Service'),
      ),
      therapistName: _asString(
        tx['therapistName'],
        _asString(therapist['name'], '-'),
      ),
      roomName: _asString(tx['roomName'], _asString(room['name'], '-')),
      paymentMethod: _asString(tx['paymentMethod'], 'unknown'),
      itemCount: itemCount <= 0 ? 1 : itemCount,
      servicePrice: _asDouble(
        tx['servicePrice'],
        _asDouble(appointment['totalPrice']),
      ),
      sstAmount: _asDouble(tx['sstAmount']),
      totalAmount: _asDouble(
        tx['totalAmount'],
        _asDouble(appointment['totalPrice']),
      ),
      createdAt: _asDateTime(tx['createdAt']),
    );
  }

  bool get isAppointmentBooking => appointmentId.isNotEmpty;

  String get paymentLabel {
    switch (paymentMethod) {
      case 'cash':
        return 'Cash';
      case 'qr_code':
        return 'QR Code';
      case 'card':
        return 'Card';
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
      case 'card':
        return Icons.credit_card_outlined;
      default:
        return Icons.receipt_long_outlined;
    }
  }
}

class _HistorySummary {
  final double collection;
  final double serviceNet;
  final double sst;
  final int orderCount;
  final int itemCount;
  final int customerCount;
  final Map<String, double> paymentTotals;

  const _HistorySummary({
    required this.collection,
    required this.serviceNet,
    required this.sst,
    required this.orderCount,
    required this.itemCount,
    required this.customerCount,
    required this.paymentTotals,
  });

  static const empty = _HistorySummary(
    collection: 0,
    serviceNet: 0,
    sst: 0,
    orderCount: 0,
    itemCount: 0,
    customerCount: 0,
    paymentTotals: {'cash': 0, 'qr_code': 0, 'card': 0},
  );

  factory _HistorySummary.fromOrders(List<_HistoryOrder> orders) {
    final paymentTotals = {
      'cash': 0.0,
      'qr_code': 0.0,
      'card': 0.0,
      'other': 0.0,
    };
    final customers = <String>{};
    var collection = 0.0;
    var serviceNet = 0.0;
    var sst = 0.0;
    var itemCount = 0;

    for (final order in orders) {
      collection += order.totalAmount;
      serviceNet += order.servicePrice;
      sst += order.sstAmount;
      itemCount += order.itemCount;
      customers.add(
        order.customerId.isNotEmpty ? order.customerId : order.customerName,
      );
      if (paymentTotals.containsKey(order.paymentMethod)) {
        paymentTotals[order.paymentMethod] =
            paymentTotals[order.paymentMethod]! + order.totalAmount;
      } else {
        paymentTotals['other'] = paymentTotals['other']! + order.totalAmount;
      }
    }

    return _HistorySummary(
      collection: collection,
      serviceNet: serviceNet,
      sst: sst,
      orderCount: orders.length,
      itemCount: itemCount,
      customerCount: customers.where((id) => id.trim().isNotEmpty).length,
      paymentTotals: paymentTotals,
    );
  }

  double get averageOrder => orderCount == 0 ? 0 : collection / orderCount;
}

class _HistorySidePanel extends StatelessWidget {
  final DateTime selectedDate;
  final _HistorySummary summary;
  final bool loading;
  final bool isAdmin;
  final VoidCallback onBack;
  final VoidCallback onPickDate;
  final VoidCallback onPreviousDate;
  final VoidCallback onNextDate;
  final bool canGoNextDate;
  final VoidCallback? onOpenOrders;

  const _HistorySidePanel({
    required this.selectedDate,
    required this.summary,
    required this.loading,
    required this.isAdmin,
    required this.onBack,
    required this.onPickDate,
    required this.onPreviousDate,
    required this.onNextDate,
    required this.canGoNextDate,
    this.onOpenOrders,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: SafeArea(
        top: false,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
            children: [
              SizedBox(
                height: 36,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _IconAction(
                        icon: Icons.close,
                        tooltip: 'Close history',
                        onTap: onBack,
                      ),
                    ),
                    Center(
                      child: _DateControl(
                        date: selectedDate,
                        isAdmin: isAdmin,
                        onPickDate: onPickDate,
                        onPreviousDate: onPreviousDate,
                        onNextDate: onNextDate,
                        canGoNextDate: canGoNextDate,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isAdmin) ...[
                const SizedBox(height: 10),
                const _StaffDateNotice(),
              ],
              const SizedBox(height: 22),
              _CollectionTile(
                total: summary.collection,
                orderCount: summary.orderCount,
                loading: loading,
              ),
              const SizedBox(height: 18),
              const _SideSectionLabel('Payment Breakdown'),
              _SideMetricRow(
                icon: Icons.payments_outlined,
                iconColor: const Color(0xFFD946EF),
                label: 'Cash',
                value: _money(summary.paymentTotals['cash'] ?? 0),
              ),
              _SideMetricRow(
                icon: Icons.qr_code_2_outlined,
                iconColor: const Color(0xFF7C3AED),
                label: 'QR Code',
                value: _money(summary.paymentTotals['qr_code'] ?? 0),
              ),
              _SideMetricRow(
                icon: Icons.credit_card_outlined,
                iconColor: const Color(0xFF2563EB),
                label: 'Card',
                value: _money(summary.paymentTotals['card'] ?? 0),
              ),
              if ((summary.paymentTotals['other'] ?? 0) > 0)
                _SideMetricRow(
                  icon: Icons.account_balance_wallet_outlined,
                  iconColor: const Color(0xFF64748B),
                  label: 'Other',
                  value: _money(summary.paymentTotals['other'] ?? 0),
                ),
              const SizedBox(height: 22),
              const _SideSectionLabel('Daily Sales'),
              _SideMetricRow(
                icon: Icons.shopping_cart_outlined,
                iconColor: const Color(0xFF2563EB),
                label: 'Orders',
                value: '${summary.orderCount}',
                selected: true,
                onTap: onOpenOrders,
              ),
              _SideMetricRow(
                icon: Icons.spa_outlined,
                iconColor: const Color(0xFF10B981),
                label: 'Services',
                value: '${summary.itemCount}',
              ),
              _SideMetricRow(
                icon: Icons.people_outline,
                iconColor: const Color(0xFF1B6B72),
                label: 'Customers',
                value: '${summary.customerCount}',
              ),
              _SideMetricRow(
                icon: Icons.trending_up_outlined,
                iconColor: const Color(0xFFF59E0B),
                label: 'Avg. Order',
                value: _money(summary.averageOrder),
              ),
              const SizedBox(height: 22),
              const _SideSectionLabel('Tax & Settlement'),
              _SideMetricRow(
                icon: Icons.receipt_long_outlined,
                iconColor: const Color(0xFF64748B),
                label: 'Service Net',
                value: _money(summary.serviceNet),
              ),
              _SideMetricRow(
                icon: Icons.percent_outlined,
                iconColor: const Color(0xFF64748B),
                label: 'SST',
                value: _money(summary.sst),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DateControl extends StatelessWidget {
  final DateTime date;
  final bool isAdmin;
  final VoidCallback onPickDate;
  final VoidCallback onPreviousDate;
  final VoidCallback onNextDate;
  final bool canGoNextDate;

  const _DateControl({
    required this.date,
    required this.isAdmin,
    required this.onPickDate,
    required this.onPreviousDate,
    required this.onNextDate,
    required this.canGoNextDate,
  });

  @override
  Widget build(BuildContext context) {
    final label = DateFormat('dd/MM/yyyy').format(date);
    if (!isAdmin) {
      return Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFE8F5F5),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 14, color: _teal),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: _teal,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFFE8F5F5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TinyDateButton(
            icon: Icons.chevron_left,
            enabled: isAdmin,
            onTap: onPreviousDate,
          ),
          InkWell(
            onTap: isAdmin ? onPickDate : null,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Icon(Icons.calendar_today_outlined, size: 14, color: _teal),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: const TextStyle(
                      color: _teal,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ),
          _TinyDateButton(
            icon: Icons.chevron_right,
            enabled: canGoNextDate,
            onTap: onNextDate,
          ),
        ],
      ),
    );
  }
}

class _TinyDateButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _TinyDateButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        width: 30,
        height: 36,
        child: Icon(
          icon,
          size: 17,
          color: enabled ? _teal : const Color(0xFF94A3B8),
        ),
      ),
    );
  }
}

class _StaffDateNotice extends StatelessWidget {
  const _StaffDateNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: _muted),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Staff view is limited to today\'s paid sales.',
              style: TextStyle(
                color: _muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CollectionTile extends StatelessWidget {
  final double total;
  final int orderCount;
  final bool loading;

  const _CollectionTile({
    required this.total,
    required this.orderCount,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFDFF1FA),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Daily Collection',
                  style: TextStyle(
                    color: Color(0xFF2563EB),
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  loading
                      ? 'Loading paid sales'
                      : '$orderCount paid order${orderCount == 1 ? '' : 's'}',
                  style: const TextStyle(
                    color: Color(0xFF2563EB),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Text(
            loading ? '-' : _money(total),
            style: const TextStyle(
              color: Color(0xFF2563EB),
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _SideSectionLabel extends StatelessWidget {
  final String label;

  const _SideSectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      child: Text(
        label,
        style: const TextStyle(
          color: _ink,
          fontSize: 14,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _SideMetricRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final bool selected;
  final VoidCallback? onTap;

  const _SideMetricRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final child = Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFE8F5F5) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: _ink,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: selected ? _teal : _muted,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: _teal, size: 17),
          ],
        ],
      ),
    );
    if (onTap == null) return child;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: child,
    );
  }
}

class _HistoryOrderPane extends StatelessWidget {
  final DateTime selectedDate;
  final List<_HistoryOrder> orders;
  final _HistorySummary summary;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;
  final ValueChanged<_HistoryOrder> onTapOrder;
  final bool compact;

  const _HistoryOrderPane({
    required this.selectedDate,
    required this.orders,
    required this.summary,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onTapOrder,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _page,
      child: Column(
        children: [
          if (!compact)
            Container(
              height: 76,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Daily Order Sales - ${DateFormat('EEE, d MMM yyyy').format(selectedDate)}',
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  _HeaderStat(label: 'Orders', value: '${summary.orderCount}'),
                  const SizedBox(width: 10),
                  _HeaderStat(
                    label: 'Collection',
                    value: _money(summary.collection),
                  ),
                  const SizedBox(width: 10),
                  _IconAction(
                    icon: Icons.refresh,
                    tooltip: 'Refresh history',
                    onTap: onRefresh,
                  ),
                ],
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: onRefresh,
              color: _teal,
              child: _buildBody(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (loading) {
      return const Center(child: CircularProgressIndicator(color: _teal));
    }
    if (error != null) {
      return ListView(
        padding: const EdgeInsets.all(18),
        children: [
          _HistoryMessage(
            icon: Icons.cloud_off_outlined,
            title: 'Unable to load sales history',
            subtitle: error!,
          ),
        ],
      );
    }
    if (orders.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(18),
        children: const [
          _HistoryMessage(
            icon: Icons.receipt_long_outlined,
            title: 'No paid orders for this day',
            subtitle: 'Completed walk-in transactions will appear here.',
          ),
        ],
      );
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 18, 0, compact ? 12 : 18, 22),
      itemCount: orders.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: EdgeInsets.only(
              top: compact ? 12 : 0,
              bottom: 10,
              left: compact ? 2 : 0,
            ),
            child: Text(
              'Total - ${orders.length}',
              style: const TextStyle(
                color: _ink,
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
          );
        }
        final order = orders[index - 1];
        return _HistoryOrderCard(
          order: order,
          compact: compact,
          onTap: () => onTapOrder(order),
        );
      },
    );
  }
}

class _HeaderStat extends StatelessWidget {
  final String label;
  final String value;

  const _HeaderStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: _muted,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: const TextStyle(
              color: _teal,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryOrderCard extends StatelessWidget {
  final _HistoryOrder order;
  final bool compact;
  final VoidCallback onTap;

  const _HistoryOrderCard({
    required this.order,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: EdgeInsets.all(compact ? 12 : 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFF1F5F9)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: compact ? _buildCompact() : _buildWide(),
          ),
        ),
      ),
    );
  }

  Widget _buildWide() {
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.description_outlined,
              size: 18,
              color: Color(0xFF2563EB),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: _OrderTextBlock(
                title: order.receiptNumber,
                subtitle: DateFormat(
                  'hh:mm a, dd/MM/yyyy',
                ).format(order.createdAt),
              ),
            ),
            Expanded(
              flex: 2,
              child: _OrderTextBlock(
                title: order.customerName,
                subtitle: order.customerPhone,
              ),
            ),
            Expanded(
              flex: 2,
              child: _OrderTextBlock(
                title: order.serviceName,
                subtitle: order.therapistName == '-'
                    ? order.roomName
                    : '${order.therapistName} - ${order.roomName}',
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _money(order.totalAmount),
                  style: const TextStyle(
                    color: Color(0xFF2563EB),
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${order.itemCount} item${order.itemCount == 1 ? '' : 's'}',
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
        const Divider(height: 20, color: Color(0xFFF1F5F9)),
        Row(
          children: [
            _PaymentChip(order: order),
            const Spacer(),
            const Icon(Icons.chevron_right, color: Color(0xFFCBD5E1)),
          ],
        ),
      ],
    );
  }

  Widget _buildCompact() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.description_outlined,
              size: 17,
              color: Color(0xFF2563EB),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                order.receiptNumber,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Text(
              _money(order.totalAmount),
              style: const TextStyle(
                color: Color(0xFF2563EB),
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '${DateFormat('hh:mm a').format(order.createdAt)} - ${order.customerName}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _ink,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          '${order.serviceName} - ${order.itemCount} service${order.itemCount == 1 ? '' : 's'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _muted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        _PaymentChip(order: order),
      ],
    );
  }
}

class _OrderTextBlock extends StatelessWidget {
  final String title;
  final String subtitle;

  const _OrderTextBlock({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.isEmpty ? '-' : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _ink,
            fontSize: 13,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle.isEmpty ? '-' : subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: _muted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _PaymentChip extends StatelessWidget {
  final _HistoryOrder order;

  const _PaymentChip({required this.order});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(order.paymentIcon, size: 14, color: _muted),
          const SizedBox(width: 6),
          Text(
            '${order.paymentLabel} : ${_money(order.totalAmount)}',
            style: const TextStyle(
              color: _ink,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _HistoryMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 80),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Column(
        children: [
          Icon(icon, color: _teal, size: 34),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _ink,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _muted,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderDetailSheet extends StatelessWidget {
  final _HistoryOrder order;

  const _OrderDetailSheet({required this.order});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          18,
          0,
          18,
          MediaQuery.of(context).viewInsets.bottom + 18,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    order.receiptNumber,
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  _money(order.totalAmount),
                  style: const TextStyle(
                    color: _teal,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              DateFormat('EEEE, d MMM yyyy - hh:mm a').format(order.createdAt),
              style: const TextStyle(
                color: _muted,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 18),
            if (order.isAppointmentBooking)
              const _DetailRow('Source', 'Appointment booking'),
            _DetailRow('Customer', order.customerName),
            _DetailRow('Phone', order.customerPhone),
            _DetailRow('Service', order.serviceName),
            _DetailRow('Therapist', order.therapistName),
            _DetailRow('Room / Zone', order.roomName),
            _DetailRow('Payment', order.paymentLabel),
            const Divider(height: 28, color: _line),
            _DetailRow('Service Net', _money(order.servicePrice)),
            _DetailRow('SST', _money(order.sstAmount)),
            _DetailRow('Total', _money(order.totalAmount), strong: true),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final bool strong;

  const _DetailRow(this.label, this.value, {this.strong = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: const TextStyle(
                color: _muted,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: strong ? _teal : _ink,
                fontSize: strong ? 15 : 13,
                fontWeight: strong ? FontWeight.w900 : FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, color: _teal, size: 21),
        ),
      ),
    );
  }
}

class _HistoryCalendarDialog extends StatefulWidget {
  final DateTime initialDate;

  const _HistoryCalendarDialog({required this.initialDate});

  @override
  State<_HistoryCalendarDialog> createState() => _HistoryCalendarDialogState();
}

class _HistoryCalendarDialogState extends State<_HistoryCalendarDialog> {
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
    final currentMonth = DateTime(today.year, today.month);
    final canMoveNextMonth = _visibleMonth.isBefore(currentMonth);

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
                    onPressed: canMoveNextMonth ? () => _moveMonth(1) : null,
                    icon: const Icon(Icons.chevron_right),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: const [
                  _WeekdayLabel('SUN'),
                  _WeekdayLabel('MON'),
                  _WeekdayLabel('TUE'),
                  _WeekdayLabel('WED'),
                  _WeekdayLabel('THU'),
                  _WeekdayLabel('FRI'),
                  _WeekdayLabel('SAT'),
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
                  final isFuture = cleanDay.isAfter(today);

                  return InkWell(
                    onTap: isFuture
                        ? null
                        : () => Navigator.pop(context, cleanDay),
                    borderRadius: BorderRadius.circular(18),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected ? _teal : Colors.transparent,
                        border: isToday && !isSelected
                            ? Border.all(color: _teal)
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
                              : isFuture
                              ? const Color(0xFFE2E8F0)
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
                      foregroundColor: _teal,
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

class _WeekdayLabel extends StatelessWidget {
  final String label;

  const _WeekdayLabel(this.label);

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

String _money(double value) => value.toStringAsFixed(2);
