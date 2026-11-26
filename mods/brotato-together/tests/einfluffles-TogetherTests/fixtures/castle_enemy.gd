extends "res://entities/units/enemies/enemy.gd"
# An enemy script of a mod, as TreasureCastle's castle_enemy.gd: the game's with data of its own.

export(Dictionary) var definition = {}
export(Resource) var donor_stats
export(Vector2) var body_size = Vector2(48, 48)
