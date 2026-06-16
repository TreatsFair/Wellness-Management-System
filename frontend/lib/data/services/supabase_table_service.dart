import 'package:supabase_flutter/supabase_flutter.dart';

const Map<String, String> _snakeToCamelAliases = {
  'appointment_id': 'appointmentId',
  'appointment_date': 'date',
  'availability_status': 'availabilityStatus',
  'business_name': 'businessName',
  'busy_until': 'busyUntil',
  'created_at': 'createdAt',
  'created_by': 'createdBy',
  'customer_id': 'customerId',
  'customer_name': 'customerName',
  'customer_phone': 'customerPhone',
  'date_of_birth': 'dateOfBirth',
  'employment_type': 'employmentType',
  'end_time': 'endTime',
  'image_url': 'imageUrl',
  'is_active': 'isActive',
  'item_count': 'itemCount',
  'join_date': 'joinDate',
  'paid_at': 'paidAt',
  'payment_method': 'paymentMethod',
  'payment_status': 'paymentStatus',
  'photo_url': 'photoUrl',
  'profile_image_url': 'profileImageUrl',
  'receipt_number': 'receiptNumber',
  'room_id': 'roomId',
  'room_name': 'roomName',
  'room_type': 'roomType',
  'service_description': 'serviceDescription',
  'service_id': 'serviceId',
  'service_name': 'serviceName',
  'service_price': 'servicePrice',
  'sst_amount': 'sstAmount',
  'start_time': 'startTime',
  'therapist_id': 'therapistId',
  'therapist_name': 'therapistName',
  'total_amount': 'totalAmount',
  'total_price': 'totalPrice',
  'total_slots': 'totalSlots',
  'updated_at': 'updatedAt',
  'updated_by': 'updatedBy',
};

final Map<String, String> _camelToSnakeAliases = {
  for (final entry in _snakeToCamelAliases.entries) entry.value: entry.key,
  'appointmentDate': 'appointment_date',
};

class SupabaseTableService {
  SupabaseTableService(this.tableName, {SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final String tableName;
  final SupabaseClient _client;

  SupabaseClient get client => _client;

  Future<List<Map<String, dynamic>>> list({
    String? orderBy,
    bool ascending = true,
    int? limit,
  }) async {
    dynamic query = _client.from(tableName).select();
    if (orderBy != null) {
      query = query.order(orderBy, ascending: ascending);
    }
    if (limit != null) {
      query = query.limit(limit);
    }

    final rows = await query;
    return _toMapList(rows);
  }

  Future<Map<String, dynamic>?> getById(String id) async {
    final row = await _client
        .from(tableName)
        .select()
        .eq('id', id)
        .maybeSingle();
    if (row == null) return null;
    return _toMap(row);
  }

  Future<List<Map<String, dynamic>>> getManyByIds(Iterable<String> ids) async {
    final uniqueIds = ids.where((id) => id.trim().isNotEmpty).toSet().toList();
    if (uniqueIds.isEmpty) return [];

    final rows = await _client
        .from(tableName)
        .select()
        .inFilter('id', uniqueIds);
    return _toMapList(rows);
  }

  Future<List<Map<String, dynamic>>> findBy(
    String column,
    Object value, {
    String? orderBy,
    bool ascending = true,
    int? limit,
  }) async {
    dynamic query = _client.from(tableName).select().eq(column, value);
    if (orderBy != null) {
      query = query.order(orderBy, ascending: ascending);
    }
    if (limit != null) {
      query = query.limit(limit);
    }

    final rows = await query;
    return _toMapList(rows);
  }

  Future<List<Map<String, dynamic>>> findIn(
    String column,
    List<Object> values, {
    String? orderBy,
    bool ascending = true,
    int? limit,
  }) async {
    if (values.isEmpty) return [];
    dynamic query = _client.from(tableName).select().inFilter(column, values);
    if (orderBy != null) {
      query = query.order(orderBy, ascending: ascending);
    }
    if (limit != null) {
      query = query.limit(limit);
    }

    final rows = await query;
    return _toMapList(rows);
  }

  Future<List<Map<String, dynamic>>> findBetween(
    String column,
    Object startInclusive,
    Object endInclusive, {
    String? orderBy,
    bool ascending = true,
  }) async {
    dynamic query = _client
        .from(tableName)
        .select()
        .gte(column, startInclusive)
        .lte(column, endInclusive);
    if (orderBy != null) {
      query = query.order(orderBy, ascending: ascending);
    }

    final rows = await query;
    return _toMapList(rows);
  }

  Future<Map<String, dynamic>> create(Map<String, dynamic> values) async {
    final row = await _client
        .from(tableName)
        .insert(toSupabaseValues(values))
        .select()
        .single();
    return _toMap(row);
  }

  Future<Map<String, dynamic>> update(
    String id,
    Map<String, dynamic> values,
  ) async {
    final row = await _client
        .from(tableName)
        .update(toSupabaseValues(values))
        .eq('id', id)
        .select()
        .single();
    return _toMap(row);
  }

  Future<void> delete(String id) async {
    await _client.from(tableName).delete().eq('id', id);
  }

  Map<String, dynamic> toSupabaseValues(Map<String, dynamic> values) {
    final normalized = <String, dynamic>{};
    for (final entry in values.entries) {
      if (entry.key == 'id') continue;
      if (entry.key == 'active' && values.containsKey('isActive')) continue;
      if (entry.value == null) continue;
      if (_isSyntheticUuidValue(entry.key, entry.value)) continue;
      normalized[_toSupabaseColumn(entry.key)] = entry.value;
    }
    return normalized;
  }

  bool _isSyntheticUuidValue(String key, Object? value) {
    final uuidKeys = {
      'appointmentId',
      'createdBy',
      'customerId',
      'roomId',
      'serviceId',
      'therapistId',
    };
    if (!uuidKeys.contains(key)) return false;
    final text = value?.toString().trim() ?? '';
    return text.isEmpty || text == 'walk_in_guest';
  }

  String _toSupabaseColumn(String key) {
    return _camelToSnakeAliases[key] ?? key;
  }

  Map<String, dynamic> _toMap(Object? row) {
    final raw = Map<String, dynamic>.from(row as Map);
    final normalized = <String, dynamic>{...raw};

    for (final entry in raw.entries) {
      final alias = _snakeToCamelAliases[entry.key];
      if (alias != null && !normalized.containsKey(alias)) {
        normalized[alias] = entry.value;
      }
    }

    if (raw.containsKey('appointment_date') &&
        !normalized.containsKey('date')) {
      normalized['date'] = raw['appointment_date'];
    }

    return normalized;
  }

  List<Map<String, dynamic>> _toMapList(Object? rows) {
    return (rows as List).map((row) => _toMap(row)).toList();
  }
}
