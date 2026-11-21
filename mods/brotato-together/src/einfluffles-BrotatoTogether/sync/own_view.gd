extends Reference
# The client's own player among the others and under the camera: the other players block its
# prediction as they block it on the host, it is drawn moving every frame like the puppets around
# it, and the camera follows in the same frame. One instance per battle.

const BattleScene := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/battle_scene.gd")
const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const PF := Snapshot.PlayerField
# Physics layer of the blockers: none of the game's scenes uses it, so only the own player's
# prediction (BattleScene.step) runs into them.
const BLOCKER_LAYER := 1 << 20

var jump := Vector2.ZERO  # how far the newest input moved the own player's display
var _blockers := []  # player index -> StaticBody2D (null: the player has no body shape)
var _camera: Node = null


# main: the frozen puppet battle (BattleClient._freeze).
func setup(main: Node) -> void:
	for player in main.get("_players"):
		player.collision_mask = BattleScene.OBSTACLES | BLOCKER_LAYER
		_blockers.append(_blocker(main, player))
	# MyCamera moves a co-op camera in its physics step, the puppets move every frame.
	_camera = main.get("_camera")
	if _camera != null:
		_camera.set_process(false)
		_camera.set_physics_process(false)


# Each other living player's body at its newest host position: where the host has it while it
# applies this client's inputs, not the puppet's, which is drawn a render delay behind.
func place(players: Array, newest: Dictionary, you: int) -> void:
	for i in _blockers.size():
		var blocker = _blockers[i]
		if blocker == null or not is_instance_valid(blocker):
			continue
		var entry: Array = newest.players[i] if i < newest.players.size() else []
		var on: bool = i != you and not entry.empty() and not Snapshot.is_dead(entry)
		on = on and i < players.size() and not players[i].dead
		blocker.collision_layer = BLOCKER_LAYER if on else 0
		if on:
			var xform: Transform2D = players[i].global_transform
			xform.origin = entry[PF.POSITION]
			blocker.global_transform = xform


static func _blocker(main: Node, player: Node) -> Node:
	var shape = player.get("_collision")
	if not shape is CollisionShape2D or shape.shape == null:
		return null
	var body := StaticBody2D.new()
	body.collision_layer = 0
	body.collision_mask = 0
	var copy := CollisionShape2D.new()
	copy.shape = shape.shape
	copy.transform = shape.transform
	body.add_child(copy)
	main.add_child(body)
	return body


# The prediction moves the own player one input (physics tick) at a time; a frame that took
# exactly one new input spreads its step over the frames until the next tick.
func note_display(before: Vector2, after: Vector2, new_inputs: int, predicting: bool) -> void:
	if not predicting:
		jump = Vector2.ZERO
	elif new_inputs != 0:  # a new input, or a history that started over
		jump = after - before if new_inputs == 1 else Vector2.ZERO


# Drawn between the last two ticks' positions, a tick behind, as the puppets are drawn between
# snapshots. fraction: Engine.get_physics_interpolation_fraction().
static func smoothed(display: Vector2, step: Vector2, fraction: float) -> Vector2:
	return display - step * (1.0 - clamp(fraction, 0.0, 1.0))


# After this frame's players are placed: the own player (you, -1 for none) where it is drawn, then
# MyCamera's own update, in this frame's step.
func draw(players: Array, you: int, display: Vector2, delta: float) -> void:
	if you >= 0 and you < players.size() and not players[you].dead:
		var fraction := Engine.get_physics_interpolation_fraction()
		players[you].global_position = smoothed(display, jump, fraction)
	if _camera != null and is_instance_valid(_camera):
		_camera._process_internal(delta)
