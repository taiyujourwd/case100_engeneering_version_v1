import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../data/isar_schemas.dart';


/// 雙 Y 軸曲線圖：左軸=血糖(mg/dL)、右軸=電流(mA)
/// - 主圖 Y 範圍使用「血糖」範圍
/// - 電流線以線性比例縮放到血糖範圍繪製；右側刻度反算成電流顯示
class GlucoseChart extends StatelessWidget {
  final List<Sample> samples;

  /// 沒資料時的初始化視窗（秒）
  final int initialWindowSeconds;

  /// 佔位線基準（無資料時用）
  final double placeholderGlucoseMgdl; // 左軸主尺度
  final double placeholderCurrentMa;   // 右軸

  /// 手動指定兩側數值範圍（可不給，會自動依資料估算並加緩衝）
  final double? fixedGlucoseMin; // 左軸（mg/dL）
  final double? fixedGlucoseMax;
  final double? fixedCurrentMin; // 右軸（mA）
  final double? fixedCurrentMax;

  const GlucoseChart({
    super.key,
    required this.samples,
    this.initialWindowSeconds = 60,
    this.placeholderGlucoseMgdl = 110,
    this.placeholderCurrentMa = 0.8,
    this.fixedGlucoseMin,
    this.fixedGlucoseMax,
    this.fixedCurrentMin,
    this.fixedCurrentMax,
  });

