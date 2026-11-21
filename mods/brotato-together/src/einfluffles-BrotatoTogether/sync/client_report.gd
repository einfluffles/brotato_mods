extends Node
# Clients report how their game runs into the host's log (CLIENT_REPORT): after a session only
# the host's modloader.log is at hand. A ready client sends frame-time windows (with what the
# worst frame was spent on), the stall after a scene change with the mod's share of it, and
# corrections of the own player's prediction.

# Timing marks, in the order of a report's "marks" (MARK_NAMES).
enum Mark { PARSE, DESERIALIZE, APPLY, PUPPET_SETUP }
# Parts of BattleClient._process, in the order of a report's "worst_phases" (PHASE_NAMES).
enum Phase { PLAYERS, ENTITIES, PICKUPS, EVENTS }

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:ClientReport"
const META_NODE := "brotato_together_client_report"
# First in every frame: the time between two _process calls then holds a whole frame, the
# deferred scene change included.
const PROCESS_PRIORITY := -1000
const WINDOW_MSEC := 10000
const BASELINE_MSEC := 60000
const SLOW_FRAME_MSEC := 50.0
const STALL_WATCH_MSEC := 3000
const MINUTE_MSEC := 60000
# The Mod Loader keeps every log line in memory, so both ends budget them.
const WINDOW_LINES_PER_MINUTE := 6
const SCENE_LINES_PER_MINUTE := 2
const MAX_LINES_PER_MINUTE := 8
const KIND_FRAMES := 1
const KIND_SCENE := 2
const MARK_NAMES := ["run parse", "deserialize", "apply", "puppet setup"]
const PHASE_NAMES := ["players", "entities", "pickups", "events"]
const MAX_FILE_LENGTH := 40
const FILE_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"
# Scenes by file name; index 0: any other.
const SCENE_FILES := [
	"",
	"main.tscn",
	"shop.tscn",
	"coop_shop.tscn",
	"title_screen.tscn",
	"character_selection.tscn",
	"weapon_selection.tscn",
	"difficulty_selection.tscn",
	"end_run.tscn",
	"coop_end_run.tscn",
	"coop_resume.tscn",
	"client_view",  # ui/client_view.gd (no file: mod_main.gd builds it)
]
const SCENE_NAMES := {0: "another scene", 11: "the waiting screen"}
const MAX_MSEC := 600000.0
const MAX_COUNT := 1000000.0
const MAX_PX := 100000.0

var session: Node = null
var active := false  # a ready client: nothing is measured otherwise
var test_client := false  # measure and keep what would be sent, without a session
var sent := []  # the bodies kept while test_client
var window_msec := WINDOW_MSEC
var baseline_msec := BASELINE_MSEC
# Host: what was logged.
var lines_logged := 0
var lines_dropped := 0
var last_lines := []

var _last_usec := 0  # when _process ran last
var _marks := []  # usec per Mark in the frame running now
var _phases := []  # usec per Phase in the frame running now
var _fresh := 0  # puppets instanced (not taken from a pool) in the frame running now
var _previous := [0, []]  # the frame before: usec, marks
var _scene_id := 0  # instance id of the scene the window is in, 0: none yet
var _window := {}
var _stall := {}  # the scene change being watched: scene, until, frame (usec), marks
var _last_window_sent_msec := 0
var _window_lines := []  # msec of the window lines sent within the last minute
var _scene_lines := []
var _host_lines := {}  # steam id -> msec of its lines logged within the last minute
var _host_dropped := {}  # steam id -> lines dropped since its last logged one


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.connect("message", self, "_on_message")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS  # keeps track of scene changes; paused frames are not counted
	process_priority = PROCESS_PRIORITY
	_reset()


func _enter_tree() -> void:
	# The static reporters find this node through the meta: RunStateCodec has no node.
	Engine.set_meta(META_NODE, self)


func _exit_tree() -> void:
	if Engine.has_meta(META_NODE) and Engine.get_meta(META_NODE) == self:
		Engine.remove_meta(META_NODE)


static func mark(label: int, usec: int) -> void:
	var report = _active_report()
	if report != null and label >= 0 and label < report._marks.size():
		report._marks[label] += usec


