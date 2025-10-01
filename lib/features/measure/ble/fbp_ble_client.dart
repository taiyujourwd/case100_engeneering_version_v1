import 'dart:async';
import 'ble_adapter.dart';

class FbpBleClient implements BleClient {
  final _packetCtrl = StreamController<BlePacket>.broadcast();
  @override
  Stream<BlePacket> get packets => _packetCtrl.stream;

  @override
  Future<void> startScan(String? nameOrId) async {}

  @override
  Future<void> connectAndSubscribe(String deviceId) async {}

  @override
  Future<void> requestCatchup(int lastSeq) async {}

  @override
  Future<void> disconnect() async {}
}
