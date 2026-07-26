import '../services/supabase_table_service.dart';
import 'repository_utils.dart';

enum PaymentOrigin { billplz, counter }

class BusinessSettingsRepository {
  BusinessSettingsRepository({SupabaseTableService? table})
    : _table = table ?? SupabaseTableService('business_settings');

  final SupabaseTableService _table;

  Future<BusinessRuleSettings> getActiveSettings() async {
    final rows = await _table.list(limit: 1);
    if (rows.isEmpty) return BusinessRuleSettings.defaults();
    return BusinessRuleSettings.fromMap(rows.first);
  }

  Future<Map<String, dynamic>?> getActiveSettingsRow() async {
    final rows = await _table.list(limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, dynamic>> saveActiveSettings(
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (id != null && id.trim().isNotEmpty) {
      return _table.update(id, values);
    }
    final existing = await getActiveSettingsRow();
    if (existing != null) {
      return _table.update(existing['id'].toString(), values);
    }
    return _table.create(values);
  }
}

class BusinessRuleSettings {
  const BusinessRuleSettings({
    required this.sstEnabled,
    required this.billplzSstPricingMode,
    required this.counterSstPricingMode,
    required this.sstRatePercent,
    required this.sstRoundingMode,
    required this.lateGraceMinutes,
    required this.noShowThresholdMinutes,
    required this.autoExtendLateArrivals,
    required this.delayWarningMinutes,
  });

  final bool sstEnabled;
  final String billplzSstPricingMode;
  final String counterSstPricingMode;
  final double sstRatePercent;
  final String sstRoundingMode;
  final int lateGraceMinutes;
  final int noShowThresholdMinutes;
  final bool autoExtendLateArrivals;
  final int delayWarningMinutes;

  factory BusinessRuleSettings.defaults() {
    return const BusinessRuleSettings(
      sstEnabled: true,
      billplzSstPricingMode: 'inclusive',
      counterSstPricingMode: 'exclusive',
      sstRatePercent: 6,
      sstRoundingMode: 'nearest_cent',
      lateGraceMinutes: 15,
      noShowThresholdMinutes: 30,
      autoExtendLateArrivals: true,
      delayWarningMinutes: 10,
    );
  }

  factory BusinessRuleSettings.fromMap(Map<String, dynamic> row) {
    final defaults = BusinessRuleSettings.defaults();
    final legacyMode = asString(
      row['sstPricingMode'] ?? row['sst_pricing_mode'],
      'exclusive',
    );
    final billplzMode = asString(
      row['billplzSstPricingMode'] ?? row['billplz_sst_pricing_mode'],
      legacyMode,
    );
    final counterMode = asString(
      row['counterSstPricingMode'] ?? row['counter_sst_pricing_mode'],
      legacyMode,
    );
    final rounding = asString(
      row['sstRoundingMode'] ?? row['sst_rounding_mode'],
    );
    return BusinessRuleSettings(
      sstEnabled: asBool(
        row['sstEnabled'] ?? row['sst_enabled'],
        defaults.sstEnabled,
      ),
      billplzSstPricingMode: _pricingMode(billplzMode),
      counterSstPricingMode: _pricingMode(counterMode),
      sstRatePercent: asDouble(
        row['sstRatePercent'] ?? row['sst_rate_percent'],
        defaults.sstRatePercent,
      ),
      sstRoundingMode: _validRoundingMode(rounding)
          ? rounding
          : defaults.sstRoundingMode,
      lateGraceMinutes: asInt(
        row['lateGraceMinutes'] ?? row['late_grace_minutes'],
        defaults.lateGraceMinutes,
      ),
      noShowThresholdMinutes: asInt(
        row['noShowThresholdMinutes'] ?? row['no_show_threshold_minutes'],
        defaults.noShowThresholdMinutes,
      ),
      autoExtendLateArrivals: asBool(
        row['autoExtendLateArrivals'] ?? row['auto_extend_late_arrivals'],
        defaults.autoExtendLateArrivals,
      ),
      delayWarningMinutes: asInt(
        row['delayWarningMinutes'] ?? row['delay_warning_minutes'],
        defaults.delayWarningMinutes,
      ),
    );
  }

  String get sstLabel {
    if (!sstEnabled || sstRatePercent <= 0) return 'SST';
    final rate = sstRatePercent % 1 == 0
        ? sstRatePercent.toStringAsFixed(0)
        : sstRatePercent.toStringAsFixed(2);
    return 'SST ($rate%)';
  }

  // Compatibility for screens that have not yet supplied a payment origin.
  // Counter is the safe operational default because only Billplz is nett at
  // Taman Wahyu.
  bool get isInclusive => isInclusiveFor(PaymentOrigin.counter);

  bool isInclusiveFor(PaymentOrigin origin) => switch (origin) {
    PaymentOrigin.billplz => billplzSstPricingMode == 'inclusive',
    PaymentOrigin.counter => counterSstPricingMode == 'inclusive',
  };

  PriceBreakdown priceBreakdown(
    double displayedServicePrice, {
    PaymentOrigin origin = PaymentOrigin.counter,
  }) {
    final grossPrice = displayedServicePrice < 0 ? 0.0 : displayedServicePrice;
    if (!sstEnabled || sstRatePercent <= 0) {
      final total = _roundAmount(grossPrice);
      return PriceBreakdown(
        servicePrice: total,
        sstAmount: 0,
        totalAmount: total,
      );
    }

    final rate = sstRatePercent / 100;
    if (isInclusiveFor(origin)) {
      final total = _roundAmount(grossPrice);
      final service = _roundToCents(total / (1 + rate));
      return PriceBreakdown(
        servicePrice: service,
        sstAmount: _roundToCents(total - service),
        totalAmount: total,
      );
    }

    final service = _roundToCents(grossPrice);
    final sst = _roundToCents(service * rate);
    return PriceBreakdown(
      servicePrice: service,
      sstAmount: sst,
      totalAmount: _roundAmount(service + sst),
    );
  }

  double _roundAmount(double value) {
    switch (sstRoundingMode) {
      case 'nearest_10_sen':
        return _roundToCents((value * 10).round() / 10);
      case 'nearest_5_sen':
        return _roundToCents((value * 20).round() / 20);
      case 'floor_cent':
        return (value * 100).floor() / 100;
      case 'ceil_cent':
        return (value * 100).ceil() / 100;
      default:
        return _roundToCents(value);
    }
  }
}

class PriceBreakdown {
  const PriceBreakdown({
    required this.servicePrice,
    required this.sstAmount,
    required this.totalAmount,
  });

  final double servicePrice;
  final double sstAmount;
  final double totalAmount;
}

bool _validRoundingMode(String value) {
  return const {
    'nearest_cent',
    'nearest_10_sen',
    'nearest_5_sen',
    'floor_cent',
    'ceil_cent',
  }.contains(value);
}

String _pricingMode(String value) =>
    value == 'inclusive' ? 'inclusive' : 'exclusive';

double _roundToCents(double value) => (value * 100).round() / 100;
