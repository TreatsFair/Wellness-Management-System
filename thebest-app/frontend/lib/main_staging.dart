import 'app.dart';
import 'core/supabase/supabase_config.dart';

Future<void> main() {
  return runTreatsApp(
    const TreatsAppConfiguration(
      supabaseUrl: SupabaseConfig.url,
      supabasePublishableKey: SupabaseConfig.publishableKey,
      appTitle: 'Treats — STAGING',
      isStaging: true,
      environmentBannerText: 'STAGING — DUMMY DATA',
    ),
  );
}
