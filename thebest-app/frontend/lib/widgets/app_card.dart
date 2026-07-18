import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// The one card used everywhere: white surface, 1px border, 12px radius.
/// When [onTap] is set it renders a proper ripple so taps give visible
/// feedback (screens must not wrap cards in bare GestureDetectors).
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final Color? borderColor;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.onTap,
    this.color,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.card),
      side: BorderSide(color: borderColor ?? context.appBorder),
    );
    return Material(
      color: color ?? context.appSurface,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? Padding(padding: padding, child: child)
          : InkWell(
              onTap: onTap,
              child: Padding(padding: padding, child: child),
            ),
    );
  }
}
