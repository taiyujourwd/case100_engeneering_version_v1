import 'dart:async';
import 'dart:math' as math;
import '../../../../common/utils/date_key.dart';
import '../providers/ble_providers.dart';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/isar_schemas.dart';
import '../providers/current_glucose_providers.dart';

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
/// - X軸支援雙指縮放：6分鐘 ~ 36小時
/// - 初始顯示：6分鐘視窗
/// - 縮放至最小：6分鐘窗口
/// - 縮放至最大：6格，每格6小時（36小時）
/// - 使用接收到的時間和電流直接繪製曲線
/// - 同一天延續繪製，不同天清空重新開始
/// - 支持手勢縮放和滑動查看歷史
/// - 放大後可左右滑動查看被隱藏的部分
/// - 點擊曲線顯示該點詳細資訊，並繪製虛線到X/Y軸
/// - **支援多條曲線繪製 + 單指平移 + 雙指 X/Y 同步縮放 + 雙擊復位**
/// - **修正：雙指分離=由時到分(放大)，接近=由分到時(縮小)，X/Y 軸等比例同步**
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

class _GlucoseChartState extends ConsumerState<GlucoseChart> {
  // ✅ 縮放範圍：6分鐘 到 36小時
  static const double minWindowMs = 6 * 60 * 1000.0;  // 最小 6 分鐘
  static const double maxWindowMs = 36 * 60 * 60 * 1000.0;  // 最大 36 小時（6格×6小時）
  static const double defaultWindowMs = 6 * 60 * 1000.0;  // 預設 6 分鐘
  static const double oneMinuteMs = 60 * 1000.0;

  late double _tStartMs;
  late double _tEndMs;
  late double _currentWindowWidthMs;
  DateTime? _firstDataTime;

  bool _isManualMode = false;

  // === 針對縮放手勢的 Y 範圍會話狀態 ===
  bool _yScaleSessionActive = false;
  double? _yScaleStartMin;   // 雙指縮放「開始」的自動 Y 最小
  double? _yScaleStartMax;   // 雙指縮放「開始」的自動 Y 最大
  double  _scaleStartDistance = 0;          // 你原本就有；保留
  double  _windowWidthBeforeScale = defaultWindowMs; // 你原本就有；保留

  // ✅ 手動追蹤觸摸點
  final Map<int, Offset> _pointers = {};  // pointer ID -> 位置
  bool _isDragging = false;
  bool _isScaling = false;

  // 拖動相關
  double _dragStartX = 0;
  double? _lastDragX;

  // 觸摸點狀態
  String? _touchedLineId;  // 記錄被觸摸的線ID
  double? _touchedY;
  double? _touchedX;
  String? _tooltipText;

  // 保存原始採樣數據（支援多條線）
  List<FlSpot> _rawCurrentSpots = [];
  final Map<String, List<FlSpot>> _rawSpotsMap = {};

  // === 新增：快取（整天） ===
  List<FlSpot> _cachedMainGlucose = [];
  final Map<String, List<FlSpot>> _cachedAddGlucose = {};
  int _cachedMainCount = 0;
  final Map<String, int> _cachedAddCount = {};

  // === 新增：Y 軸手動模式（同步縮放） ===
  bool _yManual = false;
  double? _yMinManual;
  double? _yMaxManual;

  // 縮放速度（越小越靈敏；1.0=線性；>1.0 越鈍）
  double _zoomFactor = 0.02;
  bool _scaleActive = false;   // 超過門檻後才開始縮放
  double _scaleLastDistance = 0;
  int _lastScaleTickMs = 0;

// 可調參數
  double _zoomFactorBase = 0.001;  // 基礎靈敏度（慢速）
  double _zoomFactorMax  = 0.05;   // 最高靈敏度（快速拖動）
  double _activateThreshold = 0.5; // 啟動門檻：相對起始距離 ±0.5% 以內不縮放

  // 記錄當前繪圖的日期
  DateTime? _currentPlotDate;

