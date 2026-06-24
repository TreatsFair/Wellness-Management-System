import '../services/supabase_table_service.dart';
import 'customer_repository.dart';
import 'repository_utils.dart';
import 'transaction_repository.dart';

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
    return updateAppointment(id, {
      'status': 'cancelled',
    });
  }

  Future<Map<String, dynamic>> completeAppointment(String id) {
    return updateAppointment(id, {
      'status': 'completed',
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
      final existingEnd = timeToMinutes(asString(row['endTime'], '00:00'));
      if (start < existingEnd && end > existingStart) {
        return true;
      }
    }

    return false;
  }

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
      appointmentUpdates['customerId'] = customerId;
      transactionValues['customerId'] = customerId;
    }

    await updateAppointment(appointmentId, {
      ...appointmentUpdates,
      'status': 'completed',
    });

    return TransactionRepository().createTransaction({
      ...transactionValues,
      'appointmentId': appointmentId,
      'paymentStatus': transactionValues['paymentStatus'] ?? 'paid',
    });
  }

  Future<Map<String, dynamic>> checkoutAppointmentGroup({
    required String appointmentGroupId,
    required List<String> appointmentIds,
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
      appointmentUpdates['customerId'] = customerId;
      transactionValues['customerId'] = customerId;
    }

    for (final appointmentId in appointmentIds) {
      await updateAppointment(appointmentId, {
        ...appointmentUpdates,
        'status': 'completed',
      });
    }

    return TransactionRepository().createTransaction({
      ...transactionValues,
      'appointmentGroupId': appointmentGroupId,
      'paymentStatus': transactionValues['paymentStatus'] ?? 'paid',
    });
  }

  Future<void> deleteAppointment(String id) => _table.delete(id);
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
