import 'package:flutter/material.dart';

class Responsive {
  static const double tabletBreakpoint = 900;
  static const double desktopBreakpoint = 1200;

  static bool isPhone(BuildContext context) =>
      MediaQuery.of(context).size.width < tabletBreakpoint;

  static bool isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= tabletBreakpoint;

  static bool isDesktop(BuildContext context) =>
      MediaQuery.of(context).size.width >= desktopBreakpoint;

  static double screenWidth(BuildContext context) =>
      MediaQuery.of(context).size.width;

  static double screenHeight(BuildContext context) =>
      MediaQuery.of(context).size.height;

  static double uiScale(Size size) {
    final width = size.width;
    if (width < 600) return 1;
    if (width < tabletBreakpoint) return 0.9;
    if (width < desktopBreakpoint) return 0.94;
    return 1;
  }

  static double horizontalPadding(BuildContext context) =>
      isTablet(context) ? 28.0 : 18.0;

  static double cardMaxWidth(BuildContext context) =>
      isTablet(context) ? 500.0 : double.infinity;
}
