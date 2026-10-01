part of '../../screens/browse_screen.dart';

class _BilibiliAccountRail extends StatefulWidget {
  const _BilibiliAccountRail({
    required this.accountService,
    required this.onBack,
  });

  final BilibiliAccountService accountService;
  final VoidCallback onBack;

  @override
  State<_BilibiliAccountRail> createState() => _BilibiliAccountRailState();
}

class _BilibiliAccountRailState extends State<_BilibiliAccountRail> {
  static const _fontFamily = 'Microsoft YaHei UI';
  static const _fontFamilyFallback = <String>[
    'Microsoft YaHei',
    'Segoe UI',
    'Noto Sans CJK SC',
  ];

  @override
  void initState() {
    super.initState();
    widget.accountService.addListener(_handleAccountChanged);
    unawaited(widget.accountService.startLoginFlow());
  }

  @override
  void didUpdateWidget(covariant _BilibiliAccountRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountService == widget.accountService) return;
    oldWidget.accountService
      ..removeListener(_handleAccountChanged)
      ..stopQrPolling();
    widget.accountService.addListener(_handleAccountChanged);
    unawaited(widget.accountService.startLoginFlow());
  }

  @override
  void dispose() {
    widget.accountService
      ..removeListener(_handleAccountChanged)
      ..stopQrPolling();
    super.dispose();
  }

  void _handleAccountChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _logout() async {
    await widget.accountService.logout();
    if (!mounted) return;
    await widget.accountService.startLoginFlow();
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.accountService;
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _BackButton(onPressed: widget.onBack),
            const SizedBox(height: 45),
            Expanded(
              child: service.isLoggedIn
                  ? Transform.translate(
                      offset: const Offset(0, -72),
                      child: _buildSignedIn(service),
                    )
                  : _buildSignedOut(service),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSignedOut(BilibiliAccountService service) {
    final qrData = service.qrUrl;
    final loading = service.qrState == BilibiliQrLoginState.loading;
    return Column(
      children: [
        const Text(
          '登录 Bilibili 账号',
          style: TextStyle(
            color: KiraColors.cream,
            fontSize: 27,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          '登录后可获取更高画质',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: KiraColors.muted,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const Spacer(),
        Container(
          width: 244,
          height: 244,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xfff8f5ee),
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: qrData != null
              ? QrImageView(
                  data: qrData,
                  version: QrVersions.auto,
                  backgroundColor: const Color(0xfff8f5ee),
                )
              : loading
                  ? const CircularProgressIndicator(color: KiraColors.red)
                  : const Icon(
                      Icons.qr_code_2,
                      size: 150,
                      color: Color(0xffb8b3aa),
                    ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 48,
          child: Text(
            service.statusMessage,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: service.qrState == BilibiliQrLoginState.error ||
                      service.qrState == BilibiliQrLoginState.expired
                  ? KiraColors.red
                  : KiraColors.muted,
              fontSize: 16,
              height: 1.4,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 58,
          child: OutlinedButton.icon(
            onPressed: loading ? null : service.refreshLoginQr,
            icon: const Icon(Icons.refresh, size: 23),
            label: const Text(
              '刷新二维码',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: KiraColors.cream,
              side: const BorderSide(color: KiraColors.lineStrong),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        const Spacer(),
      ],
    );
  }

  Widget _buildSignedIn(BilibiliAccountService service) {
    final profile = service.profile!;
    return Column(
      children: [
        const Spacer(),
        _buildAvatar(profile),
        const SizedBox(height: 22),
        Text(
          profile.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: KiraColors.cream,
            fontSize: 28,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            profile.signature.isEmpty ? '这个用户还没有填写个人简介' : profile.signature,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: KiraColors.muted,
              fontSize: 15,
              height: 1.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const Spacer(),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '画质偏好',
            style: TextStyle(
              color: KiraColors.muted,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 9),
        _buildQualitySelector(service),
        const SizedBox(height: 30),
        SizedBox(
          width: double.infinity,
          height: 58,
          child: OutlinedButton.icon(
            onPressed: _logout,
            icon: const Icon(Icons.logout, size: 22),
            label: const Text(
              '退出登录',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: KiraColors.red,
              side: const BorderSide(color: KiraColors.red),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        const Spacer(),
      ],
    );
  }

  Widget _buildQualitySelector(BilibiliAccountService service) {
    final selectedLabel = bilibiliQualityLabel(service.preferredQualityQn);
    final viewport = MediaQuery.sizeOf(context);
    final canvasScale = math.min(
      viewport.width / KiraDesignCanvas.stageSize.width,
      viewport.height / KiraDesignCanvas.stageSize.height,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final visibleWidth = constraints.maxWidth * canvasScale;
        final menuRowHeight = 48.0 * canvasScale;
        final menuFontSize = 18.0 * canvasScale;
        final menuRadius = 10.0 * canvasScale;
        final menuHorizontalPadding = 16.0 * canvasScale;

        return PopupMenuButton<int>(
          key: const ValueKey('bilibili-quality-selector'),
          initialValue: service.preferredQualityQn,
          tooltip: '画质偏好',
          position: PopupMenuPosition.under,
          color: KiraColors.surface2,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          menuPadding: EdgeInsets.symmetric(vertical: 4 * canvasScale),
          constraints: BoxConstraints.tightFor(width: visibleWidth),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(menuRadius),
            side: const BorderSide(color: KiraColors.lineStrong),
          ),
          onSelected: (value) {
            unawaited(service.setPreferredQualityQn(value));
          },
          itemBuilder: (context) => bilibiliQualityOptions
              .map(
                (option) => PopupMenuItem<int>(
                  key: ValueKey('bilibili-quality-option-${option.qn}'),
                  value: option.qn,
                  height: menuRowHeight,
                  padding: EdgeInsets.symmetric(
                    horizontal: menuHorizontalPadding,
                  ),
                  child: Text(
                    option.label,
                    style: TextStyle(
                      color: KiraColors.cream,
                      fontFamily: _fontFamily,
                      fontFamilyFallback: _fontFamilyFallback,
                      fontSize: menuFontSize,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              )
              .toList(growable: false),
          child: Container(
            height: 62,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: KiraColors.surface2,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: KiraColors.lineStrong),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    selectedLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: KiraColors.cream,
                      fontFamily: _fontFamily,
                      fontFamilyFallback: _fontFamilyFallback,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: KiraColors.cream,
                  size: 25,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAvatar(BilibiliAccountProfile profile) {
    Widget fallback() => const ColoredBox(
          color: KiraColors.surface2,
          child: Center(
            child: Icon(Icons.person, color: KiraColors.muted, size: 92),
          ),
        );

    return Container(
      width: 190,
      height: 190,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: KiraColors.lineStrong, width: 2),
      ),
      padding: const EdgeInsets.all(4),
      child: ClipOval(
        child: profile.faceUrl.isEmpty
            ? fallback()
            : Image.network(
                profile.faceUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => fallback(),
              ),
      ),
    );
  }
}
