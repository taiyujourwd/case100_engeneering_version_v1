class BleDeviceData {
  final String id;
  final String name;
  final int rssi;
  final DateTime? timestamp;
  final double? voltage;
  final double? temperature;
  final List<double> currents;
  final List<int> rawData;

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