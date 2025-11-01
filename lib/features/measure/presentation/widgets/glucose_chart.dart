import 'dart:async';
import 'dart:math' as math;
import '../../../../common/utils/date_key.dart';
import '../providers/ble_providers.dart';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/isar_schemas.dart';
import '../providers/current_glucose_providers.dart';

/// 帶光暈效果的點繪製器
class GlowingDotPainter extends FlDotPainter {
  final double radius;
  final Color color;
  final double glowOpacity;
  final double strokeWidth;
  final Color strokeColor;

  GlowingDotPainter({
    required this.radius,
    required this.color,
    required this.glowOpacity,
    this.strokeWidth = 0,
    this.strokeColor = Colors.transparent,
  });

  @override
  void draw(Canvas canvas, FlSpot spot, Offset offsetInCanvas) {
    // 繪製最外層光暈（最淡）
    final outerGlowPaint = Paint()
      ..color = color.withOpacity(glowOpacity * 0.15)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawCircle(offsetInCanvas, radius * 2.5, outerGlowPaint);

    // 繪製中層光暈
    final midGlowPaint = Paint()
      ..color = color.withOpacity(glowOpacity * 0.3)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    canvas.drawCircle(offsetInCanvas, radius * 1.8, midGlowPaint);

    // 繪製內層光暈
    final innerGlowPaint = Paint()
      ..color = color.withOpacity(glowOpacity * 0.5)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1);
    canvas.drawCircle(offsetInCanvas, radius * 1.3, innerGlowPaint);

    // 繪製主圓點
    final mainPaint = Paint()
      ..color = color.withOpacity(glowOpacity)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(offsetInCanvas, radius, mainPaint);

    // 繪製邊框
    if (strokeWidth > 0) {
      final strokePaint = Paint()
        ..color = strokeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth;
      canvas.drawCircle(offsetInCanvas, radius, strokePaint);
    }
  }

  @override
  Size getSize(FlSpot spot) {
    return Size(radius * 6, radius * 6); // 留足空間給光暈效果
  }

  @override
  FlDotPainter lerp(FlDotPainter a, FlDotPainter b, double t) {
    return this;
  }

  @override
  // TODO: implement mainColor
  Color get mainColor => throw UnimplementedError();

  @override
  // TODO: implement props
  List<Object?> get props => throw UnimplementedError();
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

  @override
  String toString() {
    return 'LineDataConfig('
        'id: $id, '
        'label: $label, '
        'color: ${color.value.toRadixString(16)}, '
        'samples: ${samples.length}, '
        'slope: $slope, '
        'intercept: $intercept, '
        'showDots: $showDots'
        ')';
  }
}

/// 雙 Y 軸曲線圖：左軸=血糖(mg/dL)、右軸=電流(nA)
/// - 換算關係:血糖(mg/dL) = slope × 電流(A) × 1E9 + intercept
/// - Y軸範圍由 Riverpod Provider 控制（固定或自動）
/// - X軸支援雙指縮放：6分鐘 ~ 24小時，固定6格顯示
/// - 初始顯示：6分鐘視窗
/// - 縮放至最小：6分鐘窗口（每格1分鐘）
/// - 縮放至最大：24小時（每格4小時）
/// - **兩指橫向縮放控制時間軸，縱向縮放控制數值軸**
/// - **單指平移查看歷史數據 - 使用真正的平移效果，不重繪曲線**
class GlucoseChart extends ConsumerStatefulWidget {
  final String dayKey;
  final List<Sample> samples;
  final double placeholderCurrentA;
  final double slope;
  final double intercept;

  // 多曲線配置
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
  ConsumerState<GlucoseChart> createState() => _GlucoseChartState();
}

class _GlucoseChartState extends ConsumerState<GlucoseChart> with SingleTickerProviderStateMixin {
  // ✅ 縮放範圍：6分鐘 到 24小時，固定6格
  static const double minWindowMs = 6 * 60 * 1000.0;  // 最小 6 分鐘（每格1分鐘）
  static const double maxWindowMs = 24 * 60 * 60 * 1000.0;  // 最大 24 小時（每格4小時）
  static const double defaultWindowMs = 6 * 60 * 1000.0;  // 預設 6 分鐘
  static const double oneMinuteMs = 60 * 1000.0;
  static const int fixedGridCount = 6;  // 固定 6 格

  late double _tStartMs;
  late double _tEndMs;
  late double _currentWindowWidthMs;
  DateTime? _firstDataTime;

  bool _isManualMode = false;

  // 閃爍動畫控制器
  late AnimationController _blinkController;
  late Animation<double> _blinkAnimation;

  // === Y 軸縮放會話狀態 ===
  bool _yScaleSessionActive = false;
  double? _yScaleStartMin;
  double? _yScaleStartMax;

  // ✅ 手動追蹤觸摸點
  final Map<int, Offset> _pointers = {};
  bool _isDragging = false;
  bool _isScaling = false;

  // 拖動相關 - 改進平移體驗
  double _dragStartX = 0;
  double _dragStartTimeMs = 0;  // 記錄拖動開始時的時間起點

  // 縮放相關 - 分離 X/Y 控制
  double _scaleStartHorizontalDistance = 0;  // 橫向距離（控制時間）
  double _scaleStartVerticalDistance = 0;    // 縱向距離（控制數值）
  double _scaleLastHorizontalDistance = 0;
  double _scaleLastVerticalDistance = 0;
  bool _scaleActiveX = false;  // X 軸縮放是否啟動
  bool _scaleActiveY = false;  // Y 軸縮放是否啟動
  int _lastScaleTickMs = 0;

  // 縮放靈敏度
  double _zoomFactorBaseX = 0.002;  // X 軸基礎靈敏度
  double _zoomFactorMaxX = 0.05;    // X 軸最高靈敏度
  double _zoomFactorBaseY = 0.002;  // Y 軸基礎靈敏度
  double _zoomFactorMaxY = 0.05;    // Y 軸最高靈敏度
  double _activateThreshold = 0.5;  // 啟動門檻

