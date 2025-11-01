import 'dart:async';
import 'dart:io';

import 'package:case100_engeneering_version_v1/features/measure/presentation/providers/correction_params_provider.dart';
import 'package:case100_engeneering_version_v1/features/measure/presentation/providers/device_info_providers.dart';
import 'package:case100_engeneering_version_v1/features/measure/presentation/widgets/data_smoother.dart';
import 'package:case100_engeneering_version_v1/features/measure/presentation/widgets/settings_dialog.dart';
import 'package:case100_engeneering_version_v1/features/measure/presentation/widgets/smoothing_settings_dialog.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../../common/utils/date_key.dart';
import '../ble/ble_connection_mode.dart';
import '../data/isar_schemas.dart';
import '../data/measure_repository.dart';
import '../data/sample_data.dart';
import '../data/sample_real_data.dart';
import '../foreground/foreground_ble_service.dart';
import '../screens/qu_scan_screen.dart';
import '../models/ble_device.dart';  // ✅ 加入
import 'providers/ble_providers.dart';
import 'widgets/glucose_chart.dart';

enum BleUiState { idle, connecting, connected }

class MeasureScreen extends ConsumerStatefulWidget {
  const MeasureScreen({super.key});

  @override
  ConsumerState<MeasureScreen> createState() => _MeasureScreenState();
}

