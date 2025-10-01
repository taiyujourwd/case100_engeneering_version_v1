import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import 'widgets/glucose_chart.dart';

class MeasureDetailScreen extends ConsumerWidget {
  final String deviceId;
  final String dayKey;
  const MeasureDetailScreen({super.key, required this.deviceId, required this.dayKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repoAsync = ref.watch(repoProvider);
    return Scaffold(
      appBar: AppBar(title: Text('資料：$dayKey')),
      body: repoAsync.when(
        data: (repo) {
          return StreamBuilder(
            stream: repo.watchDay(deviceId, dayKey),
            builder: (context, snap) {
              final list = snap.data ?? const [];
              return InteractiveViewer(child: GlucoseChart(samples: list));
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('讀取失敗：$e')),
      ),
    );
  }
}
