extends Reference
# The run state in parts, so that a state stream body carries only the parts a client lacks
# (sections shop and upgrades: sync/shop_sync.gd, sync/upgrades_sync.gd).
#
# split(data) cuts RunStateCodec.serialize()'s dictionary into ordered parts:
#   "c": the dictionary with players_data replaced by its size (shop items, locked items,
#     counters and whatever other mods add stay here);
#   per player p "g<p>": {weapons, items} (the big lists);
#   per player p "p<p>": the rest of the player's dictionary (weapons and items kept as null, so
#     that join puts them back at their place and the JSON text is the same).
# join(parts) is the inverse. A part's id is [hash(part), length of its JSON text]: ids are
# compared, never the content. (Different content with equal ids, 1 in 2^32 and the same length,
# would keep a client on the old part until the next change, like RunCache's check before.)
#
# Wire format (the body's "run"): {"ids": {key: id}, "parts": {key: {size, data}}}: every key of
# the run with its id, and the zstd-compressed JSON of the parts the client does not have yet.
# {} when the run is the one the client was last sent (no id differs): the ids of four players
# are 350 of the 1100 bytes of a page flip. The client's store fills in the ids of the last run
# it got, in place (ingest), so that every later reader of the body sees them.
#
# Sender (host, one for ShopSync and UpgradesSync, created by mod_main.gd): what each peer was
# sent. The provider's state_body calls offer(its RunCache); state_patch calls run_for(peer),
# which lists every id and includes only the parts whose id differs from what that peer was last
# sent (or is {}, see above); the stream's state_sent hook calls commit(peer), which records that
# offer as sent.
# StateStream.message_for (tests) builds bodies without state_sent, so it records nothing.
# forget(peer) makes the next send to the peer full: on peer_ready (every provider calls it from
# its own handler; Godot 3 calls a signal's targets by object id, not in connection order, so it
# is idempotent per idle frame: the second call of one emission must not drop a commit made in
# between), on peer_removed and on lobby_left. Counters per screen (RunCache.label) for the log
# line when the screen closes (summary).
#
# Store (client, one for both handlers, created by mod_main.gd): ingest(run) at receive (the
# stream's accept_state hook: a body replaced while pending is never applied, so its parts must
# be stored when it arrives; take() is ingest plus the resync below) keeps the compressed parts
# by key and id, the last two of each key, and returns false when an id is neither stored nor
# delivered (the handler then asks the host for a full resync and applies nothing). ids_for(run)
# is the ids at apply time (it ingests a body that did not come through the stream: tests).
# Every body of both sections reaches the store in the order the host sent them (one reliable
# channel), so its last ids are the sender's record of the peer. state_for(ids) builds the run
# state: it decompresses and parses only parts it has not parsed yet, runs the game's
# deserializer (ProgressDataLoaderV3.deserialize_run_state) on a copy of "c" whose players_data
# holds only the players whose parts changed since the last state_for, and puts the
# PlayerRunData objects of that last state back for the others. changed_players() and
# gear_changed(p): what that state_for moved against the one before it (also over bodies
# replaced while pending).

const EffectArgs := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/effect_args.gd")
const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const COMMON := "c"
const GEAR_FIELDS := ["weapons", "items"]
const LOG_NAME := "einfluffles-BrotatoTogether:RunParts"


static func split(data: Dictionary) -> Dictionary:
	var parts := {}
	var common: Dictionary = data.duplicate()
	parts[COMMON] = common
	var players = data.get("players_data")
	if typeof(players) != TYPE_ARRAY:
		return parts
	common["players_data"] = players.size()
	for p in players.size():
		var rest = players[p]
		var gear := {}
		if typeof(rest) == TYPE_DICTIONARY:
			rest = rest.duplicate()
			for field in GEAR_FIELDS:
				if rest.has(field):
					gear[field] = rest[field]
					rest[field] = null
		parts["g%d" % p] = gear
		parts["p%d" % p] = rest
	return parts


