import 'package:flutter/material.dart';

class CheckoutPaymentMethodGrid extends StatelessWidget {
  const CheckoutPaymentMethodGrid({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final String? selected;
  final ValueChanged<String> onSelected;

  static const _primary = <(String, String, IconData)>[
    ('cash', 'Cash', Icons.payments_outlined),
    ('qr_code', 'QR Code', Icons.qr_code_2_outlined),
    ('credit_card', 'Credit Card', Icons.credit_card_outlined),
    ('debit_card', 'Debit Card', Icons.credit_card),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width >= 760) {
          return Row(
            children: [
              for (var index = 0; index < 5; index++) ...[
                if (index > 0) const SizedBox(width: 12),
                Expanded(
                  child: _PaymentMethodCard(
                    method: index == 4 ? 'others' : _primary[index].$1,
                    label: index == 4 ? 'Others' : _primary[index].$2,
                    icon: index == 4
                        ? Icons.more_horiz_rounded
                        : _primary[index].$3,
                    selected: selected,
                    onSelected: onSelected,
                  ),
                ),
              ],
            ],
          );
        }

        final columns = width < 430 ? 2 : 4;
        final cardWidth = (width - (columns - 1) * 12) / columns;
        return Column(
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final method in _primary)
                  SizedBox(
                    width: cardWidth,
                    child: _PaymentMethodCard(
                      method: method.$1,
                      label: method.$2,
                      icon: method.$3,
                      selected: selected,
                      onSelected: onSelected,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            _PaymentMethodCard(
              method: 'others',
              label: 'Others',
              icon: Icons.more_horiz_rounded,
              selected: selected,
              onSelected: onSelected,
              horizontal: true,
            ),
          ],
        );
      },
    );
  }
}

class _PaymentMethodCard extends StatelessWidget {
  const _PaymentMethodCard({
    required this.method,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onSelected,
    this.horizontal = false,
  });

  final String method;
  final String label;
  final IconData icon;
  final String? selected;
  final ValueChanged<String> onSelected;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final isSelected = selected == method;
    final color = isSelected
        ? const Color(0xFF1B6B72)
        : const Color(0xFF6B7280);
    return InkWell(
      onTap: () => onSelected(method),
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        constraints: BoxConstraints(minHeight: horizontal ? 58 : 92),
        padding: EdgeInsets.symmetric(
          horizontal: horizontal ? 18 : 10,
          vertical: horizontal ? 12 : 14,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFFE8F5F4)
              : const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF1B6B72)
                : const Color(0xFFE2E8F0),
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: horizontal
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color, size: 23),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (isSelected) ...[
                    const SizedBox(width: 10),
                    const Icon(
                      Icons.check_circle,
                      size: 18,
                      color: Color(0xFF1B6B72),
                    ),
                  ],
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: color, size: 25),
                  const SizedBox(height: 9),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
