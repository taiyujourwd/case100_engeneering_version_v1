import 'package:workmanager/workmanager.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

const taskSync = 'sync-upload';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == taskSync) {
      final conn = await Connectivity().checkConnectivity();
      final isWifi = conn.contains(ConnectivityResult.wifi);
      if (isWifi) {
        // TODO: 讀取未上傳資料 → API 上傳 → 標記已上傳
      }
    }
    return true;
  });
}

Future<void> schedulePeriodicSync() async {
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  await Workmanager().registerPeriodicTask(
    'sync-upload-id',
    taskSync,
    frequency: const Duration(hours: 1),
    constraints: Constraints(networkType: NetworkType.unmetered),
    backoffPolicy: BackoffPolicy.linear,
  );
}
