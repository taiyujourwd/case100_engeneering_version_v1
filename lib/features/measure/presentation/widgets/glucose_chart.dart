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
}

/// 雙 Y 軸曲線圖：左軸=血糖(mg/dL)、右軸=電流(nA)
/// - 換算關係:血糖(mg/dL) = slope × 電流(A) × 1E8 + intercept
/// - Y軸範圍由 Riverpod Provider 控制（固定）
/// - X軸支援雙指縮放：6分鐘 ~ 24小時
/// - 使用接收到的時間和電流直接繪製曲線
/// - 同一天延續繪製，不同天清空重新開始
/// - 支持手勢縮放和滑動查看歷史
/// - 點擊曲線顯示該點詳細資訊，並繪製虛線到X/Y軸
/// - **新增：支援多條曲線繪製**
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
  // ✅ 縮放範圍：6分鐘 到 24小時
  static const double minWindowMs = 6 * 60 * 1000.0;
  static const double maxWindowMs = 24 * 60 * 60 * 1000.0;
  static const double defaultWindowMs = 6 * 60 * 1000.0;
  static const double oneMinuteMs = 60 * 1000.0;

  late double _tStartMs;
  late double _tEndMs;
  late double _currentWindowWidthMs;
  DateTime? _firstDataTime;

  bool _isManualMode = false;

  // ✅ 手動追蹤觸摸點
  final Map<int, Offset> _pointers = {};  // pointer ID -> 位置
  bool _isDragging = false;
  bool _isScaling = false;

  // 拖動相關
  double _dragStartX = 0;
  double? _lastDragX;

  // 縮放相關
  double _scaleStartDistance = 0;
  double _windowWidthBeforeScale = defaultWindowMs;

  // 觸摸點狀態
  String? _touchedLineId;  // 新增：記錄被觸摸的線ID
  double? _touchedY;
  double? _touchedX;
  String? _tooltipText;

  // 保存原始採樣數據（支援多條線）
  List<FlSpot> _rawCurrentSpots = [];
  final Map<String, List<FlSpot>> _rawSpotsMap = {};

  // 記錄當前繪圖的日期
  DateTime? _currentPlotDate;

  // 「自上一筆」累積秒數
  Timer? _elapsedTicker;
  int _elapsedSec = 0;           // 從上一筆開始累積的秒數
  DateTime? _lastSampleTime;     // 最近一筆資料的時間戳（只用來判斷是否新點）

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
        setState(() {});
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
              oldConfig.intercept != newConfig.intercept) {
            hasChanged = true;
            break;
          }
        }
      }
      if (hasChanged && mounted) {
        setState(() {});
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
      startTime = DateTime(
        earliestTime.year,
        earliestTime.month,
        earliestTime.day,
        earliestTime.hour,
        earliestTime.minute,
        0,
        0,
      );
    } else {
      final now = DateTime.now();
      startTime = DateTime(now.year, now.month, now.day, now.hour, now.minute, 0, 0);
    }

    _tStartMs = startTime.millisecondsSinceEpoch.toDouble();
    _tEndMs = _tStartMs + _currentWindowWidthMs;
  }

  void _advanceWindowIfNeeded(double latestX) {
    if (_isManualMode) return;
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

  // ✅ 縮放處理
  void _handleScale(double currentDistance) {
    if (_scaleStartDistance == 0) return;

    setState(() {
      _isManualMode = true;

      // 計算縮放比例
      final scale = _scaleStartDistance / currentDistance;

      // 計算新的視窗寬度
      final newWindowWidth = (_windowWidthBeforeScale * scale).clamp(
        minWindowMs,
        maxWindowMs,
      );

      // 保持視窗中心點不變
      final center = (_tStartMs + _tEndMs) / 2;
      _tStartMs = center - newWindowWidth / 2;
      _tEndMs = center + newWindowWidth / 2;

      // 更新當前視窗寬度
      _currentWindowWidthMs = newWindowWidth;

      // 對齊到分鐘
      final startTime = DateTime.fromMillisecondsSinceEpoch(_tStartMs.toInt());
      final alignedStart = DateTime(
        startTime.year, startTime.month, startTime.day,
        startTime.hour, startTime.minute, 0, 0,
      );
      _tStartMs = alignedStart.millisecondsSinceEpoch.toDouble();
      _tEndMs = _tStartMs + newWindowWidth;
    });
  }

  // ✅ 處理觸摸開始
  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;

    debugPrint('👇 手指按下: ${_pointers.length} 個手指');

    if (_pointers.length == 1) {
      // ✅ 單指：準備拖動
      final pos = _pointers.values.first;
      _dragStartX = pos.dx;
      _lastDragX = pos.dx;
      _isDragging = false;
      _isScaling = false;

    } else if (_pointers.length == 2) {
      // ✅ 雙指：開始縮放
      setState(() {
        _isScaling = true;
        _isDragging = false;

        // 清除 tooltip
        _touchedY = null;
        _touchedX = null;
        _tooltipText = null;
        _touchedLineId = null;

        // 計算初始距離
        final positions = _pointers.values.toList();
        final dx = positions[0].dx - positions[1].dx;
        final dy = positions[0].dy - positions[1].dy;
        _scaleStartDistance = math.sqrt(dx * dx + dy * dy);
        _windowWidthBeforeScale = _currentWindowWidthMs;
      });

      debugPrint('🔍 開始縮放: 初始距離 = ${_scaleStartDistance.toStringAsFixed(1)}');
    }
  }

  // ✅ 處理觸摸移動
  void _onPointerMove(PointerMoveEvent event) {
    _pointers[event.pointer] = event.localPosition;

    if (_pointers.length == 2 && _isScaling) {
      // ✅ 雙指縮放
      final positions = _pointers.values.toList();
      final dx = positions[0].dx - positions[1].dx;
      final dy = positions[0].dy - positions[1].dy;
      final currentDistance = math.sqrt(dx * dx + dy * dy);

      _handleScale(currentDistance);

    } else if (_pointers.length == 1 && !_isScaling) {
      // ✅ 單指拖動
      final currentX = event.localPosition.dx;
      final dragDistance = (currentX - _dragStartX).abs();

      // 移動距離夠遠才開始拖動
      if (!_isDragging && dragDistance > 10) {
        setState(() {
          _isDragging = true;
        });
        debugPrint('👆 開始拖動');
      }

      // 執行拖動
      if (_isDragging && _lastDragX != null) {
        final delta = currentX - _lastDragX!;
        _handleHorizontalDrag(delta);
        _lastDragX = currentX;
      }
    }
  }

  // ✅ 處理觸摸結束
  void _onPointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);

    debugPrint('👆 手指抬起: 剩餘 ${_pointers.length} 個手指');

    if (_pointers.isEmpty) {
      // ✅ 所有手指都抬起
      debugPrint('✋ 手勢結束: isDragging=$_isDragging, isScaling=$_isScaling');

      if (_isDragging || _isScaling) {
        _alignWindowToMinute();
      }

      setState(() {
        _isDragging = false;
        _isScaling = false;
        _lastDragX = null;
        _scaleStartDistance = 0;
      });

    } else if (_pointers.length == 1 && _isScaling) {
      // ✅ 從雙指變成單指：取消縮放
      setState(() {
        _isScaling = false;
        _isDragging = false;
      });
      debugPrint('⚠️ 縮放中斷，剩一根手指');
    }
  }

  // ✅ 處理觸摸取消
  void _onPointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);

    if (_pointers.isEmpty) {
      setState(() {
        _isDragging = false;
        _isScaling = false;
        _lastDragX = null;
        _scaleStartDistance = 0;
      });
    }
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
    return s * (currentAmperes * 1E9) + i;
  }

  double _glucoseToCurrent(double glucose, {double? slope, double? intercept}) {
    final s = slope ?? widget.slope;
    if (s == 0) return 0;
    final i = intercept ?? widget.intercept;
    return (glucose - i) / s;
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
    final intervalMs = _currentWindowWidthMs / 6.0;
    final intervalMinutes = intervalMs / oneMinuteMs;

    double niceIntervalMinutes;

    if (intervalMinutes <= 1) {
      niceIntervalMinutes = 1;
    } else if (intervalMinutes <= 2) {
      niceIntervalMinutes = 2;
    } else if (intervalMinutes <= 3) {
      niceIntervalMinutes = 3;
    } else if (intervalMinutes <= 5) {
      niceIntervalMinutes = 5;
    } else if (intervalMinutes <= 10) {
      niceIntervalMinutes = 10;
    } else if (intervalMinutes <= 15) {
      niceIntervalMinutes = 15;
    } else if (intervalMinutes <= 20) {
      niceIntervalMinutes = 20;
    } else if (intervalMinutes <= 30) {
      niceIntervalMinutes = 30;
    } else if (intervalMinutes <= 60) {
      niceIntervalMinutes = 60;
    } else if (intervalMinutes <= 120) {
      niceIntervalMinutes = 120;
    } else if (intervalMinutes <= 180) {
      niceIntervalMinutes = 180;
    } else if (intervalMinutes <= 240) {
      niceIntervalMinutes = 240;
    } else {
      niceIntervalMinutes = 360;
    }

    return niceIntervalMinutes * oneMinuteMs;
  }

  String _formatTimeLabel(DateTime dt, double intervalMs) {
    final intervalMinutes = intervalMs / oneMinuteMs;

    if (intervalMinutes >= 60) {
      final hh = dt.hour.toString().padLeft(2, '0');
      return '$hh:00';
    } else {
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
            _initializeWindow();
          });
        }
      });
    }

    final todaySamples = _filterTodaySamples(widget.samples);
    final hasData = todaySamples.isNotEmpty;
    final bleConnected = ref.watch(bleConnectionStateProvider); // 讀取藍牙連線狀態（控制要不要計時）

    // ★ 偵測新點：第一次或出現更晚的 ts
    if (hasData) {
      final newLast = todaySamples.last.ts;
      final isNewPoint = _lastSampleTime == null || newLast.isAfter(_lastSampleTime!);

      if (isNewPoint) {
        _lastSampleTime = newLast;
        _elapsedSec = 0;            // 歸零
        if (bleConnected) {
          _startElapsedTicker();    // 已連線就每秒累加
        } else {
          _stopElapsedTicker(reset: false);
        }
      }
    } else {
      // 沒有任何資料 → 停止與歸零
      _lastSampleTime = null;
      _stopElapsedTicker(reset: true);
    }

    if (hasData && _firstDataTime == null) {
      _firstDataTime = todaySamples.first.ts;
      _initializeWindow();
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

    // 處理主線數據
    final currBasisSpots = () {
      if (!hasData) {
        _rawCurrentSpots = _buildPlaceholderSpots(
          (_currentWindowWidthMs / 1000).toInt(),
          widget.placeholderCurrentA,
        );
        return _rawCurrentSpots;
      }

      _rawCurrentSpots = _mapToSortedSpots(todaySamples, (s) => _getCurrent(s));
      return _rawCurrentSpots;
    }();

    if (hasData) {
      final latestX = todaySamples.last.ts.millisecondsSinceEpoch.toDouble();
      _advanceWindowIfNeeded(latestX);
    }

    var currWin = _applyWindowFixed(currBasisSpots);
    final hasDataInWindow = currWin.isNotEmpty && hasData;

    if (currWin.isEmpty) {
      currWin = _buildWindowAlignedPlaceholder(_tStartMs, _tEndMs, widget.placeholderCurrentA);
    }

    final glucoseFromCurrentWin = currWin
        .map((p) => FlSpot(p.x, _currentToGlucose(p.y)))
        .toList();

    // 處理額外的線
    final List<List<FlSpot>> additionalGlucoseSpots = [];

    if (widget.additionalLines != null) {
      for (final config in widget.additionalLines!) {
        final samples = _filterTodaySamples(config.samples);
        final spots = samples.isNotEmpty
            ? _mapToSortedSpots(samples, (s) => _getCurrent(s))
            : <FlSpot>[];

        _rawSpotsMap[config.id] = spots;

        if (samples.isNotEmpty) {
          final latestX = samples.last.ts.millisecondsSinceEpoch.toDouble();
          _advanceWindowIfNeeded(latestX);
        }

        var win = _applyWindowFixed(spots);
        if (win.isEmpty) {
          win = [];
        }

        final glucoseSpots = win
            .map((p) => FlSpot(p.x, _currentToGlucose(p.y, slope: config.slope, intercept: config.intercept)))
            .toList();

        additionalGlucoseSpots.add(glucoseSpots);
      }
    }

    double? safeMin = glucoseRange.min;
    double? safeMax = glucoseRange.max;

    if (safeMin != null && safeMax != null) {
      final unreasonable =
          safeMin.abs() > 1000 ||
              safeMax.abs() > 1000 ||
              (safeMax - safeMin).abs() > 2000 ||
              safeMin >= safeMax;
      if (unreasonable) {
        safeMin = null;
        safeMax = null;
      }
    }

    if (!hasDataInWindow && additionalGlucoseSpots.every((s) => s.isEmpty)) {
      if (safeMin == null || safeMax == null) {
        safeMin = 0.0;
        safeMax = 400.0;
      }
    }

    // 收集所有線的Y值來計算範圍
    final allYValues = <double>[];
    if (hasDataInWindow) {
      allYValues.addAll(glucoseFromCurrentWin.map((e) => e.y));
    }
    for (final spots in additionalGlucoseSpots) {
      if (spots.isNotEmpty) {
        allYValues.addAll(spots.map((e) => e.y));
      }
    }

    final gluRange = _calcRange(
      allYValues.isNotEmpty ? allYValues : [safeMin ?? 0, safeMax ?? 400],
      fixedMin: safeMin,
      fixedMax: safeMax,
      targetTicks: 12,
    );

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
    if (hasDataInWindow && glucoseFromCurrentWin.length >= 2) {
      allLineBars.addAll(_buildContinuousSegments(glucoseFromCurrentWin, Colors.blue));
      allLineBars.addAll(_buildGapSegments(glucoseFromCurrentWin, Colors.blue));
    }

    if (hasDataInWindow) {
      allLineBars.add(LineChartBarData(
        spots: glucoseFromCurrentWin,
        isCurved: false,
        barWidth: 0,
        color: Colors.transparent,
        dotData: FlDotData(
          show: true,
          getDotPainter: (spot, percent, barData, index) {
            return FlDotCirclePainter(
              radius: 3,
              color: Colors.blue,
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
                return FlDotCirclePainter(
                  radius: 3,
                  color: config.color,
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
                      Text('${voltage?.toStringAsFixed(3) ?? '--'} (V)'),
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
              // ✅ 使用 Listener 手動追蹤觸摸點
              Listener(
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
                          reservedSize: 20,
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
                          reservedSize: 20,
                          interval: safeRightInterval,
                          getTitlesWidget: (glucoseValue, _) {
                            final currentTimesE8 = _glucoseToCurrent(glucoseValue);
                            final currentAmperes = currentTimesE8 / 1E8;
                            final currentNanoAmperes = currentAmperes * 1E9;

                            String text;
                            if (currentNanoAmperes.abs() < 0.01) {
                              text = '0.00';
                            } else {
                              text = currentNanoAmperes.toStringAsFixed(2);
                            }
                            return Text(text, style: const TextStyle(fontSize: 8));
                          },
                        ),
                        axisNameWidget: const Padding(
                          padding: EdgeInsets.only(right: 8, bottom: 4),
                          child: Text('Current (nA)'),
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

                            final target = closestRawSpot ?? FlSpot(
                                hit.x,
                                _glucoseToCurrent(hit.y, slope: lineSlope, intercept: lineIntercept) / 1E8
                            );

                            final displaySpot = FlSpot(
                              target.x,
                              _currentToGlucose(target.y, slope: lineSlope, intercept: lineIntercept),
                            );

                            final dt = DateTime.fromMillisecondsSinceEpoch(displaySpot.x.toInt());
                            final timeStr = _formatTime(dt);
                            final actualCurrentA = _glucoseToCurrent(
                                displaySpot.y,
                                slope: lineSlope,
                                intercept: lineIntercept
                            ) / 1E8;
                            final currentNanoAmperes = actualCurrentA * 1E9;

                            setState(() {
                              _touchedX = displaySpot.x;
                              _touchedY = displaySpot.y;
                              _tooltipText = isMainLine
                                  ? '時間: $timeStr\n'
                                  '血糖: ${displaySpot.y.toStringAsFixed(2)} mg/dL\n'
                                  '電流: ${currentNanoAmperes.toStringAsFixed(2)} nA\n'
                                  '(實際採樣值)'
                                  : '【$lineLabel】\n'
                                  '時間: $timeStr\n'
                                  '血糖: ${displaySpot.y.toStringAsFixed(2)} mg/dL\n'
                                  '電流: ${currentNanoAmperes.toStringAsFixed(2)} nA';
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
    if (minutes < 60) {
      return '${minutes.toStringAsFixed(0)} 分鐘';
    } else {
      final hours = minutes / 60;
      if (hours < 24) {
        return '${hours.toStringAsFixed(1)} 小時';
      } else {
        return '24 小時';
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
      final y = 0.0;
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
    double minV, maxV;

    if (fixedMin != null && fixedMax != null) {
      minV = fixedMin;
      maxV = fixedMax;
    } else if (values.isEmpty) {
      minV = 0;
      maxV = 400;
    } else {
      final rawMin = values.reduce(math.min);
      final rawMax = values.reduce(math.max);

      final span = (rawMax - rawMin).abs();
      final pad = span * 0.15 + 1e-12;
      minV = rawMin - pad;
      maxV = rawMax + pad;

      if (span < 1e-10) {
        final center = (minV + maxV) / 2;
        final absCenter = center.abs();
        if (absCenter < 1e-10) {
          minV = 0;
          maxV = 400;
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
      minV = 0;
      maxV = 400;
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