import 'dart:math';
import 'dart:math' as math;

// ---------------------------------------------------------
// 參數設定資料類別（管線三步）
// ---------------------------------------------------------
class TrimConfig {
  final int n;         // 取前 n 筆做平均/比較
  final double C;      // 差距百分比門檻 (0~100)
  final double delta;  // 修剪係數 δ (0~1)
  final bool useTrimmedWindow; // 平均基準用「已修剪」視窗
  const TrimConfig({
    required this.n,
    required this.C,
    required this.delta,
    this.useTrimmedWindow = true,
  });
}

class KalmanConfig {
  final int n;     // 回歸視窗大小
  final double Kn; // 卡爾曼增益 (0~1)
  const KalmanConfig({required this.n, required this.Kn});
}

class WeightedAvgConfig {
  final int n;       // 加權平均視窗大小
  final double p;    // 權重次方 (≥1)
  final bool keepHeadOriginal; // 視窗不足時是否保留原值
  const WeightedAvgConfig({
    required this.n,
    required this.p,
    this.keepHeadOriginal = true,
  });
}

// 數據平滑處理類別
class DataSmoother {
  final List<double> _dataBuffer = [];
  static const int maxBufferSize = 30;

  void addData(double value) {
    _dataBuffer.add(value);
    if (_dataBuffer.length > maxBufferSize) {
      _dataBuffer.removeAt(0);
    }
  }

  void clearBuffer() {
    _dataBuffer.clear();
  }

  double? smooth1(int order) {
    if (order < 1) {
      throw ArgumentError('order 至少為 1');
    }

    if (_dataBuffer.isEmpty) {
      return null;
    }

    // ⚠️ order == 1 時沒有平滑效果，直接回傳最後一筆
    if (order == 1) {
      return _dataBuffer.last;
    }

    // 取最後 n 筆資料（包含最後一筆本身）
    final n = min(order, _dataBuffer.length);
    final startIndex = _dataBuffer.length - n;
    final recentData = _dataBuffer.sublist(startIndex); // 包含最後一筆

    // 計算平均
    final sum = recentData.reduce((a, b) => a + b);
    final avg = sum / recentData.length;

    return avg;
  }

  double? smooth2(int order, double errorPercent) {
    if (order < 1) {
      throw ArgumentError('order 至少為 1');
    }
    if (errorPercent < 0.0 || errorPercent > 10.0) {
      throw ArgumentError('errorPercent 必須在 0.0 到 10.0 之間');
    }

    if (_dataBuffer.length < 2) {
      return _dataBuffer.isEmpty ? null : _dataBuffer.first;
    }

    if (order == 1) {
      return _dataBuffer.last;
    }

    final lastValue = _dataBuffer[_dataBuffer.length - 1];
    final prevValue = _dataBuffer[_dataBuffer.length - 2];
    if (prevValue == 0.0) {
      return lastValue; // 返回原值
    }
    final errorRate = ((lastValue - prevValue).abs() / prevValue.abs()) * 100;

    if (errorRate > errorPercent) {
      final n = min(order, _dataBuffer.length);
      final lastNData = _dataBuffer.sublist(_dataBuffer.length - n);
      final sum = lastNData.reduce((acc, val) => acc + val);
      return sum / n;
    }

    return lastValue;
  }

  /// Smooth3：修剪 → 卡爾曼 → 加權平均
  /// - 若有帶入 [value]，會先自動 addData 再做平滑
  /// - 三段參數都有預設值，直接呼叫即可
  /// - 回傳「最新平滑值」，若資料不足則回傳 null
  double? smooth3({
    double? value,                 // 如果有這個參數，是否 addData
    required int trimN,
    required double trimC,
    required double trimDelta,
    required bool useTrimmedWindow,
    required int kalmanN,
    required double kn,
    required int weightN,
    required double p,
    required bool keepHeadOriginal,
  }) {
    final bufLen = _dataBuffer.length;
    if (bufLen == 0) return null;               // 沒資料：直接返回

    // 只取 <= 當前 buffer 長度
    final tN = math.min(trimN, bufLen);
    final kN = math.min(kalmanN, bufLen);
    final wN = math.min(weightN, bufLen);

    // --- Step 1: 修剪 ---
    final trimmed = _trimSeries(
      _dataBuffer,
      n: tN,
      C: trimC,
      delta: trimDelta,
      useTrimmedWindow: useTrimmedWindow,
    );

    // --- Step 2: 卡爾曼 ---
    // 線性回歸至少需要 2 筆；不足 2 筆時就「略過卡爾曼」，沿用修剪結果
    List<double> kalmanOut;
    if (kN >= 2) {
      kalmanOut = _kalmanFilter(
        trimmed,
        n: kN,
        Kn: kn,
      );
    } else {
      kalmanOut = trimmed; // 資料太少，不做卡爾曼
    }

    // --- Step 3: 加權平均 ---
    // 加權視窗至少要 1；若 wN 變成 0（理論上不會，但保險），強制用 1
    final weightedOut = _weightedAverageSeries(
      kalmanOut,
      n: wN <= 0 ? 1 : wN,
      p: p,
      keepHeadOriginal: keepHeadOriginal,
    );

    return weightedOut.isEmpty ? null : weightedOut.last;
  }

  List<double> getBuffer() => List.from(_dataBuffer);
  int get bufferLength => _dataBuffer.length;
  bool get isEmpty => _dataBuffer.isEmpty;

