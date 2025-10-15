import 'dart:async';

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
import '../foreground/foreground_ble_service.dart';
import '../screens/qu_scan_screen.dart';
import 'measure_detail_screen.dart';
import 'providers/ble_providers.dart';
import 'widgets/glucose_chart.dart';

class MeasureScreen extends ConsumerStatefulWidget {
  const MeasureScreen({super.key});

  @override
  ConsumerState<MeasureScreen> createState() => _MeasureScreenState();
}

class _MeasureScreenState extends ConsumerState<MeasureScreen> {
  late String _dayKey;
  int _navIndex = 0;
  String? _scannedDeviceName; // 儲存掃描的設備名稱
  Timer? _serviceMonitor;  // 服務監控計時器


  @override
  void initState() {
    super.initState();
    _dayKey = dayKeyOf(DateTime.now());
    _loadScannedDevice(); // 載入已掃描的設備
    _loadDeviceInfo();

    // ✅ 使用 addTaskDataCallback 而不是直接監聽 receivePort
    _setupDataCallback();

    _initForegroundService();
    _checkForegroundServiceStatus(); // 檢查前景服務狀態
  }

  void _setupDataCallback() {
    debugPrint('🔧 [UI] 設置 data callback...');

    // 移除之前可能存在的回調
    FlutterForegroundTask.removeTaskDataCallback(_handleForegroundData);

    // 添加新的回調
    FlutterForegroundTask.addTaskDataCallback(_handleForegroundData);

    debugPrint('✅ [UI] data callback 設置完成');
  }

  // ✅ 處理來自 foreground service 的數據
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

