extends Reference
# Global "this client is mirroring the host's run" flag, readable from script extensions.
# While set, the client's own save file, challenges and achievements must not be touched.
#
# Saves are blocked while puppeting (extensions/singletons/progress_data.gd), but the puppet run
# still overwrites ProgressData fields that the *next* save() writes: the shop resume path sets
# saved_run_state to the host's run (the title screen would offer "Continue" for it). Turning
# puppet mode on stashes everything ProgressData.save() persists from the run side; turning it
# off restores it, so the client's own run and stats come back exactly as they were.

const META_KEY := "brotato_together_puppet"
const STASH_KEY := "brotato_together_puppet_stash"
# ProgressData fields written by runs (save() serializes all of them).
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
