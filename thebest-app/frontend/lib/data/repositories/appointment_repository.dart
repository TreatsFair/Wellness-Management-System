import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/outlets/outlet_context.dart';
import '../../core/services/payment_service.dart';
import '../../core/utils/error_message.dart';
import '../services/supabase_table_service.dart';
import 'customer_repository.dart';
import 'repository_utils.dart';

class AppointmentRepository {
  AppointmentRepository({SupabaseTableService? table})
    : _table = table ?? SupabaseTableService('appointments');

  final SupabaseTableService _table;

  Future<List<Map<String, dynamic>>> listAppointments() {
    return _table.list(orderBy: 'appointment_date');
  }

  Future<List<Map<String, dynamic>>> listAppointmentsForDate(String date) {
    return getAppointmentsByDate(date);
  }

  Future<List<Map<String, dynamic>>> getAppointmentsByDate(String date) {
    return _table.findBy('appointment_date', date, orderBy: 'start_time');
  }

  Future<List<Map<String, dynamic>>> getAppointmentsInDateRange(
    String startDate,
    String endDate,
  ) {
    return _table.findBetween(
      'appointment_date',
      startDate,
      endDate,
      orderBy: 'appointment_date',
    );
  }

  Future<int> markPastAppointmentsNoShow() async {
    final result = await _table.client.rpc(
      'mark_past_appointments_no_show',
      params: {'p_outlet_id': OutletContext.activeOutletId.value},
    );
    if (result is int) return result;
    if (result is num) return result.toInt();
    return int.tryParse(result?.toString() ?? '') ?? 0;
  }

  /// Makes "service finished" real in the database. The app never writes
  /// status='completed' from a manual action (that button was removed in
  /// favor of an automatic display label) -- this is the server-side
  /// counterpart that actually persists completion once the service window
  /// has passed, and credits online-booking commission at that same moment.
  Future<int> completeDueAppointments() async {
    final result = await _table.client.rpc(
      'complete_due_appointments',
      params: {'p_outlet_id': OutletContext.activeOutletId.value},
    );
    if (result is int) return result;
    if (result is num) return result.toInt();
    return int.tryParse(result?.toString() ?? '') ?? 0;
  }

  Future<List<Map<String, dynamic>>> getAppointmentsByCustomer(
    String customerId,
  ) {
    return _table.findBy(
      'customer_id',
      customerId,
      orderBy: 'appointment_date',
      ascending: false,
    );
  }

  Future<List<Map<String, dynamic>>> getAppointmentsByTherapist(
    String therapistId, {
    DateTime? date,
  }) async {
    final rows = await _table.findBy(
      'therapist_id',
      therapistId,
      orderBy: 'start_time',
    );
    if (date == null) return rows;
    final key = dateKey(date);
    return rows.where((row) => asString(row['date']) == key).toList();
  }

  Future<List<Map<String, dynamic>>> getActiveAppointmentsForRoom(
    String roomId,
    String date,
  ) async {
    final rows = await _table.findBy('room_id', roomId, orderBy: 'start_time');
    return rows.where((row) {
      if (!_isScheduledAppointmentRow(row)) return false;
      if (asString(row['paymentStatus']).toLowerCase() == 'voided') {
        return false;
      }
      final status = asString(row['status']).toLowerCase();
      return asString(row['date']) == date && _blocksSchedule(status);
    }).toList();
  }

  Future<List<Map<String, dynamic>>> getActiveAppointmentsForTherapist(
    String therapistId,
    String date,
  ) async {
    final rows = await _table.findBy(
      'therapist_id',
      therapistId,
      orderBy: 'start_time',
    );
    return rows.where((row) {
      if (!_isScheduledAppointmentRow(row)) return false;
      if (asString(row['paymentStatus']).toLowerCase() == 'voided') {
        return false;
      }
      final status = asString(row['status']).toLowerCase();
      return asString(row['date']) == date && _blocksSchedule(status);
    }).toList();
  }

  Future<Map<String, dynamic>?> getAppointment(String id) => _table.getById(id);

  Future<Map<String, dynamic>> createAppointment(Map<String, dynamic> values) {
    return _table.create(values);
  }

