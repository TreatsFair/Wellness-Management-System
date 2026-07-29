import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/services/csp_service.dart';

/// Shared individual-room ("Room 1", "Room 2", …) presentation for body-room
/// zones. Used by the walk-in flow, where a room can be picked, and by the
/// appointment flow, where the room unit is locked by the
/// `assign_appointment_room_unit` trigger and the list is informational.
///
/// Laid out two per row so a body zone with eight rooms reads as four short
/// rows instead of one long column; it falls back to a single column when
/// there isn't room for two.
class RoomUnitGrid extends StatelessWidget {
  const RoomUnitGrid({
    super.key,
    required this.units,
    this.selectedUnitId,
    this.onSelected,
  });

  final List<RoomUnitAvailability> units;

  final String? selectedUnitId;

  /// Null makes the grid read-only — the appointment flow cannot choose a room
  /// unit, so its cards must not look tappable.
  final ValueChanged<RoomUnitAvailability>? onSelected;

  @override
  Widget build(BuildContext context) {
    const spacing = 8.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 380 ? 2 : 1;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final unit in units)
              SizedBox(
                width: itemWidth,
                child: RoomUnitCard(
                  unit: unit,
                  isSelected: selectedUnitId == unit.id,
                  onTap: onSelected == null ? null : () => onSelected!(unit),
                ),
              ),
          ],
        );
      },
    );
  }
}

class RoomUnitCard extends StatelessWidget {
  const RoomUnitCard({
    super.key,
    required this.unit,
    required this.isSelected,
    this.onTap,
  });

  final RoomUnitAvailability unit;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = switch (unit.status) {
      'occupied' => const Color(0xFFDC2626),
      'cleaning' => const Color(0xFFF59E0B),
      _ when !unit.availableForRequestedTime => const Color(0xFFF59E0B),
      _ => const Color(0xFF059669),
    };
    return Material(
      color: isSelected ? const Color(0xFFE8F5F5) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isSelected ? const Color(0xFF1B6B72) : const Color(0xFFE5E7EB),
          width: isSelected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          child: Row(
            children: [
              Icon(Icons.meeting_room_outlined, color: color, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      unit.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      roomUnitAvailabilityLabel(unit),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                const Icon(Icons.check_circle, color: Color(0xFF1B6B72)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 'Available now' / 'Reserved 4:30 PM–5:30 PM'.
String roomUnitAvailabilityLabel(RoomUnitAvailability unit) {
  if (unit.status == 'available' && unit.availableForRequestedTime) {
    return 'Available now';
  }
  final rawStart = unit.reservationStartAt;
  final rawEnd = unit.reservationEndAt ?? unit.availableAt;
  if (rawStart == null ||
      rawStart.isEmpty ||
      rawEnd == null ||
      rawEnd.isEmpty) {
    return switch (unit.status) {
      'cleaning' => 'Cleaning',
      'occupied' => 'Occupied',
      _ => 'Reserved',
    };
  }
  try {
    final start = DateFormat(
      'h:mm a',
    ).format(DateFormat('HH:mm').parse(rawStart));
    final end = DateFormat('h:mm a').format(DateFormat('HH:mm').parse(rawEnd));
    return 'Reserved $start–$end';
  } catch (_) {
    return 'Reserved $rawStart–$rawEnd';
  }
}
