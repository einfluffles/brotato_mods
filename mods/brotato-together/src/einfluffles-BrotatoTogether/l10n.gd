extends Reference
# The mod's own texts in the game's languages: translations.csv (UTF-8, header
# key,en,fr,zh,ja,ko,zh_TW,ru,pl,es,pt,de,tr,it, quoted cells for commas and line breaks) becomes
# one Translation per language column. An empty cell is left out: the game falls back to en.
# The same file, with the same API, is in every mod of this repo (each must work alone).

const LOG_NAME := "L10n"
const BOM := 0xFEFF


# Returns the number of keys added (0: no file or no header). A malformed file or row is
# logged as a warning; the rows that can be read are still used.
static func load_csv(path: String) -> int:
	var file := File.new()
	if file.open(path, File.READ) != OK:
		ModLoaderLog.warning("No translations: %s cannot be read" % path, LOG_NAME)
		return 0
	var header := file.get_csv_line()
	if header.size() > 0 and header[0].length() > 0 and header[0].ord_at(0) == BOM:
		header[0] = header[0].substr(1)
	if header.size() < 2 or header[0] != "key":
		ModLoaderLog.warning("No translations: %s has no header key,<locale>,..." % path, LOG_NAME)
		file.close()
		return 0
	var translations := []
	for i in range(1, header.size()):
		var translation := Translation.new()
		translation.locale = header[i].strip_edges()
		translations.append(translation)
	var keys := 0
	var skipped := 0
	while not file.eof_reached():
		var row := file.get_csv_line()
		if row.size() == 1 and row[0].strip_edges() == "":
			continue  # empty line, as at the end of the file
		if row.size() != header.size() or row[0].strip_edges() == "":
			skipped += 1
			continue
		keys += 1
		for i in range(1, row.size()):
			if row[i] != "":
				translations[i - 1].add_message(row[0].strip_edges(), row[i])
	file.close()
	for translation in translations:
		TranslationServer.add_translation(translation)
	if skipped > 0:
		ModLoaderLog.warning(
			"%s: %d malformed rows skipped (not %d cells or no key)" % [path, skipped, header.size()],
			LOG_NAME
		)
	return keys
