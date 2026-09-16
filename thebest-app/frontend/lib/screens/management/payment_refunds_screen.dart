import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/outlets/outlet_context.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories/booking_payment_repository.dart';
import '../../widgets/app_date_range_dialog.dart';
import '../../widgets/management_catalogue_shell.dart';

enum _PaymentView { all, payments, refunds, attention }

enum _PaymentDateFilter { allTime, today, last7Days, last30Days, custom }

class PaymentRefundsScreen extends StatefulWidget {
  const PaymentRefundsScreen({super.key});

  @override
  State<PaymentRefundsScreen> createState() => _PaymentRefundsScreenState();
}

class _PaymentRefundsScreenState extends State<PaymentRefundsScreen> {
  final _repository = BookingPaymentRepository();
  final _currency = NumberFormat.currency(symbol: 'RM ', decimalDigits: 2);
  final _dateTime = DateFormat('d MMM yyyy, h:mm a');
  final _syncTime = DateFormat('h:mm a');
  List<_PaymentRecord> _records = const [];
  _PaymentView _view = _PaymentView.all;
  _PaymentDateFilter _dateFilter = _PaymentDateFilter.allTime;
  DateTimeRange? _customDateRange;
  Timer? _refreshTimer;
  bool _loading = true;
  bool _refreshing = false;
  DateTime? _lastSyncedAt;
  String? _error;

  @override
  void initState() {
    super.initState();
    OutletContext.activeOutletId.addListener(_onOutletChanged);
    _load();
    _refreshTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    OutletContext.activeOutletId.removeListener(_onOutletChanged);
    super.dispose();
  }

  void _onOutletChanged() => _load();

  Future<void> _load({bool silent = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final rows = await _repository.listForActiveOutlet();
      if (!mounted) return;
      setState(() {
        _records = rows.map(_PaymentRecord.fromMap).toList();
        _loading = false;
        _lastSyncedAt = DateTime.now();
        _error = null;
      });
    } catch (error) {
      if (!mounted || silent) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    } finally {
      _refreshing = false;
    }
  }

  List<_PaymentRecord> get _dateFiltered => _records
      .where(_matchesDateFilter)
      .toList();

  List<_PaymentRecord> get _filtered => _dateFiltered
      .where((record) => switch (_view) {
            _PaymentView.all => true,
            _PaymentView.payments => !record.hasRefundActivity,
            _PaymentView.refunds => record.hasRefundActivity,
            _PaymentView.attention => record.needsAttention,
          })
      .toList();

  int _viewCount(_PaymentView view) => _dateFiltered.where((record) {
        return switch (view) {
          _PaymentView.all => true,
          _PaymentView.payments => !record.hasRefundActivity,
          _PaymentView.refunds => record.hasRefundActivity,
          _PaymentView.attention => record.needsAttention,
        };
      }).length;

  int get _paidCount => _dateFiltered.where((record) => record.isPaid).length;
  int get _processingCount =>
      _dateFiltered.where((record) => record.isProcessing).length;
  int get _refundedCount =>
      _dateFiltered.where((record) => record.isRefunded).length;
  int get _attentionCount =>
      _dateFiltered.where((record) => record.needsAttention).length;

  DateTimeRange? get _activeDateRange {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (_dateFilter) {
      _PaymentDateFilter.allTime => null,
      _PaymentDateFilter.today => DateTimeRange(start: today, end: now),
      _PaymentDateFilter.last7Days => DateTimeRange(
          start: today.subtract(const Duration(days: 6)),
          end: now,
        ),
      _PaymentDateFilter.last30Days => DateTimeRange(
          start: today.subtract(const Duration(days: 29)),
          end: now,
        ),
      _PaymentDateFilter.custom => _customDateRange,
    };
  }

  bool _matchesDateFilter(_PaymentRecord record) {
    final range = _activeDateRange;
    if (range == null) return true;
    final activityAt = record.activityAt;
    if (activityAt == null) return false;
    final start = DateTime(range.start.year, range.start.month, range.start.day);
    final end = DateTime(
      range.end.year,
      range.end.month,
      range.end.day,
      23,
      59,
      59,
      999,
    );
    return !activityAt.isBefore(start) && !activityAt.isAfter(end);
  }

