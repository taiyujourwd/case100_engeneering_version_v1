import 'dart:async';

class BlePacket {
  final int seq;
  final double? voltage;
  final double? current;
  final double? glucose;
  final DateTime ts;
  BlePacket(this.seq, this.voltage, this.current, this.glucose, this.ts);
}

abstract class BleClient {
  Stream<BlePacket> get packets;
  Future<void> startScan(String? nameOrId);
  Future<void> connectAndSubscribe(String deviceId);
  Future<void> requestCatchup(int lastSeq);
  Future<void> disconnect();
}
