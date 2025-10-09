import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController cameraController = MobileScannerController();
  bool isScanned = false;

  @override
  void dispose() {
    cameraController.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (isScanned) return;

    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final String? code = barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;

    setState(() => isScanned = true);

    // 儲存到 SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('scanned_device_name', code);

    // 返回掃描結果
    if (mounted) {
      Navigator.pop(context, code);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('掃描 QR Code'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => cameraController.toggleTorch(),
            tooltip: '手電筒',
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => cameraController.switchCamera(),
            tooltip: '切換鏡頭',
          ),
        ],
      ),
      body: Stack(
        children: [
          // 相機預覽
          MobileScanner(
            controller: cameraController,
            onDetect: _onDetect,
          ),
          // 遮罩層（讓掃描框外變暗）
          ColorFiltered(
            colorFilter: ColorFilter.mode(
              Colors.black.withOpacity(0.5),
              BlendMode.srcOut,
            ),
            child: Stack(
              children: [
                Container(
                  decoration: const BoxDecoration(
                    color: Colors.black,
                    backgroundBlendMode: BlendMode.dstOut,
                  ),
                ),
                Align(
                  alignment: Alignment.center,
                  child: Container(
                    height: 250,
                    width: 250,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 掃描框
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Colors.white,
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Stack(
                children: [
                  // 左上角
                  Positioned(
                    top: 0,
                    left: 0,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: const BoxDecoration(
                        border: Border(
                          top: BorderSide(color: Colors.green, width: 4),
                          left: BorderSide(color: Colors.green, width: 4),
                        ),
                      ),
                    ),
                  ),
                  // 右上角
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: const BoxDecoration(
                        border: Border(
                          top: BorderSide(color: Colors.green, width: 4),
                          right: BorderSide(color: Colors.green, width: 4),
                        ),
                      ),
                    ),
                  ),
                  // 左下角
                  Positioned(
                    bottom: 0,
                    left: 0,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: Colors.green, width: 4),
                          left: BorderSide(color: Colors.green, width: 4),
                        ),
                      ),
                    ),
                  ),
                  // 右下角
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: Colors.green, width: 4),
                          right: BorderSide(color: Colors.green, width: 4),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 提示文字
          Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '將 QR Code 對準掃描框',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}