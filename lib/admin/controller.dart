import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../account/haneoka_account.dart';
import '../chart_editor/project.dart';

const adminSections = [
  'overview',
  'users',
  'posts',
  'forums',
  'reports',
  'appeals',
  'comments',
  'operations',
];
const adminRoles = [
  'member',
  'regular',
  'trusted',
  'contributor',
  'moderator',
  'admin',
];

typedef AdminRequest = Future<ChartMap> Function(
  String path, {
  String method,
  Object? body,
  Map<String, String> headers,
  Uint8List? bytes,
});

class AdminController extends ChangeNotifier {
  AdminController(this.section, {Map<String, String> initialQuery = const {}})
    : query = {...initialQuery} {
    _account.addListener(_accountChanged);
    _identity = _currentIdentity;
  }
  final _account = HaneokaAccount.instance;
  Object? _identity;
  Object get _currentIdentity =>
      (_account.user?['id'], _account.authorization['Authorization']);
  String section;
  final Map<String, String> query;
  ValueChanged<String>? onNavigate;
  ChartMap staff = {}, document = {};
  List<ChartMap> servers = [], forums = [], groups = [];
  ChartMap? readyPackage;
  String? cursor, error;
  bool loading = false, busy = false, _closed = false;
  int _generation = 0, _listGeneration = 0;
  int get ownerGeneration => _generation;
  double packageProgress = 0;
  bool can(String capability) =>
      ((staff['capabilities'] as List?) ?? const []).contains(capability);
  String get contentKind =>
      section == 'posts' &&
          const {'charts', 'playlists'}.contains(query['kind'])
      ? query['kind']!
      : 'posts';
  String get recordsKey =>
      section == 'posts' && contentKind != 'posts' ? 'creations' : section;
  List<ChartMap> get records => chartRows(document[recordsKey] ?? const []);
  void selectContent(String kind) {
    if (onNavigate case final navigate?) {
      navigate(
        Uri(path: '/admin/posts', queryParameters: {'kind': kind}).toString(),
      );
      return;
    }
    query['kind'] = kind;
    for (final key in ['status', 'moderationStatus', 'forumId', 'cursor']) {
      query.remove(key);
    }
    document = {};
    cursor = null;
    unawaited(load());
  }

  void changed() {
    if (!_closed) notifyListeners();
  }

  void _accountChanged() {
    if (_identity != _currentIdentity) {
      _identity = _currentIdentity;
      _generation++;
      _listGeneration++;
      staff = {};
      document = {};
      servers = [];
      forums = [];
      groups = [];
      readyPackage = null;
      packageProgress = 0;
      cursor = null;
      error = null;
      changed();
      unawaited(load());
    }
  }

  Future<ChartMap> request(
    String path, {
    String method = 'GET',
    Object? body,
    Map<String, String> headers = const {},
    Uint8List? bytes,
    int? ownerGeneration,
  }) async {
    if (_closed || ownerGeneration != null && ownerGeneration != _generation) {
      throw const AccountError('account_changed');
    }
    final generation = _generation;
    try {
      final result = await _account
          .request(
            method,
            path,
            body: body,
            bytes: bytes,
            headers: {
              if (method != 'GET') 'Idempotency-Key': 'admin-${chartUuid()}',
              ...headers,
            },
          )
          .timeout(const Duration(seconds: 30));
      if (_closed || generation != _generation) {
        throw const AccountError('account_changed');
      }
      return objectOf(result);
    } on AccountError catch (e) {
      if (const {
        'unauthenticated',
        'forbidden',
        'admin_required',
        'capability_required',
      }.contains(e.code)) {
        _generation++;
        staff = {};
        document = {};
        servers = [];
        forums = [];
        groups = [];
        readyPackage = null;
        packageProgress = 0;
        error = 'forbidden';
        changed();
      }
      rethrow;
    }
  }

  Future<void> load({bool append = false}) async {
    final list = ++_listGeneration;
    loading = true;
    error = null;
    changed();
    try {
      await _account.load();
      _identity = _currentIdentity;
      if (!append) {
        final session = await request('/api/v1/admin/session');
        staff = chartMap(session['session']);
        if (staff['role'] == 'moderator') section = 'appeals';
      }
      final parameters = {
        'limit': '50',
        ...query,
        if (append && cursor != null) 'cursor': cursor!,
        if (const {'reports', 'appeals'}.contains(section) &&
            !query.containsKey('status'))
          'status': 'all',
      };
      parameters.remove('kind');
      ChartMap result;
      if (section == 'overview') {
        final values = await Future.wait([
          request('/api/v1/admin/overview'),
          request('/api/v1/admin/statistics'),
        ]);
        result = {
          ...values[0],
          'statistics': values[1]['statistics'],
          'statisticsGeneratedAt': values[1]['generatedAt'],
          'sessionCounts': values[1]['sessions'],
        };
      } else {
        result = await request(
          Uri(
            path: '/api/v1/admin/${section == 'posts' ? contentKind : section}',
            queryParameters: section == 'forums' ? null : parameters,
          ).toString(),
        );
      }
      if (_closed || list != _listGeneration) return;
      document = append
          ? {
              ...result,
              recordsKey: [...records, ...chartRows(result[recordsKey])],
            }
          : result;
      cursor = result['nextCursor'] as String?;
      if (section == 'forums') {
        forums = chartRows(result['forums'] ?? const []);
        groups = chartRows(result['groups'] ?? const []);
      }
      if (section == 'operations') await loadServers();
    } catch (e) {
      if (!_closed && list == _listGeneration) {
        error = e is AccountError ? e.code : 'loadFailed';
      }
    } finally {
      if (!_closed && list == _listGeneration) {
        loading = false;
        changed();
      }
    }
  }

