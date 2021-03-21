library routemaster;

export 'src/parser.dart';
export 'src/route_info.dart';
export 'src/pages/guard.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart';
import 'package:collection/collection.dart';
import 'src/pages/guard.dart';
import 'src/route_dart.dart';
import 'src/system_nav.dart';
import 'src/trie_router/trie_router.dart';
import 'src/route_info.dart';

part 'src/pages/stack.dart';
part 'src/pages/tab_pages.dart';
part 'src/pages/standard.dart';

typedef RoutemasterBuilder = Widget Function(
  BuildContext context,
  Routemaster routemaster,
);

typedef PageBuilder = Page Function(RouteInfo info);

typedef UnknownRouteCallback = Page? Function(
  Routemaster routemaster,
  String route,
  BuildContext context,
);

/// An abstract class that can provide a map of routes
abstract class RouteConfig {
  /// Called when there's no match for a route. Defaults to redirecting to '/'.
  ///
  /// There are two general options for this callback's operation:
  ///
  ///   1. Return a page, which will be displayed.
  ///
  /// or
  ///
  ///   2. Use the routing delegate to, for instance, redirect to another route
  ///      and return null.
  ///
  Page? onUnknownRoute(
      Routemaster delegate, String route, BuildContext context) {
    delegate.push('/');
  }

  /// Generate a single [RouteResult] for the given [path]. Returns null if the
  /// path isn't valid.
  RouterResult? get(String path);

  /// Generate all [RouteResult] objects required to build the navigation tree
  /// for the given [path]. Returns null if the path isn't valid.
  List<RouterResult>? getAll(String path);
}

@immutable
abstract class DefaultRouterConfig extends RouteConfig {
  final _router = TrieRouter();

  DefaultRouterConfig() {
    _router.addAll(routes);
  }

  @override
  RouterResult? get(String route) => _router.get(route);

  @override
  List<RouterResult>? getAll(String route) => _router.getAll(route);

  Map<String, PageBuilder> get routes;
}

/// A standard simple routing table which takes a map of routes.
class RouteMap extends DefaultRouterConfig {
  /// A map of paths and [PageBuilder] delegates that return [Page] objects to
  /// build.
  @override
  final Map<String, PageBuilder> routes;

  final UnknownRouteCallback? _onUnknownRoute;

  RouteMap({
    required this.routes,
    UnknownRouteCallback? onUnknownRoute,
  }) : _onUnknownRoute = onUnknownRoute;

  @override
  Page? onUnknownRoute(
      Routemaster routemaster, String route, BuildContext context) {
    if (_onUnknownRoute != null) {
      return _onUnknownRoute!(routemaster, route, context);
    }

    super.onUnknownRoute(routemaster, route, context);
  }
}

class Routemaster extends RouterDelegate<RouteData> with ChangeNotifier {
  /// Used to override how the [Navigator] builds.
  final RoutemasterBuilder? builder;
  final TransitionDelegate? transitionDelegate;

  // TODO: Could this have a better name?
  // Options: mapBuilder, builder, routeMapBuilder
  final RouteConfig Function(BuildContext context) routesBuilder;

  _RoutemasterState _state = _RoutemasterState();
  bool _isBuilding = false;

  Routemaster({
    required this.routesBuilder,
    this.builder,
    this.transitionDelegate,
  });

