extends "res://singletons/challenge_service.gd"
# A mirrored run belongs to the host: nothing this client's copy of the game does there completes
# a challenge (same while it uses the host's DLC). What the host's game finds reached is sent to
# the clients and completed there for their own save, under Puppet.own_progress.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const BT_SHARE := "/root/ModLoader/einfluffles-BrotatoTogether/ProgressShare"
# Where a challenge's reward is kept unlocked: [ProgressData list, the reward's id property].
const BT_REWARD_LISTS := {
	RewardType.CHARACTER: ["characters_unlocked", "my_id"],
	RewardType.ITEM: ["items_unlocked", "my_id"],
	RewardType.WEAPON: ["weapons_unlocked", "weapon_id"],
	RewardType.STARTING_WEAPON: ["weapons_unlocked", "weapon_id"],
	RewardType.ZONE: ["zones_unlocked", "my_id"],
	RewardType.CONSUMABLE: ["consumables_unlocked", "my_id"],
	RewardType.UPGRADE: ["upgrades_unlocked", "upgrade_id"],
}

var _bt_share: Node = null  # the ProgressShare node, once the mod is up


# The host's game asks this whenever a value could have reached a challenge, also for challenges
# the host has long completed: its clients may not have.
func try_complete_challenge(chal_id: int, value: int, check_below: bool = false):
	var share := _bt_get_share()
	if share != null:
		share.host_met(chal_id, value, check_below)
	.try_complete_challenge(chal_id, value, check_below)


func complete_challenge(chal_id: int, also_complete_platform_challenge: bool = true) -> void:
	var share := _bt_get_share()
	if share != null:
		share.host_completed(chal_id)
	if Puppet.blocks_progress() and not Puppet.own_progress():
		return
	.complete_challenge(chal_id, also_complete_platform_challenge)
	if Puppet.own_progress():
		_bt_unlock_own(chal_id)


# Onto this client's own list whether the content is registered here or not: a reward behind a
# DLC it only has from the host stays unlocked in its save (the game offers it once owned).
func _bt_unlock_own(chal_id: int) -> void:
	var chal = get_chal(chal_id)
	if chal == null or not chal.reward or not BT_REWARD_LISTS.has(chal.reward_type):
		return
	var entry: Array = BT_REWARD_LISTS[chal.reward_type]
	var reward_id = chal.reward.get(entry[1])
	if typeof(reward_id) != TYPE_STRING or reward_id == "":
		return
	var reward_hash: int = Keys.generate_hash(reward_id)
	var own: Array = Puppet.own_list(entry[0])
	if not own.has(reward_hash):
		own.push_back(reward_hash)


func _bt_get_share() -> Node:
	if _bt_share == null:
		_bt_share = get_node_or_null(BT_SHARE)
	return _bt_share
