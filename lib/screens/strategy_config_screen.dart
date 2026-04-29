import 'package:flutter/material.dart';
import '../models/strategy_config_model.dart';
import '../services/scrip_service.dart';
import '../strategies/base_strategy.dart';
import '../strategies/strategy_registry.dart';

class StrategyConfigScreen extends StatefulWidget {
  final StrategyConfigModel config;
  final bool isNew;

  const StrategyConfigScreen({
    super.key,
    required this.config,
    this.isNew = false,
  });

  @override
  State<StrategyConfigScreen> createState() => _StrategyConfigScreenState();
}

class _StrategyConfigScreenState extends State<StrategyConfigScreen> {
  late StrategyConfigModel _config;
  late BaseStrategy _strategy;
  late TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _config = widget.config.copyWith();
    _strategy = StrategyRegistry.create(_config.strategyType)!;
    _nameCtrl = TextEditingController(text: _config.name);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _save() {
    _config.name = _nameCtrl.text.trim().isEmpty
        ? _strategy.displayName
        : _nameCtrl.text.trim();
    _config.updatedAt = DateTime.now();
    Navigator.pop(context, _config);
  }

  @override
  Widget build(BuildContext context) {
    // Group params by section
    final grouped = <String, List<StrategyParamDef>>{};
    for (final def in _strategy.paramDefinitions) {
      grouped.putIfAbsent(def.group, () => []).add(def);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'New Strategy' : 'Edit Strategy'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Strategy name
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              labelText: 'Strategy Name',
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              prefixIcon: const Icon(Icons.label_outline),
            ),
          ),
          const SizedBox(height: 16),

