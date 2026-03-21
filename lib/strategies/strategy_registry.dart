import 'base_strategy.dart';
import 'dominance_breakout_strategy.dart';

/// Registry of all available strategy types.
/// To add a new strategy: create the class, then register it here.
class StrategyRegistry {
  static final Map<String, BaseStrategy Function()> _factories = {};

  static void init() {
    register('dominance_breakout', () => DominanceBreakoutStrategy());
    // Future strategies:
    // register('orb', () => OpeningRangeBreakoutStrategy());
    // register('vwap_reversal', () => VwapReversalStrategy());
  }

  static void register(String type, BaseStrategy Function() factory) {
    _factories[type] = factory;
  }

  static BaseStrategy? create(String type) => _factories[type]?.call();

  static List<BaseStrategy> get allTypes =>
      _factories.values.map((f) => f()).toList();
}
