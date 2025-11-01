import 'dart:math';
import 'isar_schemas.dart';

final List<Sample> mockSamples = _generateMockSamples(
  count: 300,
  // 🔧 可調參數（想更瘋就往上調）
  baseValue: 5.878321428571364e-11, // 基準電流
  sinA: 0.8,    // 慢頻波動振幅（越大起伏越大）
  sinB: 0.35,   // 快頻波動振幅
  sinAPeriod: 12.0, // 慢頻週期（索引除以此值）
  sinBPeriod: 3.5,  // 快頻週期
  gaussianStd: 0.60, // 乘法雜訊強度（對數常態），0.4~0.6 會很抖
  spikeProb: 0.06,   // 尖峰機率（每筆）
  dipProb: 0.06,     // 下殺機率（每筆）
  spikeRange: (1.8, 3.5), // 尖峰倍率範圍
  dipRange: (0.25, 0.65), // 下殺倍率範圍
  regimeStep: 60,         // 每隔幾筆做 regime shift
  regimeShiftPct: 0.30,   // regime shift 的±比例（0.30 = ±30%）
);

List<Sample> _generateMockSamples({
  required int count,
  required double baseValue,
  double sinA = 0.6,
  double sinB = 0.25,
  double sinAPeriod = 10.0,
  double sinBPeriod = 4.0,
  double gaussianStd = 0.25,
  double spikeProb = 0.03,
  double dipProb = 0.03,
  (double, double) spikeRange = const (1.5, 3.0),
  (double, double) dipRange = const (0.3, 0.7),
  int regimeStep = 90,
  double regimeShiftPct = 0.20,
}) {
  final r = Random();
  final List<Sample> samples = [];
  final start = DateTime.parse('2025-11-01 09:16:15.000');

  // regime 水位：每隔 regimeStep 筆會整體上/下移一個比例
  double regimeLevel = 1.0;

  for (int i = 0; i < count; i++) {
    // --- 1) 周期波動（多頻） ---
    final slow = sin(i / sinAPeriod); // 慢頻
    final fast = sin(i / sinBPeriod); // 快頻
    // 讓週期項為正且保留強度（避免 <0 被吃掉）
    final seasonal = (1.0 + sinA * slow + sinB * fast).clamp(0.15, double.infinity);

    // --- 2) 對數常態乘法雜訊（震盪更大） ---
    final gauss = _gaussian(r, mean: 0.0, std: gaussianStd);
    final multiplicativeNoise = exp(gauss); // log-normal：>1 或 <1 的機率對稱但放大尾巴

    // --- 3) 突發尖峰/下殺事件 ---
    double shock = 1.0;
    if (r.nextDouble() < spikeProb) {
      final (lo, hi) = spikeRange;
      shock *= _lerp(lo, hi, r.nextDouble()); // 放大到 1.8~3.5 倍
    } else if (r.nextDouble() < dipProb) {
      final (lo, hi) = dipRange;
      shock *= _lerp(lo, hi, r.nextDouble()); // 壓低到 0.25~0.65 倍
    }

    // --- 4) Regime shift：每隔 regimeStep 筆上下跳 ---
    if (regimeStep > 0 && i > 0 && i % regimeStep == 0) {
      final shift = (r.nextDouble() * 2 - 1) * regimeShiftPct; // [-pct, +pct]
      regimeLevel *= (1.0 + shift);
      // 避免 regimeLevel 太接近 0
      regimeLevel = max(regimeLevel, 0.1);
    }

    // --- 5) 綜合：基準 * 週期 * 雜訊 * 事件 * regime ---
    double current = baseValue * seasonal * multiplicativeNoise * shock * regimeLevel;

    // 避免極端過小（視覺上看不到）
    current = max(current, baseValue * 0.05);

    // 產出樣本
    final sample = Sample.create(
      id: i + 1,
      deviceId: 'PSA00179',
      seq: 1761873375000,
      ts: start.add(Duration(seconds: i * 30)),
      dayKey: '2025-11-01',
      voltage: 2.879,
      current: current,
      glucose: null,
      temperature: 31.54,
      currents: [current], // 若你想另外加「整數位±10」的版本，也可在此替換
    );

    samples.add(sample);
  }

  return samples;
}

/// 產生常態分佈亂數（Box-Muller）
double _gaussian(Random r, {double mean = 0, double std = 1}) {
  // 避免 log(0)
  var u1 = r.nextDouble();
  var u2 = r.nextDouble();
  u1 = (u1 <= 1e-12) ? 1e-12 : u1;

  final z0 = sqrt(-2.0 * log(u1)) * cos(2 * pi * u2);
  return mean + std * z0;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;