import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:intl/intl.dart';

import '../../../../common/utils/date_key.dart';
import '../../data/isar_schemas.dart';
import '../providers/ble_providers.dart';

// ===== 假設的導入（需根據您的項目調整） =====
// import '../../../../common/utils/date_key.dart';
// import '../providers/ble_providers.dart';
// import '../../data/isar_schemas.dart';
// import '../providers/current_glucose_providers.dart';

// ===== 模擬的類型定義（實際使用時請替換為真實類型） =====
// class Sample {
//   final DateTime ts;
//   final double? voltage;
//   final double? temperature;
//   final List<double>? currents;
//
//   Sample({
//     required this.ts,
//     this.voltage,
//     this.temperature,
//     this.currents,
//   });
// }

// 模擬的 Provider（實際使用時請替換）
// final bleConnectionStateProvider = StateProvider<bool>((ref) => false);
final glucoseRangeProvider = StateProvider<GlucoseRange>((ref) => GlucoseRange());

class GlucoseRange {
  final double? min;
  final double? max;
  GlucoseRange({this.min, this.max});
}

// String dayKeyOf(DateTime dt) => '${dt.year}-${dt.month}-${dt.day}';

/// 帶光暈效果的標記繪製器
class GlowingMarkerPainter extends CustomPainter {
  final double radius;
  final Color color;
  final double glowOpacity;
  final double strokeWidth;
  final Color strokeColor;

  GlowingMarkerPainter({
    required this.radius,
    required this.color,
    required this.glowOpacity,
    this.strokeWidth = 0,
    this.strokeColor = Colors.transparent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // 繪製最外層光暈（最淡）
    final outerGlowPaint = Paint()
      ..color = color.withOpacity(glowOpacity * 0.15)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawCircle(center, radius * 2.5, outerGlowPaint);

    // 繪製中層光暈
    final midGlowPaint = Paint()
      ..color = color.withOpacity(glowOpacity * 0.3)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    canvas.drawCircle(center, radius * 1.8, midGlowPaint);

    // 繪製內層光暈
    final innerGlowPaint = Paint()
      ..color = color.withOpacity(glowOpacity * 0.5)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1);
    canvas.drawCircle(center, radius * 1.3, innerGlowPaint);

    // 繪製主圓點
    final mainPaint = Paint()
      ..color = color.withOpacity(glowOpacity)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, mainPaint);

    // 繪製邊框
    if (strokeWidth > 0) {
      final strokePaint = Paint()
        ..color = strokeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth;
      canvas.drawCircle(center, radius, strokePaint);
    }
  }

  @override
  bool shouldRepaint(GlowingMarkerPainter oldDelegate) {
    return oldDelegate.glowOpacity != glowOpacity ||
        oldDelegate.radius != radius ||
        oldDelegate.color != color;
  }
}

/// 曲線數據配置
class LineDataConfig {
  final String id;
  final String label;
  final Color color;
  final List<Sample> samples;
  final double slope;
  final double intercept;
  final bool showDots;

  const LineDataConfig({
    required this.id,
    required this.label,
    required this.color,
    required this.samples,
    this.slope = 600.0,
    this.intercept = 0.0,
    this.showDots = true,
  });
}

/// 圖表數據點
class ChartDataPoint {
  final DateTime time;
  final double value;
  final double? current;
  final bool isLatest;
  final bool isGap;

  ChartDataPoint({
    required this.time,
    required this.value,
    this.current,
    this.isLatest = false,
    this.isGap = false,
  });
}

/// Syncfusion 版本的血糖圖表
///
/// 主要功能：
/// - 雙Y軸：左軸血糖(mg/dL)、右軸電流(nA)
/// - 支援多條線顯示
/// - 單指拖動平移，雙指縮放（橫向控制時間，縱向控制數值）
/// - 時間軸範圍：6分鐘到24小時
/// - 最新數據點閃爍動畫
/// - 數據間隙虛線顯示
/// - 點擊顯示詳細信息
class GlucoseChart extends ConsumerStatefulWidget {
  final String dayKey;
  final List<Sample> samples;
  final double placeholderCurrentA;
  final double slope;
  final double intercept;
  final List<LineDataConfig>? additionalLines;

  const GlucoseChart({
    super.key,
    required this.dayKey,
    required this.samples,
    this.placeholderCurrentA = 0.0,
    this.slope = 600.0,
    this.intercept = 0.0,
    this.additionalLines,
  });

  @override
  ConsumerState<GlucoseChart> createState() =>
      _GlucoseChartSyncfusionState();
}

