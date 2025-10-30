import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ble/ble_service.dart';
import '../ble/ble_connection_mode.dart';
import '../models/ble_device.dart';
import '../data/measure_repository.dart';
import '../ble/reactive_ble_client.dart';

class BleTaskHandler extends TaskHandler {
  BleService? _bleService;
  StreamSubscription<BleDeviceData>? _dataSubscription;
  StreamSubscription<String>? _versionSubscription;
  MeasureRepository? _repo;

  int _dataCount = 0;
  DateTime? _lastDataTime;
  DateTime _lastHeartbeat = DateTime.now();  // ✅ 記錄最後心跳
  String? _deviceVersion;
  String? _targetDeviceId;
  String? _targetDeviceName;
  BleConnectionMode _connectionMode = BleConnectionMode.broadcast;

  final _recentTimestamps = <String, DateTime>{};
  static const _cacheExpireDuration = Duration(seconds: 10);  // ✅ 增加到 10 秒
  static const _maxCacheSize = 200;  // ✅ 增加緩存大小

  IOSink? _bleLogSink;

  // 初始化（例如在 initState 或服務啟動時呼叫一次）
  Future<void> _initBleLogSink() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/ble_data_log.txt');
    // 若檔案不存在自動建立；使用 append 模式
    _bleLogSink = file.openWrite(mode: FileMode.append);
  }

// 安全釋放（例如在 dispose 或服務結束時）
  Future<void> _closeBleLogSink() async {
    await _bleLogSink?.flush();
    await _bleLogSink?.close();
    _bleLogSink = null;
  }

