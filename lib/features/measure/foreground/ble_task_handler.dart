import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_foreground_task/task_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ble/ble_service.dart';
import '../models/ble_device.dart';

class BleTaskHandler extends TaskHandler {
  BleService? _bleService;
  StreamSubscription<BleDeviceData>? _dataSubscription;
  StreamSubscription<String>? _versionSubscription;

  int _dataCount = 0;
  DateTime? _lastDataTime;
  String? _deviceVersion;
  String? _targetDeviceId;
  String? _targetDeviceName;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('🚀 前景服務已啟動');

    try {
      // 讀取目標設備資訊
      final prefs = await SharedPreferences.getInstance();
      _targetDeviceId = prefs.getString('target_device_id');
      _targetDeviceName = prefs.getString('target_device_name');

      debugPrint('🎯 目標設備: ID=$_targetDeviceId, Name=$_targetDeviceName');

      // 初始化 BLE 服務
      _bleService = BleService();

      // 監聽設備數據流
      _dataSubscription = _bleService!.deviceDataStream.listen((data) {
        _onDeviceData(data);
      }, onError: (error) {
        debugPrint('❌ 數據流錯誤: $error');
      });

      // 監聽版本號流
      _versionSubscription = _bleService!.deviceVersionStream.listen((version) {
        _deviceVersion = version;
        debugPrint('📦 設備版本: $version');

        // 發送版本號到 UI
        FlutterForegroundTask.sendDataToMain({
          'type': 'version',
          'version': version,
        });
      });

      // 請求權限並開始掃描
      final hasPermission = await _bleService!.requestPermissions();
      if (hasPermission) {
        await _startScanning();
      } else {
        debugPrint('❌ 藍牙權限不足');
      }

    } catch (e) {
      debugPrint('❌ 服務啟動失敗: $e');
    }
  }

  // 開始掃描
  Future<void> _startScanning() async {
    try {
      await _bleService?.startScan(
        targetName: _targetDeviceName,
        targetId: _targetDeviceId,
      );
      debugPrint('🔍 開始掃描設備');
    } catch (e) {
      debugPrint('❌ 掃描失敗: $e');
    }
  }

  // 處理接收到的設備數據
  void _onDeviceData(BleDeviceData data) {
    _dataCount++;
    _lastDataTime = DateTime.now();

    debugPrint('📊 收到數據 #$_dataCount: ${data.name} (${data.id})');
    if (data.voltage != null) debugPrint('   電壓: ${data.voltage}V');
    if (data.temperature != null) debugPrint('   溫度: ${data.temperature}°C');
    if (data.currents.isNotEmpty) debugPrint('   電流: ${data.currents.first}A');

    // 更新通知
    final notificationText = _buildNotificationText(data);
    FlutterForegroundTask.updateService(
      notificationTitle: '藍牙服務運行中',
      notificationText: notificationText,
    );

    // 發送數據到 UI
    FlutterForegroundTask.sendDataToMain({
      'type': 'data',
      'deviceId': data.id,
      'deviceName': data.name,
      'rssi': data.rssi,
      'timestamp': data.timestamp?.toIso8601String(),
      'voltage': data.voltage,
      'temperature': data.temperature,
      'currents': data.currents,
      'dataCount': _dataCount,
    });
  }

  // 構建通知文字
  String _buildNotificationText(BleDeviceData data) {
    final parts = <String>[];

    parts.add('設備: ${data.name.isNotEmpty ? data.name : data.id.substring(0, 8)}');

    if (data.voltage != null) {
      parts.add('${data.voltage!.toStringAsFixed(3)}V');
    }
    if (data.temperature != null) {
      parts.add('${data.temperature!.toStringAsFixed(1)}°C');
    }
    if (data.currents.isNotEmpty) {
      final current = data.currents.first;
      parts.add('${(current * 1000000).toStringAsFixed(2)}µA');
    }

    parts.add('已接收: $_dataCount 筆');

    return parts.join(' | ');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // 定期執行的任務
    final now = DateTime.now();

    // 檢查是否長時間沒有收到數據（超過30秒）
    if (_lastDataTime != null) {
      final timeSinceLastData = now.difference(_lastDataTime!);
      if (timeSinceLastData.inSeconds > 30) {
        debugPrint('⚠️ 長時間未收到數據，嘗試重新掃描...');
        _restartScanning();
      }
    }

    // 發送心跳
    FlutterForegroundTask.sendDataToMain({
      'type': 'heartbeat',
      'timestamp': now.toIso8601String(),
      'dataCount': _dataCount,
    });
  }

  // 重新掃描
  Future<void> _restartScanning() async {
    try {
      await _bleService?.stopScan();
      await Future.delayed(const Duration(seconds: 1));
      await _startScanning();
    } catch (e) {
      debugPrint('❌ 重新掃描失敗: $e');
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('🛑 前景服務停止中...');

    await _dataSubscription?.cancel();
    await _versionSubscription?.cancel();
    await _bleService?.stopScan();
    _bleService?.dispose();

    debugPrint('✅ 前景服務已停止，共接收 $_dataCount 筆數據');
  }

  @override
  void onNotificationButtonPressed(String id) {
    debugPrint('🔘 通知按鈕被按下: $id');

    if (id == 'stop') {
      FlutterForegroundTask.stopService();
    }
  }

  @override
  void onNotificationPressed() {
    debugPrint('📱 通知被點擊，啟動應用');
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onNotificationDismissed() {
    debugPrint('🗑️ 通知被關閉');
  }
}