import 'dart:async';
import 'dart:io';

import 'package:case100_engeneering_version_v1/features/measure/presentation/providers/correction_params_provider.dart';
import 'package:case100_engeneering_version_v1/features/measure/presentation/providers/device_info_providers.dart';
import 'package:case100_engeneering_version_v1/features/measure/presentation/widgets/settings_dialog.dart';
import 'package:case100_engeneering_version_v1/features/measure/presentation/widgets/smoothing_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../common/utils/date_key.dart';
import '../ble/ble_connection_mode.dart';
import '../data/isar_schemas.dart';
import '../data/measure_repository.dart';
import '../foreground/foreground_ble_service.dart';
import '../screens/qu_scan_screen.dart';
import '../models/ble_device.dart';  // ✅ 加入
import 'measure_detail_screen.dart';
import 'providers/ble_providers.dart';
import 'widgets/glucose_chart.dart';

class MeasureScreen extends ConsumerStatefulWidget {
  const MeasureScreen({super.key});

  @override
  ConsumerState<MeasureScreen> createState() => _MeasureScreenState();
}

// ✅ 加入 WidgetsBindingObserver 監聽生命週期
class _MeasureScreenState extends ConsumerState<MeasureScreen> with WidgetsBindingObserver {
  late String _dayKey;
  int _navIndex = 0;
  String? _scannedDeviceName;
  Timer? _serviceMonitor;

  // ✅ 新增：主線程 BLE 訂閱（iOS 必須，Android 備援）
  StreamSubscription<BleDeviceData>? _mainThreadBleSubscription;

  // ✅ 新增：去重緩存
  final _recentTimestamps = <String, DateTime>{};
  static const _cacheExpireDuration = Duration(seconds: 10);
  static const _maxCacheSize = 200;

