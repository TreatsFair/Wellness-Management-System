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
  ) {
    return _table.update(id, values);
  }

  Future<void> deleteRoom(String id) => _table.delete(id);

  Future<Map<String, dynamic>> toggleRoomActive(String id, bool active) {
    return _table.update(id, {'isActive': active});
  }
}