  // 觸摸點狀態
  String? _touchedLineId;
  double? _touchedY;
  double? _touchedX;
  String? _tooltipText;

  // 保存原始採樣數據（支援多條線）
  List<FlSpot> _rawCurrentSpots = [];
  final Map<String, List<FlSpot>> _rawSpotsMap = {};

  // === 快取（整天）===
  List<FlSpot> _cachedMainGlucose = [];
  final Map<String, List<FlSpot>> _cachedAddGlucose = {};
  int _cachedMainCount = 0;
  final Map<String, int> _cachedAddCount = {};

  // === Y 軸手動模式 ===
  bool _yManual = false;
  double? _yMinManual;
  double? _yMaxManual;

  // 記錄當前繪圖的日期
  DateTime? _currentPlotDate;

  // 「自上一筆」累積秒數
  Timer? _elapsedTicker;
  int _elapsedSec = 0;
  DateTime? _lastSampleTime;

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

  @override
  void initState() {
    super.initState();
    _currentWindowWidthMs = defaultWindowMs;
    _initializeWindow();

    // 初始化閃爍動畫（0.8秒一個循環）
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

    _tStartMs = startTime.millisecondsSinceEpoch.toDouble();
    _tEndMs = _tStartMs + _currentWindowWidthMs;
  }

  void _advanceWindowIfNeeded(double latestX) {
    if (_isManualMode) return;

    if (_currentWindowWidthMs >= maxWindowMs * 0.95) return;

    if (latestX < _tEndMs) return;

    final steps = ((latestX - _tEndMs) / oneMinuteMs).floor() + 1;
    _tStartMs += steps * oneMinuteMs;
    _tEndMs += steps * oneMinuteMs;
  }

  void _resetToLatest() {
    setState(() {
      _isManualMode = false;
      _currentWindowWidthMs = defaultWindowMs;
      _initializeWindow();

      double? latestX;

      final todaySamples = _filterTodaySamples(widget.samples);
      if (todaySamples.isNotEmpty) {
        latestX = todaySamples.last.ts.millisecondsSinceEpoch.toDouble();
      }

      if (widget.additionalLines != null) {
        for (final config in widget.additionalLines!) {
          final samples = _filterTodaySamples(config.samples);
          if (samples.isNotEmpty) {
            final x = samples.last.ts.millisecondsSinceEpoch.toDouble();
            if (latestX == null || x > latestX) {
              latestX = x;
            }
          }
        }
      }

      if (latestX != null) {
        _advanceWindowIfNeeded(latestX);
      }

      _yManual = false;
      _yMinManual = _yMaxManual = null;
    });
  }

  // ✅ 改進的水平拖動 - 更平滑的平移體驗
  void _handleHorizontalDrag(double delta) {
    setState(() {
      _isManualMode = true;

      // 使用固定的靈敏度比例，避免視窗大小影響平移速度
      final windowWidth = _tEndMs - _tStartMs;
      // 改用螢幕寬度的比例來計算，假設圖表寬度約為螢幕寬度
      final dragRatio = delta / 300.0;  // 假設圖表寬度約 300 像素
      final timeDelta = windowWidth * dragRatio;

      final newStartMs = _tStartMs - timeDelta;
      final newEndMs = _tEndMs - timeDelta;

      // 從所有線中找出數據範圍
      double? firstDataMs;
      double? lastDataMs;

      final todaySamples = _filterTodaySamples(widget.samples);
      if (todaySamples.isNotEmpty) {
        firstDataMs = todaySamples.first.ts.millisecondsSinceEpoch.toDouble();
        lastDataMs = todaySamples.last.ts.millisecondsSinceEpoch.toDouble();
      }

      if (widget.additionalLines != null) {
        for (final config in widget.additionalLines!) {
          final samples = _filterTodaySamples(config.samples);
          if (samples.isNotEmpty) {
            final firstMs = samples.first.ts.millisecondsSinceEpoch.toDouble();
            final lastMs = samples.last.ts.millisecondsSinceEpoch.toDouble();

            if (firstDataMs == null || firstMs < firstDataMs) {
              firstDataMs = firstMs;
            }
            if (lastDataMs == null || lastMs > lastDataMs) {
              lastDataMs = lastMs;
            }
          }
        }
      }

      // 限制拖動範圍
      if (firstDataMs != null && lastDataMs != null) {
        if (newStartMs < firstDataMs) {
          _tStartMs = firstDataMs;
          _tEndMs = _tStartMs + windowWidth;
          return;
        }

        if (newEndMs > lastDataMs + windowWidth) {
          _tEndMs = lastDataMs + windowWidth;
          _tStartMs = _tEndMs - windowWidth;
          return;
        }
      }

      _tStartMs = newStartMs;
      _tEndMs = newEndMs;
    });
  }

  void _alignWindowToMinute() {
    setState(() {
      final startTime = DateTime.fromMillisecondsSinceEpoch(_tStartMs.toInt());
      final alignedStart = DateTime(
        startTime.year, startTime.month, startTime.day,
        startTime.hour, startTime.minute, 0, 0,
      );
      final windowWidth = _tEndMs - _tStartMs;
      _tStartMs = alignedStart.millisecondsSinceEpoch.toDouble();
      _tEndMs = _tStartMs + windowWidth;
    });
  }

