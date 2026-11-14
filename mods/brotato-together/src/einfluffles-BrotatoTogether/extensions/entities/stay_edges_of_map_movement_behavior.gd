extends "res://entities/units/movement_behaviors/stay_edges_of_map_movement_behavior.gd"
# Client puppets: BrachiosaurusFoot._ready calls its boss's move_away(), which needs init() (never
# run on puppets: _parent is null) and would tween the puppet. The host's boss moves; snapshots
# carry its position.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")


func move_away():
	if Puppet.is_active():
		return
	.move_away()
