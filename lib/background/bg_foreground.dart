import 'package:flutter_foreground_task/flutter_foreground_task.dart';

Future<void> startForeground() async {
  // 注意：init() 回傳 void，不可 await
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'measure_channel',
      channelName: 'Measuring',
      channelDescription: '接收藍牙量測資料中',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true, // iOS 仍需填入選項
      playSound: false,
    ),
    foregroundTaskOptions: const ForegroundTaskOptions(
      interval: 15000,
      isOnceEvent: false,
      autoRunOnBoot: true,
    ),
  );

  // 這個可以 await：回傳 ServiceRequestResult
  final result = await FlutterForegroundTask.startService(
    notificationTitle: '量測進行中',
    notificationText: '背景接收藍牙資料…',
  );

  // 如需檢查是否啟動成功，可判斷 result
  // if (result == ServiceRequestResult.success) { ... }
}