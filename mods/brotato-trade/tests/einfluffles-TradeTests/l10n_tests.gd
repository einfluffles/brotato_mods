extends Reference
# The mod's texts in the game's languages: translations.csv (columns, keys, placeholders), its
# loader, the game's keys the mod reuses, every key the sources name, a language switch in the
# shop (en, de, ja) on the Trade button and the hint, and the game's fonts for every text.

const L10n := preload("res://mods-unpacked/einfluffles-BrotatoTrade/l10n.gd")
const MOD_DIR := "res://mods-unpacked/einfluffles-BrotatoTrade/"
const CSV := MOD_DIR + "translations.csv"
const HEADER := [
	"key", "en", "fr", "zh", "ja", "ko", "zh_TW", "ru", "pl", "es", "pt", "de", "tr", "it"
]
const PREFIX := "BTR_"
const VANILLA_KEYS := ["COOP_PLAYER", "MENU_COMBINE", "MENU_CANCEL"]
const SWITCH := ["en", "de", "ja"]
# CoopShopHint.set_text: from this many characters the hint takes the small font and scrolls.
const HINT_LONG := 30

var _t: Node = null
var _rows := {}  # key -> {locale: text}
var _locale := ""
var _button_width := 0.0  # the popup's buttons and the popup in English
var _popup_width := 0.0
var _language = null  # headless: no Steam, so no language setting (tools/check.sh)


func run(t: Node):
	_t = t
	_locale = TranslationServer.get_locale()
	_language = ProgressData.settings.language
	_csv()
	_loader()
	_vanilla()
	_sources()
	t.coop_run(2)
	var plain = t.item_with_limit(-1)
	RunData.add_item(plain, 0)
	var shop = yield(t.open_shop(), "completed")
	yield(_switch(shop, plain), "completed")
	_fonts(shop)
	ProgressData.settings.language = _language
	TranslationServer.set_locale(_locale)
	yield(t.frames(1), "completed")


func _csv() -> void:
	var file := File.new()
	_t.check(file.open(CSV, File.READ) == OK, "the mod ships translations.csv")
	if not file.is_open():
		return
	var header := Array(file.get_csv_line())
	_t.check(header == HEADER, "its columns are the game's languages in the game's order")
	var cells_ok := true
	var placeholders_ok := true
	var keys_ok := true
	while not file.eof_reached():
		var row := Array(file.get_csv_line())
		if row.size() == 1 and row[0] == "":
			continue
		var key: String = row[0]
		keys_ok = keys_ok and key.begins_with(PREFIX) and not key in _rows
		if row.size() != HEADER.size():
			cells_ok = false
			_t.check(false, "%s has %d cells" % [key, row.size()])
			continue
		var texts := {}
		var english := _placeholders(row[1])
		for column in range(1, HEADER.size()):
			texts[HEADER[column]] = row[column]
			if row[column].strip_edges().empty():
				cells_ok = false
				_t.check(false, "%s: %s is filled" % [key, HEADER[column]])
			elif _placeholders(row[column]) != english:
				placeholders_ok = false
				_t.check(false, "%s: %s has the placeholders of en" % [key, HEADER[column]])
		_rows[key] = texts
	file.close()
	_t.check(not _rows.empty() and keys_ok, "its keys are unique and start with %s" % PREFIX)
	_t.check(cells_ok, "every language has every text (%d keys)" % _rows.size())
	_t.check(placeholders_ok, "every text has the {n} placeholders of its English one")


func _placeholders(text: String) -> Array:
	var found := []
	var regex := RegEx.new()
	regex.compile("\\{\\d+\\}")
	for hit in regex.search_all(text):
		found.append(hit.get_string())
	found.sort()
	return found


