import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:location/location.dart' as loc;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ble_device.dart';
import 'ble_connection_mode.dart';

/// -------- 時間位欄位規格 --------
/// [31..26] 年(相對2000, 6b)  → 2000..2063
/// [25..22] 月(4b)            → 1..12
/// [21..17] 日(5b)            → 1..31
/// [16..12] 時(5b)            → 0..23
/// [11..6 ] 分(6b)            → 0..59
/// [5 ..0 ] 秒(6b)            → 0..59

enum EndianType { big, little }

/// 根據實際韌體端序切換（先試 big，不對就換 little）
const EndianType kTimeEndian = EndianType.big;

/// ✅ 硬體過濾（Hardware-offloaded filtering）：請填你的 Service UUID
///    可填多個；越精準越省電、越不易被節流
class _BleFilters {
  static List<Uuid> kServiceFilter = <Uuid>[];     // ← 改成可變
  static Uuid? kNotifyCharUuid;                    // ← 新增：通知用 Char UUID

  static const _prefsServicesKey = 'ble_service_filters';
  static const _prefsNotifyCharKey = 'ble_notify_char';

  static Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_prefsServicesKey) ?? const [];
    kServiceFilter = list.map((s) => Uuid.parse(s)).toList();
    final n = prefs.getString(_prefsNotifyCharKey);
    kNotifyCharUuid = (n == null || n.isEmpty) ? null : Uuid.parse(n);
    debugPrint('📥 已載入 Service filters=${kServiceFilter.length}, notify=$kNotifyCharUuid');
  }

  static Future<void> saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefsServicesKey,
      kServiceFilter.map((u) => u.toString()).toList(),
    );
    await prefs.setString(_prefsNotifyCharKey, kNotifyCharUuid?.toString() ?? '');
    debugPrint('💾 已儲存 Service filters=${kServiceFilter.length}, notify=$kNotifyCharUuid');
  }
}

/// 小工具：把 bytes 轉十六進位字串，便於 debug
String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

class Time {
  int year, month, day, hour, minute, second;
  Time({
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
  });
  @override
  String toString() =>
      'Year:$year Month:$month Day:$day Hour:$hour Minute:$minute Second:$second';
}

/// ---- encode：DateTime/Time → 4 bytes (bit-field) ----
Uint8List encodeTimeBitfield4({
  required Time t,
  EndianType endian = kTimeEndian,
}) {
  final yearOff = t.year - 2000;
  if (yearOff < 0 || yearOff > 63) {
    throw ArgumentError('year must be 2000..2063 (got ${t.year})');
  }
  if (t.month < 1 || t.month > 12) throw ArgumentError('month 1..12');
  if (t.day < 1 || t.day > 31) throw ArgumentError('day 1..31');
  if (t.hour < 0 || t.hour > 23) throw ArgumentError('hour 0..23');
  if (t.minute < 0 || t.minute > 59) throw ArgumentError('minute 0..59');
  if (t.second < 0 || t.second > 59) throw ArgumentError('second 0..59');

  int v = 0;
  v |= (yearOff & 0x3F) << 26;
  v |= (t.month & 0x0F) << 22;
  v |= (t.day & 0x1F) << 17;
  v |= (t.hour & 0x1F) << 12;
  v |= (t.minute & 0x3F) << 6;
  v |= (t.second & 0x3F);

  final out = Uint8List(4);
  if (endian == EndianType.big) {
    out[0] = (v >> 24) & 0xFF;
    out[1] = (v >> 16) & 0xFF;
    out[2] = (v >> 8) & 0xFF;
    out[3] = v & 0xFF;
  } else {
    out[0] = v & 0xFF;
    out[1] = (v >> 8) & 0xFF;
    out[2] = (v >> 16) & 0xFF;
    out[3] = (v >> 24) & 0xFF;
  }
  return out;
}

/// ---- decode：4 bytes (bit-field) → DateTime ----
DateTime? decodeBitfieldTime4(
    List<int> bytes, {
      EndianType endian = kTimeEndian,
      bool asUtc = true,
    }) {
  if (bytes.length < 4) return null;

  final b0 = bytes[0] & 0xFF;
  final b1 = bytes[1] & 0xFF;
  final b2 = bytes[2] & 0xFF;
  final b3 = bytes[3] & 0xFF;

  final int v = (endian == EndianType.big)
      ? ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
      : ((b3 << 24) | (b2 << 16) | (b1 << 8) | b0);

  final yearOff = (v >> 26) & 0x3F;
  final month = (v >> 22) & 0x0F;
  final day = (v >> 17) & 0x1F;
  final hour = (v >> 12) & 0x1F;
  final minute = (v >> 6) & 0x3F;
  final second = v & 0x3F;

  final year = 2000 + yearOff;
  if (year < 2000 || year > 2063) return null;
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > 31) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;

  return asUtc
      ? DateTime.utc(year, month, day, hour, minute, second)
      : DateTime(year, month, day, hour, minute, second);
}

