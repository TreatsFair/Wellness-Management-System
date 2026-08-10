import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/accessibility/accessibility_settings.dart';
import 'core/outlets/outlet_context.dart';
import 'core/services/service_category_order.dart';
import 'core/theme/app_theme.dart';
import 'data/repositories/auth_repository.dart';
import 'screens/auth/login_screen.dart';
import 'widgets/app_shell.dart';

class TreatsAppConfiguration {
  const TreatsAppConfiguration({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    required this.appTitle,
    this.environmentBannerText,
  });

  final String supabaseUrl;
  final String supabasePublishableKey;
  final String appTitle;
  final String? environmentBannerText;
}

Future<void> runTreatsApp(TreatsAppConfiguration configuration) async {
  WidgetsFlutterBinding.ensureInitialized();
  await ServiceCategoryOrderController.instance.initialize();

  await Supabase.initialize(
    url: configuration.supabaseUrl,
    publishableKey: configuration.supabasePublishableKey,
  );

  await AccessibilityController.instance.initialize(
    Supabase.instance.client.auth.currentUser?.id,
  );

  runApp(TreatsApp(configuration: configuration));
}

class TreatsApp extends StatefulWidget {
  const TreatsApp({required this.configuration, super.key});

  final TreatsAppConfiguration configuration;

  @override
  State<TreatsApp> createState() => _TreatsAppState();
}

class _TreatsAppState extends State<TreatsApp> {
  StreamSubscription<AuthState>? _authSubscription;
  String? _authenticatedUserId;

  @override
  void initState() {
    super.initState();
    _authenticatedUserId = Supabase.instance.client.auth.currentUser?.id;
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen(
      (state) {
        final nextUserId = state.session?.user.id;
        if (nextUserId != _authenticatedUserId) {
          OutletContext.reset();
          _authenticatedUserId = nextUserId;
        }
        unawaited(AccessibilityController.instance.useUser(nextUserId));
      },
    );
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AccessibilityPreferences>(
      valueListenable: AccessibilityController.instance,
      builder: (context, preferences, _) {
        final metrics = UiScaleMetrics.forPreset(preferences.preset);
        return MaterialApp(
          title: widget.configuration.appTitle,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(metrics),
          darkTheme: AppTheme.dark(metrics),
          themeMode: preferences.themePreference.themeMode,
          builder: (context, child) {
            final mediaQuery = MediaQuery.of(context);
            final systemScale = preferences.followSystemTextScale
                ? mediaQuery.textScaler.scale(1)
                : 1.0;
            final app = MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: TextScaler.linear(
                  systemScale * metrics.textScale,
                ),
              ),
              child: child ?? const SizedBox.shrink(),
            );
            final bannerText = widget.configuration.environmentBannerText;

            if (bannerText == null) {
              return app;
            }

            return Column(
              children: [
                Material(
                  color: const Color(0xFFFFC107),
                  child: SafeArea(
                    bottom: false,
                    child: SizedBox(
                      width: double.infinity,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text(
                          bannerText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFF2C2100),
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(child: app),
              ],
            );
          },
          home: Builder(
            builder: (context) {
              final authRepository = AuthRepository();

              return StreamBuilder<Session?>(
                stream: authRepository.sessionChanges,
                initialData: authRepository.currentSession,
                builder: (context, snapshot) {
                  if (snapshot.hasData) {
                    return const AppShell();
                  }

                  return const LoginScreen();
                },
              );
            },
          ),
        );
      },
    );
  }
}
