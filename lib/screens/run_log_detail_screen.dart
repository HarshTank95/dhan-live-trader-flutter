import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/run_logger.dart';

/// Displays the full JSONL event stream for a single strategy run, with
/// tag/level filters and a search box. Used by the Log Viewer "Runs" tab and
/// from the run history detail sheet ("View full logs").
class RunLogDetailScreen extends StatefulWidget {
  final String runId;

  const RunLogDetailScreen({super.key, required this.runId});

  @override
  State<RunLogDetailScreen> createState() => _RunLogDetailScreenState();
}

class _RunLogDetailScreenState extends State<RunLogDetailScreen> {
  List<RunLogEvent> _events = [];
  RunLogIndex? _meta;
  bool _loading = true;

  String _search = '';
  String _tagFilter = ''; // '' = all
  String _levelFilter = ''; // '', 'warn', 'error'
  final TextEditingController _searchController = TextEditingController();

  /// Tag chips are derived from the loaded events, frequency-sorted, so any
  /// new strategy that introduces its own tag namespace (e.g. 'MeanReversion',
  /// 'GapFade') automatically gets first-class filter chips without editing
  /// this screen. Returns `[(tag, count), ...]` sorted by count desc.
  List<MapEntry<String, int>> get _tagPresets {
    final counts = <String, int>{};
    for (final e in _events) {
      if (e.tag.isEmpty) continue;
      counts[e.tag] = (counts[e.tag] ?? 0) + 1;
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted;
  }

  /// Total events at info/warn/error level — used to label level chips so
  /// the user knows in advance how many lines a click will produce.
  Map<String, int> get _levelCounts {
    int info = 0, warn = 0, err = 0;
    for (final e in _events) {
      if (e.level == 'error') {
        err++;
      } else if (e.level == 'warn') {
        warn++;
      } else {
        info++;
      }
    }
    return {'info': info, 'warn': warn, 'error': err};
  }

  bool get _hasActiveFilter =>
      _tagFilter.isNotEmpty || _levelFilter.isNotEmpty || _search.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final events = await RunLogger.readRun(widget.runId);
    final all = await RunLogger.listRuns();
    final matching = all.where((r) => r.runId == widget.runId);
    final meta = matching.isEmpty ? null : matching.first;
    if (!mounted) return;
    setState(() {
      _events = events;
      _meta = meta;
      _loading = false;
    });
  }

  List<RunLogEvent> get _filtered {
    final q = _search.toLowerCase();
    return _events.where((e) {
      if (_tagFilter.isNotEmpty && e.tag != _tagFilter) return false;
      if (_levelFilter == 'warn' && e.level == 'info') return false;
      if (_levelFilter == 'error' && e.level != 'error') return false;
      if (q.isNotEmpty) {
        if (!e.message.toLowerCase().contains(q) &&
            !e.tag.toLowerCase().contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  Future<void> _share() async {
    final path = await RunLogger.runFilePath(widget.runId);
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Log file not found')),
        );
      }
      return;
    }
    await Share.shareXFiles(
      [XFile(path)],
      subject: 'Dhan run log - ${widget.runId}',
    );
  }

  Future<void> _copyVisible() async {
    final lines = _filtered.map(_formatLine).toList();
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${lines.length} lines copied')),
      );
    }
  }

  String _formatLine(RunLogEvent e) {
    final t = e.timestamp;
    final ts =
        '${t.hour.toString().padLeft(2, "0")}:${t.minute.toString().padLeft(2, "0")}:${t.second.toString().padLeft(2, "0")}';
    final data = e.data != null && e.data!.isNotEmpty ? ' ${e.data}' : '';
    return '$ts [${e.level.toUpperCase()}] ${e.tag}: ${e.message}$data';
  }