static func join(parts: Dictionary) -> Dictionary:
	var common = parts.get(COMMON)
	if typeof(common) != TYPE_DICTIONARY:
		return {}
	var data: Dictionary = common.duplicate()
	var count = data.get("players_data")
	if typeof(count) != TYPE_INT and typeof(count) != TYPE_REAL:
		return data  # nothing split off (no players list)
	var players := []
	for p in int(count):
		players.append(Store.merge(parts.get("p%d" % p), parts.get("g%d" % p)))
	data["players_data"] = players
	return data


# A part as the host keeps it: {hash, id, size, data, text} (JSON printed and compressed once;
# text: its JSON when already printed).
static func entry(part, part_hash: int, text := "") -> Dictionary:
	if text == "":
		text = JSON.print(part)
	var packed := RunStateCodec.pack(text)
	return {
		"hash": part_hash,
		"id": [part_hash, text.length()],
		"size": packed.size,
		"data": packed.data,
		"text": text,
	}


# Every part of data in the wire format: what a client with nothing needs (tests).
static func pack_all(data: Dictionary) -> Dictionary:
	var parts := split(data)
	var run := {"ids": {}, "parts": {}}
	for key in parts:
		var packed := entry(parts[key], hash(parts[key]))
		run.ids[key] = packed.id
		run.parts[key] = {"size": packed.size, "data": packed.data}
	return run


# The paths under which old and new differ (hash() differs), for a log line: dictionary keys
# joined by ".", array elements as "[i]". A path ends where the values differ in type or are
# no dictionaries or arrays, depth levels down ("p1.effects.stat_max_hp"), or at an array whose
# size changed, with both sizes ("g0.items (250 -> 251)"); an array cut by depth keeps its size
# ("c.tracked_item_effects (4)"). A key on one side only: " (added)" / " (removed)". A key the
# game hashed from a name shows that name (_path). Only RunCache's miss warning calls it: one
# hash() per value it walks into.
static func changed_paths(old, new, depth := 3) -> Array:
	var paths := []
	_changed_paths(old, new, "", depth, paths)
	return paths


static func _changed_paths(old, new, path: String, depth: int, paths: Array) -> void:
	if typeof(old) == typeof(new) and hash(old) == hash(new):
		return
	if typeof(old) == TYPE_DICTIONARY and typeof(new) == TYPE_DICTIONARY and depth > 0:
		for key in new:
			var sub := _path(path, key)
			if old.has(key):
				_changed_paths(old[key], new[key], sub, depth - 1, paths)
			else:
				paths.append(sub + " (added)")
		for key in old:
			if not new.has(key):
				paths.append(_path(path, key) + " (removed)")
		return
	if typeof(old) == TYPE_ARRAY and typeof(new) == TYPE_ARRAY:
		if old.size() != new.size():
			paths.append("%s (%d -> %d)" % [path, old.size(), new.size()])
		elif depth > 0:
			for i in new.size():
				_changed_paths(old[i], new[i], "%s[%d]" % [path, i], depth - 1, paths)
		else:
			paths.append("%s (%d)" % [path, new.size()])
		return
	paths.append(path)


# A key the game hashed (Keys.generate_hash: effects, tracked item effects; a string of digits
# once parsed from JSON) by its name.
static func _path(path: String, key) -> String:
	var name := str(key)
	if name.is_valid_integer() and Keys.hash_to_string.has(int(name)):
		name = Keys.hash_to_string[int(name)]
	return name if path == "" else "%s.%s" % [path, name]


# Same keys and ids (dictionaries compare by reference in Godot 3).
static func same_ids(a, b) -> bool:
	if typeof(a) != TYPE_DICTIONARY or typeof(b) != TYPE_DICTIONARY or a.size() != b.size():
		return false
	for key in a:
		if not Store.same_id(a[key], b.get(key)):
			return false
	return true


