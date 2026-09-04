import 'package:flutter/material.dart';

import 'state/app_controller.dart';
import 'ui/home_page.dart';
import 'ui/widgets/common.dart';

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
