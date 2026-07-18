import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/accessibility/accessibility_settings.dart';
import 'core/supabase/supabase_config.dart';
import 'core/theme/app_theme.dart';
import 'data/repositories/auth_repository.dart';
import 'screens/auth/login_screen.dart';
import 'widgets/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.publishableKey,
  );

  await AccessibilityController.instance.initialize(
    Supabase.instance.client.auth.currentUser?.id,
  );

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen(
      (state) => unawaited(
        AccessibilityController.instance.useUser(state.session?.user.id),
      ),
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
          title: 'Treats',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(metrics),
          darkTheme: AppTheme.dark(metrics),
          themeMode: preferences.themePreference.themeMode,
          builder: (context, child) {
            final mediaQuery = MediaQuery.of(context);
            final systemScale = preferences.followSystemTextScale
                ? mediaQuery.textScaler.scale(1)
                : 1.0;
            return MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: TextScaler.linear(
                  systemScale * metrics.textScale,
                ),
              ),
              child: child ?? const SizedBox.shrink(),
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
