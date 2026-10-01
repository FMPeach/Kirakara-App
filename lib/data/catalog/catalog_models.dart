import 'dart:convert';

// ─────────────────────────────────────────────────────────────────────
// Kirakara Catalog API v1 — 纯数据模型 + 解析
//
// 对应 docs/catalog-api-v1.md 的四个 JSON 端点。
// 不依赖 Flutter、不依赖 SQLite、不依赖其他服务层。
// 仅负责 JSON → Dart 对象。
// ─────────────────────────────────────────────────────────────────────

// ═════════════════════════════════════════════════════════════════════
// Artists
// ═════════════════════════════════════════════════════════════════════

class CatalogArtist {
  const CatalogArtist({
    required this.id,
    required this.name,
    required this.type,
    this.categoryIds = const [],
    this.note,
    this.avatarUri,
  });

  final String id;
  final String name;
  final String type;
  final List<String> categoryIds;
  final String? note;
  final String? avatarUri;

  factory CatalogArtist.fromJson(Map<String, Object?> json) {
    return CatalogArtist(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      type: (json['type'] as String?) ?? 'other',
      categoryIds: _stringList(json['categoryIds']),
      note: json['note'] as String?,
      avatarUri: json['avatarUri'] as String?,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        if (categoryIds.isNotEmpty) 'categoryIds': categoryIds,
        if (note != null) 'note': note,
        if (avatarUri != null) 'avatarUri': avatarUri,
      };
}

// ═════════════════════════════════════════════════════════════════════
// Categories
// ═════════════════════════════════════════════════════════════════════

class CatalogCategory {
  const CatalogCategory({
    required this.id,
    required this.type,
    required this.name,
    this.note,
    this.order,
  });

  final String id;
  final String type; // "song" | "artist"
  final String name;
  final String? note;
  final int? order;

  factory CatalogCategory.fromJson(Map<String, Object?> json) {
    return CatalogCategory(
      id: (json['id'] as String?) ?? '',
      type: (json['type'] as String?) ?? 'song',
      name: (json['name'] as String?) ?? '',
      note: json['note'] as String?,
      order: (json['order'] as num?)?.toInt(),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type,
        'name': name,
        if (note != null) 'note': note,
        if (order != null) 'order': order,
      };
}

// ═════════════════════════════════════════════════════════════════════
// Songs
// ═════════════════════════════════════════════════════════════════════

class CatalogSong {
  const CatalogSong({
    required this.id,
    required this.title,
    required this.artistLine,
    this.primaryArtistId,
    this.artistRefs = const [],
    this.credits = const [],
    this.circleIds,
    this.categoryIds = const [],
    this.workIds,
    this.tags = const [],
    this.searchHints,
    this.coverColor,
    this.assets = const [],
  });

  final String id;
  final String title;
  final String artistLine;
  final String? primaryArtistId;
  final List<CatalogArtistRef> artistRefs;
  final List<CatalogCredit> credits;
  final List<String>? circleIds;
  final List<String> categoryIds;
  final List<String>? workIds;
  final List<String> tags;
  final List<String>? searchHints;
  final String? coverColor;
  final List<CatalogAsset> assets;

