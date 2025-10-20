import 'package:flutter/cupertino.dart';
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

  // ✅ 根據日期字符串獲取該天的時間範圍
  (DateTime start, DateTime end) _getDayRange(String dayKey) {
    final date = dayKeyToDate(dayKey);
    final start = DateTime(date.year, date.month, date.day, 0, 0, 0);
    final end = DateTime(date.year, date.month, date.day, 23, 59, 59, 999);
    return (start, end);
  }

// ✅ 查詢指定日期的數據（基於時間範圍）
  Future<List<Sample>> queryDay(String deviceId, String dayKey) async {
    debugPrint('═══════════════════════════════════════');
    debugPrint('🔍 [Isar] queryDay 被調用');
    debugPrint('   deviceId: "$deviceId"');
    debugPrint('   dayKey: "$dayKey"');

    final (start, end) = _getDayRange(dayKey);
    debugPrint('   時間範圍: $start ~ $end');

    // ✅ 使用 tsGreaterThan + tsLessThan 組合
    final samples = await _isar.samples
        .filter()
        .deviceIdEqualTo(deviceId)
        .tsGreaterThan(start.subtract(const Duration(milliseconds: 1)))
        .and()
        .tsLessThan(end.add(const Duration(milliseconds: 1)))
        .sortByTs()
        .findAll();

    debugPrint('   查詢結果: ${samples.length} 筆');

    if (samples.isNotEmpty) {
      debugPrint('   第一筆: ${samples.first.ts}');
      debugPrint('   最後一筆: ${samples.last.ts}');
    }

    debugPrint('═══════════════════════════════════════');
    return samples;
  }

