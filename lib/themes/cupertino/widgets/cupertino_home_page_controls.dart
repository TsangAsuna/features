part of dashboard_home_page;

/// Cupertino 首页弹弹play媒体库 section 单次最多展示的条目数，避免
/// 识别出大量番剧后把首页撑得很长；剩余条目入“查看全部”。
const int _cupertinoDandanplayHomePageSize = 6;

extension _CupertinoHomePageControls on _DashboardHomePageState {
  Future<void> _refreshCupertinoHome() async {
    await Future.wait([
      _refreshContinueWatchingData(
        '手机主页手动刷新',
        syncRemote: true,
      ),
      _loadData(
        forceRefreshRecommended: true,
        forceRefreshRandom: true,
        forceRefreshToday: true,
        forceRefreshTrending: true,
      ),
    ]);
  }

  Widget _buildCupertinoHomePage() {
    final sectionsProvider = context.watch<HomeSectionsSettingsProvider>();
    final sections = _buildCupertinoConfiguredSections(sectionsProvider);

    // NOTE: never use fully transparent color as the Cupertino home root — when
    // no home section has content (local/remote library empty, no remote
    // connection) the whole page collapses to blank/black. Fall back to the
    // same dark base color used elsewhere so the page is never empty.
    return ColoredBox(
      color: const Color(0xFF1E1E1E),
      child: CustomScrollView(
        controller: _mainScrollController,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          cupertino.CupertinoSliverRefreshControl(
            onRefresh: _refreshCupertinoHome,
          ),
          const SliverToBoxAdapter(
            child: CupertinoAppPageHeader(title: '主页'),
          ),
          SliverToBoxAdapter(child: _buildCupertinoHero()),
          if (_hasQuarterlyReviewForToday())
            SliverPadding(
              padding: const EdgeInsets.only(top: 22),
              sliver: SliverToBoxAdapter(child: _buildQuarterlyReviewSection()),
            ),
          SliverList(
              delegate: SliverChildBuilderDelegate(
                  (context, index) => sections[index],
                  childCount: sections.length)),
          const SliverPadding(padding: EdgeInsets.only(bottom: 84)),
        ],
      ),
    );
  }

  List<Widget> _buildCupertinoConfiguredSections(
    HomeSectionsSettingsProvider sectionsProvider,
  ) {
    final slivers = <Widget>[];

    void addSection(WidgetBuilder section) {
      slivers.add(const SizedBox(height: 22));
      slivers.add(Builder(builder: section));
    }

    for (final component in _buildHomeComponents(sectionsProvider)) {
      switch (component.type) {
        case UnifiedHomeComponentType.hero:
          break;
        case UnifiedHomeComponentType.todaySeries:
          addSection((_) => _buildCupertinoTodaySection());
          break;
        case UnifiedHomeComponentType.trending:
          addSection((_) => _buildCupertinoTrendingSection());
          break;
        case UnifiedHomeComponentType.randomRecommendations:
          addSection((_) => _buildCupertinoRandomSection());
          break;
        case UnifiedHomeComponentType.continueWatching:
          addSection((_) => _buildCupertinoContinueWatching());
          break;
        case UnifiedHomeComponentType.remoteLibraries:
          for (final entry in _recentJellyfinItemsByLibrary.entries) {
            addSection(
              (_) => _buildCupertinoMediaSection<JellyfinMediaItem>(
                title: 'Jellyfin - 新增${entry.key}',
                items: entry.value,
                imageUrl: (item) {
                  try {
                    return JellyfinService.instance.getImageUrl(item.id);
                  } catch (_) {
                    return '';
                  }
                },
                itemTitle: (item) => item.name,
                subtitle: (item) => item.productionYear?.toString(),
                rating: (item) => double.tryParse(item.communityRating ?? ''),
                onTap: _onJellyfinItemTap,
              ),
            );
          }
          for (final entry in _recentEmbyItemsByLibrary.entries) {
            addSection(
              (_) => _buildCupertinoMediaSection<EmbyMediaItem>(
                title: 'Emby - 新增${entry.key}',
                items: entry.value,
                imageUrl: (item) {
                  try {
                    return EmbyService.instance.getImageUrl(item.id);
                  } catch (_) {
                    return '';
                  }
                },
                itemTitle: (item) => item.name,
                subtitle: (item) => item.productionYear?.toString(),
                rating: (item) => double.tryParse(item.communityRating ?? ''),
                onTap: _onEmbyItemTap,
              ),
            );
          }
          if (_recentDandanplayGroups.isNotEmpty) {
            final dandanVisible = _recentDandanplayGroups
                .take(_cupertinoDandanplayHomePageSize)
                .toList(growable: false);
            final showAll = _recentDandanplayGroups.length > _cupertinoDandanplayHomePageSize;
            addSection(
              (_) => _buildCupertinoMediaSection<DandanplayRemoteAnimeGroup>(
                title: '弹弹play - 最近添加',
                items: dandanVisible,
                imageUrl: _getDandanGroupImage,
                itemTitle: (item) => item.title,
                subtitle: (item) => '${item.episodeCount} 集',
                onTap: _onDandanplayGroupTap,
                action: showAll
                    ? _buildCupertinoHomeIconButton(
                        label: '查看全部弹弹媒体库',
                        icon: cupertino.CupertinoIcons.list_bullet,
                        onPressed: _onDandanplayShowAllPressed,
                      )
                    : null,
              ),
            );
          }
          break;
        case UnifiedHomeComponentType.localLibrary:
          addSection(
            (_) => _buildCupertinoMediaSection<LocalAnimeItem>(
              title: '本地媒体库 - 最近添加',
              items: _localAnimeItems,
              imageUrl: (item) =>
                  item.imageUrl ?? _localImageCache[item.animeId] ?? '',
              itemTitle: (item) => item.animeName,
              subtitle: (item) => item.latestEpisode.episodeTitle,
              onTap: _onLocalAnimeItemTap,
            ),
          );
          break;
      }
    }

    // 当没有任何 section 有内容时（本地/远程库均为空、未连接远程服务器、
    // 弹弹无数据），首页只剩下 hero 会呈现空白。在此渲染一个空态占位
    // 并给出“添加媒体库”的入口，避免用户误以为媒体库识别后首页仍空。
    if (slivers.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildCupertinoEmptyLibrarySection(),
        ),
      );
    }

    return slivers;
  }

  Widget _buildCupertinoEmptyLibrarySection() {
    return SizedBox(
      height: 260,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              cupertino.CupertinoIcons.folder_fill,
              size: 56,
              color: cupertino.CupertinoColors.systemGrey3,
            ),
            const SizedBox(height: 16),
            Text(
              '媒体库尚未添加',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: cupertino.CupertinoColors.label,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '在“库管理”中添加本地文件夹、WebDAV/SMB 或 Emby/Jellyfin，\n'
              '识别完成后会出现在此页。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: cupertino.CupertinoColors.secondaryLabel,
              ),
            ),
            const SizedBox(height: 20),
            cupertino.CupertinoButton.filled(
              onPressed: _onAddMediaLibraryPressed,
              child: const Text('添加媒体库'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onAddMediaLibraryPressed() async {
    // 跳转到库管理页；由上层 DashboardHomePage 暴露统一入口。
    // 这里通过命名路由打开媒体库管理页面。
    try {
      await Navigator.of(context).pushNamed('/media-library-management');
    } catch (_) {
      // 路由未注册时静默忽略，避免首页因缺少入口而崩溃；
      // 调用方应在 onGenerateRoute 中注册该路由。
    }
  }

  Future<void> _onDandanplayShowAllPressed() async {
    // 打开全部弹弹play媒体库列表。优先走命名路由；未注册时降级为
    // 提示用户到“库管理”查看，避免首页因缺少入口而报错。
    try {
      await Navigator.of(context).pushNamed('/dandanplay-library');
    } catch (_) {
      try {
        await Navigator.of(context).pushNamed('/media-library-management');
      } catch (__) {
        // 两条路由均未注册时静默忽略，首页保持可用。
      }
    }
  }

  Widget _buildCupertinoHero() {
    // 外观设置中关闭了主页推荐轮播大图时不占用空间
    if (!context.watch<AppearanceSettingsProvider>().showHomeHeroBanner) {
      return const SizedBox.shrink();
    }
    if (_isLoadingRecommended && _recommendedItems.isEmpty) {
      return const SizedBox(
        height: 236,
        child: Center(child: cupertino.CupertinoActivityIndicator()),
      );
    }
    if (_recommendedItems.isEmpty) {
      return _buildCupertinoEmptySection('暂无推荐内容');
    }

    final items = _recommendedItems.take(5).toList(growable: false);
    return SizedBox(
      height: 250,
      child: PageView.builder(
        controller: _heroBannerPageController,
        itemCount: items.length,
        onPageChanged: (index) {
          _currentHeroBannerIndex = index;
          _heroBannerIndexNotifier.value = index;
          _stopAutoSwitch();
          Timer(const Duration(seconds: 3), _resumeAutoSwitch);
        },
        itemBuilder: (context, index) {
          final item = items[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _onRecommendedItemTap(item),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildCupertinoImage(
                      item.backgroundImageUrl,
                      fit: BoxFit.cover,
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.78),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 18,
                      right: 18,
                      bottom: 18,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (item.subtitle.trim().isNotEmpty) ...[
                            const SizedBox(height: 5),
                            Text(
                              item.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.78),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (item.rating != null)
                      Positioned(
                        top: 12,
                        right: 12,
                        child: _buildCupertinoRating(item.rating!),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCupertinoTodaySection() {
    return _buildCupertinoMediaSection<BangumiAnime>(
      title: '今日新番',
      items: _todayAnimes,
      loading: _isLoadingTodayAnimes,
      imageUrl: (item) => item.imageUrl,
      itemTitle: (item) => item.nameCn.isNotEmpty ? item.nameCn : item.name,
      subtitle: (item) => item.airDate,
      rating: (item) => item.rating,
      onTap: _showAnimeDetail,
      action: _buildCupertinoHomeIconButton(
        label: '搜索番剧',
        icon: cupertino.CupertinoIcons.search,
        onPressed: _showTagSearchModal,
      ),
    );
  }

  Widget _buildCupertinoRandomSection() {
    return _buildCupertinoMediaSection<RandomRecommendationItem>(
      title: '随机推荐',
      items: _randomRecommendations,
      loading: _isLoadingRandomRecommendations,
      imageUrl: (item) => item.anime.imageUrl ?? '',
      itemTitle: (item) => item.anime.animeTitle,
      subtitle: (item) => _formatRandomTagLabel(item.tag),
      rating: (item) => item.anime.rating > 0 ? item.anime.rating : null,
      onTap: (item) => ThemedAnimeDetail.show(
        context,
        item.anime.animeId,
      ),
      action: _buildCupertinoHomeIconButton(
        label: '刷新随机推荐',
        icon: cupertino.CupertinoIcons.refresh,
        onPressed: _isLoadingRandomRecommendations
            ? null
            : () => _loadRandomRecommendations(forceRefresh: true),
      ),
    );
  }

  Widget _buildCupertinoContinueWatching() {
    return Consumer<WatchHistoryProvider>(
      builder: (context, history, _) {
        final items = history.continueWatchingItems.take(10).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCupertinoSectionHeader(
              '继续播放',
              action: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildCupertinoHomeIconButton(
                    label: '观看记录',
                    icon: cupertino.CupertinoIcons.time,
                    onPressed: () => unawaited(_showWatchHistoryDialog()),
                  ),
                  _buildCupertinoHomeIconButton(
                    label: '刷新继续播放',
                    icon: cupertino.CupertinoIcons.refresh,
                    onPressed: _isContinueWatchingRefreshInProgress
                        ? null
                        : _onContinueWatchingRefreshPressed,
                    loading: _isContinueWatchingRefreshInProgress,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            if (items.isEmpty)
              _buildCupertinoEmptySection('暂无播放记录')
            else
              SizedBox(
                height: 196,
                child: ListView.separated(
                  controller: _continueWatchingScrollController,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _isHistoryAutoMatching
                          ? null
                          : () => _onWatchHistoryItemTap(item),
                      child: SizedBox(
                        width: 224,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: SizedBox(
                                height: 124,
                                width: 224,
                                child: _getVideoThumbnail(item),
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              item.animeName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 3),
                            _buildCupertinoProgress(item.watchProgress),
                            const SizedBox(height: 3),
                            Text(
                              '${(item.watchProgress * 100).round()}%'
                              '${item.episodeTitle == null ? '' : ' · ${item.episodeTitle}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: cupertino.CupertinoDynamicColor.resolve(
                                  cupertino.CupertinoColors.secondaryLabel,
                                  context,
                                ),
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
        );
      },
    );
  }

  Widget _buildCupertinoMediaSection<T>({
    required String title,
    required List<T> items,
    required String Function(T item) imageUrl,
    required String Function(T item) itemTitle,
    required void Function(T item) onTap,
    String? Function(T item)? subtitle,
    double? Function(T item)? rating,
    bool loading = false,
    Widget? action,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCupertinoSectionHeader(title, action: action),
        const SizedBox(height: 10),
        SizedBox(
          height: 224,
          child: loading && items.isEmpty
              ? const Center(child: cupertino.CupertinoActivityIndicator())
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _buildCupertinoPosterCard(
                      imageUrl: imageUrl(item),
                      title: itemTitle(item),
                      subtitle: subtitle?.call(item),
                      rating: rating?.call(item),
                      onTap: () => onTap(item),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildCupertinoSectionHeader(String title, {Widget? action}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (action != null) action,
        ],
      ),
    );
  }

  Widget _buildCupertinoHomeIconButton({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool loading = false,
  }) {
    final foreground = cupertino.CupertinoDynamicColor.resolve(
      cupertino.CupertinoColors.label,
      context,
    );
    final effectiveColor =
        onPressed == null ? foreground.withValues(alpha: 0.3) : foreground;

    return Semantics(
      button: true,
      label: label,
      child: SizedBox.square(
        dimension: 36,
        child: cupertino.CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size.square(36),
          onPressed: onPressed,
          child: loading
              ? cupertino.CupertinoActivityIndicator(
                  radius: 8,
                  color: effectiveColor,
                )
              : Icon(icon, size: 19, color: effectiveColor),
        ),
      ),
    );
  }

  Widget _buildCupertinoPosterCard({
    required String imageUrl,
    required String title,
    required VoidCallback onTap,
    String? subtitle,
    double? rating,
    String? badgeText,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 126,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                children: [
                  SizedBox(
                    width: 126,
                    height: 172,
                    child: _buildCupertinoImage(imageUrl, fit: BoxFit.cover),
                  ),
                  if (rating != null)
                    Positioned(
                      top: 7,
                      right: 7,
                      child: _buildCupertinoRating(rating),
                    ),
                  if (badgeText != null && badgeText.isNotEmpty)
                    Positioned(
                      left: 7,
                      top: 7,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppAccentColors.current,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          child: Text(
                            badgeText,
                            style: TextStyle(
                              color: ThemeData.estimateBrightnessForColor(
                                        AppAccentColors.current,
                                      ) ==
                                      Brightness.light
                                  ? Colors.black87
                                  : Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 7),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (subtitle?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: cupertino.CupertinoDynamicColor.resolve(
                    cupertino.CupertinoColors.secondaryLabel,
                    context,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCupertinoImage(String? imageUrl, {required BoxFit fit}) {
    final url = imageUrl?.trim() ?? '';
    final placeholderColor = cupertino.CupertinoDynamicColor.resolve(
      cupertino.CupertinoColors.systemGrey5,
      context,
    );
    if (url.isEmpty) {
      return ColoredBox(
        color: placeholderColor,
        child: const Center(
          child: Icon(
            cupertino.CupertinoIcons.photo,
            color: cupertino.CupertinoColors.systemGrey,
          ),
        ),
      );
    }
    if (url.startsWith('assets/')) {
      return Image.asset(
        url,
        fit: fit,
        errorBuilder: (_, __, ___) => ColoredBox(color: placeholderColor),
      );
    }
    return ColoredBox(
      color: placeholderColor,
      child: MediaServerAwareCachedNetworkImage(
        imageUrl: url,
        fit: fit,
        errorWidget: (_, __, ___) => ColoredBox(color: placeholderColor),
      ),
    );
  }

  Widget _buildCupertinoRating(double rating) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          rating.toStringAsFixed(1),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildCupertinoProgress(double value) {
    final progress = value.clamp(0.0, 1.0);
    final background = cupertino.CupertinoDynamicColor.resolve(
      cupertino.CupertinoColors.systemGrey4,
      context,
    );
    return SizedBox(
      height: 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: ColoredBox(
          color: background,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: progress,
              child: ColoredBox(
                color: cupertino.CupertinoTheme.of(context).primaryColor,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCupertinoEmptySection(String message) {
    final secondary = cupertino.CupertinoDynamicColor.resolve(
      cupertino.CupertinoColors.secondaryLabel,
      context,
    );
    return SizedBox(
      height: 120,
      child: Center(
        child: Text(message, style: TextStyle(color: secondary)),
      ),
    );
  }
}
