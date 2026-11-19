extends Reference
# Logs gaps in a steady stream of unreliable messages (snapshots on a client, inputs on the host),
# timed by Steam's receive time (Session.arrival_msec), so a long frame here is not a gap. The
# sender's clock, and a seq where the stream has one, name the cause.

const GAP_MSEC := 200  # 6 snapshots / 12 inputs; a PING every second only sees longer ones
const LOG_INTERVAL_MSEC := 5000

var what := ""  # "snapshot", "input from ..."
# Streams with a seq: the sender's msec per seq step, and how many lost messages each message
# makes up for (InputSync.REDUNDANCY), so only a seq jump beyond that counts as lost.
var step_msec := 0.0
var redundancy := 0
var logged := 0  # lines so far
var last_line := ""
var _last_arrival := -1  # msec, -1: nothing yet
var _last_sent := 0
var _last_seq := 0
var _next_log_msec := 0
var _unlogged := 0  # gaps since the last line that were not logged (rate limit)
var _unlogged_longest := 0


func _init(stream_name: String) -> void:
	what = stream_name


# The next message starts the stream afresh (after a pause, a new battle).
func reset() -> void:
	_last_arrival = -1
	_last_sent = 0
	_last_seq = 0


# Only the newest message counts. extra goes after the cause; quiet notes the arrival without
# logging (it ends a pause the host announced); seq: -1 when the stream has none. True: logged.
func note(
	session: Node,
	steam_id: int,
	sent_msec: int,
	log_name: String,
	extra := "",
	quiet := false,
	seq := -1
) -> bool:
	var text := arrived(session.arrival_msec(), sent_msec, quiet, seq)
	if text == "":
		return false
	var scene: Node = session.get_tree().current_scene
	text += "%s (%s)%s" % [
		extra, scene.filename.get_file() if scene != null else "-", session.steam_status_text(steam_id)
	]
	last_line = text
	ModLoaderLog.info(text, log_name)
	return true


# The line's start for a gap that is to be logged now, else "".
func arrived(arrival_msec: int, sent_msec: int, quiet := false, seq := -1) -> String:
	if _last_arrival >= 0 and (seq <= _last_seq if seq >= 0 else sent_msec <= _last_sent):
		return ""  # reordered or duplicate: not the head of the stream
	var gap: int = arrival_msec - _last_arrival
	var sent_gap: int = sent_msec - _last_sent
	var seq_step: int = seq - _last_seq
	var first := _last_arrival < 0
	_last_arrival = arrival_msec
	_last_sent = sent_msec
	_last_seq = int(max(seq, 0))
	if first or quiet or gap < GAP_MSEC:
		return ""
	if arrival_msec < _next_log_msec:
		_unlogged += 1
		_unlogged_longest = int(max(_unlogged_longest, gap))
		return ""
	_next_log_msec = arrival_msec + LOG_INTERVAL_MSEC
	logged += 1
	var text := "No %s for %d ms, sent %d ms apart" % [what, gap, sent_gap]
	if seq < 0:
		text += ": " + ("held up on the way" if sent_gap * 2 <= gap else "not sent or lost")
	else:
		text += " (seq +%d): %s" % [seq_step, _seq_cause(gap, sent_gap, seq_step)]
	if _unlogged > 0:
		text += (
			"; %d more gap(s) since the last line, longest %d ms"
			% [_unlogged, _unlogged_longest]
		)
	_unlogged = 0
	_unlogged_longest = 0
	return text


# Send time the seq steps do not account for is time the sender ran no steps: its own stall when
# that is at least half the gap. Else a seq jump beyond the redundancy means lost messages.
func _seq_cause(gap: int, sent_gap: int, seq_step: int) -> String:
	if (sent_gap - seq_step * step_msec) * 2 >= gap:
		return "its game sent nothing for %d ms (its own stall)" % sent_gap
	if seq_step > redundancy + 1:
		return "%d inputs lost on the way" % (seq_step - 1)
	return "held up on the way"
