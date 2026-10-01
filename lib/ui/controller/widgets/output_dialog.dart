part of '../../screens/controller_screen.dart';

class _OutputDialog extends StatefulWidget {
  const _OutputDialog({
    required this.displayManager,
    required this.castService,
    required this.settingsService,
    required this.onDualChanged,
    required this.onCastChanged,
    required this.onDisplaySelected,
    required this.onRefreshDisplays,
    required this.onCastDevicePressed,
  });

  final DisplayManager displayManager;
  final CastService castService;
  final SettingsService settingsService;
  final Future<void> Function(bool enabled) onDualChanged;
  final Future<void> Function(bool enabled) onCastChanged;
  final Future<void> Function(DisplayInfo display) onDisplaySelected;
  final Future<void> Function() onRefreshDisplays;
  final Future<void> Function(DlnaDevice device) onCastDevicePressed;

  @override
  State<_OutputDialog> createState() => _OutputDialogState();
}

class _OutputDialogState extends State<_OutputDialog> {
  bool _busy = false;
  bool _refreshingDisplays = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('显示输出操作失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshDisplays() async {
    if (_refreshingDisplays) return;
    setState(() => _refreshingDisplays = true);
    try {
      await widget.onRefreshDisplays();
    } finally {
      if (mounted) setState(() => _refreshingDisplays = false);
    }
  }

  Future<void> _showManualRendererDialog() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => const _ManualDlnaRendererDialog(),
    );
    if (!mounted || value == null) return;
    await _run(() async {
      final device = await widget.castService.addManualRenderer(value);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已添加 DLNA 设备：${device.friendlyName}')),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.displayManager,
        widget.castService,
      ]),
      builder: (context, _) {
        final dualActive = widget.displayManager.mode == DisplayMode.dualScreen;
        final castActive = widget.castService.isEnabled;
        return Dialog(
          backgroundColor: const Color(0xff1b1c20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: KiraColors.lineStrong),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                // Device lists (esp. many DLNA receivers like macast) can
                // exceed the dialog height when both details are expanded.
                // Keep the header fixed and let the mode sections scroll.
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _OutputModeSection(
                          icon: Icons.connected_tv_outlined,
                          title: '双屏异显',
                          active: dualActive,
                          enabled: !_busy &&
                              (dualActive ||
                                  widget
                                      .displayManager.hasPhysicalStageDisplay),
                          onChanged: (value) => _run(
                            () => widget.onDualChanged(value),
                          ),
                          detail: dualActive ? _buildDisplayDetail() : null,
                        ),
                        const Divider(height: 1, color: KiraColors.line),
                        _OutputModeSection(
                          icon: Icons.cast,
                          title: '无线投屏',
                          active: castActive,
                          enabled: !_busy,
                          onChanged: (value) => _run(
                            () => widget.onCastChanged(value),
                          ),
                          detail: castActive ? _buildCastDetail() : null,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return SizedBox(
      height: 72,
      child: Padding(
        padding: const EdgeInsets.only(left: 24, right: 12),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '显示输出',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: KiraColors.cream,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, color: KiraColors.cream),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDisplayDetail() {
    final displays = widget.displayManager.stageDisplays;
    final selected = widget.displayManager.stageDisplay;
    return _OutputDetail(
      title: _refreshingDisplays ? '正在刷新显示器…' : '选择显示器',
      refreshing: _refreshingDisplays,
      onRefresh: _busy ? null : _refreshDisplays,
      children: [
        if (displays.isEmpty)
          const _OutputEmptyState(text: '未检测到可用的第二显示器')
        else
          for (final display in displays)
            _OutputDeviceRow(
              icon: Icons.desktop_windows_outlined,
              title: display.name,
              subtitle: display.sizeLabel,
              selected: selected?.id == display.id,
              stateLabel: selected?.id == display.id ? '显示中' : null,
              onTap: _busy || selected?.id == display.id
                  ? null
                  : () => _run(
                        () => widget.onDisplaySelected(display),
                      ),
            ),
      ],
    );
  }

  Widget _buildCastDetail() {
    final state = widget.castService.state;
    final connecting = state == CastState.searching;
    final casting = state == CastState.casting;
    final discovering = widget.castService.isDiscovering;
    final activeDevice = widget.castService.activeDevice;
    final devices = widget.castService.devices;
    return _OutputDetail(
      title: discovering ? '正在搜索设备…' : '可用设备',
      refreshing: discovering,
      onRefresh: _busy || connecting || discovering
          ? null
          : () => widget.castService.refreshDevices(
                includePureK: widget.settingsService.dlnaDeepSearchEnabled,
              ),
      children: [
        if (devices.isNotEmpty)
          for (final device in devices)
            _OutputDeviceRow(
              icon: Icons.tv_outlined,
              title: device.friendlyName,
              subtitle: device.detailLabel,
              selected: activeDevice?.id == device.id,
              stateLabel: activeDevice?.id != device.id
                  ? null
                  : connecting
                      ? '连接中'
                      : casting
                          ? '投屏中'
                          : null,
              loading: activeDevice?.id == device.id && connecting,
              onTap: _busy || connecting
                  ? null
                  : () => _run(
                        () => widget.onCastDevicePressed(device),
                      ),
            )
        else
          _OutputEmptyState(
            text: discovering ? '正在搜索设备…' : '未发现可用设备',
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('manual-dlna-add-button'),
              onPressed: _busy || connecting ? null : _showManualRendererDialog,
              icon: const Icon(Icons.add_link),
              label: const Text('手动添加 DLNA 设备'),
            ),
          ),
        ),
        if (widget.castService.lastError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
            child: Text(
              widget.castService.lastError!,
              style: const TextStyle(
                color: Color(0xffff827d),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }
}

class _ManualDlnaRendererDialog extends StatefulWidget {
  const _ManualDlnaRendererDialog();

  @override
  State<_ManualDlnaRendererDialog> createState() =>
      _ManualDlnaRendererDialogState();
}

class _ManualDlnaRendererDialogState extends State<_ManualDlnaRendererDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _canSubmit = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final input = _controller.text.trim();
    if (input.isEmpty) return;
    Navigator.of(context).pop(input);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xff202126),
      title: const Text(
        '手动添加 DLNA 设备',
        style: TextStyle(color: KiraColors.cream),
      ),
      content: SizedBox(
        width: 480,
        child: TextField(
          key: const ValueKey('manual-dlna-address-field'),
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          style: const TextStyle(color: KiraColors.cream),
          decoration: const InputDecoration(
            labelText: 'Renderer IP 或 description URL',
            hintText:
                '例如 192.168.254.7 或 http://192.168.254.7:49152/description.xml',
            helperText: '跨 VLAN 时建议直接输入完整 description URL',
          ),
          onChanged: (input) {
            final canSubmit = input.trim().isNotEmpty;
            if (canSubmit != _canSubmit) {
              setState(() => _canSubmit = canSubmit);
            }
          },
          onSubmitted: (_) {
            if (_canSubmit) _submit();
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submit : null,
          child: const Text('添加'),
        ),
      ],
    );
  }
}

class _OutputModeSection extends StatelessWidget {
  const _OutputModeSection({
    required this.icon,
    required this.title,
    required this.active,
    required this.enabled,
    required this.onChanged,
    this.detail,
  });

  final IconData icon;
  final String title;
  final bool active;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final Widget? detail;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: active ? const Color(0x09dd3e38) : Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 72,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0x24dd3e38)
                          : KiraColors.surface2,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      icon,
                      size: 23,
                      color:
                          active ? const Color(0xffff827d) : KiraColors.muted,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: KiraColors.cream,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Switch(
                    value: active,
                    onChanged: enabled ? onChanged : null,
                    activeThumbColor: Colors.white,
                    activeTrackColor: KiraColors.red,
                    inactiveThumbColor: const Color(0xffbfc0c6),
                    inactiveTrackColor: const Color(0xff303137),
                    trackOutlineColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.disabled)
                          ? KiraColors.line
                          : states.contains(WidgetState.selected)
                              ? KiraColors.red
                              : const Color(0xff76777e),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (detail != null) detail!,
        ],
      ),
    );
  }
}

