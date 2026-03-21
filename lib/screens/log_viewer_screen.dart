import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../services/app_logger.dart';

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  List<String> _logs = [];
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  void _loadLogs() {
    setState(() {
      _logs = AppLogger.getRecentLogs().reversed.toList(); // newest first
    });
  }

  List<String> get _filteredLogs {
    if (_filter.isEmpty) return _logs;
    final q = _filter.toLowerCase();
    return _logs.where((l) => l.toLowerCase().contains(q)).toList();
  }

  Future<void> _copyAll() async {
    final logs = _filteredLogs;
    final text = logs.join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      final label = _filter.isEmpty ? 'All' : _filter;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${logs.length} logs copied ($label)')),
      );
    }
  }

  Future<void> _shareLogs() async {
    try {
      final logs = _filteredLogs;
      if (logs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No logs to share')),
          );
        }
        return;
      }

      // Write filtered logs to a temp file for sharing
      final dir = await getTemporaryDirectory();
      final now = DateTime.now();
      final fileName = 'dhan_logs_${now.year}${now.month.toString().padLeft(2, "0")}${now.day.toString().padLeft(2, "0")}_${now.hour.toString().padLeft(2, "0")}${now.minute.toString().padLeft(2, "0")}.txt';
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(logs.join('\n'));

      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'Dhan Strategy Logs - ${now.year}-${now.month.toString().padLeft(2, "0")}-${now.day.toString().padLeft(2, "0")}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _clearLogs() async {
    await AppLogger.clear();
    _loadLogs();
  }

  Color _levelColor(String line) {
    if (line.contains('[ERROR]')) return Colors.red;
    if (line.contains('[WARN]')) return Colors.orange;
    if (line.contains('[STRAT]')) return Colors.blue;
    if (line.contains('[TRADE]')) return Colors.green;
    return Colors.grey.shade400;
  }

  @override
  Widget build(BuildContext context) {
    final logs = _filteredLogs;

    return Scaffold(
      appBar: AppBar(
        title: Text('Logs (${logs.length})'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share logs',
            onPressed: _shareLogs,
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy filtered logs',
            onPressed: _copyAll,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: _clearLogs,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadLogs,
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter bar
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Filter logs... (e.g. ERROR, Strategy, Trade)',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),

          // Quick filter chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                _filterChip('All', ''),
                _filterChip('Errors', 'ERROR'),
                _filterChip('Strategy', 'STRAT'),
                _filterChip('Trade', 'TRADE'),
                _filterChip('Warn', 'WARN'),
              ],
            ),
          ),
          const SizedBox(height: 4),

          // Log list
          Expanded(
            child: logs.isEmpty
                ? const Center(
                    child: Text('No logs', style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: logs.length,
                    itemBuilder: (_, i) {
                      final line = logs[i];
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: _levelColor(line),
                              width: 3,
                            ),
                          ),
                        ),
                        child: Text(
                          line,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: line.contains('[ERROR]')
                                ? Colors.red.shade300
                                : null,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String value) {
    final isActive = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: isActive,
        onSelected: (_) => setState(() => _filter = value),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
