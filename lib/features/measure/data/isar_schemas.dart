import 'package:isar/isar.dart';

part 'isar_schemas.g.dart';

@collection
class Sample {
  Id id = Isar.autoIncrement;
  late DateTime ts;
  double? voltage;
  double? current;
  double? glucose;
  int seq = 0;
  late String deviceId;
  late String dayKey; // yyyyMMdd
}

@collection
class DayIndex {
  Id id = Isar.autoIncrement;
  late String dayKey;
  late String deviceId;
  int count = 0;
}
