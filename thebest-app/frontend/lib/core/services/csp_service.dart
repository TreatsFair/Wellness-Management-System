import 'package:supabase_flutter/supabase_flutter.dart';

class CspTimeSlot {
  const CspTimeSlot({
    required this.startTime,
    required this.endTime,
    required this.classification,
    required this.score,
    required this.reason,
  });

  factory CspTimeSlot.fromMap(Map<String, dynamic> row) {
    return CspTimeSlot(
      startTime: _cleanTime(row['start_time'] ?? row['startTime']),
      endTime: _cleanTime(row['end_time'] ?? row['endTime']),
      classification:
          row['classification']?.toString() ?? row['status']?.toString() ?? '',
      score: _asInt(row['score']),
      reason: row['reason']?.toString() ?? '',
    );
  }

  final String startTime;
  final String endTime;
  final String classification;
  final int score;
  final String reason;

  bool get isAvailable => classification != 'unavailable';
  bool get isRecommended => classification == 'recommended';
}

class CspValidationResult {
  const CspValidationResult({
    required this.therapistAvailable,
    required this.roomFull,
    required this.roomTotalSlots,
    required this.roomBookedSlots,
    required this.roomAvailableSlots,
    this.therapistBusyUntil,
    this.roomFullUntil,
  });

  factory CspValidationResult.fromMap(Map<String, dynamic> row) {
    return CspValidationResult(
      therapistAvailable:
          row['therapist_available'] == true ||
          row['therapistAvailable'] == true,
      roomFull: row['room_full'] == true || row['roomFull'] == true,
      roomTotalSlots: _asInt(row['room_total_slots'] ?? row['roomTotalSlots']),
      roomBookedSlots: _asInt(
        row['room_booked_slots'] ?? row['roomBookedSlots'],
      ),
      roomAvailableSlots: _asInt(
        row['room_available_slots'] ?? row['roomAvailableSlots'],
      ),
      therapistBusyUntil: _nullableCleanTime(
        row['therapist_busy_until'] ?? row['therapistBusyUntil'],
      ),
      roomFullUntil: _nullableCleanTime(
        row['room_full_until'] ?? row['roomFullUntil'],
      ),
    );
  }

  final bool therapistAvailable;
  final bool roomFull;
  final int roomTotalSlots;
  final int roomBookedSlots;
  final int roomAvailableSlots;
  final String? therapistBusyUntil;
  final String? roomFullUntil;
}

class CspCreateResult {
  const CspCreateResult({
    required this.success,
    this.appointmentId,
    this.appointmentGroupId,
    this.appointmentIds = const [],
    this.errorCode,
    this.errorMessage,
  });

  factory CspCreateResult.fromMap(Map<String, dynamic> row) {
    final ids = row['appointment_ids'] ?? row['appointmentIds'];
    return CspCreateResult(
      success: row['success'] == true,
      appointmentId:
          row['appointment_id']?.toString() ?? row['appointmentId']?.toString(),
      appointmentGroupId:
          row['appointment_group_id']?.toString() ??
          row['appointmentGroupId']?.toString(),
      appointmentIds: ids is Iterable
          ? ids.map((id) => id.toString()).toList()
          : const [],
      errorCode: row['error_code']?.toString() ?? row['errorCode']?.toString(),
      errorMessage:
          row['error_message']?.toString() ?? row['errorMessage']?.toString(),
    );
  }

  final bool success;
  final String? appointmentId;
  final String? appointmentGroupId;
  final List<String> appointmentIds;
  final String? errorCode;
  final String? errorMessage;

  String get message => errorMessage ?? errorCode ?? 'CSP validation failed';
}

class StaffWalkInHoldResult {
  const StaffWalkInHoldResult({
    required this.success,
    this.holdId,
    this.errorCode,
    this.errorMessage,
    this.expiresAt,
  });

  factory StaffWalkInHoldResult.fromMap(Map<String, dynamic> row) {
    return StaffWalkInHoldResult(
      success: row['success'] == true,
      holdId: row['hold_id']?.toString() ?? row['holdId']?.toString(),
      errorCode: row['error_code']?.toString() ?? row['errorCode']?.toString(),
      errorMessage:
          row['error_message']?.toString() ?? row['errorMessage']?.toString(),
      expiresAt: DateTime.tryParse(
        row['expires_at']?.toString() ?? row['expiresAt']?.toString() ?? '',
      ),
    );
  }

