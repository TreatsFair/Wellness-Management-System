import 'app.dart';
import 'core/supabase/production_supabase_config.dart';

Future<void> main() {
  return runTreatsApp(
    const TreatsAppConfiguration(
      supabaseUrl: ProductionSupabaseConfig.url,
      supabasePublishableKey: ProductionSupabaseConfig.publishableKey,
      appTitle: 'Treats',
    ),
  );
}
