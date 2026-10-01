part of '../../screens/browse_screen.dart';

class _RankingRail extends StatelessWidget {
  const _RankingRail({
    required this.categories,
    required this.activeCategory,
    required this.onBack,
    required this.onSelected,
  });

  final List<({String name, String note, IconData icon})> categories;
  final String activeCategory;
  final VoidCallback onBack;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _BackButton(onPressed: onBack),
            const SizedBox(height: 28),
            const Divider(color: KiraColors.line, height: 1),
            const SizedBox(height: 24),
            const Text(
              '榜单分类',
              style: TextStyle(
                color: KiraColors.muted,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: ListView.separated(
                itemCount: categories.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final cat = categories[index];
                  final active = cat.name == activeCategory;
                  return SizedBox(
                    height: 96,
                    child: FilledButton(
                      onPressed: () => onSelected(cat.name),
                      style: FilledButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        backgroundColor:
                            active ? KiraColors.orange : KiraColors.surface,
                        foregroundColor: KiraColors.cream,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                            color: active
                                ? const Color(0x56ffcd9c)
                                : KiraColors.line,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              color: const Color(0x1fffffff),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(cat.icon, color: KiraColors.cream),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  cat.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  cat.note,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: KiraColors.muted,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SongScopeRail extends StatelessWidget {
  const _SongScopeRail({
    required this.title,
    required this.options,
    required this.activeOption,
    required this.onBack,
    required this.onSelected,
  });

  final String title;
  final List<String> options;
  final String activeOption;
  final VoidCallback onBack;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _BackButton(onPressed: onBack),
            const SizedBox(height: 28),
            const Divider(color: KiraColors.line, height: 1),
            const SizedBox(height: 24),
            Text(
              title,
              style: const TextStyle(
                color: KiraColors.muted,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: ListView.separated(
                itemCount: options.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final option = options[index];
                  final active = option == activeOption;
                  return _RailOption(
                    label: option,
                    active: active,
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionRail extends StatelessWidget {
  const _OptionRail({
    required this.title,
    required this.options,
    required this.activeOption,
    required this.onBack,
    required this.onSelected,
  });

  final String title;
  final List<String> options;
  final String activeOption;
  final VoidCallback onBack;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _BackButton(onPressed: onBack),
            const SizedBox(height: 28),
            const Divider(color: KiraColors.line, height: 1),
            const SizedBox(height: 24),
            Text(
              title,
              style: const TextStyle(
                color: KiraColors.muted,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: ListView.separated(
                itemCount: options.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final option = options[index];
                  final active = option == activeOption;
                  return _RailOption(
                    label: option,
                    active: active,
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryRail extends StatelessWidget {
  const _CategoryRail({
    required this.categories,
    required this.activeCategory,
    required this.onBack,
    required this.onSelected,
  });

  final List<CategorySummary> categories;
  final String activeCategory;
  final VoidCallback onBack;
  final ValueChanged<CategorySummary> onSelected;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _panelDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _BackButton(onPressed: onBack),
            const SizedBox(height: 28),
            Expanded(
              child: ListView.separated(
                itemCount: categories.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final category = categories[index];
                  final active = category.name == activeCategory;
                  return _CategoryOption(
                    category: category,
                    active: active,
                    onTap: () => onSelected(category),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailOption extends StatelessWidget {
  const _RailOption({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          backgroundColor:
              active ? const Color(0xff1d2e4b) : Colors.transparent,
          foregroundColor: active ? const Color(0xff77a7ff) : KiraColors.cream,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: active ? const Color(0xff4777c6) : Colors.transparent,
            ),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _CategoryOption extends StatelessWidget {
  const _CategoryOption({
    required this.category,
    required this.active,
    required this.onTap,
  });

  final CategorySummary category;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 92,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          backgroundColor: active ? KiraColors.surface3 : KiraColors.surface,
          foregroundColor: KiraColors.cream,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: active ? KiraColors.lineStrong : KiraColors.line,
            ),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: const Color(0x1fffffff),
                borderRadius: BorderRadius.circular(10),
              ),
              child:
                  Icon(_categoryIcon(category.name), color: KiraColors.cream),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    category.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    category.note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: KiraColors.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
