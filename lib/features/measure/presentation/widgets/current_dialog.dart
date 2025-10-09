import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CurrentScaleResult {
  final double yMax;
  final double yMin;

  CurrentScaleResult({
    required this.yMax,
    required this.yMin,
  });
}

// 使用方法：在 settings_dialog.dart 的 _showCurrentDialog 中調用
Future<CurrentScaleResult?> showCurrentDialog(BuildContext context) async {
  final result = await showDialog<CurrentScaleResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const CurrentDialog(),
  );

  return result; // null 表示 Exit
}

class CurrentDialog extends StatefulWidget {
  const CurrentDialog({super.key});

  @override
  State<CurrentDialog> createState() => _CurrentDialogState();
}

class _CurrentDialogState extends State<CurrentDialog> {
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
      _yMaxController.text = prefs.getString('current_y_max') ?? '5.0';
      _yMinController.text = prefs.getString('current_y_min') ?? '0.0';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_y_max', _yMaxController.text);
    await prefs.setString('current_y_min', _yMinController.text);
  }

  CurrentScaleResult? _createResult() {
    final yMax = double.tryParse(_yMaxController.text.trim());
    final yMin = double.tryParse(_yMinController.text.trim());

    if (yMax == null || yMin == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('請輸入有效的數值'),
          duration: Duration(milliseconds: 800),
        ),
      );
      return null;
    }

    return CurrentScaleResult(
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
      backgroundColor: const Color(0xFFE8E0E8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 400,
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title
                  const Text(
                    'Edit Scale',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Y-Max Input
                  _buildInputField(
                    label: 'Y-Max (Current, nA = E-9)',
                    controller: _yMaxController,
                  ),
                  const SizedBox(height: 20),

                  // Y-Min Input
                  _buildInputField(
                    label: 'Y-Min (Current, nA = E-9)',
                    controller: _yMinController,
                  ),
                  const SizedBox(height: 32),

                  // Buttons
                  Row(
                    children: [
                      Expanded(
                        child: _buildButton(
                          'Apply',
                          onPressed: () async {
                            final result = _createResult();
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
                        child: _buildButton(
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

  Widget _buildInputField({
    required String label,
    required TextEditingController controller,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.black87,
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
            border: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.black54),
            ),
            enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.black54),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.black87, width: 2),
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

  Widget _buildButton(String label, {VoidCallback? onPressed}) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(30),
          side: const BorderSide(color: Colors.black54),
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