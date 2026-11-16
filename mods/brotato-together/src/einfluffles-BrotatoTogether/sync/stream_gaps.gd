extends Reference
# Gaps in a steady stream of unreliable messages (the host's snapshots on a client, a client's
# inputs on the host), for the log: which direction stalls, how long, and why. Timed by Steam's
# receive time (Session.arrival_msec), so a long frame of this game is not a gap.
# The sender's clock for the message (snapshot time; input seq in physics steps) tells the two
# kinds apart: sent at the usual pace but arriving together after the gap = held up on the way;
# sent that far apart = the sender sent nothing (its frame stalled) or the messages were lost.
# At most one line per LOG_INTERVAL_MSEC; the next line counts the gaps left out meanwhile.

const GAP_MSEC := 200  # 6 snapshots / 12 inputs; a PING every second only sees longer ones
const LOG_INTERVAL_MSEC := 5000

var what := ""  # "snapshot", "input from ..."
var logged := 0  # lines so far (tests)
var last_line := ""
var _last_arrival := -1  # msec, -1: nothing yet
var _last_sent := 0
var _next_log_msec := 0
var _unlogged := 0  # gaps since the last line that were not logged (rate limit)
var _unlogged_longest := 0


func _init(stream_name: String) -> void:
	what = stream_name


# The next message starts the stream afresh (after a pause, a new battle).
func reset() -> void:
	_last_arrival = -1
	_last_sent = 0


# A message of the stream arrived (only the newest by the sender's clock counts). Logs a gap with
# where the time went, Steam's numbers for the connection and the scene; true when it logged.
# quiet: note the arrival but log nothing (it ends a pause the host announced).
func note(
	session: Node, steam_id: int, sent_msec: int, log_name: String, extra := "", quiet := false
) -> bool:
	var text := arrived(session.arrival_msec(), sent_msec, quiet)
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
func arrived(arrival_msec: int, sent_msec: int, quiet := false) -> String:
	if _last_arrival >= 0 and sent_msec <= _last_sent:
		return ""  # reordered or duplicate: not the head of the stream
	var gap: int = arrival_msec - _last_arrival
	var sent_gap: int = sent_msec - _last_sent
	var first := _last_arrival < 0
	_last_arrival = arrival_msec
	_last_sent = sent_msec
	if first or quiet or gap < GAP_MSEC:
		return ""
	if arrival_msec < _next_log_msec:
		_unlogged += 1
		_unlogged_longest = int(max(_unlogged_longest, gap))
		return ""
	_next_log_msec = arrival_msec + LOG_INTERVAL_MSEC
	logged += 1
	var cause := "held up on the way" if sent_gap * 2 <= gap else "not sent or lost"
	var text := "No %s for %d ms, sent %d ms apart: %s" % [what, gap, sent_gap, cause]
	if _unlogged > 0:
		text += (
			"; %d more gap(s) since the last line, longest %d ms"
			% [_unlogged, _unlogged_longest]
		)
	_unlogged = 0
	_unlogged_longest = 0
	return text
