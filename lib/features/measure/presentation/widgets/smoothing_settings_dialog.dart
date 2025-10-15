import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SmoothingResult {
  final int method; // 1 for Smooth 1, 2 for Smooth 2
  final int? smooth1Order;
  final int? smooth2Order;
  final double? smooth2Error;

  SmoothingResult({
    required this.method,
    this.smooth1Order,
    this.smooth2Order,
    this.smooth2Error,
  });
}

/// 顯示平滑設定對話框
Future<SmoothingResult?> showSmoothingDialog(BuildContext context) async {
  return showDialog<SmoothingResult>(
    context: context,
    builder: (context) => const SmoothingDialog(),
  );
}

class SmoothingDialog extends StatefulWidget {
  const SmoothingDialog({super.key});

  @override
  State<SmoothingDialog> createState() => _SmoothingDialogState();
}

class _SmoothingDialogState extends State<SmoothingDialog> {
  int _selectedMethod = 1; // 1: Smooth 1, 2: Smooth 2

  // Smooth 1 參數
  final TextEditingController _smooth1OrderController = TextEditingController(text: '6');

  // Smooth 2 參數
  final TextEditingController _smooth2ErrorController = TextEditingController(text: '1.0');
  final TextEditingController _smooth2OrderController = TextEditingController(text: '6');

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  /// 載入已儲存的設定
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    setState(() {
      _selectedMethod = prefs.getInt('smoothing_method') ?? 1;
      _smooth1OrderController.text = prefs.getInt('smooth1_order')?.toString() ?? '6';
      _smooth2ErrorController.text = prefs.getDouble('smooth2_error')?.toString() ?? '1.0';
      _smooth2OrderController.text = prefs.getInt('smooth2_order')?.toString() ?? '6';
    });
  }

  /// 儲存設定並關閉對話框
  Future<void> _saveAndApply() async {
    final prefs = await SharedPreferences.getInstance();

    // 儲存選擇的方法
    await prefs.setInt('smoothing_method', _selectedMethod);

    if (_selectedMethod == 1) {
      // 儲存 Smooth 1 參數
      final order = int.tryParse(_smooth1OrderController.text) ?? 6;
      await prefs.setInt('smooth1_order', order);

      if (mounted) {
        Navigator.of(context).pop(
          SmoothingResult(
            method: 1,
            smooth1Order: order,
          ),
        );
      }
    } else {
      // 儲存 Smooth 2 參數
      final error = double.tryParse(_smooth2ErrorController.text) ?? 1.0;
      final order = int.tryParse(_smooth2OrderController.text) ?? 6;

      await prefs.setInt('smooth2_order', order);
      await prefs.setDouble('smooth2_error', error);

      if (mounted) {
        Navigator.of(context).pop(
          SmoothingResult(
            method: 2,
            smooth2Error: error,
            smooth2Order: order,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _smooth1OrderController.dispose();
    _smooth2ErrorController.dispose();
    _smooth2OrderController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFFF5E6E8),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 下拉選單
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Colors.grey.shade300,
                  width: 2,
                ),
              ),
              child: DropdownButton<int>(
                value: _selectedMethod,
                isExpanded: true,
                underline: const SizedBox(),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
                icon: Icon(Icons.arrow_drop_down, color: Colors.grey.shade700),
                items: const [
                  DropdownMenuItem(
                    value: 1,
                    child: Text('Smooth 1'),
                  ),
                  DropdownMenuItem(
                    value: 2,
                    child: Text('Smooth 2'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selectedMethod = value);
                  }
                },
              ),
            ),

            const SizedBox(height: 24),

            // 參數輸入區域
            if (_selectedMethod == 1) ...[
              _buildSmooth1Settings(),
            ] else ...[
              _buildSmooth2Settings(),
            ],

            const SizedBox(height: 24),

            // Apply 和 Exit 按鈕
            Row(
              children: [
                Expanded(
                  child: _buildActionButton(
                    label: 'Apply',
                    onTap: _saveAndApply,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildActionButton(
                    label: 'Exit',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmooth1Settings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Smooth 1：Order (1 ~ 30)',
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade700,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _smooth1OrderController,
          keyboardType: TextInputType.number,
          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildSmooth2Settings() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Smooth 2:Error(0~10%)',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _smooth2ErrorController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w500),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Smooth 2:Order(1~30)',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _smooth2OrderController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w500),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildActionButton({
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.grey.shade300,
            width: 2,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade800,
            ),
          ),
        ),
      ),
    );
  }
}