  factory CatalogSong.fromJson(Map<String, Object?> json) {
    return CatalogSong(
      id: (json['id'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      artistLine: (json['artistLine'] as String?) ?? '',
      primaryArtistId: json['primaryArtistId'] as String?,
      artistRefs: _parseList(json['artistRefs'], CatalogArtistRef.fromJson),
      credits: _parseList(json['credits'], CatalogCredit.fromJson),
      circleIds: _nullableStringList(json['circleIds']),
      categoryIds: _stringList(json['categoryIds']),
      workIds: _nullableStringList(json['workIds']),
      tags: _stringList(json['tags']),
      searchHints: _nullableStringList(json['searchHints']),
      coverColor: json['coverColor'] as String?,
      assets: _parseList(json['assets'], CatalogAsset.fromJson),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'artistLine': artistLine,
        if (primaryArtistId != null) 'primaryArtistId': primaryArtistId,
        if (artistRefs.isNotEmpty)
          'artistRefs': artistRefs.map((r) => r.toJson()).toList(),
        if (credits.isNotEmpty)
          'credits': credits.map((c) => c.toJson()).toList(),
        if (circleIds != null && circleIds!.isNotEmpty) 'circleIds': circleIds,
        'categoryIds': categoryIds,
        if (workIds != null && workIds!.isNotEmpty) 'workIds': workIds,
        'tags': tags,
        if (searchHints != null && searchHints!.isNotEmpty)
          'searchHints': searchHints,
        if (coverColor != null) 'coverColor': coverColor,
        'assets': assets.map((a) => a.toJson()).toList(),
      };
}

class CatalogArtistRef {
  const CatalogArtistRef({
    required this.id,
    required this.role,
    this.display = false,
  });

  final String id;
  final String role;
  final bool display;

  factory CatalogArtistRef.fromJson(Map<String, Object?> json) {
    return CatalogArtistRef(
      id: (json['id'] as String?) ?? '',
      role: (json['role'] as String?) ?? '',
      display: (json['display'] as bool?) ?? false,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'role': role,
        'display': display,
      };
}

class CatalogCredit {
  const CatalogCredit({
    required this.name,
    required this.role,
    this.entityId,
    this.display = false,
  });

  final String name;
  final String role;
  final String? entityId;
  final bool display;

  factory CatalogCredit.fromJson(Map<String, Object?> json) {
    return CatalogCredit(
      name: (json['name'] as String?) ?? '',
      role: (json['role'] as String?) ?? '',
      entityId: json['entityId'] as String?,
      display: (json['display'] as bool?) ?? false,
    );
  }

  Map<String, Object?> toJson() => {
        'name': name,
        'role': role,
        if (entityId != null) 'entityId': entityId,
        'display': display,
      };
}

class CatalogAsset {
  const CatalogAsset({
    required this.type,
    required this.uri,
    required this.version,
    required this.hash,
    required this.size,
  });

  final String type; // video | vocal | inst | cover | krl
  final String uri;
  final int version;
  final String hash;
  final int size;

  factory CatalogAsset.fromJson(Map<String, Object?> json) {
    return CatalogAsset(
      type: (json['type'] as String?) ?? '',
      uri: (json['uri'] as String?) ?? '',
      version: (json['version'] as num?)?.toInt() ?? 1,
      hash: (json['hash'] as String?) ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, Object?> toJson() => {
        'type': type,
        'uri': uri,
        'version': version,
        'hash': hash,
        'size': size,
      };
}

// ═════════════════════════════════════════════════════════════════════
// Rankings
// ═════════════════════════════════════════════════════════════════════

class CatalogRanking {
  const CatalogRanking({
    required this.categoryId,
    required this.name,
    this.entries = const [],
  });

  final String? categoryId; // null = 总榜
  final String name;
  final List<CatalogRankingEntry> entries;

  factory CatalogRanking.fromJson(Map<String, Object?> json) {
    return CatalogRanking(
      categoryId: json['categoryId'] as String?,
      name: (json['name'] as String?) ?? '',
      entries:
          _parseList(json['entries'], CatalogRankingEntry.fromJson),
    );
  }

  Map<String, Object?> toJson() => {
        if (categoryId != null) 'categoryId': categoryId,
        'name': name,
        'entries': entries.map((e) => e.toJson()).toList(),
      };
}

class CatalogRankingEntry {
  const CatalogRankingEntry({
    required this.rank,
    required this.songId,
    this.score,
    this.playCount,
  });

  final int rank;
  final String songId;
  final num? score;
  final int? playCount;

  factory CatalogRankingEntry.fromJson(Map<String, Object?> json) {
    return CatalogRankingEntry(
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      songId: (json['songId'] as String?) ?? '',
      score: json['score'] as num?,
      playCount: (json['playCount'] as num?)?.toInt(),
    );
  }

  Map<String, Object?> toJson() => {
        'rank': rank,
        'songId': songId,
        if (score != null) 'score': score,
        if (playCount != null) 'playCount': playCount,
      };
}

// ═════════════════════════════════════════════════════════════════════
// 解析辅助
// ═════════════════════════════════════════════════════════════════════

List<String> _stringList(Object? value) {
  if (value is List) {
    return value.map((e) => e.toString()).toList(growable: false);
  }
  return const [];
}

List<String>? _nullableStringList(Object? value) {
  if (value == null) return null;
  if (value is List && value.isEmpty) return null;
  return _stringList(value);
}

List<T> _parseList<T>(Object? value, T Function(Map<String, Object?>) fromJson) {
  if (value is List) {
    return value
        .whereType<Map<String, Object?>>()
        .map(fromJson)
        .toList(growable: false);
  }
  return const [];
}

// ═════════════════════════════════════════════════════════════════════
// LabelMaps — 服务器下发的枚举展示文案
// ═════════════════════════════════════════════════════════════════════

class CatalogLabelMaps {
  const CatalogLabelMaps({
    this.artistTypes = const {},
    this.roles = const {},
    this.assetTypes = const {},
  });

  final Map<String, String> artistTypes;
  final Map<String, String> roles;
  final Map<String, String> assetTypes;

  factory CatalogLabelMaps.fromJson(Map<String, Object?> json) {
    return CatalogLabelMaps(
      artistTypes: _stringMap(json['artistTypes']),
      roles: _stringMap(json['roles']),
      assetTypes: _stringMap(json['assetTypes']),
    );
  }

  String artistTypeLabel(String type) => artistTypes[type] ?? type;
  String roleLabel(String role) => roles[role] ?? role;
  String assetTypeLabel(String type) => assetTypes[type] ?? type;
}

Map<String, String> _stringMap(Object? value) {
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), v.toString()));
  }
  return const {};
}

// ═════════════════════════════════════════════════════════════════════
// 顶层编解码
// ═════════════════════════════════════════════════════════════════════

class CatalogManifest {
  const CatalogManifest({
    this.artists = const [],
    this.songs = const [],
    this.categories = const [],
    this.rankings = const [],
    this.labelMaps,
  });

  final List<CatalogArtist> artists;
  final List<CatalogSong> songs;
  final List<CatalogCategory> categories;
  final List<CatalogRanking> rankings;
  final CatalogLabelMaps? labelMaps;

  /// 从各端点收集到的原始 JSON body 构造。
  factory CatalogManifest.fromRawJsonBodies({
    String artistsBody = '[]',
    String songsBody = '[]',
    String categoriesBody = '{}',
    String rankingsBody = '[]',
  }) {
    final catDecoded = jsonDecode(categoriesBody);
    List<CatalogCategory> categories;
    CatalogLabelMaps? labelMaps;

    if (catDecoded is Map<String, Object?>) {
      // 新格式: { "items": [...], "labelMaps": {...} }
      categories = _decodeJsonArrayObj(catDecoded['items'], CatalogCategory.fromJson);
      final lm = catDecoded['labelMaps'];
      labelMaps = lm is Map<String, Object?> ? CatalogLabelMaps.fromJson(lm) : null;
    } else if (catDecoded is List) {
      // 兼容旧格式: [...]
      categories = _decodeJsonArray(categoriesBody, CatalogCategory.fromJson);
    } else {
      categories = const [];
    }

    return CatalogManifest(
      artists: _decodeJsonArray(artistsBody, CatalogArtist.fromJson),
      songs: _decodeJsonArray(songsBody, CatalogSong.fromJson),
      categories: categories,
      rankings: _decodeJsonArray(rankingsBody, CatalogRanking.fromJson),
      labelMaps: labelMaps,
    );
  }

  Map<String, Object?> toJson() => {
        'artists': artists.map((a) => a.toJson()).toList(),
        'songs': songs.map((s) => s.toJson()).toList(),
        'categories': categories.map((c) => c.toJson()).toList(),
        'rankings': rankings.map((r) => r.toJson()).toList(),
        if (labelMaps != null) 'labelMaps': {},
      };
}

List<T> _decodeJsonArray<T>(
  String body,
  T Function(Map<String, Object?>) fromJson,
) {
  final decoded = jsonDecode(body);
  return _decodeJsonArrayObj(decoded, fromJson);
}

List<T> _decodeJsonArrayObj<T>(
  Object? decoded,
  T Function(Map<String, Object?>) fromJson,
) {
  if (decoded is! List) return const [];
  return decoded
      .whereType<Map<String, Object?>>()
      .map(fromJson)
      .toList(growable: false);
}
