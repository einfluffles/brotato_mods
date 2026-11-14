extends "res://singletons/progress_data.gd"
# A mirrored (puppet) run belongs to the host: never write it into the client's save file. Same
# while the client uses the host's DLC (session/dlc_borrow.gd).

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")


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
