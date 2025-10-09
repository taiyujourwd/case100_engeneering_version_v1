import 'package:case100_engeneering_version_v1/features/measure/presentation/widgets/current_dialog.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'glucose_dialog.dart';

class SettingResult {
  final int method; // 1 for BroadCast, 2 for Connection
  final int? slope;
  final int? intercept;
  final double? error;

  SettingResult({
    required this.method,
    this.slope,
    this.intercept,
    this.error,
  });
}

// 使用方法：在 measure_screen.dart 中調用
Future<SettingResult?> showSettingsDialog(BuildContext context) async {
  final result = await showDialog<SettingResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const SettingsDialog(),
  );

  if (result != null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('設定已儲存')),
    );
  }
  return result; // null 表示 Exit
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  bool _isBroadcast = true; // true: BroadCast, false: Connection
  final TextEditingController _slopeController = TextEditingController();
  final TextEditingController _interceptController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 800),
      ),
    );
  }

  // by濃度
  void _showGlucoseDialog() async {
    final result = await showGlucoseDialog(context);

    if (result != null) {
      _toast('yMax=${result.yMax}、yMin=${result.yMin}');
    }
  }

  // by電流
  void _showCurrentDialog() async {
    final result = await showCurrentDialog(context);

    if (result != null) {
      if (result != null) {
        _toast('yMax=${result.yMax}、yMin=${result.yMin}');
      }
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isBroadcast = prefs.getBool('connection_mode_broadcast') ?? true;
      _slopeController.text =
          prefs.getString('correction_slope') ?? '600.000';
      _interceptController.text =
          prefs.getString('correction_intercept') ?? '0.000';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('connection_mode_broadcast', _isBroadcast);
    await prefs.setString('correction_slope', _slopeController.text);
    await prefs.setString('correction_intercept', _interceptController.text);
  }

  SettingResult _createSettingResult() {
    final method = _isBroadcast ? 1 : 2;

    // 先以 double 解析，成功後再四捨五入為 int（維持你的型別介面）
    int? toSafeInt(String s) {
      final d = double.tryParse(s.trim());
      return d != null ? d.round() : null;
    }

    final slope = toSafeInt(_slopeController.text);
    final intercept = toSafeInt(_interceptController.text);

    return SettingResult(
      method: method,
      slope: slope,
      intercept: intercept,
      error: null,
    );
  }

  @override
  void dispose() {
    _slopeController.dispose();
    _interceptController.dispose();
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
            // 不硬塞 500 寬，最多 500，否則依外部約束縮小
            maxWidth: 500,
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // App Version
                  const Text(
                    'App Version : V010.4',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),

                  // BroadCast / Connection Toggle（用 Wrap 避免橫向爆）
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: [
                      _buildToggleButton(
                        label: 'BroadCast',
                        isSelected: _isBroadcast,
                        onTap: () => setState(() => _isBroadcast = true),
                      ),
                      _buildToggleButton(
                        label: 'Connection',
                        isSelected: !_isBroadcast,
                        onTap: () => setState(() => _isBroadcast = false),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Slope / Intercept
                  _buildTextField(
                    label: 'Correction formula - Slope',
                    controller: _slopeController,
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    label: 'Correction formula - Intercept',
                    controller: _interceptController,
                  ),
                  const SizedBox(height: 20),

                  // 僅保留你要的兩顆功能 + Apply/Exit
                  Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _buildActionButton(
                              'Set Scale by 濃度',
                              onPressed: _showGlucoseDialog
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildActionButton(
                              'Set Scale by 電流',
                              onPressed: _showCurrentDialog
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _buildActionButton(
                              'Apply',
                              onPressed: () async {
                                await _saveSettings();
                                final result = _createSettingResult();
                                if (context.mounted) {
                                  Navigator.of(context).pop(result);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToggleButton({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 140),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? Colors.yellow[300] : Colors.white,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: Colors.grey[400]!),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
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
        Text(label, style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          keyboardType:
          const TextInputType.numberWithOptions(decimal: true, signed: false),
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            border: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.grey[400]!),
            ),
            contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          ),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  Widget _buildActionButton(String label, {VoidCallback? onPressed}) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(30),
          side: BorderSide(color: Colors.grey[400]!),
        ),
      ),
      child: Text(label, style: const TextStyle(fontSize: 16)),
    );
  }
}