import 'package:flutter/material.dart';

/// The "2 Payment" pill in a checkout page header. Shared so the walk-in and
/// appointment checkout pages read as the same step in the same flow.
class CheckoutStepPill extends StatelessWidget {
  const CheckoutStepPill({
    super.key,
    this.number = 2,
    this.label = 'Payment',
    this.isActive = true,
  });

  final int number;
  final String label;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final onPill = isActive ? Colors.white : const Color(0xFF9E9E9E);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFF1B6B72) : const Color(0xFFF0F0F0),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive
                  ? Colors.white.withValues(alpha: 0.25)
                  : const Color(0xFFDDDDDD),
            ),
            child: Center(
              child: Text(
                '$number',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: onPill,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: onPill,
            ),
          ),
        ],
      ),
    );
  }
}

/// Footer note under a checkout page's confirm button.
class CheckoutConfirmHint extends StatelessWidget {
  const CheckoutConfirmHint({super.key, required this.canConfirm});

  final bool canConfirm;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        canConfirm
            ? 'A receipt will be recorded automatically'
            : 'Select a payment method to continue\n'
                  'A receipt will be recorded automatically',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E)),
      ),
    );
  }
}

/// The booking date, shown once above the guest cards on a checkout page so
/// staff can see which day they are settling without opening a card.
class CheckoutDateHeader extends StatelessWidget {
  const CheckoutDateHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          const Icon(
            Icons.calendar_today_outlined,
            size: 15,
            color: Color(0xFF0F766E),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1A1A2E),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One service line inside a [CheckoutGuestCard].
class CheckoutGuestLine {
  const CheckoutGuestLine({
    required this.name,
    required this.durationMinutes,
    required this.price,
    this.typeLabel = 'Main Service',
    this.isPaid = false,
    this.imageUrl = '',
  });

  final String name;
  final int durationMinutes;
  final double price;

  /// 'Main Service' / 'Add-on' / 'Package'.
  final String typeLabel;
  final bool isPaid;
  final String imageUrl;
}

/// The per-guest summary card on the checkout page: a collapsed header with the
/// guest, therapist and room, expanding to the service lines being paid for.
///
/// Shared so the walk-in and appointment checkout pages present a booking the
/// same way. It deliberately carries no therapist-lock or duration panel —
/// checkout is for confirming what is being paid, not for changing resources.
class CheckoutGuestCard extends StatelessWidget {
  const CheckoutGuestCard({
    super.key,
    required this.index,
    required this.guestName,
    required this.therapistLabel,
    required this.roomLabel,
    required this.lines,
    required this.storageKey,
    this.initiallyExpanded = true,
    this.showGuestNameInTitle = true,
    this.trailingNote = '',
  });

  final int index;
  final String guestName;
  final String therapistLabel;
  final String roomLabel;
  final List<CheckoutGuestLine> lines;

  /// Keeps each card's expanded state stable across rebuilds.
  final String storageKey;
  final bool initiallyExpanded;
  final bool showGuestNameInTitle;

  /// Optional extra line under the meta row, e.g. 'Start: Now - 11:59 AM'.
  final String trailingNote;

  @override
  Widget build(BuildContext context) {
    final displayName = guestName.trim().isEmpty ? 'Guest' : guestName.trim();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: PageStorageKey('checkout-guest-$storageKey'),
          initiallyExpanded: initiallyExpanded,
          maintainState: true,
          tilePadding: const EdgeInsets.all(12),
          childrenPadding: EdgeInsets.zero,
          leading: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFEAF7F6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                color: Color(0xFF0F766E),
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          title: Text(
            showGuestNameInTitle
                ? 'Guest ${index + 1} - $displayName'
                : 'Guest ${index + 1}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: Color(0xFF1A1A2E),
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 5,
                  children: [
                    if (therapistLabel.trim().isNotEmpty)
                      _GuestMeta(
                        icon: Icons.person_outline,
                        text: therapistLabel,
                      ),
                    if (roomLabel.trim().isNotEmpty)
                      _GuestMeta(
                        icon: Icons.meeting_room_outlined,
                        text: roomLabel,
                      ),
                  ],
                ),
                if (trailingNote.trim().isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    trailingNote,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                ],
              ],
            ),
          ),
          children: [
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (lines.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No service selected',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    )
                  else
                    for (var i = 0; i < lines.length; i++) ...[
                      _CheckoutServiceCard(line: lines[i]),
                      if (i != lines.length - 1) const SizedBox(height: 10),
                    ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuestMeta extends StatelessWidget {
  const _GuestMeta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: const Color(0xFF0F766E)),
        const SizedBox(width: 4),
        Text(
          text,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6B7280),
          ),
        ),
      ],
    );
  }
}

class _CheckoutServiceCard extends StatelessWidget {
  const _CheckoutServiceCard({required this.line});

  final CheckoutGuestLine line;

  @override
  Widget build(BuildContext context) {
    final typeColor = switch (line.typeLabel.toLowerCase()) {
      'add-on' => const Color(0xFFB45309),
      'package' => const Color(0xFF7C3AED),
      _ => const Color(0xFF0F766E),
    };
    final paymentColor = line.isPaid
        ? const Color(0xFF047857)
        : const Color(0xFFB45309);

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 54,
              height: 54,
              color: const Color(0xFFF1F5F9),
              child: line.imageUrl.isEmpty
                  ? const Icon(Icons.spa_outlined, color: Color(0xFF64748B))
                  : Image.network(
                      line.imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.spa_outlined,
                        color: Color(0xFF64748B),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.name.trim().isEmpty ? 'Service' : line.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 7,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${line.durationMinutes} min',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                    _ServicePill(label: line.typeLabel, color: typeColor),
                    _ServicePill(
                      label: line.isPaid ? 'Paid' : 'Unpaid',
                      color: paymentColor,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'RM ${line.price.toStringAsFixed(2)}',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w900,
              color: Color(0xFF0F8A5F),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServicePill extends StatelessWidget {
  const _ServicePill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w900,
          color: color,
        ),
      ),
    );
  }
}
