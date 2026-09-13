import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../main.dart';
import '../../services/fence_subscription.dart';
import '../../services/geofence.dart';
import '../../state/app_controller.dart';

/// 电子围栏订阅管理页（对齐 CU fence_subscription_page.dart）
class FenceSubscriptionScreen extends StatefulWidget {
  const FenceSubscriptionScreen({super.key});

  @override
  State<FenceSubscriptionScreen> createState() => _FenceSubscriptionScreenState();
}

class _FenceSubscriptionScreenState extends State<FenceSubscriptionScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<FenceSubscriptionInfo> _subscribed = [];
  List<FenceSubscriptionInfo> _created = [];
  bool _loading = true;
  String? _error;

  AppController? _app;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<String> _chipId() async {
    final app = _app ??= AppScope.instance.controller;
    final device = app.deviceInfo.chipId;
    if (device.isNotEmpty) return device;
    final backup = await app.storage.getBackupChipId();
    return backup;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final chipId = await _chipId();
    if (chipId.isEmpty) {
      setState(() {
        _loading = false;
        _error = '无法获取设备标识，请先连接设备';
      });
      return;
    }
    try {
      final results = await Future.wait([
        FenceSubscriptionApi.fetchSubscribed(chipId),
        FenceSubscriptionApi.fetchCreated(chipId),
      ]);
      if (!mounted) return;
      setState(() {
        _subscribed = results[0];
        _created = results[1];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
          content: Text(msg), duration: const Duration(seconds: 4)));
  }

  Future<void> _showCreateDialog() async {
    final created = await showDialog<String>(
      context: context,
      builder: (ctx) => const _CreateSubscriptionDialog(),
    );
    if (created != null && mounted) {
      _toast('订阅创建成功，订阅码: $created');
      await _load();
    }
  }

  Future<void> _showJoinDialog() async {
    final joined = await showDialog<bool>(
      context: context,
      builder: (ctx) => const _JoinSubscriptionDialog(),
    );
    if (joined == true && mounted) {
      _toast('订阅成功');
      await _load();
    }
  }

  Future<void> _importFences(FenceSubscriptionInfo sub) async {
    final chipId = await _chipId();
    if (chipId.isEmpty) {
      _toast('无法获取设备标识，请先连接设备');
      return;
    }
    String? dataPassword;
    if (sub.isAuthorized) {
      dataPassword = await _promptDataPassword(sub);
      if (dataPassword == null) return;
    }
    if (!mounted) return;
    try {
      final fences = await FenceSubscriptionApi.fetchFences(
          code: sub.code, chipId: chipId, dataPassword: dataPassword ?? '');
      if (!mounted) return;
      final provider = (_app ??= AppScope.instance.controller).geofence;
      var imported = 0;
      for (final fenceJson in fences) {
        final fence = _toLocalFence(fenceJson);
        if (fence != null) {
          provider.addFence(fence);
          imported++;
        }
      }
      if (!mounted) return;
      _toast('已导入 $imported 个围栏到本地');
    } catch (e) {
      if (!mounted) return;
      _toast('导入失败: $e');
    }
  }

  Geofence? _toLocalFence(Map<String, dynamic> json) {
    try {
      final fence = Geofence.fromJson(json);
      return Geofence(
        id: const Uuid().v4(),
        name: fence.name,
        label: fence.label,
        slotNumber: fence.slotNumber,
        enabled: true,
        points: List.from(fence.points),
        colorValue: fence.colorValue,
        cardLibraryMode: fence.cardLibraryMode,
        icCardId: fence.icCardId,
        idCardId: fence.idCardId,
        rollingCode: fence.rollingCode,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _promptDataPassword(FenceSubscriptionInfo sub) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('导入「${sub.name}」的围栏'),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '数据密码',
            helperText: '授权订阅，请输入数据密码',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _leaveSubscription(FenceSubscriptionInfo sub) async {
    final chipId = await _chipId();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消订阅'),
        content: Text('确定取消订阅「${sub.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('取消订阅'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await FenceSubscriptionApi.leave(sub.code, chipId);
      if (!mounted) return;
      _toast('已取消订阅');
      await _load();
    } catch (e) {
      if (!mounted) return;
      _toast('操作失败: $e');
    }
  }

  Future<void> _deleteSubscription(FenceSubscriptionInfo sub) async {
    final chipId = await _chipId();
    if (!mounted) return;
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除订阅'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确定删除「${sub.name}」吗？此操作不可撤销。'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '管理密码',
                helperText: '请输入订阅的管理密码',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await FenceSubscriptionApi.delete(sub.code, chipId, controller.text.trim());
      if (!mounted) return;
      _toast('订阅已删除');
      await _load();
    } catch (e) {
      if (!mounted) return;
      _toast('删除失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('围栏订阅'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          TabBar(
            controller: _tabController,
            labelColor: colorScheme.primary,
            tabs: const [
              Tab(text: '我订阅的'),
              Tab(text: '我创建的'),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildSubscribedTab(),
                _buildCreatedTab(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _showJoinDialog,
                  icon: const Icon(Icons.add_link),
                  label: const Text('加入订阅'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _showCreateDialog,
                  icon: const Icon(Icons.add),
                  label: const Text('添加订阅'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubscribedTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _buildError();
    if (_subscribed.isEmpty) {
      return _buildEmpty('暂无订阅，点击下方"加入订阅"');
    }
    return ListView.separated(
      itemCount: _subscribed.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
      itemBuilder: (context, index) {
        final sub = _subscribed[index];
        return _SubscriptionTile(
          sub: sub,
          onImport: () => _importFences(sub),
          onLeave: () => _leaveSubscription(sub),
        );
      },
    );
  }

  Widget _buildCreatedTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _buildError();
    if (_created.isEmpty) {
      return _buildEmpty('还没有创建订阅，点击下方"添加订阅"');
    }
    return ListView.separated(
      itemCount: _created.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
      itemBuilder: (context, index) {
        final sub = _created[index];
        return _SubscriptionTile(
          sub: sub,
          showCode: true,
          onDelete: () => _deleteSubscription(sub),
        );
      },
    );
  }

  Widget _buildEmpty(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.fence, size: 40, color: Colors.grey.shade400),
          const SizedBox(height: 8),
          Text(message, style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off, size: 40, color: Colors.grey.shade400),
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(fontSize: 13), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionTile extends StatelessWidget {
  final FenceSubscriptionInfo sub;
  final bool showCode;
  final VoidCallback? onImport;
  final VoidCallback? onLeave;
  final VoidCallback? onDelete;

  const _SubscriptionTile({
    required this.sub,
    this.showCode = false,
    this.onImport,
    this.onLeave,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final modeLabel = sub.isAuthorized ? '授权订阅' : '开放订阅';

    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: sub.isAuthorized
            ? colorScheme.tertiary
            : colorScheme.primary,
        child: Icon(
          sub.isAuthorized ? Icons.verified_user : Icons.public,
          size: 18,
          color: Colors.white,
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              sub.name,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              modeLabel,
              style: TextStyle(
                fontSize: 10,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showCode)
            Text('订阅码: ${sub.code}', style: const TextStyle(fontSize: 12)),
          if (sub.description.isNotEmpty)
            Text(sub.description, style: const TextStyle(fontSize: 12)),
          Text(
            '${sub.fenceCount} 个围栏 · ${sub.memberCount} 位订阅者',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onImport != null)
            IconButton(
              icon: const Icon(Icons.download_outlined, size: 20),
              onPressed: onImport,
              tooltip: '导入围栏',
            ),
          if (onLeave != null)
            IconButton(
              icon: const Icon(Icons.link_off, size: 20, color: Colors.red),
              onPressed: onLeave,
              tooltip: '取消订阅',
            ),
          if (onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
              onPressed: onDelete,
              tooltip: '删除',
            ),
        ],
      ),
    );
  }
}

class _JoinSubscriptionDialog extends StatefulWidget {
  const _JoinSubscriptionDialog();

  @override
  State<_JoinSubscriptionDialog> createState() => _JoinSubscriptionDialogState();
}

class _JoinSubscriptionDialogState extends State<_JoinSubscriptionDialog> {
  final _codeController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('加入订阅'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _codeController,
            decoration: const InputDecoration(
              labelText: '订阅码',
              helperText: '输入创建者分享的订阅码',
            ),
            textCapitalization: TextCapitalization.characters,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _loading ? null : _next,
          child: _loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('下一步'),
        ),
      ],
    );
  }

  Future<String?> _chipId() async {
    final app = AppScope.instance.controller;
    final device = app.deviceInfo.chipId;
    if (device.isNotEmpty) return device;
    final backup = await app.storage.getBackupChipId();
    return backup.isEmpty ? null : backup;
  }

  Future<void> _next() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() => _error = '请输入订阅码');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await FenceSubscriptionApi.fetchDetail(code);
      if (!mounted) return;
      if (detail.isAuthorized) {
        final joined = await showDialog<bool>(
          context: context,
          builder: (ctx) => _AuthorizedJoinDialog(code: code, detail: detail),
        );
        if (mounted) Navigator.pop(context, joined == true);
      } else {
        final chipId = await _chipId();
        if (chipId == null || chipId.isEmpty) {
          setState(() => _loading = false);
          _error = '无法获取设备标识，请先连接设备';
          return;
        }
        await FenceSubscriptionApi.join(code: code, chipId: chipId);
        if (!mounted) return;
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }
}

class _AuthorizedJoinDialog extends StatefulWidget {
  final String code;
  final FenceSubscriptionInfo detail;

  const _AuthorizedJoinDialog({required this.code, required this.detail});

  @override
  State<_AuthorizedJoinDialog> createState() => _AuthorizedJoinDialogState();
}

class _AuthorizedJoinDialogState extends State<_AuthorizedJoinDialog> {
  final _dataPasswordController = TextEditingController();
  final _adminPasswordController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _dataPasswordController.dispose();
    _adminPasswordController.dispose();
    super.dispose();
  }

  Future<String?> _chipId() async {
    final app = AppScope.instance.controller;
    final device = app.deviceInfo.chipId;
    if (device.isNotEmpty) return device;
    final backup = await app.storage.getBackupChipId();
    return backup.isEmpty ? null : backup;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('加入「${widget.detail.name}」'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('授权订阅', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _dataPasswordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '数据密码',
                helperText: '至少6个字符',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _adminPasswordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '管理密码',
                helperText: '由创建者提供',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _loading ? null : _join,
          child: _loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('订阅'),
        ),
      ],
    );
  }

  Future<void> _join() async {
    final dataPassword = _dataPasswordController.text;
    final adminPassword = _adminPasswordController.text;
    if (dataPassword.length < 6) {
      setState(() => _error = '数据密码至少6个字符');
      return;
    }
    if (adminPassword.length < 6) {
      setState(() => _error = '管理密码至少6个字符');
      return;
    }
    final chipId = await _chipId();
    if (chipId == null || chipId.isEmpty) {
      setState(() => _error = '无法获取设备标识，请先连接设备');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await FenceSubscriptionApi.join(
        code: widget.code,
        chipId: chipId,
        dataPassword: dataPassword,
        adminPassword: adminPassword,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }
}

class _CreateSubscriptionDialog extends StatefulWidget {
  const _CreateSubscriptionDialog();

  @override
  State<_CreateSubscriptionDialog> createState() => _CreateSubscriptionDialogState();
}

class _CreateSubscriptionDialogState extends State<_CreateSubscriptionDialog> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _adminPasswordController = TextEditingController();
  final _dataPasswordController = TextEditingController();
  bool _showAdminPassword = false;
  bool _showDataPassword = false;
  bool _authorizedMode = false;
  bool _loading = false;
  String? _error;
  List<Geofence> _allFences = [];
  Set<Geofence> _selectedFences = {};

  @override
  void initState() {
    super.initState();
    final provider = AppScope.instance.controller.geofence;
    _allFences = provider.fences;
    _selectedFences = provider.fences.toSet();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _adminPasswordController.dispose();
    _dataPasswordController.dispose();
    super.dispose();
  }

  Widget _buildPasswordField({
    required String label,
    required TextEditingController controller,
    required bool obscure,
    required VoidCallback onToggle,
    required String helperText,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        suffixIcon: IconButton(
          icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
          onPressed: onToggle,
        ),
      ),
    );
  }

  Future<String?> _chipId() async {
    final app = AppScope.instance.controller;
    final device = app.deviceInfo.chipId;
    if (device.isNotEmpty) return device;
    final backup = await app.storage.getBackupChipId();
    return backup.isEmpty ? null : backup;
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    final adminPassword = _adminPasswordController.text;
    final dataPassword = _dataPasswordController.text;
    if (name.isEmpty) {
      setState(() => _error = '请输入订阅名称');
      return;
    }
    if (adminPassword.length < 6) {
      setState(() => _error = '管理密码至少6个字符');
      return;
    }
    if (_authorizedMode && dataPassword.length < 6) {
      setState(() => _error = '数据密码至少6个字符');
      return;
    }
    if (_selectedFences.isEmpty) {
      setState(() => _error = '请至少选择一个围栏');
      return;
    }
    final chipId = await _chipId();
    if (chipId == null || chipId.isEmpty) {
      setState(() => _error = '无法获取设备标识，请先连接设备');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final code = await FenceSubscriptionApi.create(
        name: name,
        description: _descriptionController.text.trim(),
        mode: _authorizedMode ? 'authorized' : 'open',
        adminPassword: adminPassword,
        dataPassword: dataPassword,
        chipId: chipId,
        fences: _selectedFences.map((f) => f.toJson()).toList(),
      );
      if (!mounted) return;
      Navigator.pop(context, code);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('创建订阅'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: '订阅名称'),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(labelText: '描述（可选）'),
            ),
            const SizedBox(height: 12),
            _buildPasswordField(
              label: '管理密码',
              controller: _adminPasswordController,
              obscure: _showAdminPassword,
              onToggle: () => setState(() => _showAdminPassword = !_showAdminPassword),
              helperText: '至少6个字符，删除订阅时使用',
            ),
            const SizedBox(height: 4),
            if (_authorizedMode)
              _buildPasswordField(
                label: '数据密码',
                controller: _dataPasswordController,
                obscure: _showDataPassword,
                onToggle: () => setState(() => _showDataPassword = !_showDataPassword),
                helperText: '至少6个字符，订阅者加入时使用',
              ),
            const SizedBox(height: 16),
            const Text('订阅模式', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                border: Border.all(color: colorScheme.outline),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _ModeSegment(
                      label: '开放订阅',
                      selected: !_authorizedMode,
                      onTap: () => setState(() => _authorizedMode = false),
                    ),
                  ),
                  Expanded(
                    child: _ModeSegment(
                      label: '授权订阅',
                      selected: _authorizedMode,
                      icon: Icons.check,
                      onTap: () => setState(() => _authorizedMode = true),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '选择要订阅的围栏（${_selectedFences.length} / ${_allFences.length}）',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            if (_allFences.isEmpty)
              Text('暂无围栏数据', style: TextStyle(fontSize: 13, color: Colors.grey.shade500))
            else
              ..._allFences.map((fence) => CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    title: Text(
                      '${fence.name}${fence.label.isNotEmpty ? ' (${fence.label})' : ''}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text('槽位 ${fence.slotNumber}', style: const TextStyle(fontSize: 11)),
                    value: _selectedFences.contains(fence),
                    onChanged: (checked) {
                      setState(() {
                        if (checked == true) {
                          _selectedFences.add(fence);
                        } else {
                          _selectedFences.remove(fence);
                        }
                      });
                    },
                  )),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _loading ? null : _create,
          child: _loading
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('创建'),
        ),
      ],
    );
  }
}

class _ModeSegment extends StatelessWidget {
  final String label;
  final bool selected;
  final IconData? icon;
  final VoidCallback onTap;

  const _ModeSegment({
    required this.label,
    required this.selected,
    this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? colorScheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null && selected) ...[
              Icon(icon, size: 16, color: selected ? colorScheme.onPrimary : colorScheme.onSurface),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                color: selected ? colorScheme.onPrimary : colorScheme.onSurface,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}