  Future<Map<String, dynamic>> updateAppointment(
    String id,
    Map<String, dynamic> values,
  ) {
    return _table.update(id, values);
  }

  /// Dedicated server-side cancellation keeps cancellation metadata and
  /// resource release atomic. Never replace this with a table update.
  Future<Map<String, dynamic>> cancelAppointment(
    String id, {
    String reason = '',
  }) async {
    final row = _firstResultMap(await _table.client.rpc(
      'cancel_appointment',
      params: {'p_appointment_id': id, 'p_reason': reason},
    ));
    _throwIfOperationFailed(row, fallback: 'Unable to cancel appointment');
    return row;
  }

  /// Legacy call-site compatibility. Voiding an appointment is now the same
  /// operational cancellation RPC; payment history is deliberately retained.
  Future<Map<String, dynamic>> voidAppointment(String id) =>
      cancelAppointment(id);

  Future<bool> checkAppointmentConflict({
    required String date,
    required String startTime,
    required String endTime,
    String? therapistId,
    String? roomId,
    String? excludeAppointmentId,
  }) async {
    final rows = await getAppointmentsByDate(date);
    final start = timeToMinutes(startTime);
    final end = timeToMinutes(endTime);

    for (final row in rows) {
      if (excludeAppointmentId != null && row['id'] == excludeAppointmentId) {
        continue;
      }
      if (!_isScheduledAppointmentRow(row)) continue;
      final status = asString(row['status']).toLowerCase();
      if (!_blocksSchedule(status)) continue;

      final sameTherapist =
          therapistId != null && asString(row['therapistId']) == therapistId;
      final sameRoom = roomId != null && asString(row['roomId']) == roomId;
      if (!sameTherapist && !sameRoom) continue;

      final existingStart = timeToMinutes(asString(row['startTime'], '00:00'));
      final existingEnd =
          timeToMinutes(asString(row['endTime'], '00:00')) +
          asInt(row['bufferAfterMinutes']);
      if (start < existingEnd && end > existingStart) {
        return true;
      }
    }

    return false;
  }

  /// Updates the appointment to in_progress and records the sale atomically
  /// (single DB transaction — see checkout_appointment_with_payment). Customer
  /// creation stays a separate, non-financial step before the atomic write.
  Future<Map<String, dynamic>> checkoutAppointment({
    required String appointmentId,
    required Map<String, dynamic> appointmentUpdates,
    required Map<String, dynamic> transactionValues,
    Map<String, dynamic>? newCustomerValues,
  }) async {
    String? customerId = asString(appointmentUpdates['customerId']);
    if ((customerId.isEmpty || customerId == 'walk_in_guest') &&
        _canCreateCustomer(newCustomerValues)) {
      final customer = await CustomerRepository().addCustomer(
        newCustomerValues!,
      );
      customerId = asString(customer['id']);
    }

    final result = await PaymentService.checkoutAppointmentWithPayment(
      appointmentId: appointmentId,
      customerId: customerId,
      customerName: asString(transactionValues['customerName']),
      customerPhone: asString(transactionValues['customerPhone']),
      bookedDate: appointmentUpdates['bookedDate']?.toString(),
      bookedStartTime: appointmentUpdates['bookedStartTime']?.toString(),
      bookedEndTime: appointmentUpdates['bookedEndTime']?.toString(),
      bookedStartAt: appointmentUpdates['bookedStartAt']?.toString(),
      bookedEndAt: appointmentUpdates['bookedEndAt']?.toString(),
      endTime: appointmentUpdates['endTime']?.toString(),
      endAt: appointmentUpdates['endAt']?.toString(),
      allowLateExtensionOverlap: asBool(
        appointmentUpdates['allowLateExtensionOverlap'],
      ),
      counterStaffId: transactionValues['counterStaffId']?.toString(),
      counterStaffName: transactionValues['counterStaffName']?.toString(),
      servicePrice: asDouble(transactionValues['servicePrice']),
      sstAmount: asDouble(transactionValues['sstAmount']),
      totalAmount: asDouble(transactionValues['totalAmount']),
      paymentMethod: asString(transactionValues['paymentMethod'], 'cash'),
      receiptNumber: asString(transactionValues['receiptNumber']),
      transactionNotes: asString(transactionValues['notes']),
    );

    if (!result.success) {
      throw Exception(result.message);
    }
    return {
      'appointmentId': result.appointmentId,
      'transactionId': result.transactionId,
    };
  }

