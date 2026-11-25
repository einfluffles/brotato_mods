extends Reference
# Suite non_finite: a NaN or infinite number in the run state. Godot's JSON.print writes it as
# nan / inf / -inf, which JSON.parse rejects. The host sends it as 0 (sync/finite_json.gd), and a
# client keeps its run state when a part cannot be read (RunParts.Store), so its level-up panels
# still show. client_panels runs inside suite upgrades_change, which has the panels up.

const FiniteJson := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/finite_json.gd")
const RunParts := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_parts.gd")
const RunCache := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_cache.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const LATE_ITEMS := 250
const SCANS := 20
const BAD_TEXT := '{"a":nan}'  # a part as a host without FiniteJson printed it

var _t: Node = null


func _init(t: Node) -> void:
	_t = t


func run() -> void:
	_test_print()
	_test_scan()
	_test_to_text()
	_test_cache()
	_test_fingerprint()
	_test_store()
	_measure_scan()


# What the scan looks for is what Godot prints.
func _test_print() -> void:
	var printed := JSON.print([NAN, INF, -INF])
	_t._check(
		printed in ["[nan,inf,-inf]", "[nan,1.#INF,-1.#INF]"] and JSON.parse(printed).error != OK,
		"non-finite: JSON.print writes nan and inf (1.#INF on Windows), JSON.parse rejects them (%s)"
		% printed
	)
	for value in [NAN, INF, -INF]:
		_t._check(
			FiniteJson.has_non_finite(JSON.print([value])),
			"non-finite: the scan finds %s as this build prints it" % JSON.print([value])
		)


func _test_scan() -> void:
	var hits := ["nan", "[inf]", '{"a":nan}', '{"a":-inf,"b":1}', "[1,nan]", '{"a":{"b":inf}}']
	hits += ["[1.#INF]", '{"a":-1.#INF}', "[1,-1.#IND]", '{"a":1.#QNAN,"b":2}', "1.#SNAN"]
	for text in hits:
		_t._check(FiniteJson.has_non_finite(text), "non-finite: the scan finds %s" % text)
	var misses := [
		'{"id":"banana"}',
		'{"text":"infinite"}',
		'{"nan":1}',
		'{"a":"nan"}',
		'["inf"]',
		'{"a":"1.#INF"}',
		'{"a":"-inf"}',
		'{"info":2,"x":"nanobot"}',
		"",
	]
	for text in misses:
		_t._check(not FiniteJson.has_non_finite(text), "non-finite: the scan passes %s" % text)


func _test_to_text() -> void:
	var count := FiniteJson.replaced_count()
	var data := {
		"a": NAN,
		"b": [1.5, INF, {"c": -INF, "id": "banana"}],
		"d": "infinite",
		"e": PoolRealArray([2.0, NAN]),
		"effects": {Keys.stat_luck_hash: NAN},
	}
	var parsed := JSON.parse(FiniteJson.to_text(data, "root"))
	var got = parsed.result if parsed.error == OK else {}
	_t._check(
		parsed.error == OK
		and got.get("a") == 0.0
		and got.b.slice(0, 1) == [1.5, 0.0]
		and got.b[2].get("c") == 0.0
		and got.b[2].get("id") == "banana"
		and got.d == "infinite"
		and got.e == [2.0, 0.0]
		and got.effects.get(str(Keys.stat_luck_hash)) == 0.0,
		"non-finite: NaN, inf and -inf go out as 0, strings and other numbers as they are"
	)
	_t._check(
		is_nan(data.a) and is_inf(data.b[1]) and data.b[2].c < 0 and is_inf(data.b[2].c)
		and is_nan(data.e[1]) and is_nan(data.effects[Keys.stat_luck_hash]),
		"non-finite: the printed data keeps its values"
	)
	var warnings: Dictionary = Engine.get_meta(FiniteJson.META_KEY)
	var paths := ["root.a", "root.b[1]", "root.b[2].c", "root.e[1]", "root.effects.stat_luck"]
	var logged := true
	for path in paths:
		logged = logged and warnings.logged.has(path)
	_t._check(
		FiniteJson.replaced_count() == count + paths.size() and logged,
		"non-finite: a warning per path, the hashed key by its name"
	)
	FiniteJson.to_text(data, "root")
	_t._check(
		warnings.unlogged.get("root.a") == 1 and FiniteJson.replaced_count() == count + 10,
		"non-finite: the same path again within the interval is counted, not logged"
	)
	var clean := {"a": 1.25, "s": "x:nan,", "t": ["inf"]}  # the scan's false hit: no value to fix
	_t._check(
		FiniteJson.to_text(clean) == JSON.print(clean)
		and FiniteJson.replaced_count() == count + 10,
		"non-finite: a text without such a number is JSON.print's, also on a false hit"
	)
	_test_warn_limits(warnings)


