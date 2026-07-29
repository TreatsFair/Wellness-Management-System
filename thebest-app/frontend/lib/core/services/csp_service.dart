import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/error_message.dart';

class CspTimeSlot {
  const CspTimeSlot({
    required this.startTime,
    required this.endTime,
    required this.classification,
    required this.score,
    required this.reason,
    this.roomAvailableSlots = 0,
    this.previousBlockEnd,
    this.nextBlockStart,
    this.gapBeforeMinutes,
    this.gapAfterMinutes,
  });

  factory CspTimeSlot.fromMap(Map<String, dynamic> row) {
    return CspTimeSlot(
      startTime: _cleanTime(row['start_time'] ?? row['startTime']),
      endTime: _cleanTime(row['end_time'] ?? row['endTime']),
      classification:
          row['classification']?.toString() ?? row['status']?.toString() ?? '',
      score: _asInt(row['score']),
      reason: row['reason']?.toString() ?? '',
      roomAvailableSlots: _asInt(
        row['room_available_slots'] ?? row['roomAvailableSlots'],
      ),
      previousBlockEnd: _nullableCleanTime(
        row['previous_block_end'] ?? row['previousBlockEnd'],
      ),
      nextBlockStart: _nullableCleanTime(
        row['next_block_start'] ?? row['nextBlockStart'],
      ),
      gapBeforeMinutes: _nullableInt(
        row['gap_before_minutes'] ?? row['gapBeforeMinutes'],
      ),
      gapAfterMinutes: _nullableInt(
        row['gap_after_minutes'] ?? row['gapAfterMinutes'],
      ),
    );
  }

  final String startTime;
  final String endTime;
  final String classification;
  final int score;
  final String reason;
  final int roomAvailableSlots;
  final String? previousBlockEnd;
  final String? nextBlockStart;
  final int? gapBeforeMinutes;
  final int? gapAfterMinutes;

  bool get isAvailable => classification != 'unavailable';
  bool get isRecommended => classification == 'recommended';
}

class CspScheduleBlock {
  const CspScheduleBlock({
    required this.startTime,
    required this.endTime,
    required this.blockedUntil,
    required this.kind,
    required this.label,
  });

  factory CspScheduleBlock.fromMap(Map<String, dynamic> row) {
    return CspScheduleBlock(
      startTime: _cleanTime(row['start_time'] ?? row['startTime']),
      endTime: _cleanTime(row['end_time'] ?? row['endTime']),
      blockedUntil: _cleanTime(
        row['blocked_until'] ?? row['blockedUntil'] ?? row['end_time'],
      ),
      kind: row['kind']?.toString() ?? 'appointment',
      label: row['label']?.toString() ?? 'Booked service',
    );
  }

  final String startTime;
  final String endTime;
  final String blockedUntil;
  final String kind;
  final String label;

  bool get hasCleanup => blockedUntil != endTime;
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

  String get message => friendlyBookingErrorMessage(
    errorMessage ?? errorCode,
    fallback: 'CSP validation failed',
  );
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

  String get message => friendlyBookingErrorMessage(
    errorMessage ?? errorCode,
    fallback: 'Unable to reserve this therapist',
  );
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

class TherapistQueueEntry {
  const TherapistQueueEntry({
    required this.therapistId,
    required this.name,
    required this.gender,
    required this.queuePosition,
    required this.status,
    required this.protectedTurnOwed,
    required this.isRecommended,
    this.freeAt,
    this.reservationStartAt,
    this.reservationEndAt,
    this.freeInMinutes = 0,
  });