class Sender:
	extends Reference
	# screen label -> {states, run_states, run_bytes, view_bytes, largest, parts {key: count}}
	var stats := {}
	var _cache = null  # the RunCache whose parts run_for offers
	var _sent := {}  # steam_id -> {key: id} as last committed
	var _offers := {}  # steam_id -> [label, ids, keys delivered, run bytes] of the last run_for
	var _forgotten := {}  # steam_id -> idle frame of its last forget

	func setup(session: Node) -> void:
		session.connect("peer_removed", self, "forget")
		session.transport.connect("lobby_left", self, "reset")

	# The parts the next run_for offers: the provider's RunCache, right after its refresh.
	func offer(cache) -> void:
		_cache = cache

	func run_for(steam_id: int) -> Dictionary:
		var ids := {}
		var parts := {}
		var had: Dictionary = _sent.get(steam_id, {})
		var label := ""
		if _cache != null:
			label = _cache.label
			for key in _cache.parts:
				var part: Dictionary = _cache.parts[key]
				ids[key] = part.id
				if not Store.same_id(had.get(key), part.id):
					parts[key] = {"size": part.size, "data": part.data}
		var run := {"ids": ids, "parts": parts}
		if parts.empty() and not ids.empty() and had.size() == ids.size():
			run = {}  # what the peer was last sent: the client takes its last ids
		_offers[steam_id] = [label, ids, parts.keys(), var2bytes(run).size()]
		return run

	# The last run_for for the peer went out. view_bytes: the rest of the body, for the counters.
	func commit(steam_id: int, view_bytes := 0) -> void:
		var offer = _offers.get(steam_id)
		if offer == null:
			return
		_offers.erase(steam_id)
		_sent[steam_id] = offer[1].duplicate()
		_count(offer, view_bytes)

	func forget(steam_id: int) -> void:
		var frame := Engine.get_idle_frames()
		if _forgotten.get(steam_id, -1) == frame:
			return
		_forgotten[steam_id] = frame
		_sent.erase(steam_id)
		_offers.erase(steam_id)

	func reset() -> void:
		_sent.clear()
		_offers.clear()
		_forgotten.clear()
		stats.clear()

	# The provider's screen is gone: cache cleared, and one log line for what the screen sent
	# ("Shop 12: 37 states, ...", the title its provider gave the cache).
	func close(cache) -> void:
		if cache.parts.empty():
			return
		cache.clear()
		var line := summary(cache.label)
		if line != "":
			ModLoaderLog.info("%s: %s" % [cache.title, line], LOG_NAME)

	# The ids the peer was last sent (tests).
	func sent_to(steam_id: int) -> Dictionary:
		return _sent.get(steam_id, {})

	# "37 states, 14 with run parts (212 KB), 23 view only (9 KB), largest 15 KB" for the screen's
	# sends so far ("" when none); its counters start over.
	func summary(label: String) -> String:
		var screen = stats.get(label)
		stats.erase(label)
		if screen == null or screen.states == 0:
			return ""
		var parts := []
		for key in screen.parts:
			parts.append("%s %d" % [key, screen.parts[key]])
		return (
			"%d states, %d with run parts (%s: %s), %d view only (%s), largest %s"
			% [
				screen.states,
				screen.run_states,
				_size(screen.run_bytes),
				", ".join(parts),
				screen.states - screen.run_states,
				_size(screen.view_bytes),
				_size(screen.largest),
			]
		)

	func _count(offer: Array, view_bytes: int) -> void:
		if not stats.has(offer[0]):
			stats[offer[0]] = {
				"states": 0, "run_states": 0, "run_bytes": 0, "view_bytes": 0, "largest": 0,
				"parts": {},
			}
		var screen: Dictionary = stats[offer[0]]
		var bytes: int = offer[3] + view_bytes
		screen.states += 1
		screen.largest = int(max(screen.largest, bytes))
		if offer[2].empty():
			screen.view_bytes += bytes
			return
		screen.run_states += 1
		screen.run_bytes += bytes
		for key in offer[2]:
			screen.parts[key] = screen.parts.get(key, 0) + 1

	static func _size(bytes: int) -> String:
		return "%d B" % bytes if bytes < 1024 else "%.1f KB" % (bytes / 1024.0)


