import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_phoenix/flutter_phoenix.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
import 'src/core/config/environment.dart';

const bool _devForceSignOutOnStart = bool.fromEnvironment(
  'DEV_FORCE_SIGNOUT_ON_START',
  defaultValue: true,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Environment.ensureSupabaseConfig();
  await Supabase.initialize(
    url: Environment.supabaseUrl,
    anonKey: Environment.supabaseAnonKey,
  );

  if (!kReleaseMode && _devForceSignOutOnStart) {
    final auth = Supabase.instance.client.auth;
    if (auth.currentSession != null) {
      try {
        await auth.signOut(scope: SignOutScope.global);
      } catch (_) {
        await auth.signOut(scope: SignOutScope.local);
      }
      if (auth.currentSession != null) {
        await auth.signOut(scope: SignOutScope.local);
      }
      debugPrint('[Auth][Dev] Existing session clear attempted on app startup. sessionPresent=${auth.currentSession != null}');
    }
  }

  runApp(
    Phoenix(
      child: const App(),
    ),
  );
}
