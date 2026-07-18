import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/appointments/appointment_checkin_logic.dart';

void main() {
  test('prepaid booking identifies only newly added services', () {
    final additions = appointmentAddOnItems(
      currentItems: const [
        {'id': 'foot', 'name': 'Foot Massage'},
        {'id': 'shoulder', 'name': 'Shoulder Massage'},
      ],
      paidItems: const [
        {'id': 'foot', 'name': 'Foot Massage'},
      ],
    );

    expect(additions, hasLength(1));
    expect(additions.single['id'], 'shoulder');
    expect(additions.single['lineType'], 'add_on');
  });

  test('unpaid booking treats the whole visit as unpaid, not add-on only', () {
    final additions = appointmentAddOnItems(
      currentItems: const [
        {'id': 'foot'},
        {'id': 'shoulder'},
      ],
      paidItems: const [],
    );

    expect(additions.map((item) => item['id']), ['foot', 'shoulder']);
  });

  test('explicit add-on labels survive after the add-on receipt is paid', () {
    final additions = appointmentAddOnItems(
      currentItems: const [
        {'id': 'foot', 'lineType': 'booked'},
        {'id': 'shoulder', 'lineType': 'add_on'},
      ],
      paidItems: const [
        {'id': 'foot'},
        {'id': 'shoulder'},
      ],
    );

    expect(additions, hasLength(1));
    expect(additions.single['id'], 'shoulder');
  });

  test('duplicate paid services are matched by quantity', () {
    final additions = appointmentAddOnItems(
      currentItems: const [
        {'id': 'foot'},
        {'id': 'foot'},
      ],
      paidItems: const [
        {'id': 'foot'},
      ],
    );

    expect(additions, hasLength(1));
    expect(additions.single['id'], 'foot');
  });

  test('online group items are scoped to their own appointment', () {
    final transaction = <String, dynamic>{
      'appointmentGroupId': 'group-1',
      'serviceItems': [
        {'service_id': 'foot', 'appointment_id': 'pax-1'},
        {'service_id': 'head', 'appointment_id': 'pax-2'},
      ],
    };

    final pax1 = transactionItemsForAppointment(
      transaction: transaction,
      appointmentId: 'pax-1',
    );
    final pax2 = transactionItemsForAppointment(
      transaction: transaction,
      appointmentId: 'pax-2',
    );

    expect(pax1.map(serviceItemId), ['foot']);
    expect(pax2.map(serviceItemId), ['head']);
  });

  test('paid add-on is excluded from the next amount due', () {
    final unpaid = appointmentUnpaidItems(
      currentItems: const [
        {'id': 'foot', 'lineType': 'booked'},
        {'id': 'head', 'lineType': 'add_on'},
        {'id': 'shoulder', 'lineType': 'add_on'},
      ],
      paidItems: const [
        {'service_id': 'foot'},
        {'service_id': 'head'},
      ],
    );

    expect(unpaid.map(serviceItemId), ['shoulder']);
  });

  test('group receipt amount is allocated by appointment item value', () {
    final transaction = <String, dynamic>{
      'appointmentGroupId': 'group-1',
      'totalAmount': 360,
      'serviceItems': [
        {
          'service_id': 'foot',
          'appointment_id': 'pax-1',
          'price': 120,
        },
        {
          'service_id': 'head',
          'appointment_id': 'pax-2',
          'price': 240,
        },
      ],
    };

    expect(
      transactionAmountForAppointment(
        transaction: transaction,
        appointmentId: 'pax-1',
      ),
      120,
    );
    expect(
      transactionAmountForAppointment(
        transaction: transaction,
        appointmentId: 'pax-2',
      ),
      240,
    );
  });
}