  static Routemaster of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_RoutemasterWidget>()!
        .delegate;
  }

  /// Pop the top-most path from the router.
  void pop() {
    _state.stack!._pop();
    _markNeedsUpdate();
  }

  @override
  Future<bool> popRoute() {
    if (_state.stack == null) {
      return SynchronousFuture(false);
    }

    return _state.stack!._maybePop();
  }

  /// Passed to top-level [Navigator] widget, called when the navigator requests
  /// that it wants to pop a page.
  bool onPopPage(Route<dynamic> route, dynamic result) {
    return _state.stack!.onPopPage(route, result);
  }

  /// Pushes [path] into the navigation tree.
  void push(String path, {Map<String, String>? queryParameters}) {
    _setLocation(
      isAbsolute(path) ? path : join(currentConfiguration!.path, path),
      queryParameters: queryParameters,
    );
  }

  /// Replaces the current route with [path].
  void replace(String path, {Map<String, String>? queryParameters}) {
    if (kIsWeb) {
      final url = Uri(path: path, queryParameters: queryParameters);
      SystemNav.replaceLocation(url.toString());
    } else {
      push(path, queryParameters: queryParameters);
    }
  }

  /// Generates all pages and sub-pages.
  List<Page> createPages(BuildContext context) {
    assert(_state.stack != null,
        'Stack must have been created when createPages() is called');
    final pages = _state.stack!.createPages();
    assert(pages.isNotEmpty, 'Returned pages list must not be empty');
    _updateCurrentConfiguration();
    return pages;
  }

  void _markNeedsUpdate() {
    _updateCurrentConfiguration();

    if (!_isBuilding) {
      notifyListeners();
    }
  }

  /// Replace the entire route with the path from [path].
  void _setLocation(String path, {Map<String, String>? queryParameters}) {
    if (queryParameters != null) {
      path = Uri(
        path: path,
        queryParameters: queryParameters,
      ).toString();
    }

    if (_isBuilding) {
      // About to build pages, process request now
      _processNavigation(path);
    } else {
      // Schedule request for next build. This makes sure the routing table is
      // updated before processing the new path.
      _state.pendingNavigation = path;
      _markNeedsUpdate();
    }
  }

  void _processPendingNavigation() {
    if (_state.pendingNavigation != null) {
      _processNavigation(_state.pendingNavigation!);
      _state.pendingNavigation = null;
    }
  }

  void _processNavigation(String path) {
    final states = _createAllStates(path);
    if (states == null) {
      return;
    }

    _state.stack!._setPageStates(states);
  }

  @override
  Widget build(BuildContext context) {
    return _DependencyTracker(
      delegate: this,
      builder: (context) {
        _isBuilding = true;
        _init(context);
        _processPendingNavigation();
        final pages = createPages(context);
        _isBuilding = false;

        return _RoutemasterWidget(
          delegate: this,
          child: builder != null
              ? builder!(context, this)
              : Navigator(
                  pages: pages,
                  onPopPage: onPopPage,
                  key: _state.stack!.navigatorKey,
                  transitionDelegate: transitionDelegate ??
                      const DefaultTransitionDelegate<dynamic>(),
                ),
        );
      },
    );
  }

  // Returns a [RouteData] that matches the current route state.
  // This is used to update a browser's current URL.

  @override
  RouteData? get currentConfiguration {
    return _state.currentConfiguration;
  }

  void _updateCurrentConfiguration() {
    if (_state.stack == null) {
      return;
    }

    final path = _state.stack!._getCurrentPageStates().last._routeInfo.path;
    print("Updated path: '$path'");
    _state.currentConfiguration = RouteData(path);
  }

  // Called when a new URL is set. The RouteInformationParser will parse the
  // URL, and return a new [RouteData], that gets passed this this method.
  //
  // This method then modifies the state based on that information.
  @override
  Future<void> setNewRoutePath(RouteData routeData) {
    push(routeData.path);
    return SynchronousFuture(null);
  }

  void _init(BuildContext context, {bool isRebuild = false}) {
    if (_state.routeConfig == null) {
      _state.routeConfig = routesBuilder(context);

      final path = currentConfiguration?.path ?? '/';
      final pageStates = _createAllStates(path);
      if (pageStates == null) {
        if (isRebuild) {
          // Route map has rebuilt but there's no path match. Assume user is
          // about to set a new path on the router that we don't know about yet
          print(
            "Router rebuilt but no match for '$path'. Assuming navigation is about to happen.",
          );
          return;
        }

        throw 'Failed to create initial state';
      }

      _state.stack = StackPageState(
        delegate: this,
        routes: pageStates.toList(),
      );
    }
  }

  /// Called when dependencies of the [routesBuilder] changed.
  void _didChangeDependencies(BuildContext context) {
    if (currentConfiguration == null) {
      return;
    }

    WidgetsBinding.instance?.addPostFrameCallback((_) => _markNeedsUpdate());

    _state.routeConfig = null;

    _isBuilding = true;
    _init(context, isRebuild: true);
    _isBuilding = false;
  }

  List<_PageState>? _createAllStates(String requestedPath) {
    final routerResult = _state.routeConfig!.getAll(requestedPath);

    if (routerResult == null) {
      print("Router couldn't find a match for path '$requestedPath''");

      final result = _state.routeConfig!.onUnknownRoute(
          this, requestedPath, _state.globalKey.currentContext!);
      if (result == null) {
        // No 404 page returned
        return null;
      }

      // Show 404 page
      final routeInfo = RouteInfo(requestedPath, (_) => result);
      return [_StatelessPage(routeInfo, result)];
    }

    final currentRoutes = _state.stack?._getCurrentPageStates().toList();

    var result = <_PageState>[];

    var i = 0;
    for (final routerData in routerResult.reversed) {
      final routeInfo = RouteInfo.fromRouterResult(
        routerData,
        // Only the last route gets query parameters
        i == 0 ? requestedPath : routerData.pathSegment,
      );

      final state = _getOrCreatePageState(routeInfo, currentRoutes, routerData);

      if (state == null) {
        return null;
      }

      if (result.isNotEmpty && state._maybeSetPageStates(result)) {
        result = [state];
      } else {
        result.insert(0, state);
      }

      i++;
    }

    assert(result.isNotEmpty, "_createAllStates can't return empty list");
    return result;
  }

  /// If there's a current route matching the path in the tree, return it.
  /// Otherwise create a new one. This could possibly be made more efficient
  /// By using a map rather than iterating over all currentRoutes.
  _PageState? _getOrCreatePageState(
    RouteInfo routeInfo,
    List<_PageState>? currentRoutes,
    RouterResult routerResult,
  ) {
    if (currentRoutes != null) {
      print(
          " - Trying to find match for state matching '${routeInfo.path}'...");
      final currentState = currentRoutes.firstWhereOrNull(
        ((element) => element._routeInfo == routeInfo),
      );

      if (currentState != null) {
        print(' - Found match for state');
        return currentState;
      }

      print(' - No match for state, will need to create it');
    }

    return _createState(routerResult, routeInfo);
  }

  /// Try to get the route for [requestedPath]. If no match, returns default path.
  /// Returns null if validation fails.
  _PageState? _getRoute(String requestedPath) {
    final routerResult = _state.routeConfig!.get(requestedPath);
    if (routerResult == null) {
      print(
        "Router couldn't find a match for path '$requestedPath'",
      );

      _state.routeConfig!.onUnknownRoute(
          this, requestedPath, _state.globalKey.currentContext!);
      return null;
    }

    final routeInfo = RouteInfo.fromRouterResult(routerResult, requestedPath);
    return _createState(routerResult, routeInfo);
  }

  _PageState? _createState(RouterResult routerResult, RouteInfo routeInfo) {
    var page = routerResult.builder(routeInfo);

    if (page is GuardedPage) {
      final context = _state.globalKey.currentContext!;
      if (page.validate != null && !page.validate!(routeInfo, context)) {
        print("Validation failed for '${routeInfo.path}'");
        page.onValidationFailed!(this, routeInfo, context);
        return null;
      }

      page = page.child;
    }

    if (page is StatefulPage) {
      return page.createState(this, routeInfo);
    }

    assert(page is! ProxyPage, 'ProxyPage has not been unwrapped');

    // Page is just a standard Flutter page, create a wrapper for it
    return _StatelessPage(routeInfo, page);
  }
}

