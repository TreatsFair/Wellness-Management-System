import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/error_message.dart';

class PaymentResult {
  const PaymentResult({
    required this.success,
    this.appointmentId,
    this.appointmentGroupId,
    this.appointmentIds = const [],
    this.transactionId,
    this.errorCode,
    this.errorMessage,
  });

  factory PaymentResult.fromMap(Map<String, dynamic> row) {
    final ids = row['appointment_ids'] ?? row['appointmentIds'];
    return PaymentResult(
      success: row['success'] == true,
      appointmentId:
          row['appointment_id']?.toString() ?? row['appointmentId']?.toString(),
      appointmentGroupId:
          row['appointment_group_id']?.toString() ??
          row['appointmentGroupId']?.toString(),
      appointmentIds: ids is Iterable
          ? ids.map((id) => id.toString()).toList()
          : const [],
      transactionId:
          row['transaction_id']?.toString() ?? row['transactionId']?.toString(),
      errorCode: row['error_code']?.toString() ?? row['errorCode']?.toString(),
      errorMessage:
          row['error_message']?.toString() ?? row['errorMessage']?.toString(),
    );
  }

  final bool success;
  final String? appointmentId;
  final String? appointmentGroupId;
  final List<String> appointmentIds;
  final String? transactionId;
  final String? errorCode;
  final String? errorMessage;

  String get message => friendlyBookingErrorMessage(
    errorMessage ?? errorCode,
    fallback: 'Payment failed',
  );
}

/// Atomic appointment-write + transaction-write RPCs. Each call either lands
/// both writes or neither — no separate client-side transaction insert, and
/// commission is computed server-side from services/therapists data instead
/// of being trusted from the client.
class PaymentService {
  PaymentService._();

  static SupabaseClient get _client => Supabase.instance.client;

  static Future<PaymentResult> createWalkInAppointmentWithPayment({
    required String customerId,
    required String therapistId,
    required String roomId,
    required String serviceId,
    required String date,
    required String startTime,
    required String endTime,
    required double servicePrice,
    required String serviceName,
    required List<Map<String, dynamic>> serviceItems,
    required int itemCount,
    required String notes,
    required String customerName,
    required String customerPhone,
    String? counterStaffId,
    String? counterStaffName,
    required double sstAmount,
    required double totalAmount,
    required String paymentMethod,
    required String receiptNumber,
    String transactionNotes = '',
    bool startImmediately = true,
    String? draftSessionId,
  }) async {
    final rows = await _client.rpc(
      'create_staff_walkin_with_payment',
      params: {
        'p_customer_id': _nullIfBlank(customerId),
        'p_therapist_id': therapistId,
        'p_room_id': roomId,
        'p_service_id': serviceId,
        'p_date': date,
        'p_start_time': startTime,
        'p_end_time': endTime,
        'p_service_price': servicePrice,
        'p_service_name': serviceName,
        'p_service_items': serviceItems,
        'p_item_count': itemCount,
        'p_notes': notes,
        'p_customer_name': customerName,
        'p_customer_phone': customerPhone,
        'p_counter_staff_id': _nullIfBlank(counterStaffId),
        'p_counter_staff_name': counterStaffName,
        'p_sst_amount': sstAmount,
        'p_total_amount': totalAmount,
        'p_payment_method': paymentMethod,
        'p_receipt_number': receiptNumber,
        'p_transaction_notes': transactionNotes,
        'p_start_immediately': startImmediately,
        'p_draft_session_id': _nullIfBlank(draftSessionId),
      },
    );
    return PaymentResult.fromMap(_firstMap(rows));
  }

  static Future<PaymentResult> createWalkInAppointmentGroupWithPayment({
    required String customerId,
    required String groupName,
    required int paxCount,
    required String date,
    required List<Map<String, dynamic>> allocations,
    required String notes,
    required String customerName,
    required String customerPhone,
    String? counterStaffId,
    String? counterStaffName,
    required double servicePrice,
    required double sstAmount,
    required double totalAmount,
    required String paymentMethod,
    required String receiptNumber,
    String transactionNotes = '',
    bool startImmediately = true,
    String? draftSessionId,
  }) async {
    final rows = await _client.rpc(
      'create_staff_walkin_group_with_payment',
      params: {
        'p_customer_id': _nullIfBlank(customerId),
        'p_group_name': groupName,
        'p_pax_count': paxCount,
        'p_appointment_date': date,
        'p_allocations': allocations,
        'p_notes': notes,
        'p_customer_name': customerName,
        'p_customer_phone': customerPhone,
        'p_counter_staff_id': _nullIfBlank(counterStaffId),
        'p_counter_staff_name': counterStaffName,
        'p_service_price': servicePrice,
        'p_sst_amount': sstAmount,
        'p_total_amount': totalAmount,
        'p_payment_method': paymentMethod,
        'p_receipt_number': receiptNumber,
        'p_transaction_notes': transactionNotes,
        'p_start_immediately': startImmediately,
        'p_draft_session_id': _nullIfBlank(draftSessionId),
      },
    );
    return PaymentResult.fromMap(_firstMap(rows));
  }

