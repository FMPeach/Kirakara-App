# Future SQLite FTS Shape

The first prototype uses in-memory mock search. The local-first production path
should keep searchable catalog rows in SQLite and expose FTS over:

- song title
- artist name
- song code
- aliases
- tags and category
- romanization / kana / pinyin helpers

Room state remains outside cloud catalog sync. Queue and playback state are
local authority data.
