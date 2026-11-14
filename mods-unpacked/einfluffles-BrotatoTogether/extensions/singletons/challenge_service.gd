extends "res://singletons/challenge_service.gd"
# No challenge/achievement unlocks from a mirrored (puppet) run — the host's game decides those.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")


func complete_challenge(chal_id: int, also_complete_platform_challenge: bool = true) -> void:
	if Puppet.is_active():
		return
	.complete_challenge(chal_id, also_complete_platform_challenge)