# Many paths in one print: MAX_LINES lines and one summary; the remembered paths stay bounded.
func _test_warn_limits(warnings: Dictionary) -> void:
	var many := []
	for i in 40:
		many.append(NAN)
	var lines: int = warnings.lines
	FiniteJson.to_text(many, "many")
	_t._check(
		warnings.lines == lines + FiniteJson.MAX_LINES + 1 and warnings.logged.has("many[39]"),
		"non-finite: 40 paths at once give %d lines and a summary (%d)"
		% [FiniteJson.MAX_LINES, warnings.lines - lines]
	)
	var old := OS.get_ticks_msec() - FiniteJson.WARN_INTERVAL_MSEC - 1
	for i in FiniteJson.MAX_PATHS:
		warnings.logged["old %d" % i] = old
		warnings.unlogged["old %d" % i] = 1
	FiniteJson.to_text({"x": INF}, "fresh")
	_t._check(
		warnings.logged.size() <= FiniteJson.MAX_PATHS
		and not warnings.logged.has("old 0")
		and not warnings.unlogged.has("old 0")
		and warnings.logged.has("fresh.x")
		and warnings.logged.has("many[39]"),
		"non-finite: past %d paths the expired ones are dropped (%d left)"
		% [FiniteJson.MAX_PATHS, warnings.logged.size()]
	)
	for i in FiniteJson.MAX_PATHS + 1:
		warnings.logged["recent %d" % i] = OS.get_ticks_msec()
	FiniteJson.to_text({"y": NAN}, "full")
	_t._check(
		warnings.logged.empty() and warnings.unlogged.empty(),
		"non-finite: still too many: all are dropped (%d left)" % warnings.logged.size()
	)


# The host's run parts: valid JSON, the value as 0 under its path, RunData untouched.
func _test_cache() -> void:
	var luck: Dictionary = RunData.get_player_effects(0)
	var max_hp: Dictionary = RunData.get_player_effects(1)
	var saved := [luck[Keys.stat_luck_hash], max_hp[Keys.stat_max_hp_hash]]
	var saved_xp: float = RunData.players_data[1].current_xp
	luck[Keys.stat_luck_hash] = NAN
	max_hp[Keys.stat_max_hp_hash] = -INF
	RunData.players_data[1].current_xp = INF
	var cache = RunCache.new("non-finite test")
	var screen := Node.new()
	cache.refresh(screen)
	var valid: bool = not cache.parts.empty()
	for key in cache.parts:
		valid = valid and JSON.parse(cache.parts[key].text).error == OK
	var p0 = JSON.parse(cache.parts.p0.text).result
	var p1 = JSON.parse(cache.parts.p1.text).result
	_t._check(
		valid
		and p0.effects.get(str(Keys.stat_luck_hash)) == 0.0
		and p1.effects.get(str(Keys.stat_max_hp_hash)) == 0.0
		and p1.get("current_xp") == 0.0,
		"non-finite: the host's run parts are valid JSON, with 0 for NaN, inf and -inf"
	)
	_t._check(
		is_nan(luck[Keys.stat_luck_hash]) and is_inf(max_hp[Keys.stat_max_hp_hash])
		and is_inf(RunData.players_data[1].current_xp),
		"non-finite: RunData keeps its values"
	)
	var logged: Dictionary = Engine.get_meta(FiniteJson.META_KEY).logged
	_t._check(
		logged.has("p0.effects.stat_luck") and logged.has("p1.effects.stat_max_hp")
		and logged.has("p1.current_xp"),
		"non-finite: the warnings name the part and the path"
	)
	luck[Keys.stat_luck_hash] = saved[0]
	max_hp[Keys.stat_max_hp_hash] = saved[1]
	RunData.players_data[1].current_xp = saved_xp
	screen.free()


# NaN != NaN: a NaN in the fingerprint (current_xp) must not make every check serialize.
func _test_fingerprint() -> void:
	var saved_xp: float = RunData.players_data[0].current_xp
	RunData.players_data[0].current_xp = NAN
	var cache = RunCache.new("non-finite test")
	var screen := Node.new()
	cache.refresh(screen)
	var serialized: int = cache.serialized
	cache.refresh(screen)
	cache.refresh(screen)
	_t._check(
		cache.serialized == serialized,
		"non-finite: a NaN xp leaves the fingerprint as it was (no serialization per check)"
	)
	_t._check(
		RunCache.same_values([1, NAN, 2.5], [1, NAN, 2.5])
		and not RunCache.same_values([1, NAN], [1, 0.0])
		and not RunCache.same_values([1, 2], [1, 3]),
		"non-finite: fingerprints compare a NaN equal to a NaN, and only to one"
	)
	RunData.players_data[0].current_xp = saved_xp
	screen.free()


