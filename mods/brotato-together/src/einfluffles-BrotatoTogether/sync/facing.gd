extends Reference
# The rotation of mirrored projectiles (protocol 18). A puppet used to face the direction between
# its last two snapshot positions. Those are rounded to half a pixel, so a slow shot's angle
# wobbled with every snapshot: the long red line an enemy slash shows before it strikes
# (300 px/s, 10 px per snapshot) swung by up to 4 degrees 30 times a second, and a shot the game
# never turns into its flight was turned all the same. The angle is the host's now.
#
# Host: a projectile's rotation is sent for REPEAT snapshots after it changes (a new shot, a
# bounce, a spinning one every time) and every REFRESH snapshots (staggered by net id).
# Client: resolve() keeps the newest angle per net id for as long as the id is listed. A puppet
# without one yet (all the snapshots that carried it were lost) faces its motion as before.
# Enemy lasers are not in here: their aim is a pose value (sync/pose.gd).

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const REPEAT := 3
const REFRESH := 15

# Host: net id -> [angle as on the wire, snapshot count of its last change]
var _last := {}
var _next := {}
var _sent := {}  # entity index -> radians, for the snapshot being built


# --- host ---


# For each projectile without a pose, while building a snapshot (end_snapshot() afterwards).
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


# The angles section of the snapshot just built: {entity index: radians}.
func end_snapshot() -> Dictionary:
	var sent := _sent
	_last = _next
	_next = {}
	_sent = {}
	return sent


# --- client ---


# After Snapshot.resolve (it builds view.index): view.angles_by_id {net id: radians} of every
# listed projectile whose angle is known. cache: owned by the caller, empty at battle start.
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
