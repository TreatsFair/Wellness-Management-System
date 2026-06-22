import '../services/supabase_table_service.dart';
import 'repository_utils.dart';

class RoomRepository {
  RoomRepository({SupabaseTableService? table})
    : _table = table ?? SupabaseTableService('rooms');

  final SupabaseTableService _table;

  Future<List<Map<String, dynamic>>> getRooms() {
    return _table.list(orderBy: 'name');
  }

  Future<List<Map<String, dynamic>>> listRooms() => getRooms();

  Future<List<Map<String, dynamic>>> getActiveRooms() async {
    final rows = await getRooms();
    return rows.where(isActiveRow).toList();
  }

  Future<Map<String, dynamic>?> getRoom(String id) => _table.getById(id);

  Future<Map<String, dynamic>> createRoom(Map<String, dynamic> values) {
    return _table.create(values);
  }

  Future<Map<String, dynamic>> updateRoom(
    String id,
    Map<String, dynamic> values,
  ) async {
    final row = await _table.update(id, values);
    _verifySavedString(row, values, 'name');
    _verifySavedString(row, values, 'type');
    _verifySavedString(row, values, 'roomType');
    _verifySavedString(row, values, 'floor');
    _verifySavedInt(row, values, 'totalSlots');
    _verifySavedString(row, values, 'equipment');
    _verifySavedBool(row, values, 'isActive');
    return row;
  }

  Future<void> deleteRoom(String id) => _table.delete(id);

  Future<Map<String, dynamic>> toggleRoomActive(String id, bool active) {
    return _table.update(id, {'isActive': active});
  }
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
      'Room update was not saved. Please run supabase/sql/011_management_update_policies.sql and try again.',
    );
  }
}

void _verifySavedInt(
  Map<String, dynamic> row,
  Map<String, dynamic> values,
  String key,
) {
  if (!values.containsKey(key)) return;
  if (asInt(row[key]) != asInt(values[key])) {
    throw StateError(
      'Room update was not saved. Please run supabase/sql/011_management_update_policies.sql and try again.',
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
      'Room update was not saved. Please run supabase/sql/011_management_update_policies.sql and try again.',
    );
  }
}