// ✅ 監聽指定日期的數據流（基於時間範圍）
  Stream<List<Sample>> watchDay(String deviceId, String dayKey) {
    debugPrint('═══════════════════════════════════════');
    debugPrint('📡 [Isar] watchDay 被調用');
    debugPrint('   deviceId: "$deviceId"');
    debugPrint('   dayKey: "$dayKey"');

    final (start, end) = _getDayRange(dayKey);
    debugPrint('   時間範圍: $start ~ $end');
    debugPrint('═══════════════════════════════════════');

    // ✅ 使用 tsGreaterThan + tsLessThan 組合
    return _isar.samples
        .filter()
        .deviceIdEqualTo(deviceId)
        .tsGreaterThan(start.subtract(const Duration(milliseconds: 1)))
        .and()
        .tsLessThan(end.add(const Duration(milliseconds: 1)))
        .sortByTs()
        .watch(fireImmediately: true);
  }

  // ✅ 查詢前一天有數據的日期
  Future<String?> prevDayWithData(String deviceId, String dayKey) async {
    debugPrint('🔍 [Isar] 查找前一天: deviceId=$deviceId, dayKey=$dayKey');

    final currentDate = dayKeyToDate(dayKey);
    final dayStart = DateTime(currentDate.year, currentDate.month, currentDate.day, 0, 0, 0);

    // ✅ 設定最小有效時間（2020-01-01）
    final minValidDate = DateTime(2020, 1, 1);

    // ✅ 查找這一天開始之前的最新數據，並過濾無效時間戳
    final sample = await _isar.samples
        .filter()
        .deviceIdEqualTo(deviceId)
        .tsLessThan(dayStart)
        .and()
        .tsGreaterThan(minValidDate)  // ✅ 過濾掉 1970 年的數據
        .sortByTsDesc()
        .findFirst();

    if (sample == null) {
      debugPrint('🔍 [Isar] 前一天: 無');
      return null;
    }

    // ✅ 再次驗證時間戳的有效性
    if (sample.ts.year < 2020) {
      debugPrint('⚠️ [Isar] 前一天時間戳無效: ${sample.ts}');
      return null;
    }

    final prevDay = dayKeyOf(sample.ts);
    debugPrint('🔍 [Isar] 前一天: $prevDay (timestamp: ${sample.ts})');
    return prevDay;
  }

  // ✅ 查詢後一天有數據的日期
  Future<String?> nextDayWithData(String deviceId, String dayKey) async {
    debugPrint('🔍 [Isar] 查找後一天: deviceId=$deviceId, dayKey=$dayKey');

    final currentDate = dayKeyToDate(dayKey);
    final nextDayStart = DateTime(
      currentDate.year,
      currentDate.month,
      currentDate.day + 1,
      0,
      0,
      0,
    );

    // ✅ 設定最小有效時間
    final minValidDate = DateTime(2020, 1, 1);
    // ✅ 設定最大有效時間（未來 1 年）
    final maxValidDate = DateTime.now().add(const Duration(days: 365));

    // ✅ 查找這一天之後的最早數據，並過濾無效時間戳
    final sample = await _isar.samples
        .filter()
        .deviceIdEqualTo(deviceId)
        .tsGreaterThan(nextDayStart.subtract(const Duration(milliseconds: 1)))
        .and()
        .tsGreaterThan(minValidDate)  // ✅ 最小時間
        .and()
        .tsLessThan(maxValidDate)     // ✅ 最大時間
        .sortByTs()
        .findFirst();

    if (sample == null) {
      debugPrint('🔍 [Isar] 後一天: 無');
      return null;
    }

    // ✅ 再次驗證時間戳的有效性
    if (sample.ts.year < 2020 || sample.ts.year > DateTime.now().year + 1) {
      debugPrint('⚠️ [Isar] 後一天時間戳無效: ${sample.ts}');
      return null;
    }

    final nextDay = dayKeyOf(sample.ts);
    debugPrint('🔍 [Isar] 後一天: $nextDay (timestamp: ${sample.ts})');
    return nextDay;
  }

  // ✅ 查詢所有有數據的日期（基於時間戳分組）
  Future<List<String>> getAllDaysWithData(String deviceId) async {
    debugPrint('🔍 [Isar] 查詢所有日期: deviceId=$deviceId');

    // ✅ 設定有效時間範圍
    final minValidDate = DateTime(2020, 1, 1);
    final maxValidDate = DateTime.now().add(const Duration(days: 365));

    final samples = await _isar.samples
        .filter()
        .deviceIdEqualTo(deviceId)
        .tsGreaterThan(minValidDate)  // ✅ 過濾無效時間戳
        .and()
        .tsLessThan(maxValidDate)
        .sortByTsDesc()
        .findAll();

    // 使用 Set 去重，從 timestamp 生成 dayKey
    final days = <String>{};
    for (final sample in samples) {
      // ✅ 額外驗證
      if (sample.ts.year >= 2020 && sample.ts.year <= DateTime.now().year + 1) {
        final dayKey = dayKeyOf(sample.ts);
        days.add(dayKey);
      }
    }

    // 轉為 List 並排序（降序）
    final daysList = days.toList()..sort((a, b) => b.compareTo(a));

    debugPrint('🔍 [Isar] 找到 ${daysList.length} 個有效日期');
    if (daysList.length <= 10) {
      debugPrint('🔍 [Isar] 日期列表: $daysList');
    } else {
      debugPrint('🔍 [Isar] 最近 10 個日期: ${daysList.take(10).toList()}');
    }

    return daysList;
  }

  // 獲取所有不重複的日期（從 timestamp 生成）
  Future<List<String>> getAllDayKeys() async {
    final minValidDate = DateTime(2020, 1, 1);
    final maxValidDate = DateTime.now().add(const Duration(days: 365));

    final samples = await _isar.samples
        .filter()
        .tsGreaterThan(minValidDate)
        .and()
        .tsLessThan(maxValidDate)
        .findAll();

    // 從 timestamp 生成日期
    final dayKeys = samples
        .where((s) => s.ts.year >= 2020 && s.ts.year <= DateTime.now().year + 1)
        .map((s) => dayKeyOf(s.ts))
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));

    debugPrint('🔍 [Isar] getAllDayKeys: ${dayKeys.length} 個有效日期');
    return dayKeys;
  }

  // ✅ 新增：清理無效時間戳的數據
  Future<int> cleanInvalidTimestamps() async {
    debugPrint('🧹 [Isar] 開始清理無效時間戳數據...');

    final minValidDate = DateTime(2020, 1, 1);
    final maxValidDate = DateTime.now().add(const Duration(days: 365));

    int deletedCount = 0;

    await _isar.writeTxn(() async {
      // 找出所有無效的數據
      final invalidSamples = await _isar.samples
          .filter()
          .tsLessThan(minValidDate)
          .or()
          .tsGreaterThan(maxValidDate)
          .findAll();

      if (invalidSamples.isNotEmpty) {
        debugPrint('🧹 [Isar] 找到 ${invalidSamples.length} 筆無效數據');

        for (final sample in invalidSamples) {
          debugPrint('   刪除: deviceId=${sample.deviceId}, ts=${sample.ts}');
        }

        final ids = invalidSamples.map((s) => s.id).toList();
        deletedCount = await _isar.samples.deleteAll(ids);

        debugPrint('✅ [Isar] 已刪除 $deletedCount 筆無效數據');
      } else {
        debugPrint('✅ [Isar] 沒有無效數據需要清理');
      }
    });

    return deletedCount;
  }

  // ========== 調試方法 ==========

  // 獲取所有不重複的設備 ID
  Future<List<String>> getAllDeviceIds() async {
    final samples = await _isar.samples.where().findAll();
    final deviceIds = samples.map((s) => s.deviceId).toSet().toList()..sort();
    debugPrint('🔍 [Isar] getAllDeviceIds: ${deviceIds.length} 個設備');
    return deviceIds;
  }

  // 獲取指定設備的所有數據（不限日期）
  Future<List<Sample>> getAllSamplesByDevice(String deviceId) async {
    return await _isar.samples
        .filter()
        .deviceIdEqualTo(deviceId)
        .sortByTs()
        .findAll();
  }

  // 獲取指定日期的所有數據（基於時間範圍）
  Future<List<Sample>> getAllSamplesByDay(String dayKey) async {
    final (start, end) = _getDayRange(dayKey);

    // ✅ 使用 tsGreaterThan + tsLessThan
    return await _isar.samples
        .filter()
        .tsGreaterThan(start.subtract(const Duration(milliseconds: 1)))
        .and()
        .tsLessThan(end.add(const Duration(milliseconds: 1)))
        .sortByTs()
        .findAll();
  }

