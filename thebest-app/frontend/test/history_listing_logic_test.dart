import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/history/history_listing_logic.dart';

class _Record {
  const _Record(this.id, {required this.paidAt, required this.serviceAt});

  final String id;
  final DateTime paidAt;
  final DateTime serviceAt;
}

void main() {
  final bookingDay = DateTime(2026, 7, 16);
  final serviceDay = DateTime(2026, 7, 20);

  test('prepaid booking appears in each listing on its relevant day', () {
    final prepaid = _Record(
      'prepaid',
      paidAt: DateTime(2026, 7, 16, 14, 30),
      serviceAt: DateTime(2026, 7, 20, 10),
    );

    final bills = filterSalesHistoryListing(
      records: [prepaid],
      selectedDate: bookingDay,
      listing: SalesHistoryListing.bills,
      paidAt: (record) => record.paidAt,
      serviceAt: (record) => record.serviceAt,
    );
    final appointments = filterSalesHistoryListing(
      records: [prepaid],
      selectedDate: serviceDay,
      listing: SalesHistoryListing.appointments,
      paidAt: (record) => record.paidAt,
      serviceAt: (record) => record.serviceAt,
    );

    expect(bills.map((record) => record.id), ['prepaid']);
    expect(appointments.map((record) => record.id), ['prepaid']);
    expect(
      filterSalesHistoryListing(
        records: [prepaid],
        selectedDate: serviceDay,
        listing: SalesHistoryListing.bills,
        paidAt: (record) => record.paidAt,
        serviceAt: (record) => record.serviceAt,
      ),
      isEmpty,
    );
  });

  test('same-day record can share both date axes without cloning', () {
    final walkIn = _Record(
      'walk-in',
      paidAt: DateTime(2026, 7, 16, 9, 5),
      serviceAt: DateTime(2026, 7, 16, 9, 5),
    );

    final bills = filterSalesHistoryListing(
      records: [walkIn],
      selectedDate: bookingDay,
      listing: SalesHistoryListing.bills,
      paidAt: (record) => record.paidAt,
      serviceAt: (record) => record.serviceAt,
    );
    final appointments = filterSalesHistoryListing(
      records: [walkIn],
      selectedDate: bookingDay,
      listing: SalesHistoryListing.appointments,
      paidAt: (record) => record.paidAt,
      serviceAt: (record) => record.serviceAt,
    );

    expect(bills.single, same(walkIn));
    expect(appointments.single, same(walkIn));
  });

  test(
    'appointment history excludes walk-ins but keeps scheduled bookings',
    () {
      expect(isScheduledHistoryAppointmentType('appointment'), isTrue);
      expect(isScheduledHistoryAppointmentType('online'), isTrue);
      expect(isScheduledHistoryAppointmentType(''), isTrue);
      expect(isScheduledHistoryAppointmentType('walkin'), isFalse);
      expect(isScheduledHistoryAppointmentType('walk-in'), isFalse);
    },
  );

  test('customer history counts only actual arrivals on the selected day', () {
    expect(
      isHistoryVisitor(actualStartedAt: null, selectedDate: bookingDay),
      isFalse,
    );
    expect(
      isHistoryVisitor(
        actualStartedAt: DateTime(2026, 7, 16, 10, 30),
        selectedDate: bookingDay,
      ),
      isTrue,
    );
    expect(
      isHistoryVisitor(
        actualStartedAt: DateTime(2026, 7, 17, 0, 5),
        selectedDate: bookingDay,
      ),
      isFalse,
    );
  });

  test('settlement service net follows paid receipts, not service day', () {
    final prepaid = _Record(
      'prepaid',
      paidAt: DateTime(2026, 7, 18, 12),
      serviceAt: DateTime(2026, 7, 19, 10),
    );

    final paidToday = filterSalesHistoryListing(
      records: [prepaid],
      selectedDate: DateTime(2026, 7, 18),
      listing: SalesHistoryListing.bills,
      paidAt: (record) => record.paidAt,
      serviceAt: (record) => record.serviceAt,
    );

    expect(sumSettlementServiceNet(paidToday, (_) => 339.62), 339.62);
  });

  test('appointment history shows the latest service time first', () {
    final early = _Record(
      'early',
      paidAt: bookingDay,
      serviceAt: DateTime(2026, 7, 20, 10),
    );
    final late = _Record(
      'late',
      paidAt: bookingDay,
      serviceAt: DateTime(2026, 7, 20, 18, 30),
    );

    final appointments = filterSalesHistoryListing(
      records: [early, late],
      selectedDate: serviceDay,
      listing: SalesHistoryListing.appointments,
      paidAt: (record) => record.paidAt,
      serviceAt: (record) => record.serviceAt,
    );

    expect(appointments.map((record) => record.id), ['late', 'early']);
  });
}
