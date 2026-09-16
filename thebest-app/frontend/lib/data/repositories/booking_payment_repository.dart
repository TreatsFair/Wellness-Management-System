import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/outlets/outlet_context.dart';

class BookingPaymentRepository {
  BookingPaymentRepository({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<List<Map<String, dynamic>>> listForActiveOutlet({
    int limit = 200,
  }) async {
    final result = await _client.rpc(
      'list_admin_booking_payments',
      params: {
        'p_outlet_id': OutletContext.activeOutletId.value,
        'p_limit': limit,
      },
    );
    if (result is! List) return const [];
    return result
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }
}
