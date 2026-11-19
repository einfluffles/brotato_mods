extends Reference
# What went out reliably to each peer in the last two seconds, by message type (and STATE
# section), for the log lines about a slow answer or a full Steam send queue.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const StateStream := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd")
const BUCKET_MSEC := 1000
const MAX_LABELS := 4  # in one summary, largest first
const BACKLOG_TEXT_BYTES := 4096
const BIG_MESSAGE_BYTES := 32768
const BIG_BACKLOG_BYTES := 65536
const LINE_INTERVAL_MSEC := 5000
# Steam's queue is asked after every message of QUERY_MIN_BYTES or more, after smaller ones at
# most once per QUERY_INTERVAL_MSEC per peer: a stream of small messages costs no call each.
const QUERY_MIN_BYTES := 4096
const QUERY_INTERVAL_MSEC := 250

# steam_id -> {second, now: {label: [count, bytes]}, before: {...}, next_line_msec,
# next_query_msec}
var peers := {}
var lines := 0  # standalone lines logged so far
var last_line := ""


static func label(msg_type: int, body) -> String:
	var names: Array = Protocol.Msg.keys()
	var text: String = names[msg_type] if msg_type >= 0 and msg_type < names.size() else str(msg_type)
	if msg_type == Protocol.Msg.STATE and typeof(body) == TYPE_ARRAY and not body.empty():
		var section = body[0]
		if typeof(section) == TYPE_INT and section >= 0 and section < StateStream.NAMES.size():
			text += " " + StateStream.NAMES[section]
	return text


func note(steam_id: int, text: String, size: int, now_msec: int) -> void:
	if not peers.has(steam_id):
		peers[steam_id] = {
			"second": now_msec / BUCKET_MSEC,
			"now": {},
			"before": {},
			"next_line_msec": 0,
			"next_query_msec": 0,
		}
	var bucket: Dictionary = _roll(peers[steam_id], now_msec).now
	if not bucket.has(text):
		bucket[text] = [0, 0]
	bucket[text][0] += 1
	bucket[text][1] += size


# label -> [count, bytes] of this second and the one before.
func window(steam_id: int, now_msec: int) -> Dictionary:
	if not peers.has(steam_id):
		return {}
	var entry: Dictionary = _roll(peers[steam_id], now_msec)
	var sums := {}
	for bucket in [entry.before, entry.now]:
		for text in bucket:
			if not sums.has(text):
				sums[text] = [0, 0]
			sums[text][0] += bucket[text][0]
			sums[text][1] += bucket[text][1]
	return sums


# "STATE shop 3 x 13.1 KB, UI_SOUNDS 4 x 0.2 KB": count x mean size, largest total first, at most
# MAX_LABELS; "" when nothing went out.
func summary(steam_id: int, now_msec: int) -> String:
	var sums := window(steam_id, now_msec)
	var rows := []
	for text in sums:
		rows.append([text, sums[text][0], sums[text][1]])
	rows.sort_custom(self, "_larger")
	var parts := []
	for i in min(rows.size(), MAX_LABELS):
		var row: Array = rows[i]
		parts.append("%s %d x %s" % [row[0], row[1], kilobytes(row[2] / row[1])])
	return PoolStringArray(parts).join(", ")


func backlog_text(steam_id: int, pending_reliable: int, now_msec: int) -> String:
	if pending_reliable < BACKLOG_TEXT_BYTES:
		return ""
	var text := summary(steam_id, now_msec)
	return "; reliable in the last 2 s: " + text if text != "" else ""


# After note(): the standalone line for this send, or "".
func burst_line(
	steam_id: int, peer_name: String, text: String, size: int, pending_reliable: int, now_msec: int
) -> String:
	if size <= BIG_MESSAGE_BYTES and pending_reliable <= BIG_BACKLOG_BYTES:
		return ""
	if not line_due(steam_id, now_msec):
		return ""
	peers[steam_id].next_line_msec = now_msec + LINE_INTERVAL_MSEC
	lines += 1
	last_line = (
		"Reliable burst to %s: %s of %s queued, %s pending; reliable in the last 2 s: %s"
		% [
			peer_name, text, kilobytes(size), kilobytes(pending_reliable),
			summary(steam_id, now_msec)
		]
	)
	return last_line


func line_due(steam_id: int, now_msec: int) -> bool:
	return not peers.has(steam_id) or now_msec >= peers[steam_id].next_line_msec


func query_due(steam_id: int, size: int, now_msec: int) -> bool:
	if not peers.has(steam_id):
		return true
	var entry: Dictionary = peers[steam_id]
	if size < QUERY_MIN_BYTES and now_msec < entry.next_query_msec:
		return false
	entry.next_query_msec = now_msec + QUERY_INTERVAL_MSEC
	return true


func forget(steam_id: int) -> void:
	peers.erase(steam_id)


func clear() -> void:
	peers.clear()


static func kilobytes(size: int) -> String:
	return "%.1f KB" % (size / 1024.0)


static func _roll(entry: Dictionary, now_msec: int) -> Dictionary:
	var second := now_msec / BUCKET_MSEC
	if second <= entry.second:
		return entry
	entry.before = entry.now if second == entry.second + 1 else {}
	entry.now = {}
	entry.second = second
	return entry


func _larger(a: Array, b: Array) -> bool:
	return a[2] > b[2] or (a[2] == b[2] and a[0] < b[0])