  String get _dateFilterLabel => switch (_dateFilter) {
    _PaymentDateFilter.allTime => 'All time',
    _PaymentDateFilter.today => 'Today',
    _PaymentDateFilter.last7Days => 'Last 7 days',
    _PaymentDateFilter.last30Days => 'Last 30 days',
    _PaymentDateFilter.custom => _customDateRange == null
        ? 'Custom range'
        : '${DateFormat('d MMM').format(_customDateRange!.start)} – ${DateFormat('d MMM').format(_customDateRange!.end)}',
  };

  void _selectDateFilter(_PaymentDateFilter filter) {
    setState(() {
      _dateFilter = filter;
      if (filter != _PaymentDateFilter.custom) _customDateRange = null;
    });
  }

  Future<void> _pickCustomDateRange() async {
    final now = DateTime.now();
    final selected = await showAppDateRangeDialog(
      context: context,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialStartDate: _customDateRange?.start ??
          now.subtract(const Duration(days: 29)),
      initialEndDate: _customDateRange?.end ?? now,
    );
    if (!mounted || selected == null) return;
    setState(() {
      _customDateRange = selected;
      _dateFilter = _PaymentDateFilter.custom;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final filteredCount = _filtered.length;
    final contentTitle = switch (_view) {
      _PaymentView.all => 'All payment activity',
      _PaymentView.payments => 'Payment attempts',
      _PaymentView.refunds => 'Refund activity',
      _PaymentView.attention => 'Needs review',
    };
    final syncLabel = _lastSyncedAt == null
        ? 'Not synced yet'
        : 'Synced ${_syncTime.format(_lastSyncedAt!)}';
    return ManagementCatalogueShell(
      moduleTitle: 'Payments & Refunds',
      moduleSubtitle: '${OutletContext.activeOutlet.name} · Read-only activity',
      contentTitle: contentTitle,
      itemCountLabel:
          '$filteredCount ${filteredCount == 1 ? 'record' : 'records'} · $_dateFilterLabel',
      primaryAction: CataloguePrimaryButton(
        icon: Icons.refresh_rounded,
        label: 'Refresh',
        onPressed: _refreshing ? null : () => _load(),
        busy: _refreshing,
      ),
      headerActions: wide
          ? Text(
              syncLabel,
              style: AppText.caption.copyWith(color: context.appMuted),
            )
          : null,
      navigation: _desktopNavigation(),
      mobileNavigation: _mobileNavigation(),
      toolbar: _PaymentDateFilterBar(
        selected: _dateFilter,
        selectedLabel: _dateFilterLabel,
        onSelected: _selectDateFilter,
        onCustom: _pickCustomDateRange,
      ),
      content: _buildBody(context),
    );
  }

  Widget _desktopNavigation() => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _navigationTile(
            view: _PaymentView.all,
            icon: Icons.payments_outlined,
            title: 'All activity',
            subtitle: 'Payments and refunds',
          ),
          _navigationTile(
            view: _PaymentView.payments,
            icon: Icons.account_balance_wallet_outlined,
            title: 'Payment attempts',
            subtitle: 'No refund activity',
          ),
          _navigationTile(
            view: _PaymentView.refunds,
            icon: Icons.currency_exchange_rounded,
            title: 'Refund activity',
            subtitle: 'Requested or completed',
          ),
          _navigationTile(
            view: _PaymentView.attention,
            icon: Icons.priority_high_rounded,
            title: 'Needs review',
            subtitle: 'Staff attention required',
          ),
        ],
      );

  Widget _navigationTile({
    required _PaymentView view,
    required IconData icon,
    required String title,
    required String subtitle,
  }) =>
      CatalogueSidebarTile(
        icon: icon,
        title: title,
        subtitle: subtitle,
        count: _viewCount(view),
        selected: _view == view,
        onTap: () => setState(() => _view = view),
      );