# The loader on files of its own, under keys of the test's own.
func _loader() -> void:
	var path := "user://trade_l10n_test.csv"
	var file := File.new()
	file.open(path, File.WRITE)
	file.store_string(
		"key,en,de,zh_TW\n"
		+ "TRADE_TEST_ONE,One,\"Eins, zwei\nund drei\",一\n"
		+ "TRADE_TEST_TWO,Two,,\n"
		+ "TRADE_TEST_BAD,only two cells\n"
	)
	file.close()
	_t.check(L10n.load_csv(path) == 2, "the loader counts the rows it read, without a bad one")
	TranslationServer.set_locale("de")
	_t.check(tr("TRADE_TEST_ONE") == "Eins, zwei\nund drei", "a quoted cell with a comma and a break")
	_t.check(tr("TRADE_TEST_TWO") == "Two", "an empty cell falls back to en")
	_t.check(tr("TRADE_TEST_BAD") == "TRADE_TEST_BAD", "a row with too few cells is skipped")
	TranslationServer.set_locale("zh_TW")
	_t.check(tr("TRADE_TEST_ONE") == "一", "zh_TW has a translation of its own")
	TranslationServer.set_locale(_locale)
	file.open(path, File.WRITE)
	file.store_string("en,de\nTRADE_TEST_THREE,Drei\n")
	file.close()
	_t.check(L10n.load_csv(path) == 0, "a file without the key column adds nothing")
	_t.check(L10n.load_csv("user://trade_l10n_missing.csv") == 0, "nor does a missing file")
	Directory.new().remove(path)


func _vanilla() -> void:
	var vanilla_ok := true
	var own_ok := true
	for locale in ProgressData.languages:
		TranslationServer.set_locale(locale)
		for key in VANILLA_KEYS:
			if tr(key) == key:
				vanilla_ok = false
				_t.check(false, "the game has %s in %s" % [key, locale])
		for key in _rows:
			if tr(key) != _rows[key][locale]:
				own_ok = false
				_t.check(false, "%s in %s: %s" % [key, locale, tr(key)])
	TranslationServer.set_locale(_locale)
	_t.check(
		vanilla_ok,
		"the game's keys the mod uses exist in all %d languages" % ProgressData.languages.size()
	)
	_t.check(own_ok, "the mod's keys show the CSV's text in every language")
	var paths: Array = ProjectSettings.get_setting("locale/translations")
	var clash := []
	for path in paths:
		var translation = load(path)
		for key in _rows:
			if translation is Translation and translation.get_message(key) != "":
				clash.append("%s in %s" % [key, path.get_file()])
	_t.check(
		paths.size() >= ProgressData.languages.size() and clash.empty(),
		"without the CSV the game knows none of the mod's keys %s" % [clash]
	)


func _sources() -> void:
	var regex := RegEx.new()
	regex.compile("\"(%s[A-Z0-9_]+)\"" % PREFIX)
	var used := {}
	for path in _scripts(MOD_DIR):
		var file := File.new()
		file.open(path, File.READ)
		for hit in regex.search_all(file.get_as_text()):
			used[hit.get_string(1)] = path.get_file()
		file.close()
	var missing := []
	for key in used:
		if not key in _rows:
			missing.append("%s (%s)" % [key, used[key]])
	var unused := []
	for key in _rows:
		if not key in used:
			unused.append(key)
	_t.check(
		not used.empty() and missing.empty(),
		"every key the sources name is in the CSV %s" % [missing]
	)
	_t.check(unused.empty(), "and the sources use every key of the CSV %s" % [unused])


func _scripts(dir_path: String) -> Array:
	var found := []
	var dir := Directory.new()
	if dir.open(dir_path) != OK:
		return found
	dir.list_dir_begin(true, true)
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			found += _scripts(dir_path.plus_file(entry))
		elif entry.ends_with(".gd"):
			found.append(dir_path.plus_file(entry))
		entry = dir.get_next()
	dir.list_dir_end()
	return found


