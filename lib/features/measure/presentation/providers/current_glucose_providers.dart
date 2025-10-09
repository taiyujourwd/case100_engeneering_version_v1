import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 血糖範圍模型
class GlucoseRange {
  final double min;
  final double max;

  const GlucoseRange({required this.min, required this.max});

  GlucoseRange copyWith({double? min, double? max}) {
    return GlucoseRange(
      min: min ?? this.min,
      max: max ?? this.max,
    );
  }
}

/// 電流範圍模型
class CurrentRange {
  final double min;
  final double max;

  const CurrentRange({required this.min, required this.max});

  CurrentRange copyWith({double? min, double? max}) {
    return CurrentRange(
      min: min ?? this.min,
      max: max ?? this.max,
    );
  }
}

/// 血糖範圍 Notifier
class GlucoseRangeNotifier extends StateNotifier<GlucoseRange> {
  GlucoseRangeNotifier() : super(const GlucoseRange(min: -120.0, max: 300.0)) {
    _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final min = double.tryParse(prefs.getString('glucose_y_min') ?? '-120.0') ?? -120.0;
    final max = double.tryParse(prefs.getString('glucose_y_max') ?? '300.0') ?? 300.0;
    state = GlucoseRange(min: min, max: max);
  }

  Future<void> updateRange(double min, double max) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('glucose_y_min', min.toString());
    await prefs.setString('glucose_y_max', max.toString());
    state = GlucoseRange(min: min, max: max);
  }
}

/// 电流范围 Notifier（单位：nA 纳安）
class CurrentRangeNotifier extends StateNotifier<CurrentRange> {
  CurrentRangeNotifier() : super(const CurrentRange(min: -2.0, max: 50.0)) {
    _loadFromPrefs();
  }

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final min = double.tryParse(prefs.getString('current_y_min') ?? '-2.0') ?? -2.0;
    final max = double.tryParse(prefs.getString('current_y_max') ?? '50.0') ?? 50.0;
    state = CurrentRange(min: min, max: max);
  }

  Future<void> updateRange(double min, double max) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_y_min', min.toString());
    await prefs.setString('current_y_max', max.toString());
    state = CurrentRange(min: min, max: max);
  }
}

/// Provider 實例
final glucoseRangeProvider = StateNotifierProvider<GlucoseRangeNotifier, GlucoseRange>((ref) {
  return GlucoseRangeNotifier();
});

final currentRangeProvider = StateNotifierProvider<CurrentRangeNotifier, CurrentRange>((ref) {
  return CurrentRangeNotifier();
});