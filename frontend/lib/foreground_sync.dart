import 'dart:async';
import 'models.dart';

/// Syncs connected accounts while the app is visible. No background task is
/// registered, and an overdue interval results in one sync when returning.
class ForegroundSync {
  static const interval = Duration(hours: 1);
  final CalendarState state;
  final DateTime Function() now;
  Timer? _timer;
  String? _account, _lastSync;
  DateTime? _due;
  bool _foreground = false, _running = false, _disposed = false;

  ForegroundSync(this.state, {DateTime Function()? now})
    : now = now ?? DateTime.now {
    state.addListener(_changed);
  }

  void setForeground(bool value) {
    _foreground = value;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    final account = state.connected ? state.account : null;
    if (account != _account) {
      _account = account;
      _lastSync = state.lastSync;
      final previous = DateTime.tryParse(state.lastSync ?? '');
      // A new connection starts its hourly interval here; a restored account
      // can catch up once if its last successful sync is already overdue.
      _due = (previous == null || previous.isAfter(now()) ? now() : previous)
          .add(interval);
    } else if (_lastSync != state.lastSync) {
      _lastSync = state.lastSync;
      _due = now().add(interval);
    }
    if (!_foreground || account == null || state.loading || _running) return;
    final delay = _due!.difference(now());
    _timer = Timer(delay.isNegative ? Duration.zero : delay, _sync);
  }

  Future<void> _sync() async {
    _timer = null;
    if (_disposed || !_foreground || !state.connected || state.loading) {
      _changed();
      return;
    }
    _running = true;
    // Failures wait a full interval, rather than repeatedly retrying offline.
    _due = now().add(interval);
    try {
      await state.sync();
    } catch (_) {
      // CalendarState retains unsynced edits and exposes the error in Settings.
    } finally {
      _running = false;
      _changed();
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    state.removeListener(_changed);
  }
}