          // Enabled toggle
          Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: SwitchListTile(
              title: const Text('Strategy Enabled',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                _config.enabled
                    ? 'Strategy will run during market hours'
                    : 'Strategy is paused — will not scan or trade',
              ),
              secondary: Icon(
                _config.enabled ? Icons.power_settings_new : Icons.pause_circle,
                color: _config.enabled ? Colors.green : Colors.grey,
              ),
              value: _config.enabled,
              onChanged: (v) => setState(() => _config.enabled = v),
            ),
          ),
          const SizedBox(height: 8),

          // Paper / Live toggle
          Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: SwitchListTile(
              title: Text(
                _config.paperTrading ? 'Paper Trading' : 'Live Trading',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                _config.paperTrading
                    ? 'No real orders — simulated fills'
                    : 'Real orders will be placed on Dhan',
              ),
              secondary: Icon(
                _config.paperTrading ? Icons.article_outlined : Icons.flash_on,
                color: _config.paperTrading ? Colors.orange : Colors.green,
              ),
              value: _config.paperTrading,
              onChanged: (v) async {
                // Switching to Live requires confirmation
                if (!v) {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Switch to Live Trading?'),
                      content: const Text(
                        'Live trading will place REAL orders on Dhan with real money. '
                        'Make sure you understand the risks before proceeding.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Enable Live',
                              style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                }
                setState(() => _config.paperTrading = v);
              },
            ),
          ),
          const SizedBox(height: 8),

          // Pre-market reminder
          _buildReminderCard(),
          const SizedBox(height: 8),

          // Stock universe count
          Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              leading: const Icon(Icons.list_alt, color: Colors.blue),
              title: const Text('Stock Universe',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                  '${_config.securityIds.length} stocks selected'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                // Show which stocks are in the universe
                final scripService = ScripService();
                final stockNames = _config.securityIds.map((id) {
                  final scrip = scripService.findById(id);
                  return scrip?.symbol ?? id.toString();
                }).toList();

                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  shape: const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(20)),
                  ),
                  builder: (_) => DraggableScrollableSheet(
                    initialChildSize: 0.6,
                    maxChildSize: 0.9,
                    minChildSize: 0.3,
                    expand: false,
                    builder: (_, scrollController) => Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(
                            child: Container(
                              width: 40,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade300,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                              '${stockNames.length} Nifty 500 Stocks',
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          const Text(
                            'Strategy scans Nifty 500 stocks (same as C# project)',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const SizedBox(height: 12),
                          if (stockNames.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 20),
                              child: Center(
                                  child: Text('No Nifty 500 stocks found — scrip data may not be loaded yet',
                                      style: TextStyle(color: Colors.grey))),
                            )
                          else
                            Expanded(
                              child: SingleChildScrollView(
                                controller: scrollController,
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: stockNames
                                      .map((s) => Chip(
                                            label: Text(s,
                                                style:
                                                    const TextStyle(fontSize: 12)),
                                            backgroundColor:
                                                Colors.blue.shade50,
                                          ))
                                      .toList(),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),

          // Parameter sections
          ...grouped.entries.map((entry) => _buildSection(entry.key, entry.value)),
        ],
      ),
    );
  }

  Widget _buildReminderCard() {
    const marketOpenMin = 9 * 60 + 15;
    final reminderMinOfDay = marketOpenMin - _config.reminderMinutesBefore;
    final h24 = reminderMinOfDay ~/ 60;
    final m = reminderMinOfDay % 60;
    final period = h24 >= 12 ? 'PM' : 'AM';
    final h12 = h24 == 0 ? 12 : (h24 > 12 ? h24 - 12 : h24);
    final fmtTime = '$h12:${m.toString().padLeft(2, '0')} $period';
    final leadHrs = _config.reminderMinutesBefore / 60;
    final leadDesc = leadHrs >= 1
        ? '${leadHrs.toStringAsFixed(leadHrs == leadHrs.roundToDouble() ? 0 : 1)} hr before market open'
        : '${_config.reminderMinutesBefore} min before market open';

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('Pre-Market Reminder',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              _config.reminderEnabled
                  ? 'Notify at $fmtTime ($leadDesc, Mon–Fri)'
                  : 'Get a notification before market open to start this strategy',
            ),
            secondary: Icon(
              Icons.notifications_active_outlined,
              color: _config.reminderEnabled ? Colors.purple : Colors.grey,
            ),
            value: _config.reminderEnabled,
            onChanged: (v) =>
                setState(() => _config.reminderEnabled = v),
          ),
          if (_config.reminderEnabled) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  const Text('Lead time',
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                  const Spacer(),
                  Text(
                    '${_config.reminderMinutesBefore} min',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            Slider(
              value: _config.reminderMinutesBefore.toDouble(),
              min: 5,
              max: 180,
              divisions: 35,
              label: '${_config.reminderMinutesBefore} min',
              activeColor: Colors.purple,
              onChanged: (v) => setState(
                  () => _config.reminderMinutesBefore = v.round()),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  const Icon(Icons.schedule, size: 14, color: Colors.purple),
                  const SizedBox(width: 6),
                  Text(
                    'Notification at $fmtTime IST',
                    style: const TextStyle(
                        fontSize: 12,
                        color: Colors.purple,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<StrategyParamDef> defs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.blue.shade700,
            ),
          ),
        ),
        Card(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Column(
            children: defs.map((def) => _buildParam(def)).toList(),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildParam(StrategyParamDef def) {
    final value = _config.params[def.key] ?? def.defaultValue;

    switch (def.type) {
      case ParamType.decimal:
        final dv = (value as num).toDouble();
        final mn = (def.min as num?)?.toDouble() ?? 0;
        final mx = (def.max as num?)?.toDouble() ?? 100;
        return ListTile(
          title: Text(def.label, style: const TextStyle(fontSize: 14)),
          subtitle: def.description.isNotEmpty
              ? Text(def.description,
                  style: const TextStyle(fontSize: 11, color: Colors.grey))
              : null,
          trailing: SizedBox(
            width: 160,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: Slider(
                    value: dv.clamp(mn, mx),
                    min: mn,
                    max: mx,
                    divisions: ((mx - mn) * 10).toInt().clamp(1, 200),
                    onChanged: (v) => setState(() {
                      _config.params[def.key] =
                          double.parse(v.toStringAsFixed(1));
                    }),
                  ),
                ),
                SizedBox(
                  width: 50,
                  child: Text(
                    '${dv.toStringAsFixed(1)}${def.unit ?? ''}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        );

      case ParamType.integer:
        final iv = (value as num).toInt();
        return ListTile(
          title: Text(def.label, style: const TextStyle(fontSize: 14)),
          subtitle: def.description.isNotEmpty
              ? Text(def.description,
                  style: const TextStyle(fontSize: 11, color: Colors.grey))
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  onPressed: () {
                    final mn = (def.min as num?)?.toInt() ?? 0;
                    if (iv > mn) {
                      setState(() => _config.params[def.key] = iv - 1);
                    }
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text('$iv${def.unit != null ? ' ${def.unit}' : ''}',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.add_circle_outline, size: 20),
                  onPressed: () {
                    final mx = (def.max as num?)?.toInt() ?? 999999;
                    if (iv < mx) {
                      setState(() => _config.params[def.key] = iv + 1);
                    }
                  },
                ),
              ),
            ],
          ),
        );

      case ParamType.boolean:
        return SwitchListTile(
          title: Text(def.label, style: const TextStyle(fontSize: 14)),
          subtitle: def.description.isNotEmpty
              ? Text(def.description,
                  style: const TextStyle(fontSize: 11, color: Colors.grey))
              : null,
          value: value as bool? ?? false,
          onChanged: (v) => setState(() => _config.params[def.key] = v),
        );

      case ParamType.time:
        return ListTile(
          title: Text(def.label, style: const TextStyle(fontSize: 14)),
          trailing: Text('$value',
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        );
    }
  }
}
