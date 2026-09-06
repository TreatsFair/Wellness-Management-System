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
  final Color? accentColor;

  const QuickActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.sublabel,
    this.emphasized = false,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = accentColor ?? scheme.primary;
    final fg = emphasized ? Colors.white : scheme.onSurface;
    final iconBg = emphasized ? Colors.white24 : accent.withValues(alpha: 0.12);
    final iconFg = emphasized ? Colors.white : accent;
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
                  maxLines: 2,
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
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: emphasized ? Colors.white70 : scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 40,
            height: 40,
            child: Icon(
              Icons.chevron_right_rounded,
              color: emphasized ? Colors.white70 : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
