extends Reference
# The line one emulator sends over (one direction of every session it has): latency, jitter, loss,
# retransmits, the line's own rate, burst stalls and relay POP changes. Settings by key (DEFAULT),
# or a named profile (link_profiles.gd). Two random streams: one per message (jitter, loss), one
# for the schedule (stalls, POP), so when a stall comes does not depend on how much is sent.
# All times are the emulator's clock in usec (steam_emulator.gd: now_usec).

const LinkProfiles := preload("res://mods-unpacked/einfluffles-TogetherLocal/link_profiles.gd")

const DEFAULT := {
	"latency_msec": 0,
	"relay_latency_msec": 0,
	"jitter_msec": 0,
	"loss": 0.0,
	"retransmit_msec": 100,
	"line_rate": 0,
	"stalls": [],
	"pop_switch_msec": 0,
}
const MAX_RETRANSMITS := 10  # a reliable message is late, never lost
const FAKE_POP := 0x6C636C  # "lcl" as LinkWatch.pop_code reads it
const OTHER_POP := 0x6C6378  # "lcx": the relay after a POP change

var settings := DEFAULT.duplicate(true)
var profile := ""  # the profile set last; "" before one, "custom" after set_values
# Counters (status.json, tests): stalls begun, their msec, POP changes
var stalls := 0
var stalled_msec := 0
var pop_switches := 0

var _rng := RandomNumberGenerator.new()
var _schedule_rng := RandomNumberGenerator.new()
var _stall_until_usec := 0
var _next_stall_usec := []  # per settings.stalls entry; -1: not scheduled yet
var _next_pop_usec := -1
var _other_pop := false


func _init(seed_value := 1) -> void:
	reseed(seed_value)


func reseed(value: int) -> void:
	_rng.seed = value
	_schedule_rng.seed = value * 7919 + 1


# Settings by DEFAULT's keys; false (and nothing changed) for an unknown key or a bad value.
func set_values(values: Dictionary) -> bool:
	for key in values:
		if not DEFAULT.has(key) or not _valid(key, values[key]):
			return false
	for key in values:
		settings[key] = values[key].duplicate(true) if values[key] is Array else values[key]
	profile = "custom"
	_restart_schedule()
	return true


# All of a named profile's settings (link_profiles.gd), or "none": DEFAULT, no latency at all.
# False for an unknown name.
func set_profile(name: String) -> bool:
	if name == "none":
		settings = DEFAULT.duplicate(true)
		_restart_schedule()
		profile = name
		return true
	if not LinkProfiles.has(name):
		return false
	settings = DEFAULT.duplicate(true)
	if not set_values(LinkProfiles.settings(name)):
		return false
	profile = name
	return true


static func _valid(key: String, value) -> bool:
	match key:
		"loss":
			return (value is float or value is int) and value >= 0.0 and value <= 1.0
		"stalls":
			if not value is Array:
				return false
			for kind in value:
				if not kind is Dictionary or not _range(kind.get("every")):
					return false
				if not _range(kind.get("msec")):
					return false
				if kind.every[0] <= 0 or not float(kind.get("chance", 1.0)) > 0.0:
					return false
			return true
	return (value is int or value is float) and value >= 0


static func _range(value) -> bool:
	return value is Array and value.size() == 2 and value[0] >= 0 and value[1] >= value[0]


# Called once per poll: begins the stalls and POP changes that are due.
func tick(now: int) -> void:
	var kinds: Array = settings.stalls
	for i in kinds.size():
		if _next_stall_usec[i] < 0:
			_next_stall_usec[i] = now + _msec_between(kinds[i].every) * 1000
		elif now >= _next_stall_usec[i]:
			_next_stall_usec[i] = now + _msec_between(kinds[i].every) * 1000
			if _schedule_rng.randf() < float(kinds[i].get("chance", 1.0)):
				stall(now, _msec_between(kinds[i].msec))
	var every := int(settings.pop_switch_msec)
	if every <= 0:
		return
	if _next_pop_usec < 0:
		_next_pop_usec = now + every * 1000
	elif now >= _next_pop_usec:
		_next_pop_usec = now + every * 1000
		_other_pop = not _other_pop
		pop_switches += 1


# Every scheduled stall and POP change comes at most msec from now: a short test sees what the
# profile does over minutes.
func bring_forward(now: int, msec: int) -> void:
	var at := now + msec * 1000
	for i in _next_stall_usec.size():
		_next_stall_usec[i] = at if _next_stall_usec[i] < 0 else int(min(_next_stall_usec[i], at))
	if int(settings.pop_switch_msec) > 0:
		_next_pop_usec = at if _next_pop_usec < 0 else int(min(_next_pop_usec, at))


# Nothing this side sends moves for msec (a stall of the line or of Steam); queues keep it.
func stall(now: int, msec: int) -> void:
	var until := now + msec * 1000
	if until > _stall_until_usec:
		stalls += 1
		stalled_msec += msec
		_stall_until_usec = until


func stalled(now: int) -> bool:
	return now < _stall_until_usec


# One message's trip, jitter included (usec).
func latency_usec(relayed: bool) -> int:
	var msec := base_msec(relayed)
	var jitter := float(settings.jitter_msec)
	if jitter > 0.0:
		msec += _rng.randf_range(-jitter, jitter)
	return int(max(0.0, msec) * 1000.0)


# One way without jitter: what Steam's ping is made of.
func base_msec(relayed: bool) -> float:
	return float(settings.latency_msec) + (float(settings.relay_latency_msec) if relayed else 0.0)


func lost() -> bool:
	return float(settings.loss) > 0.0 and _rng.randf() < float(settings.loss)


# A reliable message's extra time: retransmit_msec per loss (the retransmits can be lost too).
# [usec, losses].
func retransmit_usec() -> Array:
	var losses := 0
	while losses < MAX_RETRANSMITS and lost():
		losses += 1
	return [losses * int(settings.retransmit_msec) * 1000, losses]


# What the line carries per second: Steam's send rate, or less on a slow line.
func pace_rate(send_rate: int) -> int:
	var line := int(settings.line_rate)
	return send_rate if line <= 0 or line >= send_rate else line


func pop() -> int:
	return OTHER_POP if _other_pop else FAKE_POP


func _restart_schedule() -> void:
	_next_stall_usec = []
	for _kind in settings.stalls:
		_next_stall_usec.append(-1)
	_next_pop_usec = -1


func _msec_between(bounds: Array) -> int:
	return _schedule_rng.randi_range(int(bounds[0]), int(bounds[1]))


# For status.json: the profile and what it did so far.
func summary() -> Dictionary:
	return {
		"profile": profile,
		"latency_msec": settings.latency_msec,
		"relay_latency_msec": settings.relay_latency_msec,
		"jitter_msec": settings.jitter_msec,
		"loss": settings.loss,
		"line_rate": settings.line_rate,
		"stalls": stalls,
		"stalled_msec": stalled_msec,
		"pop_switches": pop_switches,
	}
