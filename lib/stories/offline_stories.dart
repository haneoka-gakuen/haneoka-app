import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../core/api.dart';
import '../core/app_state.dart';
import '../core/catalog_source.dart';
import '../core/offline_files.dart';
import '../shell/page.dart';
import 'stories.dart';
import 'story_sequence_player.dart';

String _size(int bytes) => bytes >= 1 << 30
    ? '${(bytes / (1 << 30)).toStringAsFixed(2)} GB'
    : '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';

class OfflineStoriesScreen extends StatefulWidget {
  const OfflineStoriesScreen({super.key});
  @override
  State<OfflineStoriesScreen> createState() => _OfflineStoriesScreenState();
}

class _OfflineStoriesScreenState extends State<OfflineStoriesScreen> {
  final library = OfflineFiles.instance;
  String? _server;
  bool _checking = true;
  Object? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_server == null) {
      _server = AppScope.of(context).server == 'jp' ? 'jp' : 'intl';
      unawaited(_check());
    }
  }

  Future<void> _check({bool force = false}) async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      await library.initialize();
      if (mounted) setState(() {});
      await library.check(_server!, force: force);
    } catch (error) {
      _error = error;
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _download({
    String? package,
    bool all = false,
    bool resume = false,
  }) async {
    if (resume) {
      await library.resume(_server!);
    } else {
      await library.download(_server!, package: package, all: all);
    }
    if (mounted && library.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppScope.of(context).text('app.offline.downloadFailed'),
          ),
        ),
      );
    }
  }

  Future<void> _remove([String? package]) async {
    final t = AppScope.of(context).text;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('app.offline.removeConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('common.actions.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('app.offline.remove')),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await library.remove(_server!, package: package);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(t('common.states.error'))));
        }
      }
    }
  }

  Future<void> _play(String id, {bool text = false}) async {
    final lease = library.retain(_server!);
    final snapshot = lease.snapshot;
    final api = HaneokaApi(
      server: _server!,
      eagerRelease: false,
      offlineRelease: snapshot['releaseId'] as String,
      offlineSource: snapshot['sourceId'] as String,
    );
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: RouteSettings(name: '/stories/$id?server=$_server'),
          builder: (_) => CatalogSourceScope(
            api: api,
            child: text
                ? StoryReaderScreen(episode: {'storyKey': id}, api: api)
                : StorySequencePlayer(storyId: id, server: _server, api: api),
          ),
        ),
      );
    } finally {
      api.dispose();
      await lease.release();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppScope.of(context).text;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final server = _server!;
        final snapshot = library.available(server);
        final root = snapshot?['root'] as Map?;
        final busy = library.running;
        final saved = library.snapshot(server);
        final packages = [
          ...(root?['packages'] as List? ?? const []).cast<Map>(),
        ];
        final availableIds = packages.map((row) => row['id']).toSet();
        packages.addAll(
          (saved?['root']['packages'] as List? ?? const []).cast<Map>().where(
            (row) =>
                library.downloaded(server, row['id'] as String) &&
                !availableIds.contains(row['id']),
          ),
        );
        return ShellPage(
          title: t('app.offline.title'),
          showBack: true,
          status: SizedBox(
            width: 112,
            child: busy && library.activeServer == server
                ? Text(
                    '${_size(library.completedBytes)} / ${_size(library.totalBytes)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : Text(
                    root == null ? '' : _size(root['totalBytes'] as int),
                    maxLines: 1,
                  ),
          ),
          actions: [
            BarAction(
              icon: Symbols.refresh_rounded,
              label: t('app.offline.check'),
              onPressed: busy || _checking ? null : () => _check(force: true),
            ),
            if (busy)
              BarAction(
                icon: Symbols.pause_rounded,
                label: t('app.offline.pause'),
                onPressed: library.pause,
              )
            else if (library.resumable(server))
              BarAction(
                icon: Symbols.download_rounded,
                label: t('app.offline.resume'),
                onPressed: () => _download(resume: true),
              ),
            if (saved != null || library.resumable(server))
              BarAction(
                icon: Symbols.delete_outline_rounded,
                label: t('app.offline.remove'),
                onPressed: busy ? null : _remove,
              ),
          ],
          body: Column(
            children: [
              SizedBox(
                height: 4,
                child: _checking
                    ? const LinearProgressIndicator()
                    : busy && library.activeServer == server
                    ? LinearProgressIndicator(
                        value: library.totalBytes == 0
                            ? null
                            : library.completedBytes / library.totalBytes,
                      )
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    DropdownButton<String>(
                      value: server,
                      items: const [
                        DropdownMenuItem(value: 'jp', child: Text('JP')),
                        DropdownMenuItem(value: 'intl', child: Text('INTL')),
                      ],
                      onChanged: busy
                          ? null
                          : (value) {
                              setState(() => _server = value!);
                              unawaited(_check());
                            },
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: busy || root == null
                            ? null
                            : () => _download(all: true),
                        icon: Icon(
                          library.updateAvailable(server)
                              ? Symbols.system_update_alt_rounded
                              : Symbols.download_rounded,
                        ),
                        label: Text(
                          t(
                            library.updateAvailable(server)
                                ? 'app.offline.update'
                                : 'app.offline.downloadAll',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: root == null
                    ? Center(
                        child: _error == null
                            ? const CircularProgressIndicator()
                            : TextButton.icon(
                                onPressed: () => _check(force: true),
                                icon: const Icon(Symbols.refresh_rounded),
                                label: Text(t('app.offline.loadFailed')),
                              ),
                      )
                    : ListView.builder(
                        itemCount: packages.length,
                        itemBuilder: (context, index) {
                          final package = packages[index],
                              id = package['id'] as String;
                          final downloaded = library.downloaded(server, id);
                          final savedPackage =
                              ((saved?['root']['packages'] as List? ?? const [])
                                      .cast<Map>())
                                  .where((row) => row['id'] == id)
                                  .firstOrNull;
                          final episodes =
                              ((downloaded
                                              ? savedPackage
                                              : package)?['episodes']
                                          as List? ??
                                      const [])
                                  .cast<Map>();
                          return ExpansionTile(
                            key: ValueKey((server, id, downloaded)),
                            leading: Icon(
                              downloaded
                                  ? Symbols.download_done_rounded
                                  : Symbols.auto_stories_rounded,
                            ),
                            title: Text(t.text(package['title'])),
                            subtitle: Text(
                              '${episodes.length} · ${_size(package['bytes'] as int)}',
                            ),
                            trailing: IconButton(
                              tooltip: t(
                                downloaded
                                    ? 'app.offline.remove'
                                    : 'app.offline.download',
                              ),
                              onPressed: busy
                                  ? null
                                  : downloaded
                                  ? () => _remove(id)
                                  : () => _download(package: id),
                              icon: Icon(
                                downloaded
                                    ? Symbols.delete_outline_rounded
                                    : Symbols.download_rounded,
                              ),
                            ),
                            children: [
                              for (final episode in episodes)
                                ListTile(
                                  title: Text(t.text(episode['title'])),
                                  onTap: downloaded
                                      ? () => _play(episode['id'] as String)
                                      : null,
                                  trailing: downloaded
                                      ? IconButton(
                                          tooltip: t('app.offline.text'),
                                          icon: const Icon(
                                            Symbols.article_rounded,
                                          ),
                                          onPressed: () => _play(
                                            episode['id'] as String,
                                            text: true,
                                          ),
                                        )
                                      : null,
                                ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