  Widget _mobileNavigation() => CatalogueMobileNavigation(
        children: [
          for (final view in _PaymentView.values)
            CatalogueNavigationChip(
              label: switch (view) {
                _PaymentView.all => 'All · ${_viewCount(view)}',
                _PaymentView.payments => 'Payments · ${_viewCount(view)}',
                _PaymentView.refunds => 'Refunds · ${_viewCount(view)}',
                _PaymentView.attention => 'Review · ${_viewCount(view)}',
              },
              selected: _view == view,
              onTap: () => setState(() => _view = view),
            ),
        ],
      );

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _PaymentError(onRetry: () => _load());
    }
    final filtered = _filtered;
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1180),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  child: _PaymentSummary(
                    paid: _paidCount,
                    processing: _processingCount,
                    refunded: _refundedCount,
                    attention: _attentionCount,
                  ),
                ),
              ),
            ),
          ),
          if (filtered.isEmpty)
            SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg,
                      0,
                      AppSpacing.lg,
                      AppSpacing.xxl,
                    ),
                    child: _PaymentEmpty(
                      view: _view,
                      dateLabel: _dateFilterLabel,
                    ),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.xxl,
              ),
              sliver: SliverList.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppSpacing.md),
                itemBuilder: (context, index) => Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1180),
                    child: _PaymentCard(
                      record: filtered[index],
                      currency: _currency,
                      dateTime: _dateTime,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PaymentRecord {
  const _PaymentRecord({
    required this.orderId,
    required this.amount,
    required this.paymentStatus,
    required this.transactionId,
    required this.channel,
    required this.customerName,
    required this.customerPhone,
    required this.customerEmail,
    required this.bookingStart,
    required this.paymentReceived,
    required this.paymentCreated,
    required this.paymentUpdated,
    required this.refundStatus,
    required this.refundId,
    required this.refundRequested,
    required this.refundCompleted,
    required this.refundUpdated,
    required this.refundErrorCode,
    required this.refundError,
  });

  factory _PaymentRecord.fromMap(Map<String, dynamic> row) {
    DateTime? date(String key) =>
        DateTime.tryParse(row[key]?.toString() ?? '')?.toLocal();
    return _PaymentRecord(
      orderId: row['order_id']?.toString() ?? '',
      amount: num.tryParse(row['amount']?.toString() ?? '') ?? 0,
      paymentStatus: row['payment_status']?.toString() ?? 'created',
      transactionId: row['gateway_transaction_id']?.toString() ?? '',
      channel: row['payment_channel']?.toString() ?? '',
      customerName: row['customer_name']?.toString() ?? 'Online customer',
      customerPhone: row['customer_phone']?.toString() ?? '',
      customerEmail: row['customer_email']?.toString() ?? '',
      bookingStart: date('booking_start_at'),
      paymentReceived: date('payment_received_at'),
      paymentCreated: date('payment_created_at'),
      paymentUpdated: date('payment_updated_at'),
      refundStatus: row['refund_status']?.toString() ?? '',
      refundId: row['gateway_refund_id']?.toString() ?? '',
      refundRequested: date('refund_requested_at'),
      refundCompleted: date('refund_completed_at'),
      refundUpdated: date('refund_updated_at'),
      refundErrorCode: row['refund_error_code']?.toString() ?? '',
      refundError: row['refund_error']?.toString() ?? '',
    );
  }

  final String orderId;
  final num amount;
  final String paymentStatus;
  final String transactionId;
  final String channel;
  final String customerName;
  final String customerPhone;
  final String customerEmail;
  final DateTime? bookingStart;
  final DateTime? paymentReceived;
  final DateTime? paymentCreated;
  final DateTime? paymentUpdated;
  final String refundStatus;
  final String refundId;
  final DateTime? refundRequested;
  final DateTime? refundCompleted;
  final DateTime? refundUpdated;
  final String refundErrorCode;
  final String refundError;

  DateTime? get activityAt => refundUpdated ??
      refundCompleted ??
      refundRequested ??
      paymentUpdated ??
      paymentReceived ??
      paymentCreated;

  bool get needsAttention =>
      refundStatus == 'needs_review' ||
      refundStatus == 'failed' ||
      (paymentStatus == 'refund_required' && refundStatus.isEmpty);

  bool get isProcessing =>
      const {'created', 'pending'}.contains(paymentStatus) ||
      const {
        'awaiting_gateway',
        'queued',
        'submitting',
        'requested',
        'checking',
      }.contains(refundStatus);

  bool get hasRefundActivity =>
      refundStatus.isNotEmpty ||
      const {'refund_required', 'refunded'}.contains(paymentStatus);

  bool get isPaid => paymentStatus == 'confirmed' && !hasRefundActivity;

  bool get isRefunded =>
      refundStatus == 'succeeded' || paymentStatus == 'refunded';

  String get statusLabel {
    if (refundStatus == 'needs_review') return 'Needs review';
    if (refundStatus == 'failed') return 'Refund failed';
    if (refundStatus == 'succeeded' || paymentStatus == 'refunded') {
      return 'Refunded';
    }
    if (refundStatus == 'requested') return 'Refund requested';
    if (const {'awaiting_gateway', 'queued', 'submitting', 'checking'}
        .contains(refundStatus)) {
      return 'Refund processing';
    }
    return switch (paymentStatus) {
      'confirmed' => 'Paid',
      'failed' => 'Payment failed',
      'pending' => 'Payment pending',
      'created' => 'Awaiting payment',
      'refund_required' => 'Refund required',
      _ => 'Awaiting payment',
    };
  }

  String get refundLabel => switch (refundStatus) {
    'needs_review' => 'Needs review',
    'failed' => 'Failed',
    'succeeded' => 'Completed',
    'requested' => 'Requested',
    'awaiting_gateway' || 'queued' || 'submitting' || 'checking' =>
      'Processing',
    _ => paymentStatus == 'refunded'
        ? 'Completed'
        : paymentStatus == 'refund_required'
        ? 'Required'
        : 'Not requested',
  };

  Color get refundColor => switch (refundStatus) {
    'needs_review' || 'failed' => AppColors.danger,
    'succeeded' => AppColors.success,
    'requested' || 'awaiting_gateway' || 'queued' || 'submitting' ||
    'checking' => AppColors.warning,
    _ => AppColors.muted,
  };

  Color get refundSoftColor => switch (refundStatus) {
    'needs_review' || 'failed' => AppColors.dangerSoft,
    'succeeded' => AppColors.successSoft,
    'requested' || 'awaiting_gateway' || 'queued' || 'submitting' ||
    'checking' => AppColors.warningSoft,
    _ => AppColors.canvas,
  };

  Color get statusColor {
    if (needsAttention) return AppColors.danger;
    if (isProcessing) return AppColors.warning;
    if (statusLabel == 'Paid' || statusLabel == 'Refunded') {
      return AppColors.success;
    }
    if (statusLabel == 'Payment failed') return AppColors.muted;
    return AppColors.info;
  }

  Color get statusSoftColor {
    if (needsAttention) return AppColors.dangerSoft;
    if (isProcessing) return AppColors.warningSoft;
    if (statusLabel == 'Paid' || statusLabel == 'Refunded') {
      return AppColors.successSoft;
    }
    return AppColors.infoSoft;
  }
}

class _PaymentDateFilterBar extends StatelessWidget {
  const _PaymentDateFilterBar({
    required this.selected,
    required this.selectedLabel,
    required this.onSelected,
    required this.onCustom,
  });

  final _PaymentDateFilter selected;
  final String selectedLabel;
  final ValueChanged<_PaymentDateFilter> onSelected;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) {
    const options = <(_PaymentDateFilter, String)>[
      (_PaymentDateFilter.allTime, 'All time'),
      (_PaymentDateFilter.today, 'Today'),
      (_PaymentDateFilter.last7Days, '7 days'),
      (_PaymentDateFilter.last30Days, '30 days'),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 680;
        return Row(
          children: [
            if (!compact) ...[
              Icon(
                Icons.calendar_month_outlined,
                size: 20,
                color: context.appMuted,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Activity date',
                style: AppText.label.copyWith(color: context.appText),
              ),
              const SizedBox(width: AppSpacing.lg),
            ],
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final option in options)
                      CatalogueNavigationChip(
                        label: option.$2,
                        selected: selected == option.$1,
                        onTap: () => onSelected(option.$1),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: managementCatalogueControlHeight,
                        height: managementCatalogueControlHeight,
                        child: IconButton.outlined(
                          tooltip: selected == _PaymentDateFilter.custom
                              ? 'Custom range: $selectedLabel'
                              : 'Custom date range',
                          onPressed: onCustom,
                          style: IconButton.styleFrom(
                            backgroundColor:
                                selected == _PaymentDateFilter.custom
                                ? context.appColors.primary
                                : context.appSurface,
                            foregroundColor:
                                selected == _PaymentDateFilter.custom
                                ? Colors.white
                                : context.appColors.primary,
                            side: BorderSide(
                              color: selected == _PaymentDateFilter.custom
                                  ? context.appColors.primary
                                  : context.appBorder,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          icon: const Icon(
                            Icons.calendar_month_rounded,
                            size: 19,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PaymentSummary extends StatelessWidget {
  const _PaymentSummary({
    required this.paid,
    required this.attention,
    required this.processing,
    required this.refunded,
  });

  final int paid;
  final int attention;
  final int processing;
  final int refunded;

  @override
  Widget build(BuildContext context) {
    final items = <(String, String, int, IconData, Color)>[
      (
        'Paid',
        'Confirmed payments',
        paid,
        Icons.check_circle_outline_rounded,
        AppColors.success,
      ),
      (
        'Processing',
        'Still updating',
        processing,
        Icons.sync_rounded,
        AppColors.warning,
      ),
      (
        'Refunded',
        'Completed refunds',
        refunded,
        Icons.currency_exchange_rounded,
        AppColors.info,
      ),
      (
        'Needs attention',
        'Review required',
        attention,
        Icons.priority_high_rounded,
        AppColors.danger,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 980
                ? 4
                : constraints.maxWidth < 340
                ? 1
                : 2;
            final gap = AppSpacing.md;
            final tileWidth =
                (constraints.maxWidth - (gap * (columns - 1))) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final item in items)
                  SizedBox(
                    width: tileWidth,
                    child: _SummaryTile(
                      label: item.$1,
                      helper: item.$2,
                      count: item.$3,
                      icon: item.$4,
                      color: item.$5,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.label,
    required this.helper,
    required this.count,
    required this.icon,
    required this.color,
  });

  final String label;
  final String helper;
  final int count;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 88,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.appSurface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: context.appBorder),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 170;
          return Row(
            children: [
              Container(
                width: compact ? 32 : 38,
                height: compact ? 32 : 38,
                decoration: BoxDecoration(
                  color: color.withAlpha(24),
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Icon(icon, color: color, size: compact ? 18 : 20),
              ),
              SizedBox(width: compact ? AppSpacing.sm : AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      label,
                      maxLines: compact ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.label,
                    ),
                    if (!compact) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        helper,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(
                          color: context.appMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(width: compact ? AppSpacing.xs : AppSpacing.sm),
              Text(
                '$count',
                style: AppText.display.copyWith(
                  fontSize: compact ? 20 : 24,
                  color: context.appText,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PaymentCard extends StatelessWidget {
  const _PaymentCard({
    required this.record,
    required this.currency,
    required this.dateTime,
  });

  final _PaymentRecord record;
  final NumberFormat currency;
  final DateFormat dateTime;

  String _date(DateTime? value) =>
      value == null ? 'Not available' : dateTime.format(value);

  @override
  Widget build(BuildContext context) {
    final contact = [record.customerPhone, record.customerEmail]
        .where((value) => value.isNotEmpty)
        .join(' · ');
    return Card(
      elevation: 0,
      color: context.appSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: context.appBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PaymentCardHeader(
              record: record,
              contact: contact,
              amount: currency.format(record.amount),
            ),
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              spacing: AppSpacing.lg,
              runSpacing: AppSpacing.lg,
              children: [
                _PaymentDetail(
                  icon: Icons.event_outlined,
                  label: 'Appointment',
                  value: _date(record.bookingStart),
                ),
                _PaymentDetail(
                  icon: Icons.account_balance_wallet_outlined,
                  label: 'Payment channel',
                  value: record.channel.isEmpty ? 'Fiuu' : record.channel,
                ),
                _PaymentDetail(
                  icon: Icons.update_rounded,
                  label: 'Last updated',
                  value: _date(record.refundCompleted ??
                      record.refundRequested ??
                      record.paymentUpdated ??
                      record.paymentCreated),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            _RefundStatusPanel(record: record, dateTime: dateTime),
            const SizedBox(height: AppSpacing.lg),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: context.appCanvas,
                borderRadius: BorderRadius.circular(AppRadius.control),
                border: Border.all(color: context.appBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'References',
                    style: AppText.label.copyWith(color: context.appText),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _ReferenceLine(label: 'Order', value: record.orderId),
                  if (record.transactionId.isNotEmpty)
                    _ReferenceLine(
                      label: 'Transaction',
                      value: record.transactionId,
                    ),
                  if (record.refundId.isNotEmpty)
                    _ReferenceLine(label: 'Refund', value: record.refundId),
                ],
              ),
            ),
            if (record.refundErrorCode.isNotEmpty ||
                record.refundError.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.dangerSoft,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Text(
                  [record.refundErrorCode, record.refundError]
                      .where((value) => value.isNotEmpty)
                      .join(' · '),
                  style: AppText.body.copyWith(color: AppColors.danger),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PaymentCardHeader extends StatelessWidget {
  const _PaymentCardHeader({
    required this.record,
    required this.contact,
    required this.amount,
  });

  final _PaymentRecord record;
  final String contact;
  final String amount;

  @override
  Widget build(BuildContext context) {
    Widget identity() => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: record.statusSoftColor,
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: Icon(
                record.paymentStatus == 'confirmed'
                    ? Icons.check_rounded
                    : record.paymentStatus == 'failed'
                    ? Icons.close_rounded
                    : Icons.payments_outlined,
                color: record.statusColor,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.customerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.heading.copyWith(color: context.appText),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    contact.isEmpty ? 'Online booking customer' : contact,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(color: context.appMuted),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.xs,
                    children: [
                      _StatusPill(
                        label: record.statusLabel,
                        foreground: record.statusColor,
                        background: record.statusSoftColor,
                      ),
                      const _StatusPill(
                        label: 'Fiuu',
                        foreground: AppColors.primary,
                        background: AppColors.primarySoft,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );

    Widget amountView({required bool horizontal}) => horizontal
        ? Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Amount',
                style: AppText.caption.copyWith(color: context.appMuted),
              ),
              Text(
                amount,
                style: AppText.heading.copyWith(color: context.appText),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Amount',
                style: AppText.caption.copyWith(color: context.appMuted),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                amount,
                style: AppText.heading.copyWith(color: context.appText),
              ),
            ],
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              identity(),
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: context.appCanvas,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: amountView(horizontal: true),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: identity()),
            const SizedBox(width: AppSpacing.lg),
            amountView(horizontal: false),
          ],
        );
      },
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.foreground,
    required this.background,
  });

  final String label;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: AppText.caption.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _RefundStatusPanel extends StatelessWidget {
  const _RefundStatusPanel({required this.record, required this.dateTime});

  final _PaymentRecord record;
  final DateFormat dateTime;

  String _date(DateTime? value) =>
      value == null ? '' : dateTime.format(value);

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      if (record.refundRequested != null)
        'Requested ${_date(record.refundRequested)}',
      if (record.refundCompleted != null)
        'Completed ${_date(record.refundCompleted)}',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: record.refundSoftColor,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: record.refundColor.withAlpha(45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            record.refundStatus.isEmpty
                ? Icons.receipt_long_outlined
                : Icons.currency_exchange_rounded,
            color: record.refundColor,
            size: 20,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Refund status',
                  style: AppText.caption.copyWith(color: context.appMuted),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  record.refundLabel,
                  style: AppText.label.copyWith(color: record.refundColor),
                ),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    details.join(' · '),
                    style: AppText.caption.copyWith(color: context.appMuted),
                  ),
                ] else if (record.refundStatus.isEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'No refund request recorded',
                    style: AppText.caption.copyWith(color: context.appMuted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          const Icon(Icons.visibility_outlined, size: 18),
        ],
      ),
    );
  }
}

class _PaymentDetail extends StatelessWidget {
  const _PaymentDetail({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: context.appMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppText.caption.copyWith(color: context.appMuted),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label.copyWith(color: context.appText),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReferenceLine extends StatelessWidget {
  const _ReferenceLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: AppText.caption.copyWith(color: context.appMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: AppText.caption.copyWith(color: context.appText),
            ),
          ),
        ],
      ),
    );
  }
}

class _PaymentEmpty extends StatelessWidget {
  const _PaymentEmpty({required this.view, required this.dateLabel});

  final _PaymentView view;
  final String dateLabel;

  @override
  Widget build(BuildContext context) {
    final (icon, message, detail) = switch (view) {
      _PaymentView.all => (
          Icons.payments_outlined,
          'No payment activity yet',
          'New online bookings will appear after the first payment attempt.',
        ),
      _PaymentView.payments => (
          Icons.account_balance_wallet_outlined,
          'No payment attempts found',
          'Payment attempts without refund activity will appear here.',
        ),
      _PaymentView.refunds => (
          Icons.currency_exchange_rounded,
          'No refund activity found',
          'Requested, processing and completed refunds will appear here.',
        ),
      _PaymentView.attention => (
          Icons.task_alt_rounded,
          'Nothing needs review',
          'Verified payments and refund exceptions will appear here.',
        ),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xl,
        vertical: AppSpacing.xxl,
      ),
      decoration: BoxDecoration(
        color: context.appSurface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: context.appBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: context.appMuted),
          const SizedBox(height: AppSpacing.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppText.heading.copyWith(color: context.appText),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: context.appMuted),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Date filter: $dateLabel · Pull down or use refresh to check again.',
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(color: context.appMuted),
          ),
        ],
      ),
    );
  }
}

class _PaymentError extends StatelessWidget {
  const _PaymentError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: AppColors.danger,
            ),
            const SizedBox(height: AppSpacing.md),
            const Text('Unable to load payments', style: AppText.heading),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Check your connection or ask an administrator to confirm the read-only payment migration is installed.',
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(color: context.appMuted),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
