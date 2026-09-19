abstract final class AppEnvironment {
  static bool _isStaging = false;

  static bool get isStaging => _isStaging;

  static void initialize({required bool isStaging}) {
    _isStaging = isStaging;
  }
}