  final bool success;
  final String? holdId;
  final String? errorCode;
  final String? errorMessage;
  final DateTime? expiresAt;

  String get message =>
      errorMessage ?? errorCode ?? 'Unable to reserve this therapist';
}

class WalkInTherapistAvailability {
  const WalkInTherapistAvailability({
    required this.therapistId,
    required this.name,
    required this.status,
    this.freeAt,
    this.freeInMinutes = 0,
  });

  factory WalkInTherapistAvailability.fromMap(Map<String, dynamic> row) {
    return WalkInTherapistAvailability(
      therapistId:
          row['therapist_id']?.toString() ??
          row['therapistId']?.toString() ??
          '',
      name: row['name']?.toString() ?? '',
      status: row['status']?.toString() ?? 'busy',
      freeAt: _nullableCleanTime(row['free_at'] ?? row['freeAt']),
      freeInMinutes: _asInt(row['free_in_minutes'] ?? row['freeInMinutes']),
    );
  }

  final String therapistId;
  final String name;
  final String status;
  final String? freeAt;
  final int freeInMinutes;

  bool get isFreeNow => status == 'free_now';
}

class WalkInAvailability {
  const WalkInAvailability({
    required this.therapists,
    required this.zoneAvailableNow,
    required this.zoneFreeSlots,
    required this.canStartNow,
    this.nextAvailableTime,
  });

