extends "res://singletons/progress_data.gd"
# A mirrored (puppet) run belongs to the host: never write it into the client's save file. Same
# while the client uses the host's DLC (session/dlc_borrow.gd).

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const BT_SHARE := "/root/ModLoader/einfluffles-BrotatoTogether/ProgressShare"

var _bt_share: Node = null  # session/progress_share.gd, once the mod is up


# A host's lifetime counters count for its clients too (session/progress_share.gd).
func increment_stat(key: String) -> void:
	.increment_stat(key)
	if _bt_share == null:
		_bt_share = get_node_or_null(BT_SHARE)
	if _bt_share != null:
		_bt_share.host_stat(key)


# Writes this machine's own progress to its save while it mirrors the host or uses its DLC:
# what was put aside goes in for the save and the live values come back after it, so the file
# holds this player's own run, counters and lists, plus what it just earned.
func bt_save_own() -> void:
	var live := _bt_own_in()
	.save()
	_bt_own_out(live)


# What that save holds (the game's own save object, of this machine's own values).
func bt_own_save_object() -> Dictionary:
	var live := _bt_own_in()
	var object: Dictionary = get_current_save_object()
	_bt_own_out(live)
	return object


func _bt_own_in() -> Dictionary:
	var own: Dictionary = Puppet.own_fields()
	var live := {}
	for field in own:
		live[field] = get(field)
		set(field, own[field])
	return live


func _bt_own_out(live: Dictionary) -> void:
	for field in live:
		set(field, live[field])


func save() -> void:
	if Puppet.blocks_progress():
		return
	.save()


func save_run_state(
	shop_items := [],
	reroll_count := [],
	paid_reroll_count := [],
	initial_free_rerolls := [],
	free_rerolls := [],
	item_steals := []
) -> void:
	if Puppet.blocks_progress():
		return
	.save_run_state(
		shop_items, reroll_count, paid_reroll_count, initial_free_rerolls, free_rerolls, item_steals
	)


func reset_and_save_new_run_state() -> void:
	if Puppet.blocks_progress():
		return
	.reset_and_save_new_run_state()


func reset_and_save_run_state(run_state: Dictionary) -> void:
	if Puppet.blocks_progress():
		return
	.reset_and_save_run_state(run_state)