  @override
  Widget build(BuildContext context) {
    final hasData = samples.isNotEmpty;

    // 1) 準備資料點（血糖/電流）；若無資料，產生佔位曲線
    final gluSpots = hasData
        ? _mapToSortedSpots(samples, (s) => _getGlucose(s))
        : _buildPlaceholderSpots(initialWindowSeconds, placeholderGlucoseMgdl);

    final currRawSpots = hasData
        ? _mapToSortedSpots(samples, (s) => _getCurrent(s))
        : _buildPlaceholderSpots(initialWindowSeconds, placeholderCurrentMa);

    // 2) 計算原始範圍（左=血糖、右=電流）
    final gluRange = _calcRange(
      gluSpots.map((e) => e.y),
      floor: 0,
      fixedMin: fixedGlucoseMin,
      fixedMax: fixedGlucoseMax,
    );
    final currRange = _calcRange(
      currRawSpots.map((e) => e.y),
      floor: 0,
      fixedMin: fixedCurrentMin,
      fixedMax: fixedCurrentMax,
    );

    // 3) 將「電流線」縮放到「血糖的 Y 座標系」繪製
    final currScaledSpots = currRawSpots
        .map((p) => FlSpot(
      p.x,
      _scaleToLeftAxis(p.y, from: currRange, to: gluRange),
    ))
        .toList();

    // 4) X 軸視窗（以血糖線為主，若空則用電流線）
    final minX = (gluSpots.isNotEmpty ? gluSpots.first.x : currScaledSpots.first.x);
    final maxX = (gluSpots.isNotEmpty ? gluSpots.last.x : currScaledSpots.last.x);
    final double topY = gluRange.max;
    final double bottomY = gluRange.min;
    const double eps = 1e-6;

    // 5) 左軸（血糖）刻度間距
    final leftInterval = _niceInterval(gluRange.min, gluRange.max, 5);

    // 6) 右軸（電流）刻度：以左軸的 y 值為座標，但顯示反算後的電流
    final rightInterval = leftInterval;

    return Column(
      children: [
        // 血糖值
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0, left: 1, right: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.center, // 垂直置中對齊
            children: const [
              // 左側資訊欄
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min, // 避免填滿整個高度
                children: [
                  Text('0.000 (V)'),
                  Text('電流：-1.462E-11 A'),
                  Text('時間：14:35:45'),
                  Text('溫度：26.5 ℃'),
                ],
              ),
              SizedBox(width: 12), // 與大數字之間的距離
              // 血糖值
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic, // 一定要加這行才能用 baseline 對齊
                children: [
                  Text(
                    '129.5',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 60,
                    ),
                  ),
                  SizedBox(width: 12),
                  Text(
                    'mg/dL',
                    style: TextStyle(
                      fontSize: 18,
                    ),
                  ),
                ],
              )
            ],
          ),
        ),
        Expanded(
          child: LineChart(
            LineChartData(
              minX: minX,
              maxX: maxX,
              minY: bottomY,
              maxY: topY,
              clipData: FlClipData.all(), // ✅ 避免內容超出外框（包含分隔線）
              lineBarsData: [
                // 血糖線（左軸原始值）
                LineChartBarData(
                  spots: gluSpots,
                  isCurved: true,
                  isStrokeCapRound: true,
                  barWidth: 2,
                  color: Colors.red,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(show: false),
                ),
                // 電流線（已縮放到左軸座標）
                LineChartBarData(
                  spots: currScaledSpots,
                  isCurved: true,
                  isStrokeCapRound: true,
                  barWidth: 2,
                  color: Colors.blue,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(show: false),
                ),
              ],
              gridData: FlGridData(show: true,),
              titlesData: FlTitlesData(
                // 左軸：血糖（mg/dL）
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 30,
                    interval: leftInterval,
                    getTitlesWidget: (value, meta) =>
                        Text(value.toStringAsFixed(0), style: const TextStyle(fontSize: 10)),
                  ),
                  axisNameWidget:
                  const Padding(padding: EdgeInsets.only(right: 4), child: Text('Glu conc (mg/dL)')),
                  axisNameSize: 12,
                ),
                // 右軸：電流（以左軸座標 → 反算顯示 mA）
                rightTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 30,
                    interval: rightInterval,
                    getTitlesWidget: (yOnLeft, meta) {
                      final ma = _scaleFromLeftAxis(yOnLeft, from: gluRange, to: currRange);
                      return Text(ma.toStringAsFixed(2), style: const TextStyle(fontSize: 10));
                    },
                  ),
                  axisNameWidget:
                  const Padding(padding: EdgeInsets.only(left: 4), child: Text('Current(1E-9 A)')),
                  axisNameSize: 12,
                ),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    getTitlesWidget: (value, meta) {
                      // 過濾掉最左 (minX) 和最右 (maxX)
                      if (value == meta.min || value == meta.max) {
                        return const SizedBox.shrink(); // 空白，不顯示
                      }
                      return _buildBottomTimeTitle(value, meta);
                    },
                  ),
                  axisNameWidget: const Padding(padding: EdgeInsets.only(left: 4), child: Text('Time (HH:mm)')),
                ),
              ),
              borderData: FlBorderData(
                show: true,
                border: Border.all(
                  color: Colors.grey,
                  width: 1,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---- helpers ----

  // 依時間排序後轉為 (時間, 值)
  List<FlSpot> _mapToSortedSpots(List<Sample> data, double Function(Sample) pickY) {
    final list = data
        .map((s) => FlSpot(s.ts.millisecondsSinceEpoch.toDouble(), pickY(s)))
        .toList()
      ..sort((a, b) => a.x.compareTo(b.x));
    return list;
  }

  // 無資料時建立佔位（最近 N 秒、小幅起伏）
  List<FlSpot> _buildPlaceholderSpots(int seconds, double baseline) {
    final nowMs = DateTime.now().millisecondsSinceEpoch.toDouble();
    final startMs = nowMs - seconds * 1000;
    return List<FlSpot>.generate(seconds + 1, (i) {
      final t = startMs + i * 1000;
      final w1 = 2 * math.pi / 12;
      final w2 = 2 * math.pi / 30;
      final jitter = math.sin(i * w1) * 0.5 + math.sin(i * w2) * 0.2; // 幅度稍大以便可見
      return FlSpot(t, baseline + jitter);
    });
  }

  // 取血糖（請依你的 Sample 欄位名稱修改）
  double _getGlucose(Sample s) {
    return (s.glucose ?? 0).toDouble();
  }

  // 取電流（請依你的 Sample 欄位名稱修改）
  double _getCurrent(Sample s) {
    // e.g. return (s.current ?? 0).toDouble();
    // 若你的欄位名稱不是 current，請改為正確欄位
    // ignore: invalid_use_of_protected_member
    return (s.current ?? 0).toDouble();
  }

  // y 的線性縮放：把「右軸量測值(電流)」縮放到「左軸座標(血糖)」
  double _scaleToLeftAxis(double y, {required _Range from, required _Range to}) {
    if (from.span == 0) return to.min; // 避免除以 0
    final ratio = (y - from.min) / from.span;
    return to.min + ratio * to.span;
  }

  // 反向縮放：把「左軸座標值(血糖座標)」換回「右軸量測值(電流)」
  double _scaleFromLeftAxis(double yLeft, {required _Range from, required _Range to}) {
    if (from.span == 0) return to.min;
    final ratio = (yLeft - from.min) / from.span;
    return to.min + ratio * to.span;
  }

  _Range _calcRange(Iterable<double> values,
      {double? fixedMin, double? fixedMax, double floor = -double.infinity}) {
    double minV, maxV;
    if (fixedMin != null && fixedMax != null) {
      minV = fixedMin;
      maxV = fixedMax;
    } else if (values.isEmpty) {
      minV = 0;
      maxV = 1;
    } else {
      minV = values.reduce(math.min);
      maxV = values.reduce(math.max);
      // 給 10% padding，並下界不小於 floor
      final pad = (maxV - minV).abs() * 0.1 + 0.001;
      minV = math.max(floor, minV - pad);
      maxV = maxV + pad;
      if (minV == maxV) {
        // 退場機制：避免 span = 0
        minV -= 1;
        maxV += 1;
      }
    }
    return _Range(minV, maxV);
  }

  double _niceInterval(double min, double max, int targetTick) {
    final span = (max - min).abs();
    if (span <= 0) return 1;
    final raw = span / math.max(1, targetTick);
    final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final norm = raw / mag;
    double nice;
    if (norm < 1.5) {
      nice = 1;
    } else if (norm < 3) {
      nice = 2;
    } else if (norm < 7) {
      nice = 5;
    } else {
      nice = 10;
    }
    return nice * mag;
  }

  static Widget _buildBottomTimeTitle(double value, TitleMeta meta) {
    final dt = DateTime.fromMillisecondsSinceEpoch(value.toInt());
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return Text('$hh:$mm', style: const TextStyle(fontSize: 10));
  }
}

class _Range {
  final double min;
  final double max;
  const _Range(this.min, this.max);
  double get span => max - min;
}