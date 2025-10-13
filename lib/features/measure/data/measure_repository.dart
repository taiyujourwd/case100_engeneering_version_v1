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
    repo._isar = await Isar.open(
      [SampleSchema, DayIndexSchema],
      directory: dir.path,
      inspector: true,
    );
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

  // 新增：單一樣本寫入方法（用於 BLE 即時數據）
  Future<void> addSample(Sample sample) async {
    await _isar.writeTxn(() async {
      await _isar.samples.put(sample);

      // 更新 DayIndex
      final idx = await _isar.dayIndexs
          .filter()
          .deviceIdEqualTo(sample.deviceId)
          .and()
          .dayKeyEqualTo(sample.dayKey)
          .findFirst();

      if (idx == null) {
        await _isar.dayIndexs.put(DayIndex()
          ..deviceId = sample.deviceId
          ..dayKey = sample.dayKey
          ..count = 1);
      } else {
        idx.count += 1;
        await _isar.dayIndexs.put(idx);
      }
    });
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

// 新增：從 BleDeviceData 建立 Sample（用於 BLE 即時數據）
Sample makeSampleFromBle({
  required String deviceId,
  required DateTime timestamp,
  required List<double> currents,
  double? voltage,
  double? temperature,
}) {
  return Sample()
    ..deviceId = deviceId
    ..seq = timestamp.millisecondsSinceEpoch // 使用時間戳記作為序號
    ..voltage = voltage
    ..current = currents.isNotEmpty ? currents.first : null // 使用第一個電流值
    ..currents = currents // 儲存所有電流值
    ..temperature = temperature
    ..ts = timestamp
    ..dayKey = dayKeyOf(timestamp);
}