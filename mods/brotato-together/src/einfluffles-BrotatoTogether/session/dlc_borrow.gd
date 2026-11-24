extends Reference
# The host's DLC, lent to a client for one session (like Steam Remote Play Together), never an
# unlock. DLC content ships with the base game; ownership only decides what is registered
# (ProgressData.available_dlc_ids, DLCData.add_resources), and that is what borrow() changes.

const META_KEY := "brotato_together_dlc_borrow"  # = Puppet.DLC_BORROW_META_KEY
const NAMES := {"abyssal_terrors": "Abyssal Terrors", "primal_dread": "Primal Dread"}
# ProgressData fields: registration inputs + lists that save() writes (add_unlocked_by_default
# walks the registered characters/items/weapons).
const PROGRESS_FIELDS := [
	"available_dlc_ids",
	"active_update_data",
	"zones_unlocked",
	"characters_unlocked",
	"upgrades_unlocked",
	"consumables_unlocked",
	"weapons_unlocked",
	"items_unlocked",
	"difficulties_unlocked",
]
# ItemService caches built from the registered lists (pools, lazy id lookups).
const ITEM_SERVICE_FIELDS := [
	"_tiers_data", "_item_id_lookup", "_weapon_id_lookup", "_base_weapon_lookup"
]


static func is_active() -> bool:
	return Engine.has_meta(META_KEY)


static func borrowed_ids() -> Array:
	if not is_active():
		return []
	return Engine.get_meta(META_KEY).ids.duplicate()


static func owned_ids() -> Array:
	var owned := []
	var borrowed := borrowed_ids()
	for dlc_id in ProgressData.available_dlc_ids:
		if not dlc_id in borrowed:
			owned.append(dlc_id)
	return owned


# host_dlcs is network data: only known ids are taken.
static func missing(host_dlcs) -> Array:
	var result := []
	if typeof(host_dlcs) != TYPE_ARRAY:
		return result
	for dlc_id in host_dlcs:
		if (
			typeof(dlc_id) == TYPE_STRING
			and dlc_id in ProgressData.dlc_ids
			and not dlc_id in ProgressData.available_dlc_ids
			and not dlc_id in result
			and ItemService.get_dlc_data_by_id(dlc_id) != null
		):
			result.append(dlc_id)
	return result


static func borrow(host_dlcs) -> Array:
	revert()
	var ids := missing(host_dlcs)
	if ids.empty():
		return ids
	var stash := {"ids": [], "progress": {}, "items": {}}
	for field in PROGRESS_FIELDS:
		stash.progress[field] = ProgressData.get(field).duplicate()
	for field in ITEM_SERVICE_FIELDS:
		stash.items[field] = ItemService.get(field).duplicate(true)
	# The game's registration order (ItemService.init_dlc_content): update_data_list order.
	for update in ItemService.update_data_list:
		if update != null and update.dlc_data != null and update.id in ids:
			stash.ids.append(update.id)
			ProgressData.available_dlc_ids.append(update.id)
			update.dlc_data.add_resources()
	Engine.set_meta(META_KEY, stash)
	_invalidate_item_lists()
	ProgressData.refresh_active_update_data()  # until the host's run state brings its own
	return stash.ids.duplicate()


static func revert() -> void:
	if not is_active():
		return
	var stash: Dictionary = Engine.get_meta(META_KEY)
	Engine.remove_meta(META_KEY)
	var ids: Array = stash.ids
	for i in range(ids.size() - 1, -1, -1):
		var dlc_data = ItemService.get_dlc_data_by_id(ids[i])
		dlc_data.remove_resources()
		_drop_music(dlc_data)
	for field in stash.progress:
		_assign(ProgressData, field, stash.progress[field])
	for field in stash.items:
		ItemService.set(field, stash.items[field])
	_invalidate_item_lists()


# Line for the lobby page's details ("" when nothing is borrowed).
static func note() -> String:
	var names := []
	for dlc_id in borrowed_ids():
		names.append(NAMES.get(dlc_id, dlc_id))
	if names.empty():
		return ""
	return Text.text("BT_DLC_BORROWED", [PoolStringArray(names).join(", ")])


static func _invalidate_item_lists() -> void:
	ItemService.invalidate_items_cache()
	ItemService.invalidate_characters_cache()
	ItemService.invalidate_weapons_cache()


# Arrays are refilled in place: other code may hold the same array.
static func _assign(target: Object, field: String, value: Array) -> void:
	var current = target.get(field)
	if current is Array:
		current.clear()
		current.append_array(value)
	else:
		target.set(field, value.duplicate())


# MusicManager queues DLC tracks for available_dlc_ids when its queue runs dry.
static func _drop_music(dlc_data) -> void:
	var music = Engine.get_main_loop().root.get_node_or_null("MusicManager")
	if music == null or not "shuffled_tracks" in music:
		return
	for track in dlc_data.music_tracks:
		while track in music.shuffled_tracks:
			music.shuffled_tracks.erase(track)