  static Future<PaymentResult> checkoutAppointmentWithPayment({
    required String appointmentId,
    required String customerId,
    required String customerName,
    required String customerPhone,
    String? bookedDate,
    String? bookedStartTime,
    String? bookedEndTime,
    String? bookedStartAt,
    String? bookedEndAt,
    String? endTime,
    String? endAt,
    bool allowLateExtensionOverlap = false,
    String? counterStaffId,
    String? counterStaffName,
    required double servicePrice,
    required double sstAmount,
    required double totalAmount,
    required String paymentMethod,
    required String receiptNumber,
    String transactionNotes = '',
  }) async {
    final rows = await _client.rpc(
      'checkout_appointment_with_payment',
      params: {
        'p_appointment_id': appointmentId,
        'p_customer_id': _nullIfBlank(customerId),
        'p_customer_name': customerName,
        'p_customer_phone': customerPhone,
        'p_booked_date': bookedDate,
        'p_booked_start_time': bookedStartTime,
        'p_booked_end_time': bookedEndTime,
        'p_booked_start_at': bookedStartAt,
        'p_booked_end_at': bookedEndAt,
        'p_end_time': endTime,
        'p_end_at': endAt,
        'p_allow_late_extension_overlap': allowLateExtensionOverlap,
        'p_counter_staff_id': _nullIfBlank(counterStaffId),
        'p_counter_staff_name': counterStaffName,
        'p_service_price': servicePrice,
        'p_sst_amount': sstAmount,
        'p_total_amount': totalAmount,
        'p_payment_method': paymentMethod,
        'p_receipt_number': receiptNumber,
        'p_transaction_notes': transactionNotes,
      },
    );
    return PaymentResult.fromMap(_firstMap(rows));
  }

  static Future<PaymentResult> checkoutAppointmentGroupWithPayment({
    required String appointmentGroupId,
    required List<String> appointmentIds,
    required String customerId,
    required String customerName,
    required String customerPhone,
    Map<String, Map<String, dynamic>> perAppointmentUpdates = const {},
    String? counterStaffId,
    String? counterStaffName,
    required double servicePrice,
    required double sstAmount,
    required double totalAmount,
    required String paymentMethod,
    required String receiptNumber,
    String transactionNotes = '',
  }) async {
    final rows = await _client.rpc(
      'checkout_appointment_group_with_payment',
      params: {
        'p_appointment_group_id': appointmentGroupId,
        'p_appointment_ids': appointmentIds,
        'p_customer_id': _nullIfBlank(customerId),
        'p_customer_name': customerName,
        'p_customer_phone': customerPhone,
        'p_per_appointment_updates': perAppointmentUpdates,
        'p_counter_staff_id': _nullIfBlank(counterStaffId),
        'p_counter_staff_name': counterStaffName,
        'p_service_price': servicePrice,
        'p_sst_amount': sstAmount,
        'p_total_amount': totalAmount,
        'p_payment_method': paymentMethod,
        'p_receipt_number': receiptNumber,
        'p_transaction_notes': transactionNotes,
      },
    );
    return PaymentResult.fromMap(_firstMap(rows));
  }

