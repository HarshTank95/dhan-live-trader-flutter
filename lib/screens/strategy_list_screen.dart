import 'dart:async';
import 'package:flutter/material.dart';
import '../models/strategy_config_model.dart';
import '../services/app_logger.dart';
import '../services/scrip_service.dart';
import '../services/storage_service.dart';
import '../services/strategy_background_service.dart';
import '../services/strategy_reminder_service.dart';
import '../strategies/base_strategy.dart';
import '../strategies/strategy_registry.dart';
import 'backtest_config_screen.dart';
import 'strategy_config_screen.dart';
import 'strategy_dashboard_screen.dart';

class StrategyListScreen extends StatefulWidget {
  final String clientId;
  final String accessToken;

  const StrategyListScreen({
    super.key,
    required this.clientId,
    required this.accessToken,
  });

  @override
  State<StrategyListScreen> createState() => _StrategyListScreenState();
}

class _StrategyListScreenState extends State<StrategyListScreen>
    with WidgetsBindingObserver {
  List<StrategyConfigModel> _configs = [];
  bool _isLoading = true;

  // Track running state per config id
  final Map<String, bool> _runningStates = {};
  String _statusMessage = '';
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenToService();
    _load().then((_) => _checkServiceRunning());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkServiceRunning();
    } else if (state == AppLifecycleState.paused) {
      StrategyBackgroundService.flushNow();
    }
  }

  void _listenToService() {
    // Listen for status updates from background service
    _subs.add(StrategyBackgroundService.onUpdate.listen((event) {
      AppLogger.info('StrategyList', 'onUpdate event: $event');
      if (event == null) return;
      final status = event['status'] as String?;
      final message = event['message'] as String? ?? '';
      final configId = event['configId'] as String?;

      if (mounted) {
        setState(() {
          if (message.isNotEmpty) _statusMessage = message;
          if (status == 'running' && configId != null && configId.isNotEmpty) {
            _runningStates[configId] = true;
            StorageService.setActiveStrategy(configId);
          }
          if (status == 'stopped' || status == 'completed') {
            _runningStates.updateAll((key, value) => false);
            _statusMessage = '';
            StorageService.setActiveStrategy(null);
          }
        });
      }
    }));

    _subs.add(StrategyBackgroundService.onCompleted.listen((event) {
      if (event == null || !mounted) return;
      StorageService.setActiveStrategy(null);
      setState(() {
        _runningStates.updateAll((key, value) => false);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(event['message'] as String? ?? 'Strategy completed'),
          backgroundColor: Colors.blue.shade700,
        ),
      );
    }));
  }

  Future<void> _checkServiceRunning() async {
    final activeConfigId = await StorageService.getActiveStrategy();
    if (activeConfigId == null || !mounted) return;

    final running = await StrategyBackgroundService.isRunning();
    if (running) {
      // Service is alive — sync UI even if configs still loading.
      if (mounted) {
        setState(() {
          _runningStates[activeConfigId] = true;
        });
      }
    } else if (_configs.isNotEmpty) {
      // Service not running and configs are loaded → flag is stale, clear it.
      // Skip clearing while _configs is empty to avoid wiping the flag during
      // a race with _load() on app resume.
      await StorageService.setActiveStrategy(null);
    }
  }

  Future<void> _load() async {
    var configs = await StorageService.loadStrategyConfigs();

    // Auto-create default strategy on first launch
    if (configs.isEmpty) {
      final defaultConfig = _createDefaultConfig();
      if (defaultConfig != null) {
        configs = [defaultConfig];
        await StorageService.saveStrategyConfigs(configs);
      }
    }

    // Refresh security IDs from dynamic index list
    final scripService = ScripService();
    if (scripService.isLoaded) {
      final freshIds = scripService.getSecurityIdsForUniverse('Nifty 500');
      if (freshIds.length > configs.first.securityIds.length) {
        for (final c in configs) {
          c.securityIds = freshIds;
        }
        await StorageService.saveStrategyConfigs(configs);
      }
    }

    if (mounted) setState(() { _configs = configs; _isLoading = false; });
  }

  /// Creates the default Dominance+Breakout strategy with Nifty 500 stocks.
  StrategyConfigModel? _createDefaultConfig() {
    final strategy = StrategyRegistry.create('dominance_breakout');
    if (strategy == null) return null;

    final scripService = ScripService();
    final nifty500Ids = scripService.isLoaded
        ? scripService.getSecurityIdsForUniverse('Nifty 500')
        : <int>[];

    return StrategyConfigModel(
      strategyType: strategy.type,
      name: strategy.displayName,
      params: Map<String, dynamic>.from(strategy.defaultParams),
      securityIds: nifty500Ids,
    );
  }

  Future<void> _save() async {
    await StorageService.saveStrategyConfigs(_configs);
  }

  void _createNew() {
    final strategies = StrategyRegistry.allTypes;
    if (strategies.isEmpty) return;

    if (strategies.length == 1) {
      _createForType(strategies.first);
      return;
    }

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Choose Strategy Type',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ...strategies.map((s) => ListTile(
                  leading: const Icon(Icons.bolt, color: Colors.blue),
                  title: Text(s.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(s.description, style: const TextStyle(fontSize: 12)),
                  onTap: () {
                    Navigator.pop(context);
                    _createForType(s);
                  },
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _createForType(BaseStrategy strategy) async {
    final scripService = ScripService();
    if (!scripService.isLoaded) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Loading stock data... please try again in a moment')),
        );
      }
      return;
    }
    final nifty500Ids = scripService.getSecurityIdsForUniverse('Nifty 500');

    final config = StrategyConfigModel(
      strategyType: strategy.type,
      name: '${strategy.displayName} ${_configs.length + 1}',
      params: Map<String, dynamic>.from(strategy.defaultParams),
      securityIds: nifty500Ids,
    );

    _openConfig(config, isNew: true);
  }

  Future<void> _openConfig(StrategyConfigModel config,
      {bool isNew = false}) async {
    final result = await Navigator.push<StrategyConfigModel>(
      context,
      MaterialPageRoute(
        builder: (_) => StrategyConfigScreen(config: config, isNew: isNew),
      ),
    );

    if (result != null && mounted) {
      setState(() {
        final idx = _configs.indexWhere((c) => c.id == result.id);
        if (idx >= 0) {
          _configs[idx] = result;
        } else {
          _configs.add(result);
        }
      });
      await _save();

      // Sync the reminder for this config — schedule if enabled, else cancel.
      if (result.reminderEnabled) {
        await StrategyReminderService.scheduleReminder(result);
      } else {
        await StrategyReminderService.cancelReminder(result.id);
      }
    }
  }

  void _openDashboard(StrategyConfigModel config) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StrategyDashboardScreen(
          config: config,
          clientId: widget.clientId,
          accessToken: widget.accessToken,
        ),
      ),
    );
  }

  Future<void> _delete(StrategyConfigModel config) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Strategy?'),
        content: Text('Delete "${config.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await StrategyReminderService.cancelReminder(config.id);
      setState(() {
        _configs.removeWhere((c) => c.id == config.id);
        _runningStates.remove(config.id);
      });
      await _save();
    }
  }

  // ── Start / Stop ──────────────────────────────────────────────────────

  Future<void> _toggleStrategy(StrategyConfigModel config) async {
    final isRunning = _runningStates[config.id] ?? false;
    AppLogger.info('StrategyList', 'Toggle ${config.name}: isRunning=$isRunning');

    if (!isRunning) {
      // Starting
      if (!config.enabled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Strategy is paused. Enable it in config first.')),
        );
        return;
      }

      final started = await StrategyBackgroundService.startService(
        configId: config.id,
        strategyType: config.strategyType,
        configName: config.name,
        isPaper: config.paperTrading,
        clientId: widget.clientId,
        accessToken: widget.accessToken,
        configJson: config.toJson(),
      );

      if (!mounted) return;

      if (started) {
        await StorageService.setActiveStrategy(config.id);
        setState(() => _runningStates[config.id] = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${config.name} started — scanning ${config.securityIds.length} stocks'),
            backgroundColor: Colors.green.shade700,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to start — please allow notification permission'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } else {
      // Stopping
      await StrategyBackgroundService.stopService();
      await StorageService.setActiveStrategy(null);

      if (mounted) {
        setState(() => _runningStates[config.id] = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${config.name} stopped'),
            backgroundColor: Colors.orange.shade700,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Strategies'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New Strategy',
            onPressed: _createNew,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _configs.isEmpty
              ? _buildEmpty()
              : _buildList(),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.auto_graph, size: 72, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          const Text('No strategies yet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Tap + to create one',
              style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      itemCount: _configs.length,
      itemBuilder: (context, index) {
        final config = _configs[index];
        final strategy = StrategyRegistry.create(config.strategyType);
        final isRunning = _runningStates[config.id] ?? false;

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: isRunning ? 4 : 1,
          child: Column(
            children: [
              // ── Top section: strategy info (tap → dashboard) ──────
              InkWell(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                onTap: () => _openDashboard(config),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
                  child: Row(
                    children: [
                      // Icon with running indicator
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: isRunning
                              ? Colors.green.withValues(alpha: 0.15)
                              : Colors.blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: isRunning
                              ? Border.all(color: Colors.green, width: 2)
                              : null,
                        ),
                        child: Icon(
                          isRunning ? Icons.trending_up : Icons.bolt,
                          color: isRunning ? Colors.green : Colors.blue,
                          size: 26,
                        ),
                      ),
                      const SizedBox(width: 14),
                      // Info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(config.name,
                                      style: const TextStyle(
                                          fontSize: 16, fontWeight: FontWeight.bold)),
                                ),
                                if (!config.enabled)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade200,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text('Paused',
                                        style: TextStyle(
                                            fontSize: 10, color: Colors.grey)),
                                  ),
                                if (isRunning)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.green.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text('RUNNING',
                                        style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.green)),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              strategy?.displayName ?? config.strategyType,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.grey),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                _badge(
                                  config.paperTrading ? 'Paper' : 'Live',
                                  config.paperTrading
                                      ? Colors.orange
                                      : Colors.green,
                                ),
                                _badge(
                                  '${config.securityIds.length} stocks',
                                  Colors.blue,
                                ),
                                _badge(
                                  'SL ₹${((config.params['fixedStopLoss'] as num?) ?? 500).toStringAsFixed(0)}',
                                  Colors.red,
                                ),
                                if (config.reminderEnabled &&
                                    config.reminderMinutesBefore > 0)
                                  _badge(
                                    '🔔 ${_reminderClock(config.reminderMinutesBefore)}',
                                    Colors.purple,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // 3-dot menu
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, color: Colors.grey),
                        onSelected: (value) {
                          if (value == 'edit') _openConfig(config);
                          if (value == 'delete') _delete(config);
                          if (value == 'dashboard') _openDashboard(config);
                          if (value == 'backtest') {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => BacktestConfigScreen(
                                  accessToken: widget.accessToken,
                                  clientId: widget.clientId,
                                ),
                              ),
                            );
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                              value: 'dashboard', child: Text('View Dashboard')),
                          const PopupMenuItem(
                              value: 'backtest',
                              child: Row(
                                children: [
                                  Icon(Icons.science, size: 18, color: Colors.purple),
                                  SizedBox(width: 8),
                                  Text('Backtest'),
                                ],
                              )),
                          const PopupMenuItem(
                              value: 'edit', child: Text('Edit Config')),
                          const PopupMenuItem(
                              value: 'delete',
                              child:
                                  Text('Delete', style: TextStyle(color: Colors.red))),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // ── Status message when running ──────────────────────
              if (isRunning && _statusMessage.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.green),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _statusMessage,
                            style: const TextStyle(fontSize: 12, color: Colors.green),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // ── Bottom section: START / STOP button ──────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SizedBox(
                  height: 44,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isRunning
                          ? Colors.red
                          : Colors.green,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: isRunning ? 2 : 4,
                    ),
                    onPressed: () => _toggleStrategy(config),
                    icon: Icon(
                      isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                      size: 22,
                    ),
                    label: Text(
                      isRunning ? 'STOP STRATEGY' : 'START STRATEGY',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _reminderClock(int minutesBefore) {
    final mod = (9 * 60 + 15) - minutesBefore;
    final h24 = mod ~/ 60;
    final m = mod % 60;
    final period = h24 >= 12 ? 'PM' : 'AM';
    final h12 = h24 == 0 ? 12 : (h24 > 12 ? h24 - 12 : h24);
    return '$h12:${m.toString().padLeft(2, '0')} $period';
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style:
            TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
