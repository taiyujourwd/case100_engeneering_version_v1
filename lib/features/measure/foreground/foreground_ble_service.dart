import 'dart:async';
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
    if (now.difference(_lastNotify).inSeconds < 10) return; // 節流 10 秒
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

  // ✅ 初始化前景任務配置（優化長期運行）
  static Future<void> init() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ble_foreground_channel',
        channelName: '藍牙連線服務',
        channelDescription: '持續監聽藍牙設備數據',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // ✅ 減少心跳間隔，保持服務活躍
        eventAction: ForegroundTaskEventAction.repeat(3000), // 3秒一次
        autoRunOnBoot: true,  // ✅ 開機自動啟動
        autoRunOnMyPackageReplaced: true,  // ✅ 更新後自動啟動
        allowWakeLock: true,  // ✅ 允許喚醒鎖
        allowWifiLock: true,  // ✅ 允許 WiFi 鎖
      ),
    );

    debugPrint('✅ ForegroundTask 初始化完成（長期運行模式）');
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

  // 保存連線模式
  static Future<void> saveConnectionMode(BleConnectionMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_connectionModeKey, mode.index);
  }

  // 讀取連線模式
  static Future<BleConnectionMode> getConnectionMode() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_connectionModeKey) ?? 0;
    return BleConnectionMode.values[index];
  }

  // ✅ 啟動前景服務（增加檢查和重試）
  static Future<bool> start({
    String? targetDeviceId,
    String? targetDeviceName,
    BleConnectionMode? mode,
  }) async {
    // 保存設備資訊
    if (targetDeviceId != null || targetDeviceName != null) {
      await saveTargetDevice(
        deviceId: targetDeviceId,
        deviceName: targetDeviceName,
      );
    }

    if (mode != null) {
      await saveConnectionMode(mode);
    }

    // ✅ 如果服務已在運行，先停止
    final isRunning = await FlutterForegroundTask.isRunningService;
    if (isRunning) {
      debugPrint('⚠️ 服務已在運行，先停止');
      await FlutterForegroundTask.stopService();
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // ✅ 清除終止標記
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('service_terminated', false);

    // 啟動服務
    final modeText = mode == BleConnectionMode.broadcast ? '廣播' : '連線';
    final result = await FlutterForegroundTask.startService(
      serviceId: 256,  // ✅ 指定固定 ID
      notificationTitle: '藍牙服務運行中（$modeText 模式）',
      notificationText: '正在監聽設備：${targetDeviceName ?? "未指定"}',
      notificationButtons: [
        const NotificationButton(id: 'stop', text: '停止服務'),
      ],
      callback: startCallback,
    );

    final success = result != null;
    debugPrint('🚀 [Service] 啟動${success ? "成功" : "失敗"}');

    return success;
  }

  // 停止前景服務
  static Future<bool> stopSafely() async {
    debugPrint('🛑 準備停止前景服務...');

    // 1) 通知主線程進入停止期，阻擋後續 update
    FgGuards.stopping = true;

    // 2) 請背景任務先收斂（停止掃描/連線/寫入等）
    try {
      FlutterForegroundTask.sendDataToTask({'type': 'prepareStop'});
      await Future.delayed(const Duration(milliseconds: 300)); // 等待處理
    } catch (e) {
      debugPrint('⚠️ 發送 prepareStop 失敗: $e');
    }

    // 3) 確認服務在跑，再停止
    final running = await FlutterForegroundTask.isRunningService;
    if (running) {
      final result = await FlutterForegroundTask.stopService();

      // ✅ 重置停止標記
      await Future.delayed(const Duration(milliseconds: 300));
      FgGuards.stopping = false;

      debugPrint('✅ 前景服務已停止');
      return result != null;
    }

    FgGuards.stopping = false;
    debugPrint('ℹ️ 服務本來就沒有運行');
    return true;
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

  // ✅ 接收來自前景服務的數據（使用正確的 API）
  static void receivePort(Function(dynamic) callback) {
    FlutterForegroundTask.addTaskDataCallback((data) {
      callback(data);
    });
  }

  // ✅ 移除數據回調
  static void removeReceivePort(Function(dynamic) callback) {
    FlutterForegroundTask.removeTaskDataCallback(callback);
  }
}

// 前景任務回調入口點
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(BleTaskHandler());
}