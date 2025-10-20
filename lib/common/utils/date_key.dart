/// 日期工具函數
/// dayKey 格式：YYYY-MM-DD (例如：2025-10-20)

/// 將 DateTime 轉換為 dayKey（純日期字符串）
String dayKeyOf(DateTime dt) {
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// 將 dayKey 轉換為 DateTime（設定為當天的 00:00:00）
DateTime dayKeyToDate(String dayKey) {
  final parts = dayKey.split('-');
  if (parts.length != 3) {
    throw ArgumentError('Invalid dayKey format: $dayKey. Expected: YYYY-MM-DD');
  }

  try {
    final year = int.parse(parts[0]);
    final month = int.parse(parts[1]);
    final day = int.parse(parts[2]);

    return DateTime(year, month, day);
  } catch (e) {
    throw ArgumentError('Invalid dayKey format: $dayKey. Error: $e');
  }
}

/// 取得今天的 dayKey
String todayKey() => dayKeyOf(DateTime.now());

/// 取得昨天的 dayKey
String yesterdayKey() {
  final yesterday = DateTime.now().subtract(const Duration(days: 1));
  return dayKeyOf(yesterday);
}