  factory TherapistQueueEntry.fromMap(Map<String, dynamic> row) {
    return TherapistQueueEntry(
      therapistId:
          row['therapist_id']?.toString() ??
          row['therapistId']?.toString() ??
          '',
      name: row['name']?.toString() ?? '',
      gender: row['gender']?.toString() ?? '',
      queuePosition: _asInt(row['queue_position'] ?? row['queuePosition']),
      status: row['status']?.toString() ?? 'busy',
      protectedTurnOwed:
          row['protected_turn_owed'] == true ||
          row['protectedTurnOwed'] == true,
      isRecommended:
          row['is_recommended'] == true || row['isRecommended'] == true,
      freeAt: _nullableCleanTime(row['free_at'] ?? row['freeAt']),
      reservationStartAt: _nullableCleanTime(
        row['reservation_start_at'] ?? row['reservationStartAt'],
      ),
      reservationEndAt: _nullableCleanTime(
        row['reservation_end_at'] ?? row['reservationEndAt'],
      ),
      freeInMinutes: _asInt(row['free_in_minutes'] ?? row['freeInMinutes']),
    );
  }

  final String therapistId;
  final String name;
  final String gender;
  final int queuePosition;
  final String status;
  final bool protectedTurnOwed;
  final bool isRecommended;
  final String? freeAt;
  final String? reservationStartAt;
  final String? reservationEndAt;
  final int freeInMinutes;

  bool get isFreeNow => status == 'free_now';
  bool get isBusyNow => status == 'busy_now' || status == 'busy';
  bool get isReserved => status == 'reserved';
  bool get isTentativeHold => status == 'tentative_hold';
}

class TodayQueueTherapist {
  const TodayQueueTherapist({
    required this.therapistId,
    required this.name,
    this.profileImageUrl = '',
    this.status = '',
    this.isRecommended = false,
    this.protectedTurnOwed = false,
  });

  factory TodayQueueTherapist.fromMap(Map<String, dynamic> row) {
    return TodayQueueTherapist(
      therapistId:
          row['therapist_id']?.toString() ??
          row['therapistId']?.toString() ??
          '',
      name: row['name']?.toString() ?? '',
      profileImageUrl:
          row['profile_image_url']?.toString() ??
          row['profileImageUrl']?.toString() ??
          '',
      status: row['status']?.toString() ?? '',
      isRecommended:
          row['is_recommended'] == true || row['isRecommended'] == true,
      protectedTurnOwed:
          row['protected_turn_owed'] == true ||
          row['protectedTurnOwed'] == true,
    );
  }

  final String therapistId;
  final String name;
  final String profileImageUrl;
  final String status;
  final bool isRecommended;
  final bool protectedTurnOwed;
}

class TodayQueueManagement {
  const TodayQueueManagement({
    required this.queueDate,
    required this.isManualOverride,
    required this.requiresResetWarning,
    required this.liveQueue,
    this.starter,
    this.currentNext,
    this.changedBy,
    this.changedAt,
    this.reason,
    this.firstTurnConsumedAt,
  });

