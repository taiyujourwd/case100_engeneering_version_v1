import 'package:isar/isar.dart';

part 'isar_schemas.g.dart';

@collection
class Sample {
  Id id = Isar.autoIncrement;

  late String deviceId;
  late int seq;
  late DateTime ts;
  late String dayKey;
  double? voltage;
  double? current;      // 主電流值
  double? glucose;      // 血糖值
  double? temperature;  // 新增溫度欄位
  List<double>? currents; // 儲存多個電流值的陣列

  Sample();

  // ✅ 便利建構子（不影響 Isar 的零參數建構子）
  Sample.create({
    Id? id,
    required String deviceId,
    required int seq,
    required DateTime ts,
    required String dayKey,
    double? voltage,
    double? current,
    double? glucose,
    double? temperature,
    List<double>? currents,
  }) {
    if (id != null) this.id = id;
    this.deviceId = deviceId;
    this.seq = seq;
    this.ts = ts;
    this.dayKey = dayKey;
    this.voltage = voltage;
    this.current = current;
    this.glucose = glucose;
    this.temperature = temperature;
    this.currents = currents;
  }

  Sample copyWith({
    Id? id,
    String? deviceId,
    int? seq,
    DateTime? ts,
    String? dayKey,
    double? voltage,
    double? current,
    double? glucose,
    double? temperature,
    List<double>? currents,
  }) {
    return Sample()
      ..id = id ?? this.id
      ..deviceId = deviceId ?? this.deviceId
      ..seq = seq ?? this.seq
      ..ts = ts ?? this.ts
      ..dayKey = dayKey ?? this.dayKey
      ..voltage = voltage ?? this.voltage
      ..current = current ?? this.current
      ..glucose = glucose ?? this.glucose
      ..temperature = temperature ?? this.temperature
      ..currents = currents ?? this.currents;
  }

  @override
  String toString() {
    return 'Sample('
        'id=$id, '
        'deviceId=$deviceId, '
        'seq=$seq, '
        'ts=$ts, '
        'dayKey=$dayKey, '
        'voltage=$voltage, '
        'current=$current, '
        'glucose=$glucose, '
        'temperature=$temperature, '
        'currents=$currents'
        ')';
  }
}

@collection
class DayIndex {
  Id id = Isar.autoIncrement;

  late String deviceId;
  late String dayKey;
  late int count;

  @Index(composite: [CompositeIndex('dayKey')])
  String get deviceDayKey => '$deviceId-$dayKey';
}