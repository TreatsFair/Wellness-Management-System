import '../services/supabase_table_service.dart';

class SettingsRepository {
  SettingsRepository({SupabaseTableService? table})
    : _table = table ?? SupabaseTableService('settings');

  final SupabaseTableService _table;

  Future<List<Map<String, dynamic>>> listSettings() => _table.list();

  Future<Map<String, dynamic>?> getSettings(String id) => _table.getById(id);

  Future<Map<String, dynamic>?> getBusinessSettings() async {
    final settings = await _table.list(limit: 1);
    return settings.isEmpty ? null : settings.first;
  }

  Future<Map<String, dynamic>> createSettings(Map<String, dynamic> values) {
    return _table.create(values);
  }

  Future<Map<String, dynamic>> updateSettings(
    String id,
    Map<String, dynamic> values,
  ) {
    return _table.update(id, values);
  }

  Future<Map<String, dynamic>> updateBusinessSettings(
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (id != null && id.trim().isNotEmpty) {
      return updateSettings(id, values);
    }

    final existing = await getBusinessSettings();
    if (existing != null) {
      return updateSettings(existing['id'].toString(), values);
    }

    return createSettings(values);
  }
}
