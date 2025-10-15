import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/measure/presentation/measure_screen.dart';
import 'background/bg_workmanager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await schedulePeriodicSync();  // 定期 Wi‑Fi 上傳（留白）

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
