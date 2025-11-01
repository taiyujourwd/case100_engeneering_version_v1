import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SmoothingResult {
  final int method; // 1 for Smooth 1, 2 for Smooth 2, 3 for Smooth 3
  final int? smooth1Order;
  final int? smooth2Order;
  final double? smooth2Error;
  final int? smooth3TrimN;
  final double? smooth3TrimC;
  final double? smooth3TrimDelta;
  final bool? smooth3UseTrimmedWindow;
  final int? smooth3KalmanN;
  final double? smooth3Kn;
  final int? smooth3WeightN;
  final double? smooth3P;
  final bool? smooth3KeepHeadOriginal;

  SmoothingResult({
    required this.method,
    this.smooth1Order,
    this.smooth2Order,
    this.smooth2Error,
    this.smooth3TrimN,
    this.smooth3TrimC,
    this.smooth3TrimDelta,
    this.smooth3UseTrimmedWindow,
    this.smooth3KalmanN,
    this.smooth3Kn,
    this.smooth3WeightN,
    this.smooth3P,
    this.smooth3KeepHeadOriginal,
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
  int _selectedMethod = 4; // 1: Smooth 1, 2: Smooth 2, 3: Smooth 3, 4: None

  // Smooth 1 參數
  final TextEditingController _smooth1OrderController = TextEditingController(text: '6');

  // Smooth 2 參數
  final TextEditingController _smooth2ErrorController = TextEditingController(text: '1.0');
  final TextEditingController _smooth2OrderController = TextEditingController(text: '6');

  // Smooth 3 參數
  final TextEditingController _s3TrimNCtl = TextEditingController(text: '20');
  final TextEditingController _s3TrimCCtl = TextEditingController(text: '20.0');
  final TextEditingController _s3TrimDeltaCtl = TextEditingController(text: '0.8');
  bool _s3UseTrimmedWindow = true;
  final TextEditingController _s3KalmanNCtl = TextEditingController(text: '10');
  final TextEditingController _s3KnCtl = TextEditingController(text: '0.2');
  final TextEditingController _s3WeightNCtl = TextEditingController(text: '10');
  final TextEditingController _s3PCtl = TextEditingController(text: '3.0');
  bool _s3KeepHeadOriginal = true;

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
      _s3TrimNCtl.text = (prefs.getInt('smooth3_trim_n') ?? 20).toString();
      _s3TrimCCtl.text = (prefs.getDouble('smooth3_trim_c') ?? 20.0).toString();
      _s3TrimDeltaCtl.text = (prefs.getDouble('smooth3_trim_delta') ?? 0.8).toString();
      _s3UseTrimmedWindow = prefs.getBool('smooth3_use_trimmed_window') ?? true;
      _s3KalmanNCtl.text = (prefs.getInt('smooth3_kalman_n') ?? 10).toString();
      _s3KnCtl.text = (prefs.getDouble('smooth3_kn') ?? 0.2).toString();
      _s3WeightNCtl.text = (prefs.getInt('smooth3_weight_n') ?? 10).toString();
      _s3PCtl.text = (prefs.getDouble('smooth3_p') ?? 3.0).toString();
      _s3KeepHeadOriginal = prefs.getBool('smooth3_keep_head_original') ?? true;
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
    } else if (_selectedMethod == 2) {
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
    } else if (_selectedMethod == 3) {
      print('test123 smooth3_trim_n: ${_s3TrimNCtl.text}');
      print('test123 smooth3_trim_n: ${_s3TrimCCtl.text}');
      print('test123 smooth3_trim_n: ${_s3TrimDeltaCtl.text}');
      print('test123 smooth3_trim_n: ${_s3UseTrimmedWindow}');
      print('test123 smooth3_trim_n: ${_s3KalmanNCtl.text}');
      print('test123 smooth3_trim_n: ${_s3KnCtl.text}');
      print('test123 smooth3_trim_n: ${_s3WeightNCtl.text}');
      print('test123 smooth3_trim_n: ${_s3PCtl.text}');
      print('test123 smooth3_trim_n: ${_s3KeepHeadOriginal}');

      await prefs.setInt('smooth3_trim_n', int.tryParse(_s3TrimNCtl.text) ?? 20);
      await prefs.setDouble('smooth3_trim_c', double.tryParse(_s3TrimCCtl.text) ?? 20.0);
      await prefs.setDouble('smooth3_trim_delta', double.tryParse(_s3TrimDeltaCtl.text) ?? 0.8);
      await prefs.setBool('smooth3_use_trimmed_window', _s3UseTrimmedWindow);

      await prefs.setInt('smooth3_kalman_n', int.tryParse(_s3KalmanNCtl.text) ?? 10);
      await prefs.setDouble('smooth3_kn', double.tryParse(_s3KnCtl.text) ?? 0.2);

      await prefs.setInt('smooth3_weight_n', int.tryParse(_s3WeightNCtl.text) ?? 10);
      await prefs.setDouble('smooth3_p', double.tryParse(_s3PCtl.text) ?? 3.0);
      await prefs.setBool('smooth3_keep_head_original', _s3KeepHeadOriginal);

      if (mounted) {
        Navigator.of(context).pop(
          SmoothingResult(
            method: 3,
            smooth3TrimN: int.tryParse(_s3TrimNCtl.text),
            smooth3TrimC: double.tryParse(_s3TrimCCtl.text),
            smooth3TrimDelta: double.tryParse(_s3TrimDeltaCtl.text),
            smooth3UseTrimmedWindow: _s3UseTrimmedWindow,
            smooth3KalmanN: int.tryParse(_s3KalmanNCtl.text),
            smooth3Kn: double.tryParse(_s3KnCtl.text),
            smooth3WeightN: int.tryParse(_s3WeightNCtl.text),
            smooth3P: double.tryParse(_s3PCtl.text),
            smooth3KeepHeadOriginal: _s3KeepHeadOriginal,
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
                  DropdownMenuItem(
                    value: 3,
                    child: Text('Smooth 3'),
                  ),
                  DropdownMenuItem(
                    value: 4,
                    child: Text('None'),
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
            ] else if (_selectedMethod == 2) ...[
              _buildSmooth2Settings(),
            ] else if (_selectedMethod == 3) ...[
              _buildSmooth3Settings(),
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
          'Order (1 ~ 30)',
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade700,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _smooth1OrderController,
          keyboardType: TextInputType.number,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
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
                    'Error(0~10%)',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _smooth2ErrorController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
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
                    'Order(1~30)',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _smooth2OrderController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
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

  Widget _buildSmooth3Settings() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  _label('n(1~200)'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _s3TrimNCtl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
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
                  const SizedBox(height: 8),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('C(0%~20%)'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _s3TrimCCtl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
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
                  _label('𝜹(0~1.0)'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _s3TrimDeltaCtl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
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
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  _label('n(1~200)'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _s3KalmanNCtl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
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
                  const SizedBox(height: 8),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('K(0~1)'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _s3KnCtl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
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
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  _label('n(1~100)'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _s3WeightNCtl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
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
                  const SizedBox(height: 8),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('P(1~5)'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _s3PCtl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
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

  Widget _label(String text) {
    return SizedBox(
      height: 20, // 可微調成 18~22 視覺最順的數字
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Text(
          text,
          style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
        ),
      ),
    );
  }
}