# phases: usec per Phase of this call's usec.
static func mirror_cost(usec: int, entities: int, phases := []) -> void:
	var report = _active_report()
	if report == null or report._window.empty():
		return
	var window: Dictionary = report._window
	window.mirror_frames += 1
	window.mirror_usec += usec
	window.mirror_worst_usec = max(window.mirror_worst_usec, usec)
	window.entities = max(window.entities, entities)
	for i in min(phases.size(), report._phases.size()):
		report._phases[i] += phases[i]


# A puppet instanced instead of taken from a pool: file is its scene's, usec what instancing and
# setting it up took.
static func fresh(file: String, usec: int) -> void:
	var report = _active_report()
	if report == null or report._window.empty():
		return
	var window: Dictionary = report._window
	report._fresh += 1
	window.fresh += 1
	window.fresh_usec += usec
	if usec > window.fresh_worst_usec:
		window.fresh_worst_usec = usec
		window.fresh_worst_file = file.left(MAX_FILE_LENGTH)


# px: from where the own player was shown to where the host's position puts it now. late_msec:
# how much later the snapshot came than the fastest so far (its age: plus half the round trip).
static func note_correction(px: float, late_msec: float, unacked: int, speed: float) -> void:
	var report = _active_report()
	if report == null or report._window.empty():
		return
	if px <= speed / float(Engine.iterations_per_second):
		return
	var window: Dictionary = report._window
	window.corrections += 1
	if px > window.largest:
		window.largest = px
		window.age = late_msec + report.half_rtt_msec()
		window.unacked = unacked
		window.speed = speed


# history: [seq, move] each.
static func unacked(history: Array, ack: int) -> int:
	var count := 0
	for k in range(history.size() - 1, -1, -1):
		if history[k][0] <= ack:
			break
		count += 1
	return count


static func _active_report():
	if not Engine.has_meta(META_NODE):
		return null
	var report = Engine.get_meta(META_NODE)
	if not is_instance_valid(report) or not report.active:
		return null
	return report


func _process(_delta: float) -> void:
	var now_usec := OS.get_ticks_usec()
	var previous := _last_usec
	_last_usec = now_usec
	var was_active := active
	active = test_client or (session != null and session.is_ready_client())
	if not active:
		if was_active:
			_reset()
		return
	if not was_active or previous == 0:
		return  # no whole frame measured yet
	var tree := get_tree()
	step(now_usec - previous, tree.current_scene, tree.paused, OS.get_ticks_msec())


func step(frame_usec: int, scene: Node, paused: bool, now_msec: int) -> void:
	var frame_marks := _marks
	_marks = _no_marks()
	var frame_phases := _phases
	_phases = _no_phases()
	var frame_fresh := _fresh
	_fresh = 0
	var previous := _previous
	_previous = [frame_usec, frame_marks]
	var scene_id := scene.get_instance_id() if scene != null else 0
	var changed := scene_id != _scene_id
	if changed:
		var first := _scene_id == 0
		_flush_window(now_msec)
		_scene_id = scene_id
		_window = _new_window(scene_index(scene))
		if first:
			_last_window_sent_msec = now_msec
		else:
			_stall = {"scene": _window.scene, "until": now_msec + STALL_WATCH_MSEC}
			# The frame before counts too: the scene may have loaded before this _process ran.
			_stall.frame = previous[0]
			_stall.marks = previous[1]
	if not _stall.empty():
		if frame_usec > _stall.frame:
			_stall.frame = frame_usec
			_stall.marks = frame_marks
		if now_msec >= _stall.until:
			_send_stall(now_msec)
	if changed or paused:
		return  # the scene change's own frame is the stall's
	var msec := frame_usec / 1000.0
	_window.msec += msec
	_window.frames += 1
	if msec > _window.worst:
		_window.worst = msec
		_window.worst_marks = frame_marks
		_window.worst_phases = frame_phases
		_window.worst_fresh = frame_fresh
	if msec >= SLOW_FRAME_MSEC:
		_window.over += 1
	if _window.msec >= window_msec:
		_window_due(now_msec)


