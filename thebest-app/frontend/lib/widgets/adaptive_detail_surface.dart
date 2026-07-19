import 'package:flutter/material.dart';

import '../core/utils/responsive.dart';
import 'detail_drawer_layout.dart';

typedef AdaptiveDetailBuilder =
    Widget Function(BuildContext context, bool isFullScreen);

/// Opens detailed work in one predictable place: a right-side drawer on
/// tablet/desktop and a full-screen route on a phone.
Future<T?> showAdaptiveDetailSurface<T>({
  required BuildContext context,
  required AdaptiveDetailBuilder builder,
  String barrierLabel = 'Close details',
}) {
  final media = MediaQuery.of(context);
  if (media.size.width < Responsive.tabletBreakpoint) {
    return Navigator.of(context).push<T>(
      PageRouteBuilder<T>(
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context, true),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final offset = Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          );
          return SlideTransition(position: offset, child: child);
        },
      ),
    );
  }

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: false,
    barrierLabel: barrierLabel,
    barrierColor: Colors.black.withValues(alpha: 0.28),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) {
      final size = MediaQuery.sizeOf(context);
      final topMargin = DetailDrawerLayout.topMarginFor(size.height);
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            0,
            topMargin,
            DetailDrawerLayout.rightMargin,
            topMargin,
          ),
          child: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: DetailDrawerLayout.widthFor(size.width),
              height: DetailDrawerLayout.maxHeightFor(size.height),
              child: Material(
                clipBehavior: Clip.antiAlias,
                color: Theme.of(context).colorScheme.surface,
                elevation: 18,
                shadowColor: Colors.black.withValues(alpha: 0.22),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: builder(context, false),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final offset = Tween<Offset>(
        begin: const Offset(0.12, 0),
        end: Offset.zero,
      ).animate(
        CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      );
      return FadeTransition(
        opacity: animation,
        child: SlideTransition(position: offset, child: child),
      );
    },
  );
}
