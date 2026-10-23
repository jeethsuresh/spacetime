import 'dart:async';
import 'models.dart';

/// Saves locally first, then syncs each operation while the app is visible.
/// Brief bursts are combined and requests never overlap. Hourly refresh also
/// fetches updates made elsewhere. No background task is registered.
class ForegroundSync {
  static const interval = Duration(hours: 1);
  static const operationDelay = Duration(milliseconds: 250);
  final CalendarState state;
  final DateTime Function() now;
  final Future<void> Function()? onUnauthorized;
  Timer? _timer;
  String? _account, _lastSync, _token;
  DateTime? _due;
  DateTime? _retryAt;
  int _generation = 0, _failures = 0;
  int? _syncGeneration;
  bool _loading = false;
  bool _pending = false;
  bool _foreground = false, _running = false, _disposed = false;

  ForegroundSync(this.state, {DateTime Function()? now, this.onUnauthorized})
    : now = now ?? DateTime.now {
    state.addListener(_changed);
  }

  void setForeground(bool value) {
    if (value && !_foreground && state.connected) {
      _pending = true;
      _retryAt = null;
    }
    _foreground = value;
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    if (state.loading && !_loading) {
      _syncGeneration = state.localChangeGeneration;
    }
    _loading = state.loading;
    final account = state.connected ? state.account : null;
    final tokenChanged = _token != state.api.token;
    _token = state.api.token;
    if (account != _account) {
      _account = account;
      _lastSync = state.lastSync;
      _generation = state.localChangeGeneration;
      _pending = account != null;
      _retryAt = null;
      _failures = 0;
      _due = now().add(interval);
    } else if (_lastSync != state.lastSync) {
      _lastSync = state.lastSync;
      _due = now().add(interval);
      if (_syncGeneration == state.localChangeGeneration) _pending = false;
      _retryAt = null;
      _failures = 0;
    }
    if (_generation != state.localChangeGeneration) {
      _generation = state.localChangeGeneration;
      _pending = true;
      _retryAt = null;
    }
    if (tokenChanged && account != null) {
      _pending = true;
      _retryAt = null;
      _failures = 0;
    }
    if (!_foreground || account == null || state.loading || _running) return;
    final deadline = _pending ? (_retryAt ?? now().add(operationDelay)) : _due!;
    final delay = deadline.difference(now());
    _timer = Timer(delay.isNegative ? Duration.zero : delay, _sync);
  }

  Future<void> _sync() async {
    _timer = null;
    if (_disposed || !_foreground || !state.connected || state.loading) {
      _changed();
      return;
    }
    _running = true;
    _pending = false;
    final account = state.account;
    _due = now().add(interval);
    try {
      await state.sync();
    } catch (error) {
      if (!_disposed &&
          _foreground &&
          error is ApiException &&
          error.status == 401) {
        await onUnauthorized?.call();
      }
      // Retry transient connection/server failures with a bounded backoff while
      // visible. Authentication and edit conflicts need user attention.
      if (state.connected &&
          state.account == account &&
          error is ApiException &&
          (error.status == 0 || error.status == 429 || error.status >= 500)) {
        _failures = (_failures + 1).clamp(1, 5);
        _retryAt = now().add(
          Duration(seconds: (15 * (1 << _failures)).clamp(30, 300)),
        );
        _pending = true;
      }
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