  // =========================================================
  // 一鍵處理管線（修剪 → 卡爾曼 → 加權平均）
  // =========================================================

  /// 便捷方法：丟新量測、入緩衝並回傳管線後的**最新平滑值**
  double? processAndSmooth(
      double newValue, {
        TrimConfig trim = const TrimConfig(n: 20, C: 20.0, delta: 0.8),
        KalmanConfig kalman = const KalmanConfig(n: 10, Kn: 0.2),
        WeightedAvgConfig weighted = const WeightedAvgConfig(n: 10, p: 3.0),
      }) {
    // addData(newValue);
    return smoothPipeline(trim: trim, kalman: kalman, weighted: weighted);
  }

  /// 直接把目前緩衝資料跑完整管線並回傳**最新平滑值**
  double? smoothPipeline({
    TrimConfig trim = const TrimConfig(n: 20, C: 20.0, delta: 0.8),
    KalmanConfig kalman = const KalmanConfig(n: 10, Kn: 0.2),
    WeightedAvgConfig weighted = const WeightedAvgConfig(n: 10, p: 3.0),
  }) {
    if (_dataBuffer.isEmpty) return null;

    // 1) 修剪
    final trimmed = _trimSeries(
      _dataBuffer,
      n: math.min(trim.n, _dataBuffer.length),
      C: trim.C,
      delta: trim.delta,
      useTrimmedWindow: trim.useTrimmedWindow,
    );

    // 2) 卡爾曼
    final kalmanOut = _kalmanFilter(
      trimmed,
      n: math.min(kalman.n, trimmed.length.clamp(2, trimmed.length)),
      Kn: kalman.Kn,
    );

    // 3) 加權平均
    final weightedOut = _weightedAverageSeries(
      kalmanOut,
      n: math.min(weighted.n, kalmanOut.length),
      p: weighted.p,
      keepHeadOriginal: weighted.keepHeadOriginal,
    );

    return weightedOut.isEmpty ? null : weightedOut.last;
  }

  // ---------------- 内部：修剪 ----------------
  List<double> _trimSeries(
      List<double> data, {
        required int n,
        required double C,
        required double delta,
        required bool useTrimmedWindow,
      }) {
    if (data.length <= 1) return List<double>.from(data);

    // ✅ 改為：使用 min(n, 當前長度) 作為窗口
    final out = <double>[];

    for (int i = 0; i < data.length; i++) {
      if (i == 0) {
        out.add(data[i]);  // 第一筆保持原值
        continue;
      }

      // ✅ 動態窗口大小
      final windowSize = math.min(n, i);
      final window = useTrimmedWindow
          ? out.sublist(i - windowSize, i)
          : data.sublist(i - windowSize, i);

      final mean = window.reduce((a, b) => a + b) / window.length;
      final y = data[i];
      final denom = mean == 0 ? 1e-12 : mean.abs();
      final diffPercent = ((y - mean).abs() / denom) * 100.0;

      final yTrimmed = (diffPercent > C) ? (y * (1 - delta) + mean * delta) : y;
      out.add(yTrimmed);
    }
    return out;
  }

  // ---------------- 内部：線性回歸 + 卡爾曼 ----------------
  Map<String, double> _linearRegression(List<double> yValues) {
    final n = yValues.length;
    final xs = List<int>.generate(n, (i) => i + 1);
    final meanX = xs.reduce((a, b) => a + b) / n;
    final meanY = yValues.reduce((a, b) => a + b) / n;

    double num = 0, den = 0;
    for (int i = 0; i < n; i++) {
      final dx = xs[i] - meanX;
      final dy = yValues[i] - meanY;
      num += dx * dy;
      den += dx * dx;
    }
    final a = den == 0 ? 0.0 : num / den;
    final b = meanY - a * meanX;
    return {'a': a, 'b': b};
  }

  List<double> _kalmanFilter(
      List<double> data, {
        required int n,
        required double Kn,
      }) {
    if (data.length <= 1) return List<double>.from(data);

    final out = <double>[];

    for (int i = 0; i < data.length; i++) {
      if (i < 2) {
        out.add(data[i]);  // 前 2 筆（回歸最少需要 2 點）
        continue;
      }

      // ✅ 動態窗口大小
      final windowSize = math.min(n, i);
      final window = out.sublist(i - windowSize, i);

      final reg = _linearRegression(window);
      final a = reg['a']!, b = reg['b']!;
      final xNext = windowSize + 1;
      final yHat = a * xNext + b;

      final y = data[i];
      final yNew = Kn * y + (1 - Kn) * yHat;
      out.add(yNew);
    }
    return out;
  }

  // ---------------- 内部：加權平均 ----------------
  List<double> _weightedAverageSeries(
      List<double> data, {
        required int n,
        required double p,
        required bool keepHeadOriginal,
      }) {
    if (data.isEmpty) return const <double>[];

    final result = <double>[];

    for (int i = 0; i < data.length; i++) {
      // ✅ 動態窗口大小
      final windowSize = math.min(n, i + 1);
      final start = i - windowSize + 1;
      final window = data.sublist(start, i + 1);

      // ✅ 即使窗口不足也計算加權平均（移除 keepHeadOriginal 判斷）
      double num = 0.0, den = 0.0;
      for (int j = 0; j < window.length; j++) {
        final w = math.pow(j + 1, p).toDouble();
        num += window[j] * w;
        den += w;
      }
      result.add(num / den);
    }
    return result;
  }
}