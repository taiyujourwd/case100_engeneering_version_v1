import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:location/location.dart' as loc;
import 'package:permission_handler/permission_handler.dart';

import '../models/ble_device.dart';

/// -------- 時間位欄位規格 --------
/// [31..26] 年(相對2000, 6b)  → 2000..2063
/// [25..22] 月(4b)            → 1..12
/// [21..17] 日(5b)            → 1..31
/// [16..12] 時(5b)            → 0..23
/// [11..6 ] 分(6b)            → 0..59
/// [5 ..0 ] 秒(6b)            → 0..59

enum EndianType { big, little }

/// 根據實際韌體端序切換（先試 big，不對就換 little）
const EndianType kTimeEndian = EndianType.big; // ← 若時間不對，改成 EndianType.little

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
/// 依據端序把 4 bytes 解回 UTC 的 DateTime
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

  final yearOff = (v >> 26) & 0x3F; // 0..63
  final month = (v >> 22) & 0x0F; // 1..12
  final day = (v >> 17) & 0x1F; // 1..31
  final hour = (v >> 12) & 0x1F; // 0..23
  final minute = (v >> 6) & 0x3F; // 0..59
  final second = v & 0x3F; // 0..59

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
/// 同時嘗試 Big / Little，回傳更接近 nowUtc 的那組
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

  final _deviceDataController = StreamController<BleDeviceData>.broadcast();
  Stream<BleDeviceData> get deviceDataStream => _deviceDataController.stream;

  final Set<String> _initializedDevices = {};
  final Map<String, bool> _timeWritten = {};
  bool _gattBusy = false;
  bool _isScanning = false;

  // ------- 權限 -------
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

      // GPS 開啟（Android 某些機型掃描需要）
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

  // ------- 掃描 -------
  Future<void> startScan({String? targetName, String? targetId}) async {
    if (_isScanning) return;

    // 假如上次沒收乾淨，這裡再保險一次
    await _scanSub?.cancel();
    _scanSub = null;

    final ok = await requestPermissions();
    if (!ok) {
      debugPrint('❌ 無法啟動掃描：權限不足');
      return;
    }

    debugPrint('🔎 開始掃描裝置...');
    _isScanning = true;

    _scanSub = _ble
        .scanForDevices(withServices: [], scanMode: ScanMode.lowLatency)
        .listen((device) async {
      // ✅ 先以 MAC/Id 過濾（最穩）
      if (targetId != null && targetId.isNotEmpty && device.id != targetId) {
        return;
      }
      // ✅ 名稱只做寬鬆比對
      if (targetName != null && targetName.isNotEmpty) {
        final n = device.name.toLowerCase();
        final q = targetName.toLowerCase();
        if (!(n.contains(q) || n.startsWith(q))) return;
      }

      debugPrint('📡 發現裝置：${device.name} (${device.id}) RSSI=${device.rssi}');

      // 解析廣播（只用 bit-field）
      final parsed = _parseManufacturerData(device);
      if (parsed != null) _deviceDataController.add(parsed);

      // 自動初始化：只做一次
      if (!_initializedDevices.contains(device.id)) {
        await _initializeDevice(device.id);
      }
    }, onError: (e) async{
      debugPrint('❌ 掃描錯誤：$e');
      _isScanning = false;             // ✅ 確保旗標回復
      await Future.delayed(const Duration(milliseconds: 500));
      await restartScan();
    }, onDone: () async{
      debugPrint('ℹ️ 掃描串流已結束');
      _isScanning = false;             // ✅ 確保旗標回復
      await Future.delayed(const Duration(milliseconds: 500));
      await restartScan();
    });
  }

  Future<void> restartScan({String? targetName}) async {
    await _scanSub?.cancel();
    _scanSub = null;
    _isScanning = false;
    await Future.delayed(const Duration(milliseconds: 200));
    await startScan(targetName: targetName);
  }

  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    _isScanning = false;
    debugPrint('⏹️ 已停止掃描');
  }

  // ------- 初始化：連線 → 寫時間 → 讀版本 -------
  Future<void> _initializeDevice(String deviceId) async {
    debugPrint('🔗 初始化裝置：$deviceId');
    _initializedDevices.add(deviceId);

    // await stopScan(); // 先停掃，提高連線穩定度

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
            // 提升連線優先權（可忽略錯誤）
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

          // 重新掃描
          await Future.delayed(const Duration(seconds: 3));
          if (!_isScanning) await restartScan();
          if (!_isScanning) await startScan();
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

  // ------- 簡單 GATT 互斥鎖 -------
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

  // ------- 尋找特徵 -------
  Future<({QualifiedCharacteristic wr, QualifiedCharacteristic rdFw})?>
  _findCharacteristics(String deviceId) async {
    debugPrint('deviceId: $deviceId');
    final services = await _ble.discoverServices(deviceId);
    QualifiedCharacteristic? wr, rdFw;

    debugPrint('servicesAAA: $services');

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

  // ------- 寫入時間（bit-field + UTC） -------
  Future<bool> _writeDeviceTime(
      String deviceId, QualifiedCharacteristic wr) async {
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
      0x01,             // Method = IT (依你協定)
      0x03, 0xE8,       // Quiet ms = 1000 (16-bit big, 0x03E8)
      0x00, 0x64,       // Sample ms = 100 (16-bit big, 0x0064)
      0x00, 0x01,       // Run count = 1 (16-bit big)
      0x03, 0x84,       // Init E (mV) = 900 (16-bit big)
      ...t4,            // Time (4B, bit-field with kTimeEndian)
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

  // ------- 讀取韌體版本 -------
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

  // ------- 解析廣播：只用 bit-field -------
  BleDeviceData? _parseManufacturerData(DiscoveredDevice device) {
    final mfr = device.manufacturerData;
    print("test123 manufacturerData: ${device.manufacturerData}");
    print('test123 manufacturerData(hex): ${toHexList(mfr)}');
    if (mfr.isEmpty) return null;

    // 找看起來像 bit-field 時間的切片（同時嘗試 big/little）
    DateTime? timestamp;
    final guess = guessBitfieldTime(mfr);
    if (guess != null) {
      timestamp = guess.time;
      debugPrint(
          '⏱️ bit-field 時間 @off=${guess.offset}, endian=${guess.endian}, value=$timestamp, bytes(hex)=${_hex(mfr.sublist(guess.offset, guess.offset + 4))}');
    } else {
      debugPrint('⏱️ 廣播未找到可解的 bit-field 時間');
    }

    // 其他欄位（固定位置解析）
    double? voltage;
    double? temperature;

    // 電流維持List回傳（若想只回傳單點，可改成單值）
    final rawCurrents = <double>[];

    // 假設已有 _safeU16 為 big-endian： (hi<<8)|lo
    int _safeU16(List<int> m, int hiIndex) {
      if (hiIndex < 0 || hiIndex + 1 >= m.length) return -1;
      return (m[hiIndex] << 8) | m[hiIndex + 1];
    }

    // 取電流 [4..5] → mA = raw / 10.0
    final rawCurrent = _safeU16(mfr, 4);
    if (rawCurrent >= 0) {
      final current_mA = rawCurrent / 10.0;
      rawCurrents.add(current_mA);
      debugPrint('⚡ current raw=0x${rawCurrent.toRadixString(16)} -> ${current_mA.toStringAsFixed(1)} mA');
    }

    // 取溫度 [6..7] → °C = raw / 100.0
    final rawTemp = _safeU16(mfr, 6);
    if (rawTemp >= 0) {
      temperature = rawTemp / 100.0;
      debugPrint('🌡️ temp raw=0x${rawTemp.toRadixString(16)} -> ${temperature.toStringAsFixed(2)} °C');
    }

    // 取電壓 [8..9] → V = raw / 1000.0
    final rawVolt = _safeU16(mfr, 8);
    if (rawVolt >= 0) {
      voltage = rawVolt / 1000.0;
      debugPrint('🔋 volt raw=0x${rawVolt.toRadixString(16)} -> ${voltage.toStringAsFixed(3)} V');
    }

    print('test123 rawCurrents: $rawCurrents');

    final current = calculateCurrent(rawCurrents);
    final currents = [current];

    print('test123 currents: $currents');

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

  //轉換電流值
  double calculateCurrent(List<double> currents) {
    String functionName = "calculateCurrent()";
    try {
      // 電路參數
      double R1 = 2.00E6;
      double R2 = 88.7E3;
      double R3 = 100.00E3;
      double R4 = 2.00E6;
      double V_09 = 0.9000;  // V_0.9
      double TIR_Inp = V_09; // TIR_In+

      if (currents.isEmpty) {
        throw Exception("currents 陣列為空");
      }

      // 取第一個值 (假設單位是 mV，要轉 V)
      double V_out = currents.first / 1000.0; // 2356.2 mV → 2.3562 V

      // 計算公式
      double V_In_N = (V_out - V_09) / (R3 + R4) * R3 + V_09;
      double V_TIR  = V_In_N + (V_In_N / R1) * R2;
      double result = (V_TIR - TIR_Inp) / 20E6; // 電流 (A)

      return result;
    } catch (error) {
      debugPrint(">> log : [catch] - $functionName, $error");
      return -1;
    }
  }

  // ------- 資源釋放 -------
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _deviceDataController.close();
  }

  /// 將 List<int>/Uint8List 轉成十六進位清單樣式：[C0, AD, 00, 5A, ...]
  String toHexList(Iterable<int> bytes, {bool withBrackets = true}) {
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(', ');
    return withBrackets ? '[$hex]' : hex;
  }

  /// 十六進位轉回位元組（支援 "C0 AD 00", "C0,AD,00", "0xC0 0xAD" 等）
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

  /// 進階：hexdump（每行 16 bytes，帶位移）
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
}