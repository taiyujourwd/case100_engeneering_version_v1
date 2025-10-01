// lib/features/measure/screens/measure_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../common/utils/date_key.dart';
import '../data/isar_schemas.dart';
import '../providers.dart';
import 'widgets/glucose_chart.dart';
import 'measure_detail_screen.dart';

class MeasureScreen extends ConsumerStatefulWidget {
  final String deviceId;
  const MeasureScreen({super.key, required this.deviceId});

  @override
  ConsumerState<MeasureScreen> createState() => _MeasureScreenState();
}

class _MeasureScreenState extends ConsumerState<MeasureScreen> {
  late String _dayKey;
  int _navIndex = 0;

  @override
  void initState() {
    super.initState();
    _dayKey = dayKeyOf(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    final repoAsync = ref.watch(repoProvider);
    print("test123 repoAsync: $repoAsync");
    final bleConnected = ref.watch(bleConnectionStateProvider);

    // 監聽 BLE 數據流
    ref.listen(bleDeviceDataStreamProvider, (previous, next) {
      next.whenData((data) {
        debugPrint('📊 收到 BLE 數據：'
            '電壓=${data.voltage}V, '
            '溫度=${data.temperature}°C, '
            '電流數=${data.currents.length}, '
            '電流=${data.currents}'
            '時間=${data.timestamp},'
            'RAW DATA=${data.rawData}');
        // TODO: 將數據寫入 repository
        // 例如: ref.read(repoProvider).value?.addSample(...)
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
                  const SizedBox(width: 8),
                  // BLE 連線狀態指示器
                  Icon(
                    bleConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                    color: bleConnected ? Colors.green : Colors.grey,
                    size: 20,
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  switch (value) {
                    case 'ble':
                      _handleBleConnection();
                      break;
                    case 'qr':
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('QR 掃瞄')),
                      );
                      break;
                    case 'smooth':
                      _showSmoothingSheet();
                      break;
                    case 'settings':
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('設定')),
                      );
                      break;
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'ble', child: Text('藍芽連線')),
                  PopupMenuItem(value: 'qr', child: Text('QR Code 掃瞄')),
                  PopupMenuItem(value: 'smooth', child: Text('平滑處理')),
                  PopupMenuItem(value: 'settings', child: Text('設定')),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: repoAsync.when(
          data: (repo) {
            final dayStream = repo.watchDay(widget.deviceId, _dayKey);
            return StreamBuilder<List<Sample>>(
              stream: dayStream,
              builder: (context, snap) {
                final list = snap.data ?? const [];
                return Column(
                  children: [
                    Expanded(
                      child: InteractiveViewer(
                        child: GlucoseChart(samples: list),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FutureBuilder<List<String?>>(  // 明確指定泛型型別
                      future: Future.wait<String?>([  // 給 Future.wait 加上泛型
                        repo.prevDayWithData(widget.deviceId, _dayKey),
                        repo.nextDayWithData(widget.deviceId, _dayKey),
                      ]),
                      builder: (context, s2) {
                        if (!s2.hasData) return const SizedBox(height: 48);
                        final prev = s2.data![0];  // 不需要 as String? 因為已經有型別了
                        final next = s2.data![1];
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
                                      deviceId: widget.deviceId,
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
                                      deviceId: widget.deviceId,
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
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _navIndex,
        type: BottomNavigationBarType.fixed,
        onTap: _onNavTapped,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.bluetooth),
            label: '藍芽',
            tooltip: '藍芽連線/裝置管理',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.qr_code_scanner),
            label: '掃瞄',
            tooltip: '掃描裝置 QR Code',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.tune),
            label: '平滑',
            tooltip: '平滑處理/濾波設定',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: '設定',
            tooltip: '系統設定',
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
        _toast('開啟 QR Code 掃瞄');
        break;

      case 2: // 平滑處理
        _showSmoothingSheet();
        break;

      case 3: // 設定
        _toast('開啟設定');
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
    } else {
      // 顯示裝置名稱輸入對話框
      final deviceName = await _showDeviceNameDialog();
      if (deviceName != null) {
        ref.read(targetDeviceNameProvider.notifier).state = deviceName;
        await bleService.startScan(targetName: deviceName.isEmpty ? null : deviceName);
        ref.read(bleConnectionStateProvider.notifier).state = true;
        _toast('開始藍芽掃描${deviceName.isEmpty ? '' : '：$deviceName'}');
      }
    }
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
            labelText: '裝置名稱（選填）',
            hintText: '例如：PSA00163',
            helperText: '留空以掃描所有裝置',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text),
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

  void _showSmoothingSheet() {
    showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (ctx) {
          double alpha = 0.2;
          int window = 5;
          return StatefulBuilder(
              builder: (context, setState) {
                return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                      const Text(
                      '平滑處理設定',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                        const Text('指數平滑 α'),
                    Slider(
                      value: alpha,
                      min: 0.0,
                      max: 1.0,
                      divisions: 100,
                      label: alpha.toStringAsFixed(2),
                      onChanged: (v) => setState(() => alpha = v),
                    ),
                        ],
                    ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('移動平均視窗'),
                            Slider(
                              value: window.toDouble(),
                              min: 3,
                              max: 21,
                              divisions: 9,
                              label: window.toString(),
                              onChanged: (v) => setState(() => window = v.round()),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('取消'),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed: () {
                                // TODO: 將參數寫入狀態管理
                                Navigator.pop(context);
                                _toast('已套用平滑：α=${alpha.toStringAsFixed(2)}、視窗=$window');
                              },
                              child: const Text('套用'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                );
              },
          );
        },
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