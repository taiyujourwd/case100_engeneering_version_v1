import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class GlucoseScaleResult {
  final double yMax;
  final double yMin;

  GlucoseScaleResult({
    required this.yMax,
    required this.yMin,
  });
}

// 使用方法：在 settings_dialog.dart 的 "Set Scale by 濃度" 按鈕中調用
Future<GlucoseScaleResult?> showGlucoseDialog(BuildContext context) async {
  final result = await showDialog<GlucoseScaleResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const EditScaleDialog(),
  );

  if (result != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('量表設定已儲存')),
    );
  }
  return result; // null 表示 Exit
}

class EditScaleDialog extends StatefulWidget {
  const EditScaleDialog({super.key});

  @override
  State<EditScaleDialog> createState() => _EditScaleDialogState();
}

class _EditScaleDialogState extends State<EditScaleDialog> {
  final TextEditingController _yMaxController = TextEditingController();
  final TextEditingController _yMinController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _yMaxController.text = prefs.getString('scale_y_max') ?? '3000.0';
      _yMinController.text = prefs.getString('scale_y_min') ?? '-120.0';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('glucose_y_max', _yMaxController.text);
    await prefs.setString('glucose_y_min', _yMinController.text);
  }

  GlucoseScaleResult? _createScaleResult() {
    final yMax = double.tryParse(_yMaxController.text.trim());
    final yMin = double.tryParse(_yMinController.text.trim());

    if (yMax == null || yMin == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('請輸入有效的數值')),
      );
      return null;
    }

    if (yMax <= yMin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Y-Max 必須大於 Y-Min')),
      );
      return null;
    }

    return GlucoseScaleResult(
      yMax: yMax,
      yMin: yMin,
    );
  }

  @override
  void dispose() {
    _yMaxController.dispose();
    _yMinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.grey[200],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 500,
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Title
                  const Text(
                    'Edit Scale',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Y-Max Input
                  _buildTextField(
                    label: 'Y-Max (Glu conc, mg/dL)',
                    controller: _yMaxController,
                  ),
                  const SizedBox(height: 20),

                  // Y-Min Input
                  _buildTextField(
                    label: 'Y-Min (Glu conc, mg/dL)',
                    controller: _yMinController,
                  ),
                  const SizedBox(height: 32),

                  // Apply / Exit Buttons
                  Row(
                    children: [
                      Expanded(
                        child: _buildActionButton(
                          'Apply',
                          onPressed: () async {
                            final result = _createScaleResult();
                            if (result != null) {
                              await _saveSettings();
                              if (context.mounted) {
                                Navigator.of(context).pop(result);
                              }
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _buildActionButton(
                          'Exit',
                          onPressed: () {
                            Navigator.of(context).pop(null);
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            border: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.grey[400]!),
            ),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.grey[400]!),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.grey[600]!, width: 2),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
          ),
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButton(String label, {required VoidCallback onPressed}) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(30),
          side: BorderSide(color: Colors.grey[400]!),
        ),
        elevation: 0,
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}