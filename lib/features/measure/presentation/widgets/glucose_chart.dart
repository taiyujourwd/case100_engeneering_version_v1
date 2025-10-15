import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/isar_schemas.dart';
import '../providers/current_glucose_providers.dart';

/// 雙 Y 軸曲線圖：左軸=血糖(mg/dL)、右軸=電流(nA)
/// - 換算關係:血糖(mg/dL) = slope × 電流(A) × 1E8 + intercept
/// - Y軸範圍由 Riverpod Provider 控制
/// - X軸顯示6分鐘視窗，每1分鐘一個刻度
/// - 使用接收到的時間和電流直接繪製曲線
/// - 同一天延續繪製，不同天清空重新開始
/// - 支持手勢縮放和滑動查看歷史
/// - 點擊曲線顯示該點詳細資訊，並繪製虛線到X/Y軸
/// - 點擊空白處可清除虛線和 tooltip
class GlucoseChart extends ConsumerStatefulWidget {
  final List<Sample> samples;
  final int initialWindowSeconds;
  final double placeholderCurrentA;
  final double slope;
  final double intercept;

  const GlucoseChart({
    super.key,
    required this.samples,
    this.initialWindowSeconds = 360,
    this.placeholderCurrentA = 0.0,
    this.slope = 600.0,
    this.intercept = 0.0,
  });

  @override
  ConsumerState<GlucoseChart> createState() => _GlucoseChartState();
}

class _GlucoseChartState extends ConsumerState<GlucoseChart> {
  static const int windowMinutes = 6;
  static const double oneMinuteMs = 60 * 1000.0;

  late double _tStartMs;
  late double _tEndMs;
  DateTime? _firstDataTime;

  // 手勢控制狀態
  double _zoomLevel = 1.0;
  bool _isManualMode = false;
  double? _lastDragPosition;

  // 觸摸點狀態（用於繪製十字虛線）
  double? _touchedY;
  double? _touchedX;
  String? _tooltipText;

  // 手勢檢測狀態
  bool _isDragging = false;
  double _dragStartX = 0;

  // 保存原始采样数据（用于点击时显示实际值）
  List<FlSpot> _rawCurrentSpots = [];

  // 记录当前绘图的日期（用于检测日期变化）
  DateTime? _currentPlotDate;

  @override
  void initState() {
    super.initState();
    _initializeWindow();
  }

  @override
  void didUpdateWidget(GlucoseChart oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 當 slope 或 intercept 變化時，強制重建
    if (oldWidget.slope != widget.slope ||
        oldWidget.intercept != widget.intercept) {
      if (mounted) {
        setState(() {
          // 參數變更 → 重新繪製
        });
      }
    }
  }

