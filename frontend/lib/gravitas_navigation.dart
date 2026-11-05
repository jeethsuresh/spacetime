import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A destination can be reopened by Forward. Only opt in browsing destinations;
/// never register login, confirmation, payment, editor or call-start actions.
class HistoryPageRoute<T> extends MaterialPageRoute<T> {
  HistoryPageRoute({required super.builder, super.settings});
}

class HistoryDestination {
  const HistoryDestination(this.open);
  final VoidCallback open;
}

class _ForwardVisit {
  _ForwardVisit(this.anchor, this.open);
  Route<dynamic>? anchor;
  final VoidCallback open;
}

/// One forward stack covers both Navigator routes and state-based destinations.
class GravitasNavigationObserver extends NavigatorObserver {
  final _routes = <Route<dynamic>>[];
  final _future = <_ForwardVisit>[];
  bool _replaying = false;
  Route<dynamic>? get current => _routes.lastOrNull;

  void branch() {
    if (!_replaying) _future.clear();
  }

  void clear() => _future.clear();

  void remember(VoidCallback open) {
    _future.add(_ForwardVisit(current, open));
    if (_future.length > 64) _future.removeAt(0);
  }

  void forward() {
    if (current?.willHandlePopInternally == true ||
        _future.isEmpty ||
        _future.last.anchor != current) {
      return;
    }
    final visit = _future.removeLast();
    _replaying = true;
    try {
      visit.open();
    } finally {
      _replaying = false;
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute || route.settings.arguments is HistoryDestination) {
      branch();
    }
    _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    if (route is HistoryPageRoute) {
      final builder = route.builder, settings = route.settings;
      remember(() {
        final replacement = HistoryPageRoute<void>(
          builder: builder,
          settings: settings,
        );
        for (final visit in _future) {
          if (visit.anchor == route) visit.anchor = replacement;
        }
        navigator?.push<void>(replacement);
      });
    } else if (route.settings.arguments case final HistoryDestination visit) {
      remember(visit.open);
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    clear();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0 && newRoute != null) _routes[index] = newRoute;
    clear();
  }
}

/// Put this in MaterialApp.builder and the observer in navigatorObservers.
class GravitasNavigation extends StatefulWidget {
  const GravitasNavigation({
    super.key,
    required this.observer,
    required this.child,
  });
  final GravitasNavigationObserver observer;
  final Widget child;
  static GravitasNavigationObserver? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_NavigationScope>()?.observer;
  @override
  State<GravitasNavigation> createState() => _GravitasNavigationState();
}

class _GravitasNavigationState extends State<GravitasNavigation> {
  static const channel = MethodChannel('cool.gravitas/navigation');
  static _GravitasNavigationState? owner;
  @override
  void initState() {
    super.initState();
    owner = this;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'forward') widget.observer.forward();
    });
  }

  @override
  void dispose() {
    if (owner == this) {
      owner = null;
      channel.setMethodCallHandler(null);
    }
    widget.observer.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _NavigationScope(observer: widget.observer, child: widget.child);
}

class _NavigationScope extends InheritedWidget {
  const _NavigationScope({required this.observer, required super.child});
  final GravitasNavigationObserver observer;
  @override
  bool updateShouldNotify(_NavigationScope oldWidget) =>
      observer != oldWidget.observer;
}

/// Record immutable destination values (Dart records work well). Recreating the
/// boundary on account changes drops private history. Restoration navigates only;
/// it must never repeat the action that originally opened a destination.
class HistoryBoundary<T> extends StatefulWidget {
  const HistoryBoundary({
    super.key,
    required this.value,
    required this.restore,
    required this.child,
    this.interceptBack = true,
    this.sameDestination,
  });
  final T value;
  final ValueChanged<T> restore;
  final Widget child;
  final bool interceptBack;
  final bool Function(T, T)? sameDestination;
  @override
  State<HistoryBoundary<T>> createState() => HistoryBoundaryState<T>();
}

class HistoryBoundaryState<T> extends State<HistoryBoundary<T>> {
  final _past = <T>[];
  late T _current;
  @override
  void initState() {
    super.initState();
    _current = widget.value;
  }

  GravitasNavigationObserver? navigation;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    navigation = GravitasNavigation.of(context);
  }

  @override
  void didUpdateWidget(HistoryBoundary<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == _current) return;
    if (widget.sameDestination?.call(_current, widget.value) == true) {
      _current = widget.value;
      return;
    }
    _past.add(_current);
    if (_past.length > 64) _past.removeAt(0);
    _current = widget.value;
    navigation?.branch();
  }

  bool get hasBack => _past.isNotEmpty;
  bool back() {
    if (_past.isEmpty) return false;
    final next = _past.removeLast(), previous = _current;
    navigation?.remember(() {
      if (!mounted) return;
      _past.add(_current);
      _current = previous;
      widget.restore(previous);
    });
    _current = next;
    widget.restore(next);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final localHistory =
        ModalRoute.of(context)?.willHandlePopInternally == true;
    return PopScope<Object?>(
      canPop: localHistory || !widget.interceptBack || _past.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !localHistory && widget.interceptBack) back();
      },
      child: widget.child,
    );
  }
}
