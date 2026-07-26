import '../../core/outlets/outlet_context.dart';
import '../services/supabase_table_service.dart';
import 'appointment_repository.dart';
import 'repository_utils.dart';

class TherapistRepository {
  TherapistRepository({SupabaseTableService? table})
    : _table = table ?? SupabaseTableService('therapists'),
      _appointments = AppointmentRepository();

  final SupabaseTableService _table;
  final AppointmentRepository _appointments;

  Future<List<Map<String, dynamic>>> getTherapists() async {
    final rows = await _table.list(orderBy: 'name');
    rows.sort((left, right) {
      final orderComparison = asInt(
        left['displayOrder'],
      ).compareTo(asInt(right['displayOrder']));
      if (orderComparison != 0) return orderComparison;
      return asString(
        left['name'],
      ).toLowerCase().compareTo(asString(right['name']).toLowerCase());
    });
    return rows;
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

  Future<bool> isTherapistRotationNumberAvailable(
    int rotationNumber, {
    String? excludingTherapistId,
  }) async {
    final rows = await getTherapists();
    return !rows.any(
      (row) =>
          _isTherapistRole(row) &&
          asString(row['id']) != excludingTherapistId &&
          asInt(row['displayOrder']) == rotationNumber,
    );
  }

  Future<Map<String, dynamic>> addTherapist(Map<String, dynamic> values) async {
    if (values.containsKey('displayOrder')) return _table.create(values);
    final role = asString(values['role'], 'Therapist').trim();
    final existing = await getTherapists();
    var nextOrder = 0;
    for (final row in existing) {
      if (asString(row['role']).trim() != role) continue;
      final candidate = asInt(row['displayOrder']) + 1;
      if (candidate > nextOrder) nextOrder = candidate;
    }
    return _table.create({...values, 'displayOrder': nextOrder});
  }

  Future<Map<String, dynamic>> createTherapist(Map<String, dynamic> values) {
    return addTherapist(values);
  }

  Future<Map<String, dynamic>> updateTherapist(
    String id,
    Map<String, dynamic> values,
  ) async {
    final row = await _table.update(id, values);
    _verifySavedString(row, values, 'name');
    _verifySavedString(row, values, 'phone');
    _verifySavedString(row, values, 'role');
    _verifySavedString(row, values, 'profileImageUrl');
    _verifySavedBool(row, values, 'availabilityStatus');
    _verifySavedString(row, values, 'busyUntil');
    return row;
  }

  Future<void> deleteTherapist(String id) => _table.delete(id);

  Future<void> updateTherapistOrder(
    List<String> therapistIds,
    List<int> displayOrders,
  ) async {
    await _table.client.rpc(
      'reorder_staff_display_order',
      params: {
        'p_outlet_id': OutletContext.activeOutletId.value,
        'p_staff_ids': therapistIds,
        'p_display_orders': displayOrders,
      },
    );
  }

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

void _verifySavedString(
  Map<String, dynamic> row,
  Map<String, dynamic> values,
  String key,
) {
  if (!values.containsKey(key)) return;
  final expected = asString(values[key]).trim();
  final actual = asString(row[key]).trim();
  if (actual != expected) {
    throw StateError(
      'Staff update was not saved. Please run supabase/sql/011_management_update_policies.sql and try again.',
    );
  }
}

void _verifySavedBool(
  Map<String, dynamic> row,
  Map<String, dynamic> values,
  String key,
) {
  if (!values.containsKey(key)) return;
  if (asBool(row[key]) != asBool(values[key])) {
    throw StateError(
      'Staff update was not saved. Please run supabase/sql/011_management_update_policies.sql and try again.',
    );
  }
}
