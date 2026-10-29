import 'dart:async';

import 'package:flutter/widgets.dart';

import 'api.dart';
import 'app_state.dart';
import 'account_resource.dart';
import 'private_content_api.dart';
import 'provider_api.dart';

class CatalogSourceScope extends StatefulWidget {
  const CatalogSourceScope({super.key, required this.api, required this.child});
  final HaneokaApi api;
  final Widget child;
  @override
  State<CatalogSourceScope> createState() => _CatalogSourceScopeState();
  static HaneokaApi? maybeApi(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_CatalogSourceInherited>()
      ?.notifier;
  static HaneokaApi apiOf(BuildContext context) =>
      maybeApi(context) ?? AppScope.of(context).api;
  static HaneokaApi resolve(
    BuildContext context, {
    HaneokaApi? api,
    String? server,
  }) {
    if (api != null) return api;
    final scoped = maybeApi(context);
    if (scoped != null && (server == null || server == scoped.server)) {
      return scoped;
    }
    final state = AppScope.of(context);
    return state.apiFor(server ?? state.server);
  }

  static String serverOf(BuildContext context) =>
      maybeApi(context)?.server ?? AppScope.of(context).server;
  static Map<String, HaneokaApi> apisOf(BuildContext context) {
    final api = maybeApi(context);
    return api == null
        ? AppScope.of(context).catalogApis
        : api is! ProviderApi && const {'jp', 'intl'}.contains(api.server)
        ? {...AppScope.of(context).catalogApis, api.server: api}
        : {api.server: api};
  }

  static Object keyOf(BuildContext context) {
    final api = maybeApi(context);
    return (api, api?.revision, AppScope.of(context).publicDataKey);
  }
}

class _CatalogSourceScopeState extends State<CatalogSourceScope> {
  StreamSubscription<void>? _changes;
  int _epoch = 0;
  bool _revoked = false;
  void _bind() {
    unawaited(_changes?.cancel());
    _changes = null;
    _revoked = false;
    if (widget.api is! PrivateContentApi) return;
    _epoch = AccountResources.instance.epoch;
    _changes = AccountResources.instance.changes.listen((_) {
      if (!mounted || _epoch == AccountResources.instance.epoch) return;
      setState(() => _revoked = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_revoked) return;
        final route = ModalRoute.of(context), navigator = Navigator.of(context);
        if (route == null || !route.isActive) return;
        if (!route.isCurrent) {
          navigator.removeRoute(route);
        } else if (navigator.canPop()) {
          navigator.pop();
        }
      });
    });
  }

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(CatalogSourceScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.api, oldWidget.api)) _bind();
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _CatalogSourceInherited(
    api: widget.api,
    child: _revoked
        ? const SizedBox.shrink()
        : KeyedSubtree(key: ValueKey(widget.api), child: widget.child),
  );
}

class _CatalogSourceInherited extends InheritedNotifier<HaneokaApi> {
  const _CatalogSourceInherited({required HaneokaApi api, required super.child})
    : super(notifier: api);
}