class _GlucoseChartSyncfusionState extends ConsumerState<GlucoseChart>
    with SingleTickerProviderStateMixin {
  // ===== 常數定義 =====
  static const double minWindowMs = 6 * 60 * 1000.0; // 6分鐘
  static const double maxWindowMs = 24 * 60 * 60 * 1000.0; // 24小時
  static const double defaultWindowMs = 6 * 60 * 1000.0; // 預設6分鐘
  static const double oneMinuteMs = 60 * 1000.0;
  static const int fixedGridCount = 6;
  static const double gapThresholdMs = 90 * 1000.0; // 90秒

  // ===== 狀態變量 =====
  late ZoomPanBehavior _zoomPanBehavior;
  late TrackballBehavior _trackballBehavior;
  late AnimationController _blinkController;
  late Animation<double> _blinkAnimation;

  double _currentWindowWidthMs = defaultWindowMs;
  DateTime? _firstDataTime;
  DateTime? _currentPlotDate;
  bool _isManualMode = false;

  // Y軸範圍控制
  bool _yManual = false;
  double? _yMinManual;
  double? _yMaxManual;

  // 觸控狀態
  final Map<int, Offset> _pointers = {};
  bool _isDragging = false;
  bool _isScaling = false;
  bool _scaleActiveX = false;
  bool _scaleActiveY = false;

  // 縮放相關
  double _scaleStartHorizontalDistance = 0;
  double _scaleStartVerticalDistance = 0;
  double _scaleLastHorizontalDistance = 0;
  double _scaleLastVerticalDistance = 0;
  int _lastScaleTickMs = 0;

  // Y軸縮放會話
  bool _yScaleSessionActive = false;
  double? _yScaleStartMin;
  double? _yScaleStartMax;

  // 拖動相關
  double _dragStartX = 0;
  DateTime _dragStartTime = DateTime.now();

  // 靈敏度設定
  final double _zoomFactorBaseX = 0.002;
  final double _zoomFactorMaxX = 0.05;
  final double _zoomFactorBaseY = 0.002;
  final double _zoomFactorMaxY = 0.05;
  final double _activateThreshold = 0.5;

  // 數據快取
  final Map<String, List<ChartDataPoint>> _cachedDataMap = {};
  int _cachedMainCount = 0;
  final Map<String, int> _cachedAddCount = {};

  // 時間計數器
  Timer? _elapsedTicker;
  int _elapsedSec = 0;
  DateTime? _lastSampleTime;

  // 觸摸點信息
  String? _touchedLineId;
  String? _tooltipText;

  @override
  void initState() {
    super.initState();
    _initializeWindow();
    _initializeZoomPan();
    _initializeTrackball();
    _initializeAnimation();
  }

  void _initializeWindow() {
    DateTime startTime;
    DateTime? earliestTime;

    if (widget.samples.isNotEmpty) {
      earliestTime = widget.samples.first.ts;
    }

    if (widget.additionalLines != null) {
      for (final config in widget.additionalLines!) {
        if (config.samples.isNotEmpty) {
          final firstTime = config.samples.first.ts;
          if (earliestTime == null || firstTime.isBefore(earliestTime)) {
            earliestTime = firstTime;
          }
        }
      }
    }

    if (earliestTime != null) {
      _firstDataTime = earliestTime;
      startTime = DateTime(
        earliestTime.year,
        earliestTime.month,
        earliestTime.day,
        0,
        0,
        0,
        0,
      );
    } else {
      final now = DateTime.now();
      startTime = DateTime(now.year, now.month, now.day, 0, 0, 0, 0);
    }

    _dragStartTime = startTime;
  }

  void _initializeZoomPan() {
    _zoomPanBehavior = ZoomPanBehavior(
      enablePinching: false, // 我們自己處理
      enablePanning: false, // 我們自己處理
      enableDoubleTapZooming: false,
      enableSelectionZooming: false,
    );
  }

  void _initializeTrackball() {
    _trackballBehavior = TrackballBehavior(
      enable: true,
      activationMode: ActivationMode.singleTap,
      lineType: TrackballLineType.vertical,
      tooltipDisplayMode: TrackballDisplayMode.groupAllPoints,
      shouldAlwaysShow: false,
      builder: (BuildContext context, TrackballDetails trackballDetails) {
        return _buildCustomTooltip(trackballDetails);
      },
    );
  }

  void _initializeAnimation() {
    _blinkController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    )..repeat(reverse: true);

    _blinkAnimation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _blinkController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _elapsedTicker?.cancel();
    _blinkController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(GlucoseChart oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.slope != widget.slope ||
        oldWidget.intercept != widget.intercept) {
      if (mounted) {
        setState(() {
          _cachedMainCount = -1;
        });
      }
    }

    if (widget.additionalLines != null) {
      bool hasChanged = false;
      for (int i = 0; i < widget.additionalLines!.length; i++) {
        if (oldWidget.additionalLines != null &&
            i < oldWidget.additionalLines!.length) {
          final oldConfig = oldWidget.additionalLines![i];
          final newConfig = widget.additionalLines![i];
          if (oldConfig.slope != newConfig.slope ||
              oldConfig.intercept != newConfig.intercept ||
              oldConfig.samples.length != newConfig.samples.length) {
            hasChanged = true;
            break;
          }
        }
      }
      if (hasChanged && mounted) {
        setState(() {
          _cachedAddCount.clear();
        });
      }
    }
  }

  // ===== 數據處理方法 =====

  List<Sample> _filterTodaySamples(List<Sample> allSamples) {
    if (allSamples.isEmpty) return [];

    final latestDate = allSamples.last.ts;

    if (_currentPlotDate == null || !_isSameDay(_currentPlotDate!, latestDate)) {
      _currentPlotDate = DateTime(
        latestDate.year,
        latestDate.month,
        latestDate.day,
      );
    }

    return allSamples.where((sample) {
      return _isSameDay(sample.ts, _currentPlotDate!);
    }).toList();
  }

  bool _isSameDay(DateTime date1, DateTime date2) {
    return date1.year == date2.year &&
        date1.month == date2.month &&
        date1.day == date2.day;
  }

  double _currentToGlucose(double currentAmperes,
      {double? slope, double? intercept}) {
    final s = slope ?? widget.slope;
    final i = intercept ?? widget.intercept;
    return s * (currentAmperes * 1e9) + i;
  }

  double _glucoseToCurrent(double glucose, {double? slope, double? intercept}) {
    final s = slope ?? widget.slope;
    if (s == 0) return 0;
    final i = intercept ?? widget.intercept;
    return (glucose - i) / s;
  }

  List<ChartDataPoint> _buildChartData(
      List<Sample> samples,
      double slope,
      double intercept,
      ) {
    if (samples.isEmpty) return [];

    final List<ChartDataPoint> points = [];

    for (int i = 0; i < samples.length; i++) {
      final sample = samples[i];
      final currents = sample.currents;

      if (currents == null || currents.isEmpty) continue;

      final currentA = currents.first.toDouble();
      final glucose = _currentToGlucose(currentA, slope: slope, intercept: intercept);

      // 檢查是否為間隙
      bool isGap = false;
      if (i > 0) {
        final prevTime = samples[i - 1].ts;
        final timeDiff = sample.ts.difference(prevTime).inMilliseconds;
        isGap = timeDiff >= gapThresholdMs;
      }

      points.add(ChartDataPoint(
        time: sample.ts,
        value: glucose,
        current: currentA,
        isLatest: i == samples.length - 1,
        isGap: isGap,
      ));
    }

    return points;
  }

  void _rebuildCachedData() {
    final todayMain = _filterTodaySamples(widget.samples);

    if (todayMain.length != _cachedMainCount) {
      _cachedMainCount = todayMain.length;
      _cachedDataMap['main'] = _buildChartData(
        todayMain,
        widget.slope,
        widget.intercept,
      );
    }

    if (widget.additionalLines != null) {
      for (final config in widget.additionalLines!) {
        final today = _filterTodaySamples(config.samples);
        final key = config.id;
        final prev = _cachedAddCount[key] ?? -1;

        if (today.length != prev) {
          _cachedAddCount[key] = today.length;
          _cachedDataMap[key] = _buildChartData(
            today,
            config.slope,
            config.intercept,
          );
        }
      }
    }
  }

  // ===== 視窗控制方法 =====

  void _advanceWindowIfNeeded(DateTime latestTime) {
    if (_isManualMode) return;
    if (_currentWindowWidthMs >= maxWindowMs * 0.95) return;

    final windowEnd = _dragStartTime.add(Duration(milliseconds: _currentWindowWidthMs.toInt()));

    if (latestTime.isBefore(windowEnd)) return;

    final steps = ((latestTime.millisecondsSinceEpoch - windowEnd.millisecondsSinceEpoch) / oneMinuteMs).floor() + 1;
    _dragStartTime = _dragStartTime.add(Duration(milliseconds: (steps * oneMinuteMs).toInt()));
  }

  void _resetToLatest() {
    setState(() {
      _isManualMode = false;
      _currentWindowWidthMs = defaultWindowMs;
      _initializeWindow();

      DateTime? latestTime;

      final todaySamples = _filterTodaySamples(widget.samples);
      if (todaySamples.isNotEmpty) {
        latestTime = todaySamples.last.ts;
      }

      if (widget.additionalLines != null) {
        for (final config in widget.additionalLines!) {
          final samples = _filterTodaySamples(config.samples);
          if (samples.isNotEmpty) {
            final t = samples.last.ts;
            if (latestTime == null || t.isAfter(latestTime)) {
              latestTime = t;
            }
          }
        }
      }

      if (latestTime != null) {
        _advanceWindowIfNeeded(latestTime);
      }

      _yManual = false;
      _yMinManual = _yMaxManual = null;
    });
  }

  DateTime get _windowEnd => _dragStartTime.add(Duration(milliseconds: _currentWindowWidthMs.toInt()));

  List<ChartDataPoint> _filterByWindow(List<ChartDataPoint> allPoints) {
    return allPoints.where((point) {
      return !point.time.isBefore(_dragStartTime) && !point.time.isAfter(_windowEnd);
    }).toList();
  }

  // ===== 觸控處理方法 =====

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;

    if (_pointers.length == 1) {
      final pos = _pointers.values.first;
      _dragStartX = pos.dx;
      _isDragging = false;
      _isScaling = false;
      _scaleActiveX = false;
      _scaleActiveY = false;
    } else if (_pointers.length == 2) {
      final positions = _pointers.values.toList();
      final dx = (positions[0].dx - positions[1].dx).abs();
      final dy = (positions[0].dy - positions[1].dy).abs();

      _scaleStartHorizontalDistance = dx;
      _scaleStartVerticalDistance = dy;

      final (yMin, yMax) = _computeCurrentYRange();
      _yScaleSessionActive = true;
      _yScaleStartMin = yMin;
      _yScaleStartMax = yMax;

      _scaleActiveX = false;
      _scaleActiveY = false;
      _scaleLastHorizontalDistance = dx;
      _scaleLastVerticalDistance = dy;
      _lastScaleTickMs = DateTime.now().millisecondsSinceEpoch;

      setState(() {
        _isScaling = true;
        _isDragging = false;
      });
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    _pointers[event.pointer] = event.localPosition;

    if (_pointers.length == 1) {
      final pos = _pointers.values.first;
      final currentX = pos.dx;
      final deltaX = currentX - _dragStartX;

      if (deltaX.abs() > 2) {
        _isDragging = true;
        _isScaling = false;
        _handleHorizontalDrag(deltaX);
        _dragStartX = currentX;
      }
    } else if (_pointers.length >= 2) {
      final positions = _pointers.values.toList();
      final dx = (positions[0].dx - positions[1].dx).abs();
      final dy = (positions[0].dy - positions[1].dy).abs();
      final nowMs = DateTime.now().millisecondsSinceEpoch;

      // X軸縮放（橫向）
      if (!_scaleActiveX) {
        final denom = _scaleStartHorizontalDistance == 0 ? dx : _scaleStartHorizontalDistance;
        final ratioFromStart = dx / (denom == 0 ? 1.0 : denom);
        if ((ratioFromStart - 1.0).abs() >= _activateThreshold) {
          _scaleActiveX = true;
          _scaleLastHorizontalDistance = dx;
        }
      }

      if (_scaleActiveX) {
        final prev = _scaleLastHorizontalDistance <= 0 ? dx : _scaleLastHorizontalDistance;
        double rawStepX = (dx <= 0 ? 0.0001 : dx) / prev;
        final stepDeltaX = rawStepX - 1.0;

        final dtSec = math.max(0.001, (nowMs - _lastScaleTickMs) / 1000.0);
        final distChangeRatioPerSec = (dx - prev).abs() / math.max(1.0, prev) / dtSec;

        final dynamicFactorX = (_zoomFactorBaseX +
            (_zoomFactorMaxX - _zoomFactorBaseX) * (distChangeRatioPerSec / 2.0))
            .clamp(_zoomFactorBaseX, _zoomFactorMaxX);

        double scaleX = 1.0 + stepDeltaX * dynamicFactorX;
        if (scaleX.isNaN || !scaleX.isFinite) scaleX = 1.0;
        scaleX = scaleX.clamp(0.85, 1.20);

        _applyXAxisScale(scaleX);
        _scaleLastHorizontalDistance = dx;
      }

      // Y軸縮放（縱向）
      if (!_scaleActiveY) {
        final denom = _scaleStartVerticalDistance == 0 ? dy : _scaleStartVerticalDistance;
        final ratioFromStart = dy / (denom == 0 ? 1.0 : denom);
        if ((ratioFromStart - 1.0).abs() >= _activateThreshold) {
          _scaleActiveY = true;
          _scaleLastVerticalDistance = dy;
        }
      }

      if (_scaleActiveY) {
        final prev = _scaleLastVerticalDistance <= 0 ? dy : _scaleLastVerticalDistance;
        double rawStepY = (dy <= 0 ? 0.0001 : dy) / prev;
        final stepDeltaY = rawStepY - 1.0;

        final dtSec = math.max(0.001, (nowMs - _lastScaleTickMs) / 1000.0);
        final distChangeRatioPerSec = (dy - prev).abs() / math.max(1.0, prev) / dtSec;

        final dynamicFactorY = (_zoomFactorBaseY +
            (_zoomFactorMaxY - _zoomFactorBaseY) * (distChangeRatioPerSec / 2.0))
            .clamp(_zoomFactorBaseY, _zoomFactorMaxY);

        double scaleY = 1.0 + stepDeltaY * dynamicFactorY;
        if (scaleY.isNaN || !scaleY.isFinite) scaleY = 1.0;
        scaleY = scaleY.clamp(0.85, 1.20);

        _applyYAxisScale(scaleY);
        _scaleLastVerticalDistance = dy;
      }

      _lastScaleTickMs = nowMs;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);

    if (_pointers.isEmpty) {
      if (_isDragging || _isScaling) {
        _alignWindowToMinute();
      }
      setState(() {
        _isDragging = false;
        _isScaling = false;
        _scaleActiveX = false;
        _scaleActiveY = false;
        _yScaleSessionActive = false;
        _yScaleStartMin = null;
        _yScaleStartMax = null;
      });
    } else if (_pointers.length == 1 && _isScaling) {
      setState(() {
        _isScaling = false;
        _isDragging = false;
        _scaleActiveX = false;
        _scaleActiveY = false;
      });
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isEmpty) {
      setState(() {
        _isDragging = false;
        _isScaling = false;
        _scaleActiveX = false;
        _scaleActiveY = false;
        _yScaleSessionActive = false;
        _yScaleStartMin = null;
        _yScaleStartMax = null;
      });
    }
  }

  void _handleHorizontalDrag(double delta) {
    setState(() {
      _isManualMode = true;

      final windowWidth = _currentWindowWidthMs;
      final dragRatio = delta / 300.0;
      final timeDelta = windowWidth * dragRatio;

      final newStartTime = _dragStartTime.subtract(Duration(milliseconds: timeDelta.toInt()));

      // 限制拖動範圍
      DateTime? firstDataTime;
      DateTime? lastDataTime;

      final todaySamples = _filterTodaySamples(widget.samples);
      if (todaySamples.isNotEmpty) {
        firstDataTime = todaySamples.first.ts;
        lastDataTime = todaySamples.last.ts;
      }

      if (widget.additionalLines != null) {
        for (final config in widget.additionalLines!) {
          final samples = _filterTodaySamples(config.samples);
          if (samples.isNotEmpty) {
            final first = samples.first.ts;
            final last = samples.last.ts;

            if (firstDataTime == null || first.isBefore(firstDataTime)) {
              firstDataTime = first;
            }
            if (lastDataTime == null || last.isAfter(lastDataTime)) {
              lastDataTime = last;
            }
          }
        }
      }

      if (firstDataTime != null && lastDataTime != null) {
        final newEndTime = newStartTime.add(Duration(milliseconds: windowWidth.toInt()));

        if (newStartTime.isBefore(firstDataTime)) {
          _dragStartTime = firstDataTime;
          return;
        }

        if (newEndTime.isAfter(lastDataTime.add(Duration(milliseconds: windowWidth.toInt())))) {
          _dragStartTime = lastDataTime.add(Duration(milliseconds: windowWidth.toInt()))
              .subtract(Duration(milliseconds: windowWidth.toInt()));
          return;
        }
      }

      _dragStartTime = newStartTime;
    });
  }

  void _alignWindowToMinute() {
    setState(() {
      final alignedStart = DateTime(
        _dragStartTime.year,
        _dragStartTime.month,
        _dragStartTime.day,
        _dragStartTime.hour,
        _dragStartTime.minute,
        0,
        0,
      );
      _dragStartTime = alignedStart;
    });
  }

  void _applyXAxisScale(double scaleX) {
    setState(() {
      _isManualMode = true;

      final newWinX = (_currentWindowWidthMs / scaleX).clamp(minWindowMs, maxWindowMs);
      final windowCenter = _dragStartTime.add(Duration(milliseconds: (_currentWindowWidthMs / 2).toInt()));

      _dragStartTime = windowCenter.subtract(Duration(milliseconds: (newWinX / 2).toInt()));
      _currentWindowWidthMs = newWinX;

      // 對齊到整分鐘
      final alignedStart = DateTime(
        _dragStartTime.year,
        _dragStartTime.month,
        _dragStartTime.day,
        _dragStartTime.hour,
        _dragStartTime.minute,
        0,
        0,
      );
      _dragStartTime = alignedStart;
    });
  }

  void _applyYAxisScale(double scaleY) {
    setState(() {
      if (!_yScaleSessionActive || _yScaleStartMin == null || _yScaleStartMax == null) {
        final (yMin0, yMax0) = _computeCurrentYRange();
        _yScaleSessionActive = true;
        _yScaleStartMin = yMin0;
        _yScaleStartMax = yMax0;
      }

      final span0 = (_yScaleStartMax! - _yScaleStartMin!).abs().clamp(1e-6, 1e9);
      final center0 = (_yScaleStartMax! + _yScaleStartMin!) / 2.0;

      final spanNew = (span0 / scaleY).clamp(1.0, 10000.0);
      _yMinManual = center0 - spanNew / 2.0;
      _yMaxManual = center0 + spanNew / 2.0;
      _yManual = true;
    });
  }

  (double, double) _computeCurrentYRange() {
    if (_yManual && _yMinManual != null && _yMaxManual != null) {
      return (_yMinManual!, _yMaxManual!);
    }

    final allY = <double>[];
    for (final dataList in _cachedDataMap.values) {
      allY.addAll(dataList.map((e) => e.value));
    }

    if (allY.isEmpty) return (0.0, 400.0);

    final minV = allY.reduce(math.min);
    final maxV = allY.reduce(math.max);
    final span = (maxV - minV).abs();
    final pad = span * 0.15 + 1e-12;

    return (minV - pad, maxV + pad);
  }

  // ===== 時間相關方法 =====

  void _startElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsedSec += 1;
      });
    });
  }

  void _stopElapsedTicker({bool reset = false}) {
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
    if (reset && mounted) {
      setState(() {
        _elapsedSec = 0;
      });
    }
  }

  String _formatElapsed(int sec) {
    if (sec < 60) return '${sec.toString().padLeft(2, '0')}s';
    final m = sec ~/ 60;
    final s = sec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}:'
          '${dt.second.toString().padLeft(2, '0')}';

  String _formatWindowDuration(double durationMs) {
    final minutes = durationMs / oneMinuteMs;
    if (minutes < 1) {
      return '${(minutes * 60).toStringAsFixed(0)} 秒';
    } else if (minutes < 60) {
      return '${minutes.toStringAsFixed(0)} 分鐘';
    } else {
      final hours = minutes / 60;
      if (hours >= 24) {
        return '24 小時';
      } else if (hours.floor() == hours) {
        return '${hours.toStringAsFixed(0)} 小時';
      } else {
        return '${hours.toStringAsFixed(1)} 小時';
      }
    }
  }

  // ===== Y軸範圍計算 =====

  (double, double) _calculateYAxisRange() {
    final glucoseRange = ref.watch(glucoseRangeProvider);
    final hasUserRange = glucoseRange.min != null && glucoseRange.max != null;

    if (_yManual && _yMinManual != null && _yMaxManual != null) {
      return (_yMinManual!, _yMaxManual!);
    }

    final allY = <double>[];
    for (final entry in _cachedDataMap.entries) {
      final filtered = _filterByWindow(entry.value);
      allY.addAll(filtered.map((e) => e.value));
    }

    if (allY.isEmpty) return (0.0, 400.0);

    if (hasUserRange) {
      return (glucoseRange.min!, glucoseRange.max!);
    }

    final minV = allY.reduce(math.min);
    final maxV = allY.reduce(math.max);
    final span = (maxV - minV).abs();
    final pad = span * 0.15 + 10.0;

    return (minV - pad, maxV + pad);
  }

  // ===== UI 組件建構方法 =====

  Widget _buildCustomTooltip(TrackballDetails details) {
    if (details.groupingModeInfo == null) return const SizedBox.shrink();

    final points = details.groupingModeInfo!.points;
    if (points.isEmpty) return const SizedBox.shrink();

    final pointInfo = points.first;

    // 獲取數據點 - 直接從 x 和 y 值
    final xValue = pointInfo.x;
    final yValue = pointInfo.y;

    if (xValue == null || yValue == null) return const SizedBox.shrink();

    DateTime time;
    if (xValue is DateTime) {
      time = xValue;
    } else if (xValue is num) {
      time = DateTime.fromMillisecondsSinceEpoch(xValue.toInt());
    } else {
      return const SizedBox.shrink();
    }

    final timeStr = _formatTime(time);
    final glucoseStr = (yValue as num).toStringAsFixed(2);

    // 計算電流值
    final glucose = yValue as double;
    final currentNa = _glucoseToCurrent(glucose);
    final currentStr = currentNa.toStringAsFixed(2);

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.9),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        '時間: $timeStr\n血糖: $glucoseStr mg/dL\n電流: $currentStr nA',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildStatusIndicators() {
    return Stack(
      children: [
        if (_isScaling)
          Positioned(
            right: 16,
            top: 60,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.9),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.zoom_in, color: Colors.white, size: 16),
                  const SizedBox(width: 4),
                  Text(
                    '縮放中 (橫向${_scaleActiveX ? '✓' : ''} 縱向${_scaleActiveY ? '✓' : ''})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_isDragging)
          Positioned(
            right: 16,
            top: 60,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.9),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.pan_tool, color: Colors.white, size: 16),
                  SizedBox(width: 4),
                  Text(
                    '平移中',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_isManualMode)
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.small(
              onPressed: _resetToLatest,
              backgroundColor: Colors.blue,
              child: const Icon(Icons.refresh, size: 20),
            ),
          ),
        Positioned(
          left: 16,
          top: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _formatWindowDuration(_currentWindowWidthMs),
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }

  // ===== 主要 build 方法 =====

  @override
  Widget build(BuildContext context) {
    // 監聽 BLE 連接狀態
    ref.listen<bool>(bleConnectionStateProvider, (prev, next) {
      if (next == true) {
        if (_lastSampleTime != null && _elapsedTicker == null) {
          _startElapsedTicker();
        }
      } else {
        _stopElapsedTicker(reset: true);
        _lastSampleTime = null;
      }
    });

    final todayKey = dayKeyOf(DateTime.now());
    final isToday = widget.dayKey == todayKey;
    final bleConnected = ref.watch(bleConnectionStateProvider);

    // 重建快取數據
    _rebuildCachedData();

    // 處理最新數據
    final todaySamples = _filterTodaySamples(widget.samples);
    final hasData = todaySamples.isNotEmpty;

    if (hasData) {
      final newLast = todaySamples.last.ts;
      final isNewPoint = _lastSampleTime == null || newLast.isAfter(_lastSampleTime!);

      if (isNewPoint) {
        _lastSampleTime = newLast;
        _elapsedSec = 0;
        if (bleConnected) {
          _startElapsedTicker();
        } else {
          _stopElapsedTicker(reset: false);
        }
      }

      _advanceWindowIfNeeded(newLast);
    } else {
      _lastSampleTime = null;
      _stopElapsedTicker(reset: true);
    }

    // 獲取最新樣本數據
    final latestSample = hasData ? todaySamples.last : null;
    final voltage = latestSample?.voltage;
    final temperature = latestSample?.temperature;
    final currentA = (() {
      final list = latestSample?.currents;
      if (list == null || list.isEmpty) return null;
      return list.first.toDouble();
    })();
    final timestamp = latestSample != null ? _formatTime(latestSample.ts) : '--:--:--';

    final glucoseFromCurrent = currentA != null
        ? _currentToGlucose(currentA).toStringAsFixed(1)
        : '--';

    final currentDisplay = currentA != null
        ? (currentA.abs() < 1e-6
        ? currentA.toStringAsExponential(3).toUpperCase()
        : currentA.toStringAsFixed(6))
        : '--';

    // 計算 Y 軸範圍
    final (yMin, yMax) = _calculateYAxisRange();

    // 準備系列數據
    final List<LineSeries<ChartDataPoint, DateTime>> seriesList = [];

    // 主線數據
    final mainData = _cachedDataMap['main'] ?? [];
    final mainFiltered = _filterByWindow(mainData);

    if (mainFiltered.isNotEmpty) {
      // 連續線段
      final List<List<ChartDataPoint>> continuousSegments = [];
      List<ChartDataPoint> currentSegment = [];

      for (int i = 0; i < mainFiltered.length; i++) {
        final point = mainFiltered[i];
        currentSegment.add(point);

        if (i < mainFiltered.length - 1 && mainFiltered[i + 1].isGap) {
          if (currentSegment.length >= 2) {
            continuousSegments.add(List.from(currentSegment));
          }
          currentSegment = [];
        } else if (i == mainFiltered.length - 1) {
          if (currentSegment.length >= 2) {
            continuousSegments.add(List.from(currentSegment));
          }
        }
      }

      for (final segment in continuousSegments) {
        seriesList.add(
          LineSeries<ChartDataPoint, DateTime>(
            dataSource: segment,
            xValueMapper: (ChartDataPoint point, _) => point.time,
            yValueMapper: (ChartDataPoint point, _) => point.value,
            color: Colors.blue,
            width: 2,
            markerSettings: MarkerSettings(
              isVisible: true,
              height: 6,
              width: 6,
              shape: DataMarkerType.circle,
              borderWidth: 1.5,
              borderColor: Colors.white,
            ),
          ),
        );
      }

      // 間隙虛線
      for (int i = 0; i < mainFiltered.length - 1; i++) {
        if (mainFiltered[i + 1].isGap) {
          seriesList.add(
            LineSeries<ChartDataPoint, DateTime>(
              dataSource: [mainFiltered[i], mainFiltered[i + 1]],
              xValueMapper: (ChartDataPoint point, _) => point.time,
              yValueMapper: (ChartDataPoint point, _) => point.value,
              color: Colors.blue.withOpacity(0.5),
              width: 1.5,
              dashArray: const <double>[5, 5],
              markerSettings: const MarkerSettings(isVisible: false),
            ),
          );
        }
      }
    }

    // 附加線數據
    if (widget.additionalLines != null) {
      for (final config in widget.additionalLines!) {
        final data = _cachedDataMap[config.id] ?? [];
        final filtered = _filterByWindow(data);

        if (filtered.isNotEmpty) {
          // 連續線段
          final List<List<ChartDataPoint>> continuousSegments = [];
          List<ChartDataPoint> currentSegment = [];

          for (int i = 0; i < filtered.length; i++) {
            final point = filtered[i];
            currentSegment.add(point);

            if (i < filtered.length - 1 && filtered[i + 1].isGap) {
              if (currentSegment.length >= 2) {
                continuousSegments.add(List.from(currentSegment));
              }
              currentSegment = [];
            } else if (i == filtered.length - 1) {
              if (currentSegment.length >= 2) {
                continuousSegments.add(List.from(currentSegment));
              }
            }
          }

          for (final segment in continuousSegments) {
            seriesList.add(
              LineSeries<ChartDataPoint, DateTime>(
                dataSource: segment,
                xValueMapper: (ChartDataPoint point, _) => point.time,
                yValueMapper: (ChartDataPoint point, _) => point.value,
                color: config.color,
                width: 2,
                markerSettings: config.showDots
                    ? MarkerSettings(
                  isVisible: true,
                  height: 6,
                  width: 6,
                  shape: DataMarkerType.circle,
                  borderWidth: 1.5,
                  borderColor: Colors.white,
                )
                    : const MarkerSettings(isVisible: false),
              ),
            );
          }

          // 間隙虛線
          for (int i = 0; i < filtered.length - 1; i++) {
            if (filtered[i + 1].isGap) {
              seriesList.add(
                LineSeries<ChartDataPoint, DateTime>(
                  dataSource: [filtered[i], filtered[i + 1]],
                  xValueMapper: (ChartDataPoint point, _) => point.time,
                  yValueMapper: (ChartDataPoint point, _) => point.value,
                  color: config.color.withOpacity(0.5),
                  width: 1.5,
                  dashArray: const <double>[5, 5],
                  markerSettings: const MarkerSettings(isVisible: false),
                ),
              );
            }
          }
        }
      }
    }

    return Column(
      children: [
        // 資訊面板
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0, left: 1, right: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('電池：${voltage?.toStringAsFixed(3) ?? '--'} (V)'),
                      Text('電流：$currentDisplay A'),
                      Text('時間：$timestamp'),
                      if (isToday && bleConnected && _lastSampleTime != null)
                        Text('距上一筆：${_formatElapsed(_elapsedSec)}'),
                      Text('溫度：${temperature?.toStringAsFixed(2) ?? '--'} ℃'),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(
                              color: Colors.blue,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Text(
                            '主線(Raw Data)',
                            style: TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      glucoseFromCurrent,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 48),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text('mg/dL', style: TextStyle(fontSize: 16)),
                ],
              ),
            ],
          ),
        ),

        // 圖表
        Expanded(
          child: AnimatedBuilder(
            animation: _blinkAnimation,
            builder: (context, child) {
              return Stack(
                children: [
                  Listener(
                    onPointerDown: _onPointerDown,
                    onPointerMove: _onPointerMove,
                    onPointerUp: _onPointerUp,
                    onPointerCancel: _onPointerCancel,
                    child: GestureDetector(
                      onDoubleTap: () {
                        setState(() {
                          _isManualMode = false;
                          _currentWindowWidthMs = defaultWindowMs;
                          _initializeWindow();
                          _yManual = false;
                          _yMinManual = _yMaxManual = null;
                        });
                      },
                      child: SfCartesianChart(
                        zoomPanBehavior: _zoomPanBehavior,
                        trackballBehavior: _trackballBehavior,
                        primaryXAxis: DateTimeAxis(
                          minimum: _dragStartTime,
                          maximum: _windowEnd,
                          intervalType: DateTimeIntervalType.auto,
                          dateFormat: DateFormat('HH:mm'),
                          majorGridLines: const MajorGridLines(width: 1, color: Colors.grey),
                          title: const AxisTitle(text: 'Time (HH:mm)'),
                        ),
                        primaryYAxis: NumericAxis(
                          minimum: yMin,
                          maximum: yMax,
                          majorGridLines: const MajorGridLines(width: 1, color: Colors.grey),
                          title: const AxisTitle(text: 'Glu conc (mg/dL)'),
                        ),
                        axes: <ChartAxis>[
                          NumericAxis(
                            name: 'yAxisCurrent',
                            opposedPosition: true,
                            minimum: _glucoseToCurrent(yMin),
                            maximum: _glucoseToCurrent(yMax),
                            majorGridLines: const MajorGridLines(width: 0),
                            title: const AxisTitle(text: 'Current (1E-9 A)'),
                          ),
                        ],
                        series: seriesList,
                      ),
                    ),
                  ),
                  _buildStatusIndicators(),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

// 需要導入的包（添加到 pubspec.yaml）：
// dependencies:
//   syncfusion_flutter_charts: ^31.2.4
//   intl: ^0.19.0