  Color _levelColor(RunLogEvent e) {
    if (e.level == 'error') return Colors.red;
    if (e.level == 'warn') return Colors.orange;
    if (e.tag == 'Scan') return Colors.purple;
    if (e.tag == 'Fetch') return Colors.cyan;
    if (e.tag == 'PreMarket') return Colors.indigo;
    if (e.tag == 'Diagnosis') return Colors.deepOrange;
    if (e.tag == 'Reject') return Colors.amber.shade700;
    if (e.message.contains('DOMINANCE') || e.message.contains('TRADE')) {
      return Colors.green;
    }
    return Colors.grey.shade400;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.runId, style: const TextStyle(fontSize: 14)),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.share, size: 20),
            tooltip: 'Share file',
            onPressed: _share,
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 20),
            tooltip: 'Copy visible',
            onPressed: _copyVisible,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_meta != null) _metaHeader(_meta!),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search (e.g. TCS, R5, REJECT)…',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                ),
                _filterRow(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  child: Row(
                    children: [
                      Text('${visible.length} / ${_events.length} events',
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 11)),
                      const Spacer(),
                      if (_hasActiveFilter)
                        TextButton.icon(
                          onPressed: () => setState(() {
                            _tagFilter = '';
                            _levelFilter = '';
                            _search = '';
                            _searchController.clear();
                          }),
                          icon: const Icon(Icons.filter_alt_off, size: 14),
                          label: const Text('Clear filters',
                              style: TextStyle(fontSize: 11)),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: const Size(0, 28),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: visible.isEmpty
                      ? const Center(
                          child: Text('No matching events',
                              style: TextStyle(color: Colors.grey)),
                        )
                      : ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (_, i) => _eventTile(visible[i]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _metaHeader(RunLogIndex m) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(m.configName,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              _MetaKindChip(meta: m),
              const Spacer(),
              Text(m.status,
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${m.date} • ${m.startTime}${m.endTime.isNotEmpty ? " → ${m.endTime}" : ""} • '
            'stocks ${m.totalStocks} • signals ${m.signals} • trades ${m.trades} • '
            'P&L Rs ${m.totalPnl.toStringAsFixed(0)}',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _filterRow() {
    final tags = _tagPresets;
    final lvl = _levelCounts;
    final allCount = _events.length;
    final warnPlusCount = lvl['warn']! + lvl['error']!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _filterRowLabelled(
          label: 'Tag',
          chips: [
            _tagChip('All', '', allCount),
            for (final entry in tags) _tagChip(entry.key, entry.key, entry.value),
          ],
        ),
        _filterRowLabelled(
          label: 'Level',
          chips: [
            _levelChip('Info+', '', allCount),
            _levelChip('Warn+', 'warn', warnPlusCount),
            _levelChip('Error', 'error', lvl['error']!),
          ],
        ),
      ],
    );
  }

  Widget _filterRowLabelled({required String label, required List<Widget> chips}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: Row(
        children: [
          SizedBox(
            width: 38,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: chips),
            ),
          ),
        ],
      ),
    );
  }

  /// A filter chip is only visibly "selected" when it represents a
  /// non-default choice. The default "All" / "Info+" chips behave as the
  /// neutral baseline so the filter row never *looks* like two filters are
  /// stuck on when nothing is actually being filtered.
  Widget _tagChip(String label, String value, int count) {
    final isDefault = value.isEmpty;
    final active = _tagFilter == value;
    final showSelected = active && !isDefault;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text('$label ($count)', style: const TextStyle(fontSize: 11)),
        selected: showSelected,
        onSelected: (_) => setState(() => _tagFilter = active ? '' : value),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _levelChip(String label, String value, int count) {
    final isDefault = value.isEmpty;
    final active = _levelFilter == value;
    final showSelected = active && !isDefault;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text('$label ($count)', style: const TextStyle(fontSize: 11)),
        selected: showSelected,
        onSelected: (_) => setState(() => _levelFilter = active ? '' : value),
        visualDensity: VisualDensity.compact,
        selectedColor: value == 'error'
            ? Colors.red.shade100
            : value == 'warn'
                ? Colors.orange.shade100
                : null,
      ),
    );
  }

  Widget _eventTile(RunLogEvent e) {
    final color = _levelColor(e);
    final hasData = e.data != null && e.data!.isNotEmpty;
    final t = e.timestamp;
    final ts =
        '${t.hour.toString().padLeft(2, "0")}:${t.minute.toString().padLeft(2, "0")}:${t.second.toString().padLeft(2, "0")}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$ts [${e.tag}] ${e.message}',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: e.level == 'error'
                  ? Colors.red.shade300
                  : e.level == 'warn'
                      ? Colors.orange.shade400
                      : null,
            ),
          ),
          if (hasData)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 1),
              child: Text(
                e.data.toString(),
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  color: Colors.grey.shade500,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MetaKindChip extends StatelessWidget {
  final RunLogIndex meta;
  const _MetaKindChip({required this.meta});

  @override
  Widget build(BuildContext context) {
    final (label, color) = meta.kind == 'backtest'
        ? ('Backtest', Colors.purple)
        : meta.paperTrading
            ? ('Paper', Colors.orange)
            : ('Live', Colors.green);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
