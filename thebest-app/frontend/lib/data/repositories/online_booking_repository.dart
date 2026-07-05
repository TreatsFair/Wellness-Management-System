import 'package:supabase_flutter/supabase_flutter.dart';

class OnlineBookingRepository {
  OnlineBookingRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<Map<String, dynamic>> load(String outletId) async {
    final results = await Future.wait([
      _client
          .from('online_booking_outlet_settings')
          .select()
          .eq('outlet_id', outletId)
          .single(),
      _client
          .from('online_booking_services')
          .select()
          .eq('outlet_id', outletId)
          .order('display_order'),
      _client
          .from('services')
          .select('id,name,duration,is_active')
          .eq('outlet_id', outletId)
          .order('name'),
      _client
          .from('rooms')
          .select('id,name,total_slots,is_active')
          .eq('outlet_id', outletId)
          .order('name'),
      _client
          .from('online_booking_service_rooms')
          .select()
          .eq('outlet_id', outletId),
      _client
          .from('online_booking_service_hours')
          .select()
          .eq('outlet_id', outletId)
          .order('day_of_week'),
      _client
          .from('online_booking_closures')
          .select()
          .eq('outlet_id', outletId)
          .order('closure_date'),
    ]);
    return {
      'settings': Map<String, dynamic>.from(results[0] as Map),
      'catalogue': _maps(results[1]),
      'services': _maps(results[2]),
      'rooms': _maps(results[3]),
      'roomLinks': _maps(results[4]),
      'hours': _maps(results[5]),
      'closures': _maps(results[6]),
    };
  }

  Future<void> saveSettings(
    String outletId,
    Map<String, dynamic> values,
  ) async {
    await _client.from('online_booking_outlet_settings').upsert({
      'outlet_id': outletId,
      ...values,
      'slot_interval_minutes': 30,
      'maximum_booking_days': 7,
      'same_day_booking_allowed': false,
      'public_therapist_names_allowed': false,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'outlet_id');
  }

  Future<String> saveService({
    required String outletId,
    String? id,
    required Map<String, dynamic> values,
    required Set<String> roomIds,
    required List<Map<String, dynamic>> hours,
  }) async {
    final payload = {
      'outlet_id': outletId,
      ...values,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    final row = id == null
        ? await _client
              .from('online_booking_services')
              .insert(payload)
              .select('id')
              .single()
        : await _client
              .from('online_booking_services')
              .update(payload)
              .eq('id', id)
              .eq('outlet_id', outletId)
              .select('id')
              .single();
    final catalogueId = row['id'].toString();
    await _client
        .from('online_booking_service_rooms')
        .delete()
        .eq('online_booking_service_id', catalogueId);
    if (roomIds.isNotEmpty) {
      await _client
          .from('online_booking_service_rooms')
          .insert(
            roomIds
                .map(
                  (roomId) => {
                    'online_booking_service_id': catalogueId,
                    'room_id': roomId,
                    'outlet_id': outletId,
                  },
                )
                .toList(),
          );
    }
    await _client
        .from('online_booking_service_hours')
        .delete()
        .eq('online_booking_service_id', catalogueId);
    if (hours.isNotEmpty) {
      await _client
          .from('online_booking_service_hours')
          .insert(
            hours
                .map(
                  (hour) => {
                    ...hour,
                    'online_booking_service_id': catalogueId,
                    'outlet_id': outletId,
                  },
                )
                .toList(),
          );
    }
    return catalogueId;
  }

  Future<void> deleteService(String id) =>
      _client.from('online_booking_services').delete().eq('id', id);

  Future<void> addClosure(Map<String, dynamic> value) =>
      _client.from('online_booking_closures').insert(value);
  Future<void> deleteClosure(String id) =>
      _client.from('online_booking_closures').delete().eq('id', id);

  static List<Map<String, dynamic>> _maps(Object? rows) => (rows as List)
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
}