// ✅ 加入 WidgetsBindingObserver 監聽生命週期
class _MeasureScreenState extends ConsumerState<MeasureScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late String _dayKey;
  int _navIndex = 0;
  String? _scannedDeviceName;
  Timer? _serviceMonitor;

  // ✅ 平滑設定（由 SharedPreferences 載入）
  int smoothMethod = 0;     // '0' = 不套用, '1' = Smooth1, '2' = Smooth2
  int smooth1Order = 5;          // Smooth1 的 order（移動平均窗口）
  int smooth2Order = 7;          // Smooth2 的 order（例：Savitzky-Golay 或自定義）
  double smooth2Error = 3.0;     // Smooth2 的允許誤差（自定義語意）

  // Smooth 3
  int smooth3TrimN = 3;
  double smooth3TrimC = 20.0;
  double smooth3TrimDelta = 0.8;
  bool smooth3UseTrimmedWindow = false;

  int smooth3KalmanN = 3;
  double smooth3Kn = 0.2;

  int smooth3WeightN = 3;
  double smooth3P = 3.0;
  bool smooth3KeepHeadOriginal = false;

  // ✅ 主線程 BLE 訂閱（iOS 必須，Android 備援）
  StreamSubscription<BleDeviceData>? _mainThreadBleSubscription;

  late final AnimationController _spinCtrl;

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(); // 需要時再啟/停，預設可先停
    _spinCtrl.stop();

    _dayKey = dayKeyOf(DateTime.now());

    // ✅ 集中處理所有異步初始化
    _initializeAll();

    // ✅ 監聽 App 生命週期
    WidgetsBinding.instance.addObserver(this);
  }

  // ✅ 統一處理所有異步初始化
  Future<void> _initializeAll() async {
    debugPrint('🚀 [initState] 開始初始化...');

    try {
      // 1. 初始化前景服務
      debugPrint('📱 [1/4] 初始化前景服務...');
      await _initForegroundService();
      debugPrint('✅ [1/4] 前景服務初始化完成');

      // 2. 載入掃描的設備
      debugPrint('📱 [2/4] 載入掃描設備...');
      await _loadScannedDevice();
      debugPrint('✅ [2/4] 掃描設備載入完成');

      // 3. 載入設備資訊
      debugPrint('📱 [3/4] 載入設備資訊...');
      await _loadDeviceInfo();
      debugPrint('✅ [3/4] 設備資訊載入完成');

      // 4. 載入平滑設定 ⭐ 關鍵步驟
      debugPrint('📱 [4/4] 載入平滑設定...');
      await _loadSmoothingPrefs();
      debugPrint('✅ [4/4] 平滑設定載入完成');
      debugPrint('   當前 smoothMethod: "$smoothMethod"');
      debugPrint('   當前 smooth1Order: $smooth1Order');
      debugPrint('   當前 smooth2Order: $smooth2Order');
      debugPrint('   當前 smooth2Error: $smooth2Error');

      // 5. 檢查前景服務狀態
      debugPrint('📱 檢查前景服務狀態...');
      await _checkForegroundServiceStatus();
      debugPrint('✅ 前景服務狀態檢查完成');

      debugPrint('🎉 所有初始化完成！');
    } catch (e, stack) {
      debugPrint('❌ 初始化失敗: $e');
      debugPrint('堆棧: $stack');
    }
  }

  // ✅ 新增：監聽 App 生命週期變化
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('📱 App 生命週期: ${state.name}');

    if (!Platform.isIOS) return;

    final isConnected = ref.read(bleConnectionStateProvider);

    if (state == AppLifecycleState.paused && isConnected) {
      // iOS：App 進入背景
      debugPrint('🍎 [iOS] App 進入背景，BLE 將降頻但持續運行');
    } else if (state == AppLifecycleState.resumed && isConnected) {
      // iOS：App 回到前景
      debugPrint('🍎 [iOS] App 回到前景，恢復正常掃描');
      // 確保主線程監聽還在運行
      if (_mainThreadBleSubscription == null) {
        _setupMainThreadBleListener();
      }
    }
  }

  void _handleForegroundData(dynamic data) {
    debugPrint('📬 [UI] 收到原始訊息: $data');

    if (!mounted) {
      debugPrint('⚠️ [UI] Widget 未 mounted');
      return;
    }

    if (data is Map) {
      final type = data['type'];
      debugPrint('📦 [UI] 訊息類型: $type');

      switch (type) {
        case 'version':
          final version = data['version'] as String?;
          if (version != null && version.isNotEmpty) {
            debugPrint('✅ [UI] 收到版本號: $version');
            if (mounted) {
              ref.read(targetDeviceVersionProvider.notifier).state = version;
              debugPrint('✅ [UI] 版本號已更新到 provider');
            }
          }
          break;

        case 'stopping':
          FgGuards.stopping = true;
          break;

        case 'heartbeat':
          debugPrint('💓 [UI] 收到心跳');
          break;

        case 'data':
          debugPrint('📊 [UI] 前景服務數據: ${data['deviceName']}');
          break;

        case 'error':
          if (mounted) {
            _toast(data['message'] ?? '發生錯誤');
          }
          break;
      }
    } else {
      debugPrint('⚠️ [UI] 收到非 Map 類型訊息: ${data.runtimeType}');
    }
  }

  // ✅ 新增：主線程 BLE 監聽（iOS 必須，Android 可作為備援）
  void _setupMainThreadBleListener() {
    debugPrint('📡 [主線程] 設置 BLE 監聽...');

    final bleService = ref.read(bleServiceProvider);
    _mainThreadBleSubscription?.cancel();

    _mainThreadBleSubscription = bleService.deviceDataStream.listen((data) async {
      // ✅ 檢查數據完整性
      if (data.timestamp == null || data.currents.isEmpty) {
        debugPrint('⚠️ [主線程] 數據不完整，跳過');
        return;
      }

      try {
        final repo = await ref.read(repoProvider.future);
        final deviceName = ref.read(targetDeviceNameProvider);

        final sample = makeSampleFromBle(
          deviceId: deviceName.isNotEmpty ? deviceName : data.id,
          timestamp: data.timestamp!,
          currents: data.currents,
          voltage: data.voltage,
          temperature: data.temperature,
        );

        await repo.addSample(sample);

        // ✅ 記錄詳細時間以便除錯
        final timeStr = '${data.timestamp!.hour.toString().padLeft(2, '0')}:'
            '${data.timestamp!.minute.toString().padLeft(2, '0')}:'
            '${data.timestamp!.second.toString().padLeft(2, '0')}.'
            '${data.timestamp!.millisecond.toString().padLeft(3, '0')}';
        debugPrint('💾 [主線程] 寫入成功: $timeStr');
      } catch (e) {
        debugPrint('❌ [主線程] 寫入失敗：$e');
      }
    });

    debugPrint('✅ [主線程] BLE 監聽已啟動');
  }

  Future<void> _loadSmoothingPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    // 讀取並輸出所有相關的 key
    final keys = prefs.getKeys();
    debugPrint('📋 SharedPreferences 中的所有 keys: $keys');

    // 讀 smoothing_method，預設 '0' 表不套用
    final method = prefs.getInt('smoothing_method') ?? 0;

    // 預設值：避免第一次沒有資料
    final s1Order = prefs.getInt('smooth1_order') ?? 5;
    final s2Order = prefs.getInt('smooth2_order') ?? 7;
    final s2Error = prefs.getDouble('smooth2_error') ?? 3.0;
    final s3TrimN = prefs.getInt('smooth3_trim_n') ?? 20;
    final s3TrimC = prefs.getDouble('smooth3_trim_c') ?? 20.0;
    final s3TrimDelta = prefs.getDouble('smooth3_trim_delta') ?? 0.8;
    final s3UseTrimmedWindow = prefs.getBool('smooth3_use_trimmed_window') ?? true;
    final s3KalmanN = prefs.getInt('smooth3_kalman_n') ?? 10;
    final s3Kn = prefs.getDouble('smooth3_kn') ?? 0.2;
    final s3WeightN = prefs.getInt('smooth3_weight_n') ?? 10;
    final s3P = prefs.getDouble('smooth3_p') ?? 3.0;
    final s3KeepHeadOriginal = prefs.getBool('smooth3_keep_head_original') ?? true;

    if (!mounted) return;
    setState(() {
      smoothMethod = method;
      smooth1Order = s1Order;
      smooth2Order = s2Order;
      smooth2Error = s2Error;
      smooth3TrimN = s3TrimN;
      smooth3TrimC = s3TrimC;
      smooth3TrimDelta = s3TrimDelta;
      smooth3UseTrimmedWindow = s3UseTrimmedWindow;
      smooth3KalmanN = s3KalmanN;
      smooth3Kn = s3Kn;
      smooth3WeightN = s3WeightN;
      smooth3P = s3P;
      smooth3KeepHeadOriginal = s3KeepHeadOriginal;
    });

    debugPrint('🧮 載入平滑設定: method=$smoothMethod, '
        'smooth1_order=$smooth1Order, smooth2_order=$smooth2Order, smooth2_error=$smooth2Error');
  }

  Future<void> _initForegroundService() async {
    await ForegroundBleService.init();

    // ✅ 只在 Android 上設置 Foreground Task callback
    if (Platform.isAndroid) {
      FlutterForegroundTask.removeTaskDataCallback(_handleForegroundData);
      FlutterForegroundTask.addTaskDataCallback(_handleForegroundData);
      debugPrint('✅ [Android] data callback 設置完成');
    } else {
      debugPrint('ℹ️ [iOS] 跳過 foreground task callback');
    }

    final isRunning = await ForegroundBleService.isRunning();
    if (isRunning) {
      ref.read(bleConnectionStateProvider.notifier).state = true;
    }
  }

  Future<void> _checkForegroundServiceStatus() async {
    final isRunning = await ForegroundBleService.isRunning();
    if (isRunning) {
      ref.read(bleConnectionStateProvider.notifier).state = true;
      _toast('前景服務運行中');
    }
  }

  Future<void> _loadScannedDevice() async {
    final prefs = await SharedPreferences.getInstance();
    final deviceName = prefs.getString('scanned_device_name');
    if (deviceName != null) {
      setState(() => _scannedDeviceName = deviceName);
    }
  }

  Future<void> _loadDeviceInfo() async {
    final prefs = await SharedPreferences.getInstance();

    final deviceName = prefs.getString('device_name') ?? '';
    if (deviceName.isNotEmpty) {
      ref.read(targetDeviceNameProvider.notifier).state = deviceName;
    }

    final deviceVersion = prefs.getString('device_version') ?? '';
    if (deviceVersion.isNotEmpty) {
      ref.read(targetDeviceVersionProvider.notifier).state = deviceVersion;
    }
  }

  Future<void> _handleQrScan() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );

    if (result != null) {
      setState(() => _scannedDeviceName = result);
      _toast('已掃描設備：$result');
    }
  }

  Future<void> _saveDeviceName(String deviceName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_name', deviceName);
  }

  Future<String?> _showDeviceNameDialog() async {
    final controller = TextEditingController(
      text: ref.read(targetDeviceNameProvider),
    );

    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('藍芽裝置設定'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '裝置名稱（必填）',
            hintText: '例如：PSA00163',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isEmpty) {
                _toast('請輸入產品名稱...');
              } else {
                _saveDeviceName(controller.text);
                Navigator.pop(context, controller.text);
              }
            },
            child: const Text('確定'),
          ),
        ],
      ),
    );
  }

  void _showSmoothingDialog() async {
    final result = await showSmoothingDialog(context);
    if (result == null) return;

    // 1) 依結果立刻更新本地狀態 → 直接觸發圖形重建
    setState(() {
      // 對話框的 4 = None；在畫面狀態用 0 表示不套用
      smoothMethod = (result.method == 4) ? 0 : result.method;

      if (result.method == 1 && result.smooth1Order != null) {
        smooth1Order = result.smooth1Order!;
      } else if (result.method == 2) {
        if (result.smooth2Order != null) smooth2Order = result.smooth2Order!;
        if (result.smooth2Error != null) smooth2Error = result.smooth2Error!;
      } else if (result.method == 3) {
        if (result.smooth3TrimN != null)          smooth3TrimN = result.smooth3TrimN!;
        if (result.smooth3TrimC != null)          smooth3TrimC = result.smooth3TrimC!;
        if (result.smooth3TrimDelta != null)      smooth3TrimDelta = result.smooth3TrimDelta!;
        if (result.smooth3UseTrimmedWindow != null) smooth3UseTrimmedWindow = result.smooth3UseTrimmedWindow!;
        if (result.smooth3KalmanN != null)        smooth3KalmanN = result.smooth3KalmanN!;
        if (result.smooth3Kn != null)             smooth3Kn = result.smooth3Kn!;
        if (result.smooth3WeightN != null)        smooth3WeightN = result.smooth3WeightN!;
        if (result.smooth3P != null)              smooth3P = result.smooth3P!;
        if (result.smooth3KeepHeadOriginal != null) smooth3KeepHeadOriginal = result.smooth3KeepHeadOriginal!;
      }
    });

    // 2) 提示
    switch (result.method) {
      case 1:
        _toast('已套用 Smooth 1：Order=${smooth1Order}');
        break;
      case 2:
        _toast('已套用 Smooth 2：Error=${smooth2Error}%、Order=${smooth2Order}');
        break;
      case 3:
        _toast('已套用 Smooth 3');
        break;
      case 4:
        _toast('已關閉平滑');
        break;
    }
  }

  void _showSettingsDialog() async {
    final result = await showSettingsDialog(context);

    if (result != null) {
      if (result.method == 1) {
        _toast('連線模式:BroadCast、slope=${result.slope}、intercept:=${result.intercept}');
      } else {
        _toast('連線模式:Connection、slope=${result.slope}、intercept:=${result.intercept}');
      }
    }
  }

  void _onNavTapped(int index) async {
    setState(() => _navIndex = index);

    switch (index) {
      case 0:
        _handleBleConnection();
        break;
      case 1:
        await _handleQrScan();
        break;
      case 2:
        _showSmoothingDialog();
        break;
      case 3:
        _showSettingsDialog();
        break;
    }
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要權限'),
        content: const Text(
          '藍芽功能需要以下權限：\n\n'
              '• 藍芽掃描\n'
              '• 藍芽連線\n'
              '• 位置資訊（Android 藍芽掃描需要）\n\n'
              '請在設定中授予這些權限。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await openAppSettings();
            },
            child: const Text('前往設定'),
          ),
        ],
      ),
    );
  }

  Future<void> _requestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return;

    debugPrint('🔋 檢查電池優化狀態...');

    final status = await Permission.ignoreBatteryOptimizations.status;

    if (!status.isGranted) {
      // ✅ 更明確的說明
      final shouldRequest = await showDialog<bool>(
        context: context,
        barrierDismissible: false,  // ✅ 不允許點外面關閉
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.battery_alert, color: Colors.orange),
              SizedBox(width: 8),
              Text('重要：電池優化設定'),
            ],
          ),
          content: const SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '⚠️ 檢測到電池優化已啟用',
                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
                ),
                SizedBox(height: 12),
                Text('這會導致以下問題：'),
                Text('• 螢幕關閉後數據停止接收'),
                Text('• Service 被系統終止'),
                Text('• 無法進行 14 天持續監測'),
                SizedBox(height: 12),
                Text(
                  '必須關閉電池優化才能正常運行！',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  '這不會顯著增加耗電，請放心允許。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
              ),
              child: const Text('立即設定'),
            ),
          ],
        ),
      );

      if (shouldRequest == true) {
        final result = await Permission.ignoreBatteryOptimizations.request();

        if (result.isGranted) {
          debugPrint('✅ 電池優化豁免已授予');
          _toast('✅ 電池優化已關閉');
        } else {
          // ❌ 如果被拒絕，顯示手動設定指引
          _showManualBatterySettingsGuide();
        }
      } else {
        // ⚠️ 如果用戶拒絕，警告無法持續運行
        _showBatteryOptimizationWarning();
      }
    } else {
      debugPrint('✅ 電池優化已關閉');
    }
  }

  // ✅ 顯示手動設定指引
  void _showManualBatterySettingsGuide() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要手動設定'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('請按以下步驟手動關閉電池優化：'),
              SizedBox(height: 12),
              Text('1. 點擊下方「前往設定」'),
              Text('2. 找到本 App'),
              Text('3. 選擇「不優化」或「無限制」'),
              SizedBox(height: 12),
              Text(
                '⚠️ 如不設定，螢幕關閉後將停止接收數據',
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await openAppSettings();
            },
            child: const Text('前往設定'),
          ),
        ],
      ),
    );
  }

  // ✅ 警告用戶後果
  void _showBatteryOptimizationWarning() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning, color: Colors.red),
            SizedBox(width: 8),
            Text('警告'),
          ],
        ),
        content: const Text(
          '未關閉電池優化，螢幕關閉後將無法接收數據。\n\n'
              '建議您稍後在「設定 → 電池 → 本 App」中手動關閉優化。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _startServiceMonitoring() async {
    if (!Platform.isAndroid) return;

    _serviceMonitor?.cancel();

    debugPrint('👀 [Android] 開始監控服務狀態...');

    // ✅ 縮短檢查間隔（10秒 → 5秒）
    _serviceMonitor = Timer.periodic(const Duration(seconds: 5), (timer) async {
      final isRunning = await ForegroundBleService.isRunning();
      final shouldBeRunning = ref.read(bleConnectionStateProvider);

      if (!isRunning && shouldBeRunning) {
        debugPrint('⚠️ [Android] 檢測到服務已停止，嘗試重啟...');

        final prefs = await SharedPreferences.getInstance();

        // ✅ 記錄服務停止時間
        final now = DateTime.now();
        await prefs.setString('last_service_stop', now.toIso8601String());

        final modeIndex = prefs.getInt('ble_connection_mode') ?? 0;
        final mode = BleConnectionMode.values[modeIndex];
        final deviceName = prefs.getString('device_name');
        final deviceId = prefs.getString('target_device_id');

        if (deviceName != null && deviceName.isNotEmpty) {
          debugPrint('🔄 [Android] 執行自動重啟...');
          debugPrint('   設備: $deviceName');
          debugPrint('   模式: $mode');
          debugPrint('   時間: $now');

          final success = await ForegroundBleService.start(
            targetDeviceId: deviceId,
            targetDeviceName: deviceName,
            mode: mode,
          );

          if (success) {
            debugPrint('✅ [Android] 服務重啟成功');

            // ✅ 確保 WakeLock 還在
            final isEnabled = await WakelockPlus.enabled;
            if (!isEnabled) {
              await WakelockPlus.enable();
              debugPrint('🔒 重新啟用 WakeLock');
            }

            if (mounted) {
              _toast('藍芽服務已自動重啟');
            }

            // ✅ 記錄重啟成功
            await prefs.setString('last_service_restart', now.toIso8601String());

          } else {
            debugPrint('❌ [Android] 服務重啟失敗');

            if (mounted) {
              _toast('服務重啟失敗，請手動重新連線');
            }

            ref.read(bleConnectionStateProvider.notifier).state = false;
            timer.cancel();
          }
        }
      } else if (isRunning && shouldBeRunning) {
        // ✅ 定期記錄健康檢查
        debugPrint('💚 [Android] 服務運行正常');
      }
    });
  }

  // ✅ 支援 iOS 和 Android 雙模式
  void _handleBleConnection() async {
    final bleService = ref.read(bleServiceProvider);
    final isConnected = ref.read(bleConnectionStateProvider);

    if (isConnected) {
      // ⭐ 進入「正在停止」：先讓 UI 回 idle（也可新增 disconnecting 狀態，這裡簡化）
      ref.read(bleUiStateProvider.notifier).state = BleUiState.idle;
      _spinCtrl.stop();

      _serviceMonitor?.cancel();
      if (Platform.isIOS) {
        await _mainThreadBleSubscription?.cancel();
        _mainThreadBleSubscription = null;
        await bleService.stopScan();
      }

      final success = await ForegroundBleService.stopSafely();
      await WakelockPlus.disable();

      if (success) {
        ref.read(bleConnectionStateProvider.notifier).state = false;
        _toast('已停止藍芽監聽');
      } else {
        _toast('停止服務失敗');
      }
      return;
    }

    // ---- 以下為「開始連線」流程 ----

    // ⭐ UI 先進入 connecting 狀態（顯示動畫）
    ref.read(bleUiStateProvider.notifier).state = BleUiState.connecting;
    _spinCtrl.repeat();

    if (Platform.isAndroid) {
      await _requestBatteryOptimizationExemption();
    }
    await WakelockPlus.enable();

    final hasPermission = await bleService.requestPermissions();
    if (!hasPermission) {
      _toast('藍芽權限不足，請在設定中授予權限');
      _showPermissionDialog();
      // ⭐ 權限失敗 → 回 idle
      ref.read(bleUiStateProvider.notifier).state = BleUiState.idle;
      _spinCtrl.stop();
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final modeIndex = prefs.getInt('ble_connection_mode') ?? 0;
    final mode = BleConnectionMode.values[modeIndex];

    String? deviceName = prefs.getString('device_name');
    String? deviceId = prefs.getString('target_device_id');

    if (deviceName == null || deviceName.isEmpty) {
      deviceName = await _showDeviceNameDialog();
      if (deviceName == null) {
        // ⭐ 使用者取消 → 回 idle
        ref.read(bleUiStateProvider.notifier).state = BleUiState.idle;
        _spinCtrl.stop();
        return;
      }
    }

    if (Platform.isIOS) {
      ref.read(targetDeviceNameProvider.notifier).state = deviceName;
      ref.read(bleConnectionStateProvider.notifier).state = true;
      // iOS 主線程
      if (mode == BleConnectionMode.broadcast) {
        await bleService.startScan(targetName: deviceName, targetId: deviceId);
      } else {
        await bleService.startConnectionMode(deviceId: deviceId ?? '', deviceName: deviceName);
      }
      _setupMainThreadBleListener();
      _toast('藍芽服務已啟動（iOS 模式）：$deviceName');

      // ⭐ 成功 → connected
      ref.read(bleUiStateProvider.notifier).state = BleUiState.connected;
      _spinCtrl.stop();

      final hasShownWarning = prefs.getBool('ios_warning_shown') ?? false;
      if (!hasShownWarning) {
        await prefs.setBool('ios_warning_shown', true);
        _showIosLimitationDialog();
      }
      return;
    }

    // Android 前景服務
    final success = await ForegroundBleService.start(
      targetDeviceId: deviceId,
      targetDeviceName: deviceName,
      mode: mode,
    );

    if (success) {
      ref.read(targetDeviceNameProvider.notifier).state = deviceName;
      ref.read(bleConnectionStateProvider.notifier).state = true;
      _toast('藍芽前景服務已啟動：$deviceName');
      _startServiceMonitoring();

      // ⭐ 成功 → connected
      ref.read(bleUiStateProvider.notifier).state = BleUiState.connected;
      _spinCtrl.stop();
    } else {
      _toast('前景服務啟動失敗');

      // ⭐ 失敗 → 回 idle
      ref.read(bleUiStateProvider.notifier).state = BleUiState.idle;
      _spinCtrl.stop();
    }
  }

  // ✅ iOS 限制說明對話框
  void _showIosLimitationDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.orange),
            SizedBox(width: 8),
            Text('iOS 背景運行說明'),
          ],
        ),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'iOS 系統對背景藍牙有嚴格限制：',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 12),
              Text('✅ App 在前景時：'),
              Text('  • 正常接收數據', style: TextStyle(fontSize: 13)),
              Text('  • 即時更新圖表', style: TextStyle(fontSize: 13)),
              SizedBox(height: 8),
              Text('⚠️ App 在背景時：'),
              Text('  • 掃描頻率降低', style: TextStyle(fontSize: 13)),
              Text('  • 可能隨時被暫停', style: TextStyle(fontSize: 13)),
              SizedBox(height: 8),
              Text('❌ App 被滑掉後：'),
              Text('  • 所有任務停止', style: TextStyle(fontSize: 13)),
              Text('  • 無法繼續收集數據', style: TextStyle(fontSize: 13)),
              SizedBox(height: 12),
              Divider(),
              SizedBox(height: 8),
              Text(
                '📱 使用建議：',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
              Text('• 保持 App 在前景運行', style: TextStyle(fontSize: 13)),
              Text('• 防止螢幕自動鎖定', style: TextStyle(fontSize: 13)),
              Text('• 長時間監測請使用 Android', style: TextStyle(fontSize: 13)),
              SizedBox(height: 12),
              Text(
                '這是 iOS 系統限制，無法通過技術手段繞過。如需 14 天持續監測，請使用 Android 設備。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('我了解了'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 800),
      ),
    );
  }

  @override
  void dispose() {
    _spinCtrl.dispose();

    // ✅ 移除生命週期觀察者
    WidgetsBinding.instance.removeObserver(this);

    // 停止服務監控
    _serviceMonitor?.cancel();

    // ✅ 清理主線程 BLE 訂閱
    _mainThreadBleSubscription?.cancel();

    // ✅ 只在 Android 上清理 Foreground Task callback
    if (Platform.isAndroid) {
      FlutterForegroundTask.removeTaskDataCallback(_handleForegroundData);
    }

    final bleService = ref.read(bleServiceProvider);
    bleService.stopScan();

    super.dispose();
  }

  // ✅ 導航到前一天
  void _navigateToPrevDay(String prevDay) {
    debugPrint('⬅️ 切換到前一天: $prevDay');
    setState(() {
      _dayKey = prevDay;
    });
    _toast('已切換到: $prevDay');
  }

  // ✅ 導航到後一天
  void _navigateToNextDay(String nextDay) {
    debugPrint('➡️ 切換到後一天: $nextDay');
    setState(() {
      _dayKey = nextDay;
    });
    _toast('已切換到: $nextDay');
  }

  // ✅ 選擇日期
  Future<void> _selectDate() async {
    try {
      final currentDate = dayKeyToDate(_dayKey);

      final picked = await showDatePicker(
        context: context,
        initialDate: currentDate,
        firstDate: DateTime(2020),
        lastDate: DateTime.now(),
        helpText: '選擇日期',
        cancelText: '取消',
        confirmText: '確定',
      );

      if (picked != null) {
        final newDayKey = dayKeyOf(picked);
        debugPrint('📅 用戶選擇日期: $newDayKey');

        // 檢查是否有數據
        final repo = await ref.read(repoProvider.future);
        final deviceName = ref.read(targetDeviceNameProvider);
        final allDays = await repo.getAllDaysWithData(deviceName);

        if (allDays.contains(newDayKey)) {
          setState(() {
            _dayKey = newDayKey;
          });
          _toast('已切換到: $newDayKey');
        } else {
          // 即使沒有數據也切換（會顯示空白圖表）
          setState(() {
            _dayKey = newDayKey;
          });
          _toast('$newDayKey\n此日期沒有數據');
        }
      }
    } catch (e) {
      debugPrint('❌ 選擇日期失敗: $e');
      _toast('日期選擇失敗');
    }
  }

  // ✅ 測試資料庫和日期
  Future<void> _testDatabaseAndDates() async {
    try {
      final repo = await ref.read(repoProvider.future);
      final deviceName = ref.read(targetDeviceNameProvider);

      debugPrint('═══════════════════════════════');
      debugPrint('🧪 測試資料庫');
      debugPrint('🧪 設備名稱: $deviceName');
      debugPrint('🧪 當前日期: $_dayKey');

      // 查詢當天數據
      final samples = await repo.queryDay(deviceName, _dayKey);
      debugPrint('🧪 當前日期數據筆數: ${samples.length}');

      if (samples.isNotEmpty) {
        debugPrint('🧪 第一筆時間: ${samples.first.ts}');
        debugPrint('🧪 最後一筆時間: ${samples.last.ts}');
      }

      // 查詢所有有數據的日期
      final allDays = await repo.getAllDaysWithData(deviceName);
      debugPrint('🧪 有數據的日期數量: ${allDays.length}');
      debugPrint('🧪 日期列表: $allDays');

      // 查詢前後日期
      final prev = await repo.prevDayWithData(deviceName, _dayKey);
      final next = await repo.nextDayWithData(deviceName, _dayKey);
      debugPrint('🧪 前一天: $prev');
      debugPrint('🧪 後一天: $next');
      debugPrint('═══════════════════════════════');

      // 顯示對話框
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('資料庫測試結果'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('設備：$deviceName'),
                  const Divider(),
                  Text('當前日期：$_dayKey'),
                  Text('數據筆數：${samples.length}'),
                  const Divider(),
                  Text('總共天數：${allDays.length}'),
                  if (allDays.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('有數據的日期：', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    ...allDays.map((day) => Text('  • $day')),
                  ],
                  const Divider(),
                  Text('前一天：${prev ?? '無'}'),
                  Text('後一天：${next ?? '無'}'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('確定'),
              ),
            ],
          ),
        );
      }

      _toast('測試完成，請查看對話框和控制台');
    } catch (e) {
      debugPrint('❌ 測試失敗: $e');
      _toast('測試失敗: $e');
    }
  }

  // ✅ 調試特定日期的資料庫數據
  Future<void> _debugDatabase(String deviceName, String dayKey) async {
    try {
      final repo = await ref.read(repoProvider.future);

      debugPrint('═══════════════════════════════════════');
      debugPrint('🔍 開始詳細調試');
      debugPrint('🔍 查詢條件：');
      debugPrint('   deviceName: "$deviceName"');
      debugPrint('   dayKey: "$dayKey"');
      debugPrint('═══════════════════════════════════════');

      // 1. 查詢該日期的數據
      final samples = await repo.queryDay(deviceName, dayKey);
      debugPrint('📊 直接查詢結果: ${samples.length} 筆');

      // 2. 查詢該設備所有數據（使用公共方法）
      final allDeviceSamples = await repo.getAllSamplesByDevice(deviceName);
      debugPrint('📊 該設備所有數據: ${allDeviceSamples.length} 筆');

      // 3. 獲取所有設備 ID（使用公共方法）
      final allDeviceIds = await repo.getAllDeviceIds();
      debugPrint('📊 資料庫中所有設備 ID (${allDeviceIds.length} 個):');
      for (final id in allDeviceIds) {
        final count = await repo.getCountByDevice(id);
        debugPrint('   - "$id": $count 筆');
      }

      // 4. 獲取所有日期（使用公共方法）
      final allDayKeys = await repo.getAllDayKeys();
      debugPrint('📊 資料庫中所有日期 (${allDayKeys.length} 個):');
      for (final key in allDayKeys.take(10)) {
        final count = await repo.getCountByDay(key);
        debugPrint('   - "$key": $count 筆');
      }
      if (allDayKeys.length > 10) {
        debugPrint('   ... 還有 ${allDayKeys.length - 10} 個日期');
      }

      // 5. 查詢該日期所有設備的數據（使用公共方法）
      final samplesAllDevices = await repo.getAllSamplesByDay(dayKey);
      debugPrint('📊 該日期 ($dayKey) 所有設備數據: ${samplesAllDevices.length} 筆');

      if (samplesAllDevices.isNotEmpty) {
        debugPrint('📊 該日期的設備列表:');
        final deviceIds = samplesAllDevices.map((s) => s.deviceId).toSet();
        for (final id in deviceIds) {
          final count = samplesAllDevices.where((s) => s.deviceId == id).length;
          debugPrint('   - "$id": $count 筆');
        }
      }

      // 6. 查詢該設備前後的日期（使用公共方法）
      final prev = await repo.prevDayWithData(deviceName, dayKey);
      final next = await repo.nextDayWithData(deviceName, dayKey);
      debugPrint('📊 該設備前一天: $prev');
      debugPrint('📊 該設備後一天: $next');

      // 7. 獲取統計信息（使用公共方法）
      final stats = await repo.getDatabaseStats();
      debugPrint('📊 資料庫統計:');
      debugPrint('   總數據: ${stats['totalCount']}');
      debugPrint('   設備數: ${stats['deviceCount']}');
      debugPrint('   日期數: ${stats['dayCount']}');

      // 8. 獲取診斷報告（使用公共方法）
      final diagnosticInfo = await repo.getDiagnosticInfo();
      debugPrint(diagnosticInfo);

      debugPrint('═══════════════════════════════════════');

      // 顯示詳細報告對話框
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.bug_report, color: Colors.orange),
                SizedBox(width: 8),
                Text('調試報告'),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('查詢條件：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text('  設備：$deviceName'),
                  Text('  日期：$dayKey'),
                  const Divider(height: 20),

                  const Text('查詢結果：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(
                    '  該日期該設備：${samples.length} 筆',
                    style: TextStyle(
                      color: samples.isEmpty ? Colors.red : Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text('  該設備總數據：${allDeviceSamples.length} 筆'),
                  Text('  該日期總數據：${samplesAllDevices.length} 筆'),
                  const Divider(height: 20),

                  const Text('資料庫統計：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text('  總數據：${stats['totalCount']} 筆'),
                  Text('  設備數量：${stats['deviceCount']} 個'),
                  Text('  日期數量：${stats['dayCount']} 個'),
                  const Divider(height: 20),

                  if (allDeviceIds.isNotEmpty) ...[
                    const Text('所有設備 ID：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 4),
                    ...allDeviceIds.map((id) => Padding(
                      padding: const EdgeInsets.only(left: 8, top: 2),
                      child: Text(
                        '• "$id"',
                        style: TextStyle(
                          color: id == deviceName ? Colors.green : Colors.black,
                          fontWeight: id == deviceName ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    )),
                    const Divider(height: 20),
                  ],

                  if (allDayKeys.isNotEmpty) ...[
                    const Text('最近的日期：', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 4),
                    ...allDayKeys.take(10).map((key) => Padding(
                      padding: const EdgeInsets.only(left: 8, top: 2),
                      child: Text(
                        '• "$key"',
                        style: TextStyle(
                          color: key == dayKey ? Colors.green : Colors.black,
                          fontWeight: key == dayKey ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    )),
                    if (allDayKeys.length > 10)
                      Padding(
                        padding: const EdgeInsets.only(left: 8, top: 2),
                        child: Text('  ... 還有 ${allDayKeys.length - 10} 個'),
                      ),
                    const Divider(height: 20),
                  ],

                  if (samplesAllDevices.isNotEmpty) ...[
                    Text('該日期 ($dayKey) 的設備：',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 4),
                    ...samplesAllDevices.map((s) => s.deviceId).toSet().map((id) {
                      final count = samplesAllDevices.where((s) => s.deviceId == id).length;
                      return Padding(
                        padding: const EdgeInsets.only(left: 8, top: 2),
                        child: Text('• "$id": $count 筆'),
                      );
                    }),
                  ],

                  if (samples.isEmpty && (allDeviceSamples.isNotEmpty || samplesAllDevices.isNotEmpty)) ...[
                    const Divider(height: 20),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.orange[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange, width: 1),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.warning, color: Colors.orange, size: 20),
                              SizedBox(width: 8),
                              Text('可能的問題：', style: TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (samplesAllDevices.isEmpty && allDeviceSamples.isNotEmpty)
                            const Text('• 該日期沒有任何設備的數據，但該設備有其他日期的數據'),
                          if (samplesAllDevices.isNotEmpty && samples.isEmpty)
                            const Text('• 該日期有數據，但設備名稱不匹配（請檢查設備名稱的大小寫和空格）'),
                          if (allDeviceSamples.isEmpty)
                            const Text('• 該設備在資料庫中完全沒有數據'),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('關閉'),
              ),
              if (samples.isEmpty && allDeviceSamples.isNotEmpty)
                ElevatedButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    // 跳轉到該設備有數據的最近日期
                    final days = await repo.getAllDaysWithData(deviceName);
                    if (days.isNotEmpty) {
                      setState(() {
                        _dayKey = days.first;
                      });
                      _toast('已切換到該設備最近的日期: ${days.first}');
                    }
                  },
                  child: const Text('跳到最近日期'),
                ),
            ],
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('❌ 調試失敗: $e');
      debugPrint('堆棧: $stack');
      _toast('調試失敗: $e');
    }
  }

  // ✅ 添加清理無效數據的方法
  Future<void> _cleanInvalidData() async {
    try {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning, color: Colors.orange),
              SizedBox(width: 8),
              Text('清理無效數據'),
            ],
          ),
          content: const Text(
            '此操作將刪除資料庫中所有時間戳無效的數據（例如：1970-01-01）。\n\n'
                '無效數據通常是由於系統錯誤或數據損壞產生的。\n\n'
                '確定要繼續嗎？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('確定刪除'),
            ),
          ],
        ),
      );

      if (confirm != true) return;

      _toast('開始清理...');

      final repo = await ref.read(repoProvider.future);
      final deletedCount = await repo.cleanInvalidTimestamps();

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Row(
              children: [
                Icon(
                  deletedCount > 0 ? Icons.check_circle : Icons.info,
                  color: deletedCount > 0 ? Colors.green : Colors.blue,
                ),
                const SizedBox(width: 8),
                const Text('清理完成'),
              ],
            ),
            content: Text(
              deletedCount > 0
                  ? '已刪除 $deletedCount 筆無效數據。\n\n建議重新啟動應用。'
                  : '沒有發現無效數據。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('確定'),
              ),
            ],
          ),
        );
      }

      // 強制刷新畫面
      setState(() {});
    } catch (e, stack) {
      debugPrint('❌ 清理失敗: $e');
      debugPrint('堆棧: $stack');
      _toast('清理失敗: $e');
    }
  }

  // ---- 用 DataSmoother 生成平滑樣本 ----
  List<Sample> buildSmooth1Samples(List<Sample> raw, int order) {
    if (raw.isEmpty) return const [];
    final src = [...raw]..sort((a, b) => a.ts.compareTo(b.ts));
    final smoother = DataSmoother();
    final out = <Sample>[];

    double totalDiff = 0;
    int changedCount = 0;

    for (int i = 0; i < src.length; i++) {
      final s = src[i];

      final currents = s.currents;
      if (currents == null || currents.isEmpty) {
        out.add(s);
        continue;
      }

      final v = currents.first.toDouble();
      smoother.addData(v);

      final sm = smoother.smooth1(order) ?? v;
      final diff = (sm - v).abs();

      if (diff > 1e-15) {
        changedCount++;
        totalDiff += diff;

        if (changedCount <= 10) {
          debugPrint('📊 [Smooth1] 第${i+1}筆: '
              '原始=${v.toStringAsExponential(6)}, '
              '平滑=${sm.toStringAsExponential(6)}, '
              '差值=${diff.toStringAsExponential(6)}, '
              '变化率=${(diff/v.abs()*100).toStringAsFixed(2)}%');
        }
      }

      // 🔧 关键修正：把平滑值存入 currents 列表
      out.add(s.copyWith(
        current: sm,              // 也更新 current 以保持一致
        currents: [sm],           // ✅ 把平滑值存入 currents 列表
      ));
    }

    if (changedCount > 0) {
      debugPrint('📈 [Smooth1] 總計: ${src.length}筆, '
          '有${changedCount}筆被平滑 '
          '(${(changedCount/src.length*100).toStringAsFixed(1)}%), '
          '平均差值=${(totalDiff/changedCount).toStringAsExponential(6)}');
    } else {
      debugPrint('⚠️ [Smooth1] 没有任何数据被平滑！');
    }

    return out;
  }

  List<Sample> buildSmooth2Samples(List<Sample> raw, int order, double errorPercent) {
    if (raw.isEmpty) return const [];

    final src = [...raw]..sort((a, b) => a.ts.compareTo(b.ts));
    final smoother = DataSmoother();
    final out = <Sample>[];

    for (final s in src) {
      final currents = s.currents;
      if (currents == null || currents.isEmpty) {
        out.add(s);
        continue;
      }

      final v = currents.first.toDouble();
      smoother.addData(v);

      final sm = smoother.smooth2(order, errorPercent) ?? v;

      // ✅ 存入 currents 列表
      out.add(s.copyWith(
        current: sm,
        currents: [sm],
      ));
    }
    return out;
  }

  List<Sample> buildSmooth3Samples(List<Sample> raw, {
    required int trimN,
    required double trimC,
    required double trimDelta,
    required bool useTrimmedWindow,
    required int kalmanN,
    required double kn,
    required int weightN,
    required double p,
    required bool keepHeadOriginal,
  }) {
    if (raw.isEmpty) return const [];
    final src = [...raw]..sort((a, b) => a.ts.compareTo(b.ts));

    final smoother = DataSmoother();
    final out = <Sample>[];

    int changedCount = 0;
    int totalCount = 0;

    for (final s in src) {
      final currents = s.currents;
      if (currents == null || currents.isEmpty) {
        out.add(s);
        continue;
      }

      final v = currents.first.toDouble();
      smoother.addData(v);

      final sm = smoother.smooth3(
        trimN: trimN,
        trimC: trimC,
        trimDelta: trimDelta,
        useTrimmedWindow: useTrimmedWindow,
        kalmanN: kalmanN,
        kn: kn,
        weightN: weightN,
        p: p,
        keepHeadOriginal: keepHeadOriginal,
      ) ?? v;

      totalCount++;
      if ((sm - v).abs() > 1e-10) {
        changedCount++;
        if (changedCount <= 5) {
          debugPrint('🔍 [Smooth3] 第 $totalCount 筆: 原始=$v, 平滑=$sm, 差值=${sm - v}');
        }
      }

      // ✅ 存入 currents 列表
      out.add(s.copyWith(
        current: sm,
        currents: [sm],
      ));
    }

    debugPrint('📊 [Smooth3] 總共 $totalCount 筆，有 $changedCount 筆被平滑 (${(changedCount / totalCount * 100).toStringAsFixed(1)}%)');

    return out;
  }

  @override
  Widget build(BuildContext context) {
    // ✅ 監聽版本號
    ref.watch(versionListenerProvider);

    // 讀取 UI 狀態
    final bleUiState = ref.watch(bleUiStateProvider);

    final repoAsync = ref.watch(repoProvider);
    final bleConnected = ref.watch(bleConnectionStateProvider);
    final params = ref.watch(correctionParamsProvider);

    final deviceName = ref.watch(targetDeviceNameProvider);
    final deviceVersion = ref.watch(targetDeviceVersionProvider);

    Widget _buildStatusRow(String label, bool isOk) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              isOk ? Icons.check_circle : Icons.cancel,
              color: isOk ? Colors.green : Colors.red,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      );
    }

    // ✅ 顯示服務狀態
    void _showServiceStatusDialog() async {
      final prefs = await SharedPreferences.getInstance();
      final isRunning = await ForegroundBleService.isRunning();
      final wakeLockEnabled = await WakelockPlus.enabled;
      final batteryOptimization = await Permission.ignoreBatteryOptimizations.status;

      final lastStop = prefs.getString('last_service_stop');
      final lastRestart = prefs.getString('last_service_restart');

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('服務狀態診斷'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStatusRow('前景服務', isRunning),
                  _buildStatusRow('WakeLock', wakeLockEnabled),
                  _buildStatusRow('電池優化豁免', batteryOptimization.isGranted),
                  const Divider(),
                  if (lastStop != null) ...[
                    const Text('最後停止時間：', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text(lastStop, style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 4),
                  ],
                  if (lastRestart != null) ...[
                    const Text('最後重啟時間：', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text(lastRestart, style: const TextStyle(fontSize: 12)),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('關閉'),
              ),
            ],
          ),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.pink,
        centerTitle: true,
        automaticallyImplyLeading: false,
        leading: FutureBuilder<bool>(
          future: WakelockPlus.enabled,
          builder: (context, snapshot) {
            final isEnabled = snapshot.data ?? false;
            return IconButton(
              icon: Icon(
                isEnabled ? Icons.lock_open : Icons.lock,
                color: isEnabled ? Colors.green : Colors.grey,
              ),
              tooltip: isEnabled ? 'WakeLock 已啟用' : 'WakeLock 未啟用',
              onPressed: () {
                _showServiceStatusDialog();
              },
            );
          },
        ),
        title: Stack(
          alignment: Alignment.center,
          children: [
            const Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Potentiostat - CEMS100', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (value) {
                      switch (value) {
                        case 'deviceConfig':
                          _showDeviceNameDialog();
                          break;
                        case 'fileExport':
                          _handleQrScan();
                          break;
                        case 'cleanNunData':
                          _cleanInvalidData();
                          break;
                        case 'testDatabase':
                          _testDatabaseAndDates();
                          break;
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'deviceConfig', child: Text('手動設定量測設備')),
                      PopupMenuItem(value: 'fileExport', child: Text('量測資料匯出')),
                      PopupMenuItem(value: 'cleanNunData', child: Text('清理無效數據')),
                      PopupMenuItem(value: 'testDatabase', child: Text('測試資料庫')),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: repoAsync.when(
          data: (repo) {
            return Column(
              key: ValueKey('main_$_dayKey'),  // ✅ 添加 Key 確保重建
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
                  color: Colors.grey[200],
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.calendar_today, size: 16, color: Colors.blue),
                      const SizedBox(width: 8),
                      Text(
                        '當前日期：$_dayKey',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.blue,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                // ✅ 曲線圖區域
                Expanded(
                  child: StreamBuilder<List<Sample>>(
                    key: ValueKey('chart_$_dayKey'),
                    stream: repo.watchDay(deviceName, _dayKey),
                    builder: (context, snap) {
                      // ✅ 非常詳細的調試輸出
                      debugPrint('═══════════════════════════════════════');
                      debugPrint('📊 [StreamBuilder] 當前狀態：');
                      debugPrint('   dayKey: "$_dayKey"');
                      debugPrint('   deviceName: "$deviceName"');
                      debugPrint('   connectionState: ${snap.connectionState}');
                      debugPrint('   hasData: ${snap.hasData}');
                      debugPrint('   hasError: ${snap.hasError}');

                      if (snap.hasError) {
                        debugPrint('   錯誤: ${snap.error}');
                        debugPrint('   堆棧: ${snap.stackTrace}');
                      }

                      List<Sample> list = snap.data ?? const [];
                      debugPrint('   數據筆數: ${list.length}');


                      // 測試用，產生假資料
                      list.clear();
                      list = mockSamples; // 自動產生的虛擬資料
                      // list = sampleRealData; // 實際量測資料

                      // 依 method 動態產生平滑樣本
                      final smooth1Samples = (smoothMethod == 1)
                          ? buildSmooth1Samples(list, smooth1Order)
                          : const <Sample>[];

                      // 測試用
                      // for (final s in list) {
                      //   print('test123 list: ts=${s.ts}, current=${s.current}, currents=${s.currents}');
                      // }
                      //
                      // for (final s in smooth1Samples) {
                      //   print('test123 smooth1Samples: ts=${s.ts}, current=${s.current}, currents=${s.currents}');
                      // }

                      final smooth2Samples = (smoothMethod == 2)
                          ? buildSmooth2Samples(list, smooth2Order, smooth2Error)
                          : const <Sample>[];

                      final smooth3Samples = (smoothMethod == 3)
                          ? buildSmooth3Samples(
                        list,
                        trimN: smooth3TrimN,
                        trimC: smooth3TrimC,
                        trimDelta: smooth3TrimDelta,
                        useTrimmedWindow: smooth3UseTrimmedWindow,
                        kalmanN: smooth3KalmanN,
                        kn: smooth3Kn,
                        weightN: smooth3WeightN,
                        p: smooth3P,
                        keepHeadOriginal: smooth3KeepHeadOriginal,
                      ): const <Sample>[];

                      LineDataConfig? buildSecondLine() {
                        if (smoothMethod == 1) {
                          return LineDataConfig(
                            id: 'smooth1',
                            label: 'Smooth 1',
                            color: Colors.green,
                            samples: smooth1Samples,
                            slope: params.slope,
                            intercept: params.intercept,
                          );
                        } else if (smoothMethod == 2) {
                          return LineDataConfig(
                            id: 'smooth2',
                            label: 'Smooth 2 (+100)',
                            color: Colors.orange,
                            samples: smooth2Samples,
                            slope: params.slope,
                            intercept: params.intercept + 100.0,
                          );
                        } else if (smoothMethod == 3) {
                          return LineDataConfig(
                            id: 'smooth3',
                            label: 'Smooth 3 (+100)',  // ← 修改標籤，顯示有偏移
                            color: Colors.purple,
                            samples: smooth3Samples,
                            slope: params.slope,
                            intercept: params.intercept + 100.0,  // ← 加上 100 mg/dL 的偏移
                          );
                        }
                        return null;
                      }

                      final secondLine = buildSecondLine();

                      // 只把額外的線放進 additionalLines
                      final additionalLines = <LineDataConfig>[];
                      if (secondLine != null) {
                        additionalLines.add(secondLine);
                      }

                      if (list.isNotEmpty) {
                        debugPrint('   第一筆數據:');
                        debugPrint('     - deviceId: "${list.first.deviceId}"');
                        debugPrint('     - dayKey: "${list.first.dayKey}"');
                        debugPrint('     - timestamp: ${list.first.ts}');
                        debugPrint('   最後一筆數據:');
                        debugPrint('     - deviceId: "${list.last.deviceId}"');
                        debugPrint('     - dayKey: "${list.last.dayKey}"');
                        debugPrint('     - timestamp: ${list.last.ts}');
                      }
                      debugPrint('═══════════════════════════════════════');

                      // 如果沒有數據，顯示提示
                      if (list.isEmpty && snap.connectionState == ConnectionState.active) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.inbox, size: 64, color: Colors.grey),
                              const SizedBox(height: 16),
                              Text(
                                '$_dayKey\n此日期沒有數據',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 16, color: Colors.grey),
                              ),
                              const SizedBox(height: 16),
                              // ✅ 添加調試按鈕
                              ElevatedButton.icon(
                                onPressed: () => _debugDatabase(deviceName, _dayKey),
                                icon: const Icon(Icons.bug_report),
                                label: const Text('調試此日期'),
                              ),
                            ],
                          ),
                        );
                      }

                      return GlucoseChart(
                          dayKey: _dayKey,
                          samples: list,  // 主線使用原始數據
                          slope: params.slope,
                          intercept: params.intercept,
                          additionalLines: additionalLines.isEmpty ? null : additionalLines,
                        );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                // ✅ 日期導航按鈕
                FutureBuilder<List<String?>>(
                  key: ValueKey('nav_$_dayKey'),  // ✅ 添加 Key
                  future: Future.wait<String?>([
                    repo.prevDayWithData(deviceName, _dayKey),
                    repo.nextDayWithData(deviceName, _dayKey),
                  ]),
                  builder: (context, s2) {
                    final prev = s2.hasData ? s2.data![0] : null;
                    final next = s2.hasData ? s2.data![1] : null;

                    debugPrint('📅 [導航] 前一天: $prev');
                    debugPrint('📅 [導航] 後一天: $next');

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // ✅ 前一天按鈕
                          Expanded(
                            child: TextButton.icon(
                              onPressed: prev == null
                                  ? null
                                  : () => _navigateToPrevDay(prev),
                              icon: const Icon(Icons.keyboard_double_arrow_left),
                              label: Text(
                                prev != null ? '前一天\n$prev' : '無更早\n資料',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 11),
                              ),
                              style: TextButton.styleFrom(
                                foregroundColor: prev == null ? Colors.grey : Colors.blue,
                                padding: const EdgeInsets.symmetric(vertical: 8),
                              ),
                            ),
                          ),
                          // ✅ 日期選擇器按鈕
                          IconButton(
                            onPressed: _selectDate,
                            icon: const Icon(Icons.calendar_month, size: 32),
                            tooltip: '選擇日期',
                            color: Colors.blue,
                          ),
                          // ✅ 後一天按鈕
                          Expanded(
                            child: TextButton.icon(
                              onPressed: next == null
                                  ? null
                                  : () => _navigateToNextDay(next),
                              icon: const Icon(Icons.keyboard_double_arrow_right),
                              label: Text(
                                next != null ? '後一天\n$next' : '無更新\n資料',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 11),
                              ),
                              style: TextButton.styleFrom(
                                foregroundColor: next == null ? Colors.grey : Colors.blue,
                                padding: const EdgeInsets.symmetric(vertical: 8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            );
          },
          loading: () => const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('正在初始化資料庫...'),
              ],
            ),
          ),
          error: (e, _) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text('初始化失敗：$e'),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            color: Colors.blue[50],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '設備：${deviceName.isEmpty ? '未輸入設備名稱' : deviceName}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 20),
                Text(
                  '版本：${deviceVersion.isEmpty ? '設備未連接' : deviceVersion}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          BottomNavigationBar(
            backgroundColor: Colors.pink,
            currentIndex: _navIndex,
            type: BottomNavigationBarType.fixed,
            onTap: _onNavTapped,
            selectedItemColor: Colors.white,
            unselectedItemColor: Colors.white,
            items: [
              BottomNavigationBarItem(
                icon: SizedBox(
                  width: 24,
                  height: 24,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim, child: child),
                    child: () {
                      switch (bleUiState) {
                        case BleUiState.idle:
                          // 未連線：藍牙關閉圖示
                          return const Icon(
                            Icons.bluetooth_disabled,
                            key: ValueKey('idle'),
                          );
                        case BleUiState.connecting:
                          // 連線中：轉圈圈動畫（autorenew + RotationTransition）
                          return RotationTransition(
                            key: const ValueKey('connecting'),
                            turns: _spinCtrl,
                            child: const Icon(Icons.autorenew),
                          );
                        case BleUiState.connected:
                          // 已連線：停止鍵
                          return const Icon(
                            Icons.stop_circle,
                            key: ValueKey('connected'),
                          );
                      }
                    }(),
                  ),
                ),
                label: '藍芽',
                tooltip: () {
                  switch (bleUiState) {
                    case BleUiState.idle:
                      return '點擊開始連線';
                    case BleUiState.connecting:
                      return '連線中…';
                    case BleUiState.connected:
                      return '已連線，點擊可停止';
                  }
                }(),
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.qr_code_scanner, color: Colors.white),
                label: '掃瞄',
                tooltip: '掃描裝置 QR Code',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.tune, color: Colors.white),
                label: '平滑',
                tooltip: '平滑處理/濾波設定',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.settings, color: Colors.white),
                label: '設定',
                tooltip: '系統設定',
              ),
            ],
          ),
        ],
      ),
    );
  }
}