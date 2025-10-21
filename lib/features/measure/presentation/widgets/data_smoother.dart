import 'dart:math';

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
    if (order < 1 || order > maxBufferSize) {
      throw ArgumentError('order 必須在 1 到 $maxBufferSize 之間');
    }

    if (order == 1) {
      return _dataBuffer.isEmpty ? null : _dataBuffer.last;
    }

    if (_dataBuffer.isEmpty) {
      return null;
    }

    final n = min(order, _dataBuffer.length);
    final lastNData = _dataBuffer.sublist(_dataBuffer.length - n);
    final sum = lastNData.reduce((acc, val) => acc + val);
    return sum / n;
  }

  double? smooth2(int order, double errorPercent) {
    if (order < 1 || order > maxBufferSize) {
      throw ArgumentError('order 必須在 1 到 $maxBufferSize 之間');
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
    final errorRate = ((lastValue - prevValue).abs() / prevValue.abs()) * 100;

    if (errorRate > errorPercent) {
      final n = min(order, _dataBuffer.length);
      final lastNData = _dataBuffer.sublist(_dataBuffer.length - n);
      final sum = lastNData.reduce((acc, val) => acc + val);
      return sum / n;
    }

    return lastValue;
  }

  List<double> getBuffer() => List.from(_dataBuffer);
  int get bufferLength => _dataBuffer.length;
  bool get isEmpty => _dataBuffer.isEmpty;
}