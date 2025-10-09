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

  List<double>? currents; // 新增：儲存多個電流值的陣列

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