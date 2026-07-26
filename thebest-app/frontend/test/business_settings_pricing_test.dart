import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/data/repositories/business_settings_repository.dart';

BusinessRuleSettings _settings({
  required String billplzMode,
  required String counterMode,
  required String rounding,
}) => BusinessRuleSettings(
  sstEnabled: true,
  billplzSstPricingMode: billplzMode,
  counterSstPricingMode: counterMode,
  sstRatePercent: 6,
  sstRoundingMode: rounding,
  lateGraceMinutes: 15,
  noShowThresholdMinutes: 30,
  autoExtendLateArrivals: true,
  delayWarningMinutes: 10,
);

void main() {
  group('payment-origin SST', () {
    test('PV128 remains inclusive for Billplz and counter', () {
      final settings = _settings(
        billplzMode: 'inclusive',
        counterMode: 'inclusive',
        rounding: 'nearest_cent',
      );

      expect(
        settings
            .priceBreakdown(58, origin: PaymentOrigin.billplz)
            .totalAmount,
        58,
      );
      expect(
        settings
            .priceBreakdown(58, origin: PaymentOrigin.counter)
            .totalAmount,
        58,
      );
    });

    test('Taman Wahyu Billplz is nett and counter adds rounded SST', () {
      final settings = _settings(
        billplzMode: 'inclusive',
        counterMode: 'exclusive',
        rounding: 'nearest_10_sen',
      );

      expect(
        settings
            .priceBreakdown(58, origin: PaymentOrigin.billplz)
            .totalAmount,
        58,
      );
      final counter = settings.priceBreakdown(
        58,
        origin: PaymentOrigin.counter,
      );
      expect(counter.servicePrice, 58);
      expect(counter.sstAmount, 3.5);
      expect(counter.totalAmount, 61.5);
    });

    test('nearest RM0.10 uses half-up boundaries', () {
      final settings = _settings(
        billplzMode: 'inclusive',
        counterMode: 'exclusive',
        rounding: 'nearest_10_sen',
      );

      // Feed pre-SST amounts whose 6%-inclusive totals hit the requested
      // rounding boundaries exactly.
      expect(
        settings
            .priceBreakdown(21.22 / 1.06, origin: PaymentOrigin.counter)
            .totalAmount,
        21.2,
      );
      expect(
        settings
            .priceBreakdown(21.25 / 1.06, origin: PaymentOrigin.counter)
            .totalAmount,
        21.3,
      );
      expect(
        settings
            .priceBreakdown(21.28 / 1.06, origin: PaymentOrigin.counter)
            .totalAmount,
        21.3,
      );
    });
  });
}