  Future<void> select(
    String value, {
    Map<String, String> filters = const {},
  }) async {
    if (section == value && filters.isEmpty && query.isEmpty) return;
    if (onNavigate case final navigate?) {
      navigate(
        Uri(
          path: '/admin/$value',
          queryParameters: filters.isEmpty ? null : filters,
        ).toString(),
      );
      return;
    }
    section = value;
    document = {};
    query
      ..clear()
      ..addAll(filters);
    cursor = null;
    await load();
  }

  Future<void> mutate(
    Future<void> Function(AdminRequest request) action, {
    bool reload = true,
  }) async {
    if (busy || staff.isEmpty) return;
    final generation = _generation;
    busy = true;
    error = null;
    changed();
    try {
      await action(
        (
          String path, {
          String method = 'GET',
          Object? body,
          Map<String, String> headers = const {},
          Uint8List? bytes,
        }) => request(
          path,
          method: method,
          body: body,
          headers: headers,
          bytes: bytes,
          ownerGeneration: generation,
        ),
      );
      if (generation == _generation && reload) await load();
    } catch (e) {
      if (!_closed && generation == _generation) {
        error = e is AccountError ? e.code : 'actions.failed';
      }
    } finally {
      if (!_closed) {
        busy = false;
        changed();
      }
    }
  }

  Future<void> role(ChartMap user, String role) => mutate((request) async {
    await request(
      '/api/v1/admin/users/${user['id']}/role',
      method: 'PUT',
      body: {
        'expectedVersion': user['version'],
        'reasonCode': 'admin.dashboard.role',
        'role': role,
      },
    );
  });
  Future<void> removeCreation(String kind, ChartMap record) =>
      mutate((request) async {
        await request(
          '/api/v1/admin/$kind/${record['id']}',
          method: 'DELETE',
          body: {
            'expectedVersion': record['version'],
            'reasonCode': 'admin.dashboard.remove',
          },
        );
      });
  Future<void> restrict(ChartMap user, String kind, int duration) =>
      mutate((request) async {
        await request(
          '/api/v1/admin/users/${user['id']}/restrictions',
          method: 'POST',
          body: {
            'expectedVersion': user['version'],
            'expiresAt': duration > 0
                ? DateTime.now().millisecondsSinceEpoch + duration
                : null,
            'kind': kind,
            'reasonCode': 'admin.dashboard.restrict.$kind',
          },
        );
      });
  Future<void> revokeRestriction(String user, ChartMap row) =>
      mutate((request) async {
        await request(
          '/api/v1/admin/users/$user/restrictions/${row['id']}',
          method: 'DELETE',
          body: {
            'expectedVersion': row['version'],
            'reasonCode': 'admin.dashboard.restriction.revoke',
          },
        );
      });
  Future<void> revokeSessions(ChartMap user) => mutate((request) async {
    await request(
      '/api/v1/admin/users/${user['id']}/session-revocations',
      method: 'POST',
      body: {
        'expectedVersion': user['version'],
        'reasonCode': 'admin.dashboard.sessions',
      },
    );
  });
  Future<void> report(ChartMap row, String status) => mutate((request) async {
    await request(
      '/api/v1/admin/reports/${row['id']}/status',
      method: 'PUT',
      body: {
        'expectedVersion': row['version'],
        'resolutionReasonCode': status == 'reviewing'
            ? null
            : 'admin.dashboard.report.$status',
        'status': status,
      },
    );
  });
  Future<void> appeal(ChartMap row, String decision) => mutate((request) async {
    await request(
      '/api/v1/admin/appeals/${row['id']}/decision',
      method: 'POST',
      body: {
        'decision': decision,
        'expectedVersion': row['version'],
        'reasonCode': 'admin.dashboard.appeal.$decision',
      },
    );
  });
  Future<void> postState(ChartMap row, String action, {bool comment = false}) =>
      mutate((request) async {
        await request(
          '/api/v1/admin/${comment ? 'comments' : 'posts'}/${row['id']}/state',
          method: 'PUT',
          body: {
            'action': action,
            'expectedVersion': row['version'],
            'reasonCode':
                'admin.dashboard.${comment ? 'comment' : 'post'}.$action',
          },
        );
      });
  Future<void> siteSettings(ChartMap settings) => mutate((request) async {
    await request('/api/v1/admin/site-settings', method: 'PUT', body: settings);
  });
  Future<void> loadForums() async {
    final value = await request('/api/v1/admin/forums');
    forums = chartRows(value['forums'] ?? const []);
    groups = chartRows(value['groups'] ?? const []);
    changed();
  }

