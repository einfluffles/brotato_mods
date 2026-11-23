extends Reference
# JSON.print for text a client parses. Godot prints a NaN float as nan and an infinite one as inf
# or -inf, which JSON.parse rejects (error 43): the client loses the whole text. The game can make
# such values (a stat divided by a stat gain of 0, say) and its own save has the same problem.
# to_text() checks the printed text for such a value (two finds on it, see has_non_finite); only
# on a hit it prints a copy again with each of them as 0, and warns with their paths (once per path
# per WARN_INTERVAL_MSEC). The data itself (the game's RunData) is never changed.

const LOG_NAME := "einfluffles-BrotatoTogether:FiniteJson"
const META_KEY := "bt_non_finite_json"  # Engine meta: {count, logged {path: msec}, unlogged}
const WARN_INTERVAL_MSEC := 60000
const TOKENS := ["nan", "inf"]  # "-inf" is "inf" after a "-"
const BEFORE := ":,["  # what JSON.print puts before a value (no spaces without an indent)
const AFTER := ",]}"


# JSON.print(value) with every NaN or infinite float as 0. root: the path of value, for the
# warning ("p1", "crate item item_x").
static func to_text(value, root := "") -> String:
	var text := JSON.print(value)
	if not has_non_finite(text):
		return text
	var found := []
	var copy = finite(value, root, found)
	if found.empty():
		return text  # the token was inside a string ("a:nan,"): the text is valid
	_warn(found)
	return JSON.print(copy)


# Whether text (JSON.print's) has a bare nan, inf or -inf as a value: after ":", "," or "[" (or
# the whole text) and before ",", "]" or "}" (or the end). One inside a string ("banana",
# "infinite") is not; a string with the very same characters ("x:nan,") is a false hit that
# finite() then finds nothing in.
static func has_non_finite(text: String) -> bool:
	for token in TOKENS:
		var at := text.find(token)
		while at >= 0:
			if _is_value(text, at, token.length()):
				return true
			at = text.find(token, at + token.length())
	return false


static func _is_value(text: String, at: int, length: int) -> bool:
	var start := at
	if start > 0 and text[start - 1] == "-":
		start -= 1
	if start > 0 and not text[start - 1] in BEFORE:
		return false
	var end := at + length
	return end == text.length() or text[end] in AFTER


# value with every NaN or infinite float replaced by 0: value itself when it has none, else a copy
# (new containers only along the paths that changed). found gets [path, the value as printed] for
# each. A key's path is only formatted on the way to a container or to a hit.
static func finite(value, path: String, found: Array):
	match typeof(value):
		TYPE_REAL:
			if is_nan(value) or is_inf(value):
				found.append([path, str(value)])
				return 0.0
		TYPE_DICTIONARY:
			var copy = null  # a shallow copy once a value in it changes
			for key in value:
				if not _may_change(value[key]):
					continue
				var before := found.size()
				var fixed = finite(value[key], _path(path, key), found)
				if found.size() != before:
					if copy == null:
						copy = value.duplicate()
					copy[key] = fixed
			return copy if copy != null else value
		TYPE_ARRAY, TYPE_REAL_ARRAY:
			var copy = null
			for i in value.size():
				if not _may_change(value[i]):
					continue
				var before := found.size()
				var fixed = finite(value[i], "%s[%d]" % [path, i], found)
				if found.size() != before:
					if copy == null:
						copy = Array(value) if typeof(value) == TYPE_REAL_ARRAY else value.duplicate()
					copy[i] = fixed
			return copy if copy != null else value
	return value


static func _may_change(item) -> bool:
	match typeof(item):
		TYPE_REAL:
			return is_nan(item) or is_inf(item)
		TYPE_DICTIONARY, TYPE_ARRAY, TYPE_REAL_ARRAY:
			return true
	return false


# A dictionary key in a path: a key the game hashed (Keys.generate_hash: effects, tracked item
# effects; a string of digits once parsed from JSON) by its name.
static func _path(path: String, key) -> String:
	var name := str(key)
	if name.is_valid_integer() and Keys.hash_to_string.has(int(name)):
		name = Keys.hash_to_string[int(name)]
	return name if path == "" else "%s.%s" % [path, name]


# Values replaced since the game started (all paths), for the tests.
static func replaced_count() -> int:
	return Engine.get_meta(META_KEY).count if Engine.has_meta(META_KEY) else 0


static func _warn(found: Array) -> void:
	if not Engine.has_meta(META_KEY):
		Engine.set_meta(META_KEY, {"count": 0, "logged": {}, "unlogged": {}})
	var warnings: Dictionary = Engine.get_meta(META_KEY)
	var now := OS.get_ticks_msec()
	warnings.count += found.size()
	for entry in found:
		var path: String = entry[0] if entry[0] != "" else "(the whole value)"
		if warnings.logged.has(path) and now - warnings.logged[path] < WARN_INTERVAL_MSEC:
			warnings.unlogged[path] = warnings.unlogged.get(path, 0) + 1
			continue
		var text := (
			"%s at %s sent as 0: JSON has no such number (the game's own value stays)"
			% [entry[1], path]
		)
		var more: int = warnings.unlogged.get(path, 0)
		if more > 0:
			text += " (%d more times since the last warning)" % more
		ModLoaderLog.warning(text, LOG_NAME)
		warnings.logged[path] = now
		warnings.unlogged.erase(path)
