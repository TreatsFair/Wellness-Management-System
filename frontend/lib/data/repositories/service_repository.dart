import '../services/supabase_table_service.dart';
import 'repository_utils.dart';

class ServiceRepository {
  ServiceRepository({SupabaseTableService? table})
    : _table = table ?? SupabaseTableService('services');

  final SupabaseTableService _table;

  Future<List<Map<String, dynamic>>> getServices() {
    return _table.list(orderBy: 'name');
  }

  Future<List<Map<String, dynamic>>> listServices() => getServices();

  Future<List<Map<String, dynamic>>> getActiveServices() async {
    final rows = await getServices();
    return rows.where(isActiveRow).toList();
  }

  Future<Map<String, dynamic>?> getService(String id) => _table.getById(id);

  Future<Map<String, dynamic>> addService(Map<String, dynamic> values) {
    return _table.create(values);
  }

  Future<Map<String, dynamic>> createService(Map<String, dynamic> values) {
    return addService(values);
  }

  Future<Map<String, dynamic>> updateService(
    String id,
    Map<String, dynamic> values,
  ) {
    return _table.update(id, values);
  }

  Future<void> deleteService(String id) => _table.delete(id);

  Future<Map<String, dynamic>> deactivateService(String id) {
    return toggleServiceActive(id, false);
  }

  Future<Map<String, dynamic>> toggleServiceActive(String id, bool active) {
    return _table.update(id, {'isActive': active});
  }
}
