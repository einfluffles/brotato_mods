extends Reference
# The client's own player under the camera (sync/own_view.gd), part of suite battle_scene: drawn
# between its last two physics ticks it moves at an even pace on screens faster than 60 Hz, and
# the co-op camera follows where the players are drawn in the same frame, not in the physics step.

const OwnView := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/own_view.gd")
const SCREEN_HZ := [60, 75, 120, 144, 165, 240]
const STEP := Vector2(7.5, 0)  # px a physics tick: 450 px/s
const FRAMES := 30  # client frames with a new input each
const EPSILON := 0.01  # px


# The host's camera is the game's own: the co-op camera moves in the physics step.
static func check_host_camera(t: Node, main: Node) -> void:
	var camera: Node = main.get("_camera")
	t._check(
		camera.is_physics_processing() and not camera._is_snapped,
		"host: the co-op camera moves in the game's physics step"
	)


func test_client(t: Node, client: Node, you: int):
	_test_even_pace(t)
	yield(_test_camera(t, client, you), "completed")


# A second of walking at one input per physics tick, seen on screens of different rates: the
# prediction's display moves on the frames with a tick only, the drawn player every frame alike.
func _test_even_pace(t: Node) -> void:
	var worst := 0.0  # px between the drawn player and an even walk a tick behind
	var uneven := 0  # screen rates on which the display itself moved unevenly
	for hz in SCREEN_HZ:
		var view = OwnView.new()
		var display := Vector2.ZERO
		var seq := 0
		var raw := {}  # px the display moved in a frame -> true
		for frame in range(1, hz + 1):
			var ticks: float = float(frame) * 60.0 / hz
			var seqs: int = int(floor(ticks + 1e-6))
			var shown := display
			display = STEP * seqs
			view.note_display(shown, display, seqs - seq, true)
			seq = seqs
			raw[stepify(display.x - shown.x, 0.01)] = true
			if seqs >= 1:
				var drawn: Vector2 = OwnView.smoothed(display, view.jump, ticks - seqs)
				worst = max(worst, drawn.distance_to(STEP * (ticks - 1.0)))
		uneven += 1 if raw.size() > 1 else 0
	t._check(
		worst < EPSILON and uneven == SCREEN_HZ.size() - 1,
		(
			"own player drawn at an even pace on screens of %s Hz (off by %.3f px; the prediction "
			+ "alone moves unevenly on %d of them)"
		) % [SCREEN_HZ.slice(1, SCREEN_HZ.size() - 1), worst, uneven]
	)


# The own player walks a step every frame (more often than the physics ticks): after each frame
# the camera stands where MyCamera puts it for the players as drawn in that frame.
func _test_camera(t: Node, client: Node, you: int):
	var main: Node = client._main
	var camera: Node = main.get("_camera")
	t._check(
		not camera.is_physics_processing() and not camera.is_processing(),
		"client: the camera does not move on its own (physics step or frame)"
	)
	var saved := [
		camera.move_speed_factor, camera.zoom_in_speed_factor, camera.zoom_out_speed_factor,
		client._you, client.input_sync.history
	]
	camera.move_speed_factor = 1.0  # at its target in every update
	camera.zoom_in_speed_factor = 0.0
	camera.zoom_out_speed_factor = 0.0
	client._you = you
	var players: Array = main.get("_players")
	var away: Vector2 = players[you].global_position - players[1 - you].global_position
	var history := []
	client.input_sync.history = history
	var start: Vector2 = camera.global_position
	var worst := 0.0
	var behind := 0.0  # px the drawn own player is behind its prediction, past one input
	var no_tick := 0  # frames without a physics tick
	var ticks: int = Engine.get_physics_frames()
	for seq in range(1, FRAMES + 1):
		history.append([seq, away.normalized()])
		client._newest_rx_msec = OS.get_ticks_msec()
		yield(t.get_tree(), "idle_frame")  # the frame before ran client._process
		if seq == 1:
			continue
		var targets: Array = camera._get_alive_targets()
		var average: Vector2 = camera._get_average_target_position(targets)
		var expected: Vector2 = camera._calculate_final_position(
			average + camera._calculate_offset(average),
			camera._calculate_edge_visibility(),
			false,
			1.0
		)
		worst = max(worst, camera.global_position.distance_to(expected))
		var lag: float = players[you].global_position.distance_to(client._own_display)
		behind = max(behind, lag - client._view.jump.length())
		no_tick += 1 if Engine.get_physics_frames() == ticks else 0
		ticks = Engine.get_physics_frames()
	var moved: float = camera.global_position.distance_to(start)
	t._check(
		worst < EPSILON and moved > 10.0,
		(
			"client camera follows the players as drawn in each frame (off by %.3f px, moved %.0f "
			+ "px, %d of %d frames without a physics tick)"
		) % [worst, moved, no_tick, FRAMES - 1]
	)
	t._check(behind < EPSILON, "own player drawn at most one input behind its prediction")
	camera.move_speed_factor = saved[0]
	camera.zoom_in_speed_factor = saved[1]
	camera.zoom_out_speed_factor = saved[2]
	client._you = saved[3]
	client.input_sync.history = saved[4]
