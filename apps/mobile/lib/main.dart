import 'package:flutter/material.dart';
import 'package:flutter_phoenix/flutter_phoenix.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
import 'src/core/config/environment.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Environment.ensureSupabaseConfig();
  await Supabase.initialize(
    url: Environment.supabaseUrl,
    anonKey: Environment.supabaseAnonKey,
  );

  runApp(
    Phoenix(
      child: const App(),
    ),
  );
}
