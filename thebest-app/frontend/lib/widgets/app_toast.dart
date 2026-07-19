import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// Top-anchored notification-style toast, used instead of bottom snackbars
/// for errors, confirmations, and live notifications.
///
/// Usage:
///   AppToast.error(context, 'Unable to load available slots');
///   AppToast.success(context, 'Appointment saved');
///   AppToast.notice(context, title: 'New online booking', message: '...',
///       actionLabel: 'View', onAction: () { ... });
enum AppToastKind { info, success, error, notice }

class AppToast {
  AppToast._();

  static OverlayEntry? _currentEntry;

  static void show(
    BuildContext context, {
    required String title,
    String message = '',
    AppToastKind kind = AppToastKind.info,
    Duration duration = const Duration(seconds: 5),
    String? actionLabel,
    VoidCallback? onAction,
    IconData? icon,
    Color? accentColor,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    dismiss();

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _AppToastHost(
        title: title,
        message: message,
        kind: kind,
        duration: duration,
        actionLabel: actionLabel,
        onAction: onAction,
        icon: icon,
        accentColor: accentColor,
        onClose: () {
          if (_currentEntry == entry) _currentEntry = null;
          if (entry.mounted) entry.remove();
        },
      ),
    );
    _currentEntry = entry;
    overlay.insert(entry);
  }

  static void dismiss() {
    final entry = _currentEntry;
    _currentEntry = null;
    if (entry != null && entry.mounted) entry.remove();
  }

  static void error(
    BuildContext context,
    String message, {
    String title = 'Something went wrong',
  }) {
    show(
      context,
      title: title,
      message: message,
      kind: AppToastKind.error,
      duration: const Duration(seconds: 6),
    );
  }

  static void success(BuildContext context, String title, {String message = ''}) {
    show(context, title: title, message: message, kind: AppToastKind.success);
  }

  static void info(BuildContext context, String title, {String message = ''}) {
    show(context, title: title, message: message, kind: AppToastKind.info);
  }

  static void notice(
    BuildContext context, {
    required String title,
    String message = '',
    String? actionLabel,
    VoidCallback? onAction,
    IconData? icon,
    Color? accentColor,
  }) {
    show(
      context,
      title: title,
      message: message,
      kind: AppToastKind.notice,
      duration: const Duration(seconds: 7),
      actionLabel: actionLabel,
      onAction: onAction,
      icon: icon,
      accentColor: accentColor,
    );
  }
}

class _AppToastHost extends StatefulWidget {
  final String title;
  final String message;
  final AppToastKind kind;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onClose;
  final IconData? icon;
  final Color? accentColor;

  const _AppToastHost({
    required this.title,
    required this.message,
    required this.kind,
    required this.duration,
    required this.onClose,
    this.actionLabel,
    this.onAction,
    this.icon,
    this.accentColor,
  });

  @override
  State<_AppToastHost> createState() => _AppToastHostState();
}

class _AppToastHostState extends State<_AppToastHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Timer? _dismissTimer;
  var _closing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _dismissTimer = Timer(widget.duration, _close);
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _dismissTimer?.cancel();
    try {
      await _controller.reverse();
    } finally {
      widget.onClose();
    }
  }

  Color get _accent => widget.accentColor ?? switch (widget.kind) {
    AppToastKind.error => const Color(0xFFE53935),
    AppToastKind.success => const Color(0xFF2E7D32),
    AppToastKind.notice => const Color(0xFFB45309),
    AppToastKind.info => const Color(0xFF1B6B72),
  };

  Color get _iconBackground => switch (widget.kind) {
    AppToastKind.error => const Color(0xFFFDECEA),
    AppToastKind.success => const Color(0xFFE8F5E9),
    AppToastKind.notice => const Color(0xFFFFF7ED),
    AppToastKind.info => const Color(0xFFE0F3F1),
  };

  IconData get _icon => widget.icon ?? switch (widget.kind) {
    AppToastKind.error => Icons.error_outline,
    AppToastKind.success => Icons.check_circle_outline,
    AppToastKind.notice => Icons.notifications_active_outlined,
    AppToastKind.info => Icons.info_outline,
  };

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final width = screenWidth >= 520 ? 420.0 : screenWidth - 24;

    return Positioned(
      top: 0,
      right: 0,
      left: screenWidth >= 520 ? null : 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 12, right: 12, left: 12),
          child: Align(
            alignment: Alignment.topRight,
            child: FadeTransition(
              opacity: _controller,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, -0.3),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(
                    parent: _controller,
                    curve: Curves.easeOutCubic,
                  ),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: width,
                    padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                    decoration: BoxDecoration(
                      color: context.appSurfaceRaised,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: context.appBorder),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x1F000000),
                          blurRadius: 18,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _iconBackground,
                          ),
                          child: Icon(_icon, size: 20, color: _accent),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  widget.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: context.appText,
                                  ),
                                ),
                              ),
                              if (widget.message.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Text(
                                  widget.message,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: context.appMuted,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (widget.actionLabel != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 6, top: 2),
                            child: TextButton(
                              onPressed: () {
                                _close();
                                widget.onAction?.call();
                              },
                              style: TextButton.styleFrom(
                                foregroundColor: _accent,
                                minimumSize: const Size(48, 36),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                visualDensity: VisualDensity.compact,
                              ),
                              child: Text(
                                widget.actionLabel!,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        IconButton(
                          onPressed: _close,
                          icon: const Icon(Icons.close, size: 18),
                          color: const Color(0xFF9E9E9E),
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Dismiss',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