  // ✅ 分離的 X 軸縮放（橫向控制時間）
  void _applyXAxisScale(double scaleX) {
    setState(() {
      _isManualMode = true;

      // ✅ scaleX > 1: 手指橫向分開 → 放大（窗口變小，往分鐘移動）
      // ✅ scaleX < 1: 手指橫向接近 → 縮小（窗口變大，往小時移動）
      final newWinX = (_currentWindowWidthMs / scaleX).clamp(minWindowMs, maxWindowMs);
      final cx = (_tStartMs + _tEndMs) / 2;
      _tStartMs = cx - newWinX / 2;
      _tEndMs = cx + newWinX / 2;
      _currentWindowWidthMs = newWinX;

      // X 起點對齊整分鐘
      final startTime = DateTime.fromMillisecondsSinceEpoch(_tStartMs.toInt());
      final alignedStart = DateTime(
        startTime.year, startTime.month, startTime.day,
        startTime.hour, startTime.minute, 0, 0,
      );
      _tStartMs = alignedStart.millisecondsSinceEpoch.toDouble();
      _tEndMs = _tStartMs + newWinX;
    });
  }

  // ✅ 分離的 Y 軸縮放（縱向控制數值）
  void _applyYAxisScale(double scaleY) {
    setState(() {
      // 若還沒建立會話基準，立即建立
      if (!_yScaleSessionActive || _yScaleStartMin == null || _yScaleStartMax == null) {
        final (yMin0, yMax0) = _computeCurrentYRangeForZoom();
        _yScaleSessionActive = true;
        _yScaleStartMin = yMin0;
        _yScaleStartMax = yMax0;
      }

      final span0 = (_yScaleStartMax! - _yScaleStartMin!).abs().clamp(1e-6, 1e9);
      final center0 = (_yScaleStartMax! + _yScaleStartMin!) / 2.0;

      // ✅ scaleY > 1: 手指縱向分開 → 放大（數值範圍變小，值由大到小）
      // ✅ scaleY < 1: 手指縱向接近 → 縮小（數值範圍變大，值由小到大）
      final spanNew = (span0 / scaleY).clamp(1.0, 10000.0);
      _yMinManual = center0 - spanNew / 2.0;
      _yMaxManual = center0 + spanNew / 2.0;
      _yManual = true;
    });
  }

  // ✅ 觸控：開始
  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;

    if (_pointers.length == 1) {
      // 單指：準備拖動
      final pos = _pointers.values.first;
      _dragStartX = pos.dx;
      _dragStartTimeMs = _tStartMs;  // 記錄開始時的時間起點
      _isDragging = false;
      _isScaling = false;

      _scaleActiveX = false;
      _scaleActiveY = false;
      _scaleLastHorizontalDistance = 0;
      _scaleLastVerticalDistance = 0;
      _lastScaleTickMs = 0;
      return;
    }

