import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../chart_editor/project.dart';
import '../core/app_state.dart';
import '../ui/detail.dart';
import 'controller.dart';
import 'forms.dart';

class AdminResources extends StatefulWidget {
  const AdminResources({super.key, required this.controller});
  final AdminController controller;
  @override
  State<AdminResources> createState() => _AdminResourcesState();
}

class _AdminResourcesState extends State<AdminResources> {
  String? _server;
  Future<ChartMap>? _sources;
  int _sourcesGeneration = 0;
  PlatformFile? _file;
  bool _package = false, _ktx2 = false;
  final _reference = TextEditingController();
  final _referenceFocus = FocusNode();
  final _form = GlobalKey<FormState>();
  AdminController get c => widget.controller;
  String t(String key) => AppScope.of(context).text('admin.page.$key');

  @override
  void didUpdateWidget(AdminResources oldWidget) {
    super.didUpdateWidget(oldWidget);
    final active = c.servers.where((s) => s['status'] == 'active');
    if (_server != null && !active.any((s) => s['slug'] == _server)) {
      _server = null;
      _sources = null;
    }
  }

  void _source(String server) {
    _server = server;
    _reference.clear();
    _sourcesGeneration++;
    _sources = c.request(
      Uri(
        path: '/api/v1/admin/resource-sources',
        queryParameters: {'server': server},
      ).toString(),
    );
  }

  Future<void> _serverForm([ChartMap? row]) async {
    var previous = row;
    await editAdminFields(
      context,
      title: t(row == null ? 'resources.create' : 'resources.servers'),
      initial:
          row ??
          {
            'slug': '',
            'displayName': '',
            'region': 'global',
            'status': 'draft',
          },
      fields: [
        if (row == null)
          AdminField('slug', t('resources.slug'), required: true),
        AdminField('displayName', t('resources.displayName'), required: true),
        AdminField(
          'region',
          t('resources.region'),
          options: {
            for (final region in ['global', 'jp', 'en', 'tw', 'cn', 'kr'])
              region: region,
          },
        ),
        if (row != null)
          AdminField(
            'status',
            t('resources.status'),
            options: {
              for (final state in ['active', 'draft', 'retired'])
                state: t('values.$state'),
            },
          ),
      ],
      save: (value) async {
        await c.saveServer(value, previous: previous);
        return c.error == null;
      },
      reload: row == null
          ? null
          : () async {
              await c.loadServers();
              previous = c.servers
                  .where((s) => s['slug'] == row['slug'])
                  .firstOrNull;
              return previous;
            },
    );
  }

  Future<void> _pick() async {
    final selected = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['apk', 'apks', 'xapk'],
    );
    if (mounted && selected.isNotEmpty) {
      setState(() => _file = selected.single);
    }
  }

  @override
  void dispose() {
    _reference.dispose();
    _referenceFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = c.servers.where((s) => s['status'] == 'active').toList();
    if (_server == null && active.isNotEmpty) {
      _source('${active.first['slug']}');
    }
    final ready = c.readyPackage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailSection(
          icon: Symbols.cloud_sync_rounded,
          title: t('resources.title'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DetailFold(
                title: t('resources.servers'),
                child: Column(
                  children: [
                    for (final server in c.servers)
                      ListTile(
                        title: Text('${server['displayName']}'),
                        subtitle: Text(
                          '${server['slug']} / ${server['region']}',
                        ),
                        trailing: Text(t('values.${server['status']}')),
                        onTap: c.busy ? null : () => _serverForm(server),
                      ),
                    OutlinedButton.icon(
                      onPressed: c.busy ? null : () => _serverForm(),
                      icon: const Icon(Symbols.add_rounded),
                      label: Text(t('resources.create')),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey(_server),
                initialValue: _server,
                decoration: InputDecoration(labelText: t('resources.server')),
                isExpanded: true,
                items: [
                  for (final server in active)
                    DropdownMenuItem(
                      value: '${server['slug']}',
                      child: Text(
                        '${server['displayName']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: c.busy
                    ? null
                    : (value) => setState(() {
                        _package = false;
                        _source(value!);
                      }),
              ),
              const SizedBox(height: 16),
              DetailFold(
                title: t('resources.upload'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton.icon(
                      onPressed: c.busy ? null : _pick,
                      icon: const Icon(Symbols.attach_file_rounded),
                      label: Text(_file?.name ?? t('resources.chooseFile')),
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: c.packageProgress),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed:
                          c.busy || _server == null || _file?.path == null
                          ? null
                          : () => c.uploadPackage(
                              File(_file!.path!),
                              _file!.name,
                              _server!,
                            ),
                      child: Text(t('resources.upload')),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      t('resources.sourceTitle'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    if (ready != null)
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: _package,
                        title: Text(t('resources.file')),
                        subtitle: Text(
                          '${ready['fileName']} / ${ready['server']}',
                        ),
                        onChanged: c.busy
                            ? null
                            : (value) => setState(() => _package = value),
                      ),
                    if (!_package)
                      FutureBuilder<ChartMap>(
                        future: _sources,
                        builder: (context, snapshot) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Autocomplete<String>(
                              key: ValueKey(_sourcesGeneration),
                              textEditingController: _reference,
                              focusNode: _referenceFocus,
                              optionsBuilder: (value) =>
                                  chartRows(
                                        snapshot.data?['resourceSources'] ??
                                            const [],
                                      )
                                      .map((r) => '${r['id']}')
                                      .where((id) => id.contains(value.text)),
                              fieldViewBuilder:
                                  (context, controller, focus, submit) =>
                                      TextFormField(
                                        controller: controller,
                                        focusNode: focus,
                                        decoration: InputDecoration(
                                          labelText: t('resources.sourceId'),
                                        ),
                                        validator: (value) =>
                                            value == null ||
                                                value.trim().isEmpty
                                            ? t('resources.sourceId')
                                            : null,
                                        onFieldSubmitted: (_) => submit(),
                                      ),
                            ),
                            if (snapshot.hasError)
                              TextButton.icon(
                                onPressed: () =>
                                    setState(() => _source(_server!)),
                                icon: const Icon(Symbols.refresh_rounded),
                                label: Text(t('retry')),
                              ),
                          ],
                        ),
                      ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('KTX2'),
                      value: _ktx2,
                      onChanged: c.busy
                          ? null
                          : (v) => setState(() => _ktx2 = v!),
                    ),
                    FilledButton(
                      onPressed: c.busy || _server == null
                          ? null
                          : () {
                              if (!_form.currentState!.validate()) return;
                              c.dispatch(
                                _package ? '${ready!['server']}' : _server!,
                                _package ? 'package' : 'github',
                                _package
                                    ? '${ready!['id']}'
                                    : _reference.text.trim(),
                                _ktx2,
                                version: _package
                                    ? (ready!['version'] as num).toInt()
                                    : 0,
                              );
                            },
                      child: Text(t('resources.trigger')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
