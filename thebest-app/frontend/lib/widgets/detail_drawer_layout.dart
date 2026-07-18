abstract final class DetailDrawerLayout {
  static const double widthFactor = 0.36;
  static const double minWidth = 390;
  static const double maxWidth = 460;
  static const double maxHeight = 820;
  static const double rightMargin = 16;

  static double widthFor(double availableWidth) =>
      (availableWidth * widthFactor).clamp(minWidth, maxWidth).toDouble();

  static double topMarginFor(double availableHeight) =>
      availableHeight < 720 ? 8 : 16;

  static double maxHeightFor(double availableHeight) {
    final topMargin = topMarginFor(availableHeight);
    return (availableHeight - topMargin * 2)
        .clamp(240, maxHeight)
        .toDouble();
  }
}