  Future<void> saveForum(
    ChartMap value, {
    ChartMap? previous,
    bool group = false,
  }) => mutate((request) async {
    final base = '/api/v1/admin/${group ? 'forum-groups' : 'forums'}';
    await request(
      previous == null ? base : '$base/${previous['id']}',
      method: previous == null ? 'POST' : 'PATCH',
      body: previous == null
          ? value
          : {
              'expectedVersion': previous['version'],
              group ? 'group' : 'forum': value,
            },
    );
    await loadForums();
  }, reload: section == 'forums');
  Future<void> movePost(ChartMap post, String forum, String reason) =>
      mutate((request) async {
        await request(
          '/api/v1/admin/forums/move-post',
          method: 'POST',
          body: {
            'postId': '${post['id']}',
            'expectedVersion': post['version'],
            'forumId': forum,
            'reasonCode': reason,
          },
        );
      });
  Future<void> loadServers() async {
    final value = await request('/api/v1/admin/resource-servers');
    servers = chartRows(value['resourceServers'] ?? const []);
    changed();
  }

  Future<void> saveServer(ChartMap value, {ChartMap? previous}) => mutate((
    request,
  ) async {
    final slug = value['slug'];
    await request(
      '/api/v1/admin/resource-servers${previous == null ? '' : '/$slug'}',
      method: previous == null ? 'POST' : 'PUT',
      body: {
        for (final key in ['displayName', 'region', 'status']) key: value[key],
        'expectedVersion': previous?['version'] ?? 0,
        'reasonCode': previous == null
            ? 'admin.dashboard.server.create'
            : 'admin.dashboard.server.update',
        if (previous == null) ...{
          'slug': slug,
          'resourcePrefix': 'servers/$slug',
        },
      },
    );
    await loadServers();
  });
  Future<void> dispatch(
    String server,
    String kind,
    String reference,
    bool ktx2, {
    int version = 0,
  }) => mutate((request) async {
    await request(
      '/api/v1/admin/resource-runs',
      method: 'POST',
      body: {
        'expectedVersion': version,
        'ktx2': ktx2,
        'reasonCode': 'admin.dashboard.resource.$kind',
        'server': server,
        'sourceKind': kind,
        'sourceRef': reference,
      },
    );
  });
  Future<void> uploadPackage(File file, String name, String server) => mutate((
    request,
  ) async {
    packageProgress = 0;
    changed();
    final size = await file.length(),
        hash = (await sha256.bind(file.openRead()).first).toString();
    final created = await request(
      '/api/v1/admin/package-uploads',
      method: 'POST',
      body: {
        'expectedVersion': 0,
        'fileName': name,
        'mediaType': 'application/zip',
        'reasonCode': 'admin.dashboard.package.create',
        'server': server,
        'sha256': hash,
        'size': size,
      },
    );
    final upload = chartMap(created['packageUpload']),
        count = upload['partCount'] as int,
        partSize = upload['partSize'] as int;
    final input = await file.open();
    try {
      for (var part = 1; part <= count; part++) {
        final bytes = await input.read(
          math.min(partSize, size - (part - 1) * partSize),
        );
        await request(
          '/api/v1/admin/package-uploads/${upload['id']}/parts/$part?expectedVersion=${upload['version']}',
          method: 'PUT',
          bytes: bytes,
          headers: {
            'Content-Type': 'application/octet-stream',
            'X-Reason-Code': 'admin.dashboard.package.part',
          },
        );
        packageProgress = part / count * .94;
        changed();
      }
    } finally {
      await input.close();
    }
    final completed = await request(
      '/api/v1/admin/package-uploads/${upload['id']}/complete',
      method: 'POST',
      body: {
        'expectedVersion': upload['version'],
        'reasonCode': 'admin.dashboard.package.complete',
      },
    );
    readyPackage = chartMap(completed['packageUpload']);
    packageProgress = 1;
    changed();
  });
  @override
  void dispose() {
    _closed = true;
    _generation++;
    _listGeneration++;
    _account.removeListener(_accountChanged);
    staff = {};
    document = {};
    super.dispose();
  }
}
