import 'package:case100_engeneering_version_v1/features/measure/presentation/providers/correction_params_provider.dart';
import 'package:case100_engeneering_version_v1/features/measure/presentation/providers/device_info_providers.dart';
import 'package:case100_engeneering_version_v1/features/measure/presentation/widgets/settings_dialog.dart';
import 'package:case100_engeneering_version_v1/features/measure/presentation/widgets/smoothing_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../common/utils/date_key.dart';
import '../data/isar_schemas.dart';
import '../data/measure_repository.dart';
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


  @override
  void initState() {
    super.initState();
    _dayKey = dayKeyOf(DateTime.now());
    _loadScannedDevice(); // 載入已掃描的設備
    _loadDeviceInfo();
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

  @override
  Widget build(BuildContext context) {
    final repoAsync = ref.watch(repoProvider);
    final bleConnected = ref.watch(bleConnectionStateProvider);
    final params = ref.watch(correctionParamsProvider);

    // ✅ 監聽版本號更新
    ref.listen(bleDeviceVersionStreamProvider, (previous, next) {
      next.whenData((version) {
        if (version.isNotEmpty) {
          ref.read(targetDeviceVersionProvider.notifier).state = version;
          debugPrint('✅ UI 版本號已更新：$version');
        }
      });
    });

    // ✅ 監聽 BLE 數據流
    ref.listen(bleDeviceDataStreamProvider, (previous, next) {
      next.whenData((data) async {
        debugPrint('📊 收到 BLE 數據：\n'
            '電壓=${data.voltage}V,\n'
            '溫度=${data.temperature}°C,\n'
            '電流數=${data.currents.length},\n'
            '電流=${data.currents},\n'
            '時間=${data.timestamp},\n'
            'RAW DATA=${data.rawData}\n');


        // 獲取 repository
        final repo = await ref.read(repoProvider.future);

        // 轉換並儲存資料
        if (data.timestamp != null &&
            data.timestamp!.year == DateTime.now().year &&
            data.currents.isNotEmpty) {
          final sample = makeSampleFromBle(
            deviceId: ref.read(targetDeviceNameProvider.notifier).state,
            timestamp: data.timestamp!,
            currents: data.currents,
            voltage: data.voltage,
            temperature: data.temperature,
          );

          debugPrint('sampleAA: $sample');

          try {
            await repo.addSample(sample);
            debugPrint('✅ 資料已寫入：時間=${sample.ts}, 電流筆數=${sample.currents?.length}');
          } catch (e) {
            debugPrint('❌ 寫入失敗：$e');
          }
        }
      });
    });

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
                  PopupMenuItem(value: 'deviceConfig', child: Text('手動設定設備')),
                  PopupMenuItem(value: 'fileExport', child: Text('檔案匯出')),
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

  void _handleBleConnection() async {
    final bleService = ref.read(bleServiceProvider);
    final isConnected = ref.read(bleConnectionStateProvider);

    if (isConnected) {
      // 停止掃描
      await bleService.stopScan();
      ref.read(bleConnectionStateProvider.notifier).state = false;
      _toast('已停止藍芽掃描');
      debugPrint('已停止藍芽掃描');
    } else {
      // 先檢查 SharedPreferences 是否有儲存的設備名稱
      final prefs = await SharedPreferences.getInstance();
      String? deviceName = prefs.getString('device_name');

      // 如果沒有儲存的設備名稱，則顯示對話框
      if (deviceName == null || deviceName.isEmpty) {
        deviceName = await _showDeviceNameDialog();
        if (deviceName == null) return; // 使用者取消了對話框
      }

      // 使用設備名稱開始掃描
      ref.read(targetDeviceNameProvider.notifier).state = deviceName;
      await bleService.startScan(targetName: deviceName.isEmpty ? null : deviceName);
      ref.read(bleConnectionStateProvider.notifier).state = true;
      _toast('開始藍芽掃描${deviceName.isEmpty ? '' : '：$deviceName'}');
      debugPrint('開始藍芽掃描${deviceName.isEmpty ? '' : '：$deviceName'}');
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
    // 停止 BLE 掃描
    final bleService = ref.read(bleServiceProvider);
    bleService.stopScan();
    super.dispose();
  }
}