class _OutputDetail extends StatelessWidget {
  const _OutputDetail({
    required this.title,
    required this.refreshing,
    required this.onRefresh,
    required this.children,
  });

  final String title;
  final bool refreshing;
  final VoidCallback? onRefresh;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 82, right: 24, bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: KiraColors.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: onRefresh,
                  icon: refreshing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: KiraColors.cream,
                          ),
                        )
                      : const Icon(
                          Icons.refresh,
                          size: 21,
                          color: KiraColors.cream,
                        ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: KiraColors.line),
          ...children,
        ],
      ),
    );
  }
}

class _OutputDeviceRow extends StatelessWidget {
  const _OutputDeviceRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.stateLabel,
    this.loading = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final String? stateLabel;
  final bool loading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: KiraColors.line)),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color:
                      selected ? const Color(0x1f22c59b) : KiraColors.surface2,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  icon,
                  size: 19,
                  color: selected ? const Color(0xff55ddb8) : KiraColors.muted,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: KiraColors.cream,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: KiraColors.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 76,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (loading)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: KiraColors.teal,
                        ),
                      )
                    else if (stateLabel != null)
                      const Icon(
                        Icons.check,
                        size: 17,
                        color: Color(0xff55ddb8),
                      ),
                    if (stateLabel != null) ...[
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          stateLabel!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xff55ddb8),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutputEmptyState extends StatelessWidget {
  const _OutputEmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 58,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: const TextStyle(
            color: KiraColors.muted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