  // 「自上一筆」累積秒數
  Timer? _elapsedTicker;
  int _elapsedSec = 0;           // 從上一筆開始累積的秒數
  DateTime? _lastSampleTime;     // 最近一筆資料時間戳（判斷新點）

  _Range _autoRangeForCurrentWindow() {
    final List<double> y = [];
    y.addAll(_inWindow(_cachedMainGlucose).map((e) => e.y));
    if (widget.additionalLines != null) {
      for (final entry in widget.additionalLines!) {
        final cached = _cachedAddGlucose[entry.id] ?? const <FlSpot>[];
        y.addAll(_inWindow(cached).map((e) => e.y));
      }
    }
    if (y.isEmpty) return const _Range(0, 400);
    return _calcRange(y, targetTicks: 12);
  }

  void _startElapsedTicker() {
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsedSec += 1; // 每秒+1
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
  }

  @override
  void dispose() {
    _elapsedTicker?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(GlucoseChart oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.slope != widget.slope ||
        oldWidget.intercept != widget.intercept) {
      if (mounted) {
        setState(() {
          // 主線 slope/intercept 改變時，強制重建快取
          _cachedMainCount = -1;
        });
      }
    }

    // 檢查額外線的參數變化
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

    // 從主線和額外線中找到最早的數據時間
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
      // 從數據當天的 00:00 開始
      startTime = DateTime(
        earliestTime.year,
        earliestTime.month,
        earliestTime.day,
        0,  // 從 00:00 開始
        0,
        0,
        0,
      );
    } else {
      // 沒有數據時，從今天 00:00 開始
      final now = DateTime.now();
      startTime = DateTime(now.year, now.month, now.day, 0, 0, 0, 0);
    }

