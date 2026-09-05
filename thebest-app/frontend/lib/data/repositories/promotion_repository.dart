import 'package:supabase_flutter/supabase_flutter.dart';

class PromotionRepository {
  PromotionRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<List<Map<String, dynamic>>> list({String? outletId}) async {
    final rows = await _client.rpc(
      'list_staff_promotions',
      params: {'p_outlet_id': outletId},
    );
    return _maps(rows);
  }

  Future<List<Map<String, dynamic>>> services() async {
    final rows = await _client
        .from('services')
        .select('id,outlet_id,name,category,duration,price,is_active')
        .eq('is_active', true)
        .order('name');
    return _maps(rows);
  }

  Future<List<Map<String, dynamic>>> onlineServices() async {
    final rows = await _client
        .from('online_booking_services')
        .select(
          'service_id,outlet_id,public_name,display_price,display_order,'
          'services!inner(id,name,category,duration,is_active)',
        )
        .eq('enabled', true)
        .eq('services.is_active', true)
        .order('display_order');
    return _maps(rows).map((row) {
      final service = Map<String, dynamic>.from(row['services'] as Map);
      final publicName = row['public_name']?.toString().trim() ?? '';
      return {
        ...service,
        'id': row['service_id'],
        'outlet_id': row['outlet_id'],
        'name': publicName.isEmpty ? service['name'] : publicName,
        'display_price': row['display_price'],
      };
    }).toList();
  }

  Future<Map<String, dynamic>> save(Map<String, dynamic> payload) async {
    final result = await _client.rpc(
      'upsert_staff_promotion',
      params: {'p_payload': payload},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<String> generateCode(String promotionId) async {
    final result = await _client.rpc(
      'generate_staff_promotion_code',
      params: {'p_promotion_id': promotionId},
    );
    return result.toString();
  }

  Future<void> setActive(String promotionId, bool active) async {
    await _client.rpc(
      'set_staff_promotion_active',
      params: {'p_promotion_id': promotionId, 'p_active': active},
    );
  }

  static List<Map<String, dynamic>> _maps(Object? rows) => (rows as List)
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
}
