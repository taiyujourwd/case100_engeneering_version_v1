import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../measure/ble/ble_adapter.dart';
import '../measure/ble/reactive_ble_client.dart';
import '../measure/data/measure_repository.dart';

final bleClientProvider = Provider<BleClient>((ref) => ReactiveBleClient());

final repoProvider = FutureProvider<MeasureRepository>((ref) async {
  final ble = ref.read(bleClientProvider);
  return MeasureRepository.create(ble);
});
