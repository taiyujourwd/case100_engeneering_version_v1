import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../ble/ble_adapter.dart';
import '../../ble/reactive_ble_client.dart';
import '../../data/measure_repository.dart';
import '../../ble/ble_service.dart';
import '../../models/ble_device.dart';
import '../measure_screen.dart';
import 'device_info_providers.dart';

// 您原有的 Providers
final bleClientProvider = Provider<BleClient>((ref) => ReactiveBleClient());

final repoProvider = FutureProvider<MeasureRepository>((ref) async {
  final ble = ref.read(bleClientProvider);
  return MeasureRepository.create(ble);
});

final bleServiceProvider = Provider<BleService>((ref) {
  final service = BleService();
  ref.onDispose(() => service.dispose());
  return service;
});

// BLE 連線狀態 Provider
final bleConnectionStateProvider = StateProvider<bool>((ref) => false);

// ✅ 設備版本號 Stream Provider（如果還沒有）
final deviceVersionStreamProvider = StreamProvider<String>((ref) {
  final bleService = ref.watch(bleServiceProvider);
  return bleService.deviceVersionStream;
});

// ✅ 版本號監聽器
final versionListenerProvider = Provider<void>((ref) {
  // 監聽版本號 Stream
  ref.listen<AsyncValue<String>>(
    deviceVersionStreamProvider,
        (previous, next) {
      next.whenData((version) {
        if (version.isNotEmpty) {
          final currentVersion = ref.read(targetDeviceVersionProvider);
          if (currentVersion != version) {
            ref.read(targetDeviceVersionProvider.notifier).state = version;
            debugPrint('✅ [Version] 版本號已更新：$version');
          }
        }
      });
    },
  );
});

// UI 專用 Provider
final bleUiStateProvider = StateProvider<BleUiState>((ref) {
  return BleUiState.idle;
});