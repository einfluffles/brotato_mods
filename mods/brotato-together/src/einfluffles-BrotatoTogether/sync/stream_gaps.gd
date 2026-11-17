extends Reference
# Gaps in a steady stream of unreliable messages (the host's snapshots on a client, a client's
# inputs on the host), for the log: which direction stalls, how long, and why. Timed by Steam's
# receive time (Session.arrival_msec), so a long frame of this game is not a gap.
# The sender's clock for the message (snapshot time; the client's msec clock when it sent an input)
# tells the kinds apart: sent at the usual pace but arriving together after the gap = held up on
# the way; sent that far apart = the sender sent nothing (its frame stalled) or the messages were
# lost. A stream with a seq per message (inputs: one per physics step) tells those two apart too:
# a sender whose frame stalls runs no physics steps meanwhile, so its clock jumps and its seq
# doesn't, while lost messages leave a seq jump that matches the clock's.
# At most one line per LOG_INTERVAL_MSEC; the next line counts the gaps left out meanwhile.

const GAP_MSEC := 200  # 6 snapshots / 12 inputs; a PING every second only sees longer ones
const LOG_INTERVAL_MSEC := 5000

var what := ""  # "snapshot", "input from ..."
# Streams with a seq (see arrived): the sender's msec per seq step (inputs: one physics step), and
# how many lost messages each one makes up for (InputSync.REDUNDANCY: the moves before it ride
# along), so only a seq jump beyond that counts as lost.
var step_msec := 0.0
var redundancy := 0
var logged := 0  # lines so far (tests)
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


# A message of the stream arrived (only the newest counts). Logs a gap with where the time went,
# Steam's numbers for the connection and the scene; true when it logged. extra goes after the
# cause. quiet: note the arrival but log nothing (it ends a pause the host announced).
# seq: the message's seq when the stream has one (see arrived), else -1.
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


# The line's start for a gap that is to be logged now, else "". seq (-1: none) orders the messages
# and, with the sender's clock, names the cause (see _seq_cause); without one the clock alone does.
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


# Why a stream with a seq went quiet for gap ms. The send time its seq steps don't account for is
# time the sender ran no steps: its own stall, when that is at least half the gap. Else a seq jump
# beyond what the redundancy makes up for means lost messages, else they were sent at the usual
# pace and held up on the way.
func _seq_cause(gap: int, sent_gap: int, seq_step: int) -> String:
	if (sent_gap - seq_step * step_msec) * 2 >= gap:
		return "its game sent nothing for %d ms (its own stall)" % sent_gap
	if seq_step > redundancy + 1:
		return "%d inputs lost on the way" % (seq_step - 1)
	return "held up on the way"