# The game's language menu, while the popup shows Trade and the hint.
func _switch(shop: Node, plain):
	var popup = shop._get_item_popup(0)
	var emulator = Utils.get_focus_emulator(0, shop)
	emulator.focused_control = _element(shop, plain)
	yield(_t.frames(1), "completed")
	var hint = popup._trade_hint
	_t.check(popup.visible and hint.visible, "(the own item's popup shows the trade hint)")
	yield(_t.tap("ui_accept", 0), "completed")
	var button: Button = popup._trade_button
	_t.check(popup._focused and button.visible, "(and, opened, the Trade button)")
	var seen := []
	for locale in SWITCH:
		ProgressData.change_language(locale)
		yield(_t.frames(1), "completed")
		var shown := _hint_text(hint)
		var wanted: String = _rows["BTR_TRADE_HINT"][locale].replace("{0}", " ")
		_t.check(
			button.text == "BTR_TRADE" and tr(button.text) == _rows["BTR_TRADE"][locale],
			"%s: the button reads %s" % [locale, tr(button.text)]
		)
		_t.check(
			_squash(shown) == _squash(wanted) and not PREFIX in shown,
			"%s: the hint reads %s" % [locale, shown]
		)
		seen.append(shown)
		if locale == "en":
			_button_width = popup._cancel_button.rect_size.x
			_popup_width = popup.rect_size.x
	_t.check(seen[0] != seen[1] and seen[1] != seen[2], "the hint follows each language change")
	yield(_t.tap("ui_cancel", 0), "completed")
	yield(_t.frames(1), "completed")


func _hint_text(hint) -> String:
	return "%s %s" % [hint._label1.text, hint._label2.text]


func _squash(text: String) -> String:
	return text.replace(" ", "")


# Every text in the fonts the game draws it with: the popup button's and both of the hint's.
# The game's fonts carry Noto Sans CJK fallbacks; a character none of them has shows as a box.
func _fonts(shop: Node) -> void:
	var popup = shop._get_item_popup(0)
	var hint = popup._trade_hint
	var button: Button = popup._trade_button
	var fonts := {
		"button": button.get_font("font"), "hint": hint.normal_font, "small hint": hint.small_font
	}
	var missing := []
	for font_name in fonts:
		var font = fonts[font_name]
		if not font is DynamicFont:
			missing.append("%s is no DynamicFont" % font_name)
			continue
		var chars: String = font.get_available_chars()
		if chars.find("A") == -1 or chars.find("渡") == -1 or chars.find("ᚠ") != -1:
			missing.append("%s: the check cannot tell (A, 渡, no runic ᚠ)" % font_name)
		for key in _rows:
			for locale in _rows[key]:
				var text: String = _rows[key][locale].replace("{0}", "")
				for i in text.length():
					if text[i] != " " and chars.find(text[i]) == -1:
						missing.append("%s %s %s '%s'" % [font_name, key, locale, text[i]])
	_t.check(missing.empty(), "the game's fonts have every character of every text %s" % [missing])

	# Widths against the English popup: Trade within its buttons' width, a short hint (the normal
	# font) within the popup. From HINT_LONG characters CoopShopHint scrolls in the small font.
	var margins: float = button.get_stylebox("normal").get_minimum_size().x
	var wide := []
	var long := []
	for locale in _rows["BTR_TRADE"]:
		var width: float = fonts["button"].get_string_size(_rows["BTR_TRADE"][locale]).x + margins
		if width > _button_width:
			wide.append("%s %d px" % [locale, width])
		var parts: Array = _rows["BTR_TRADE_HINT"][locale].split("{0}")
		var one: String = parts[0].strip_edges()
		var two: String = parts[1].strip_edges()
		if one.length() + two.length() >= HINT_LONG:
			long.append(locale)
			continue
		var font: Font = hint.normal_font
		var line: float = font.get_string_size(one).x + font.get_string_size(two).x
		line += hint._key_icon.rect_min_size.x + 2 * hint._hbox_container.get_constant("separation")
		if line > _popup_width:
			wide.append("hint %s %d px" % [locale, line])
	_t.check(
		_button_width > 0 and wide.empty(),
		"every text fits the popup (%d px buttons, %d px popup) %s" % [_button_width, _popup_width, wide]
	)
	print("  info: hints in the small scrolling font: %s" % [long])


func _element(shop: Node, item):
	var container = shop._get_gear_container(0).items_container
	for element in container._elements.get_children():
		if not element.is_queued_for_deletion() and element.item != null:
			if element.item.my_id == item.my_id:
				return element
	return null