static func scene_index(scene: Node) -> int:
	if scene == null:
		return 0
	var file := scene.filename.get_file()
	if file == "" and scene.name == "BrotatoTogetherClientView":
		file = "client_view"
	var index := SCENE_FILES.find(file)
	return index if index > 0 else 0


func half_rtt_msec() -> float:
	if session == null or session.transport == null:
		return 0.0
	var peer = session.peers.get(session.transport.host_id)
	return max(0.0, peer.get("rtt_ms", -1) / 2.0) if peer != null else 0.0


func _window_due(now_msec: int) -> void:
	var notable: bool = _window.worst >= SLOW_FRAME_MSEC or _window.corrections > 0
	if not notable and now_msec - _last_window_sent_msec < baseline_msec:
		_window = _new_window(_window.scene)
		return
	if _take_lines(_window_lines, WINDOW_LINES_PER_MINUTE, _window_line_count(), now_msec):
		_send(_window_body())
		_last_window_sent_msec = now_msec
		_window = _new_window(_window.scene)
	# else: no room this minute; the window goes on and is sent once there is


func _flush_window(now_msec: int) -> void:
	if _window.empty() or _window.frames == 0:
		return
	if _window.worst < SLOW_FRAME_MSEC and _window.corrections == 0:
		return
	if _take_lines(_window_lines, WINDOW_LINES_PER_MINUTE, _window_line_count(), now_msec):
		_send(_window_body())
		_last_window_sent_msec = now_msec


func _send_stall(now_msec: int) -> void:
	var stall := _stall
	_stall = {}
	if stall.frame / 1000.0 < SLOW_FRAME_MSEC:
		return
	if not _take_lines(_scene_lines, SCENE_LINES_PER_MINUTE, 1, now_msec):
		return
	var marks := _msec_of(stall.get("marks", _no_marks()))
	_send({"kind": KIND_SCENE, "scene": stall.scene, "stall": stall.frame / 1000.0, "marks": marks})


func _window_body() -> Dictionary:
	var w := _window
	var mirror_avg: float = w.mirror_usec / 1000.0 / w.mirror_frames if w.mirror_frames > 0 else 0.0
	return {
		"kind": KIND_FRAMES,
		"scene": w.scene,
		"msec": w.msec,
		"frames": w.frames,
		"avg": w.msec / w.frames if w.frames > 0 else 0.0,
		"worst": w.worst,
		"over": w.over,
		"mirror_avg": mirror_avg,
		"mirror_worst": w.mirror_worst_usec / 1000.0,
		"entities": w.entities,
		"corrections": w.corrections,
		"largest": w.largest,
		"age": w.age,
		"unacked": w.unacked,
		"speed": w.speed,
		"worst_marks": _msec_of(w.worst_marks),
		"worst_phases": _msec_of(w.worst_phases),
		"worst_fresh": w.worst_fresh,
		"fresh": w.fresh,
		"fresh_msec": w.fresh_usec / 1000.0,
		"fresh_worst": w.fresh_worst_usec / 1000.0,
		"fresh_worst_file": w.fresh_worst_file,
	}


static func _msec_of(usecs: Array) -> Array:
	var msecs := []
	for usec in usecs:
		msecs.append(usec / 1000.0)
	return msecs


func _window_line_count() -> int:
	return 2 if _window.corrections > 0 else 1


func _send(body: Dictionary) -> void:
	if test_client:
		sent.append(body)
		return
	session.send_reliable(session.transport.host_id, Protocol.Msg.CLIENT_REPORT, body)


func _new_window(scene: int) -> Dictionary:
	return {
		"scene": scene,
		"msec": 0.0,
		"frames": 0,
		"worst": 0.0,
		"over": 0,
		"mirror_frames": 0,
		"mirror_usec": 0,
		"mirror_worst_usec": 0,
		"entities": 0,
		"corrections": 0,
		"largest": 0.0,
		"age": 0.0,
		"unacked": 0,
		"speed": 0.0,
		"worst_marks": _no_marks(),
		"worst_phases": _no_phases(),
		"worst_fresh": 0,
		"fresh": 0,
		"fresh_usec": 0,
		"fresh_worst_usec": 0,
		"fresh_worst_file": "",
	}