  Future<Map<String, dynamic>> startAppointment(
    String id, {
    DateTime? startedAt,
    DateTime? expectedEndAt,
    bool allowLateExtensionOverlap = false,
  }) async {
    final row = await PaymentService.startAppointmentService(
      appointmentId: id,
      startedAt: startedAt ?? DateTime.now(),
      expectedEndAt: expectedEndAt,
      allowLateExtensionOverlap: allowLateExtensionOverlap,
    );
    final actualStartedAt = asString(
      row['actual_started_at'] ?? row['actualStartedAt'],
    );
    if (asString(row['id']).isEmpty || actualStartedAt.isEmpty) {
      throw StateError('Start service did not return a started appointment.');
    }
    return row;
  }

  Future<Map<String, dynamic>> checkInPaidAppointmentWithAddOn({
    required String appointmentId,
    required List<Map<String, dynamic>> addOnServiceItems,
    required Map<String, dynamic> appointmentUpdates,
    required Map<String, dynamic> transactionValues,
  }) async {
    // Migration 122m: check-in no longer starts the service, so endTime/endAt
    // and the late-overlap flag from [appointmentUpdates] are intentionally not
    // forwarded -- check-in must not move the operational window. If an add-on
    // lengthens the service, that duration belongs to the start action.
    final result = await PaymentService.checkInAppointment(
      appointmentId: appointmentId,
      addOnServiceItems: addOnServiceItems,
      counterStaffId: transactionValues['counterStaffId']?.toString(),
      counterStaffName: transactionValues['counterStaffName']?.toString(),
      servicePrice: asDouble(transactionValues['servicePrice']),
      sstAmount: asDouble(transactionValues['sstAmount']),
      totalAmount: asDouble(transactionValues['totalAmount']),
      paymentMethod: asString(transactionValues['paymentMethod'], 'cash'),
      receiptNumber: asString(transactionValues['receiptNumber']),
    );
    if (!result.success) {
      throw AppointmentOperationException(
        code: result.errorCode ?? 'CHECK_IN_FAILED',
        message: result.message,
      );
    }
    if (result.appointmentId != appointmentId || result.checkedInAt == null) {
      throw const AppointmentOperationException(
        code: 'CHECK_IN_NOT_CONFIRMED',
        message: 'Check-in was not confirmed by the server. Refresh and retry.',
      );
    }
    return {
      'appointmentId': result.appointmentId,
      'transactionId': result.transactionId,
      'checkedInAt': result.checkedInAt,
    };
  }