    _tStartMs = startTime.millisecondsSinceEpoch.toDouble();
    _tEndMs = _tStartMs + _currentWindowWidthMs;
  }

  void _advanceWindowIfNeeded(double latestX) {
    if (_isManualMode) return;

    // 如果是接近最大全景視圖，不自動滾動
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

      // 檢查主線和額外線的最新數據
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

      // Y 回自動
      _yManual = false;
      _yMinManual = _yMaxManual = null;
    });
  }

  void _handleHorizontalDrag(double delta) {
    setState(() {
      _isManualMode = true;
      final windowWidth = _tEndMs - _tStartMs;
      final dragSensitivity = windowWidth / 300;

      final newStartMs = _tStartMs - delta * dragSensitivity;
      final newEndMs = _tEndMs - delta * dragSensitivity;

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

  // ✅ 雙指縮放（X + Y）- 修正版本：分離放大，接近縮小
  void _applyIncrementalScale(double scale) {
    setState(() {
      _isManualMode = true;

      // === X 軸（時間窗）- 修正：scale > 1 放大（窗口變小），scale < 1 縮小（窗口變大）===
      final newWinX = (_currentWindowWidthMs / scale).clamp(minWindowMs, maxWindowMs);
      final cx = (_tStartMs + _tEndMs) / 2;
      _tStartMs = cx - newWinX / 2;
      _tEndMs   = cx + newWinX / 2;
      _currentWindowWidthMs = newWinX;

      // === Y 軸（血糖窗）等比例 ===
      // 若還沒建立會話基準，立即以「當前顯示範圍」建立一次，確保 X、Y 同步
      if (!_yScaleSessionActive || _yScaleStartMin == null || _yScaleStartMax == null) {
        final (yMin0, yMax0) = _computeCurrentYRangeForZoom();
        _yScaleSessionActive = true;
        _yScaleStartMin = yMin0;
        _yScaleStartMax = yMax0;
      }

      final span0   = (_yScaleStartMax! - _yScaleStartMin!).abs().clamp(1e-6, 1e9);
      final center0 = (_yScaleStartMax! + _yScaleStartMin!) / 2.0;
      // ✅ 修正：scale > 1 放大（span 變小），scale < 1 縮小（span 變大）
      final spanNew = (span0 / scale).clamp(1.0, 10000.0);
      _yMinManual = center0 - spanNew / 2.0;
      _yMaxManual = center0 + spanNew / 2.0;
      _yManual    = true; // ← 一旦縮放，鎖定為手動比例，避免自動回彈

      // === X 起點對齊整分鐘（避免抖動） ===
      final startTime = DateTime.fromMillisecondsSinceEpoch(_tStartMs.toInt());
      final alignedStart = DateTime(
        startTime.year, startTime.month, startTime.day,
        startTime.hour, startTime.minute, 0, 0,
      );
      _tStartMs = alignedStart.millisecondsSinceEpoch.toDouble();
      _tEndMs   = _tStartMs + newWinX;
    });
  }

  // ✅ 觸控：開始
  void _onPointerDown(PointerDownEvent event) {
    // 先記錄此指頭的位置，之後再讀 positions
    _pointers[event.pointer] = event.localPosition;

    if (_pointers.length == 1) {
      // 單指：準備拖動
      final pos = _pointers.values.first;
      _dragStartX = pos.dx;
      _lastDragX = pos.dx;
      _isDragging = false;
      _isScaling = false;

      // 清縮放狀態
      _scaleActive = false;
      _scaleLastDistance = 0;
      _lastScaleTickMs = 0;
      return;
    }

    if (_pointers.length == 2) {
      // 兩指：準備縮放
      final positions = _pointers.values.toList();
      final dx = positions[0].dx - positions[1].dx;
      final dy = positions[0].dy - positions[1].dy;
      _scaleStartDistance = math.sqrt(dx * dx + dy * dy);
      _windowWidthBeforeScale = _currentWindowWidthMs;

      // 以「當前顯示」的 Y 範圍當作縮放基準（無論自動或手動都正確）
      final (yMin, yMax) = _computeCurrentYRangeForZoom();
      _yScaleSessionActive = true;
      _yScaleStartMin = yMin;
      _yScaleStartMax = yMax;

      // 延後啟動門檻
      _scaleActive = false;
      _scaleLastDistance = _scaleStartDistance;
      _lastScaleTickMs = DateTime.now().millisecondsSinceEpoch;

      setState(() {
        _isScaling = true;
        _isDragging = false;

        // 清掉點選提示
        _touchedY = null;
        _touchedX = null;
        _tooltipText = null;
        _touchedLineId = null;
      });
    }
  }

  // ✅ 觸控：移動 - 修正版本
  void _onPointerMove(PointerMoveEvent event) {
    // 先更新目前指頭位置（這行是關鍵！）
    _pointers[event.pointer] = event.localPosition;

    // 1) 一指 → 水平拖動
    if (_pointers.length == 1) {
      final pos = _pointers.values.first;
      final dx = pos.dx;
      if (_lastDragX != null) {
        final delta = dx - _lastDragX!;
        if (delta.abs() > 0) {
          _isDragging = true;
          _isScaling = false;
          _handleHorizontalDrag(delta);
        }
      }
      _lastDragX = dx;
      return;
    }

    // 2) 少於兩指，不做縮放
    if (_pointers.length < 2) return;

    // 3) 兩指 → 縮放（增量 + 速度因子）
    final positions = _pointers.values.toList();
    final dx = positions[0].dx - positions[1].dx;
    final dy = positions[0].dy - positions[1].dy;
    final currentDistance = math.sqrt(dx * dx + dy * dy);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    // 尚未啟動：檢查門檻
    if (!_scaleActive) {
      final denom = (_scaleStartDistance == 0 ? currentDistance : _scaleStartDistance);
      final ratioFromStart = currentDistance / (denom == 0 ? 1.0 : denom);
      if ((ratioFromStart - 1.0).abs() < _activateThreshold) {
        return; // 還沒過門檻
      }
      // 一旦過門檻 → 重設基準，避免第一下跳很大
      _scaleActive = true;
      _scaleLastDistance = currentDistance;
      _lastScaleTickMs = nowMs;
      return;
    }

    // 已啟動：用上一幀做『增量』
    final prev = (_scaleLastDistance <= 0) ? currentDistance : _scaleLastDistance;
    // ✅ 修正：current / prev
    //    手指分離 (current > prev) → rawStep > 1 → scale > 1 → 放大
    //    手指接近 (current < prev) → rawStep < 1 → scale < 1 → 縮小
    double rawStep = (currentDistance <= 0 ? 0.0001 : currentDistance) / prev;
    final stepDelta = rawStep - 1.0;

    final dtSec = math.max(0.001, (nowMs - _lastScaleTickMs) / 1000.0);
    final distChangeRatioPerSec = (currentDistance - prev).abs() / math.max(1.0, prev) / dtSec;

    final dynamicFactor = (_zoomFactorBase +
        (_zoomFactorMax - _zoomFactorBase) * (distChangeRatioPerSec / 2.0))
        .clamp(_zoomFactorBase, _zoomFactorMax);

    double scale = 1.0 + stepDelta * dynamicFactor;

    const double kStepMin = 0.85; // 一步最多縮 15%
    const double kStepMax = 1.20; // 一步最多放 20%
    if (scale.isNaN || !scale.isFinite) scale = 1.0;
    scale = scale.clamp(kStepMin, kStepMax);

    _applyIncrementalScale(scale);

    _scaleLastDistance = currentDistance;
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
        _lastDragX = null;

        _scaleStartDistance = 0;
        _scaleActive = false;
        _scaleLastDistance = 0;
        _lastScaleTickMs = 0;

        _yScaleSessionActive = false;
        _yScaleStartMin = null;
        _yScaleStartMax = null;
      });
    } else if (_pointers.length == 1 && _isScaling) {
      setState(() {
        _isScaling = false;
        _isDragging = false;

        // 縮放結束但仍保留手動 Y 比例
        _scaleActive = false;
        _scaleLastDistance = 0;
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
        _lastDragX = null;

        _scaleStartDistance = 0;
        _scaleActive = false;
        _scaleLastDistance = 0;
        _lastScaleTickMs = 0;

        _yScaleSessionActive = false;
        _yScaleStartMin = null;
        _yScaleStartMax = null;
      });
    }
  }

  // === 新增：只在筆數變化時重建快取 ===
  void _rebuildCachedSpotsIfNeeded() {
    // 主線
    final todayMain = _filterTodaySamples(widget.samples);
    if (todayMain.length != _cachedMainCount) {
      _cachedMainCount = todayMain.length;
      _rawCurrentSpots = _mapToSortedSpots(todayMain, (s) => _getCurrent(s));

      // ✅ 去重：移除相同時間戳的重複點（保留最後一個）
      _rawCurrentSpots = _removeDuplicateTimestamps(_rawCurrentSpots);

      _cachedMainGlucose = _rawCurrentSpots
          .map((p) => FlSpot(p.x, _currentToGlucose(p.y))) // 主線用 widget.slope/intercept
          .toList();
    }

    // 額外線
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

          // ✅ 去重：移除相同時間戳的重複點（保留最後一個）
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
        }
      }
    }
  }

  // ✅ 新增：移除相同時間戳的重複數據點
  List<FlSpot> _removeDuplicateTimestamps(List<FlSpot> spots) {
    if (spots.isEmpty) return spots;

    final Map<double, FlSpot> uniqueSpots = {};
    for (final spot in spots) {
      // 如果時間戳已存在，用新的點覆蓋（保留最後一個）
      uniqueSpots[spot.x] = spot;
    }

    // 轉回列表並排序
    final result = uniqueSpots.values.toList()
      ..sort((a, b) => a.x.compareTo(b.x));

    return result;
  }

  // 視窗裁切（不改變快取內容）
  List<FlSpot> _inWindow(List<FlSpot> all) {
    if (all.isEmpty) return const [];
    final double s = _tStartMs, e = _tEndMs;
    final out = <FlSpot>[];
    FlSpot? left, right;
    for (final p in all) {
      if (p.x < s) left = p;
      else if (p.x > e) { right ??= p; }
      if (p.x >= s && p.x <= e) out.add(p);
    }
    if (left != null) out.insert(0, left);
    if (right != null) out.add(right);
    return out;
  }

  // 供雙指縮放初始化 Y 範圍
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

  List<FlSpot> _applyWindowFixed(List<FlSpot> spots) {
    if (spots.isEmpty) return spots;

    final List<FlSpot> inWin = [];
    FlSpot? leftNeighbor;
    FlSpot? rightNeighbor;

    for (final p in spots) {
      if (p.x < _tStartMs) {
        leftNeighbor = p;
      } else if (p.x >= _tEndMs) {
        rightNeighbor ??= p;
      }

      if (p.x >= _tStartMs && p.x < _tEndMs) {
        inWin.add(p);
      }
    }

    if (leftNeighbor != null) {
      inWin.insert(0, leftNeighbor);
    }
    if (rightNeighbor != null) {
      inWin.add(rightNeighbor);
    }
    return inWin;
  }

  // 決定數字顯示的小數位數，避免間隔太小被四捨五入成重覆文字
  int _decimalsForInterval(double interval) {
    final t = interval.abs();
    if (t >= 10) return 0;
    if (t >= 1) return 0;
    if (t >= 0.1) return 1;
    if (t >= 0.01) return 2;
    if (t >= 0.001) return 3;
    return 4;
  }

  // 把「左軸(血糖)的間隔」換算成「右軸(電流 nA)的間隔」，確保兩邊比例一致
  double _mapLeftIntervalToRight(double leftInterval) {
    if (widget.slope == 0) return leftInterval; // 避免除 0
    return leftInterval / widget.slope;
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
    return s * (currentAmperes * 1e9) + i; // current(A)*1e9 = nA
  }

  double _glucoseToCurrent(double glucose, {double? slope, double? intercept}) {
    final s = slope ?? widget.slope;
    if (s == 0) return 0;
    final i = intercept ?? widget.intercept;
    return (glucose - i) / s; // 回推 nA
  }

  List<LineChartBarData> _buildContinuousSegments(List<FlSpot> spots, Color color) {
    if (spots.length < 2) return [];

    const gapThresholdMs = 90 * 1000.0;
    final List<LineChartBarData> segments = [];
    List<FlSpot> currentSegment = [];

    for (int i = 0; i < spots.length; i++) {
      final spot = spots[i];

      if (spot.x >= _tStartMs && spot.x <= _tEndMs) {
        currentSegment.add(spot);
      }

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

  List<LineChartBarData> _buildGapSegments(List<FlSpot> spots, Color color) {
    if (spots.length < 2) return [];

    const gapThresholdMs = 90 * 1000.0;
    final List<LineChartBarData> gapSegments = [];

    for (int i = 1; i < spots.length; i++) {
      final prev = spots[i - 1];
      final curr = spots[i];
      final timeDiff = curr.x - prev.x;

      if (timeDiff >= gapThresholdMs) {
        final prevInWindow = prev.x >= _tStartMs && prev.x <= _tEndMs;
        final currInWindow = curr.x >= _tStartMs && curr.x <= _tEndMs;

        if (prevInWindow || currInWindow) {
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
    }

    return gapSegments;
  }

  double _calculateTimeInterval() {
    // 目標：在畫面上顯示約 6-12 個刻度
    final targetTicks = 8;
    final intervalMs = _currentWindowWidthMs / targetTicks;
    final intervalMinutes = intervalMs / oneMinuteMs;

    double niceIntervalMinutes;

    // 根據間隔大小選擇合適的刻度單位
    if (intervalMinutes <= 1) {
      niceIntervalMinutes = 1;  // 1 分鐘
    } else if (intervalMinutes <= 2) {
      niceIntervalMinutes = 2;  // 2 分鐘
    } else if (intervalMinutes <= 5) {
      niceIntervalMinutes = 5;  // 5 分鐘
    } else if (intervalMinutes <= 10) {
      niceIntervalMinutes = 10;  // 10 分鐘
    } else if (intervalMinutes <= 15) {
      niceIntervalMinutes = 15;  // 15 分鐘
    } else if (intervalMinutes <= 30) {
      niceIntervalMinutes = 30;  // 30 分鐘
    } else if (intervalMinutes <= 60) {
      niceIntervalMinutes = 60;  // 1 小時
    } else if (intervalMinutes <= 120) {
      niceIntervalMinutes = 120;  // 2 小時
    } else if (intervalMinutes <= 180) {
      niceIntervalMinutes = 180;  // 3 小時
    } else if (intervalMinutes <= 240) {
      niceIntervalMinutes = 240;  // 4 小時
    } else if (intervalMinutes <= 360) {
      niceIntervalMinutes = 360;  // 6 小時
    } else {
      niceIntervalMinutes = 720;  // 12 小時
    }

    return niceIntervalMinutes * oneMinuteMs;
  }

  String _formatTimeLabel(DateTime dt, double intervalMs) {
    final intervalMinutes = intervalMs / oneMinuteMs;

    if (intervalMinutes >= 120) {
      // 2 小時以上：只顯示小時
      final hh = dt.hour.toString().padLeft(2, '0');
      return '$hh:00';
    } else if (intervalMinutes >= 60) {
      // 1 小時：顯示小時
      final hh = dt.hour.toString().padLeft(2, '0');
      return '$hh:00';
    } else {
      // 小於 1 小時：顯示小時和分鐘
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(bleConnectionStateProvider, (prev, next) {
      if (next == true) {
        if (_lastSampleTime != null && _elapsedTicker == null) {
          _startElapsedTicker();            // 連上且已有一筆 → 開始每秒累加
        }
      } else {
        _stopElapsedTicker(reset: true);    // 斷線 → 停表 + 歸零
        _lastSampleTime = null;
      }
    });

    final glucoseRange = ref.watch(glucoseRangeProvider);

    final todayKey = dayKeyOf(DateTime.now());
    final isToday = widget.dayKey == todayKey;

    // 檢查是否需要重置（基於所有線的最新日期）
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

    // ★ 偵測新點
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

    // 建立/更新快取（僅筆數變化才重建）
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

    // 以快取 + 視窗裁切輸出
    final glucoseFromCurrentWin = _inWindow(_cachedMainGlucose);

    // 額外線
    final List<List<FlSpot>> additionalGlucoseSpots = [];
    if (widget.additionalLines != null) {
      for (final config in widget.additionalLines!) {
        final cached = _cachedAddGlucose[config.id] ?? const <FlSpot>[];
        additionalGlucoseSpots.add(_inWindow(cached));
      }
    }

    // 組合所有線的 Y 值
    final allYValues = <double>[];
    if (glucoseFromCurrentWin.isNotEmpty) {
      allYValues.addAll(glucoseFromCurrentWin.map((e) => e.y));
    }
    for (final spots in additionalGlucoseSpots) {
      if (spots.isNotEmpty) {
        allYValues.addAll(spots.map((e) => e.y));
      }
    }

    // 計算顯示範圍（Y）：手動優先，其次使用 provider 設定或自動
    _Range gluRange;
    final hasUserRange = glucoseRange.min != null && glucoseRange.max != null;

    if (_yManual && _yMinManual != null && _yMaxManual != null) {
      gluRange = _Range(_yMinManual!, _yMaxManual!); // ← 手動優先
    } else if (hasUserRange) {
      gluRange = _calcRange(
        allYValues,
        fixedMin: glucoseRange.min,
        fixedMax: glucoseRange.max,
        targetTicks: 12,
      );
    } else {
      gluRange = _calcRange(allYValues, targetTicks: 12); // 自動（依目前視窗）
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

    // 構建所有線的 LineChartBarData
    final List<LineChartBarData> allLineBars = [];

    // 隱形基線
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

    // 主線（藍色）
    if (glucoseFromCurrentWin.length >= 2) {
      allLineBars.addAll(_buildContinuousSegments(glucoseFromCurrentWin, Colors.blue));
      allLineBars.addAll(_buildGapSegments(glucoseFromCurrentWin, Colors.blue));
    }

    if (glucoseFromCurrentWin.isNotEmpty) {
      allLineBars.add(LineChartBarData(
        spots: glucoseFromCurrentWin,
        isCurved: false,
        barWidth: 0,
        color: Colors.transparent,
        dotData: FlDotData(
          show: true,
          getDotPainter: (spot, percent, barData, index) {
            // ✅ 判斷是否為最新的點（最後一個）
            final isLatest = index == glucoseFromCurrentWin.length - 1;
            return FlDotCirclePainter(
              radius: isLatest ? 4 : 3,  // 最新點稍微大一點
              color: isLatest ? Colors.red : Colors.blue,  // 最新點紅色，其他藍色
              strokeWidth: 1.5,
              strokeColor: Colors.white,
            );
          },
        ),
      ));
    }

    // 額外的線
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
                // ✅ 判斷是否為最新的點（最後一個）
                final isLatest = index == glucoseSpots.length - 1;
                return FlDotCirclePainter(
                  radius: isLatest ? 4 : 3,  // 最新點稍微大一點
                  color: isLatest ? Colors.red : config.color,  // 最新點紅色，其他用線的顏色
                  strokeWidth: 1.5,
                  strokeColor: Colors.white,
                );
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
          child: Stack(
            children: [
              // ✅ 雙擊復位 + Listener 手勢
              GestureDetector(
                onDoubleTap: () {
                  setState(() {
                    // X 回預設
                    _isManualMode = false;
                    _currentWindowWidthMs = defaultWindowMs;
                    _initializeWindow();

                    // Y 回自動
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
                              // 右軸顯示 nA（由左軸使用相同公式反推）
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
                              // 找出被點擊的線（優先選擇有顏色的線，跳過隱形基線）
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

                              // 判斷是主線還是額外線
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

                              // 從原始數據中找到最接近的點
                              FlSpot? closestRawSpot;
                              double minDistance = double.infinity;
                              for (final raw in rawSpots) {
                                if (raw.x >= _tStartMs && raw.x < _tEndMs) {
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
                                      ) * 1e-9 // nA -> A（原註解延續；這裡僅當備用）
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
                              ); // nA

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

              // ✅ 縮放指示器
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
                          '縮放中 (${_pointers.length}指)',
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

              // ✅ 拖動指示器
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
                          '拖動中',
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
      if (hours >= 36) {
        return '36 小時';
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

  List<FlSpot> _buildPlaceholderSpots(int seconds, double baselineCurrent) {
    final nowMs = DateTime.now().millisecondsSinceEpoch.toDouble();
    final startMs = nowMs - seconds * 1000;
    const intervalMs = 5 * 1000.0;
    final numPoints = (seconds / 5).ceil() + 1;

    return List<FlSpot>.generate(numPoints, (i) {
      final t = startMs + i * intervalMs;
      final w1 = 2 * math.pi / 12;
      final w2 = 2 * math.pi / 30;
      final jitter = math.sin(i * w1) * 0.01 + math.sin(i * w2) * 0.005;
      return FlSpot(t, baselineCurrent + jitter);
    });
  }

  List<FlSpot> _buildWindowAlignedPlaceholder(double startMs, double endMs, double baselineCurrent) {
    const intervalMs = 5 * 1000.0;
    final durationMs = endMs - startMs;
    final numPoints = (durationMs / intervalMs).floor() + 1;

    return List<FlSpot>.generate(numPoints, (i) {
      final t = startMs + i * intervalMs;
      const y = 0.0;
      return FlSpot(t, y);
    });
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
    // 1) 若使用者有指定上下限（任一個），就以使用者值為主，另一邊用資料推得（或合理預設），
    //    並且「不做」padding / nice 刻度，避免 3000 變 520。
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

    // 2) 沒有固定範圍 → 自動模式
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