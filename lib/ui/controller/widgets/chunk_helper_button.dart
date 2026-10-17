import 'package:flutter/material.dart';

import '../../../services/chunk_helper_launcher.dart';

class ChunKHelperButton extends StatefulWidget {
  const ChunKHelperButton({super.key, this.enabled = true, this.onLaunch});

  final bool enabled;
  final Future<void> Function()? onLaunch;

  @override
  State<ChunKHelperButton> createState() => _ChunKHelperButtonState();
}

class _ChunKHelperButtonState extends State<ChunKHelperButton> {
  bool _launching = false;

  Future<void> _launch() async {
    if (_launching) return;
    setState(() => _launching = true);
    try {
      await (widget.onLaunch ?? const ChunKHelperLauncher().launch)();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('纯K助手已启动，连接房台后请点击刷新设备。')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法启动纯K助手：$error')),
      );
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      key: const ValueKey('chunk-helper-button'),
      onPressed: widget.enabled && !_launching ? _launch : null,
      icon: const Icon(Icons.qr_code_scanner),
      label: Text(_launching ? '正在启动…' : '纯K助手'),
    );
  }
}
