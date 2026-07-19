import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/services/csp_service.dart';

void main() {
  test('parses exact booking boundaries and stranded gaps', () {
    final slot = CspTimeSlot.fromMap({
      'start_time': '19:33:00',
      'end_time': '20:33:00',
      'classification': 'recommended',
      'score': 240,
      'reason': 'starts_after_booking',
      'room_available_slots': 2,
      'previous_block_end': '19:33:00',
      'next_block_start': '21:00:00',
      'gap_before_minutes': 0,
      'gap_after_minutes': 27,
    });

    expect(slot.startTime, '19:33');
    expect(slot.endTime, '20:33');
    expect(slot.isRecommended, isTrue);
    expect(slot.previousBlockEnd, '19:33');
    expect(slot.nextBlockStart, '21:00');
    expect(slot.gapBeforeMinutes, 0);
    expect(slot.gapAfterMinutes, 27);
    expect(slot.roomAvailableSlots, 2);
  });

  test('parses treatment end separately from cleanup block end', () {
    final block = CspScheduleBlock.fromMap({
      'start_time': '18:33:00',
      'end_time': '19:33:00',
      'blocked_until': '19:38:00',
      'kind': 'appointment',
      'label': 'Head Massage',
    });

    expect(block.startTime, '18:33');
    expect(block.endTime, '19:33');
    expect(block.blockedUntil, '19:38');
    expect(block.hasCleanup, isTrue);
  });

  test('zero-buffer schedule block has no cleanup period', () {
    final block = CspScheduleBlock.fromMap({
      'start_time': '18:33:00',
      'end_time': '19:33:00',
      'blocked_until': '19:33:00',
      'kind': 'appointment',
      'label': 'Head Massage',
    });

    expect(block.hasCleanup, isFalse);
  });
}
