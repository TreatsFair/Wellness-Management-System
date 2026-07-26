import 'package:flutter/foundation.dart';

class OutletOption {
  const OutletOption({
    required this.id,
    required this.code,
    required this.name,
  });

  final String id;
  final String code;
  final String name;
}

class OutletContext {
  OutletContext._();

  static const pv128 = OutletOption(
    id: '00000000-0000-0000-0000-000000000128',
    code: 'pv128',
    name: 'PV128',
  );

  static const tamanWahyu = OutletOption(
    id: '00000000-0000-0000-0000-000000000002',
    code: 'taman-wahyu',
    name: 'Taman Wahyu',
  );

  static const outlets = <OutletOption>[pv128, tamanWahyu];
  static final ValueNotifier<String> activeOutletId = ValueNotifier(pv128.id);

  static const outletScopedTables = <String>{
    'customers',
    'therapists',
    'rooms',
    'services',
    'service_categories',
    'appointments',
    'appointment_groups',
    'transactions',
    'booking_holds',
    'business_settings',
    'business_hours',
    'online_booking_outlet_settings',
    'online_booking_services',
    'online_booking_service_rooms',
    'online_booking_service_hours',
    'online_booking_closures',
    'therapist_working_hours',
    'therapist_unavailability',
    'notifications',
  };

  static OutletOption get activeOutlet => outletById(activeOutletId.value);

  static OutletOption outletById(String id) =>
      outlets.firstWhere((outlet) => outlet.id == id, orElse: () => pv128);

  static void select(String outletId) {
    final normalized = outletById(outletId).id;
    if (activeOutletId.value != normalized) activeOutletId.value = normalized;
  }
}
