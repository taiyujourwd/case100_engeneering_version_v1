import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../ble/ble_adapter.dart';
import '../../ble/reactive_ble_client.dart';
import '../../data/measure_repository.dart';
import '../../ble/ble_service.dart';
import '../../models/ble_device.dart';

final bleClientProvider = Provider<BleClient>((ref) => ReactiveBleClient());

final repoProvider = FutureProvider<MeasureRepository>((ref) async {
  final ble = ref.read(bleClientProvider);
  return MeasureRepository.create(ble);
});

// BLE Service Provider
final bleServiceProvider = Provider<BleService>((ref) {
  final service = BleService();
  ref.onDispose(() => service.dispose());
  return service;
});

// BLE 連線狀態 Provider
final bleConnectionStateProvider = StateProvider<bool>((ref) => false);

// BLE 裝置數據流 Provider
final bleDeviceDataStreamProvider = StreamProvider<BleDeviceData>((ref) {
  final bleService = ref.watch(bleServiceProvider);
  return bleService.deviceDataStream;
});

// 設備版本號串流
final bleDeviceVersionStreamProvider = StreamProvider<String>((ref) {
  final bleService = ref.watch(bleServiceProvider);
  return bleService.deviceVersionStream;
});
