import '../services/supabase_table_service.dart';
import 'appointment_repository.dart';
import 'repository_utils.dart';

class TherapistRepository {
  TherapistRepository({SupabaseTableService? table})
    : _table = table ?? SupabaseTableService('therapists'),
      _appointments = AppointmentRepository();

  final SupabaseTableService _table;
  final AppointmentRepository _appointments;

  Future<List<Map<String, dynamic>>> getTherapists() {
    return _table.list(orderBy: 'name');
  }

  Future<List<Map<String, dynamic>>> listTherapists() => getTherapists();

  Future<List<Map<String, dynamic>>> getActiveTherapists() async {
    final rows = await getTherapists();
    return rows.where((row) => isActiveRow(row) && _isTherapistRole(row)).toList();
  }

  Future<Map<String, dynamic>?> getAvailableCounterStaff() async {
    final rows = await getTherapists();
    final availableCounters = rows
        .where(
          (row) =>
              isActiveRow(row) &&
              _isCounterRole(row) &&
              asBool(row['availabilityStatus'], true),
        )
        .toList();
    if (availableCounters.isEmpty) return null;
    return availableCounters.first;
  }

  Future<Map<String, dynamic>?> getTherapist(String id) => _table.getById(id);

  Future<Map<String, dynamic>> addTherapist(Map<String, dynamic> values) {
    return _table.create(values);
  }

  Future<Map<String, dynamic>> createTherapist(Map<String, dynamic> values) {
    return addTherapist(values);
  }

  Future<Map<String, dynamic>> updateTherapist(
    String id,
    Map<String, dynamic> values,
  ) {
    return _table.update(id, values);
  }

  Future<void> deleteTherapist(String id) => _table.delete(id);

  Future<Map<String, dynamic>> getTherapistAppointmentStats(
    String therapistId, {
    DateTime? date,
  }) async {
    final rows = await _appointments.getAppointmentsByTherapist(
      therapistId,
      date: date ?? DateTime.now(),
    );
    final completed = rows
        .where((row) => asString(row['status']).toLowerCase() == 'completed')
        .length;
    return {
      'totalAppointments': rows.length,
      'completedAppointments': completed,
    };
  }
}

bool _isTherapistRole(Map<String, dynamic> row) {
  final role = asString(row['role'], asString(row['staffRole'])).toLowerCase();
  if (role.isEmpty) return true;
  return role == 'therapist';
}

bool _isCounterRole(Map<String, dynamic> row) {
  final role = asString(row['role'], asString(row['staffRole'])).toLowerCase();
  return role == 'counter' || role == 'cashier';
}
