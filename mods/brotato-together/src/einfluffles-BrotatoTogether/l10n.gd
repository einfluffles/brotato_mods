extends Reference
# The mod's own texts in the game's languages: translations.csv (UTF-8, header
# key,en,fr,zh,ja,ko,zh_TW,ru,pl,es,pt,de,tr,it, quoted cells for commas and line breaks) becomes
# one Translation per language column. An empty cell is left out: the game falls back to en.
# The same file, with the same API, is in every mod of this repo (each must work alone).
#
# The file is read in one piece (get_buffer) and parsed here, never with File.get_csv_line or a
# loop on eof_reached(): in a mod's zip, as the Workshop delivers the mod, Godot 3.6 leaves the
# end-of-file flag uninitialized until the first read, and get_csv_line asks it before reading
# (brotato:together's docs/implementation.md, "Localization").

const LOG_NAME := "L10n"
const BOM := 0xFEFF
const QUOTE := 34  # "
const NEWLINE := 10  # \n


# Returns the number of keys added (0: no file or no header). A malformed file or row is
# logged as a warning; the rows that can be read are still used.
static func load_csv(path: String) -> int:
	var file := File.new()
	if file.open(path, File.READ) != OK:
		ModLoaderLog.warning("No translations: %s cannot be read" % path, LOG_NAME)
		return 0
	var length := file.get_len()
	var text := file.get_buffer(length).get_string_from_utf8() if length > 0 else ""
	file.close()
	var rows := parse_csv(text)
	var header: Array = rows[0] if not rows.empty() else []
	if header.size() < 2 or header[0] != "key":
		ModLoaderLog.warning("No translations: %s has no header key,<locale>,..." % path, LOG_NAME)
		return 0
	var translations := []
	for i in range(1, header.size()):
		var translation := Translation.new()
		translation.locale = header[i].strip_edges()
		translations.append(translation)
	var keys := 0
	var skipped := 0
	for r in range(1, rows.size()):
		var row: Array = rows[r]
		if row.size() == 1 and row[0].strip_edges() == "":
			continue  # an empty line
		if row.size() != header.size() or row[0].strip_edges() == "":
			skipped += 1
			continue
		keys += 1
		for i in range(1, row.size()):
			if row[i] != "":
				translations[i - 1].add_message(row[0].strip_edges(), row[i])
	for translation in translations:
		TranslationServer.add_translation(translation)
	if skipped > 0:
		ModLoaderLog.warning(
			"%s: %d malformed rows skipped (not %d cells or no key)" % [path, skipped, header.size()],
			LOG_NAME
		)
	return keys


# The rows of a CSV text, each an Array of its cells (RFC 4180): cells separated by commas, a
# cell in double quotes may hold commas, line breaks and doubled quotes ("" for one). CRLF counts
# as LF, a UTF-8 BOM at the start is dropped, a line break at the end ends the last row (no empty
# row after it), an empty line is a row of one empty cell. A quote inside an unquoted cell, or
# after a quoted cell's closing quote, is kept as it is. A row whose quoted cell never closes is
# [] (a row of the wrong size for any header).
static func parse_csv(text: String) -> Array:
	text = text.replace("\r\n", "\n")
	if text.length() > 0 and text.ord_at(0) == BOM:
		text = text.substr(1)
	var rows := []
	var length := text.length()
	if length == 0:
		return rows
	var row := []
	var at := 0
	var line_end := -1  # the next line break at or after `at` (length: none)
	while true:
		var cell := ""
		if at < length and text.ord_at(at) == QUOTE:
			var closed := false
			at += 1
			while true:
				var quote := text.find("\"", at)
				if quote == -1:
					break
				cell += text.substr(at, quote - at)
				at = quote + 1
				if at < length and text.ord_at(at) == QUOTE:
					cell += "\""
					at += 1
				else:
					closed = true
					break
			if not closed:
				rows.append([])
				return rows
		if line_end < at:
			line_end = text.find("\n", at)
			if line_end == -1:
				line_end = length
		var comma := text.find(",", at)
		var end := line_end if comma == -1 or comma > line_end else comma
		cell += text.substr(at, end - at)
		row.append(cell)
		if end >= length:
			rows.append(row)
			return rows
		at = end + 1
		if text.ord_at(end) == NEWLINE:
			rows.append(row)
			row = []
			if at >= length:
				return rows
	return rows
