import 'dart:async';
import 'dart:io';  // ✅ 加入
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ble/ble_service.dart';
import '../ble/ble_connection_mode.dart';
import '../models/ble_device.dart';
import 'ble_task_handler.dart';

class FgGuards {
  static bool stopping = false;
  static DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> safeUpdate(String title, String text) async {
    if (stopping) return;
    final running = await FlutterForegroundTask.isRunningService;
    if (!running) return;

    final now = DateTime.now();
    if (now.difference(_lastNotify).inSeconds < 10) return;
    _lastNotify = now;

    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }
}

class ForegroundBleService {
  static const String _targetDeviceIdKey = 'target_device_id';
  static const String _targetDeviceNameKey = 'target_device_name';
  static const String _connectionModeKey = 'ble_connection_mode';

  static Future<void> init() async {
    // ✅ Android 才初始化 Foreground Task
    if (Platform.isAndroid) {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'ble_foreground_channel',
          channelName: '藍牙連線服務',
          channelDescription: '持續監聽藍牙設備數據',
          channelImportance: NotificationChannelImportance.HIGH,
          priority: NotificationPriority.HIGH,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,  // iOS 不顯示通知
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(3000),
          autoRunOnBoot: true,
          autoRunOnMyPackageReplaced: true,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );

      debugPrint('✅ [Android] ForegroundTask 初始化完成');
    } else {
      debugPrint('ℹ️ [iOS] 跳過 ForegroundTask 初始化');
    }
  }

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

  static Future<void> saveConnectionMode(BleConnectionMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_connectionModeKey, mode.index);
  }

  static Future<BleConnectionMode> getConnectionMode() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_connectionModeKey) ?? 0;
    return BleConnectionMode.values[index];
  }

  static Future<bool> start({
    String? targetDeviceId,
    String? targetDeviceName,
    BleConnectionMode? mode,
  }) async {
    if (targetDeviceId != null || targetDeviceName != null) {
      await saveTargetDevice(
        deviceId: targetDeviceId,
        deviceName: targetDeviceName,
      );
    }

    if (mode != null) {
      await saveConnectionMode(mode);
    }

    // ✅ Android：使用前景服務
    if (Platform.isAndroid) {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (isRunning) {
        debugPrint('⚠️ [Android] 服務已在運行，先停止');
        await FlutterForegroundTask.stopService();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('service_terminated', false);

      final modeText = mode == BleConnectionMode.broadcast ? '廣播' : '連線';
      final result = await FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: '藍牙服務運行中（$modeText 模式）',
        notificationText: '正在監聽設備：${targetDeviceName ?? "未指定"}',
        notificationButtons: [
          const NotificationButton(id: 'stop', text: '停止服務'),
        ],
        callback: startCallback,
      );

      final success = result != null;
      debugPrint('🚀 [Android] 前景服務啟動${success ? "成功" : "失敗"}');
      return success;
    }

    // ✅ iOS：返回 true（由主線程處理）
    debugPrint('ℹ️ [iOS] 由主線程處理 BLE');
    return true;
  }

  static Future<bool> stopSafely() async {
    debugPrint('🛑 準備停止服務...');

    FgGuards.stopping = true;

    // ✅ Android：停止前景服務
    if (Platform.isAndroid) {
      try {
        FlutterForegroundTask.sendDataToTask({'type': 'prepareStop'});
        await Future.delayed(const Duration(milliseconds: 300));
      } catch (e) {
        debugPrint('⚠️ [Android] 發送 prepareStop 失敗: $e');
      }

      final running = await FlutterForegroundTask.isRunningService;
      if (running) {
        final result = await FlutterForegroundTask.stopService();
        await Future.delayed(const Duration(milliseconds: 300));
        FgGuards.stopping = false;
        debugPrint('✅ [Android] 前景服務已停止');
        return result != null;
      }
    }

    FgGuards.stopping = false;
    debugPrint('ℹ️ 服務本來就沒有運行');
    return true;
  }

  static Future<bool> isRunning() async {
    if (Platform.isAndroid) {
      return await FlutterForegroundTask.isRunningService;
    }
    return false;
  }

  static void updateNotification({
    required String title,
    required String text,
  }) {
    if (Platform.isAndroid) {
      FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
      );
    }
  }

  static void sendData(dynamic data) {
    if (Platform.isAndroid) {
      FlutterForegroundTask.sendDataToTask(data);
    }
  }

  static void receivePort(Function(dynamic) callback) {
    if (Platform.isAndroid) {
      FlutterForegroundTask.addTaskDataCallback((data) {
        callback(data);
      });
    }
  }

  static void removeReceivePort(Function(dynamic) callback) {
    if (Platform.isAndroid) {
      FlutterForegroundTask.removeTaskDataCallback(callback);
    }
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(BleTaskHandler());
}