func _no_marks() -> Array:
	return _zeros(MARK_NAMES.size())


func _no_phases() -> Array:
	return _zeros(PHASE_NAMES.size())


static func _zeros(size: int) -> Array:
	var zeros := []
	zeros.resize(size)
	for i in size:
		zeros[i] = 0
	return zeros


func _reset() -> void:
	_marks = _no_marks()
	_phases = _no_phases()
	_fresh = 0
	_previous = [0, _no_marks()]
	_scene_id = 0
	_window = {}
	_stall = {}
	_window_lines.clear()
	_scene_lines.clear()


# Room for lines more within the last minute of times (msec of earlier lines), up to limit:
# takes it (true) or leaves times as they are (false).
static func _take_lines(times: Array, limit: int, lines: int, now_msec: int) -> bool:
	while not times.empty() and now_msec - times[0] >= MINUTE_MSEC:
		times.pop_front()
	if times.size() + lines > limit:
		return false
	for _i in lines:
		times.append(now_msec)
	return true


func _on_message(steam_id: int, msg_type: int, body) -> void:
	if msg_type == Protocol.Msg.CLIENT_REPORT:
		host_receive(steam_id, body, OS.get_ticks_msec())


func host_receive(steam_id: int, body, now_msec: int) -> void:
	if session == null or not session.is_host():
		return
	var peer = session.peers.get(steam_id)
	if peer == null or not peer.ready:
		return
	var lines := report_lines(str(peer.name), body)
	if lines.empty():
		ModLoaderLog.debug("Malformed client report from %s" % steam_id, LOG_NAME)
		return
	var times: Array = _host_lines.get(steam_id, [])
	_host_lines[steam_id] = times
	last_lines = []
	for line in lines:
		if not _take_lines(times, MAX_LINES_PER_MINUTE, 1, now_msec):
			lines_dropped += 1
			_host_dropped[steam_id] = _host_dropped.get(steam_id, 0) + 1
			continue
		var dropped: int = _host_dropped.get(steam_id, 0)
		if dropped > 0:
			line += " (%d lines of this client left out before)" % dropped
			_host_dropped[steam_id] = 0
		lines_logged += 1
		last_lines.append(line)
		ModLoaderLog.info(line, LOG_NAME)


static func report_lines(client_name: String, body) -> Array:
	if typeof(body) != TYPE_DICTIONARY:
		return []
	var kind = body.get("kind")
	if typeof(kind) != TYPE_INT:
		return []
	var scene = _number(body, "scene", 0.0, SCENE_FILES.size() - 1.0)
	if scene == null:
		return []
	var where: String = SCENE_NAMES.get(int(scene), SCENE_FILES[int(scene)])
	if kind == KIND_SCENE:
		return _scene_lines_of(client_name, where, body)
	if kind == KIND_FRAMES:
		return _frame_lines_of(client_name, where, body)
	return []


static func _scene_lines_of(client_name: String, where: String, body: Dictionary) -> Array:
	var stall = _number(body, "stall", 0.0, MAX_MSEC)
	var marks = body.get("marks")
	if stall == null or typeof(marks) != TYPE_ARRAY or marks.size() != MARK_NAMES.size():
		return []
	var values = _numbers(marks, MARK_NAMES.size())
	if values == null:
		return []
	var parts := _mark_parts(values)
	var rest: float = stall
	for value in values:
		rest -= value
	parts.append("rest %d" % round(max(0.0, rest)))
	var line := (
		"Client %s entered %s: stalled %d ms (%s)"
		% [client_name, where, round(stall), PoolStringArray(parts).join(", ")]
	)
	return [line]


