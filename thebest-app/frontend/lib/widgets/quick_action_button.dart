import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import 'app_card.dart';

/// Large, obvious tappable tile for the actions staff use constantly.
/// Sized for fingers and readable at a glance for non-technical users.
class QuickActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? sublabel;
  final VoidCallback onTap;

  /// When true the tile is filled with the brand color (the single primary
  /// action on a screen); otherwise it is a white card.
  final bool emphasized;

  const QuickActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.sublabel,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = emphasized ? Colors.white : scheme.onSurface;
    final iconBg = emphasized ? Colors.white24 : scheme.primaryContainer;
    final iconFg = emphasized ? Colors.white : scheme.onPrimaryContainer;
    return AppCard(
      onTap: onTap,
      color: emphasized ? AppColors.primary : null,
      borderColor: emphasized ? AppColors.primary : null,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.lg,
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Icon(icon, color: iconFg, size: 24),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
                if (sublabel != null)
                  Text(
                    sublabel!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: emphasized ? Colors.white70 : scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right,
            color: emphasized ? Colors.white70 : scheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}
