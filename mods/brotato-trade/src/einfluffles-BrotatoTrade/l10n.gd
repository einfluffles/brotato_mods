extends Reference
# The mod's texts in the game's languages: translations.csv, read at runtime into one Translation
# per language. A row is a key and its text per language, in the game's column order:
# key,en,fr,zh,ja,ko,zh_TW,ru,pl,es,pt,de,tr,it (UTF-8, cells with a comma or a line break
# quoted). An empty cell is left out, so Godot falls back to English. brotato:together has the
# same loader: this mod must work without it.

const LOG_NAME := "einfluffles-BrotatoTrade:L10n"


# Returns the number of keys added; 0 and a warning for a file that cannot be read.
static func load_csv(path: String) -> int:
	var file := File.new()
	if file.open(path, File.READ) != OK:
		ModLoaderLog.warning("Cannot open %s" % path, LOG_NAME)
		return 0
	var header: PoolStringArray = file.get_csv_line()
	if header.size() > 0:
		header[0] = header[0].trim_prefix("﻿")
	if header.size() < 2 or header[0] != "key":
		ModLoaderLog.warning("%s: the first line must be key,en,..." % path, LOG_NAME)
		file.close()
		return 0
	var translations := []
	for column in range(1, header.size()):
		var translation := Translation.new()
		translation.locale = header[column].strip_edges()
		translations.append(translation)
	var keys := 0
	var row_number := 1  # rows, not lines: a quoted cell can span lines
	while not file.eof_reached():
		var row: PoolStringArray = file.get_csv_line()
		row_number += 1
		if row.size() == 1 and row[0].strip_edges().empty():
			continue  # a blank line, or the end of the file
		var key := row[0].strip_edges() if row.size() > 0 else ""
		if row.size() != header.size() or key.empty():
			ModLoaderLog.warning(
				"%s, row %d: %d cells instead of %d, or no key: skipped" % [
					path, row_number, row.size(), header.size()
				],
				LOG_NAME
			)
			continue
		for column in range(1, header.size()):
			if not row[column].empty():
				translations[column - 1].add_message(key, row[column])
		keys += 1
	file.close()
	for translation in translations:
		TranslationServer.add_translation(translation)
	return keys
