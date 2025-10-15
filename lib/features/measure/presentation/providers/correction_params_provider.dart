import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 校正參數模型
class CorrectionParams {
  final double slope;
  final double intercept;

  const CorrectionParams({
    required this.slope,
    required this.intercept,
  });

  /// 默認值
  static const defaultParams = CorrectionParams(
    slope: 600.0,
    intercept: 0.0,
  );

  @override
  String toString() => 'CorrectionParams(slope: $slope, intercept: $intercept)';
}

/// 校正參數 Notifier
class CorrectionParamsNotifier extends StateNotifier<CorrectionParams> {
  CorrectionParamsNotifier() : super(CorrectionParams.defaultParams) {
    // 初始化時載入參數
    _loadParams();
  }

  /// 從 SharedPreferences 載入參數
  Future<void> _loadParams() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final slopeStr = prefs.getString('correction_slope');
      final interceptStr = prefs.getString('correction_intercept');

      final slope = slopeStr != null ? double.tryParse(slopeStr) : null;
      final intercept = interceptStr != null ? double.tryParse(interceptStr) : null;

      state = CorrectionParams(
        slope: slope ?? CorrectionParams.defaultParams.slope,
        intercept: intercept ?? CorrectionParams.defaultParams.intercept,
      );

      print('📊 Loaded correction params: slope=${state.slope}, intercept=${state.intercept}');
    } catch (e) {
      print('❌ Error loading correction params: $e');
      state = CorrectionParams.defaultParams;
    }
  }

  /// ✅ 更新參數並保存到 SharedPreferences（關鍵方法）
  Future<void> updateParams(double slope, double intercept) async {
    try {
      // 1. 立即更新 state（觸發所有監聽者重建）
      state = CorrectionParams(slope: slope, intercept: intercept);
      print('✅ Updated correction params: slope=$slope, intercept=$intercept');

      // 2. 保存到 SharedPreferences（持久化）
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('correction_slope', slope.toString());
      await prefs.setString('correction_intercept', intercept.toString());
      print('💾 Saved correction params to SharedPreferences');
    } catch (e) {
      print('❌ Error updating correction params: $e');
    }
  }

  /// 重新從 SharedPreferences 載入
  Future<void> reload() async {
    await _loadParams();
  }
}

/// ✅ 改用 StateNotifierProvider（不是 FutureProvider）
final correctionParamsProvider = StateNotifierProvider<CorrectionParamsNotifier, CorrectionParams>(
      (ref) => CorrectionParamsNotifier(),
);