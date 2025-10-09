import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../measure/ble/ble_adapter.dart';
import '../measure/ble/reactive_ble_client.dart';
import '../measure/data/measure_repository.dart';
import 'ble/ble_service.dart';
import 'models/ble_device.dart';

Future<String> _loadDeviceName() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('device_name').toString();
}

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

// 初始化（讀取 SharedPreferences）
final targetDeviceNameFutureProvider = FutureProvider<String?>((ref) async => await _loadDeviceName());

// 實際使用的狀態
final targetDeviceNameProvider = StateProvider<String>((ref) {
  final asyncValue = ref.watch(targetDeviceNameFutureProvider);
  return asyncValue.maybeWhen(
    data: (name) => name ?? '',
    orElse: () => '', // 預設空字串
  );
});
