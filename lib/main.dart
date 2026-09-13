import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import 'helpers/overlay_window.dart';
import 'state/app_controller.dart';
import 'ui/home_page.dart';
import 'ui/widgets/common.dart';

@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    FlutterOverlayWindow.shareData('overlay_boot');
    runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: OverlayWindowApp(),
    ));
  } catch (e, st) {
    debugPrint('overlayMain error: $e\n$st');
    FlutterOverlayWindow.shareData('overlay_boot_error');
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NfcToolApp());
}

class NfcToolApp extends StatelessWidget {
  const NfcToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: AppScope.instance.controller.ble.status,
      builder: (context, _, _) {
        return MaterialApp(
          title: 'NFC Tool',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(),
          home: const HomePage(),
        );
      },
    );
  }
}

/// 全局作用域（提供单例 AppController）
class AppScope {
  AppScope._();
  static final AppScope instance = AppScope._();
  final AppController controller = AppController();
}
