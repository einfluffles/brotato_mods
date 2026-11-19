extends Reference
# How far behind the newest snapshot a client renders the host's world. Through a stall of up to
# MAX_HOLD_MSEC render time holds on the newest snapshot, so the world carries on from there
# instead of jumping ahead, then catches up; recurring lateness keeps the delay at floor_msec.

const MAX_HOLD_MSEC := 500
const SHRINK_RATE := 0.15  # delay ms given back per ms
const JITTER_WINDOW_MSEC := 5000
const JITTER_HOLDS := 2
const MAX_JITTER_MSEC := 250
const MAX_HOLDS_KEPT := 16

var delay_msec := 0.0
var holds := 0
var _base := 0.0
var _holding := false
var _holds := []  # [msec, delay reached] of recent holds, oldest first


func _init(base_msec: int) -> void:
	_base = float(base_msec)
	delay_msec = _base


# Render time (host msec) for this frame. clock_offset: local msec - host msec (min-filtered);
# newest_t: host time of the newest snapshot; delta: this frame's seconds.
func render_time(now: int, clock_offset: float, newest_t: float, delta: float) -> float:
	var lag: float = now - clock_offset - newest_t  # the delay that renders the newest snapshot
	if lag > delay_msec:  # render time would pass the newest snapshot: nothing to show there
		if lag <= MAX_HOLD_MSEC:
			delay_msec = lag
			_holding = true
		else:
			delay_msec = floor_msec(now)
			_holding = false  # too long to hold: not counted as lateness either
	else:
		if _holding:  # the next snapshot came
			_holding = false
			holds += 1
			_holds.append([now, delay_msec])
			if _holds.size() > MAX_HOLDS_KEPT:
				_holds.pop_front()
		var lowest := floor_msec(now)
		if delay_msec > lowest:
			delay_msec = max(lowest, delay_msec - SHRINK_RATE * delta * 1000.0)
	return now - clock_offset - delay_msec


# The base delay, or the recent lateness while it recurs.
func floor_msec(now: int) -> float:
	while not _holds.empty() and now - _holds[0][0] > JITTER_WINDOW_MSEC:
		_holds.pop_front()
	if _holds.size() < JITTER_HOLDS:
		return _base
	var longest := _base
	for hold in _holds:
		longest = max(longest, hold[1])
	return min(longest, max(_base, MAX_JITTER_MSEC))


func text() -> String:
	return "; render delay %d ms" % delay_msec
