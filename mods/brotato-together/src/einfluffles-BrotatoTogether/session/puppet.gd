extends Reference
# Global "this client is mirroring the host's run" flag, readable from script extensions. While
# set, the client's own save file, challenges and achievements must not be touched.

const META_KEY := "brotato_together_puppet"
const STASH_KEY := "brotato_together_puppet_stash"
# Set while the client uses the host's DLC (= session/dlc_borrow.gd META_KEY; not preloaded:
# the ProgressData / ChallengeService extensions preload this file at mod init).
const DLC_BORROW_META_KEY := "brotato_together_dlc_borrow"
# Set around a write of this client's own progress that it earned in the host's run
# (session/progress_share.gd): the one thing that may reach its save while it mirrors.
const OWN_META := "brotato_together_own_progress"
# ProgressData fields a mirrored run overwrites and the next save() would write (saved_run_state:
# the title screen would offer "Continue" for the host's run). Stashed while the flag is set.
const STASHED_FIELDS := [
	"saved_run_state",
	"last_saved_run_state",
	"data",
	"killed_enemies",
	"killed_by_enemies",
	"items_bought",
]


static func is_active() -> bool:
	return Engine.has_meta(META_KEY) and Engine.get_meta(META_KEY)


static func blocks_progress() -> bool:
	return is_active() or Engine.has_meta(DLC_BORROW_META_KEY)


static func own_progress() -> bool:
	return Engine.has_meta(OWN_META)


static func set_own_progress(on: bool) -> void:
	if on:
		Engine.set_meta(OWN_META, true)
	elif Engine.has_meta(OWN_META):
		Engine.remove_meta(OWN_META)


# ProgressData.data (the lifetime counters) as this client's save has it.
static func own_data() -> Dictionary:
	var stash = Engine.get_meta(STASH_KEY) if Engine.has_meta(STASH_KEY) else null
	if stash is Dictionary and stash.get("data") is Dictionary:
		return stash.data
	var progress_data = _progress_data()
	return progress_data.data if progress_data != null else {}


# A list this client's save keeps (characters_unlocked, ...), without what it borrowed.
static func own_list(field: String) -> Array:
	var borrow = Engine.get_meta(DLC_BORROW_META_KEY) if Engine.has_meta(DLC_BORROW_META_KEY) else null
	if borrow is Dictionary and borrow.get("progress") is Dictionary and borrow.progress.has(field):
		return borrow.progress[field]
	var progress_data = _progress_data()
	var list = progress_data.get(field) if progress_data != null else null
	return list if list is Array else []


# Everything put aside for this client: ProgressData field -> its own value (both stashes).
static func own_fields() -> Dictionary:
	var fields := {}
	var stash = Engine.get_meta(STASH_KEY) if Engine.has_meta(STASH_KEY) else null
	if stash is Dictionary:
		for field in stash:
			fields[field] = stash[field]
	var borrow = Engine.get_meta(DLC_BORROW_META_KEY) if Engine.has_meta(DLC_BORROW_META_KEY) else null
	if borrow is Dictionary and borrow.get("progress") is Dictionary:
		for field in borrow.progress:
			fields[field] = borrow.progress[field]
	return fields


static func set_active(active: bool) -> void:
	var was_active := is_active()
	if active and not was_active:
		_stash()
	elif was_active and not active:
		_restore()  # before the flag drops: no save() can see the host's run
	Engine.set_meta(META_KEY, active)


static func _stash() -> void:
	var progress_data = _progress_data()
	if progress_data == null:
		return
	var stash := {}
	for field in STASHED_FIELDS:
		var value = progress_data.get(field)
		stash[field] = value.duplicate(true) if value is Dictionary else value
	Engine.set_meta(STASH_KEY, stash)


static func _restore() -> void:
	var progress_data = _progress_data()
	if progress_data == null or not Engine.has_meta(STASH_KEY):
		return
	var stash = Engine.get_meta(STASH_KEY)
	if stash is Dictionary:
		for field in stash:
			progress_data.set(field, stash[field])
	Engine.remove_meta(STASH_KEY)


static func _progress_data() -> Object:
	var loop = Engine.get_main_loop()
	if loop is SceneTree:
		return loop.root.get_node_or_null("ProgressData")
	return null