  Future<PaymentResult> finalizeAndStartAppointment({
    required String appointmentId,
    required String customerName,
    required String customerPhone,
    required String guestName,
    required String guestPhone,
    required List<Map<String, dynamic>> serviceItems,
    required List<Map<String, dynamic>> paymentItems,
    String? therapistId,
    required String assignmentSource,
    String? requestedGender,
    required String roomId,
    String? roomUnitId,
    required DateTime startedAt,
    required DateTime expectedEndAt,
    required Map<String, dynamic> transactionValues,
  }) async {
    final result = await PaymentService.finalizeAndStartAppointment(
      appointmentId: appointmentId,
      customerName: customerName,
      customerPhone: customerPhone,
      guestName: guestName,
      guestPhone: guestPhone,
      serviceItems: serviceItems,
      paymentItems: paymentItems,
      therapistId: therapistId,
      assignmentSource: assignmentSource,
      requestedGender: requestedGender,
      roomId: roomId,
      roomUnitId: roomUnitId,
      startedAt: startedAt,
      expectedEndAt: expectedEndAt,
      counterStaffId: transactionValues['counterStaffId']?.toString(),
      counterStaffName: transactionValues['counterStaffName']?.toString(),
      servicePrice: asDouble(transactionValues['servicePrice']),
      sstAmount: asDouble(transactionValues['sstAmount']),
      totalAmount: asDouble(transactionValues['totalAmount']),
      paymentMethod: asString(transactionValues['paymentMethod'], 'cash'),
      receiptNumber: asString(transactionValues['receiptNumber']),
    );
    if (!result.success) {
      throw AppointmentOperationException(
        code: result.errorCode ?? 'FINALIZE_FAILED',
        message: result.message,
      );
    }
    if (result.appointmentId != appointmentId ||
        result.actualStartedAt == null ||
        result.expectedEndAt == null ||
        result.therapistId == null ||
        result.roomId == null) {
      throw const AppointmentOperationException(
        code: 'START_NOT_CONFIRMED',
        message:
            'Service start was not confirmed by the server. Refresh and retry.',
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> payAppointmentAddOns({
    required String appointmentId,
    required List<Map<String, dynamic>> addOnServiceItems,
    required Map<String, dynamic> transactionValues,
  }) async {
    final result = await PaymentService.payAppointmentAddOns(
      appointmentId: appointmentId,
      addOnServiceItems: addOnServiceItems,
      counterStaffId: transactionValues['counterStaffId']?.toString(),
      counterStaffName: transactionValues['counterStaffName']?.toString(),
      servicePrice: asDouble(transactionValues['servicePrice']),
      sstAmount: asDouble(transactionValues['sstAmount']),
      totalAmount: asDouble(transactionValues['totalAmount']),
      paymentMethod: asString(transactionValues['paymentMethod'], 'cash'),
      receiptNumber: asString(transactionValues['receiptNumber']),
    );
    if (!result.success) throw Exception(result.message);
    return {
      'appointmentId': result.appointmentId,
      'transactionId': result.transactionId,
    };
  }

  Future<Map<String, dynamic>> adjustServiceEnd(
    String id, {
    required DateTime expectedEndAt,
  }) async {
    final result = await _table.client.rpc(
      'adjust_appointment_service_end',
      params: {
        'p_appointment_id': id,
        'p_expected_end_at': expectedEndAt.toUtc().toIso8601String(),
      },
    );
    return _firstResultMap(result);
  }

  Future<Map<String, dynamic>> startAppointmentGroup(
    String appointmentGroupId,
    {
    DateTime? startedAt,
    bool allowLateExtensionOverlap = false,
  }) async {
    final row = await PaymentService.startAppointmentGroupService(
      appointmentGroupId: appointmentGroupId,
      startedAt: startedAt ?? DateTime.now(),
      allowLateExtensionOverlap: allowLateExtensionOverlap,
    );
    _throwIfOperationFailed(row, fallback: 'Unable to start group service');
    final returnedGroupId = asString(
      row['appointment_group_id'] ?? row['appointmentGroupId'],
    );
    final returnedIds = row['appointment_ids'] ?? row['appointmentIds'];
    if (returnedGroupId != appointmentGroupId ||
        returnedIds is! Iterable ||
        returnedIds.isEmpty) {
      throw const AppointmentOperationException(
        code: 'GROUP_START_NOT_CONFIRMED',
        message:
            'Group service start was not confirmed by the server. Refresh and retry.',
      );
    }
    return row;
  }

  Future<Map<String, dynamic>> checkInPaidAppointmentGroupWithAddOn({
    required String appointmentGroupId,
    required List<String> appointmentIds,
    required Map<String, List<Map<String, dynamic>>> addOnItemsByAppointment,
    required Map<String, Map<String, dynamic>> appointmentUpdatesById,
    required Map<String, dynamic> transactionValues,
  }) async {
    // Migration 122m: group check-in no longer starts any pax, so the
    // per-appointment end_time/end_at/late-overlap updates carried by
    // [appointmentUpdatesById] are intentionally not forwarded. Check-in must
    // leave every pax's operational window untouched.
    final result = await PaymentService.checkInAppointmentGroup(
      appointmentGroupId: appointmentGroupId,
      appointmentIds: appointmentIds,
      addOnItemsByAppointment: addOnItemsByAppointment,
      counterStaffId: transactionValues['counterStaffId']?.toString(),
      counterStaffName: transactionValues['counterStaffName']?.toString(),
      servicePrice: asDouble(transactionValues['servicePrice']),
      sstAmount: asDouble(transactionValues['sstAmount']),
      totalAmount: asDouble(transactionValues['totalAmount']),
      paymentMethod: asString(transactionValues['paymentMethod'], 'cash'),
      receiptNumber: asString(transactionValues['receiptNumber']),
    );
    if (!result.success) {
      throw AppointmentOperationException(
        code: result.errorCode ?? 'GROUP_CHECK_IN_FAILED',
        message: result.message,
      );
    }
    if (result.appointmentGroupId != appointmentGroupId ||
        result.checkedInAt == null) {
      throw const AppointmentOperationException(
        code: 'GROUP_CHECK_IN_NOT_CONFIRMED',
        message:
            'Group check-in was not confirmed by the server. Refresh and retry.',
      );
    }
    return {
      'appointmentGroupId': result.appointmentGroupId,
      'transactionId': result.transactionId,
      'checkedInAt': result.checkedInAt,
    };
  }

  Future<PaymentResult> finalizeAndStartAppointmentGroup({
    required String appointmentGroupId,
    required List<String> appointmentIds,
    required String customerName,
    required String customerPhone,
    required Map<String, Map<String, dynamic>> paxUpdates,
    required List<Map<String, dynamic>> paymentItems,
    required DateTime startedAt,
    required Map<String, dynamic> transactionValues,
  }) async {
    final result = await PaymentService.finalizeAndStartAppointmentGroup(
      appointmentGroupId: appointmentGroupId,
      appointmentIds: appointmentIds,
      customerName: customerName,
      customerPhone: customerPhone,
      paxUpdates: paxUpdates,
      paymentItems: paymentItems,
      startedAt: startedAt,
      counterStaffId: transactionValues['counterStaffId']?.toString(),
      counterStaffName: transactionValues['counterStaffName']?.toString(),
      servicePrice: asDouble(transactionValues['servicePrice']),
      sstAmount: asDouble(transactionValues['sstAmount']),
      totalAmount: asDouble(transactionValues['totalAmount']),
      paymentMethod: asString(transactionValues['paymentMethod'], 'cash'),
      receiptNumber: asString(transactionValues['receiptNumber']),
    );
    if (!result.success) {
      throw AppointmentOperationException(
        code: result.errorCode ?? 'GROUP_FINALIZE_FAILED',
        message: result.message,
      );
    }
    if (result.appointmentGroupId != appointmentGroupId ||
        result.actualStartedAt == null ||
        result.appointmentIds.length != appointmentIds.length) {
      throw const AppointmentOperationException(
        code: 'GROUP_START_NOT_CONFIRMED',
        message:
            'Group service start was not confirmed by the server. Refresh and retry.',
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> payAppointmentGroupAddOns({
    required String appointmentGroupId,
    required List<String> appointmentIds,
    required Map<String, List<Map<String, dynamic>>> addOnItemsByAppointment,
    required Map<String, dynamic> transactionValues,
  }) async {
    final result = await PaymentService.payAppointmentGroupAddOns(
      appointmentGroupId: appointmentGroupId,
      appointmentIds: appointmentIds,
      addOnItemsByAppointment: addOnItemsByAppointment,
      counterStaffId: transactionValues['counterStaffId']?.toString(),
      counterStaffName: transactionValues['counterStaffName']?.toString(),
      servicePrice: asDouble(transactionValues['servicePrice']),
      sstAmount: asDouble(transactionValues['sstAmount']),
      totalAmount: asDouble(transactionValues['totalAmount']),
      paymentMethod: asString(transactionValues['paymentMethod'], 'cash'),
      receiptNumber: asString(transactionValues['receiptNumber']),
    );
    if (!result.success) throw Exception(result.message);
    return {
      'appointmentGroupId': result.appointmentGroupId,
      'transactionId': result.transactionId,
    };
  }

  Future<Map<String, dynamic>> switchTherapist({
    required String appointmentId,
    required String newTherapistId,
    String splitMethod = 'service_time',
    String reason = '',
    String? assignmentSource,
    String? requestedGender,
  }) async {
    final rows = await _table.client.rpc(
      'switch_appointment_therapist',
      params: {
        'p_appointment_id': appointmentId,
        'p_new_therapist_id': newTherapistId,
        'p_split_method': splitMethod,
        'p_reason': reason,
        'p_assignment_source': assignmentSource,
        'p_requested_gender': requestedGender,
      },
    );
    final row = _firstResultMap(rows);
    if (row['success'] != true) {
      final code = asString(
        row['error_code'] ?? row['errorCode'],
        'SWITCH_FAILED',
      );
      throw AppointmentOperationException(
        code: code,
        message: asString(
          row['error_message'] ?? row['errorMessage'],
          code,
        ),
      );
    }
    return row;
  }

  /// Stamps assignment provenance without touching therapist_id/room_id --
  /// used when a picker selection only needs to record *why* a therapist was
  /// chosen (e.g. a walk-in's out-of-order reason) rather than replace one.
  Future<void> setAssignmentMetadata({
    required String appointmentId,
    required String assignmentSource,
    String? requestedTherapistId,
    String? requestedGender,
  }) async {
    await _table.client.rpc(
      'set_appointment_assignment_metadata',
      params: {
        'p_appointment_id': appointmentId,
        'p_assignment_source': assignmentSource,
        'p_requested_therapist_id': requestedTherapistId,
        'p_requested_gender': requestedGender,
      },
    );
  }

  Future<List<Map<String, dynamic>>> therapistAllocations(
    String appointmentId,
  ) async {
    final rows = await _table.client
        .from('appointment_therapist_allocations')
        .select()
        .eq('appointment_id', appointmentId)
        .order('commission_share', ascending: false);
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<List<Map<String, dynamic>>> therapistAllocationsForAppointments(
    Iterable<String> appointmentIds,
  ) async {
    final ids = appointmentIds.where((id) => id.trim().isNotEmpty).toSet();
    if (ids.isEmpty) return const [];
    try {
      final rows = await _table.client
          .from('appointment_therapist_allocations')
          .select()
          .inFilter('appointment_id', ids.toList());
      return rows.map((row) => Map<String, dynamic>.from(row)).toList();
    } on PostgrestException catch (error) {
      // Reports and sales history can still use the appointment's primary
      // therapist while PostgREST refreshes after a deployment.
      if (error.code == 'PGRST205') return const [];
      rethrow;
    }
  }

  Future<void> setCompletedTherapistAllocations({
    required String appointmentId,
    required List<Map<String, dynamic>> allocations,
    required String reason,
  }) async {
    final rows = await _table.client.rpc(
      'set_completed_therapist_allocations',
      params: {
        'p_appointment_id': appointmentId,
        'p_allocations': allocations,
        'p_reason': reason,
      },
    );
    final row = _firstResultMap(rows);
    if (row['success'] != true) {
      throw Exception(
        asString(
          row['error_message'] ?? row['errorMessage'],
          asString(row['error_code'] ?? row['errorCode'], 'Update failed'),
        ),
      );
    }
  }

  Future<Map<String, dynamic>> cancelAppointmentGroup(
    String appointmentGroupId, {
    String reason = '',
  }) async {
    final row = _firstResultMap(await _table.client.rpc(
      'cancel_appointment_group',
      params: {'p_group_id': appointmentGroupId, 'p_reason': reason},
    ));
    _throwIfOperationFailed(row, fallback: 'Unable to cancel group appointment');
    return row;
  }

  Future<Map<String, dynamic>> voidAppointmentGroup(String appointmentGroupId) =>
      cancelAppointmentGroup(appointmentGroupId);

  /// Updates every appointment in the group to in_progress and records ONE
  /// sale covering the group, atomically (see checkout_appointment_group_with_payment).
  Future<Map<String, dynamic>> checkoutAppointmentGroup({
    required String appointmentGroupId,
    required List<String> appointmentIds,
    required Map<String, dynamic> appointmentUpdates,
    required Map<String, dynamic> transactionValues,
    Map<String, Map<String, dynamic>> appointmentUpdatesById = const {},
    Map<String, dynamic>? newCustomerValues,
  }) async {
    String? customerId = asString(appointmentUpdates['customerId']);
    if ((customerId.isEmpty || customerId == 'walk_in_guest') &&
        _canCreateCustomer(newCustomerValues)) {
      final customer = await CustomerRepository().addCustomer(
        newCustomerValues!,
      );
      customerId = asString(customer['id']);
    }

    final perAppointmentUpdates = <String, Map<String, dynamic>>{
      for (final entry in appointmentUpdatesById.entries)
        entry.key: {
          if (entry.value['bookedDate'] != null)
            'booked_date': entry.value['bookedDate'],
          if (entry.value['bookedStartTime'] != null)
            'booked_start_time': entry.value['bookedStartTime'],
          if (entry.value['bookedEndTime'] != null)
            'booked_end_time': entry.value['bookedEndTime'],
          if (entry.value['bookedStartAt'] != null)
            'booked_start_at': entry.value['bookedStartAt'],
          if (entry.value['bookedEndAt'] != null)
            'booked_end_at': entry.value['bookedEndAt'],
          if (entry.value['endTime'] != null)
            'end_time': entry.value['endTime'],
          if (entry.value['endAt'] != null) 'end_at': entry.value['endAt'],
          if (entry.value['allowLateExtensionOverlap'] == true)
            'allow_late_extension_overlap': true,
        },
    };

    final result = await PaymentService.checkoutAppointmentGroupWithPayment(
      appointmentGroupId: appointmentGroupId,
      appointmentIds: appointmentIds,
      customerId: customerId,
      customerName: asString(transactionValues['customerName']),
      customerPhone: asString(transactionValues['customerPhone']),
      perAppointmentUpdates: perAppointmentUpdates,
      counterStaffId: transactionValues['counterStaffId']?.toString(),
      counterStaffName: transactionValues['counterStaffName']?.toString(),
      servicePrice: asDouble(transactionValues['servicePrice']),
      sstAmount: asDouble(transactionValues['sstAmount']),
      totalAmount: asDouble(transactionValues['totalAmount']),
      paymentMethod: asString(transactionValues['paymentMethod'], 'cash'),
      receiptNumber: asString(transactionValues['receiptNumber']),
      transactionNotes: asString(transactionValues['notes']),
    );

    if (!result.success) {
      throw Exception(result.message);
    }
    return {
      'appointmentGroupId': result.appointmentGroupId,
      'transactionId': result.transactionId,
    };
  }

  Future<void> deleteAppointment(String id) => _table.delete(id);
}

Map<String, dynamic> _firstResultMap(Object? rows) {
  if (rows is List && rows.isNotEmpty && rows.first is Map) {
    return Map<String, dynamic>.from(rows.first as Map);
  }
  if (rows is Map) return Map<String, dynamic>.from(rows);
  return <String, dynamic>{};
}

void _throwIfOperationFailed(
  Map<String, dynamic> row, {
  required String fallback,
}) {
  if (row['success'] == true) return;
  final code = asString(row['error_code'] ?? row['errorCode']);
  final message = asString(row['error_message'] ?? row['errorMessage'], fallback);
  throw AppointmentOperationException(
    code: code.isEmpty ? 'OPERATION_FAILED' : code,
    message: message,
  );
}

bool _canCreateCustomer(Map<String, dynamic>? values) {
  if (values == null) return false;
  final name = asString(values['name']);
  final phone = asString(values['phone']);
  if (phone.isEmpty) return false;

  final normalizedName = name.toLowerCase();
  return normalizedName.isNotEmpty &&
      normalizedName != 'guest' &&
      normalizedName != 'guest account' &&
      normalizedName != 'walk-in guest';
}

bool _blocksSchedule(String status) {
  return status == 'confirmed' || status == 'in_progress';
}

bool _isScheduledAppointmentRow(Map<String, dynamic> row) {
  final type = asString(row['type']).toLowerCase();
  return type.isEmpty || type == 'appointment' || type == 'walkin';
}