  factory TodayQueueManagement.fromMap(Map<String, dynamic> row) {
    final starter = _nullableMap(row['starter']);
    final currentNext = _nullableMap(
      row['current_next'] ?? row['currentNext'],
    );
    final queue = row['live_queue'] ?? row['liveQueue'];
    return TodayQueueManagement(
      queueDate:
          row['queue_date']?.toString() ?? row['queueDate']?.toString() ?? '',
      isManualOverride:
          row['is_manual_override'] == true || row['isManualOverride'] == true,
      requiresResetWarning:
          row['requires_reset_warning'] == true ||
          row['requiresResetWarning'] == true,
      starter: starter == null ? null : TodayQueueTherapist.fromMap(starter),
      currentNext: currentNext == null
          ? null
          : TodayQueueTherapist.fromMap(currentNext),
      liveQueue: queue is List
          ? queue
                .whereType<Map>()
                .map(
                  (item) => TodayQueueTherapist.fromMap(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList()
          : const [],
      changedBy:
          row['changed_by']?.toString() ?? row['changedBy']?.toString(),
      changedAt: DateTime.tryParse(
        row['changed_at']?.toString() ?? row['changedAt']?.toString() ?? '',
      ),
      reason: row['reason']?.toString(),
      firstTurnConsumedAt: DateTime.tryParse(
        row['first_turn_consumed_at']?.toString() ??
            row['firstTurnConsumedAt']?.toString() ??
            '',
      ),
    );
  }

  final String queueDate;
  final TodayQueueTherapist? starter;
  final bool isManualOverride;
  final TodayQueueTherapist? currentNext;
  final String? changedBy;
  final DateTime? changedAt;
  final String? reason;
  final DateTime? firstTurnConsumedAt;
  final bool requiresResetWarning;
  final List<TodayQueueTherapist> liveQueue;
}

class CounterCapacitySlot {
  const CounterCapacitySlot({
    required this.startTime,
    required this.endTime,
    required this.therapistFree,
    required this.roomFree,
    this.isAvailable = true,
    this.unavailableDimension,
    this.unavailableAt,
    this.conflictTherapistId,
    this.conflictStart,
    this.conflictEnd,
    this.candidateKind = 'standard',
  });

  factory CounterCapacitySlot.fromMap(Map<String, dynamic> row) {
    return CounterCapacitySlot(
      startTime: _cleanTime(row['start_time'] ?? row['startTime']),
      endTime: _cleanTime(row['end_time'] ?? row['endTime']),
      therapistFree: _asInt(row['therapist_free'] ?? row['therapistFree']),
      roomFree: _asInt(row['room_free'] ?? row['roomFree']),
      isAvailable:
          row['is_available'] == null ||
          row['is_available'] == true ||
          row['isAvailable'] == true,
      unavailableDimension:
          row['unavailable_dimension']?.toString() ??
          row['unavailableDimension']?.toString(),
      unavailableAt: _nullableDateTime(
        row['unavailable_at'] ?? row['unavailableAt'],
      ),
      conflictTherapistId:
          row['conflict_therapist_id']?.toString() ??
          row['conflictTherapistId']?.toString(),
      conflictStart: _nullableCleanTime(
        row['conflict_start'] ?? row['conflictStart'],
      ),
      conflictEnd: _nullableCleanTime(
        row['conflict_end'] ?? row['conflictEnd'],
      ),
      candidateKind:
          row['candidate_kind']?.toString() ??
          row['candidateKind']?.toString() ??
          'standard',
    );
  }

  final String startTime;
  final String endTime;
  final int therapistFree;
  final int roomFree;
  final bool isAvailable;
  final String? unavailableDimension;
  final DateTime? unavailableAt;
  final String? conflictTherapistId;
  final String? conflictStart;
  final String? conflictEnd;
  final String candidateKind;

  /// The soonest bookable start of the day. Ranked with Best Fit rather than
  /// buried in the plain grid, because "as early as possible" is a real
  /// counter preference alongside "packs tight against a nearby booking".
  bool get isEarliest => candidateKind == 'earliest';

  bool get isBestFit => candidateKind == 'best_fit' || isEarliest;
}

class CounterCapacityRequirement {
  const CounterCapacityRequirement({
    required this.paxIndex,
    required this.serviceIds,
    required this.durationMinutes,
    required this.roomType,
    this.bufferAfterMinutes = 0,
    this.assignmentSource = 'queue',
    this.requestedGender,
    this.requestedTherapistId,
  });

  final int paxIndex;
  final List<String> serviceIds;
  final int durationMinutes;
  final int bufferAfterMinutes;
  final String roomType;
  final String assignmentSource;
  final String? requestedGender;
  final String? requestedTherapistId;

  Map<String, dynamic> toRpcMap() => {
    'pax_index': paxIndex,
    'service_ids': serviceIds,
    'duration_minutes': durationMinutes,
    'buffer_after_minutes': bufferAfterMinutes,
    'room_type': roomType,
    'assignment_source': assignmentSource,
    'requested_gender': requestedGender,
    'requested_therapist_id': requestedTherapistId,
  };
}

List<Map<String, dynamic>> serializeCounterCapacityRequirements(
  List<CounterCapacityRequirement> requirements,
) {
  return [
    for (final requirement in requirements)
      if (requirement.paxIndex < 1)
        throw ArgumentError.value(
          requirement.paxIndex,
          'paxIndex',
          'Every pax requirement must use a one-based pax index.',
        )
      else
        requirement.toRpcMap(),
  ];
}

class ProvisionalAllocation {
  const ProvisionalAllocation({
    required this.paxIndex,
    required this.therapistId,
    required this.roomId,
    required this.endTime,
  });

  factory ProvisionalAllocation.fromMap(Map<String, dynamic> row) {
    return ProvisionalAllocation(
      paxIndex: _asInt(row['pax_index'] ?? row['paxIndex']),
      therapistId:
          row['therapist_id']?.toString() ??
          row['therapistId']?.toString() ??
          '',
      roomId: row['room_id']?.toString() ?? row['roomId']?.toString() ?? '',
      endTime: _nullableCleanTime(row['end_time'] ?? row['endTime']),
    );
  }

  final int paxIndex;
  final String therapistId;
  final String roomId;
  final String? endTime;
}

class QueueScheduleStatus {
  const QueueScheduleStatus({
    required this.activeCount,
    required this.scheduledCount,
    required this.unscheduledActiveCount,
  });

  factory QueueScheduleStatus.fromMap(Map<String, dynamic> row) {
    return QueueScheduleStatus(
      activeCount: _asInt(row['active_count'] ?? row['activeCount']),
      scheduledCount: _asInt(row['scheduled_count'] ?? row['scheduledCount']),
      unscheduledActiveCount: _asInt(
        row['unscheduled_active_count'] ?? row['unscheduledActiveCount'],
      ),
    );
  }

  final int activeCount;
  final int scheduledCount;
  final int unscheduledActiveCount;
}

class TherapistSwitchResult {
  const TherapistSwitchResult({
    required this.success,
    this.commissionMethod,
    this.errorCode,
    this.errorMessage,
  });

  factory TherapistSwitchResult.fromMap(Map<String, dynamic> row) {
    return TherapistSwitchResult(
      success: row['success'] == true,
      commissionMethod:
          row['commission_method']?.toString() ??
          row['commissionMethod']?.toString(),
      errorCode: row['error_code']?.toString() ?? row['errorCode']?.toString(),
      errorMessage:
          row['error_message']?.toString() ?? row['errorMessage']?.toString(),
    );
  }

  final bool success;
  final String? commissionMethod;
  final String? errorCode;
  final String? errorMessage;

  String get message => friendlyBookingErrorMessage(
    errorMessage ?? errorCode,
    fallback: 'Unable to switch therapist',
  );
}

class RoomUnitAvailability {
  const RoomUnitAvailability({
    required this.id,
    required this.name,
    required this.status,
    required this.availableForRequestedTime,
    this.availableAt,
    this.reservationStartAt,
    this.reservationEndAt,
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
      reservationStartAt: _nullableCleanTime(
        row['reservation_start_at'] ?? row['reservationStartAt'],
      ),
      reservationEndAt: _nullableCleanTime(
        row['reservation_end_at'] ?? row['reservationEndAt'],
      ),
    );
  }

  final String id;
  final String name;
  final String status;
  final bool availableForRequestedTime;
  final String? availableAt;
  final String? reservationStartAt;
  final String? reservationEndAt;
}

class CspService {
  CspService._();

  static SupabaseClient get _client => Supabase.instance.client;

  static Future<List<CspTimeSlot>> getAvailableSlots({
    required String date,
    required String therapistId,
    required String roomId,
    required int duration,
    int bufferAfterMinutes = 0,
    String? excludeId,
  }) async {
    Object? rows;
    try {
      rows = await _client.rpc(
        'get_available_slots',
        params: {
          'p_date': date,
          'p_therapist_id': therapistId,
          'p_room_id': roomId,
          'p_duration': duration,
          'p_exclude_id': _nullIfBlank(excludeId),
          'p_buffer_after_minutes': bufferAfterMinutes,
        },
      );
    } catch (error) {
      if (!_isMissingRpc(error)) rethrow;
      // Deployment-safe fallback while migration 081 is not yet live.
      rows = await _client.rpc(
        'get_available_slots',
        params: {
          'p_date': date,
          'p_therapist_id': therapistId,
          'p_room_id': roomId,
          'p_duration': duration,
          'p_exclude_id': _nullIfBlank(excludeId),
        },
      );
    }
    return _asMapList(rows).map(CspTimeSlot.fromMap).toList();
  }

  static Future<List<CspScheduleBlock>> getStaffBookingScheduleContext({
    required String date,
    required String therapistId,
    String? excludeId,
  }) async {
    final rows = await _client.rpc(
      'get_staff_booking_schedule_context',
      params: {
        'p_date': date,
        'p_therapist_id': therapistId,
        'p_exclude_id': _nullIfBlank(excludeId),
      },
    );
    return _asMapList(rows).map(CspScheduleBlock.fromMap).toList();
  }

  static Future<CspValidationResult> validateSlot({
    required String date,
    required String startTime,
    required String endTime,
    String? roomUnitId,
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
    String assignmentSource = 'queue',
    String? requestedTherapistId,
    String? requestedGender,
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
        'p_assignment_source': assignmentSource,
        'p_requested_therapist_id': _nullIfBlank(requestedTherapistId),
        'p_requested_gender': requestedGender,
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
    String? roomUnitId,
    String? assignmentSource,
    String? requestedTherapistId,
    String? requestedGender,
  }) async {
    final rows = await _client.rpc(
      'update_appointment_with_csp_v2',
      params: {
        'p_appointment_id': appointmentId,
        'p_therapist_id': therapistId,
        'p_room_id': roomId,
        'p_date': date,
        'p_start_time': startTime,
        'p_end_time': endTime,
        'p_room_unit_id': _nullIfBlank(roomUnitId),
        'p_assignment_source': assignmentSource,
        'p_requested_therapist_id': _nullIfBlank(requestedTherapistId),
        'p_requested_gender': requestedGender,
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
      'get_room_unit_availability_v2',
      params: {
        'p_zone_id': zoneId,
        'p_date': date,
        'p_start_time': startTime,
        'p_duration': duration,
      },
    );
    return _asMapList(rows).map(RoomUnitAvailability.fromMap).toList();
  }

  /// Live rotating queue for one outlet/day, joined with duration-aware
  /// availability for [date]+[nowTime]+[duration]. Ordered so the recommended
  /// therapist (first free-now in rotation order) sorts first.
  static Future<List<TherapistQueueEntry>> getTherapistQueue({
    required String outletId,
    required String date,
    required String nowTime,
    required int duration,
  }) async {
    final rows = await _client.rpc(
      'get_therapist_queue',
      params: {
        'p_outlet_id': outletId,
        'p_date': date,
        'p_now_time': nowTime,
        'p_duration': duration,
      },
    );
    return _asMapList(rows).map(TherapistQueueEntry.fromMap).toList();
  }

  static Future<TodayQueueManagement> getTodayQueueManagement({
    required String outletId,
    required String date,
    required String nowTime,
  }) async {
    final result = await _client.rpc(
      'get_today_queue_management',
      params: {
        'p_outlet_id': outletId,
        'p_date': date,
        'p_now_time': nowTime,
      },
    );
    return TodayQueueManagement.fromMap(_firstMap(result));
  }

  static Future<void> changeTodayQueueStarter({
    required String outletId,
    required String date,
    required String therapistId,
    String? reason,
    bool confirmReset = false,
  }) async {
    await _client.rpc(
      'change_today_queue_starter',
      params: {
        'p_outlet_id': outletId,
        'p_date': date,
        'p_starter_therapist_id': therapistId,
        'p_reason': _nullIfBlank(reason),
        'p_confirm_reset': confirmReset,
      },
    );
  }

  static Future<void> reorderCurrentTherapistQueue({
    required String outletId,
    required String date,
    required List<String> therapistIds,
  }) async {
    await _client.rpc(
      'reorder_current_therapist_queue',
      params: {
        'p_outlet_id': outletId,
        'p_date': date,
        'p_therapist_ids': therapistIds,
      },
    );
  }

  static Future<void> resetTodayQueueToAutomatic({
    required String outletId,
    required String date,
    String? reason,
    bool confirmReset = false,
  }) async {
    await _client.rpc(
      'reset_today_queue_to_automatic',
      params: {
        'p_outlet_id': outletId,
        'p_date': date,
        'p_reason': _nullIfBlank(reason),
        'p_confirm_reset': confirmReset,
      },
    );
  }

  /// Hourly counter-booking grid plus exact best-fit boundaries. Every pax
  /// keeps its own service duration, cleanup buffer, and required room type.
  static Future<List<CounterCapacitySlot>> getCounterCapacitySlots({
    required String outletId,
    required String date,
    required List<CounterCapacityRequirement> requirements,
    String? excludeGroupId,
    String? excludeId,
  }) async {
    final rows = await _client.rpc(
      'get_counter_preference_capacity_slots_v2',
      params: {
        'p_outlet_id': outletId,
        'p_date': date,
        'p_requirements': serializeCounterCapacityRequirements(requirements),
        'p_exclude_appointment_group_id': _nullIfBlank(excludeGroupId),
        'p_exclude_appointment_id': _nullIfBlank(excludeId),
      },
    );
    return _asMapList(rows).map(CounterCapacitySlot.fromMap).toList();
  }

  /// Silently picks a provisional therapist and correctly typed room/zone for
  /// each pax at one shared start time. Longer windows are allocated first.
  static Future<List<ProvisionalAllocation>> allocateProvisionalSlots({
    required String outletId,
    required String date,
    required String startTime,
    required List<CounterCapacityRequirement> requirements,
    String? excludeGroupId,
  }) async {
    final rows = await _client.rpc(
      'allocate_preference_provisional_slots',
      params: {
        'p_outlet_id': outletId,
        'p_date': date,
        'p_start_time': startTime,
        'p_requirements': serializeCounterCapacityRequirements(requirements),
        'p_exclude_appointment_group_id': _nullIfBlank(excludeGroupId),
      },
    );
    return _asMapList(rows).map(ProvisionalAllocation.fromMap).toList();
  }

  /// Diagnostic counts for an outlet/date so the picker can explain an empty
  /// queue: whether nobody is scheduled today vs. whether therapist working
  /// hours simply haven't been configured.
  static Future<QueueScheduleStatus> getQueueScheduleStatus({
    required String outletId,
    required String date,
  }) async {
    final rows = await _client.rpc(
      'get_queue_schedule_status',
      params: {'p_outlet_id': outletId, 'p_date': date},
    );
    return QueueScheduleStatus.fromMap(_firstMap(rows));
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

Map<String, dynamic>? _nullableMap(Object? value) {
  if (value is! Map) return null;
  return Map<String, dynamic>.from(value);
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

int? _nullableInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value.toString());
}

DateTime? _nullableDateTime(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
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

bool _isMissingRpc(Object error) {
  if (error is! PostgrestException) return false;
  final code = error.code?.toUpperCase() ?? '';
  final message = error.message.toLowerCase();
  return code == 'PGRST202' ||
      code == '42883' ||
      message.contains('could not find the function') ||
      message.contains('does not exist');
}