    if (_pointers.length == 2) {
      // 兩指：準備縮放
      final positions = _pointers.values.toList();
      final dx = (positions[0].dx - positions[1].dx).abs();
      final dy = (positions[0].dy - positions[1].dy).abs();

      _scaleStartHorizontalDistance = dx;
      _scaleStartVerticalDistance = dy;

      // 記錄 Y 範圍基準
      final (yMin, yMax) = _computeCurrentYRangeForZoom();
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

        _touchedY = null;
        _touchedX = null;
        _tooltipText = null;
        _touchedLineId = null;
      });
    }
  }

  // ✅ 觸控：移動 - 分離 X/Y 縮放控制
  void _onPointerMove(PointerMoveEvent event) {
    _pointers[event.pointer] = event.localPosition;

    // 1) 一指 → 水平拖動
    if (_pointers.length == 1) {
      final pos = _pointers.values.first;
      final currentX = pos.dx;
      final deltaX = currentX - _dragStartX;

      if (deltaX.abs() > 2) {  // 增加一點閾值避免微小抖動
        _isDragging = true;
        _isScaling = false;
        _handleHorizontalDrag(deltaX);
        _dragStartX = currentX;  // 更新起點，實現連續平移
      }
      return;
    }

    // 2) 少於兩指，不做縮放
    if (_pointers.length < 2) return;

    // 3) 兩指 → 分離 X/Y 縮放
    final positions = _pointers.values.toList();
    final dx = (positions[0].dx - positions[1].dx).abs();
    final dy = (positions[0].dy - positions[1].dy).abs();
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // === X 軸縮放（橫向距離） ===
    if (!_scaleActiveX) {
      final denom = (_scaleStartHorizontalDistance == 0 ? dx : _scaleStartHorizontalDistance);
      final ratioFromStart = dx / (denom == 0 ? 1.0 : denom);
      if ((ratioFromStart - 1.0).abs() >= _activateThreshold) {
        _scaleActiveX = true;
        _scaleLastHorizontalDistance = dx;
      }
    }

    if (_scaleActiveX) {
      final prev = (_scaleLastHorizontalDistance <= 0) ? dx : _scaleLastHorizontalDistance;
      double rawStepX = (dx <= 0 ? 0.0001 : dx) / prev;
      final stepDeltaX = rawStepX - 1.0;

      final dtSec = math.max(0.001, (nowMs - _lastScaleTickMs) / 1000.0);
      final distChangeRatioPerSec = (dx - prev).abs() / math.max(1.0, prev) / dtSec;

      final dynamicFactorX = (_zoomFactorBaseX +
          (_zoomFactorMaxX - _zoomFactorBaseX) * (distChangeRatioPerSec / 2.0))
          .clamp(_zoomFactorBaseX, _zoomFactorMaxX);

      double scaleX = 1.0 + stepDeltaX * dynamicFactorX;
      const double kStepMin = 0.85;
      const double kStepMax = 1.20;
      if (scaleX.isNaN || !scaleX.isFinite) scaleX = 1.0;
      scaleX = scaleX.clamp(kStepMin, kStepMax);

      _applyXAxisScale(scaleX);
      _scaleLastHorizontalDistance = dx;
    }

    // === Y 軸縮放（縱向距離） ===
    if (!_scaleActiveY) {
      final denom = (_scaleStartVerticalDistance == 0 ? dy : _scaleStartVerticalDistance);
      final ratioFromStart = dy / (denom == 0 ? 1.0 : denom);
      if ((ratioFromStart - 1.0).abs() >= _activateThreshold) {
        _scaleActiveY = true;
        _scaleLastVerticalDistance = dy;
      }
    }

    if (_scaleActiveY) {
      final prev = (_scaleLastVerticalDistance <= 0) ? dy : _scaleLastVerticalDistance;
      double rawStepY = (dy <= 0 ? 0.0001 : dy) / prev;
      final stepDeltaY = rawStepY - 1.0;

      final dtSec = math.max(0.001, (nowMs - _lastScaleTickMs) / 1000.0);
      final distChangeRatioPerSec = (dy - prev).abs() / math.max(1.0, prev) / dtSec;

      final dynamicFactorY = (_zoomFactorBaseY +
          (_zoomFactorMaxY - _zoomFactorBaseY) * (distChangeRatioPerSec / 2.0))
          .clamp(_zoomFactorBaseY, _zoomFactorMaxY);

      double scaleY = 1.0 + stepDeltaY * dynamicFactorY;
      const double kStepMin = 0.85;
      const double kStepMax = 1.20;
      if (scaleY.isNaN || !scaleY.isFinite) scaleY = 1.0;
      scaleY = scaleY.clamp(kStepMin, kStepMax);

      _applyYAxisScale(scaleY);
      _scaleLastVerticalDistance = dy;
    }

    _lastScaleTickMs = nowMs;
  }

  // ✅ 觸控：結束
  void _onPointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);

    if (_pointers.isEmpty) {
      if (_isDragging || _isScaling) {
        _alignWindowToMinute();
      }
      setState(() {
        _isDragging = false;
        _isScaling = false;

        _scaleStartHorizontalDistance = 0;
        _scaleStartVerticalDistance = 0;
        _scaleActiveX = false;
        _scaleActiveY = false;
        _scaleLastHorizontalDistance = 0;
        _scaleLastVerticalDistance = 0;
        _lastScaleTickMs = 0;

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
        _scaleLastHorizontalDistance = 0;
        _scaleLastVerticalDistance = 0;
        _lastScaleTickMs = 0;
      });
    }
  }

  // ✅ 觸控：取消
  void _onPointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.isEmpty) {
      setState(() {
        _isDragging = false;
        _isScaling = false;

        _scaleStartHorizontalDistance = 0;
        _scaleStartVerticalDistance = 0;
        _scaleActiveX = false;
        _scaleActiveY = false;
        _scaleLastHorizontalDistance = 0;
        _scaleLastVerticalDistance = 0;
        _lastScaleTickMs = 0;

        _yScaleSessionActive = false;
        _yScaleStartMin = null;
        _yScaleStartMax = null;
      });
    }
  }

  void _rebuildCachedSpotsIfNeeded() {
    final todayMain = _filterTodaySamples(widget.samples);
    if (todayMain.length != _cachedMainCount) {
      _cachedMainCount = todayMain.length;
      _rawCurrentSpots = _mapToSortedSpots(todayMain, (s) => _getCurrent(s));
      _rawCurrentSpots = _removeDuplicateTimestamps(_rawCurrentSpots);
      _cachedMainGlucose = _rawCurrentSpots
          .map((p) => FlSpot(p.x, _currentToGlucose(p.y)))
          .toList();

      print('test987 === 主線數據更新 ===');
      print('test987 主線原始電流數據點數: ${_rawCurrentSpots.length}');
      if (_rawCurrentSpots.isNotEmpty) {
        print('test987 主線原始電流 (前10點):\n${_rawCurrentSpots.take(10).map((p) =>
        'Time: ${DateTime.fromMillisecondsSinceEpoch(p.x.toInt())}, Current: ${p.y} A'
        ).join('\n')}');
      }
    }

    if (widget.additionalLines != null) {
      for (final config in widget.additionalLines!) {
        final today = _filterTodaySamples(config.samples);
        final key = config.id;
        final prev = _cachedAddCount[key] ?? -1;
        if (today.length != prev) {
          _cachedAddCount[key] = today.length;

          final spots = today.isNotEmpty
              ? _mapToSortedSpots(today, (s) => _getCurrent(s))
              : <FlSpot>[];

          final dedupedSpots = _removeDuplicateTimestamps(spots);
          _rawSpotsMap[key] = dedupedSpots;

          _cachedAddGlucose[key] = dedupedSpots
              .map((p) => FlSpot(
            p.x,
            _currentToGlucose(
              p.y,
              slope: config.slope,
              intercept: config.intercept,
            ),
          ))
              .toList();

          print('test987 === ${config.label} (${config.id}) 數據更新 ===');
          print('test987 ${config.label} 原始電流數據點數: ${dedupedSpots.length}');
          if (dedupedSpots.isNotEmpty) {
            print('test987 ${config.label} 原始電流 (前10點):\n${dedupedSpots.take(10).map((p) =>
            'Time: ${DateTime.fromMillisecondsSinceEpoch(p.x.toInt())}, Current: ${p.y} A'
            ).join('\n')}');
          }
          print('test987 Slope: ${config.slope}, Intercept: ${config.intercept}');
        }
      }
    }
  }

  List<FlSpot> _removeDuplicateTimestamps(List<FlSpot> spots) {
    if (spots.isEmpty) return spots;

    final Map<double, FlSpot> uniqueSpots = {};
    for (final spot in spots) {
      uniqueSpots[spot.x] = spot;
    }

    final result = uniqueSpots.values.toList()
      ..sort((a, b) => a.x.compareTo(b.x));

    return result;
  }

  (double, double) _computeCurrentYRangeForZoom() {
    if (_yManual && _yMinManual != null && _yMaxManual != null) {
      return (_yMinManual!, _yMaxManual!);
    }
    final allY = <double>[];
    allY.addAll(_cachedMainGlucose.map((e) => e.y));
    for (final e in _cachedAddGlucose.values) {
      allY.addAll(e.map((p) => p.y));
    }
    if (allY.isEmpty) return (0.0, 400.0);
    final minV = allY.reduce(math.min);
    final maxV = allY.reduce(math.max);
    final span = (maxV - minV).abs();
    final pad = span * 0.15 + 1e-12;
    return (minV - pad, maxV + pad);
  }

  // ✅ 計算固定 6 格的時間間隔
  double _calculateTimeInterval() {
    return _currentWindowWidthMs / fixedGridCount;
  }

  String _formatTimeLabel(DateTime dt, double intervalMs) {
    final intervalMinutes = intervalMs / oneMinuteMs;

    if (intervalMinutes >= 120) {
      final hh = dt.hour.toString().padLeft(2, '0');
      return '$hh:00';
    } else if (intervalMinutes >= 60) {
      final hh = dt.hour.toString().padLeft(2, '0');
      return '$hh:00';
    } else {
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    }
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2,'0')}:'
          '${dt.minute.toString().padLeft(2,'0')}:'
          '${dt.second.toString().padLeft(2,'0')}';

  bool _isSameDay(DateTime date1, DateTime date2) {
    return date1.year == date2.year &&
        date1.month == date2.month &&
        date1.day == date2.day;
  }

  bool _shouldReset(DateTime latestDate) {
    if (_currentPlotDate == null) return true;
    return !_isSameDay(_currentPlotDate!, latestDate);
  }

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

  double _currentToGlucose(double currentAmperes, {double? slope, double? intercept}) {
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

  // ✅ 關鍵改進：使用完整數據集構建線段，讓 clipData 處理裁剪
  List<LineChartBarData> _buildContinuousSegments(List<FlSpot> spots, Color color) {
    if (spots.length < 2) return [];

    const gapThresholdMs = 90 * 1000.0;
    final List<LineChartBarData> segments = [];
    List<FlSpot> currentSegment = [];

    for (int i = 0; i < spots.length; i++) {
      final spot = spots[i];

      // ✅ 不再過濾窗口範圍，保留所有點
      currentSegment.add(spot);

      bool shouldBreak = false;
      if (i < spots.length - 1) {
        final nextSpot = spots[i + 1];
        final timeDiff = nextSpot.x - spot.x;
        shouldBreak = timeDiff > gapThresholdMs;
      }

      if (shouldBreak || i == spots.length - 1) {
        if (currentSegment.length >= 2) {
          segments.add(LineChartBarData(
            spots: List.from(currentSegment),
            isCurved: false,
            isStrokeCapRound: true,
            barWidth: 2,
            color: color,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ));
        }
        currentSegment = [];
      }
    }

    return segments;
  }

  // ✅ 關鍵改進：使用完整數據集構建虛線
  List<LineChartBarData> _buildGapSegments(List<FlSpot> spots, Color color) {
    if (spots.length < 2) return [];

    const gapThresholdMs = 90 * 1000.0;
    final List<LineChartBarData> gapSegments = [];

    for (int i = 1; i < spots.length; i++) {
      final prev = spots[i - 1];
      final curr = spots[i];
      final timeDiff = curr.x - prev.x;

      if (timeDiff >= gapThresholdMs) {
        // ✅ 不再檢查窗口範圍，保留所有間隙線段
        gapSegments.add(
          LineChartBarData(
            spots: [prev, curr],
            isCurved: false,
            barWidth: 1.5,
            color: color.withOpacity(0.5),
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
            dashArray: [5, 5],
          ),
        );
      }
    }

    return gapSegments;
  }

  @override
  Widget build(BuildContext context) {
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

    final glucoseRange = ref.watch(glucoseRangeProvider);

    final todayKey = dayKeyOf(DateTime.now());
    final isToday = widget.dayKey == todayKey;

    DateTime? latestDateOverall;
    if (widget.samples.isNotEmpty) {
      latestDateOverall = widget.samples.last.ts;
    }
    if (widget.additionalLines != null) {
      for (final config in widget.additionalLines!) {
        if (config.samples.isNotEmpty) {
          final date = config.samples.last.ts;
          if (latestDateOverall == null || date.isAfter(latestDateOverall)) {
            latestDateOverall = date;
          }
        }
      }
    }

    if (latestDateOverall != null && _shouldReset(latestDateOverall)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _isManualMode = false;
            _currentWindowWidthMs = defaultWindowMs;
            _firstDataTime = null;
            _touchedY = null;
            _touchedX = null;
            _tooltipText = null;
            _touchedLineId = null;
            _yManual = false;
            _yMinManual = _yMaxManual = null;
            _initializeWindow();
          });
        }
      });
    }

    final todaySamples = _filterTodaySamples(widget.samples);
    final hasData = todaySamples.isNotEmpty;
    final bleConnected = ref.watch(bleConnectionStateProvider);

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
    } else {
      _lastSampleTime = null;
      _stopElapsedTicker(reset: true);
    }

    if (hasData && _firstDataTime == null) {
      _firstDataTime = todaySamples.first.ts;
      _initializeWindow();
    }

    _rebuildCachedSpotsIfNeeded();

    if (hasData) {
      final latestX = todaySamples.last.ts.millisecondsSinceEpoch.toDouble();
      _advanceWindowIfNeeded(latestX);
    }

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

    // ✅ 使用完整的緩存數據，不再過濾窗口
    final glucoseFromCurrentWin = _cachedMainGlucose;

    final List<List<FlSpot>> additionalGlucoseSpots = [];
    if (widget.additionalLines != null) {
      for (final config in widget.additionalLines!) {
        final cached = _cachedAddGlucose[config.id] ?? const <FlSpot>[];
        additionalGlucoseSpots.add(cached);  // ✅ 使用完整數據
      }
    }

    final allYValues = <double>[];
    if (glucoseFromCurrentWin.isNotEmpty) {
      allYValues.addAll(glucoseFromCurrentWin.map((e) => e.y));
    }
    for (final spots in additionalGlucoseSpots) {
      if (spots.isNotEmpty) {
        allYValues.addAll(spots.map((e) => e.y));
      }
    }

    _Range gluRange;
    final hasUserRange = glucoseRange.min != null && glucoseRange.max != null;

    if (_yManual && _yMinManual != null && _yMaxManual != null) {
      gluRange = _Range(_yMinManual!, _yMaxManual!);
    } else if (hasUserRange) {
      gluRange = _calcRange(
        allYValues,
        fixedMin: glucoseRange.min,
        fixedMax: glucoseRange.max,
        targetTicks: 12,
      );
    } else {
      gluRange = _calcRange(allYValues, targetTicks: 12);
    }

    if (allYValues.isEmpty && !_yManual) {
      gluRange = const _Range(0.0, 400.0);
    }

    final minX = _tStartMs;
    final maxX = _tEndMs;

    final leftInterval = _niceInterval(gluRange.min, gluRange.max, 12);
    final rightInterval = _niceInterval(gluRange.min, gluRange.max, 6);

    final safeLeftInterval = leftInterval > 0 && leftInterval.isFinite ? leftInterval : 50.0;
    final safeRightInterval = rightInterval > 0 && rightInterval.isFinite ? rightInterval : 100.0;

    final timeInterval = _calculateTimeInterval();

    final List<LineChartBarData> allLineBars = [];

    final invisibleBaseline = LineChartBarData(
      spots: [
        FlSpot(minX, gluRange.min),
        FlSpot(maxX, gluRange.min),
      ],
      isCurved: false,
      barWidth: 0,
      color: Colors.transparent,
      dotData: const FlDotData(show: false),
      belowBarData: BarAreaData(show: false),
    );
    allLineBars.add(invisibleBaseline);

    // ✅ 使用完整數據集構建線段
    if (glucoseFromCurrentWin.length >= 2) {
      allLineBars.addAll(_buildContinuousSegments(glucoseFromCurrentWin, Colors.blue));
      allLineBars.addAll(_buildGapSegments(glucoseFromCurrentWin, Colors.blue));
    }

    // ✨ 主線數據點 - 使用光暈效果
    if (glucoseFromCurrentWin.isNotEmpty) {
      allLineBars.add(LineChartBarData(
        spots: glucoseFromCurrentWin,
        isCurved: false,
        barWidth: 0,
        color: Colors.transparent,
        dotData: FlDotData(
          show: true,
          getDotPainter: (spot, percent, barData, index) {
            final isLatest = index == glucoseFromCurrentWin.length - 1;
            if (isLatest) {
              // 最新點使用光暈閃爍效果
              return GlowingDotPainter(
                radius: 5,
                color: Colors.red,
                glowOpacity: _blinkAnimation.value,
                strokeWidth: 1.5,
                strokeColor: Colors.white,
              );
            } else {
              // 其他點保持藍色
              return FlDotCirclePainter(
                radius: 3,
                color: Colors.blue,
                strokeWidth: 1.5,
                strokeColor: Colors.white,
              );
            }
          },
        ),
      ));
    }

    // ✨ 附加線數據點 - 使用光暈效果
    if (widget.additionalLines != null) {
      for (int i = 0; i < widget.additionalLines!.length; i++) {
        final config = widget.additionalLines![i];
        final glucoseSpots = additionalGlucoseSpots[i];

        if (glucoseSpots.length >= 2) {
          allLineBars.addAll(_buildContinuousSegments(glucoseSpots, config.color));
          allLineBars.addAll(_buildGapSegments(glucoseSpots, config.color));
        }

        if (glucoseSpots.isNotEmpty && config.showDots) {
          allLineBars.add(LineChartBarData(
            spots: glucoseSpots,
            isCurved: false,
            barWidth: 0,
            color: Colors.transparent,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, barData, index) {
                final isLatest = index == glucoseSpots.length - 1;
                if (isLatest) {
                  // 最新點使用光暈閃爍效果
                  return GlowingDotPainter(
                    radius: 5,
                    color: Colors.deepPurpleAccent,
                    glowOpacity: _blinkAnimation.value,
                    strokeWidth: 1.5,
                    strokeColor: Colors.white,
                  );
                } else {
                  // 其他點使用線的顏色
                  return FlDotCirclePainter(
                    radius: 3,
                    color: config.color,
                    strokeWidth: 1.5,
                    strokeColor: Colors.white,
                  );
                }
              },
            ),
          ));
        }
      }
    }

    return Column(
      children: [
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
        Expanded(
          child: AnimatedBuilder(
            animation: _blinkAnimation,
            builder: (context, child) {
              return Stack(
                children: [
                  GestureDetector(
                    onDoubleTap: () {
                      setState(() {
                        _isManualMode = false;
                        _currentWindowWidthMs = defaultWindowMs;
                        _initializeWindow();

                        _yManual = false;
                        _yMinManual = _yMaxManual = null;
                      });
                    },
                    child: Listener(
                      onPointerDown: _onPointerDown,
                      onPointerMove: _onPointerMove,
                      onPointerUp: _onPointerUp,
                      onPointerCancel: _onPointerCancel,
                      child: LineChart(
                        LineChartData(
                          minX: minX,
                          maxX: maxX,
                          minY: gluRange.min,
                          maxY: gluRange.max,
                          // ✅ 關鍵：啟用裁剪，讓窗口外的內容被隱藏
                          clipData: const FlClipData(left: true, top: true, right: true, bottom: true),
                          lineBarsData: allLineBars,
                          gridData: FlGridData(
                            show: true,
                            drawVerticalLine: true,
                            drawHorizontalLine: true,
                            horizontalInterval: safeLeftInterval,
                            verticalInterval: timeInterval,
                            getDrawingHorizontalLine: (value) => FlLine(
                              color: Colors.grey.withOpacity(0.8),
                              strokeWidth: 1.0,
                            ),
                            getDrawingVerticalLine: (value) => FlLine(
                              color: Colors.grey.withOpacity(0.8),
                              strokeWidth: 1.0,
                            ),
                          ),
                          titlesData: FlTitlesData(
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 30,
                                interval: safeLeftInterval,
                                getTitlesWidget: (v, _) {
                                  final text = v.toStringAsFixed(0);
                                  return Text(text, style: const TextStyle(fontSize: 9));
                                },
                              ),
                              axisNameWidget: const Padding(
                                padding: EdgeInsets.only(right: 8, bottom: 4),
                                child: Text('Glu conc (mg/dL)'),
                              ),
                              axisNameSize: 20,
                            ),
                            rightTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 34,
                                interval: safeRightInterval,
                                getTitlesWidget: (glucoseValue, _) {
                                  final currentNa = _glucoseToCurrent(glucoseValue);
                                  final text = (currentNa.abs() < 0.01)
                                      ? '0.00'
                                      : currentNa.toStringAsFixed(2);
                                  return Text(text, style: const TextStyle(fontSize: 8));
                                },
                              ),
                              axisNameWidget: const Padding(
                                padding: EdgeInsets.only(right: 8, bottom: 4),
                                child: Text('Current (1E - 9 A)'),
                              ),
                              axisNameSize: 20,
                            ),
                            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 28,
                                interval: timeInterval,
                                getTitlesWidget: (value, meta) {
                                  final dt = DateTime.fromMillisecondsSinceEpoch(value.toInt());
                                  final label = _formatTimeLabel(dt, timeInterval);
                                  return Text(label, style: const TextStyle(fontSize: 10));
                                },
                              ),
                              axisNameWidget: const Padding(
                                padding: EdgeInsets.only(left: 4),
                                child: Text('Time (HH:mm)'),
                              ),
                            ),
                          ),
                          borderData: FlBorderData(
                            show: true,
                            border: Border.all(color: Colors.grey, width: 1),
                          ),
                          lineTouchData: LineTouchData(
                            touchSpotThreshold: 4,
                            enabled: !_isDragging && !_isScaling,
                            handleBuiltInTouches: true,
                            touchTooltipData: LineTouchTooltipData(
                              getTooltipColor: (_) => Colors.transparent,
                              tooltipPadding: EdgeInsets.zero,
                              tooltipMargin: 0,
                              getTooltipItems: (touchedSpots) =>
                                  touchedSpots.map((_) => null).toList(),
                            ),
                            getTouchedSpotIndicator: (barData, spotIndexes) {
                              return spotIndexes.map((index) {
                                Color indicatorColor = Colors.blue;
                                if (barData.color != null && barData.color != Colors.transparent) {
                                  indicatorColor = barData.color!;
                                }

                                return TouchedSpotIndicatorData(
                                  FlLine(
                                    color: indicatorColor.withOpacity(0.8),
                                    strokeWidth: 2,
                                    dashArray: [5, 5],
                                  ),
                                  FlDotData(
                                    show: true,
                                    getDotPainter: (spot, percent, barData, index) {
                                      return FlDotCirclePainter(
                                        radius: 6,
                                        color: indicatorColor,
                                        strokeWidth: 3,
                                        strokeColor: Colors.white,
                                      );
                                    },
                                  ),
                                );
                              }).toList();
                            },
                            touchCallback: (FlTouchEvent event, LineTouchResponse? response) {
                              if (_isDragging || _isScaling) return;

                              final isEndTap = event is FlTapUpEvent || event is FlLongPressEnd;
                              final isMoveUpdate = event is FlPanUpdateEvent;

                              if (isMoveUpdate) return;

                              final spots = response?.lineBarSpots ?? const [];

                              if (isEndTap) {
                                if (spots.isEmpty) {
                                  setState(() {
                                    _touchedX = null;
                                    _touchedY = null;
                                    _tooltipText = null;
                                    _touchedLineId = null;
                                  });
                                } else {
                                  LineBarSpot? selectedSpot;
                                  for (final spot in spots) {
                                    if (spot.bar.color != null &&
                                        spot.bar.color != Colors.transparent) {
                                      selectedSpot = spot;
                                      break;
                                    }
                                  }

                                  if (selectedSpot == null) return;

                                  final hit = selectedSpot;
                                  final hitX = hit.x;

                                  bool isMainLine = hit.bar.color == Colors.blue;
                                  String lineLabel = '主線';
                                  double lineSlope = widget.slope;
                                  double lineIntercept = widget.intercept;
                                  List<FlSpot> rawSpots = _rawCurrentSpots;

                                  if (!isMainLine && widget.additionalLines != null) {
                                    for (final config in widget.additionalLines!) {
                                      if (config.color == hit.bar.color) {
                                        _touchedLineId = config.id;
                                        lineLabel = config.label;
                                        lineSlope = config.slope;
                                        lineIntercept = config.intercept;
                                        rawSpots = _rawSpotsMap[config.id] ?? [];
                                        break;
                                      }
                                    }
                                  } else {
                                    _touchedLineId = 'main';
                                  }

                                  FlSpot? closestRawSpot;
                                  double minDistance = double.infinity;
                                  for (final raw in rawSpots) {
                                    // ✅ 只在可視窗口內查找最近點
                                    if (raw.x >= _tStartMs && raw.x <= _tEndMs) {
                                      final d = (raw.x - hitX).abs();
                                      if (d < minDistance) {
                                        minDistance = d;
                                        closestRawSpot = raw;
                                      }
                                    }
                                  }

                                  final target = closestRawSpot ??
                                      FlSpot(
                                          hit.x,
                                          _glucoseToCurrent(
                                            hit.y,
                                            slope: lineSlope,
                                            intercept: lineIntercept,
                                          ) * 1e-9
                                      );

                                  final displaySpot = FlSpot(
                                    target.x,
                                    _currentToGlucose(
                                      target.y,
                                      slope: lineSlope,
                                      intercept: lineIntercept,
                                    ),
                                  );

                                  final dt = DateTime.fromMillisecondsSinceEpoch(displaySpot.x.toInt());
                                  final timeStr = _formatTime(dt);
                                  final currentNa = _glucoseToCurrent(
                                    displaySpot.y,
                                    slope: lineSlope,
                                    intercept: lineIntercept,
                                  );

                                  setState(() {
                                    _touchedX = displaySpot.x;
                                    _touchedY = displaySpot.y;
                                    _tooltipText = isMainLine
                                        ? '時間: $timeStr\n'
                                        '血糖: ${displaySpot.y.toStringAsFixed(2)} mg/dL\n'
                                        '電流: ${currentNa.toStringAsFixed(2)} nA\n'
                                        '(實際採樣值)'
                                        : '【$lineLabel】\n'
                                        '時間: $timeStr\n'
                                        '血糖: ${displaySpot.y.toStringAsFixed(2)} mg/dL\n'
                                        '電流: ${currentNa.toStringAsFixed(2)} nA';
                                  });
                                }
                              }
                            },
                          ),
                          extraLinesData: ExtraLinesData(
                            horizontalLines: _touchedY != null
                                ? [
                              HorizontalLine(
                                y: _touchedY!,
                                color: _getTouchedLineColor().withOpacity(0.8),
                                strokeWidth: 2,
                                dashArray: [5, 5],
                                label: HorizontalLineLabel(show: false),
                              ),
                            ]
                                : [],
                            verticalLines: _touchedX != null
                                ? [
                              VerticalLine(
                                x: _touchedX!,
                                color: _getTouchedLineColor().withOpacity(0.8),
                                strokeWidth: 2,
                                dashArray: [5, 5],
                                label: VerticalLineLabel(show: false),
                              ),
                            ]
                                : [],
                          ),
                        ),
                      ),
                    ),
                  ),

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
                  if (_tooltipText != null && _touchedX != null && _touchedY != null)
                    Positioned(
                      left: 16,
                      top: 60,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: _getTouchedLineColor().withOpacity(0.9),
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
                            _tooltipText!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Color _getTouchedLineColor() {
    if (_touchedLineId == null || _touchedLineId == 'main') return Colors.blue;

    if (widget.additionalLines != null) {
      for (final config in widget.additionalLines!) {
        if (config.id == _touchedLineId) {
          return config.color;
        }
      }
    }

    return Colors.blue;
  }

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

  List<FlSpot> _mapToSortedSpots(List<Sample> data, double Function(Sample) pickY) {
    final list = data
        .map((s) => FlSpot(s.ts.millisecondsSinceEpoch.toDouble(), pickY(s)))
        .toList()
      ..sort((a, b) => a.x.compareTo(b.x));
    return list;
  }

  double _getCurrent(Sample s) {
    final currents = s.currents;
    if (currents == null || currents.isEmpty) return 0.0;
    return currents.first.toDouble();
  }

  _Range _calcRange(
      Iterable<double> values, {
        double? fixedMin,
        double? fixedMax,
        int targetTicks = 12,
      }) {
    if (fixedMin != null || fixedMax != null) {
      final dataMin = values.isEmpty ? 0.0 : values.reduce(math.min);
      final dataMax = values.isEmpty ? 400.0 : values.reduce(math.max);

      double minV = fixedMin ?? dataMin;
      double maxV = fixedMax ?? dataMax;

      if (!minV.isFinite || !maxV.isFinite) {
        minV = 0.0;
        maxV = 400.0;
      }
      if (minV >= maxV) {
        const eps = 1e-6;
        if (minV == maxV) {
          maxV = minV + 1.0;
        } else {
          final t = minV;
          minV = maxV;
          maxV = t;
          if ((maxV - minV) < eps) maxV = minV + 1.0;
        }
      }

      return _Range(minV, maxV);
    }

    double minV, maxV;

    if (values.isEmpty) {
      minV = 0.0;
      maxV = 400.0;
    } else {
      final rawMin = values.reduce(math.min);
      final rawMax = values.reduce(math.max);

      final span = (rawMax - rawMin).abs();
      final pad = span * 0.15 + 1e-12;
      minV = rawMin - pad;
      maxV = rawMax + pad;

      if (span < 1e-10) {
        final center = (minV + maxV) / 2.0;
        final absCenter = center.abs();
        if (absCenter < 1e-10) {
          minV = 0.0;
          maxV = 400.0;
        } else {
          minV = center - absCenter * 0.5;
          maxV = center + absCenter * 0.5;
        }
      }

      final interval = _niceInterval(minV, maxV, targetTicks);
      if (interval > 0 && interval.isFinite) {
        minV = (minV / interval).floor() * interval;
        maxV = (maxV / interval).ceil() * interval;
      }
    }

    if (!minV.isFinite || !maxV.isFinite || minV >= maxV) {
      minV = 0.0;
      maxV = 400.0;
    }

    return _Range(minV, maxV);
  }

  double _niceInterval(double min, double max, int targetTicks) {
    final span = (max - min).abs();
    if (span <= 0) return 1;

    final raw = span / math.max(1, targetTicks);
    if (raw < 1e-10) return 1e-10;

    final exponent = (math.log(raw) / math.ln10).floor();
    final mag = math.pow(10, exponent).toDouble();
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

    final interval = nice * mag;
    final maxInterval = span / 2;
    final minInterval = span / 50;

    if (interval > maxInterval) {
      return maxInterval;
    } else if (interval < minInterval) {
      return minInterval;
    }

    return interval;
  }
}

class _Range {
  final double min;
  final double max;
  const _Range(this.min, this.max);
  double get span => max - min;
}