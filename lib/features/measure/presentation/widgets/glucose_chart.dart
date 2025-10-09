import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../data/isar_schemas.dart';

/// 雙 Y 軸曲線圖：左軸=血糖(mg/dL)、右軸=電流(A)
/// - 換算關係：血糖(mg/dL) = slope × 電流(A) + intercept
/// - Y軸範圍動態調整，可包含正負值
/// - X軸顯示6分鐘視窗，每1分鐘一個刻度
/// - 正弦波每5秒一個點，確保波形平滑完整
/// - 支持手勢縮放和滑動查看歷史
/// - 點擊曲線顯示該點詳細資訊，並繪製虛線到X/Y軸
/// - 點擊空白處可清除虛線和 tooltip
class GlucoseChart extends StatefulWidget {
  final List<Sample> samples;
  final int initialWindowSeconds;
  final double placeholderCurrentA;
  final double slope;
  final double intercept;
  final double? fixedGlucoseMin, fixedGlucoseMax;
  final double? fixedCurrentMin, fixedCurrentMax;

  const GlucoseChart({
    super.key,
    required this.samples,
    this.initialWindowSeconds = 360,
    this.placeholderCurrentA = 0.0,
    this.slope = 600.0,
    this.intercept = 0.0,
    this.fixedGlucoseMin,
    this.fixedGlucoseMax,
    this.fixedCurrentMin,
    this.fixedCurrentMax,
  });

  @override
  State<GlucoseChart> createState() => _GlucoseChartState();
}

class _GlucoseChartState extends State<GlucoseChart> {
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

