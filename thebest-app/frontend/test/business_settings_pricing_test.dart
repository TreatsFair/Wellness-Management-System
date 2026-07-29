import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/data/repositories/business_settings_repository.dart';

BusinessRuleSettings _settings({
  required String billplzMode,
  required String counterMode,
  String appointmentAddonMode = 'exclusive',
  required String rounding,
  double rate = 6,
}) => BusinessRuleSettings(
  sstEnabled: true,
  billplzSstPricingMode: billplzMode,
  counterSstPricingMode: counterMode,
  appointmentAddonSstPricingMode: appointmentAddonMode,
  sstRatePercent: rate,
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

    test('exclusive SST is added on top of RM99 and remains additive', () {
      final sixPercent = _settings(
        billplzMode: 'inclusive',
        counterMode: 'exclusive',
        rounding: 'nearest_10_sen',
      ).priceBreakdown(99, origin: PaymentOrigin.counter);
      expect(sixPercent.servicePrice, 99);
      expect(sixPercent.sstAmount, 5.9);
      expect(sixPercent.totalAmount, 104.9);
      expect(
        sixPercent.servicePrice + sixPercent.sstAmount,
        sixPercent.totalAmount,
      );

      final eightPercent = _settings(
        billplzMode: 'inclusive',
        counterMode: 'exclusive',
        rounding: 'nearest_10_sen',
        rate: 8,
      ).priceBreakdown(99, origin: PaymentOrigin.counter);
      expect(eightPercent.servicePrice, 99);
      expect(eightPercent.sstAmount, 7.9);
      expect(eightPercent.totalAmount, 106.9);
      expect(
        eightPercent.servicePrice + eightPercent.sstAmount,
        eightPercent.totalAmount,
      );
    });

    test('PV128 appointment add-on has no SST and keeps its total', () {
      final settings = _settings(
        billplzMode: 'inclusive',
        counterMode: 'inclusive',
        appointmentAddonMode: 'disabled',
        rounding: 'nearest_cent',
      );

      final addOn = settings.priceBreakdown(
        39,
        origin: PaymentOrigin.appointmentAddon,
      );
      expect(addOn.servicePrice, 39);
      expect(addOn.sstAmount, 0);
      expect(addOn.totalAmount, 39);
    });

    test('Taman Wahyu appointment add-on adds SST rounded to RM0.10', () {
      final settings = _settings(
        billplzMode: 'inclusive',
        counterMode: 'exclusive',
        appointmentAddonMode: 'exclusive',
        rounding: 'nearest_10_sen',
      );

      final addOn = settings.priceBreakdown(
        39,
        origin: PaymentOrigin.appointmentAddon,
      );
      expect(addOn.servicePrice, 39);
      expect(addOn.sstAmount, 2.3);
      expect(addOn.totalAmount, 41.3);
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
