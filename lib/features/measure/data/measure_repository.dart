import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import '../ble/ble_adapter.dart';
import 'isar_schemas.dart';
import '../../../common/utils/date_key.dart';

class MeasureRepository {
  final BleClient ble;
  late final Isar _isar;

  MeasureRepository(this.ble);

  static Future<MeasureRepository> create(BleClient ble) async {
    final repo = MeasureRepository(ble);
    final dir = await getApplicationSupportDirectory();
    repo._isar = await Isar.open([SampleSchema, DayIndexSchema], directory: dir.path);
    return repo;
  }

  Stream<List<Sample>> watchDay(String deviceId, String dayKey) {
    return _isar.samples
        .filter()
        .deviceIdEqualTo(deviceId)
        .and()
        .dayKeyEqualTo(dayKey)
        .sortByTs()
        .watch(fireImmediately: true);
  }

  Future<(int lastSeq, String? lastDayKey)> getLastSeq(String deviceId) async {
    final s = await _isar.samples
        .filter()
        .deviceIdEqualTo(deviceId)
        .sortBySeqDesc()
        .findFirst();
    return (s?.seq ?? 0, s?.dayKey);
  }

  Future<void> appendSamples(String deviceId, Iterable<Sample> samples) async {
    await _isar.writeTxn(() async {
      await _isar.samples.putAll(samples.toList());
      final byDay = <String, int>{};
      for (final s in samples) {
        byDay[s.dayKey] = (byDay[s.dayKey] ?? 0) + 1;
      }
      for (final e in byDay.entries) {
        final idx = await _isar.dayIndexs
            .filter()
            .deviceIdEqualTo(deviceId)
            .and()
            .dayKeyEqualTo(e.key)
            .findFirst();
        if (idx == null) {
          await _isar.dayIndexs.put(DayIndex()
            ..deviceId = deviceId
            ..dayKey = e.key
            ..count = e.value);
        } else {
          idx.count += e.value;
          await _isar.dayIndexs.put(idx);
        }
      }
    });
  }

  Future<String?> prevDayWithData(String deviceId, String dayKey) async {
    final all = await _isar.dayIndexs
        .filter()
        .deviceIdEqualTo(deviceId)
        .sortByDayKey()
        .findAll();
    final idx = all.indexWhere((e) => e.dayKey == dayKey);
    if (idx > 0) return all[idx - 1].dayKey;
    return null;
  }

  Future<String?> nextDayWithData(String deviceId, String dayKey) async {
    final all = await _isar.dayIndexs
        .filter()
        .deviceIdEqualTo(deviceId)
        .sortByDayKey()
        .findAll();
    final idx = all.indexWhere((e) => e.dayKey == dayKey);
    if (idx >= 0 && idx < all.length - 1) return all[idx + 1].dayKey;
    return null;
  }

  Future<void> requestCatchup(String deviceId) async {
    final (lastSeq, _) = await getLastSeq(deviceId);
    await ble.requestCatchup(lastSeq);
  }
}

Sample makeSample({
  required String deviceId,
  required int seq,
  double? v,
  double? i,
  double? glu,
  required DateTime ts,
}) {
  return Sample()
    ..deviceId = deviceId
    ..seq = seq
    ..voltage = v
    ..current = i
    ..glucose = glu
    ..ts = ts
    ..dayKey = dayKeyOf(ts);
}
