class Artist {
  const Artist({
    required this.id,
    required this.name,
    this.sortName,
    this.avatarUrl,
  });

  final String id;
  final String name;
  final String? sortName;
  final String? avatarUrl;
}
