extends Reference
# The rotation of mirrored projectiles. Snapshot positions are rounded to 0.5 px, so the direction
# of motion gives a wobbling angle for slow shots; the host sends the angle instead.
# Enemy lasers are not in here: their aim is a pose value (sync/pose.gd).

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const REPEAT := 3  # snapshots an angle is sent for after it changes
const REFRESH := 15  # snapshots between resends, staggered by net id

# Host: net id -> [angle as on the wire, snapshot count of its last change]
var _last := {}
var _next := {}
var _sent := {}  # entity index -> radians, for the snapshot being built


func capture(node: Node2D, net_id: int, index: int, snapshot_count: int) -> void:
	var rotation: float = node.rotation
	var angle := Snapshot.quantize_angle(rotation)
	var last = _last.get(net_id)
	var changed_at := snapshot_count
	if last != null and last[0] == angle:
		changed_at = last[1]
	_next[net_id] = [angle, changed_at]
	if snapshot_count - changed_at < REPEAT or (snapshot_count + net_id) % REFRESH == 0:
		_sent[index] = rotation


func end_snapshot() -> Dictionary:
	var sent := _sent
	_last = _next
	_next = {}
	_sent = {}
	return sent


# Needs view.index (Snapshot.resolve). Sets view.angles_by_id {net id: radians}; the caller owns
# cache, which is empty at battle start.
static func resolve(view: Dictionary, cache: Dictionary) -> void:
	if not cache.has("angles"):
		cache["angles"] = {}  # net id -> [radians, host t]
		cache["angles_t"] = -1
	var known: Dictionary = cache.angles
	var sent: Dictionary = view.get("angles", {})
	for id in sent:
		var entry = known.get(id)
		if entry == null or view.t >= entry[1]:
			known[id] = [sent[id], view.t]
	var newest: bool = view.t >= cache.angles_t
	if newest:
		cache.angles_t = view.t
	var index: Dictionary = view.index
	var current := {}
	for id in known.keys():
		if index.has(id):
			current[id] = known[id][0]
		elif newest:
			known.erase(id)  # gone on the host: a later shot under this id is another one
	view["angles_by_id"] = current
