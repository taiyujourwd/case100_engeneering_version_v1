class BleDeviceData {
  final String id; //device ID
  final String name; //設備名稱
  final int rssi; //接收信號強度
  final DateTime? timestamp; //時間戳記
  final double? voltage; //電壓
  final double? temperature; //溫度
  final List<double> currents; //電流
  final List<int> rawData; // 原始資料

  const BleDeviceData({
    required this.id,
    required this.name,
    required this.rssi,
    this.timestamp,
    this.voltage,
    this.temperature,
    required this.currents,
    required this.rawData,
  });

  BleDeviceData copyWith({
    String? id,
    String? name,
    int? rssi,
    DateTime? timestamp,
    double? voltage,
    double? temperature,
    List<double>? currents,
    List<int>? rawData,
  }) {
    return BleDeviceData(
      id: id ?? this.id,
      name: name ?? this.name,
      rssi: rssi ?? this.rssi,
      timestamp: timestamp ?? this.timestamp,
      voltage: voltage ?? this.voltage,
      temperature: temperature ?? this.temperature,
      currents: currents ?? this.currents,
      rawData: rawData ?? this.rawData,
    );
  }
}