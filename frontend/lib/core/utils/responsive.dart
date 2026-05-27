import 'package:flutter/material.dart';

class Responsive {
  static bool isPhone(BuildContext context) =>
      MediaQuery.of(context).size.width < 600;

  static bool isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= 600;

  static double screenWidth(BuildContext context) =>
      MediaQuery.of(context).size.width;

  static double screenHeight(BuildContext context) =>
      MediaQuery.of(context).size.height;

  // Use this for horizontal padding — tighter on phone, wider on tablet
  static double horizontalPadding(BuildContext context) =>
      isTablet(context) ? 48.0 : 24.0;

  // Use this for card width — full on phone, capped on tablet
  static double cardMaxWidth(BuildContext context) =>
      isTablet(context) ? 600.0 : double.infinity;
}