  void _initializeWindow() {
    DateTime startTime;

    if (widget.samples.isNotEmpty) {
      _firstDataTime = widget.samples.first.ts;
      startTime = DateTime(
        _firstDataTime!.year,
        _firstDataTime!.month,
        _firstDataTime!.day,
        _firstDataTime!.hour,
        _firstDataTime!.minute,
        0,
        0,
      );
    } else {
      final now = DateTime.now();
      startTime = DateTime(now.year, now.month, now.day, now.hour, now.minute, 0, 0);
    }

    _tStartMs = startTime.millisecondsSinceEpoch.toDouble();
    _tEndMs = _tStartMs + windowMinutes * oneMinuteMs;
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
      _zoomLevel = 1.0;
      _initializeWindow();
      final todaySamples = _filterTodaySamples(widget.samples);
      if (todaySamples.isNotEmpty) {
        final latestX = todaySamples.last.ts.millisecondsSinceEpoch.toDouble();
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

      final todaySamples = _filterTodaySamples(widget.samples);
      if (todaySamples.isNotEmpty) {
        final firstDataMs = todaySamples.first.ts.millisecondsSinceEpoch.toDouble();
        final lastDataMs = todaySamples.last.ts.millisecondsSinceEpoch.toDouble();

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

  void _handleScale(double scale) {
    setState(() {
      _isManualMode = true;
      final newZoom = (_zoomLevel * scale).clamp(0.5, 4.0);

      if (newZoom != _zoomLevel) {
        final center = (_tStartMs + _tEndMs) / 2;
        _zoomLevel = newZoom;
        final newWidth = windowMinutes * oneMinuteMs * _zoomLevel;

        _tStartMs = center - newWidth / 2;
        _tEndMs = center + newWidth / 2;

        final startTime = DateTime.fromMillisecondsSinceEpoch(_tStartMs.toInt());
        final alignedStart = DateTime(
          startTime.year, startTime.month, startTime.day,
          startTime.hour, startTime.minute, 0, 0,
        );
        _tStartMs = alignedStart.millisecondsSinceEpoch.toDouble();
        _tEndMs = _tStartMs + newWidth;
      }
    });
  }

  List<FlSpot> _applyWindowFixed(List<FlSpot> spots) {
    if (spots.isEmpty) return spots;

    final List<FlSpot> inWin = [];
    FlSpot? leftNeighbor;   // 視窗左側最近的點（x < _tStartMs）
    FlSpot? rightNeighbor;  // 視窗右側第一個點（x >= _tEndMs）

    for (final p in spots) {
      if (p.x < _tStartMs) {
        // 持續更新，最後會是距離左邊界最近的那一個
        leftNeighbor = p;
      } else if (p.x >= _tEndMs) {
        // 記錄第一個超過右邊界的點（只要第一個）
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

  double _currentToGlucose(double currentAmperes) {
    return widget.slope * (currentAmperes * 1E8) + widget.intercept;
  }

  double _glucoseToCurrent(double glucose) {
    if (widget.slope == 0) return 0;
    return (glucose - widget.intercept) / widget.slope;
  }

  List<LineChartBarData> _buildContinuousSegments(List<FlSpot> spots) {
    if (spots.length < 2) return [];
    const gapThresholdMs = 90 * 1000.0;

    final List<LineChartBarData> segments = [];
    List<FlSpot> currentSegment = [spots[0]];

    for (int i = 1; i < spots.length; i++) {
      final prev = spots[i - 1];
      final curr = spots[i];
      final timeDiff = curr.x - prev.x;

      // 先檢查是否需要斷段
      final shouldBreak = timeDiff > gapThresholdMs;

      // 對 (prev -> curr) 做視窗截斷
      final clamped = _clampSegmentToWindow(prev, curr, _tStartMs, _tEndMs);

      if (!shouldBreak) {
        // 連續段：有有效截斷才加進當前段
        if (clamped.length == 2) {
          if (currentSegment.isEmpty) currentSegment.add(clamped.first);
          currentSegment.add(clamped.last);
        }
      } else {
        // 先收掉目前連續段
        if (currentSegment.length >= 2) {
          segments.add(LineChartBarData(
            spots: List.from(currentSegment),
            isCurved: false,
            isStrokeCapRound: true,
            barWidth: 2,
            color: Colors.blue,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ));
        }
        currentSegment = [];

        // 斷段之間的「橋接線」：也用截斷結果畫（可選）
        if (clamped.length == 2) {
          segments.add(LineChartBarData(
            spots: clamped,
            isCurved: false,
            barWidth: 2,
            color: Colors.blue,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: false),
          ));
        }
      }
    }

    if (currentSegment.length >= 2) {
      segments.add(LineChartBarData(
        spots: List.from(currentSegment),
        isCurved: false,
        isStrokeCapRound: true,
        barWidth: 2,
        color: Colors.blue,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: false),
      ));
    }

    return segments;
  }

  List<LineChartBarData> _buildGapSegments(List<FlSpot> spots) {
    if (spots.length < 2) return [];

    const gapThresholdMs = 90 * 1000.0;
    final List<LineChartBarData> gapSegments = [];

    for (int i = 1; i < spots.length; i++) {
      final timeDiff = spots[i].x - spots[i - 1].x;

      if (timeDiff >= gapThresholdMs) { // 注意：已改成 >=
        final seg = _clampSegmentToWindow(
          spots[i - 1],
          spots[i],
          _tStartMs,
          _tEndMs,
        );
        if (seg.length == 2) {
          gapSegments.add(
            LineChartBarData(
              spots: seg,
              isCurved: false,
              barWidth: 2,
              color: Colors.blue, // 或保留淡色/虛線
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(show: false),
            ),
          );
        }
      }
    }
    return gapSegments;
  }

  List<FlSpot> _clampSegmentToWindow(FlSpot a, FlSpot b, double minX, double maxX) {
    FlSpot p = a, q = b;

    // 兩端皆在視窗內 → 直接回傳
    if (p.x >= minX && p.x <= maxX && q.x >= minX && q.x <= maxX) {
      return [p, q];
    }

    // 如果左端在左界外，插值到 minX
    if (p.x < minX && q.x > p.x) {
      final t = (minX - p.x) / (q.x - p.x);
      final y = p.y + (q.y - p.y) * t;
      p = FlSpot(minX, y);
    }
    // 如果右端在右界外，插值到 maxX
    if (q.x > maxX && q.x > p.x) {
      final t = (maxX - p.x) / (q.x - p.x);
      final y = p.y + (q.y - p.y) * t;
      q = FlSpot(maxX, y);
    }
    // 若 a 在右界外、b 在界內，或其它順序，對稱處理
    if (p.x > maxX && q.x < p.x) {
      final t = (maxX - q.x) / (p.x - q.x);
      final y = q.y + (p.y - q.y) * t;
      p = FlSpot(maxX, y);
    }
    if (q.x < minX && p.x > q.x) {
      final t = (minX - q.x) / (p.x - q.x);
      final y = q.y + (p.y - q.y) * t;
      q = FlSpot(minX, y);
    }

    // 若截完後仍不在視窗內，代表整段不與視窗相交 → 不畫
    final intersects =
        (p.x >= minX && p.x <= maxX) || (q.x >= minX && q.x <= maxX);
    if (!intersects) return const [];

    return [p, q];
  }

  @override
  Widget build(BuildContext context) {
    final glucoseRange = ref.watch(glucoseRangeProvider);

    final todaySamples = _filterTodaySamples(widget.samples);
    final hasData = todaySamples.isNotEmpty;

    if (widget.samples.isNotEmpty) {
      final latestDate = widget.samples.last.ts;
      if (_shouldReset(latestDate)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _isManualMode = false;
              _zoomLevel = 1.0;
              _firstDataTime = null;
              _touchedY = null;
              _touchedX = null;
              _tooltipText = null;
              _initializeWindow();
            });
          }
        });
      }
    }

