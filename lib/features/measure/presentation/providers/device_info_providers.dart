import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ✅ StateProvider，用來存儲當前值
final targetDeviceNameProvider = StateProvider<String>((ref) => '');

final targetDeviceVersionProvider = StateProvider<String>((ref) => '');