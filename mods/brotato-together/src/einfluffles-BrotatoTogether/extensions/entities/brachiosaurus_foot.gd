# gdlint: disable=max-line-length
extends "res://entities/units/enemies/jungle/bosses/brachiosaurus/brachiosaurus_foot/brachiosaurus_foot.gd"
# gdlint: enable=max-line-length

# Client puppets: the foot's _ready (it runs inside add_child, before the puppet is frozen) starts a
# stomp with shoot(). Stomps are the host's: the snapshots carry the foot's animation and sprites.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")


func shoot() -> void:
	if Puppet.is_active():
		return
	.shoot()