  static Future<PaymentResult> checkInPaidAppointmentWithAddOn({
    required String appointmentId,
    required List<Map<String, dynamic>> addOnServiceItems,
    String? endTime,
    String? endAt,
    bool allowLateExtensionOverlap = false,
    String? counterStaffId,
    String? counterStaffName,
    required double servicePrice,
    required double sstAmount,
    required double totalAmount,
    required String paymentMethod,
    required String receiptNumber,
  }) async {
    final rows = await _client.rpc(
      'check_in_paid_appointment_with_addon',
      params: {
        'p_appointment_id': appointmentId,
        'p_addon_service_items': addOnServiceItems,
        'p_end_time': endTime,
        'p_end_at': endAt,
        'p_allow_late_extension_overlap': allowLateExtensionOverlap,
        'p_counter_staff_id': _nullIfBlank(counterStaffId),
        'p_counter_staff_name': counterStaffName,
        'p_service_price': servicePrice,
        'p_sst_amount': sstAmount,
        'p_total_amount': totalAmount,
        'p_payment_method': paymentMethod,
        'p_receipt_number': receiptNumber,
      },
    );
    return PaymentResult.fromMap(_firstMap(rows));
  }

  static Future<PaymentResult> payAppointmentAddOns({
    required String appointmentId,
    required List<Map<String, dynamic>> addOnServiceItems,
    String? counterStaffId,
    String? counterStaffName,
    required double servicePrice,
    required double sstAmount,
    required double totalAmount,
    required String paymentMethod,
    required String receiptNumber,
  }) async {
    final rows = await _client.rpc(
      'pay_appointment_addons',
      params: {
        'p_appointment_id': appointmentId,
        'p_addon_service_items': addOnServiceItems,
        'p_counter_staff_id': _nullIfBlank(counterStaffId),
        'p_counter_staff_name': counterStaffName,
        'p_service_price': servicePrice,
        'p_sst_amount': sstAmount,
        'p_total_amount': totalAmount,
        'p_payment_method': paymentMethod,
        'p_receipt_number': receiptNumber,
      },
    );
    return PaymentResult.fromMap(_firstMap(rows));
  }

  static Future<PaymentResult> checkInPaidAppointmentGroupWithAddOn({
    required String appointmentGroupId,
    required List<String> appointmentIds,
    required Map<String, List<Map<String, dynamic>>> addOnItemsByAppointment,
    Map<String, Map<String, dynamic>> perAppointmentUpdates = const {},
    String? counterStaffId,
    String? counterStaffName,
    required double servicePrice,
    required double sstAmount,
    required double totalAmount,
    required String paymentMethod,
    required String receiptNumber,
  }) async {
    final rows = await _client.rpc(
      'check_in_paid_appointment_group_with_addon',
      params: {
        'p_appointment_group_id': appointmentGroupId,
        'p_appointment_ids': appointmentIds,
        'p_addon_items_by_appointment': addOnItemsByAppointment,
        'p_per_appointment_updates': perAppointmentUpdates,
        'p_counter_staff_id': _nullIfBlank(counterStaffId),
        'p_counter_staff_name': counterStaffName,
        'p_service_price': servicePrice,
        'p_sst_amount': sstAmount,
        'p_total_amount': totalAmount,
        'p_payment_method': paymentMethod,
        'p_receipt_number': receiptNumber,
      },
    );
    return PaymentResult.fromMap(_firstMap(rows));
  }

  static Future<PaymentResult> payAppointmentGroupAddOns({
    required String appointmentGroupId,
    required List<String> appointmentIds,
    required Map<String, List<Map<String, dynamic>>> addOnItemsByAppointment,
    String? counterStaffId,
    String? counterStaffName,
    required double servicePrice,
    required double sstAmount,
    required double totalAmount,
    required String paymentMethod,
    required String receiptNumber,
  }) async {
    final rows = await _client.rpc(
      'pay_appointment_group_addons',
      params: {
        'p_appointment_group_id': appointmentGroupId,
        'p_appointment_ids': appointmentIds,
        'p_addon_items_by_appointment': addOnItemsByAppointment,
        'p_counter_staff_id': _nullIfBlank(counterStaffId),
        'p_counter_staff_name': counterStaffName,
        'p_service_price': servicePrice,
        'p_sst_amount': sstAmount,
        'p_total_amount': totalAmount,
        'p_payment_method': paymentMethod,
        'p_receipt_number': receiptNumber,
      },
    );
    return PaymentResult.fromMap(_firstMap(rows));
  }
}

List<Map<String, dynamic>> _asMapList(Object? rows) {
  if (rows is List) {
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }
  if (rows is Map) return [Map<String, dynamic>.from(rows)];
  return const [];
}

Map<String, dynamic> _firstMap(Object? rows) {
  final list = _asMapList(rows);
  return list.isEmpty ? <String, dynamic>{} : list.first;
}

String? _nullIfBlank(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty || trimmed == 'walk_in_guest') return null;
  return trimmed;
}