/// Used internally so descendent widgets can use `Routemaster.of(context)`.
class _RoutemasterWidget extends InheritedWidget {
  final Routemaster delegate;

  const _RoutemasterWidget({
    required Widget child,
    required this.delegate,
  }) : super(child: child);

  @override
  bool updateShouldNotify(covariant _RoutemasterWidget oldWidget) {
    return delegate != oldWidget.delegate;
  }
}

class _RoutemasterState {
  final globalKey = GlobalKey();
  StackPageState? stack;
  RouteConfig? routeConfig;
  RouteData? currentConfiguration;
  String? pendingNavigation;
}

/// Widget to trigger router rebuild when dependencies change
class _DependencyTracker extends StatefulWidget {
  final Routemaster delegate;
  final Widget Function(BuildContext context) builder;

  _DependencyTracker({
    required this.delegate,
    required this.builder,
  });

  @override
  _DependencyTrackerState createState() => _DependencyTrackerState();
}

class _DependencyTrackerState extends State<_DependencyTracker> {
  late _RoutemasterState _delegateState;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _delegateState.globalKey,
      child: widget.builder(context),
    );
  }

  @override
  void initState() {
    super.initState();
    _delegateState = widget.delegate._state;
    widget.delegate._state = _delegateState;
  }

  @override
  void didUpdateWidget(_DependencyTracker oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.delegate._state = _delegateState;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.delegate._didChangeDependencies(this.context);
  }
}
