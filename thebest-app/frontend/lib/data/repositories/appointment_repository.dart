import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/outlets/outlet_context.dart';
import '../../core/services/payment_service.dart';
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

  Future<Map<String, dynamic>> cancelAppointment(String id) {
    return updateAppointment(id, {'status': 'cancelled'});
  }

  Future<Map<String, dynamic>> voidAppointment(String id) {
    return updateAppointment(id, {
      'status': 'cancelled',
      'paymentStatus': 'voided',
    });
  }

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
      allowLateExtensionOverlap:
          asBool(appointmentUpdates['allowLateExtensionOverlap']),
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
  }) async {
    final result = await _table.client.rpc(
      'start_appointment_service',
      params: {
        'p_appointment_id': id,
        'p_started_at': (startedAt ?? DateTime.now()).toUtc().toIso8601String(),
      },
    );
    return _firstResultMap(result);
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

  Future<void> startAppointmentGroup(
    Iterable<String> appointmentIds, {
    DateTime? startedAt,
  }) async {
    final timestamp = startedAt ?? DateTime.now();
    for (final id in appointmentIds) {
      await startAppointment(id, startedAt: timestamp);
    }
  }

  Future<Map<String, dynamic>> switchTherapist({
    required String appointmentId,
    required String newTherapistId,
    String splitMethod = 'service_time',
    String reason = '',
  }) async {
    final rows = await _table.client.rpc(
      'switch_appointment_therapist',
      params: {
        'p_appointment_id': appointmentId,
        'p_new_therapist_id': newTherapistId,
        'p_split_method': splitMethod,
        'p_reason': reason,
      },
    );
    final row = _firstResultMap(rows);
    if (row['success'] != true) {
      throw Exception(
        asString(
          row['error_message'] ?? row['errorMessage'],
          asString(row['error_code'] ?? row['errorCode'], 'Switch failed'),
        ),
      );
    }
    return row;
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

  Future<void> voidAppointmentGroup(String appointmentGroupId) async {
    final rows = await _table.findBy(
      'appointment_group_id',
      appointmentGroupId,
    );
    for (final row in rows) {
      final id = asString(row['id']);
      if (id.isNotEmpty) {
        await voidAppointment(id);
      }
    }
  }

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
          if (entry.value['endTime'] != null) 'end_time': entry.value['endTime'],
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