  @override
  void initState() {
    super.initState();
    _initializeWindow();
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
      if (widget.samples.isNotEmpty) {
        final latestX = widget.samples.last.ts.millisecondsSinceEpoch.toDouble();
        _advanceWindowIfNeeded(latestX);
      }
    });
  }

  void _handleHorizontalDrag(double delta) {
    setState(() {
      _isManualMode = true;
      final windowWidth = _tEndMs - _tStartMs;
      final dragSensitivity = windowWidth / 300;

      // 計算新的視窗位置
      final newStartMs = _tStartMs - delta * dragSensitivity;
      final newEndMs = _tEndMs - delta * dragSensitivity;

      // 檢查邊界：如果有數據，限制在數據範圍內
      if (widget.samples.isNotEmpty) {
        final firstDataMs = widget.samples.first.ts.millisecondsSinceEpoch.toDouble();
        final lastDataMs = widget.samples.last.ts.millisecondsSinceEpoch.toDouble();

        // 不能滑到第一個數據點之前（右滑限制）
        if (newStartMs < firstDataMs) {
          _tStartMs = firstDataMs;
          _tEndMs = _tStartMs + windowWidth;
          return;
        }

        // 不能滑到最後一個數據點之後（左滑限制）
        if (newEndMs > lastDataMs + windowWidth) {
          _tEndMs = lastDataMs + windowWidth;
          _tStartMs = _tEndMs - windowWidth;
          return;
        }
      }

      // 在範圍內則允許移動
      _tStartMs = newStartMs;
      _tEndMs = newEndMs;
    });
  }

  /// 拖動結束後對齊到整分鐘
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
    return spots.where((p) => p.x >= _tStartMs && p.x < _tEndMs).toList();
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2,'0')}:'
          '${dt.minute.toString().padLeft(2,'0')}:'
          '${dt.second.toString().padLeft(2,'0')}';

  double _currentToGlucose(double current) {
    return widget.slope * current + widget.intercept;
  }

  double _glucoseToCurrent(double glucose) {
    if (widget.slope == 0) return 0;
    return (glucose - widget.intercept) / widget.slope;
  }

  @override
  Widget build(BuildContext context) {
    final samples = widget.samples;
    final hasData = samples.isNotEmpty;
    final latestSample = hasData ? samples.last : null;

    if (hasData && _firstDataTime == null) {
      _firstDataTime = samples.first.ts;
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
        ? _currentToGlucose(currentA*1E8).toStringAsFixed(1)
        : '--';

    final currentDisplay = currentA != null
        ? (currentA.abs() < 1e-6
        ? currentA.toStringAsExponential(3).toUpperCase()
        : currentA.toStringAsFixed(6))
        : '--';

    final currBasisSpots = () {
      if (!hasData) {
        return _buildPlaceholderSpots(widget.initialWindowSeconds, widget.placeholderCurrentA);
      }

      final rawSpots = _mapToSortedSpots(samples, (s) => _getCurrent(s));
      final fit = _buildSineFitFromSamples<Sample>(
        samples,
        pickY: (s) => _getCurrent(s),
        pickTs: (s) => s.ts,
        minPeriodSec: 5,
        maxPeriodSec: 60,
        minPoints: 3,
      );

      return fit ?? rawSpots;
    }();

    if (hasData) {
      final latestX = samples.last.ts.millisecondsSinceEpoch.toDouble();
      _advanceWindowIfNeeded(latestX);
    }

    var currWin = _applyWindowFixed(currBasisSpots);

    if (currWin.isEmpty) {
      currWin = _buildWindowAlignedPlaceholder(_tStartMs, _tEndMs, widget.placeholderCurrentA);
    }

    final currRange = _calcRange(
      currWin.map((e) => e.y),
      fixedMin: widget.fixedCurrentMin,
      fixedMax: widget.fixedCurrentMax,
      targetTicks: 20,
    );

    final glucoseFromCurrentWin = currWin
        .map((p) => FlSpot(p.x, _currentToGlucose(p.y)))
        .toList();

    final gluRange = _calcRange(
      glucoseFromCurrentWin.map((e) => e.y),
      fixedMin: widget.fixedGlucoseMin,
      fixedMax: widget.fixedGlucoseMax,
      targetTicks: 12,
    );

    final minX = _tStartMs;
    final maxX = _tEndMs;

    // Y軸刻度間隔
    final leftInterval = _niceInterval(gluRange.min, gluRange.max, 12);

    // 右軸間隔：減少刻度數量，讓電流值間距更大、更容易閱讀
    final rightInterval = _niceInterval(gluRange.min, gluRange.max, 6);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0, left: 1, right: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${voltage?.toStringAsFixed(3) ?? '--'} (V)'),
                  Text('電流：$currentDisplay A'),
                  Text('時間：$timestamp'),
                  Text('溫度：${temperature?.toStringAsFixed(2) ?? '--'} ℃'),
                ],
              ),
              const SizedBox(width: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    glucoseFromCurrent,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 48),
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
                  // 計算移動距離
                  final dragDistance = (event.position.dx - _dragStartX).abs();

                  // 如果移動超過10像素，認為是拖動手勢
                  if (dragDistance > 10) {
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
                    _alignWindowToMinute(); // 拖動結束後對齊
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
                    // 檢測是否為縮放手勢（兩指）
                    if (details.scale != 1.0 && details.pointerCount >= 2) {
                      if (!_isDragging) {
                        // 剛開始縮放，清除觸摸點資訊
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
                      _alignWindowToMinute(); // 手勢結束後對齊
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
                      clipData: FlClipData.all(),
                      lineBarsData: [
                        LineChartBarData(
                          spots: glucoseFromCurrentWin,
                          isCurved: true,
                          curveSmoothness: 0.35,
                          isStrokeCapRound: true,
                          barWidth: 2,
                          color: Colors.blue,
                          dotData: FlDotData(
                            show: true,
                            getDotPainter: (spot, percent, barData, index) {
                              return FlDotCirclePainter(
                                radius: 3,
                                color: Colors.blue,
                                strokeWidth: 1,
                                strokeColor: Colors.white,
                              );
                            },
                          ),
                          belowBarData: BarAreaData(show: false),
                        ),
                      ],
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        drawHorizontalLine: true,
                        horizontalInterval: rightInterval,
                        verticalInterval: oneMinuteMs,
                        getDrawingHorizontalLine: (value) {
                          return FlLine(
                            color: Colors.grey.withOpacity(0.3),
                            strokeWidth: 1,
                          );
                        },
                        getDrawingVerticalLine: (value) {
                          return FlLine(
                            color: Colors.grey.withOpacity(0.3),
                            strokeWidth: 1,
                          );
                        },
                      ),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 55,
                            interval: leftInterval,
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
                            interval: rightInterval,
                            getTitlesWidget: (glucoseValue, _) {
                              final current = _glucoseToCurrent(glucoseValue);
                              String text;
                              if (current.abs() < 1e-6) {
                                text = current.toStringAsExponential(2);
                              } else if (current.abs() < 0.001) {
                                text = current.toStringAsExponential(1);
                              } else if (current.abs() < 1) {
                                text = current.toStringAsFixed(4);
                              } else {
                                text = current.toStringAsFixed(2);
                              }
                              return Text(text, style: const TextStyle(fontSize: 8));
                            },
                          ),
                          axisNameWidget: const Padding(
                            padding: EdgeInsets.only(right: 8, bottom: 4),
                            child: Text('Current (A)'),
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
                        enabled: !_isDragging,
                        // 禁用內建 tooltip，使用自定義覆蓋層
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipColor: (touchedSpot) => Colors.transparent,
                          tooltipPadding: EdgeInsets.zero,
                          tooltipMargin: 0,
                          // ✅ 返回與 touchedSpots 相同數量的 null 項目
                          getTooltipItems: (touchedSpots) =>
                              touchedSpots.map((_) => null).toList(),
                        ),
                        getTouchedSpotIndicator: (barData, spotIndexes) {
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
                          // 只在點擊事件時更新（非拖動）
                          if (!_isDragging) {
                            setState(() {
                              if (response != null &&
                                  response.lineBarSpots != null &&
                                  response.lineBarSpots!.isNotEmpty) {
                                // 點擊到曲線上的點
                                final spot = response.lineBarSpots!.first;
                                _touchedY = spot.y;
                                _touchedX = spot.x;

                                // 生成並保存 tooltip 文字
                                final dt = DateTime.fromMillisecondsSinceEpoch(spot.x.toInt());
                                final timeStr = _formatTime(dt);
                                final glucose = spot.y;
                                final current = _glucoseToCurrent(glucose);

                                _tooltipText = '時間: $timeStr\n'
                                    '血糖: ${glucose.toStringAsFixed(2)} mg/dL\n'
                                    '電流: ${current.toStringAsExponential(2)} A';
                              } else if (event is FlTapUpEvent) {
                                // 點擊空白處：清除虛線和 tooltip
                                _touchedY = null;
                                _touchedX = null;
                                _tooltipText = null;
                              }
                            });
                          }
                        },
                        handleBuiltInTouches: true,
                      ),
                      extraLinesData: ExtraLinesData(
                        // Y軸水平虛線
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
                        // X軸垂直虛線（新增）
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
                  child: Text(
                    '${(windowMinutes * _zoomLevel).toStringAsFixed(0)} 分鐘',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
              // 自定義 tooltip 覆蓋層（持久顯示，不阻擋觸摸）
              if (_tooltipText != null && _touchedX != null && _touchedY != null)
                Positioned(
                  left: 16, // 固定在左上角，不會擋到圖表中的點
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

    return List<FlSpot>.generate(numPoints, (i) {
      final t = startMs + i * intervalMs;
      final w = 2 * math.pi / 12;
      final y = baselineCurrent + math.sin(i * w) * 0.01;
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
      minV = -1;
      maxV = 1;
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
          minV = -1e-10;
          maxV = 1e-10;
        } else {
          minV = center - absCenter * 0.5;
          maxV = center + absCenter * 0.5;
        }
      }

      final interval = _niceInterval(minV, maxV, targetTicks);

      if (interval > 0) {
        minV = (minV / interval).floor() * interval;
        maxV = (maxV / interval).ceil() * interval;
      }
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

  List<FlSpot>? _buildSineFitFromSamples<T>(
      List<T> samples, {
        required double Function(T) pickY,
        required DateTime Function(T) pickTs,
        double minPeriodSec = 5,
        double maxPeriodSec = 60,
        int omegaSteps = 60,
        int minPoints = 8,
      }) {
    if (samples.length < minPoints) return null;

    final t0 = pickTs(samples.first).millisecondsSinceEpoch / 1000.0;
    final ts = samples
        .map((s) => pickTs(s).millisecondsSinceEpoch / 1000.0 - t0)
        .toList();
    final ys = samples.map((s) => pickY(s)).toList();

    final meanY = ys.reduce((a, b) => a + b) / ys.length;
    final yCentered = ys.map((v) => v - meanY).toList();

    final minW = 2 * math.pi / maxPeriodSec;
    final maxW = 2 * math.pi / minPeriodSec;

    double bestW = minW;
    double bestPower = double.negativeInfinity;

    for (int k = 0; k < omegaSteps; k++) {
      final w = minW + (maxW - minW) * (k / (omegaSteps - 1));
      double Sy = 0, Cy = 0, S2 = 0, C2 = 0;

      for (int i = 0; i < ts.length; i++) {
        final s = math.sin(w * ts[i]);
        final c = math.cos(w * ts[i]);
        final y = yCentered[i];
        Sy += y * s;
        Cy += y * c;
        S2 += s * s;
        C2 += c * c;
      }

      final power = (Sy * Sy) / (S2 + 1e-12) + (Cy * Cy) / (C2 + 1e-12);
      if (power > bestPower) {
        bestPower = power;
        bestW = w;
      }
    }

    double Sy = 0, Cy = 0, S2 = 0, C2 = 0;
    for (int i = 0; i < ts.length; i++) {
      final s = math.sin(bestW * ts[i]);
      final c = math.cos(bestW * ts[i]);
      final y = yCentered[i];
      Sy += y * s;
      Cy += y * c;
      S2 += s * s;
      C2 += c * c;
    }

    if (S2 < 1e-9 && C2 < 1e-9) return null;

    final a = Sy / (S2 + 1e-12);
    final b = Cy / (C2 + 1e-12);
    final R = math.sqrt(a * a + b * b);
    final phi = math.atan2(b, a);

    final spots = <FlSpot>[];
    final tMin = ts.first;
    final tMax = ts.last;

    // 每18秒生成一個點，讓正弦波更平滑完整
    const intervalSec = 18.0;
    double t = tMin;

    while (t <= tMax) {
      final yFit = meanY + R * math.sin(bestW * t + phi);
      final msEpoch = ((t + t0) * 1000).toInt();
      spots.add(FlSpot(msEpoch.toDouble(), yFit));
      t += intervalSec;
    }

    if ((tMax - (t - intervalSec)).abs() > 1.0) {
      final yFit = meanY + R * math.sin(bestW * tMax + phi);
      final msEpoch = ((tMax + t0) * 1000).toInt();
      spots.add(FlSpot(msEpoch.toDouble(), yFit));
    }

    return spots;
  }
}

class _Range {
  final double min;
  final double max;
  const _Range(this.min, this.max);
  double get span => max - min;
}