    final latestSample = hasData ? todaySamples.last : null;

    if (hasData && _firstDataTime == null) {
      _firstDataTime = todaySamples.first.ts;
      _initializeWindow();
    }

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

    final currBasisSpots = () {
      if (!hasData) {
        _rawCurrentSpots = _buildPlaceholderSpots(
          widget.initialWindowSeconds,
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

    // 視窗內是否有真實數據
    final hasDataInWindow = currWin.isNotEmpty && hasData;

    if (currWin.isEmpty) {
      currWin = _buildWindowAlignedPlaceholder(_tStartMs, _tEndMs, widget.placeholderCurrentA);
    }

    final glucoseFromCurrentWin = currWin
        .map((p) => FlSpot(p.x, _currentToGlucose(p.y)))
        .toList();

    // 使用 Provider 的血糖範圍，但加入安全限制
    double? safeMin = glucoseRange.min;
    double? safeMax = glucoseRange.max;

    // 只有在兩者皆非空時才檢查合理性
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

    // 當視窗內沒有真實數據時，保證有固定範圍以顯示格線
    if (!hasDataInWindow) {
      if (safeMin == null || safeMax == null) {
        safeMin = 0.0;
        safeMax = 400.0;
      }
    }

    final gluRange = _calcRange(
      hasDataInWindow ? glucoseFromCurrentWin.map((e) => e.y) : [safeMin ?? 0, safeMax ?? 400],
      fixedMin: safeMin,
      fixedMax: safeMax,
      targetTicks: 12,
    );

    final minX = _tStartMs;
    final maxX = _tEndMs;

    // 軸刻度間隔
    final leftInterval = _niceInterval(gluRange.min, gluRange.max, 12);
    final rightInterval = _niceInterval(gluRange.min, gluRange.max, 6);

    // 安全間隔
    final safeLeftInterval = leftInterval > 0 && leftInterval.isFinite ? leftInterval : 50.0;
    final safeRightInterval = rightInterval > 0 && rightInterval.isFinite ? rightInterval : 100.0;

    // ---- 這條不可見 baseline，確保就算沒有資料也會渲染格線與座標 ----
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
              // Listener 檢測原始手勢事件
              Listener(
                onPointerDown: (event) {
                  _dragStartX = event.position.dx;
                  _isDragging = false;
                },
                onPointerMove: (event) {
                  final dragDistance = (event.position.dx - _dragStartX).abs();
                  if (dragDistance > 15) {
                    _isDragging = true;
                    if (_lastDragPosition != null) {
                      final delta = event.position.dx - _lastDragPosition!;
                      _handleHorizontalDrag(delta);
                    }
                    _lastDragPosition = event.position.dx;
                  }
                },
                onPointerUp: (event) {
                  if (_isDragging) {
                    _alignWindowToMinute();
                  }
                  _lastDragPosition = null;
                  _isDragging = false;
                },
                child: GestureDetector(
                  onScaleStart: (details) {
                    _lastDragPosition = details.focalPoint.dx;
                    _dragStartX = details.focalPoint.dx;
                    _isDragging = false;
                  },
                  onScaleUpdate: (details) {
                    if (details.scale != 1.0 && details.pointerCount >= 2) {
                      if (!_isDragging) {
                        setState(() {
                          _touchedY = null;
                          _touchedX = null;
                          _tooltipText = null;
                        });
                      }
                      _handleScale(details.scale);
                      _isDragging = true;
                    }
                  },
                  onScaleEnd: (details) {
                    if (_isDragging) {
                      _alignWindowToMinute();
                    }
                    _lastDragPosition = null;
                    _isDragging = false;
                  },
                  child: LineChart(
                    LineChartData(
                      minX: minX,
                      maxX: maxX,
                      minY: gluRange.min,
                      maxY: gluRange.max,
                      clipData: const FlClipData(left: true, top: true, right: true, bottom: true),
                      lineBarsData: [
                        // 0) 不可見 baseline（保證渲染）
                        invisibleBaseline,

                        // 1) 連續段：仍然可保留合理性判斷（避免超平直假數據畫主線）
                        if (hasDataInWindow &&
                            glucoseFromCurrentWin.length >= 2 &&
                            _hasReasonableYRange(glucoseFromCurrentWin)) ...[
                          ..._buildContinuousSegments(glucoseFromCurrentWin),
                        ],

                        // 2) 跨段連線：不受 _hasReasonableYRange 限制（一定橋接）
                        if (hasDataInWindow && glucoseFromCurrentWin.length >= 2) ...[
                          ..._buildGapSegments(glucoseFromCurrentWin),
                        ],

                        // 3) 原始點（只有有真實數據時才顯示）
                        if (hasDataInWindow)
                          LineChartBarData(
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
                          ),
                      ],
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        drawHorizontalLine: true,
                        // ⬇⬇⬇ 改用左軸間隔，格線與左軸一致
                        horizontalInterval: safeLeftInterval,
                        verticalInterval: oneMinuteMs,
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
                            reservedSize: 55,
                            interval: safeLeftInterval,
                            getTitlesWidget: (v, _) {
                              String text;
                              if (v.abs() < 0.01 && v.abs() > 0) {
                                text = v.toStringAsExponential(1);
                              } else if (v.abs() < 1) {
                                text = v.toStringAsFixed(2);
                              } else if (v.abs() < 10) {
                                text = v.toStringAsFixed(1);
                              } else {
                                text = v.toStringAsFixed(0);
                              }
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
                            reservedSize: 55,
                            interval: safeRightInterval,
                            getTitlesWidget: (glucoseValue, _) {
                              final currentTimesE8 = _glucoseToCurrent(glucoseValue);
                              final currentAmperes = currentTimesE8 / 1E8;
                              final currentNanoAmperes = currentAmperes * 1E9;

                              String text;
                              if (currentNanoAmperes.abs() < 0.01) {
                                text = currentNanoAmperes.toStringAsExponential(2);
                              } else if (currentNanoAmperes.abs() < 1) {
                                text = currentNanoAmperes.toStringAsFixed(3);
                              } else if (currentNanoAmperes.abs() < 10) {
                                text = currentNanoAmperes.toStringAsFixed(2);
                              } else {
                                text = currentNanoAmperes.toStringAsFixed(1);
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
                            interval: oneMinuteMs,
                            getTitlesWidget: (value, meta) {
                              final dt = DateTime.fromMillisecondsSinceEpoch(value.toInt());
                              final hh = dt.hour.toString().padLeft(2, '0');
                              final mm = dt.minute.toString().padLeft(2, '0');
                              return Text('$hh:$mm', style: const TextStyle(fontSize: 10));
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
                        // 只在接近資料點時觸發
                        touchSpotThreshold: 4, // 像素，越小越嚴格
                        enabled: !_isDragging,
                        handleBuiltInTouches: true,

                        // 讓內建 tooltip 不畫，仍使用我們自訂的浮層
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipColor: (_) => Colors.transparent,
                          tooltipPadding: EdgeInsets.zero,
                          tooltipMargin: 0,
                          getTooltipItems: (touchedSpots) =>
                              touchedSpots.map((_) => null).toList(),
                        ),

                        getTouchedSpotIndicator: (barData, spotIndexes) {
                          // 命中點時顯示十字虛線 + 放大圓點
                          return spotIndexes.map((index) {
                            return TouchedSpotIndicatorData(
                              FlLine(
                                color: Colors.blue.withOpacity(0.8),
                                strokeWidth: 2,
                                dashArray: [5, 5],
                              ),
                              FlDotData(
                                show: true,
                                getDotPainter: (spot, percent, barData, index) {
                                  return FlDotCirclePainter(
                                    radius: 6,
                                    color: Colors.blue,
                                    strokeWidth: 3,
                                    strokeColor: Colors.white,
                                  );
                                },
                              ),
                            );
                          }).toList();
                        },

                        touchCallback: (FlTouchEvent event, LineTouchResponse? response) {
                          // 拖動過程不處理（你原本就有 _isDragging 控制）
                          if (_isDragging) return;

                          // 只有「點擊結束」或「長按結束」才決定是否顯示/清除
                          final isEndTap = event is FlTapUpEvent || event is FlLongPressEnd;
                          final isMoveUpdate = event is FlPanUpdateEvent;

                          if (isMoveUpdate) return; // 移動中不變更

                          // 命中的點（受 touchSpotThreshold 影響）
                          final spots = response?.lineBarSpots ?? const [];

                          if (isEndTap) {
                            if (spots.isEmpty) {
                              // 沒有命中任何點：清除虛線與詳情
                              setState(() {
                                _touchedX = null;
                                _touchedY = null;
                                _tooltipText = null;
                              });
                            } else {
                              // 命中點：以最近點為準，顯示虛線與詳情
                              final hit = spots.first;
                              final hitX = hit.x;

                              // 用你保存的原始點，找「此視窗內最接近 hitX 的原始採樣點」
                              FlSpot? closestRawSpot;
                              double minDistance = double.infinity;
                              for (final raw in _rawCurrentSpots) {
                                if (raw.x >= _tStartMs && raw.x < _tEndMs) {
                                  final d = (raw.x - hitX).abs();
                                  if (d < minDistance) {
                                    minDistance = d;
                                    closestRawSpot = raw;
                                  }
                                }
                              }

                              // 若找不到 raw，就用命中的那個點
                              final target = closestRawSpot ?? FlSpot(hit.x, _glucoseToCurrent(hit.y) / 1E8);

                              // 轉為顯示的血糖值（y）
                              final displaySpot = FlSpot(
                                target.x,
                                _currentToGlucose(target.y), // 以電流換算成 mg/dL 顯示
                              );

                              final dt = DateTime.fromMillisecondsSinceEpoch(displaySpot.x.toInt());
                              final timeStr = _formatTime(dt);
                              final actualCurrentA = _glucoseToCurrent(displaySpot.y) / 1E8;
                              final currentNanoAmperes = actualCurrentA * 1E9;

                              setState(() {
                                _touchedX = displaySpot.x;
                                _touchedY = displaySpot.y;
                                _tooltipText = '時間: $timeStr\n'
                                    '血糖: ${displaySpot.y.toStringAsFixed(2)} mg/dL\n'
                                    '電流: ${currentNanoAmperes.toStringAsFixed(2)} nA\n'
                                    '(實際採樣值)';
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
                            color: Colors.blue.withOpacity(0.8),
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
                            color: Colors.blue.withOpacity(0.8),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${(windowMinutes * _zoomLevel).toStringAsFixed(0)} 分鐘 | ${todaySamples.length} 點',
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                      if (_currentPlotDate != null)
                        Text(
                          '${_currentPlotDate!.year}/${_currentPlotDate!.month.toString().padLeft(2, '0')}/${_currentPlotDate!.day.toString().padLeft(2, '0')}',
                          style: const TextStyle(color: Colors.white70, fontSize: 10),
                        ),
                    ],
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
                        color: Colors.blueGrey.withOpacity(0.9),
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

    // 使用近零的電流值，避免產生極端血糖值
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

  bool _hasReasonableYRange(List<FlSpot> spots) {
    if (spots.length < 2) return false;

    final yValues = spots.map((e) => e.y).toList();
    final minY = yValues.reduce(math.min);
    final maxY = yValues.reduce(math.max);
    final yRange = (maxY - minY).abs();

    if (yRange < 0.01) {
      return false;
    }

    if (minY.abs() < 0.001 && maxY.abs() < 0.001) {
      return false;
    }

    return true;
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