// ✅ 獲取指定日期的數據筆數（基於時間範圍）
  Future<int> getCountByDay(String dayKey) async {
    final (start, end) = _getDayRange(dayKey);

    // ✅ 使用 tsGreaterThan + tsLessThan
    return await _isar.samples
        .filter()
        .tsGreaterThan(start.subtract(const Duration(milliseconds: 1)))
        .and()
        .tsLessThan(end.add(const Duration(milliseconds: 1)))
        .count();
  }

  // 獲取總數據筆數
  Future<int> getTotalCount() async {
    return await _isar.samples.count();
  }

  // 獲取指定設備的數據筆數
  Future<int> getCountByDevice(String deviceId) async {
    return await _isar.samples
        .filter()
        .deviceIdEqualTo(deviceId)
        .count();
  }

  // 獲取資料庫統計信息
  Future<Map<String, dynamic>> getDatabaseStats() async {
    final totalCount = await getTotalCount();
    final deviceIds = await getAllDeviceIds();
    final dayKeys = await getAllDayKeys();

    return {
      'totalCount': totalCount,
      'deviceCount': deviceIds.length,
      'dayCount': dayKeys.length,
      'deviceIds': deviceIds,
      'dayKeys': dayKeys,
    };
  }

  // 獲取資料庫的詳細診斷信息
  Future<String> getDiagnosticInfo() async {
    final stats = await getDatabaseStats();
    final buffer = StringBuffer();

    buffer.writeln('═══ Isar 資料庫診斷 ═══');
    buffer.writeln('總數據筆數: ${stats['totalCount']}');
    buffer.writeln('設備數量: ${stats['deviceCount']}');
    buffer.writeln('日期數量: ${stats['dayCount']}');
    buffer.writeln('');

    if (stats['deviceIds'].isNotEmpty) {
      buffer.writeln('設備列表:');
      for (final id in stats['deviceIds']) {
        final count = await getCountByDevice(id);
        buffer.writeln('  - "$id": $count 筆');
      }
    }

    buffer.writeln('');
    if (stats['dayKeys'].isNotEmpty) {
      buffer.writeln('最近 10 個日期:');
      final dayKeys = stats['dayKeys'] as List<String>;
      for (final key in dayKeys.take(10)) {
        final count = await getCountByDay(key);
        buffer.writeln('  - "$key": $count 筆');
      }
      if (dayKeys.length > 10) {
        buffer.writeln('  ... 還有 ${dayKeys.length - 10} 個日期');
      }
    }

    buffer.writeln('═══════════════════════');
    return buffer.toString();
  }

  // ========== 原有的其他方法 ==========

  Future<(int lastSeq, String? lastDayKey)> getLastSeq(String deviceId) async {
    final s = await _isar.samples
        .filter()
        .deviceIdEqualTo(deviceId)
        .sortBySeqDesc()
        .findFirst();
    return (s?.seq ?? 0, s?.dayKey);
  }

  Future<void> addSample(Sample sample) async {
    await _isar.writeTxn(() async {
      await _isar.samples.put(sample);

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

  Future<void> requestCatchup(String deviceId) async {
    final (lastSeq, _) = await getLastSeq(deviceId);
    await ble.requestCatchup(lastSeq);
  }

  void dispose() {
    _isar.close();
  }
}

// 從 BleDeviceData 建立 Sample
Sample makeSampleFromBle({
  required String deviceId,
  required DateTime timestamp,
  required List<double> currents,
  double? voltage,
  double? temperature,
}) {
  return Sample()
    ..deviceId = deviceId
    ..seq = timestamp.millisecondsSinceEpoch
    ..voltage = voltage
    ..current = currents.isNotEmpty ? currents.first : null
    ..currents = currents
    ..temperature = temperature
    ..ts = timestamp
    ..dayKey = dayKeyOf(timestamp);  // 使用正確格式
}