/// 在 manufacturerData 中滑窗找出「看起來像 bit-field 時間」的 4 bytes
({int offset, EndianType endian, DateTime time})? guessBitfieldTime(
    List<int> data, {
      bool asUtc = true,
    }) {
  if (data.length < 4) return null;
  final now = DateTime.now();

  Duration best = const Duration(days: 100000);
  ({int offset, EndianType endian, DateTime time})? ans;

  for (int i = 0; i <= data.length - 4; i++) {
    final slice = data.sublist(i, i + 4);
    for (final e in [EndianType.big, EndianType.little]) {
      final t = decodeBitfieldTime4(slice, endian: e, asUtc: false);
      if (t == null) continue;
      final diff = (t.difference(now)).abs();
      if (diff < best) {
        best = diff;
        ans = (offset: i, endian: e, time: t);
      }
    }
  }
  return ans;
}

class BleService {
  final _ble = FlutterReactiveBle();

  // 依你的韌體協議替換正確的 UUID
  static final wrUuid = Uuid.parse("5a87b4ef-3bfa-76a8-e642-92933c31434f");
  static final rdFwUuid = Uuid.parse("6e6c31cc-3bd6-fe13-124d-9611451cd8f4");

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;

  // ✅ 連線模式相關
  StreamSubscription<ConnectionStateUpdate>? _maintainConnection;
  StreamSubscription<List<int>>? _notifySubscription;
  String? _connectedDeviceId;
  String? _connectedDeviceName;
  BleConnectionMode _connectionMode = BleConnectionMode.broadcast;

  final _deviceDataController = StreamController<BleDeviceData>.broadcast();
  Stream<BleDeviceData> get deviceDataStream => _deviceDataController.stream;

  final _deviceVersionController = StreamController<String>.broadcast();
  Stream<String> get deviceVersionStream => _deviceVersionController.stream;

  final Set<String> _initializedDevices = {};
  final Map<String, bool> _timeWritten = {};
  bool _gattBusy = false;
  bool _isScanning = false;

  // ⏳ 掃描節流退避點（若系統回覆建議時間，會設定此值）
  DateTime? _nextAllowedScanAt;

  // ------- 連線模式控制 -------
  void setConnectionMode(BleConnectionMode mode) {
    _connectionMode = mode;
    debugPrint('📡 連線模式已設定為：${mode == BleConnectionMode.broadcast ? "廣播" : "連線"}');
  }

  BleConnectionMode get connectionMode => _connectionMode;
  String? get connectedDeviceId => _connectedDeviceId;
  bool get isConnected => _connectedDeviceId != null;

