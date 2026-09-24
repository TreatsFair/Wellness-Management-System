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

  Future<bool> resendConfirmationEmail(
    String attemptId, {
    String? recipientEmail,
  }) async {
    final result = await _client.functions.invoke(
      'booking-api',
      body: {
        'action': 'manual_resend_confirmation',
        'attempt_id': attemptId,
        if (recipientEmail != null) 'recipient_email': recipientEmail.trim(),
      },
    );
    final data = result.data;
    if (data is Map && data['ok'] == true && data['status'] == 'sent') {
      return data['recipient_mode'] == 'staging_test_recipient';
    }
    final message = data is Map ? data['error']?.toString() : null;
    throw Exception(message == null || message.isEmpty
        ? 'The confirmation email could not be sent.'
        : message);
  }

  Future<void> requestFullFiuuRefund(String attemptId, String reason) async {
    await _client.rpc(
      'request_admin_fiuu_full_refund',
      params: {'p_attempt_id': attemptId, 'p_reason': reason.trim()},
    );
  }
}
