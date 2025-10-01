import 'dart:async';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'ble_adapter.dart';

class ReactiveBleClient implements BleClient {
  final _ble = FlutterReactiveBle();
  final _packetCtrl = StreamController<BlePacket>.broadcast();
  StreamSubscription<List<int>>? _notifySub;
  String? _deviceId;

  static final Uuid serviceId = Uuid.parse("00000000-0000-0000-0000-000000000000");
  static final Uuid notifyChar = Uuid.parse("00000000-0000-0000-0000-000000000001");
  static final Uuid writeChar  = Uuid.parse("00000000-0000-0000-0000-000000000002");

  @override
  Stream<BlePacket> get packets => _packetCtrl.stream;

  @override
  Future<void> startScan(String? nameOrId) async {
    // TODO: 依需求實作掃描與挑選裝置
  }

  @override
  Future<void> connectAndSubscribe(String deviceId) async {
    _deviceId = deviceId;
    final conn = _ble.connectToDevice(id: deviceId, connectionTimeout: const Duration(seconds: 8));
    conn.listen((_) {}, onError: (e) {});

    final qn = QualifiedCharacteristic(serviceId: serviceId, characteristicId: notifyChar, deviceId: deviceId);
    _notifySub = _ble.subscribeToCharacteristic(qn).listen((raw) {
      final p = _parse(raw);
      if (p != null) _packetCtrl.add(p);
    });
  }

  @override
  Future<void> requestCatchup(int lastSeq) async {
    if (_deviceId == null) return;
    final qw = QualifiedCharacteristic(serviceId: serviceId, characteristicId: writeChar, deviceId: _deviceId!);
    final payload = _encodeCatchup(lastSeq);
    await _ble.writeCharacteristicWithResponse(qw, value: payload);
  }

  @override
  Future<void> disconnect() async {
    await _notifySub?.cancel();
  }

  BlePacket? _parse(List<int> raw) {
    // TODO: 依你的協議解包
    final seq = raw.isNotEmpty ? raw.first : 0;
    return BlePacket(seq, null, null, null, DateTime.now());
  }

  List<int> _encodeCatchup(int lastSeq) {
    // 自訂補償命令碼，用 0xCA 開頭 + 0xCB 作為指令代號
    return [
      0xCA,
      0xCB, // 這裡原本錯誤的 0xTC 改掉
      (lastSeq >> 8) & 0xFF,
      lastSeq & 0xFF,
    ];
  }
}