  factory WalkInAvailability.fromMap(Map<String, dynamic> row) {
    final therapistRows = row['therapists'];
    return WalkInAvailability(
      therapists: therapistRows is Iterable
          ? therapistRows
                .whereType<Map>()
                .map(
                  (item) => WalkInTherapistAvailability.fromMap(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList()
          : const [],
      zoneAvailableNow:
          row['zone_available_now'] == true || row['zoneAvailableNow'] == true,
      zoneFreeSlots: _asInt(row['zone_free_slots'] ?? row['zoneFreeSlots']),
      canStartNow: row['can_start_now'] == true || row['canStartNow'] == true,
      nextAvailableTime: _nullableCleanTime(
        row['next_available_time'] ?? row['nextAvailableTime'],
      ),
    );
  }

  final List<WalkInTherapistAvailability> therapists;
  final bool zoneAvailableNow;
  final int zoneFreeSlots;
  final bool canStartNow;
  final String? nextAvailableTime;
}

class WalkInRoomAvailability {
  const WalkInRoomAvailability({
    required this.availableNow,
    required this.freeSlots,
    required this.totalSlots,
    this.freeAt,
  });

  factory WalkInRoomAvailability.fromMap(Map<String, dynamic> row) {
    return WalkInRoomAvailability(
      availableNow: row['available_now'] == true || row['availableNow'] == true,
      freeSlots: _asInt(row['free_slots'] ?? row['freeSlots']),
      totalSlots: _asInt(row['total_slots'] ?? row['totalSlots']),
      freeAt: _nullableCleanTime(row['free_at'] ?? row['freeAt']),
    );
  }

  final bool availableNow;
  final int freeSlots;
  final int totalSlots;
  final String? freeAt;
}

class RoomUnitAvailability {
  const RoomUnitAvailability({
    required this.id,
    required this.name,
    required this.status,
    required this.availableForRequestedTime,
    this.availableAt,
  });

  factory RoomUnitAvailability.fromMap(Map<String, dynamic> row) {
    return RoomUnitAvailability(
      id:
          row['room_unit_id']?.toString() ??
          row['roomUnitId']?.toString() ??
          '',
      name:
          row['room_unit_name']?.toString() ??
          row['roomUnitName']?.toString() ??
          'Room',
      status: row['status']?.toString() ?? 'available',
      availableForRequestedTime:
          row['available_for_requested_time'] == true ||
          row['availableForRequestedTime'] == true,
      availableAt: _nullableCleanTime(
        row['available_at'] ?? row['availableAt'],
      ),
    );
  }

  final String id;
  final String name;
  final String status;
  final bool availableForRequestedTime;
  final String? availableAt;
}

class CspService {
  CspService._();

  static SupabaseClient get _client => Supabase.instance.client;

  static Future<List<CspTimeSlot>> getAvailableSlots({
    required String date,
    required String therapistId,
    required String roomId,
    required int duration,
    String? excludeId,
  }) async {
    final rows = await _client.rpc(
      'get_available_slots',
      params: {
        'p_date': date,
        'p_therapist_id': therapistId,
        'p_room_id': roomId,
        'p_duration': duration,
        'p_exclude_id': _nullIfBlank(excludeId),
      },
    );
    return _asMapList(rows).map(CspTimeSlot.fromMap).toList();
  }

  static Future<CspValidationResult> validateSlot({
    required String date,
    required String startTime,
    required String endTime,
    required String therapistId,
    required String roomId,
    String? excludeId,
  }) async {
    final rows = await _client.rpc(
      'check_booking_availability',
      params: {
        'p_date': date,
        'p_start_time': startTime,
        'p_end_time': endTime,
        'p_therapist_id': therapistId,
        'p_room_id': roomId,
        'p_exclude_appointment_id': _nullIfBlank(excludeId),
      },
    );
    final first = _firstMap(rows);
    return CspValidationResult.fromMap(first);
  }

  static Future<CspCreateResult> createAppointment({
    required String therapistId,
    required String roomId,
    required String serviceId,
    required String date,
    required String startTime,
    required String endTime,
    required double totalPrice,
    String? customerId,
    String type = 'appointment',
    String? createdBy,
    String serviceName = '',
    List<Map<String, dynamic>> serviceItems = const [],
    int itemCount = 1,
    String notes = '',
    String? appointmentGroupId,
  }) async {
    final rows = await _client.rpc(
      'create_appointment_with_csp',
      params: {
        'p_customer_id': _nullIfBlank(customerId),
        'p_therapist_id': therapistId,
        'p_room_id': roomId,
        'p_service_id': serviceId,
        'p_date': date,
        'p_start_time': startTime,
        'p_end_time': endTime,
        'p_total_price': totalPrice,
        'p_type': type,
        'p_created_by': _nullIfBlank(createdBy),
        'p_service_name': serviceName,
        'p_service_items': serviceItems,
        'p_item_count': itemCount,
        'p_notes': notes,
        'p_appointment_group_id': _nullIfBlank(appointmentGroupId),
      },
    );
    return CspCreateResult.fromMap(_firstMap(rows));
  }

  static Future<CspCreateResult> updateAppointment({
    required String appointmentId,
    required String therapistId,
    required String roomId,
    required String date,
    required String startTime,
    required String endTime,
  }) async {
    final rows = await _client.rpc(
      'update_appointment_with_csp',
      params: {
        'p_appointment_id': appointmentId,
        'p_therapist_id': therapistId,
        'p_room_id': roomId,
        'p_date': date,
        'p_start_time': startTime,
        'p_end_time': endTime,
      },
    );
    return CspCreateResult.fromMap(_firstMap(rows));
  }

  static Future<CspCreateResult> createAppointmentGroup({
    required String date,
    required List<Map<String, dynamic>> allocations,
    String? customerId,
    String groupName = '',
    int? paxCount,
    String type = 'appointment',
    String status = 'confirmed',
    String notes = '',
    String? createdBy,
  }) async {
    final rows = await _client.rpc(
      'create_appointment_group_with_csp',
      params: {
        'p_customer_id': _nullIfBlank(customerId),
        'p_group_name': groupName,
        'p_pax_count': paxCount ?? allocations.length,
        'p_appointment_date': date,
        'p_allocations': allocations,
        'p_type': type,
        'p_status': status,
        'p_notes': notes,
        'p_created_by': _nullIfBlank(createdBy),
      },
    );
    return CspCreateResult.fromMap(_firstMap(rows));
  }

  static Future<CspCreateResult> updateAppointmentGroup({
    required String appointmentGroupId,
    required String date,
    required List<Map<String, dynamic>> allocations,
    String? customerId,
    String groupName = '',
    int? paxCount,
    String type = 'appointment',
    String status = 'confirmed',
    String notes = '',
    String? updatedBy,
  }) async {
    final rows = await _client.rpc(
      'update_appointment_group_with_csp',
      params: {
        'p_appointment_group_id': appointmentGroupId,
        'p_customer_id': _nullIfBlank(customerId),
        'p_group_name': groupName,
        'p_pax_count': paxCount ?? allocations.length,
        'p_appointment_date': date,
        'p_allocations': allocations,
        'p_type': type,
        'p_status': status,
        'p_notes': notes,
        'p_updated_by': _nullIfBlank(updatedBy),
      },
    );
    return CspCreateResult.fromMap(_firstMap(rows));
  }

  static Future<WalkInAvailability> getWalkInAvailability({
    required String today,
    required String nowTime,
    required int duration,
    required String roomId,
  }) async {
    final rows = await _client.rpc(
      'check_walkin_availability',
      params: {
        'p_today': today,
        'p_now_time': nowTime,
        'p_duration': duration,
        'p_room_id': roomId,
      },
    );
    return WalkInAvailability.fromMap(_firstMap(rows));
  }

  /// Duration-aware, room-independent per-therapist availability -- unlike
  /// [getWalkInAvailability] this can be called as soon as services (and
  /// therefore a duration) are picked, before a room/zone is selected.
  static Future<List<WalkInTherapistAvailability>>
  getWalkinTherapistAvailability({
    required String today,
    required String nowTime,
    required int duration,
  }) async {
    final rows = await _client.rpc(
      'get_walkin_therapist_availability',
      params: {'p_today': today, 'p_now_time': nowTime, 'p_duration': duration},
    );
    return _asMapList(rows).map(WalkInTherapistAvailability.fromMap).toList();
  }

  /// Duration-aware per-room availability, mirroring
  /// [getWalkinTherapistAvailability] for the room/zone side.
  static Future<WalkInRoomAvailability> getWalkinRoomAvailability({
    required String today,
    required String nowTime,
    required int duration,
    required String roomId,
  }) async {
    final rows = await _client.rpc(
      'get_walkin_room_availability',
      params: {
        'p_today': today,
        'p_now_time': nowTime,
        'p_duration': duration,
        'p_room_id': roomId,
      },
    );
    return WalkInRoomAvailability.fromMap(_firstMap(rows));
  }

  static Future<StaffWalkInHoldResult> reserveStaffWalkInAllocation({
    required String draftSessionId,
    required int paxIndex,
    required String outletId,
    required String customerId,
    required String customerName,
    required String customerPhone,
    required String therapistId,
    required String roomId,
    String? roomUnitId,
    required List<Map<String, dynamic>> serviceItems,
    required String date,
    required String startTime,
    required String endTime,
    required double totalAmount,
  }) async {
    final rows = await _client.rpc(
      'reserve_staff_walkin_allocation',
      params: {
        'p_draft_session_id': draftSessionId,
        'p_pax_index': paxIndex,
        'p_outlet_id': outletId,
        'p_customer_id': _nullIfBlank(customerId),
        'p_customer_name': customerName,
        'p_customer_phone': customerPhone,
        'p_therapist_id': therapistId,
        'p_room_id': roomId,
        'p_room_unit_id': _nullIfBlank(roomUnitId),
        'p_service_items': serviceItems,
        'p_date': date,
        'p_start_time': startTime,
        'p_end_time': endTime,
        'p_total_amount': totalAmount,
      },
    );
    return StaffWalkInHoldResult.fromMap(_firstMap(rows));
  }

  static Future<List<RoomUnitAvailability>> getRoomUnitAvailability({
    required String zoneId,
    required String date,
    required String startTime,
    required int duration,
  }) async {
    final rows = await _client.rpc(
      'get_room_unit_availability',
      params: {
        'p_zone_id': zoneId,
        'p_date': date,
        'p_start_time': startTime,
        'p_duration': duration,
      },
    );
    return _asMapList(rows).map(RoomUnitAvailability.fromMap).toList();
  }

  static Future<void> releaseStaffWalkInDraft({
    required String draftSessionId,
    int? paxIndex,
  }) async {
    await _client.rpc(
      'release_staff_walkin_draft',
      params: {'p_draft_session_id': draftSessionId, 'p_pax_index': paxIndex},
    );
  }
}

List<Map<String, dynamic>> _asMapList(Object? rows) {
  if (rows is List) {
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }
  if (rows is Map) return [Map<String, dynamic>.from(rows)];
  return const [];
}

Map<String, dynamic> _firstMap(Object? rows) {
  final list = _asMapList(rows);
  return list.isEmpty ? <String, dynamic>{} : list.first;
}

String? _nullIfBlank(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty || trimmed == 'walk_in_guest') return null;
  return trimmed;
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

String? _nullableCleanTime(Object? value) {
  if (value == null) return null;
  final raw = value.toString();
  if (raw.isEmpty || raw == 'null') return null;
  return _cleanTime(raw);
}

String _cleanTime(Object? value) {
  final raw = value?.toString() ?? '';
  if (raw.length >= 5) return raw.substring(0, 5);
  return raw;
}
