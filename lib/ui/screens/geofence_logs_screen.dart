import 'package:flutter/material.dart';

import '../../main.dart';
import '../../services/geofence_provider.dart';

/// 围栏日志查看器（对齐 CU geofence_logs_viewer.dart）
class GeofenceLogsScreen extends StatefulWidget {
  const GeofenceLogsScreen({super.key});

  @override
  State<GeofenceLogsScreen> createState() => _GeofenceLogsScreenState();
}

class _GeofenceLogsScreenState extends State<GeofenceLogsScreen> {
  final ScrollController _scrollController = ScrollController();
  late final GeofenceProvider _geo;

  @override
  void initState() {
    super.initState();
    _geo = AppScope.instance.controller.geofence;
    _geo.addListener(_onChange);
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _geo.removeListener(_onChange);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logs = _geo.logs;
    return Scaffold(
      appBar: AppBar(
        title: const Text('围栏日志'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: '清空日志',
            onPressed: () => _geo.clearLogs(),
          ),
        ],
      ),
      body: logs.isEmpty
          ? const Center(child: Text('暂无日志'))
          : ListView.builder(
              controller: _scrollController,
              itemCount: logs.length,
              itemBuilder: (context, index) {
                final line = logs[index];
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: Theme.of(context).dividerColor,
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: SelectableText(
                    line,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                );
              },
            ),
    );
  }
}
