import 'package:flutter/widgets.dart';

import '../core/app_state.dart';
import '../shell/links.dart';

/// Signing in happens on the website; native screens share its session.
Future<void> openSignIn(BuildContext context) =>
    openLink(context, '/${AppScope.of(context).text.locale}/account/');