  @override
  void initState() {
    super.initState();
    _dayKey = dayKeyOf(DateTime.now());
    _loadScannedDevice();
    _loadDeviceInfo();
    _setupDataCallback();
    _initForegroundService();
    _checkForegroundServiceStatus();

    // ✅ 監聽 App 生命週期
    WidgetsBinding.instance.addObserver(this);
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

  void _setupDataCallback() {
    debugPrint('🔧 [UI] 設置 data callback...');

    // ✅ 只在 Android 上設置 Foreground Task callback
    if (Platform.isAndroid) {
      FlutterForegroundTask.removeTaskDataCallback(_handleForegroundData);
      FlutterForegroundTask.addTaskDataCallback(_handleForegroundData);
      debugPrint('✅ [Android] data callback 設置完成');
    } else {
      debugPrint('ℹ️ [iOS] 跳過 foreground task callback');
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

  Future<void> _initForegroundService() async {
    await ForegroundBleService.init();

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

    if (result != null) {
      if (result.method == 1) {
        _toast('已套用 Smooth 1：Order=${result.smooth1Order}');
      } else {
        _toast('已套用 Smooth 2：Error=${result.smooth2Error}%、Order=${result.smooth2Order}');
      }
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
    if (!Platform.isAndroid) {
      debugPrint('ℹ️ [iOS] 不需要電池優化豁免');
      return;
    }

    debugPrint('🔋 [Android] 檢查電池優化狀態...');

    final status = await Permission.ignoreBatteryOptimizations.status;

    if (!status.isGranted) {
      debugPrint('⚠️ [Android] 需要請求電池優化豁免');

      final shouldRequest = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('電池優化設定'),
          content: const Text(
            '為了讓藍芽服務能持續運行（最長 14 天），需要關閉電池優化。\n\n'
                '這不會大幅增加耗電，但能確保服務不被系統終止。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('允許'),
            ),
          ],
        ),
      );

      if (shouldRequest == true) {
        final result = await Permission.ignoreBatteryOptimizations.request();
        if (result.isGranted) {
          debugPrint('✅ [Android] 電池優化豁免已授予');
          _toast('已關閉電池優化');
        } else {
          debugPrint('❌ [Android] 電池優化豁免被拒絕');
          _toast('建議關閉電池優化以確保服務穩定運行');
        }
      }
    } else {
      debugPrint('✅ [Android] 電池優化已關閉');
    }
  }

  void _startServiceMonitoring() {
    if (!Platform.isAndroid) return;

    _serviceMonitor?.cancel();

    debugPrint('👀 [Android] 開始監控服務狀態...');

    _serviceMonitor = Timer.periodic(const Duration(seconds: 10), (timer) async {
      final isRunning = await ForegroundBleService.isRunning();
      final shouldBeRunning = ref.read(bleConnectionStateProvider);

      if (!isRunning && shouldBeRunning) {
        debugPrint('⚠️ [Android] 檢測到服務已停止，嘗試重啟...');

        final prefs = await SharedPreferences.getInstance();
        final wasTerminated = prefs.getBool('service_terminated') ?? false;

        if (wasTerminated) {
          debugPrint('🔄 [Android] 服務被系統終止，執行重啟...');
          await prefs.setBool('service_terminated', false);

          final modeIndex = prefs.getInt('ble_connection_mode') ?? 0;
          final mode = BleConnectionMode.values[modeIndex];
          final deviceName = prefs.getString('device_name');
          final deviceId = prefs.getString('target_device_id');

          if (deviceName != null && deviceName.isNotEmpty) {
            final success = await ForegroundBleService.start(
              targetDeviceId: deviceId,
              targetDeviceName: deviceName,
              mode: mode,
            );

            if (success) {
              debugPrint('✅ [Android] 服務重啟成功');
              _toast('藍芽服務已自動重啟');
            } else {
              debugPrint('❌ [Android] 服務重啟失敗');
              _toast('服務重啟失敗，請手動重新連線');
              ref.read(bleConnectionStateProvider.notifier).state = false;
              timer.cancel();
            }
          }
        }
      }
    });
  }

  // ✅ 修改：支援 iOS 和 Android 雙模式
  void _handleBleConnection() async {
    final bleService = ref.read(bleServiceProvider);
    final isConnected = ref.read(bleConnectionStateProvider);

    if (isConnected) {
      // 停止服務
      _serviceMonitor?.cancel();

      // ✅ iOS：停止主線程監聽
      if (Platform.isIOS) {
        await _mainThreadBleSubscription?.cancel();
        _mainThreadBleSubscription = null;
        await bleService.stopScan();
        debugPrint('🍎 [iOS] 已停止主線程 BLE 監聽');
      }

      final success = await ForegroundBleService.stopSafely();

      if (success) {
        ref.read(bleConnectionStateProvider.notifier).state = false;
        _toast('已停止藍芽監聽');
        debugPrint('✅ 已停止藍芽監聽');
      } else {
        _toast('停止服務失敗');
      }
    } else {
      // 啟動服務

      // ✅ Android：請求電池優化豁免
      if (Platform.isAndroid) {
        await _requestBatteryOptimizationExemption();
      }

      debugPrint('📋 開始請求藍芽權限...');
      final hasPermission = await bleService.requestPermissions();

      if (!hasPermission) {
        _toast('藍芽權限不足，請在設定中授予權限');
        debugPrint('❌ 藍芽權限未全數授予');
        _showPermissionDialog();
        return;
      }

      debugPrint('✅ 藍芽權限已授予');

      final prefs = await SharedPreferences.getInstance();
      final modeIndex = prefs.getInt('ble_connection_mode') ?? 0;
      final mode = BleConnectionMode.values[modeIndex];

      String? deviceName = prefs.getString('device_name');
      String? deviceId = prefs.getString('target_device_id');

      if (deviceName == null || deviceName.isEmpty) {
        deviceName = await _showDeviceNameDialog();
        if (deviceName == null) return;
      }

      // ✅ iOS：使用主線程模式
      if (Platform.isIOS) {
        debugPrint('🍎 [iOS] 啟動主線程 BLE 模式');

        ref.read(targetDeviceNameProvider.notifier).state = deviceName;
        ref.read(bleConnectionStateProvider.notifier).state = true;

        // 啟動 BLE 掃描或連線
        if (mode == BleConnectionMode.broadcast) {
          await bleService.startScan(
            targetName: deviceName,
            targetId: deviceId,
          );
        } else {
          await bleService.startConnectionMode(
            deviceId: deviceId ?? '',
            deviceName: deviceName,
          );
        }

        // 啟動主線程監聽
        _setupMainThreadBleListener();

        _toast('藍芽服務已啟動（iOS 模式）：$deviceName');
        debugPrint('✅ [iOS] 藍芽服務已啟動（主線程模式）');

        // ✅ 首次使用時顯示 iOS 限制說明
        final hasShownWarning = prefs.getBool('ios_warning_shown') ?? false;
        if (!hasShownWarning) {
          await prefs.setBool('ios_warning_shown', true);
          _showIosLimitationDialog();
        }

        return;
      }

      // ✅ Android：使用前景服務
      final modeText = mode == BleConnectionMode.broadcast ? '廣播' : '連線';
      debugPrint('🤖 [Android] 準備啟動前景服務：模式=$modeText, 設備=$deviceName');

      final success = await ForegroundBleService.start(
        targetDeviceId: deviceId,
        targetDeviceName: deviceName,
        mode: mode,
      );

      if (success) {
        ref.read(targetDeviceNameProvider.notifier).state = deviceName;
        ref.read(bleConnectionStateProvider.notifier).state = true;
        _toast('藍芽前景服務已啟動（$modeText 模式）：$deviceName');
        debugPrint('✅ [Android] 藍芽前景服務已啟動');
        _startServiceMonitoring();
      } else {
        _toast('前景服務啟動失敗');
        debugPrint('❌ [Android] 前景服務啟動失敗');
      }
    }
  }

  // ✅ 新增：iOS 限制說明對話框
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

  @override
  Widget build(BuildContext context) {
    final repoAsync = ref.watch(repoProvider);
    final bleConnected = ref.watch(bleConnectionStateProvider);
    final params = ref.watch(correctionParamsProvider);

    final deviceName = ref.watch(targetDeviceNameProvider);
    final deviceVersion = ref.watch(targetDeviceVersionProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.pink,
        centerTitle: true,
        automaticallyImplyLeading: false,
        title: Stack(
          alignment: Alignment.center,
          children: [
            const Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Potentiostat - CEMS100', style: TextStyle(color: Colors.white),),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  switch (value) {
                    case 'deviceConfig':
                      _showDeviceNameDialog();
                      break;
                    case 'fileExport':
                      _handleQrScan();
                      break;
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'deviceConfig', child: Text('手動設定量測設備')),
                  PopupMenuItem(value: 'fileExport', child: Text('量測資料匯出')),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: repoAsync.when(
          data: (repo) {
            final dayStream = repo.watchDay(
              ref.read(targetDeviceNameProvider.notifier).state,
              _dayKey,
            );
            return StreamBuilder<List<Sample>>(
              stream: dayStream,
              builder: (context, snap) {
                final list = snap.data ?? const [];
                return Column(
                  children: [
                    SizedBox(height: 10,),
                    Expanded(
                      child: GlucoseChart(
                        samples: list,
                        slope: params.slope,
                        intercept: params.intercept,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FutureBuilder<List<String?>>(
                      key: ValueKey(_dayKey),
                      future: Future.wait<String?>([
                        repo.prevDayWithData(
                          ref.read(targetDeviceNameProvider.notifier).state,
                          _dayKey,
                        ),
                        repo.nextDayWithData(
                          ref.read(targetDeviceNameProvider.notifier).state,
                          _dayKey,
                        ),
                      ]),
                      builder: (context, s2) {
                        final prev = s2.hasData ? s2.data![0] : null;
                        final next = s2.hasData ? s2.data![1] : null;
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            TextButton.icon(
                              onPressed: prev == null
                                  ? null
                                  : () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => MeasureDetailScreen(
                                      deviceId: ref.read(targetDeviceNameProvider.notifier).state,
                                      dayKey: prev,
                                    ),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.keyboard_double_arrow_left),
                              label: const Text(''),
                            ),
                            IconButton(
                              onPressed: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: DateTime.now(),
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime(2100),
                                );
                                if (picked != null) {
                                  setState(() {
                                    _dayKey = dayKeyOf(picked);
                                  });
                                }
                              },
                              icon: const Icon(Icons.calendar_month),
                              tooltip: '選擇日期',
                            ),
                            TextButton.icon(
                              onPressed: next == null
                                  ? null
                                  : () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => MeasureDetailScreen(
                                      deviceId: ref.read(targetDeviceNameProvider.notifier).state,
                                      dayKey: next,
                                    ),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.keyboard_double_arrow_right),
                              label: const Text(''),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                );
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('初始化失敗：$e')),
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
            selectedItemColor: Colors.white,      // 選中時 icon + label 變白色
            unselectedItemColor: Colors.white,  // 未選中時 icon + label 淡白
            items: [
              BottomNavigationBarItem(
                icon: Icon(
                  bleConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: bleConnected ? Colors.green : Colors.white,
                  size: 20,
                ),
                label: '藍芽',
                tooltip: '藍芽連線/裝置管理',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.qr_code_scanner, color: Colors.white,),
                label: '掃瞄',
                tooltip: '掃描裝置 QR Code',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.tune, color: Colors.white,),
                label: '平滑',
                tooltip: '平滑處理/濾波設定',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.settings, color: Colors.white,),
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