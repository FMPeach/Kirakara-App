part of '../../screens/controller_screen.dart';

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({
    required this.settingsService,
    required this.assetCache,
    required this.lanServer,
  });

  final SettingsService settingsService;
  final PlaybackAssetCache assetCache;
  final LanServer lanServer;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final TextEditingController _announcementController;
  late Future<int> _cacheSize;
  bool _savingAnnouncement = false;
  bool _startingLan = false;

  @override
  void initState() {
    super.initState();
    _announcementController = TextEditingController(
      text: widget.settingsService.customAnnouncement,
    );
    _cacheSize = _computeCacheSize();
  }

  @override
  void dispose() {
    _announcementController.dispose();
    super.dispose();
  }

  Future<int> _computeCacheSize() async {
    final path = widget.assetCache.cacheDirectoryPath;
    return await compute(_calcCacheSize, path);
  }

  void _refreshCacheSize() {
    setState(() {
      _cacheSize = _computeCacheSize();
    });
  }

  Future<void> _saveAnnouncement() async {
    setState(() => _savingAnnouncement = true);
    await widget.settingsService
        .setCustomAnnouncement(_announcementController.text);
    if (mounted) setState(() => _savingAnnouncement = false);
  }

  Future<void> _startLanServer() async {
    setState(() => _startingLan = true);
    try {
      await widget.lanServer.start();
    } finally {
      if (mounted) setState(() => _startingLan = false);
    }
  }

  bool _pickingCacheDirectory = false;

  Future<void> _pickCacheDirectory() async {
    if (_pickingCacheDirectory) return;
    setState(() => _pickingCacheDirectory = true);
    try {
      final selected = await FilePicker.getDirectoryPath(
        dialogTitle: '选择缓存目录',
        initialDirectory: widget.settingsService.cacheDirectoryPath,
      );
      if (!mounted) return;
      if (selected == null || selected.trim().isEmpty) return;
      await widget.settingsService.setCacheDirectoryPath(selected);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('缓存目录已更改，重启应用后生效'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _pickingCacheDirectory = false);
    }
  }

  Widget _buildAnnouncementSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _SectionHeader(title: '报幕文字', icon: Icons.campaign_outlined),
      const SizedBox(height: 8),
      TextField(
        controller: _announcementController,
        maxLength: 120,
        maxLines: 2,
        style: const TextStyle(color: KiraColors.cream),
        decoration: const InputDecoration(
          hintText: '留空则不显示自定义文字',
          hintStyle: TextStyle(color: KiraColors.muted),
          border: OutlineInputBorder(),
          filled: true,
          fillColor: KiraColors.surface2,
          counterStyle: TextStyle(color: KiraColors.muted),
        ),
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton(
          onPressed: _savingAnnouncement ? null : _saveAnnouncement,
          style: FilledButton.styleFrom(
            backgroundColor: KiraColors.surface2,
            foregroundColor: KiraColors.cream,
          ),
          child: _savingAnnouncement
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: KiraColors.cream))
              : const Text('应用'),
        ),
      ),
    ]);
  }

  Widget _buildLanSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _SectionHeader(title: '手机点歌服务', icon: Icons.router_outlined),
      const SizedBox(height: 4),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          widget.lanServer.isRunning ? '已启动' : '未启动',
          style: const TextStyle(
              color: KiraColors.cream, fontWeight: FontWeight.w700),
        ),
        subtitle: widget.lanServer.isRunning
            ? Text(widget.lanServer.localUri?.toString() ?? '',
                style: const TextStyle(color: KiraColors.teal, fontSize: 12))
            : null,
        trailing: widget.lanServer.isRunning
            ? const Icon(Icons.check_circle, color: KiraColors.teal)
            : TextButton(
                onPressed: _startingLan ? null : _startLanServer,
                child: _startingLan
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('启动',
                        style: TextStyle(color: KiraColors.amber)),
              ),
      ),
    ]);
  }

  Widget _buildCacheSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _SectionHeader(title: '媒体缓存', icon: Icons.storage_outlined),
      const SizedBox(height: 4),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('队列预缓存范围',
            style: TextStyle(
                color: KiraColors.muted, fontWeight: FontWeight.w700)),
        trailing: SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, label: Text('1 首')),
            ButtonSegment(value: 2, label: Text('2 首')),
            ButtonSegment(value: 3, label: Text('3 首')),
          ],
          selected: {widget.settingsService.prefetchLookahead},
          showSelectedIcon: false,
          onSelectionChanged: (v) async {
            await widget.settingsService.setPrefetchLookahead(v.first);
            if (mounted) setState(() {});
          },
        ),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('缓存用量',
            style: TextStyle(
                color: KiraColors.muted, fontWeight: FontWeight.w700)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          FutureBuilder<int>(
            future: _cacheSize,
            builder: (context, snapshot) => Text(
              snapshot.hasData ? _fmtBytes(snapshot.data!) : '计算中…',
              style: const TextStyle(
                  color: KiraColors.cream, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '刷新',
            onPressed: _refreshCacheSize,
            icon: const Icon(Icons.refresh, size: 20, color: KiraColors.muted),
          ),
        ]),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('缓存目录',
            style: TextStyle(
                color: KiraColors.muted, fontWeight: FontWeight.w700)),
        subtitle: Text(
          widget.settingsService.cacheDirectoryPath,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: KiraColors.muted, fontSize: 11),
        ),
        trailing: FilledButton(
          onPressed: _pickingCacheDirectory ? null : _pickCacheDirectory,
          style: FilledButton.styleFrom(
            backgroundColor: KiraColors.surface2,
            foregroundColor: KiraColors.cream,
          ),
          child: _pickingCacheDirectory
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: KiraColors.cream))
              : const Text('更改…'),
        ),
      ),
      const ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('退出应用自动清理',
            style: TextStyle(
                color: KiraColors.muted, fontWeight: FontWeight.w700)),
        trailing: Icon(Icons.check_circle_outline, color: KiraColors.teal),
      ),
    ]);
  }

  Widget _buildCastSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _SectionHeader(title: '投屏', icon: Icons.cast_outlined),
      const SizedBox(height: 4),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text(
          '深度搜索（慎用）',
          style: TextStyle(
            color: KiraColors.cream,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: const Text(
          '搜索 DLNA 设备时额外探测固定网络范围，可能延长搜索时间',
          style: TextStyle(color: KiraColors.muted, fontSize: 11),
        ),
        trailing: Switch(
          key: const ValueKey('dlna-deep-search-switch'),
          value: widget.settingsService.dlnaDeepSearchEnabled,
          onChanged: (enabled) async {
            await widget.settingsService.setDlnaDeepSearchEnabled(enabled);
            if (mounted) setState(() {});
          },
          activeThumbColor: Colors.white,
          activeTrackColor: KiraColors.red,
          inactiveThumbColor: const Color(0xffbfc0c6),
          inactiveTrackColor: const Color(0xff303137),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xff17181c),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: KiraColors.lineStrong),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Expanded(
                  child: Text('设置',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: KiraColors.cream,
                          fontSize: 28,
                          fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: KiraColors.cream),
                ),
              ]),
              const SizedBox(height: 18),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildAnnouncementSection(),
                      const Divider(height: 32, color: KiraColors.line),
                      _buildLanSection(),
                      const Divider(height: 32, color: KiraColors.line),
                      _buildCastSection(),
                      const Divider(height: 32, color: KiraColors.line),
                      _buildCacheSection(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.icon});
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        Icon(icon, size: 20, color: KiraColors.amber),
        const SizedBox(width: 8),
        Text(title,
            style: const TextStyle(
                color: KiraColors.amber,
                fontSize: 13,
                fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

int _calcCacheSize(String path) {
  var total = 0;
  final dir = Directory(path);
  if (!dir.existsSync()) return 0;
  for (final e in dir.listSync(recursive: true)) {
    if (e is File) total += e.lengthSync();
  }
  return total;
}