static func _frame_lines_of(client_name: String, where: String, body: Dictionary) -> Array:
	var v := {}
	var limits := {
		"msec": MAX_MSEC, "frames": MAX_COUNT, "avg": MAX_MSEC, "worst": MAX_MSEC,
		"over": MAX_COUNT, "mirror_avg": MAX_MSEC, "mirror_worst": MAX_MSEC,
		"entities": MAX_COUNT, "corrections": MAX_COUNT, "largest": MAX_PX, "age": MAX_MSEC,
		"unacked": MAX_COUNT, "speed": MAX_PX,
	}
	for key in limits:
		v[key] = _number(body, key, 0.0, limits[key])
		if v[key] == null:
			return []
	var seconds := "%d s" % round(v.msec / 1000.0)
	var line := (
		"Client %s frames in %s, %s: avg %d, worst %d, %d over %d ms"
		% [client_name, where, seconds, round(v.avg), round(v.worst), v.over, SLOW_FRAME_MSEC]
	)
	if v.mirror_avg > 0.0 or v.mirror_worst > 0.0:
		line += (
			"; mirror avg %.1f, worst %.1f ms; up to %d entities"
			% [v.mirror_avg, v.mirror_worst, v.entities]
		)
	if body.has("worst_phases"):
		var worst = _worst_frame_text(body)
		if worst == null:
			return []
		if v.worst >= SLOW_FRAME_MSEC:
			line += worst
	var lines := [line]
	if v.corrections > 0:
		lines.append(
			(
				"Client %s corrections, %s: %d over a step, largest %d px (snapshot %d ms old,"
				+ " %d inputs unacked, %d px/s)"
			)
			% [client_name, seconds, v.corrections, round(v.largest), round(v.age), v.unacked, v.speed]
		)
	return lines


# "; worst frame: apply 74, mirror 56.8 (players 0.3, entities 55.9, ...), 1 fresh; 31 fresh in
# 820 ms, costliest turret.tscn 55.2 ms", or null when a value is malformed.
static func _worst_frame_text(body: Dictionary):
	var marks = _numbers(body.get("worst_marks"), MARK_NAMES.size())
	var phases = _numbers(body.get("worst_phases"), PHASE_NAMES.size())
	var file = body.get("fresh_worst_file")
	if marks == null or phases == null or typeof(file) != TYPE_STRING:
		return null
	var v := {}
	for key in ["worst_fresh", "fresh"]:
		v[key] = _number(body, key, 0.0, MAX_COUNT)
	for key in ["fresh_msec", "fresh_worst"]:
		v[key] = _number(body, key, 0.0, MAX_MSEC)
	for key in v:
		if v[key] == null:
			return null
	var parts := _mark_parts(marks)
	var mirror := 0.0
	var phase_parts := []
	for i in phases.size():
		mirror += phases[i]
		phase_parts.append("%s %.1f" % [PHASE_NAMES[i], phases[i]])
	if mirror > 0.0:
		parts.append("mirror %.1f (%s)" % [mirror, PoolStringArray(phase_parts).join(", ")])
	if v.worst_fresh > 0:
		parts.append("%d fresh" % v.worst_fresh)
	var text := "; worst frame: "
	text += PoolStringArray(parts).join(", ") if not parts.empty() else "none of it measured"
	if v.fresh > 0:
		text += (
			"; %d fresh in %d ms, costliest %s %.1f ms"
			% [v.fresh, round(v.fresh_msec), _safe_file(file), v.fresh_worst]
		)
	return text


# Marks of 0.5 ms or more, as "name ms".
static func _mark_parts(marks: Array) -> Array:
	var parts := []
	for i in marks.size():
		if marks[i] >= 0.5:
			parts.append("%s %d" % [MARK_NAMES[i], round(marks[i])])
	return parts


# size numbers (msec), clamped, or null.
static func _numbers(values, size: int):
	if typeof(values) != TYPE_ARRAY or values.size() != size:
		return null
	var numbers := []
	for value in values:
		var number = _number({"v": value}, "v", 0.0, MAX_MSEC)
		if number == null:
			return null
		numbers.append(number)
	return numbers


# A scene file name from the network as it may go into the log, else "?".
static func _safe_file(file: String) -> String:
	if file.empty() or file.length() > MAX_FILE_LENGTH:
		return "?"
	for i in file.length():
		if not file[i] in FILE_CHARS:
			return "?"
	return file


static func _number(body: Dictionary, key: String, lo: float, hi: float):
	var value = body.get(key)
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_REAL:
		return null
	if is_nan(float(value)):
		return null
	return clamp(float(value), lo, hi)
