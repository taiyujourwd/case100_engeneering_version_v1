import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/measure/presentation/measure_screen.dart';
import 'background/bg_workmanager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await schedulePeriodicSync();  // 定期 Wi‑Fi 上傳（留白）

  // 設定螢幕方向： 只允許直向
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,      // 正常直向
    DeviceOrientation.portraitDown,    // 上下顛倒直向（可選，通常不需要）
  ]);

  // ✅ 設定全螢幕模式（隱藏狀態欄和導航欄）
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.immersiveSticky,  // 全螢幕且滑動後自動隱藏
    overlays: [],  // 隱藏所有系統 UI
  );

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: const MeasureScreen(),
    );
  }
}
