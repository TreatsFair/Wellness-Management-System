import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/repositories/auth_repository.dart';
import 'core/supabase/supabase_config.dart';
import 'core/utils/responsive.dart';
import 'screens/auth/login_screen.dart';
import 'screens/dashboard/dashboard_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: SupabaseConfig.url,
    publishableKey: SupabaseConfig.publishableKey,
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Treats',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF0F0F0),
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        final scale = Responsive.uiScale(mediaQuery.size);
        return MediaQuery(
          data: mediaQuery.copyWith(
            textScaler: TextScaler.linear(
              mediaQuery.textScaler.scale(1) * scale,
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
                return const DashboardScreen();
              }

              return const LoginScreen();
            },
          );
        },
      ),
    );
  }
}