class Store:
	extends Reference
	const MAX_UNCOMPRESSED_SIZE := 8 * 1024 * 1024  # RunStateCodec's
	const KEEP := 2  # versions per key: a body still pending in one section while another moved on
	var misses := 0  # bodies that named a part neither stored nor delivered (tests)
	var parsed := 0  # parts decompressed and parsed (tests)
	var session: Object = null  # ask_resync on a missing part (session/session.gd)
	var _parts := {}  # key -> [{id, size, data, raw (parsed, or null)}], newest first
	var _ids := {}  # the ids of the last state_for
	var _last_ids := {}  # the ids of the last run ingested (a run without ids names them)
	var _players := []  # its PlayerRunData objects
	var _changed := []  # the players it rebuilt
	var _gear := {}  # player -> true when its g part changed (or it is new)

	func setup(netplay_session: Node) -> void:
		session = netplay_session
		session.transport.connect("lobby_left", self, "clear")

	# ingest for a body as it arrives: a missing part is logged and the host asked for a full
	# resync (session/session.gd ask_resync). what: the section, for the log.
	func take(run, what: String) -> bool:
		if ingest(run):
			return true
		ModLoaderLog.warning(
			"The %s state names a run part this client does not have; asking for a resync" % what,
			LOG_NAME
		)
		if session != null:
			session.ask_resync()
		return false

	func clear() -> void:
		_parts.clear()
		_ids = {}
		_last_ids = {}
		_players = []
		_changed = []
		_gear = {}

	# Stores the delivered parts; false when an id is neither stored nor delivered (or the run
	# is malformed). A run without ids ({}: unchanged) gets the last ingested ones, in place.
	func ingest(run) -> bool:
		if typeof(run) != TYPE_DICTIONARY:
			return false
		if not run.has("ids") and not run.has("parts"):
			run["ids"] = _last_ids.duplicate()
			run["parts"] = {}
		var ids = run.get("ids")
		var parts = run.get("parts")
		if typeof(ids) != TYPE_DICTIONARY or typeof(parts) != TYPE_DICTIONARY or ids.empty():
			misses += 1
			return false
		_last_ids = ids.duplicate()
		var complete := true
		for key in ids:
			if typeof(key) != TYPE_STRING or not _is_id(ids[key]):
				return false
			var part = parts.get(key)
			if _is_part(part):
				_store(key, ids[key], part)
			elif _find(key, ids[key]).empty():
				complete = false
		if not complete:
			misses += 1
		return complete

	# The ids of a body's run with its parts stored: after ingest at receive (the stream's
	# accept_state) as they are; a body that did not come through the stream (tests) is ingested
	# here. null when malformed.
	func ids_for(run):
		if typeof(run) != TYPE_DICTIONARY:
			return null
		if not has_all(run.get("ids")):
			ingest(run)
		return run.get("ids")

	func has_all(ids) -> bool:
		if typeof(ids) != TYPE_DICTIONARY:
			return false
		for key in ids:
			if _find(key, ids[key]).empty():
				return false
		return true

	# key -> the parsed part (null when missing or unreadable). Parts stay as parsed here: never
	# hand them to the game's code, which writes into what it reads.
	func raws(ids: Dictionary) -> Dictionary:
		var result := {}
		for key in ids:
			result[key] = _raw(key, ids[key])
		return result

	# The run state of ids, deserialized ({} when a part is missing or unreadable).
	func state_for(ids) -> Dictionary:
		if typeof(ids) != TYPE_DICTIONARY:
			return {}
		var common = _raw("c", ids.get("c"))
		if typeof(common) != TYPE_DICTIONARY:
			return {}
		var count = common.get("players_data")
		if typeof(count) != TYPE_INT and typeof(count) != TYPE_REAL:
			return {}
		var changed := []
		var gear := {}
		var input: Dictionary = common.duplicate(true)  # the game writes into its input
		input["players_data"] = []
		for p in int(count):
			var p_key: String = "p%d" % p
			var g_key: String = "g%d" % p
			var same_gear: bool = same_id(ids.get(g_key), _ids.get(g_key)) and p < _players.size()
			if same_gear and same_id(ids.get(p_key), _ids.get(p_key)):
				continue
			var rest = _raw(p_key, ids.get(p_key))
			var player_gear = _raw(g_key, ids.get(g_key))
			if rest == null or player_gear == null:
				return {}
			changed.append(p)
			gear[p] = not same_gear
			input.players_data.append(merge(rest, player_gear).duplicate(true))
		var state: Dictionary = ProgressDataLoaderV3.new().deserialize_run_state(input)
		EffectArgs.settle(state, false)  # its effects came with their custom args
		var fresh = state.get("players_data")
		if typeof(fresh) != TYPE_ARRAY or fresh.size() != changed.size():
			return {}  # no run state (a player that is not one)
		var players := []
		for p in int(count):
			var index := changed.find(p)
			players.append(fresh[index] if index >= 0 else _players[p])
		state["players_data"] = players
		_ids = ids.duplicate()
		_players = players
		_changed = changed
		_gear = gear
		return state

	func changed_players() -> Array:
		return _changed.duplicate()

	func gear_changed(p: int) -> bool:
		return _gear.get(p, false)

	# A player's dictionary from its "p" and "g" parts (shared, not copied).
	static func merge(rest, gear):
		if typeof(rest) != TYPE_DICTIONARY:
			return rest
		var player: Dictionary = rest.duplicate()
		if typeof(gear) == TYPE_DICTIONARY:
			for field in gear:
				player[field] = gear[field]
		return player

	static func same_id(a, b) -> bool:
		return typeof(a) == TYPE_ARRAY and typeof(b) == TYPE_ARRAY and a == b

	func _raw(key, id):
		var found := _find(key, id)
		if found.empty():
			return null
		if found.raw == null:
			var text: PoolByteArray = found.data.decompress(found.size, File.COMPRESSION_ZSTD)
			var result := JSON.parse(text.get_string_from_utf8())
			if result.error != OK:
				return null
			found.raw = result.result
			parsed += 1
		return found.raw

	func _find(key, id) -> Dictionary:
		if not _is_id(id):
			return {}
		for version in _parts.get(key, []):
			if version.id == id:
				return version
		return {}

	# Newest first; one already stored moves to the front with what it parsed.
	func _store(key: String, id: Array, part: Dictionary) -> void:
		var versions: Array = _parts.get(key, [])
		var stored := _find(key, id)
		if stored.empty():
			stored = {"id": id.duplicate(), "size": part.size, "data": part.data, "raw": null}
		else:
			versions.erase(stored)
		versions.push_front(stored)
		if versions.size() > KEEP:
			versions.resize(KEEP)
		_parts[key] = versions

	static func _is_id(id) -> bool:
		return (
			typeof(id) == TYPE_ARRAY
			and id.size() == 2
			and typeof(id[0]) == TYPE_INT
			and typeof(id[1]) == TYPE_INT
		)

	static func _is_part(part) -> bool:
		return (
			typeof(part) == TYPE_DICTIONARY
			and typeof(part.get("size")) == TYPE_INT
			and typeof(part.get("data")) == TYPE_RAW_ARRAY
			and part.size > 0
			and part.size <= MAX_UNCOMPRESSED_SIZE
		)
