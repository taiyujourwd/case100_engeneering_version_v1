import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:location/location.dart' as loc;
import '../models/ble_device.dart';

class BleService {
  final _ble = FlutterReactiveBle();

  // UUID 常數
  static final wrUuid = Uuid.parse("5a87b4ef-3bfa-76a8-e642-92933c31434f");
  static final rdFwUuid = Uuid.parse("6e6c31cc-3bd6-fe13-124d-9611451cd8f4");

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;

  final _deviceDataController = StreamController<BleDeviceData>.broadcast();
  Stream<BleDeviceData> get deviceDataStream => _deviceDataController.stream;

  final Set<String> _initializedDevices = {};
  final Map<String, bool> _timeWritten = {};
  bool _gattBusy = false;
  bool _isScanning = false;

  // 權限檢查
  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
      ].request();

      if (statuses.values.any((s) => !s.isGranted)) {
        debugPrint('❌ 藍牙權限未全數允許');
        return false;
      }

      // 確保 GPS 開啟
      try {
        final location = loc.Location();
        var perm = await location.hasPermission();
        if (perm == loc.PermissionStatus.denied) {
          perm = await location.requestPermission();
        }
        bool serviceEnabled = await location.serviceEnabled();
        if (!serviceEnabled) {
          serviceEnabled = await location.requestService();
        }
        if (!serviceEnabled) {
          debugPrint('⚠️ GPS 未開啟');
          return false;
        }
      } catch (e) {
        debugPrint('⚠️ GPS 檢查失敗：$e');
        return false;
      }
    }

    debugPrint('✅ 藍牙權限已授予');
    return true;
  }

  // 開始掃描
  Future<void> startScan({String? targetName}) async {
    if (_isScanning) return;

    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      debugPrint('❌ 無法啟動掃描：權限不足');
      return;
    }

    debugPrint('🔎 開始掃描裝置...');
    _isScanning = true;

    _scanSub = _ble
        .scanForDevices(withServices: [], scanMode: ScanMode.lowLatency)
        .listen((device) async {
      // 名稱過濾
      if (targetName != null && targetName.isNotEmpty) {
        if (device.name != targetName) return;
      }

      debugPrint('📡 發現裝置：${device.name} (${device.id})');

      // 解析並發送數據
      final parsedData = _parseManufacturerData(device);
      if (parsedData != null) {
        _deviceDataController.add(parsedData);
      }

      // 自動初始化
      if (!_initializedDevices.contains(device.id)) {
        await _initializeDevice(device.id);
      }
    }, onError: (e) {
      debugPrint('❌ 掃描錯誤：$e');
      _isScanning = false;
    });
  }

  // 停止掃描
  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    _isScanning = false;
    debugPrint('⏹️ 已停止掃描');
  }

  // 初始化裝置（寫時間）
  Future<void> _initializeDevice(String deviceId) async {
    debugPrint('🔗 初始化裝置：$deviceId');
    _initializedDevices.add(deviceId);

    await stopScan();

    final completer = Completer<void>();

    _connSub = _ble
        .connectToDevice(
      id: deviceId,
      connectionTimeout: const Duration(seconds: 15),
    )
        .listen((update) async {
      debugPrint('🔄 連線狀態：${update.connectionState}');

      if (update.connectionState == DeviceConnectionState.connected) {
        try {
          await _withGattLock(() async {
            // 升級連線優先權
            try {
              await _ble.requestConnectionPriority(
                deviceId: deviceId,
                priority: ConnectionPriority.highPerformance,
              );
              await Future.delayed(const Duration(milliseconds: 200));
            } catch (e) {
              debugPrint('⚠️ 升級連線優先權失敗：$e');
            }

            // 發現服務
            final chars = await _findCharacteristics(deviceId);
            if (chars == null) {
              debugPrint('❌ 找不到必要特徵');
              return;
            }

            await Future.delayed(const Duration(milliseconds: 120));

            // 寫入時間
            final success = await _writeDeviceTime(deviceId, chars.wr);
            _timeWritten[deviceId] = success;
            debugPrint(success ? '✅ 時間寫入成功' : '❌ 時間寫入失敗');

            await Future.delayed(const Duration(milliseconds: 150));

            // 讀取韌體版本（預熱）
            try {
              final fw = await _readFirmwareVersion(deviceId, chars.rdFw);
              if (fw != null) {
                debugPrint('📦 韌體版本：$fw');
              }
            } catch (e) {
              debugPrint('📦 讀取版本失敗：$e');
            }
          });
        } catch (e) {
          debugPrint('❌ 初始化失敗：$e');
        } finally {
          await Future.delayed(const Duration(milliseconds: 300));
          await _connSub?.cancel();
          debugPrint('🔌 已斷線');
          if (!completer.isCompleted) completer.complete();

          // 重新開始掃描
          await Future.delayed(const Duration(milliseconds: 500));
          if (!_isScanning) {
            await startScan();
          }
        }
      } else if (update.connectionState == DeviceConnectionState.disconnected) {
        if (!completer.isCompleted) completer.complete();
      }
    }, onError: (e) {
      debugPrint('❌ 連線錯誤：$e');
      if (!completer.isCompleted) completer.complete();
    });

    await completer.future;
  }

  // GATT 互斥鎖
  Future<T> _withGattLock<T>(Future<T> Function() body) async {
    while (_gattBusy) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    _gattBusy = true;
    try {
      return await body();
    } finally {
      _gattBusy = false;
    }
  }

  // 尋找特徵
  Future<({QualifiedCharacteristic wr, QualifiedCharacteristic rdFw})?>
  _findCharacteristics(String deviceId) async {
    final services = await _ble.discoverServices(deviceId);
    QualifiedCharacteristic? wr, rdFw;

    for (final s in services) {
      for (final c in s.characteristics) {
        if (c.characteristicId == wrUuid) {
          wr = QualifiedCharacteristic(
            deviceId: deviceId,
            serviceId: s.serviceId,
            characteristicId: c.characteristicId,
          );
        } else if (c.characteristicId == rdFwUuid) {
          rdFw = QualifiedCharacteristic(
            deviceId: deviceId,
            serviceId: s.serviceId,
            characteristicId: c.characteristicId,
          );
        }
      }
    }

    if (wr == null || rdFw == null) return null;
    return (wr: wr, rdFw: rdFw);
  }

  // 寫入時間
  Future<bool> _writeDeviceTime(
      String deviceId, QualifiedCharacteristic wr) async {
    final nowUtc = DateTime.now().toUtc();
    final epoch = nowUtc.millisecondsSinceEpoch ~/ 1000;
    final t4 = [
      (epoch >> 24) & 0xFF,
      (epoch >> 16) & 0xFF,
      (epoch >> 8) & 0xFF,
      epoch & 0xFF,
    ];

    final payload = Uint8List.fromList(<int>[
      0x01,
      0x03, 0xE8, // quietMs = 1000
      0x00, 0x64, // sampleMs = 100
      0x00, 0x01, // runCount = 1
      0x03, 0x84, // initEmV = 900
      ...t4,
    ]);

    int attempts = 0;
    const maxAttempts = 3;

    while (attempts < maxAttempts) {
      attempts++;
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await _ble.writeCharacteristicWithoutResponse(wr, value: payload);
        debugPrint('🕒 時間寫入成功 #$attempts');
        return true;
      } catch (e) {
        debugPrint('❌ 寫入失敗 #$attempts：$e');
        if (attempts >= maxAttempts) return false;
        await Future.delayed(Duration(milliseconds: 150 * attempts));
      }
    }
    return false;
  }

  // 讀取韌體版本
  Future<String?> _readFirmwareVersion(
      String deviceId, QualifiedCharacteristic rd) async {
    try {
      final data = await _ble.readCharacteristic(rd);
      if (data.isEmpty) return null;
      return String.fromCharCodes(data);
    } catch (e) {
      debugPrint('❌ 讀版本失敗：$e');
      return null;
    }
  }

  // 解析廣播數據
  BleDeviceData? _parseManufacturerData(DiscoveredDevice device) {
    final mfr = device.manufacturerData;
    if (mfr.isEmpty) return null;

    // 解析時間
    DateTime? timestamp;
    final timeData = _guessEpoch(mfr);
    if (timeData != null) {
      timestamp = timeData.time;
    }

    // 解析電壓
    double? voltage;
    final voltCandidates = _findVoltageCandidates(mfr);
    if (voltCandidates.isNotEmpty) {
      voltage = voltCandidates.first.v;
    }

    // 解析溫度
    double? temperature;
    final tempCandidates = _findTempCandidates(mfr);
    if (tempCandidates.isNotEmpty) {
      temperature = tempCandidates.first.c;
    }

    // 解析電流
    final currentCandidates = _findCurrentCandidates(mfr);
    final currents = currentCandidates.map((e) => e.mA).toList();

    return BleDeviceData(
      id: device.id,
      name: device.name,
      rssi: device.rssi,
      timestamp: timestamp,
      voltage: voltage,
      temperature: temperature,
      currents: currents,
      rawData: mfr,
    );
  }

  // 時間解析
  ({int off, bool be, DateTime time})? _guessEpoch(List<int> m) {
    if (m.length < 4) return null;
    final now = DateTime.now();
    Duration bestDelta = const Duration(days: 100000);
    ({int off, bool be, DateTime time})? best;

    for (int off = 0; off <= m.length - 4; off++) {
      for (final be in [true, false]) {
        final v = _u32(m, off, be: be);
        if (v <= 0) continue;
        final t = _toTimeSafe(v);
        if (t == null) continue;
        final d = (t.difference(now)).abs();
        if (d < bestDelta) {
          bestDelta = d;
          best = (off: off, be: be, time: t);
        }
      }
    }
    return best;
  }

  int _u32(List<int> m, int off, {required bool be}) {
    if (off + 3 >= m.length) return -1;
    return be
        ? ((m[off] << 24) | (m[off + 1] << 16) | (m[off + 2] << 8) | m[off + 3])
        : ((m[off + 3] << 24) | (m[off + 2] << 16) | (m[off + 1] << 8) | m[off]);
  }

  DateTime? _toTimeSafe(int epochSec) {
    try {
      final t = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: true).toLocal();
      if (t.isBefore(DateTime(2015, 1, 1)) || t.isAfter(DateTime(2035, 12, 31))) {
        return null;
      }
      return t;
    } catch (_) {
      return null;
    }
  }

  // 電壓候選
  List<({int hi, int lo, double v})> _findVoltageCandidates(List<int> m) {
    final out = <({int hi, int lo, double v})>[];
    for (int i = 0; i < m.length - 1; i++) {
      final raw = _u16(m, i, be: true);
      if (raw < 0) continue;
      final v = raw / 1000.0;
      if (v >= 2.5 && v <= 4.5) out.add((hi: i, lo: i + 1, v: v));
    }
    return out.take(5).toList();
  }

  // 溫度候選
  List<({int hi, int lo, double c})> _findTempCandidates(List<int> m) {
    final out = <({int hi, int lo, double c})>[];
    for (int i = 0; i < m.length - 1; i++) {
      final raw = _u16(m, i, be: true);
      if (raw < 0) continue;
      final c = raw / 100.0;
      if (c >= -40 && c <= 125) out.add((hi: i, lo: i + 1, c: c));
    }
    return out.take(5).toList();
  }

  // 電流候選
  List<({int hi, int lo, double mA})> _findCurrentCandidates(List<int> m) {
    final out = <({int hi, int lo, double mA})>[];
    for (int i = 0; i < m.length - 1; i++) {
      final raw = _u16(m, i, be: true);
      if (raw <= 0) continue;
      final mA = raw / 10.0;
      if (mA >= 0 && mA <= 20000) out.add((hi: i, lo: i + 1, mA: mA));
    }
    return out.take(10).toList();
  }

  int _u16(List<int> m, int off, {required bool be}) {
    if (off + 1 >= m.length) return -1;
    return be ? ((m[off] << 8) | m[off + 1]) : ((m[off + 1] << 8) | m[off]);
  }

  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _deviceDataController.close();
  }
}