  // ------- 權限 -------
  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        // Android 12+ 掃描不一定需要定位，但很多機型仍要求開定位服務（非權限）
        Permission.location, // 你若完全不需要定位可移除，但請測機況
      ].request();

      if (statuses.values.any((s) => !s.isGranted)) {
        debugPrint('❌ 藍牙權限未全數允許');
        return false;
      }

      // 是否需要打開定位服務（很多機型掃描要開）
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
          debugPrint('⚠️ GPS 未開啟（部分機型會擋掃描）');
          // 不直接 return false，讓你可觀察不同機型行為
        }
      } catch (e) {
        debugPrint('⚠️ GPS 檢查失敗：$e');
      }
    }
    debugPrint('✅ 藍牙權限已授予（或已檢查完）');
    return true;
  }

  // ------- 廣播模式：掃描（含硬體過濾＋節流退避）-------
  Future<void> startScan({
    String? targetName,
    String? targetId,
    bool skipPermissionCheck = false,
    List<Uuid>? serviceUuids, // ← 可外部指定過濾
  }) async {
    if (_isScanning) return;

    // 確保有載入過偏好
    if (_BleFilters.kServiceFilter.isEmpty && _BleFilters.kNotifyCharUuid == null) {
      try { await _BleFilters.loadFromPrefs(); } catch (_) {}
    }

    // 若系統曾回傳「建議重試時間」，在時間未到前不重新掃描
    if (_nextAllowedScanAt != null && DateTime.now().isBefore(_nextAllowedScanAt!)) {
      final wait = _nextAllowedScanAt!.difference(DateTime.now()).inSeconds;
      debugPrint('⏳ 尚未到允許掃描時間（$wait s 後再試）');
      return;
    }

    await _scanSub?.cancel();
    _scanSub = null;

    if (!skipPermissionCheck) {
      final ok = await requestPermissions();
      if (!ok) {
        debugPrint('❌ ble_service 無法啟動掃描：權限不足');
        return;
      }
    }

    // ✅ 使用硬體過濾（服務 UUID）
    final filters = (serviceUuids != null && serviceUuids.isNotEmpty)
        ? serviceUuids
        : (_BleFilters.kServiceFilter.isNotEmpty
        ? _BleFilters.kServiceFilter
        : <Uuid>[]); // 第一次不知道就先空（之後會補上）

    if (filters.isEmpty) {
      debugPrint('⚠️ 未提供服務 UUID 過濾，將回退為「無硬體過濾」；背景時更易被節流');
    }

    debugPrint('🔎 開始掃描裝置（廣播模式），filters=${filters.map((e) => e.toString()).toList()}');
    _isScanning = true;

    _scanSub = _ble
        .scanForDevices(
      withServices: filters,               // ← 核心：硬體過濾
      scanMode: ScanMode.lowLatency,
      requireLocationServicesEnabled: false,      // 依需求；有的機型仍需開定位服務
    )
        .listen((device) async {
      if (targetId != null && targetId.isNotEmpty && device.id != targetId) {
        return;
      }
      if (targetName != null && targetName.isNotEmpty) {
        final n = (device.name).toLowerCase();
        final q = targetName.toLowerCase();
        if (!(n.contains(q) || n.startsWith(q))) return;
      }

      debugPrint('📡 發現裝置：${device.name} (${device.id}) RSSI=${device.rssi}');

      final parsed = _parseManufacturerData(device);
      if (parsed != null) _deviceDataController.add(parsed);

      if (!_initializedDevices.contains(device.id)) {
        await _initializeDevice(device.id);
      }
    }, onError: (e) async {
      debugPrint('❌ 掃描錯誤：$e');
      _isScanning = false;

      // ⏳ 解析「建議重試時間」，設定退避點
      final dt = _parseSuggestedRetryTime(e.toString());
      if (dt != null) {
        _nextAllowedScanAt = dt;
        final wait = dt.difference(DateTime.now());
        debugPrint('🧯 Scan throttle，暫停至 $_nextAllowedScanAt（約 ${wait.inSeconds}s）');
      } else {
        _nextAllowedScanAt = DateTime.now().add(const Duration(minutes: 3));
        debugPrint('🧯 Scan throttle（未提供時間），先退避 3 分鐘');
      }

      await Future.delayed(const Duration(milliseconds: 500));
      await restartScan(
        targetName: targetName,
        targetId: targetId,
        skipPermissionCheck: skipPermissionCheck,
        serviceUuids: filters,
      );
    }, onDone: () async {
      debugPrint('ℹ️ 掃描串流已結束');
      _isScanning = false;
      await Future.delayed(const Duration(milliseconds: 500));
      await restartScan(
        targetName: targetName,
        targetId: targetId,
        skipPermissionCheck: skipPermissionCheck,
        serviceUuids: filters,
      );
    });
  }

  Future<void> restartScan({
    String? targetName,
    String? targetId,
    bool skipPermissionCheck = false,
    List<Uuid>? serviceUuids,
  }) async {
    await _scanSub?.cancel();
    _scanSub = null;
    _isScanning = false;
    await Future.delayed(const Duration(milliseconds: 200));
    await startScan(
      targetName: targetName,
      targetId: targetId,
      skipPermissionCheck: skipPermissionCheck,
      serviceUuids: serviceUuids,
    );
  }

  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    _isScanning = false;
    debugPrint('⏹️ 已停止掃描');
  }

  // ------- ✅ 連線模式：持續連線並訂閱 -------
  Future<void> startConnectionMode({
    required String deviceId,
    String? deviceName,
  }) async {
    debugPrint('🔗 啟動連線模式：$deviceId');

    _connectedDeviceName = deviceName;

    await _maintainConnection?.cancel();
    await _notifySubscription?.cancel();

    _maintainConnection = _ble
        .connectToDevice(
      id: deviceId,
      connectionTimeout: const Duration(seconds: 30),
    )
        .listen(
          (update) async {
        debugPrint('🔄 連線狀態：${update.connectionState}');

        if (update.connectionState == DeviceConnectionState.connected) {
          _connectedDeviceId = deviceId;

          try {
            await _withGattLock(() async {
              try {
                await _ble.requestConnectionPriority(
                  deviceId: deviceId,
                  priority: ConnectionPriority.highPerformance,
                );
                await Future.delayed(const Duration(milliseconds: 200));
              } catch (e) {
                debugPrint('⚠️ 升級連線優先權失敗：$e');
              }

              final chars = await _findCharacteristics(deviceId);
              if (chars == null) {
                debugPrint('❌ 找不到必要特徵');
                return;
              }

              await Future.delayed(const Duration(milliseconds: 120));

              final ok = await _writeDeviceTime(deviceId, chars.wr);
              _timeWritten[deviceId] = ok;
              debugPrint(ok ? '✅ 時間寫入成功' : '❌ 時間寫入失敗');

              await Future.delayed(const Duration(milliseconds: 150));

              try {
                final fw = await _readFirmwareVersion(deviceId, chars.rdFw);
                if (fw != null) {
                  _saveDeviceVersion(fw);
                  debugPrint('📦 韌體版本：$fw');
                }
              } catch (e) {
                debugPrint('📦 讀取版本失敗：$e');
              }

              await Future.delayed(const Duration(milliseconds: 150));

              await _subscribeToNotifications(deviceId);
            });
          } catch (e) {
            debugPrint('❌ 連線模式初始化失敗：$e');
          }
        } else if (update.connectionState == DeviceConnectionState.disconnected) {
          _connectedDeviceId = null;
          debugPrint('🔌 設備已斷線');

          await _notifySubscription?.cancel();
          _notifySubscription = null;

          if (_connectionMode == BleConnectionMode.connection) {
            debugPrint('⏳ 3秒後嘗試重連...');
            await Future.delayed(const Duration(seconds: 3));
            await startConnectionMode(deviceId: deviceId, deviceName: deviceName);
          }
        }
      },
      onError: (e) {
        debugPrint('❌ 連線錯誤：$e');
      },
    );
  }

  Future<void> _subscribeToNotifications(String deviceId) async {
    try {
      final services = await _ble.discoverServices(deviceId);
      QualifiedCharacteristic? notifyCharQ;

      // A) 若已知 Char UUID，直接定位
      final preferredNotify = _BleFilters.kNotifyCharUuid; // ← 來自你前面存的
      if (preferredNotify != null) {
        for (final s in services) {
          for (final c in s.characteristics) {
            if (c.characteristicId == preferredNotify) {
              notifyCharQ = QualifiedCharacteristic(
                deviceId: deviceId,
                serviceId: s.serviceId,
                characteristicId: c.characteristicId,
              );
              break;
            }
          }
          if (notifyCharQ != null) break;
        }
      }

      // B) 若沒有存，或定位失敗 → 自動找第一個可通知的
      if (notifyCharQ == null) {
        for (final s in services) {
          for (final c in s.characteristics) {
            if (c.isNotifiable) {
              notifyCharQ = QualifiedCharacteristic(
                deviceId: deviceId,
                serviceId: s.serviceId,
                characteristicId: c.characteristicId,
              );
              // 同步補存（下次可直用）
              _BleFilters.kNotifyCharUuid = c.characteristicId;
              await _BleFilters.saveToPrefs();
              break;
            }
          }
          if (notifyCharQ != null) break;
        }
      }

      if (notifyCharQ == null) {
        debugPrint('⚠️ 找不到可用的通知特徵值');
        return;
      }

      _notifySubscription = _ble.subscribeToCharacteristic(notifyCharQ).listen(
            (data) {
          debugPrint('📨 收到連線模式數據：${data.length} bytes');
          _parseConnectionModeData(deviceId, data);
        },
        onError: (e) {
          debugPrint('❌ 訂閱通知失敗：$e');
        },
      );

      debugPrint('✅ 已訂閱通知特徵值：${notifyCharQ.characteristicId}');
    } catch (e) {
      debugPrint('❌ 訂閱通知過程失敗：$e');
    }
  }

  void _parseConnectionModeData(String deviceId, List<int> data) {
    if (data.isEmpty) return;

    debugPrint('🔍 解析連線數據：${_hex(data)}');

    DateTime? timestamp;
    double? voltage;
    double? temperature;
    final rawCurrents = <double>[];

    if (data.length >= 4) {
      final guess = guessBitfieldTime(data, asUtc: false);
      if (guess != null) {
        timestamp = guess.time;
        debugPrint('⏱️ 連線模式時間：$timestamp');
      }
    }

    if (data.length >= 6) {
      final rawCurrent = (data[4] << 8) | data[5];
      final current_mA = rawCurrent / 10.0;
      rawCurrents.add(current_mA);
      debugPrint('⚡ 電流：${current_mA} mA');
    }

    if (data.length >= 8) {
      final rawTemp = (data[6] << 8) | data[7];
      temperature = rawTemp / 100.0;
      debugPrint('🌡️ 溫度：${temperature} °C');
    }

    if (data.length >= 10) {
      final rawVolt = (data[8] << 8) | data[9];
      voltage = rawVolt / 1000.0;
      debugPrint('🔋 電壓：${voltage} V');
    }

    final current = calculateCurrent(rawCurrents);
    final currents = [current];

    final bleData = BleDeviceData(
      id: deviceId,
      name: _connectedDeviceName ?? deviceId.substring(0, 8),
      rssi: 0,
      timestamp: timestamp ?? DateTime.now(),
      voltage: voltage,
      temperature: temperature,
      currents: currents,
      rawData: data,
    );

    _deviceDataController.add(bleData);
  }

  Future<void> stopConnectionMode() async {
    await _notifySubscription?.cancel();
    _notifySubscription = null;
    await _maintainConnection?.cancel();
    _maintainConnection = null;
    _connectedDeviceId = null;
    _connectedDeviceName = null;
    debugPrint('🔌 連線模式已停止');
  }

  // ------- 初始化設備（廣播模式用）-------
  Future<void> _initializeDevice(String deviceId) async {
    debugPrint('🔗 初始化裝置：$deviceId');
    _initializedDevices.add(deviceId);

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
            try {
              await _ble.requestConnectionPriority(
                deviceId: deviceId,
                priority: ConnectionPriority.highPerformance,
              );
              await Future.delayed(const Duration(milliseconds: 200));
            } catch (e) {
              debugPrint('⚠️ 升級連線優先權失敗：$e');
            }

            final chars = await _findCharacteristics(deviceId);
            if (chars == null) {
              debugPrint('❌ 找不到必要特徵');
              return;
            }

            await Future.delayed(const Duration(milliseconds: 120));

            final ok = await _writeDeviceTime(deviceId, chars.wr);
            _timeWritten[deviceId] = ok;
            debugPrint(ok ? '✅ 時間寫入成功' : '❌ 時間寫入失敗');

            await Future.delayed(const Duration(milliseconds: 150));

            try {
              final fw = await _readFirmwareVersion(deviceId, chars.rdFw);
              if (fw != null) {
                _saveDeviceVersion(fw);
                debugPrint('📦 韌體版本：$fw');
              }
            } catch (e) {
              debugPrint('📦 讀取版本失敗：$e');
            }
          });

          // 在 connected 後、_withGattLock 裡面寫時間/讀版本之後，加：
          await _captureAndStoreGattProfile(deviceId);

        } catch (e) {
          debugPrint('❌ 初始化失敗：$e');
        } finally {
          await Future.delayed(const Duration(milliseconds: 300));
          await _connSub?.cancel();
          debugPrint('🔌 已斷線');
          if (!completer.isCompleted) completer.complete();

          // 回到廣播模式持續掃描（若仍在 broadcast 模式）
          await Future.delayed(const Duration(seconds: 3));
          if (!_isScanning && _connectionMode == BleConnectionMode.broadcast) {
            await restartScan(skipPermissionCheck: true, serviceUuids: _BleFilters.kServiceFilter);
            if (!_isScanning) {
              await startScan(skipPermissionCheck: true, serviceUuids: _BleFilters.kServiceFilter);
            }
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

  /// 連線後抓取 Service/Characteristic，更新硬體過濾與通知 Char，並存到偏好
  Future<void> _captureAndStoreGattProfile(String deviceId) async {
    try {
      final services = await _ble.discoverServices(deviceId);

      // 1) 收集所有 Service UUID（去重）
      final serviceIds = <Uuid>{};
      for (final s in services) {
        serviceIds.add(s.serviceId);
      }
      if (serviceIds.isNotEmpty) {
        _BleFilters.kServiceFilter = serviceIds.toList();
        debugPrint('🧱 探得 ${_BleFilters.kServiceFilter.length} 個 Service：${_BleFilters.kServiceFilter}');
      } else {
        debugPrint('⚠️ discoverServices 沒拿到任何 Service');
      }

      // 2) 尋找一個「可通知」的 Characteristic（若你已知哪個服務更準，可再加條件）
      Uuid? notifyChar;
      for (final s in services) {
        for (final c in s.characteristics) {
          // 優先挑「可通知」的
          final notifiable = c.isNotifiable;
          // 若你的韌體有特定 UUID 模式，可在這裡加白名單/關鍵字篩選
          if (notifiable) {
            notifyChar = c.characteristicId;
            debugPrint('🔔 偵測到可通知 Char: $notifyChar （Service: ${s.serviceId}）');
            break;
          }
        }
        if (notifyChar != null) break;
      }

      if (notifyChar != null) {
        // 存起來供後續連線模式直接使用
        _BleFilters.kNotifyCharUuid = notifyChar;
      } else {
        debugPrint('⚠️ 沒找到可通知的 Char（之後會回退為自動搜尋方式）');
      }

      // 3) 寫入偏好（下次掃描先用硬體過濾）
      await _BleFilters.saveToPrefs();
    } catch (e) {
      debugPrint('❌ _captureAndStoreGattProfile 失敗：$e');
    }
  }

  Future<void> _saveDeviceVersion(String deviceVersion) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_version', deviceVersion);
    _deviceVersionController.add(deviceVersion);
  }

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

  Future<bool> _writeDeviceTime(
      String deviceId,
      QualifiedCharacteristic wr,
      ) async {
    final nowUtc = DateTime.now();
    final t4 = encodeTimeBitfield4(
      t: Time(
        year: nowUtc.year,
        month: nowUtc.month,
        day: nowUtc.day,
        hour: nowUtc.hour,
        minute: nowUtc.minute,
        second: nowUtc.second,
      ),
      endian: kTimeEndian,
    );

    debugPrint('>> Write DateTime (UTC): $nowUtc');
    debugPrint('>> t4 (hex): ${_hex(t4)}  (endian=$kTimeEndian)');

    final payload = Uint8List.fromList(<int>[
      0x01,
      0x03, 0xE8,
      0x00, 0x64,
      0x00, 0x01,
      0x03, 0x84,
      ...t4,
    ]);

    debugPrint('>> payload (hex): ${_hex(payload)}');

    int attempts = 0;
    const maxAttempts = 3;

    while (attempts < maxAttempts) {
      attempts++;
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await _ble.writeCharacteristicWithoutResponse(wr, value: payload);
        debugPrint('✅ 時間寫入成功 #$attempts');
        return true;
      } catch (e) {
        debugPrint('❌ 寫入失敗 #$attempts：$e');
        if (attempts >= maxAttempts) return false;
        await Future.delayed(Duration(milliseconds: 150 * attempts));
      }
    }
    return false;
  }

  Future<String?> _readFirmwareVersion(
      String deviceId, QualifiedCharacteristic rd) async {
    try {
      debugPrint('📖 開始讀取韌體版本...');

      final data = await _ble.readCharacteristic(rd);

      debugPrint('📖 讀取到原始數據: $data');

      if (data.isEmpty) {
        debugPrint('⚠️ 版本號數據為空');
        return null;
      }

      final version = String.fromCharCodes(data);
      debugPrint('✅ 解析版本號: $version');

      return version;
    } catch (e) {
      debugPrint('❌ 讀版本失敗：$e');
      return null;
    }
  }

  // 測試用
  /// 小端 + 有號 16-bit
  int int16LE(List<int> b, int off) {
    final v = (b[off] & 0xFF) | ((b[off + 1] & 0xFF) << 8);
    return (v & 0x8000) != 0 ? v - 0x10000 : v;
  }

  /// 小端 + 無號 16-bit（如果你要解析像「計數器」或「長度」）
  int uint16LE(List<int> b, int off) {
    return (b[off] & 0xFF) | ((b[off + 1] & 0xFF) << 8);
  }

  /// 電流 mA：int16LE 後依協議除以 10
  double? parseCurrent_mA_LE(List<int> b, int off) {
    if (off + 1 >= b.length) return null;
    final raw = int16LE(b, off);
    // 缺值碼（依韌體定義調整；常見是 -1 或 -32768）
    if (raw == -1 || raw == -32768) return null;
    return raw / 10.0;
  }

  /// Dump 輔助，快速定位 offset
  String hexDump(Iterable<int> bytes, {int width = 16}) {
    final b = bytes.toList();
    final buf = StringBuffer();
    for (int off = 0; off < b.length; off += width) {
      final chunk = b.skip(off).take(width);
      final hex = chunk
          .map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
      buf.writeln(off.toRadixString(16).padLeft(4, '0').toUpperCase() + ': ' + hex);
    }
    return buf.toString();
  }

  // ====== 通用解析工具 ======
  int _toSigned16(int v) => (v & 0x8000) != 0 ? v - 0x10000 : v;

  int _int16LE(List<int> b, int off) {
    final v = (b[off] & 0xFF) | ((b[off + 1] & 0xFF) << 8);
    return _toSigned16(v);
  }

  int _int16BE(List<int> b, int off) {
    final v = ((b[off] & 0xFF) << 8) | (b[off + 1] & 0xFF);
    return _toSigned16(v);
  }

  String _hex2(int x) => x.toRadixString(16).padLeft(2, '0').toUpperCase();

  /// 把 bytes 以帶索引的十六進位列印（除錯用）
  String _hexDump(Iterable<int> bytes, {int width = 16}) {
    final b = bytes.toList();
    final buf = StringBuffer();
    for (int off = 0; off < b.length; off += width) {
      final chunk = b.skip(off).take(width);
      final hex = chunk.map((x) => _hex2(x)).join(' ');
      buf.writeln(off.toString().padLeft(3) + ': ' + hex);
    }
    return buf.toString();
  }

  /// 測試用
  /// 掃描 [start..end) 範圍內所有兩兩位元組，列出：
  ///  - index, bytes, LE(raw), LE/10(mA), BE(raw), BE/10(mA)
  /// 可用 min/max 篩掉離譜的值（例如 mA 合理範圍）
  void debugScanAllInt16Pairs({
    required List<int> bytes,
    String tag = 'SCAN',
    int? start,
    int? end,
    double scale = 0.1,        // 依協議，電流通常 /10 → mA
    bool onlyPlausible = false,
    double plausibleMin = -5000, // mA
    double plausibleMax =  5000, // mA
  }) {
    final s = start ?? 0;
    final e = end == null ? (bytes.length - 1) : end.clamp(0, bytes.length - 1);

    debugPrint('[$tag] bytes=${bytes.length}, scan [$s..$e), scale=$scale');
    for (int i = s; i <= e - 2; i++) {
      try {
        final lo = bytes[i] & 0xFF;
        final hi = bytes[i + 1] & 0xFF;

        final le = _int16LE(bytes, i);
        final be = _int16BE(bytes, i);

        final leScaled = le * scale; // mA
        final beScaled = be * scale; // mA

        if (onlyPlausible) {
          final okLE = leScaled >= plausibleMin && leScaled <= plausibleMax;
          final okBE = beScaled >= plausibleMin && beScaled <= plausibleMax;
          if (!okLE && !okBE) continue;
        }

        debugPrint(
          '[$tag] off=${i.toString().padLeft(2)} '
              'bytes=[${_hex2(lo)} ${_hex2(hi)}]  '
              'LE=${le.toString().padLeft(6)}  LE_mA=${leScaled.toStringAsFixed(1).padLeft(8)}  '
              'BE=${be.toString().padLeft(6)}  BE_mA=${beScaled.toStringAsFixed(1).padLeft(8)}',
        );
      } catch (_) {
        // ignore 越界
      }
    }
  }

  BleDeviceData? _parseManufacturerData(DiscoveredDevice device) {
    final mfr = device.manufacturerData;
    if (mfr.isEmpty) return null;

    // A) 原始廣播（含 Company ID）
    debugPrint('[ADV:MFD raw]\n${_hexDump(mfr)}');

    // B) 移除前 2 bytes 的 Company ID，掃 payload
    final payload = (mfr.length >= 2) ? mfr.sublist(2) : mfr;
    debugPrint('[ADV:payload]\n${_hexDump(payload)}');

    // C) 全面掃描：每個 offset 都算 LE/BE 與 /10(mA)
    debugScanAllInt16Pairs(
      bytes: payload,
      tag: 'ADV',
      start: 0,
      end: payload.length, // 可縮小範圍以減少 log
      scale: 0.1,          // 依協議調整
      onlyPlausible: false, // 先看全量；噪太多再開 true
    );

    DateTime? timestamp;
    final guess = guessBitfieldTime(mfr);
    if (guess != null) {
      timestamp = guess.time;
      debugPrint('⏱️ bit-field 時間 @off=${guess.offset}, endian=${guess.endian}, value=$timestamp');
    }

    double? voltage;
    double? temperature;
    final rawCurrents = <double>[];

    int _safeU16(List<int> m, int hiIndex) {
      if (hiIndex < 0 || hiIndex + 1 >= m.length) return -1;
      return (m[hiIndex] << 8) | m[hiIndex + 1];
    }

    // final rawCurrent = _safeU16(mfr, 4);
    // print('test123 rawCurrent: $rawCurrent');
    // if (rawCurrent >= 0) {
    //   final current_mA = rawCurrent / 10.0;
    //   rawCurrents.add(current_mA);
    // }

    final rawTemp = _safeU16(mfr, 6);
    if (rawTemp >= 0) {
      temperature = rawTemp / 100.0;
    }

    final rawVolt = _safeU16(mfr, 8);
    if (rawVolt >= 0) {
      voltage = rawVolt / 1000.0;
    }

    // final current = calculateCurrent(rawCurrents);
    final current = calculateCurrentFromMfr(mfr, 4);
    final currents = [current];

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

  double calculateCurrentFromMfr(List<int> mfr, int offset) {
    const double R1 = 2.00E6;
    const double R2 = 88.7E3;
    const double R3 = 100.00E3;
    const double R4 = 2.00E6;
    const double V_09 = 0.9000;
    const double TIR_Inp = V_09;

    try {
      if (offset < 0 || offset + 1 >= mfr.length) {
        throw Exception("索引超出範圍");
      }

      // 取第 offset 與 offset+1 個 Byte (Big Endian)
      final hi = mfr[offset];
      final lo = mfr[offset + 1];

      // 轉成 u16
      final u16 = (hi << 8) | lo;

      // 換算成電壓 (mV → V)
      final V_out = u16 / 1000.0;

      // 電路公式
      final V_In_N = (V_out - V_09) / (R3 + R4) * R3 + V_09;
      final V_TIR = V_In_N + (V_In_N / R1) * R2;
      final result = (V_TIR - TIR_Inp) / 20E6; // 單位 A

      debugPrint("offset=$offset, raw=[${hi.toRadixString(16)} ${lo.toRadixString(16)}], "
          "u16=$u16, V_out=$V_out, result=$result");

      return result;
    } catch (e) {
      debugPrint(">> calculateCurrentFromMfr() error: $e");
      return -1;
    }
  }

  double calculateCurrent(List<double> currents) {
    try {
      double R1 = 2.00E6;
      double R2 = 88.7E3;
      double R3 = 100.00E3;
      double R4 = 2.00E6;
      double V_09 = 0.9000;
      double TIR_Inp = V_09;

      if (currents.isEmpty) {
        throw Exception("currents 陣列為空");
      }

      double V_out = currents.first / 1000.0;
      double V_In_N = (V_out - V_09) / (R3 + R4) * R3 + V_09;
      double V_TIR = V_In_N + (V_In_N / R1) * R2;
      double result = (V_TIR - TIR_Inp) / 20E6;

      print('test123 result: $result');
      return result;
    } catch (error) {
      debugPrint(">> calculateCurrent() error: $error");
      return -1;
    }
  }

  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _maintainConnection?.cancel();
    _notifySubscription?.cancel();
    _deviceDataController.close();
    _deviceVersionController.close();
  }

  String toHexList(Iterable<int> bytes, {bool withBrackets = true}) {
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(', ');
    return withBrackets ? '[$hex]' : hex;
  }

  List<int> parseHexList(String s) {
    final cleaned = s
        .replaceAll('[', '')
        .replaceAll(']', '')
        .replaceAll('0x', '')
        .replaceAll(',', ' ')
        .trim();
    if (cleaned.isEmpty) return <int>[];
    return cleaned
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map((t) => int.parse(t, radix: 16))
        .toList(growable: false);
  }

  /// 解析「Undocumented scan throttle ... suggested retry date is ...」的時間
  /// 不同機型格式會不同，這裡做寬鬆處理；若解析失敗回 null
  DateTime? _parseSuggestedRetryTime(String message) {
    try {
      // 盡量抓最後的日期字串
      final re = RegExp(r'suggested retry date is (.+)$');
      final m = re.firstMatch(message);
      if (m == null) return null;
      var s = m.group(1)!.trim();

      // 常見格式會含 GMT+08:00 等，先做些替換讓 DateTime.parse 比較好吃
      s = s.replaceAll('GMT', '').replaceAll('  ', ' ').trim();

      // 嘗試直接 parse（大多數失敗，保留保險）
      DateTime? dt;
      try {
        dt = DateTime.parse(s);
      } catch (_) {
        // 粗略 fallback：抓到「HH:mm:ss +08:00 yyyy」的 +08:00 與 yyyy 來組合
        final tz = RegExp(r'([+-]\d{2}:\d{2})').firstMatch(s)?.group(1);
        final year = RegExp(r'\b(20\d{2})\b').firstMatch(s)?.group(1);
        final time = RegExp(r'\b\d{2}:\d{2}:\d{2}\b').firstMatch(s)?.group(0);
        final monthStr = RegExp(r'\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b')
            .firstMatch(s)
            ?.group(0);
        final day = RegExp(r'\b\d{1,2}\b').firstMatch(s)?.group(0);

        if (tz != null && year != null && time != null && monthStr != null && day != null) {
          final monthMap = {
            'Jan': '01','Feb': '02','Mar': '03','Apr': '04','May': '05','Jun': '06',
            'Jul': '07','Aug': '08','Sep': '09','Oct': '10','Nov': '11','Dec': '12'
          };
          final month = monthMap[monthStr]!;
          final day2 = day.padLeft(2, '0');
          final iso = '$year-$month-${day2}T$time$tz';
          dt = DateTime.tryParse(iso);
        }
      }
      // 如果還是失敗，就回 null
      return dt;
    } catch (_) {
      return null;
    }
  }
}