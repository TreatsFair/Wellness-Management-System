import '../services/supabase_table_service.dart';
import 'repository_utils.dart';

class ServiceRepository {
  ServiceRepository({SupabaseTableService? table})
    : _table = table ?? SupabaseTableService('services');

  final SupabaseTableService _table;

  Future<List<Map<String, dynamic>>> getServices() async {
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

  Future<List<Map<String, dynamic>>> listServices() => getServices();

  Future<List<Map<String, dynamic>>> getActiveServices() async {
    final rows = await getServices();
    return rows.where(isActiveRow).toList();
  }

  Future<Map<String, dynamic>?> getService(String id) => _table.getById(id);

  Future<Map<String, dynamic>> addService(Map<String, dynamic> values) async {
    if (values.containsKey('displayOrder')) return _table.create(values);
    final category = asString(values['category'], 'Services').trim();
    final existing = await getServices();
    var nextOrder = 0;
    for (final row in existing) {
      if (asString(row['category']).trim() != category) continue;
      final candidate = asInt(row['displayOrder']) + 1;
      if (candidate > nextOrder) nextOrder = candidate;
    }
    return _table.create({...values, 'displayOrder': nextOrder});
  }

  Future<Map<String, dynamic>> createService(Map<String, dynamic> values) {
    return addService(values);
  }

  Future<Map<String, dynamic>> updateService(
    String id,
    Map<String, dynamic> values,
  ) async {
    final row = await _table.update(id, values);
    _verifySavedString(row, values, 'name');
    _verifySavedString(row, values, 'category');
    _verifySavedString(row, values, 'serviceDescription');
    _verifySavedInt(row, values, 'duration');
    _verifySavedInt(row, values, 'bufferAfterMinutes');
    _verifySavedDouble(row, values, 'price');
    _verifySavedDouble(row, values, 'therapistCommission');
    _verifySavedDouble(row, values, 'counterCommission');
    _verifySavedString(row, values, 'roomType');
    _verifySavedString(row, values, 'imageUrl');
    _verifySavedBool(row, values, 'isActive');
    return row;
  }

  Future<void> deleteService(String id) => _table.delete(id);

  Future<Map<String, dynamic>> deactivateService(String id) {
    return toggleServiceActive(id, false);
  }

  Future<Map<String, dynamic>> toggleServiceActive(String id, bool active) {
    return _table.update(id, {'isActive': active});
  }

  Future<void> updateServiceOrder(List<String> serviceIds) async {
    for (var index = 0; index < serviceIds.length; index++) {
      await _table.update(serviceIds[index], {'displayOrder': index});
    }
  }
}

void _verifySavedDouble(
  Map<String, dynamic> row,
  Map<String, dynamic> values,
  String key,
) {
  if (!values.containsKey(key)) return;
  final expected = asDouble(values[key]);
  final actual = asDouble(row[key]);
  if ((actual - expected).abs() > 0.001) {
    throw StateError(
      'Service update was not saved. Please run supabase/sql/008_services_update_staff_admin.sql and try again.',
    );
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
      'Service update was not saved. Please run supabase/sql/008_services_update_staff_admin.sql and try again.',
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
      'Service update was not saved. Please run supabase/sql/008_services_update_staff_admin.sql and try again.',
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
      'Service update was not saved. Please run supabase/sql/008_services_update_staff_admin.sql and try again.',
    );
  }
}
