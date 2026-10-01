part of '../../screens/browse_screen.dart';

class _ExternalLinkPanel extends StatefulWidget {
  const _ExternalLinkPanel({
    required this.accountService,
    required this.clipboardService,
    required this.onAddSong,
    required this.onBumpSong,
  });

  final BilibiliAccountService accountService;
  final ClipboardService clipboardService;
  final ValueChanged<Song> onAddSong;
  final ValueChanged<Song> onBumpSong;

  @override
  State<_ExternalLinkPanel> createState() => _ExternalLinkPanelState();
}

class _ExternalLinkPanelState extends State<_ExternalLinkPanel> {
  final _urlController = TextEditingController();
  final _focusNode = FocusNode();
  bool _loading = false;
  bool _pasting = false;
  BilibiliResolveResult? _result;
  String? _error;
  bool _pageLoading = false;

  @override
  void dispose() {
    _urlController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _resolve() async {
    final input = _urlController.text.trim();
    if (input.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
      _result = null;
    });

    try {
      final result = await resolveBilibiliUrl(
        input,
        preferredQuality: widget.accountService.preferredQualityQn,
        cookieHeader: widget.accountService.cookieHeader,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } on BilibiliResolveError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '解析失败：$e';
        _loading = false;
      });
    }
  }

  void _addToQueue() {
    if (_result == null) return;
    widget.onAddSong(_result!.song);
  }

  void _bumpToNext() {
    if (_result == null) return;
    widget.onBumpSong(_result!.song);
  }

  void _reset() {
    _urlController.clear();
    _focusNode.requestFocus();
    setState(() {
      _result = null;
      _error = null;
      _pageLoading = false;
    });
  }

  Future<void> _pasteFromClipboard() async {
    if (_loading || _pasting) return;
    setState(() => _pasting = true);
    try {
      final clipboardText = await widget.clipboardService.readText();
      if (!mounted) return;
      if (clipboardText == null || clipboardText.trim().isEmpty) {
        setState(() => _error = '剪贴板中没有可粘贴的文本');
        return;
      }
      if (clipboardText.length > maxBilibiliClipboardInputCodeUnits) {
        setState(() => _error = '剪贴板文本过长，请只复制 Bilibili 链接或编号');
        return;
      }
      final input = extractBilibiliClipboardInput(clipboardText);
      if (input == null) {
        setState(() => _error = '剪贴板中没有可识别的 Bilibili 链接或 BV/AV 号');
        return;
      }
      _urlController.value = TextEditingValue(
        text: input,
        selection: TextSelection.collapsed(offset: input.length),
      );
      _focusNode.requestFocus();
      setState(() {
        _result = null;
        _error = null;
        _pageLoading = false;
      });
    } on ClipboardReadException catch (error) {
      if (mounted) setState(() => _error = error.userMessage);
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法读取剪贴板，请稍后重试');
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  Future<void> _switchPage(int index) async {
    final r = _result;
    if (r == null || index < 0 || index >= r.pages.length) return;
    final target = r.pages[index];
    if (target.page == r.selectedPage) return;

    setState(() => _pageLoading = true);
    try {
      final pageResult = await resolveBilibiliPage(
        bvid: r.bvid,
        pageInfo: target,
        ownerName: r.ownerName,
        ownerMid: r.ownerMid,
        mainTitle: r.song.title,
        preferredQuality: widget.accountService.preferredQualityQn,
        cookieHeader: widget.accountService.cookieHeader,
      );
      if (!mounted) return;
      setState(() {
        _result = BilibiliResolveResult(
          song: pageResult.song,
          bvid: r.bvid,
          cid: target.cid,
          quality: pageResult.quality,
          qualityDesc: pageResult.qualityDesc,
          pages: r.pages,
          selectedPage: target.page,
          ownerName: r.ownerName,
          ownerMid: r.ownerMid,
          coverUrl: r.coverUrl,
          playCount: r.playCount,
          danmakuCount: r.danmakuCount,
        );
        _pageLoading = false;
      });
    } on BilibiliResolveError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _pageLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '切换分P失败：$e';
        _pageLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 72),
            // ── Input row ──
            _buildInputRow(),
            const SizedBox(height: 16),
            // ── Status area ──
            Expanded(child: _buildStatusArea()),
          ],
        ),
      ),
    );
  }

  Widget _buildInputRow() {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 70,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: const Color(0xfff3eee5),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0x1fffffff)),
            ),
            child: Row(
              children: [
                const Icon(Icons.link, color: KiraColors.red, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    key: const ValueKey('bilibili-external-link-field'),
                    controller: _urlController,
                    focusNode: _focusNode,
                    enabled: !_loading,
                    style: const TextStyle(
                      color: Color(0xff222222),
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'https://www.bilibili.com/video/BV... 或 BV号',
                      hintStyle: TextStyle(
                        color: Color(0xff77746d),
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    onSubmitted: (_) => _resolve(),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),
        SizedBox(
          width: 116,
          height: 70,
          child: OutlinedButton.icon(
            key: const ValueKey('bilibili-paste-button'),
            onPressed: _loading || _pasting ? null : _pasteFromClipboard,
            icon: _pasting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : const Icon(Icons.content_paste, size: 22),
            label: const Text(
              '粘贴',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: KiraColors.red,
              side: const BorderSide(color: KiraColors.red, width: 2),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        SizedBox(
          width: 136,
          height: 70,
          child: FilledButton.icon(
            onPressed: _loading ? null : _resolve,
            icon: _loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.search, size: 22),
            label: Text(
              _loading ? '解析中' : '解析',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: KiraColors.red,
              foregroundColor: Colors.white,
              disabledBackgroundColor: KiraColors.red.withValues(alpha: 0.45),
              disabledForegroundColor: Colors.white.withValues(alpha: 0.45),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusArea() {
    // Error state
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: KiraColors.red, size: 60),
            const SizedBox(height: 15),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: KiraColors.muted,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.refresh, size: 25),
              label: const Text('重试',
                  style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900)),
              style: FilledButton.styleFrom(
                backgroundColor: KiraColors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      );
    }

    // Success state
    if (_result != null) {
      final r = _result!;
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Info card with cover ──
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xff1a1c20),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: KiraColors.lineStrong),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Cover image ──
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 160,
                      child: AspectRatio(
                        aspectRatio: 16 / 10,
                        child: r.coverUrl.isNotEmpty
                            ? Image.network(
                                r.coverUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    _coverPlaceholder(),
                              )
                            : _coverPlaceholder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  // ── Info area ──
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.song.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: KiraColors.cream,
                            fontSize: 25,
                            fontWeight: FontWeight.w800,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          r.ownerName,
                          style: const TextStyle(
                            color: Color(0xffcccccc),
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 16,
                          runSpacing: 4,
                          children: [
                            _metaChip(Icons.schedule,
                                _formatDuration(r.song.duration)),
                            _metaChip(Icons.hd, r.qualityDesc),
                            if (r.playCount != null)
                              _metaChip(Icons.play_circle_outline,
                                  _formatCount(r.playCount!)),
                            if (r.danmakuCount != null)
                              _metaChip(Icons.comment_outlined,
                                  _formatCount(r.danmakuCount!)),
                            _metaChip(Icons.tag, r.bvid),
                          ],
                        ),
                        // ── Page tabs (always visible) ──
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 36,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: r.pages.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 8),
                            itemBuilder: (context, i) {
                              final pi = r.pages[i];
                              final isActive = pi.page == r.selectedPage;
                              final label = 'P${pi.page} ${pi.title}';
                              return Material(
                                color: isActive
                                    ? KiraColors.red
                                    : const Color(0xff2a2c32),
                                borderRadius: BorderRadius.circular(8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: isActive || _pageLoading
                                      ? null
                                      : () => _switchPage(i),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 14, vertical: 6),
                                    alignment: Alignment.center,
                                    child: _pageLoading && isActive
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : Text(
                                            label.length > 20
                                                ? '${label.substring(0, 20)}…'
                                                : label,
                                            style: TextStyle(
                                              color: isActive
                                                  ? Colors.white
                                                  : KiraColors.muted,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                  // ── Action buttons (vertical) ──
                  SizedBox(
                    width: 120,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 120,
                          height: 48,
                          child: FilledButton(
                            onPressed: _addToQueue,
                            style: FilledButton.styleFrom(
                              backgroundColor: KiraColors.red,
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: const Text(
                              '点歌',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _bumpToNext,
                            borderRadius: BorderRadius.circular(8),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.arrow_upward,
                                      size: 13, color: KiraColors.muted),
                                  SizedBox(width: 4),
                                  Text(
                                    '顶歌',
                                    style: TextStyle(
                                      color: KiraColors.muted,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 后面不需要 _added 的 banner 了
          ],
        ),
      );
    }

    // Idle state
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_download_outlined,
              color: KiraColors.muted, size: 70),
          const SizedBox(height: 20),
          const Text(
            '粘贴 Bilibili 视频链接或 BV/AV 号\n点击「解析」后选择分P点歌',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: KiraColors.muted,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: KiraColors.muted.withValues(alpha: 0.6),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration? d) {
    if (d == null) return '--:--';
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatCount(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return n.toString();
  }

  Widget _coverPlaceholder() {
    return Container(
      width: 160,
      height: 100,
      decoration: BoxDecoration(
        color: const Color(0xff2a2c32),
        borderRadius: BorderRadius.circular(8),
      ),
      child:
          const Icon(Icons.play_circle_fill, color: KiraColors.red, size: 36),
    );
  }

  Widget _metaChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: KiraColors.muted),
        const SizedBox(width: 4),
        Text(
          text,
          style: const TextStyle(
            color: KiraColors.muted,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