// 非阻塞寫入：不要 await、不要每筆 open/close
  void _enqueueLog(BleDeviceData data) {
    try {
      final line = jsonEncode({
        'id': data.id,
        'name': data.name,
        'rssi': data.rssi,
        'timestamp': data.timestamp?.toIso8601String(),
        'voltage': data.voltage,
        'temperature': data.temperature,
        'currents': data.currents,
        'rawData': data.rawData,
      });
      _bleLogSink?.writeln(line); // non-blocking buffer
    } catch (e) {
      debugPrint('❌ [FG] 寫檔序列化失敗: $e');
    }
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('🚀 前景服務已啟動');

    _initBleLogSink();

    try {
      // 初始化 Repository
      final bleClient = ReactiveBleClient();
      _repo = await MeasureRepository.create(bleClient);
      debugPrint('✅ 前景服務 Repository 初始化成功');

      // 讀取設備資訊和連線模式
      final prefs = await SharedPreferences.getInstance();
      _targetDeviceId = prefs.getString('target_device_id');
      _targetDeviceName = prefs.getString('target_device_name');
      final modeIndex = prefs.getInt('ble_connection_mode') ?? 0;
      _connectionMode = BleConnectionMode.values[modeIndex];

      debugPrint('🎯 目標設備: ID=$_targetDeviceId, Name=$_targetDeviceName');
      debugPrint('📡 連線模式: ${_connectionMode == BleConnectionMode.broadcast ? "廣播" : "連線"}');

      // 初始化 BLE 服務
      _bleService = BleService();
      _bleService!.setConnectionMode(_connectionMode);

      // 監聽設備數據流
      _dataSubscription = _bleService!.deviceDataStream.listen((data) {
        _onDeviceData(data);
      }, onError: (error) {
        debugPrint('❌ 數據流錯誤: $error');
      });

      // 監聽版本號流
      _versionSubscription = _bleService!.deviceVersionStream.listen((version) {
        _deviceVersion = version;
        debugPrint('📦 [FG] 設備版本: $version');

        // ✅ 發送版本號到主線程
        FlutterForegroundTask.sendDataToMain({
          'type': 'version',
          'version': version,
        });
        debugPrint('✅ [FG] 已發送版本號到主線程: $version');
      });

      // 根據模式啟動不同的連線方式
      if (_connectionMode == BleConnectionMode.broadcast) {
        await _startBroadcastMode();
      } else {
        await _startConnectionMode();
      }

    } catch (e) {
      debugPrint('❌ 服務啟動失敗: $e');
    }
  }

  // 啟動廣播模式
  Future<void> _startBroadcastMode() async {
    try {
      await _bleService?.startScan(
        targetName: _targetDeviceName,
        targetId: _targetDeviceId,
        skipPermissionCheck: true,
      );
      debugPrint('🔍 廣播模式：開始掃描設備');
    } catch (e) {
      debugPrint('❌ 廣播模式啟動失敗: $e');
    }
  }

  // 啟動連線模式
  Future<void> _startConnectionMode() async {
    print('test123 _startConnectionMode');
    try {
      if (_targetDeviceId == null || _targetDeviceId!.isEmpty) {
        final d = await _bleService!.scanFirstHit(
          targetName: _targetDeviceName,
          serviceUuids: /* 你保存的硬體過濾 */ null,
          timeout: const Duration(seconds: 10),
        );
        if (d != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('target_device_id', d.id);
          _targetDeviceId = d.id;
          _targetDeviceName ??= d.name;
        } else {
          debugPrint('⚠️ 找不到目標裝置，放棄連線模式啟動');
          return;
        }
      }

      print('test123 _targetDeviceId: $_targetDeviceId');

      await _bleService!.startConnectionMode(
        deviceId: _targetDeviceId!,
        deviceName: _targetDeviceName,
      );
    } catch (e) {
      debugPrint('❌ 連線模式啟動失敗: $e');
    }
  }

  // 生成去重鍵
  String _makeDeduplicationKey(String deviceId, DateTime timestamp) {
    return '$deviceId-${timestamp.year}-${timestamp.month}-${timestamp.day}-'
        '${timestamp.hour}-${timestamp.minute}-${timestamp.second}';
  }

  // 檢查是否為重複數據
  bool _isDuplicateData(String deviceId, DateTime timestamp) {
    final key = _makeDeduplicationKey(deviceId, timestamp);
    final now = DateTime.now();

    // 清理過期的緩存
    _recentTimestamps.removeWhere((k, v) {
      return now.difference(v) > _cacheExpireDuration;
    });

    // 限制緩存大小
    while (_recentTimestamps.length >= _maxCacheSize) {
      final oldestKey = _recentTimestamps.keys.first;
      _recentTimestamps.remove(oldestKey);
    }

    // 檢查是否已存在
    if (_recentTimestamps.containsKey(key)) {
      return true;
    }

    // 記錄新的時間戳
    _recentTimestamps[key] = now;
    return false;
  }

  Future<void> _saveDataToFile(BleDeviceData data) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/ble_data_log.txt');

      // 每筆資料用一行 JSON
      await file.writeAsString('${data.toJsonString()}\n', mode: FileMode.append);

      debugPrint('📂 [FG] 已寫入檔案: ${file.path}');
    } catch (e) {
      debugPrint('❌ [FG] 寫檔失敗: $e');
    }
  }

  // 處理接收到的設備數據
  void _onDeviceData(BleDeviceData data) async {
    try {
      _dataCount++;
      _lastDataTime = DateTime.now();

      // ⚠️ 千萬不要在這裡 await 寫檔
      _enqueueLog(data); // 非阻塞排入緩衝

      // 去重檢查（與既有邏輯相同）
      if (data.timestamp != null) {
        final deviceId = _targetDeviceName ?? data.id;
        if (_isDuplicateData(deviceId, data.timestamp!)) {
          _updateNotification(); // 保持原本行為
          return;
        }
      }

      debugPrint('📊 [FG] 收到新數據 #$_dataCount: ${data.name}'
          ' currentsLen=${data.currents.length} ts=${data.timestamp}');

      // ✅ 用「合理時間範圍」替代嚴格的年份等於判斷
      final ts = data.timestamp;
      final now = DateTime.now();
      final bool tsOk = ts != null &&
          ts.isAfter(now.subtract(const Duration(days: 1))) &&
          ts.isBefore(now.add(const Duration(days: 1)));

      if (_repo != null && tsOk && data.currents.isNotEmpty) {
        try {
          final sample = makeSampleFromBle(
            deviceId: _targetDeviceName ?? data.id,
            timestamp: ts!,               // tsOk 已保證非空
            currents: data.currents,
            voltage: data.voltage,
            temperature: data.temperature,
          );

          await _repo!.addSample(sample); // 這是圖表資料來源的關鍵
          debugPrint('💾 [FG] 已寫入資料庫');
        } catch (e, st) {
          debugPrint('❌ [FG] 寫入失敗：$e\n$st');
        }
      } else {
        if (_repo == null) debugPrint('⚠️ [FG] _repo 為 null，無法寫 DB');
        if (!tsOk) debugPrint('⚠️ [FG] timestamp 超出合理範圍：$ts');
        if (data.currents.isEmpty) debugPrint('⚠️ [FG] currents 為空');
      }

      // 放最後，避免阻塞前面主流程
      _updateNotification();
    } catch (e, st) {
      debugPrint('❌ [FG] _onDeviceData 未捕捉例外：$e\n$st');
    }
  }

  // ✅ 更新通知
  void _updateNotification() {
    final modeText = _connectionMode == BleConnectionMode.broadcast ? '廣播' : '連線';
    final statusText = _lastDataTime != null
        ? '最後數據: ${DateTime.now().difference(_lastDataTime!).inSeconds}秒前'
        : '等待數據...';

    FlutterForegroundTask.updateService(
      notificationTitle: '藍牙服務運行中（$modeText 模式）',
      notificationText: '已接收 $_dataCount 筆 | $statusText',
    );
  }

  // ✅ 定期執行的事件（心跳）
  @override
  void onRepeatEvent(DateTime timestamp) {
    final now = DateTime.now();
    _lastHeartbeat = now;

    // ✅ 發送心跳，保持服務活躍
    FlutterForegroundTask.sendDataToMain({
      'type': 'heartbeat',
      'timestamp': now.toIso8601String(),
      'dataCount': _dataCount,
      'isAlive': true,
    });

    debugPrint('💓 [FG] 心跳: $_dataCount 筆數據');

    // 檢查數據接收情況（廣播模式）
    if (_connectionMode == BleConnectionMode.broadcast && _lastDataTime != null) {
      final timeSinceLastData = now.difference(_lastDataTime!);
      if (timeSinceLastData.inSeconds > 30) {
        debugPrint('⚠️ [FG] 長時間未收到數據，嘗試重新掃描...');
        _restartBroadcastMode();
      }
    }

    // 定期更新通知
    _updateNotification();
  }

  // 重新啟動廣播模式
  Future<void> _restartBroadcastMode() async {
    try {
      await _bleService?.stopScan();
      await Future.delayed(const Duration(seconds: 1));
      await _bleService?.startScan(
        targetName: _targetDeviceName,
        targetId: _targetDeviceId,
        skipPermissionCheck: true,
      );
      debugPrint('🔄 [FG] 已重新啟動掃描');
    } catch (e) {
      debugPrint('❌ [FG] 重新掃描失敗: $e');
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTerminated) async {
    debugPrint('🛑 [FG] 前景服務停止中... (isTerminated=$isTerminated)');

    // ✅ 如果是被系統終止，記錄狀態
    if (isTerminated) {
      debugPrint('⚠️ [FG] 服務被系統終止');

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('service_terminated', true);
      await prefs.setString('last_terminate_time', DateTime.now().toIso8601String());
      await prefs.setInt('last_data_count', _dataCount);
    }

    await _dataSubscription?.cancel();
    await _versionSubscription?.cancel();

    if (_connectionMode == BleConnectionMode.broadcast) {
      await _bleService?.stopScan();
    } else {
      await _bleService?.stopConnectionMode();
    }

    _bleService?.dispose();
    _recentTimestamps.clear();

    debugPrint('✅ [FG] 前景服務已停止，共接收 $_dataCount 筆數據');
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') {
      debugPrint('🛑 [FG] 用戶按下停止按鈕');
      try {
        FlutterForegroundTask.sendDataToMain({'type': 'stopping'});
      } catch (_) {}
      FlutterForegroundTask.stopService();
    }
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onNotificationDismissed() {
    debugPrint('🗑️ [FG] 通知被關閉');
  }
}