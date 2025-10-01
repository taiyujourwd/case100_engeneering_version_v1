import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../common/utils/date_key.dart';
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

  // 底部導覽列狀態
  int _navIndex = 0;

  @override
  void initState() {
    super.initState();
    _dayKey = dayKeyOf(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    final repoAsync = ref.watch(repoProvider);
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        // 不用 leading / actions，避免影響置中計算
        automaticallyImplyLeading: false,
        title: Stack(
          alignment: Alignment.center,
          children: [
            const Center(
              child: Text('Potentiostat - CEMS100'),
            ),
            // 左側直向三點 + 選單（不轉頁）
            Align(
              alignment: Alignment.centerRight,
              child: PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  switch (value) {
                    case 'ble':
                    // TODO: 觸發藍牙連線面板/對話框（不轉頁）
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('藍芽連線')),
                      );
                      break;
                    case 'qr':
                    // TODO: 開啟 QR 掃描對話框/BottomSheet
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('QR 掃瞄')),
                      );
                      break;
                    case 'smooth':
                    // TODO: 開啟平滑處理設定 BottomSheet
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('平滑處理設定')),
                      );
                      break;
                    case 'settings':
                    // TODO: 開啟設定對話框/BottomSheet
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('設定')),
                      );
                      break;
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'ble',     child: Text('藍芽連線')),
                  PopupMenuItem(value: 'qr',      child: Text('QR Code 掃瞄')),
                  PopupMenuItem(value: 'smooth',  child: Text('平滑處理')),
                  PopupMenuItem(value: 'settings',child: Text('設定')),
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
            return StreamBuilder(
              stream: dayStream,
              builder: (context, snap) {
                final list = snap.data ?? const [];
                return Column(
                  children: [
                    Expanded(child: InteractiveViewer(child: GlucoseChart(samples: list))),
                    const SizedBox(height: 8),
                    FutureBuilder(
                      future: Future.wait([
                        repo.prevDayWithData(widget.deviceId, _dayKey),
                        repo.nextDayWithData(widget.deviceId, _dayKey),
                      ]),
                      builder: (context, s2) {
                        if (!s2.hasData) return const SizedBox(height: 48);
                        final prev = s2.data![0] as String?;
                        final next = s2.data![1] as String?;
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            TextButton.icon(
                              onPressed: prev == null
                                  ? null
                                  : () {
                                Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => MeasureDetailScreen(
                                    deviceId: widget.deviceId,
                                    dayKey: prev,
                                  ),
                                ));
                              },
                              icon: const Icon(Icons.keyboard_double_arrow_left),
                              label: const Text(''),
                            ),
                            // 中間日曆圖示
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
                                Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => MeasureDetailScreen(
                                    deviceId: widget.deviceId,
                                    dayKey: next,
                                  ),
                                ));
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

      // === 底部導覽列 ===
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
      // TODO: 導到你的藍芽頁面或開啟裝置列表
      // Navigator.push(context, MaterialPageRoute(builder: (_) => const BleDevicesScreen()));
        _toast('開啟藍芽連線/裝置管理');
        break;

      case 1: // QR Code 掃瞄
      // TODO: 導到你的掃瞄頁面，或呼叫相機掃瞄流程
      // Navigator.push(context, MaterialPageRoute(builder: (_) => const QrScanScreen()));
        _toast('開啟 QR Code 掃瞄');
        break;

      case 2: // 平滑處理
      // TODO: 打開平滑處理設定面板（Dialog/BottomSheet）
        _showSmoothingSheet();
        break;

      case 3: // 設定
      // TODO: 導到設定頁
      // Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
        _toast('開啟設定');
        break;
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(milliseconds: 800)),
    );
  }

  void _showSmoothingSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        // TODO: 依你的需要換成實際的平滑/濾波參數 UI
        double _alpha = 0.2; // 範例：指數平滑係數
        int _window = 5;     // 範例：移動平均視窗
        return StatefulBuilder(
          builder: (context, setState) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('平滑處理設定', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('指數平滑 α'),
                      Slider(
                        value: _alpha,
                        min: 0.0,
                        max: 1.0,
                        divisions: 100,
                        label: _alpha.toStringAsFixed(2),
                        onChanged: (v) => setState(() => _alpha = v),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('移動平均視窗'),
                      Slider(
                        value: _window.toDouble(),
                        min: 3,
                        max: 21,
                        divisions: 9,
                        label: _window.toString(),
                        onChanged: (v) => setState(() => _window = v.round()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          // TODO: 將參數寫入你的狀態（e.g. ref.read(filterProvider.notifier).update(...)）
                          Navigator.pop(context);
                          _toast('已套用平滑：α=${_alpha.toStringAsFixed(2)}、視窗=$_window');
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
}