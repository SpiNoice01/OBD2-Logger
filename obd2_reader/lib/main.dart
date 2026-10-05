import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'controllers/obd_controller.dart';
import 'controllers/mock_obd_controller.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'controllers/theme_controller.dart';
import 'screens/device_list_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Layar tetap menyala selama app terbuka di foreground (seperti saat
  // menonton video). OS otomatis melepasnya saat app ke background.
  WakelockPlus.enable();
  runApp(const Obd2ReaderApp());
}

class Obd2ReaderApp extends StatelessWidget {
  const Obd2ReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) {
          // Use MockObdController on Web or non-Android desktop platforms
          if (kIsWeb) {
            return MockObdController();
          }
          if (defaultTargetPlatform != TargetPlatform.android) {
            return MockObdController();
          }
          return ObdController();
        }),
        ChangeNotifierProvider(create: (_) => ThemeController()),
      ],
      child: Consumer<ThemeController>(
        builder: (context, themeCtrl, _) => MaterialApp(
          title: 'OBD2 Reader',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: Colors.teal,
            useMaterial3: true,
            brightness: Brightness.light,
          ),
          darkTheme: ThemeData(
            colorSchemeSeed: Colors.teal,
            useMaterial3: true,
            brightness: Brightness.dark,
          ),
          themeMode: themeCtrl.mode,
          home: const DeviceListScreen(),
        ),
      ),
    );
  }
}