# A part that does not parse: parsed once, logged once, told apart from a missing one.
func _test_store() -> void:
	var store = RunParts.Store.new()
	var good := RunStateCodec.pack('{"x":1}')
	var bad := RunStateCodec.pack(BAD_TEXT)
	var ids := {"c": [1, 7], "p0": [2, 9]}
	var run := {
		"ids": ids,
		"parts": {
			"c": {"size": good.size, "data": good.data},
			"p0": {"size": bad.size, "data": bad.data},
		},
	}
	_t._check(store.ingest(run), "non-finite, client: an unreadable part is stored")
	var raws: Dictionary = store.raws(ids)
	_t._check(
		raws.c.get("x") == 1.0 and raws.p0 == null and store.unreadable == 1 and store.parsed == 1,
		"non-finite, client: its read fails, the others read"
	)
	store.raws(ids)
	store.state_for(ids)
	_t._check(
		store.unreadable == 1 and store.parsed == 1 and store.has_unreadable(ids),
		"non-finite, client: a failed part is not parsed (nor logged) again"
	)
	_t._check(
		not store.has_unreadable({"c": [1, 7]}) and not store.has_unreadable({"c": [1, 7], "p0": [3, 9]}),
		"non-finite, client: readable or missing parts are not unreadable"
	)


# What the scan costs the host on the parts of a late run (every part it prints is scanned).
func _measure_scan() -> void:
	var pool: Array = ItemService.items
	for i in LATE_ITEMS:
		RunData.add_item(pool[(i * 13) % pool.size()], 0)
	var parts := RunParts.split(RunStateCodec.serialize())
	var texts := []
	var chars := 0
	for key in parts:
		texts.append(JSON.print(parts[key]))
		chars += texts.back().length()
	var started := OS.get_ticks_usec()
	var hits := 0
	for _i in SCANS:
		for text in texts:
			hits += int(FiniteJson.has_non_finite(text))
	var scan := (OS.get_ticks_usec() - started) / float(SCANS)
	started = OS.get_ticks_usec()
	for _i in SCANS:
		for key in parts:
			JSON.print(parts[key])
	var printed := (OS.get_ticks_usec() - started) / float(SCANS)
	print(
		(
			"  info: non-finite scan of a late run (%d items, %d parts, %d chars): %.3f ms, "
			+ "JSON.print of the same parts %.2f ms"
		)
		% [LATE_ITEMS, parts.size(), chars, scan / 1000.0, printed / 1000.0]
	)
	_t._check(hits == 0, "non-finite: a late run without such numbers has no hit")


# The level-up panels of a client (player 1, a crate item open). Called by suite upgrades_change
# with the panels up; suite: that UpgradesChangeTests.
func client_panels(suite) -> void:
	var upgrades: Node = suite._sync
	var client: Node = suite._together.battle_client
	var saved_you: int = client._you
	var saved_store = upgrades.run_store
	client._you = 1
	var effects: Dictionary = RunData.get_player_effects(0)
	var saved = effects[Keys.stat_luck_hash]
	effects[Keys.stat_luck_hash] = NAN
	suite._cache.force()
	var body: Dictionary = upgrades.state_body(StateStream.UPGRADES).duplicate(true)
	effects[Keys.stat_luck_hash] = saved
	var valid := true
	for key in suite._cache.parts:
		valid = valid and JSON.parse(suite._cache.parts[key].text).error == OK
	_t._check(valid, "non-finite: the panels' run parts are valid JSON with a NaN in the run")
	_client_apply(upgrades, suite._main, body, true)
	_t._check(
		upgrades._local_active and upgrades.run_store.unreadable == 0,
		"non-finite, client: the own panel runs with a NaN in the host's run (sent as 0)"
	)
	var newer: Dictionary = body.duplicate(true)  # a later state with an unreadable part
	var bad := RunStateCodec.pack(BAD_TEXT)
	newer.run.ids["p0"] = [1, bad.size]
	newer.run.parts["p0"] = {"size": bad.size, "data": bad.data}
	_client_apply(upgrades, suite._main, newer, false)
	_t._check(
		upgrades._local_active
		and upgrades.run_store.unreadable == 1
		and RunParts.same_ids(upgrades._run_key, body.run.ids),
		"non-finite, client: a later unreadable part keeps the run applied and the own panel"
	)
	_client_apply(upgrades, suite._main, newer, true)  # a client that has no run yet
	_client_apply(upgrades, suite._main, newer, false)
	_t._check(
		upgrades._local_active and upgrades.run_store.unreadable == 1,
		"non-finite, client: with an unreadable part and no run yet, the panels run (one warning)"
	)
	upgrades._on_battle_left()
	upgrades.run_store = saved_store
	client._you = saved_you


func _client_apply(upgrades: Node, main: Node, body: Dictionary, fresh: bool) -> void:
	if fresh:
		upgrades.run_store = RunParts.Store.new()
		upgrades._guarded_ui = null
	upgrades.accept_state(StateStream.UPGRADES, body, 0)
	upgrades.apply(main, body)
