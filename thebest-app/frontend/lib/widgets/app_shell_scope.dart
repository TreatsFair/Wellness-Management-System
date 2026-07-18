import 'package:flutter/widgets.dart';

abstract final class AppShellTabs {
  static const int home = 0;
  static const int appointments = 1;
  static const int timetable = 2;
  static const int history = 3;
  static const int more = 4;
}

class AppShellScope extends InheritedWidget {
  final void Function(int index) selectTab;
  final bool fullscreen;
  final ValueChanged<bool> setFullscreen;

  const AppShellScope({
    super.key,
    required this.selectTab,
    required this.fullscreen,
    required this.setFullscreen,
    required super.child,
  });

  static AppShellScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppShellScope>();

  @override
  bool updateShouldNotify(AppShellScope oldWidget) =>
      fullscreen != oldWidget.fullscreen;
}
