import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ble/ble_service.dart';
import '../models/ble_device.dart';
import 'ble_task_handler.dart';

class ForegroundBleService {
  static const String _portName = 'ble_foreground_service_port';
  static const String _targetDeviceIdKey = 'target_device_id';
  static const String _targetDeviceNameKey = 'target_device_name';

  // 初始化前景任務配置
  static Future<void> init() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ble_foreground_channel',
        channelName: '藍牙連線服務',
        channelDescription: '持續監聽藍牙設備數據',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000), // 每5秒執行一次
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  // 保存目標設備資訊
  static Future<void> saveTargetDevice({
    String? deviceId,
    String? deviceName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (deviceId != null) {
      await prefs.setString(_targetDeviceIdKey, deviceId);
    }
    if (deviceName != null) {
      await prefs.setString(_targetDeviceNameKey, deviceName);
    }
  }

  // 啟動前景服務
  static Future<bool> start({
    String? targetDeviceId,
    String? targetDeviceName,
  }) async {
    // 保存目標設備資訊
    if (targetDeviceId != null || targetDeviceName != null) {
      await saveTargetDevice(
        deviceId: targetDeviceId,
        deviceName: targetDeviceName,
      );
    }

    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: '藍牙服務運行中',
      notificationText: '正在監聽設備數據...',
      notificationButtons: [
        const NotificationButton(id: 'stop', text: '停止服務'),
      ],
      callback: startCallback,
    );

    return result != null;
  }

  // 停止前景服務
  static Future<bool> stop() async {
    final result = await FlutterForegroundTask.stopService();
    return result != null;
  }

  // 檢查服務是否運行
  static Future<bool> isRunning() async {
    return await FlutterForegroundTask.isRunningService;
  }

  // 更新通知
  static void updateNotification({
    required String title,
    required String text,
  }) {
    FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  // 發送數據到前景服務
  static void sendData(dynamic data) {
    FlutterForegroundTask.sendDataToTask(data);
  }

  // 接收來自前景服務的數據
  static void receivePort(Function(dynamic) callback) {
    // 使用 FlutterForegroundTask 的數據接收方法
    FlutterForegroundTask.addTaskDataCallback((data) {
      callback(data);
    });
  }
}

// 前景任務回調入口點
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(BleTaskHandler());
}