            // 更新狀態
            if (mounted) {
              setState(() {
                ref.read(targetDeviceVersionProvider.notifier).state = version;
              });
            }
          }
          break;

        case 'stopping':
          FgGuards.stopping = true;
          break;

        case 'heartbeat':
        // 處理心跳
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

  // ✅ 初始化前景服務方法
  Future<void> _initForegroundService() async {
    await ForegroundBleService.init();

    // 檢查服務是否已在運行
    final isRunning = await ForegroundBleService.isRunning();
    if (isRunning) {
      ref.read(bleConnectionStateProvider.notifier).state = true;
    }
  }

  // 檢查前景服務狀態
  Future<void> _checkForegroundServiceStatus() async {
    final isRunning = await ForegroundBleService.isRunning();
    if (isRunning) {
      ref.read(bleConnectionStateProvider.notifier).state = true;
      _toast('前景服務運行中');
    }
  }

  // 載入已掃描的設備名稱
  Future<void> _loadScannedDevice() async {
    final prefs = await SharedPreferences.getInstance();
    final deviceName = prefs.getString('scanned_device_name');
    if (deviceName != null) {
      setState(() => _scannedDeviceName = deviceName);
    }
  }

  // ✅ 載入設備資訊
  Future<void> _loadDeviceInfo() async {
    final prefs = await SharedPreferences.getInstance();

    // 載入設備名稱
    final deviceName = prefs.getString('device_name') ?? '';
    if (deviceName.isNotEmpty) {
      ref.read(targetDeviceNameProvider.notifier).state = deviceName;
    }

    // 載入設備版本
    final deviceVersion = prefs.getString('device_version') ?? '';
    if (deviceVersion.isNotEmpty) {
      ref.read(targetDeviceVersionProvider.notifier).state = deviceVersion;
    }
  }

  // 處理 QR 掃描
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
      text: ref.read(targetDeviceNameProvider.notifier).state,
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
      case 0: // 藍芽
        _handleBleConnection();
        break;

      case 1: // QR Code 掃瞄
        await _handleQrScan();
        break;

      case 2: // 平滑處理
        _showSmoothingDialog();
        break;

      case 3: // 設定
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
              // 開啟應用設定頁面
              await openAppSettings();
            },
            child: const Text('前往設定'),
          ),
        ],
      ),
    );
  }

  // ✅ 請求電池優化豁免
  Future<void> _requestBatteryOptimizationExemption() async {
    debugPrint('🔋 檢查電池優化狀態...');

    final status = await Permission.ignoreBatteryOptimizations.status;

    if (!status.isGranted) {
      debugPrint('⚠️ 需要請求電池優化豁免');

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
          debugPrint('✅ 電池優化豁免已授予');
          _toast('已關閉電池優化');
        } else {
          debugPrint('❌ 電池優化豁免被拒絕');
          _toast('建議關閉電池優化以確保服務穩定運行');
        }
      }
    } else {
      debugPrint('✅ 電池優化已關閉');
    }
  }

  // 啟動服務監控，自動重啟
  void _startServiceMonitoring() {
    _serviceMonitor?.cancel();

    debugPrint('👀 [UI] 開始監控服務狀態...');

    _serviceMonitor = Timer.periodic(const Duration(seconds: 10), (timer) async {
      final isRunning = await ForegroundBleService.isRunning();
      final shouldBeRunning = ref.read(bleConnectionStateProvider);

      if (!isRunning && shouldBeRunning) {
        debugPrint('⚠️ [UI] 檢測到服務已停止，嘗試重啟...');

        // 檢查是否是被系統終止
        final prefs = await SharedPreferences.getInstance();
        final wasTerminated = prefs.getBool('service_terminated') ?? false;

        if (wasTerminated) {
          debugPrint('🔄 [UI] 服務被系統終止，執行重啟...');
          await prefs.setBool('service_terminated', false);

          // 重新啟動服務
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
              debugPrint('✅ [UI] 服務重啟成功');
              _toast('藍芽服務已自動重啟');
            } else {
              debugPrint('❌ [UI] 服務重啟失敗');
              _toast('服務重啟失敗，請手動重新連線');
              ref.read(bleConnectionStateProvider.notifier).state = false;
              timer.cancel();
            }
          }
        }
      }
    });
  }

  void _handleBleConnection() async {
    final bleService = ref.read(bleServiceProvider);
    final isConnected = ref.read(bleConnectionStateProvider);

    if (isConnected) {
      // ✅ 停止監控
      _serviceMonitor?.cancel();

      // 停止前景服務
      final success = await ForegroundBleService.stopSafely();

      if (success) {
        ref.read(bleConnectionStateProvider.notifier).state = false;
        _toast('已停止藍芽監聽');
        debugPrint('已停止藍芽監聽');
      } else {
        _toast('停止服務失敗');
      }
    } else {
      // ✅ 步驟 1：請求電池優化豁免
      await _requestBatteryOptimizationExemption();

      // ✅ 步驟 2：先在主線程中請求權限
      debugPrint('📋 開始請求藍芽權限...');
      final hasPermission = await bleService.requestPermissions();

      if (!hasPermission) {
        _toast('藍芽權限不足，請在設定中授予權限');
        debugPrint('❌ 藍芽權限未全數授予');
        _showPermissionDialog();
        return;
      }

      debugPrint('✅ 藍芽權限已授予');

      // ✅ 步驟 3：讀取連線模式和設備資訊
      final prefs = await SharedPreferences.getInstance();
      final modeIndex = prefs.getInt('ble_connection_mode') ?? 0;
      final mode = BleConnectionMode.values[modeIndex];

      String? deviceName = prefs.getString('device_name');
      String? deviceId = prefs.getString('target_device_id');

      if (deviceName == null || deviceName.isEmpty) {
        deviceName = await _showDeviceNameDialog();
        if (deviceName == null) return;
      }

      final modeText = mode == BleConnectionMode.broadcast ? '廣播' : '連線';
      debugPrint('🎯 準備啟動前景服務：模式=$modeText, 設備=$deviceName');

      // ✅ 步驟 4：啟動前景服務
      final success = await ForegroundBleService.start(
        targetDeviceId: deviceId,
        targetDeviceName: deviceName,
        mode: mode,
      );

      if (success) {
        ref.read(targetDeviceNameProvider.notifier).state = deviceName;
        ref.read(bleConnectionStateProvider.notifier).state = true;
        _toast('藍芽前景服務已啟動（$modeText 模式）：$deviceName');
        debugPrint('✅ 藍芽前景服務已啟動');

        // ✅ 步驟 5：啟動服務監控
        _startServiceMonitoring();
      } else {
        _toast('前景服務啟動失敗');
        debugPrint('❌ 前景服務啟動失敗');
      }
    }
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
    // ✅ 停止服務監控
    _serviceMonitor?.cancel();

    // ✅ 清理回調
    FlutterForegroundTask.removeTaskDataCallback(_handleForegroundData);

    // ✅ 停止 BLE 掃描
    final bleService = ref.read(bleServiceProvider);
    bleService.stopScan();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repoAsync = ref.watch(repoProvider);
    final bleConnected = ref.watch(bleConnectionStateProvider);
    final params = ref.watch(correctionParamsProvider);

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        automaticallyImplyLeading: false,
        title: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Potentiostat - CEMS100'),
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
            final dayStream = repo.watchDay(ref.read(targetDeviceNameProvider.notifier).state, _dayKey);
            return StreamBuilder<List<Sample>>(
              stream: dayStream,
              builder: (context, snap) {
                final list = snap.data ?? const [];
                return Column(
                  children: [
                    Expanded(
                      child: GlucoseChart(
                        samples: list,
                        slope: params.slope,
                        intercept: params.intercept,
                      ), //曲線圖,
                    ),
                    const SizedBox(height: 8),
                    FutureBuilder<List<String?>>(
                      key: ValueKey(_dayKey), // 在 _dayKey 改變時重新創建
                      future:Future.wait<String?>([  // ✅ 直接創建 future，不需要緩存
                        repo.prevDayWithData(ref.read(targetDeviceNameProvider.notifier).state, _dayKey),
                        repo.nextDayWithData(ref.read(targetDeviceNameProvider.notifier).state, _dayKey),
                      ]),
                      builder: (context, s2) {
                        // 即使沒有數據也顯示按鈕（只是禁用）
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
          // 顯示掃描的設備名稱
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            color: Colors.blue[50],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '設備：${
                      ref.watch(targetDeviceNameProvider).isEmpty ?
                      '未輸入設備名稱':ref.watch(targetDeviceNameProvider)
                  }',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(width: 20,),
                Text(
                  '版本：${
                      ref.watch(targetDeviceVersionProvider).isEmpty ?
                      '設備未連接':ref.watch(targetDeviceVersionProvider)
                  }',
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
            currentIndex: _navIndex,
            type: BottomNavigationBarType.fixed,
            onTap: _onNavTapped,
            items: [
              BottomNavigationBarItem(
                icon: Icon(
                  bleConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: bleConnected ? Colors.green : Colors.grey,
                  size: 20,
                ),
                label: '藍芽',
                tooltip: '藍芽連線/裝置管理',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.qr_code_scanner),
                label: '掃瞄',
                tooltip: '掃描裝置 QR Code',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.tune),
                label: '平滑',
                tooltip: '平滑處理/濾波設定',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.settings),
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