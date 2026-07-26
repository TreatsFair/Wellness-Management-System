import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/services/payment_service.dart';
import 'package:frontend/core/services/csp_service.dart';
import 'package:frontend/core/utils/error_message.dart';
import 'package:frontend/screens/appointments/appointment_checkin_logic.dart';

void main() {
  group('Phase 6B RPC response parsing', () {
    test('single finalisation captures authoritative start and resources', () {
      final result = PaymentResult.fromMap({
        'success': true,
        'appointment_id': 'appointment-1',
        'transaction_id': 'transaction-1',
        'actual_started_at': '2026-07-26T02:15:00Z',
        'expected_end_at': '2026-07-26T11:45:00+08:00',
        'therapist_id': 'therapist-1',
        'room_id': 'body-zone',
        'room_unit_id': 'room-3',
      });

      expect(result.success, isTrue);
      expect(result.appointmentId, 'appointment-1');
      expect(result.transactionId, 'transaction-1');
      expect(
        result.actualStartedAt,
        DateTime.parse('2026-07-26T02:15:00Z'),
      );
      expect(result.expectedEndAt, isNotNull);
      expect(result.therapistId, 'therapist-1');
      expect(result.roomId, 'body-zone');
      expect(result.roomUnitId, 'room-3');
    });

    test('group finalisation accepts camel-case response keys', () {
      final result = PaymentResult.fromMap({
        'success': true,
        'appointmentGroupId': 'group-1',
        'appointmentIds': ['pax-1', 'pax-2'],
        'actualStartedAt': '2026-07-26T02:15:00+00:00',
      });

      expect(result.appointmentGroupId, 'group-1');
      expect(result.appointmentIds, ['pax-1', 'pax-2']);
      expect(result.actualStartedAt, isNotNull);
    });

    test('missing started timestamp remains distinguishable', () {
      final result = PaymentResult.fromMap({
        'success': true,
        'appointment_id': 'appointment-1',
      });

      expect(result.success, isTrue);
      expect(result.actualStartedAt, isNull);
    });
  });

  group('Phase 6B staff-facing errors', () {
    test('busy therapist conflict has a clear recovery action', () {
      const error = AppointmentOperationException(
        code: 'THERAPIST_BUSY',
        message: 'database detail',
      );

      expect(
        friendlyErrorMessage(error),
        'That therapist is busy during this service window. Choose another therapist.',
      );
    });

    test('unknown operation errors retain the server message', () {
      const error = AppointmentOperationException(
        code: 'CAPACITY_CONFLICT',
        message: 'No eligible therapist remains for this time.',
      );

      expect(
        friendlyErrorMessage(error),
        'No eligible therapist remains for this time.',
      );
    });
  });

  group('Per-pax therapist preference contract', () {
    test('two pax serialize with one-based indexes', () {
      const requirements = [
        CounterCapacityRequirement(
          paxIndex: 1,
          serviceIds: ['service-1'],
          durationMinutes: 60,
          roomType: 'body_room',
        ),
        CounterCapacityRequirement(
          paxIndex: 2,
          serviceIds: ['service-2'],
          durationMinutes: 45,
          roomType: 'foot_chair',
        ),
      ];

      final payload = serializeCounterCapacityRequirements(requirements);

      expect(payload.map((row) => row['pax_index']).toList(), [1, 2]);
    });

    test('zero-based requirements are rejected before the RPC call', () {
      const requirements = [
        CounterCapacityRequirement(
          paxIndex: 0,
          serviceIds: ['service-1'],
          durationMinutes: 60,
          roomType: 'body_room',
        ),
      ];

      expect(
        () => serializeCounterCapacityRequirements(requirements),
        throwsArgumentError,
      );
    });

    test('specific request serializes independently for capacity matching', () {
      const requirement = CounterCapacityRequirement(
        paxIndex: 2,
        serviceIds: ['service-1'],
        durationMinutes: 90,
        bufferAfterMinutes: 10,
        roomType: 'body_room',
        assignmentSource: 'specific_customer_request',
        requestedTherapistId: 'therapist-1',
      );

      expect(requirement.toRpcMap(), {
        'pax_index': 2,
        'service_ids': ['service-1'],
        'duration_minutes': 90,
        'buffer_after_minutes': 10,
        'room_type': 'body_room',
        'assignment_source': 'specific_customer_request',
        'requested_gender': null,
        'requested_therapist_id': 'therapist-1',
      });
    });

    test('gender preference stays anonymous in the RPC requirement', () {
      const requirement = CounterCapacityRequirement(
        paxIndex: 1,
        serviceIds: ['service-2'],
        durationMinutes: 60,
        roomType: 'foot_chair',
        assignmentSource: 'gender_preference',
        requestedGender: 'Female',
      );

      expect(requirement.toRpcMap()['requested_gender'], 'Female');
      expect(requirement.toRpcMap()['requested_therapist_id'], isNull);
    });
  });

  group('Flexible therapist final-start payload', () {
    test('queue and gender preferences discard stale provisional IDs', () {
      expect(
        therapistIdForFinalStart(
          assignmentSource: 'queue',
          selectedTherapistId: 'stale-therapist-4',
        ),
        isNull,
      );
      expect(
        therapistIdForFinalStart(
          assignmentSource: 'gender_preference',
          selectedTherapistId: 'stale-female-therapist',
        ),
        isNull,
      );
    });

    test('specific requests and manual overrides retain their fixed IDs', () {
      expect(
        therapistIdForFinalStart(
          assignmentSource: 'specific_customer_request',
          selectedTherapistId: 'requested-therapist',
        ),
        'requested-therapist',
      );
      expect(
        therapistIdForFinalStart(
          assignmentSource: 'manual_override',
          selectedTherapistId: 'staff-selected-therapist',
        ),
        'staff-selected-therapist',
      );
    });

    test('multi-pax payload keeps flexible IDs null independently', () {
      const sources = ['queue', 'gender_preference'];
      const provisionalIds = ['therapist-4', 'therapist-5'];

      final payload = [
        for (var index = 0; index < sources.length; index++)
          {
            'pax_index': index + 1,
            'assignment_source': sources[index],
            'therapist_id': therapistIdForFinalStart(
              assignmentSource: sources[index],
              selectedTherapistId: provisionalIds[index],
            ),
          },
      ];

      expect(payload, [
        {
          'pax_index': 1,
          'assignment_source': 'queue',
          'therapist_id': null,
        },
        {
          'pax_index': 2,
          'assignment_source': 'gender_preference',
          'therapist_id': null,
        },
      ]);
    });
  });
}
