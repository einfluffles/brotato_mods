extends Reference
# The damage meter's run stats (sync/damage_meter.gd): the waves of the current run, summed per
# player. The meter hands over each wave when it freezes the wave's last measurement; the wave
# counts once the run goes on to the shop or ends (commit). A wave that starts again (retry) drops
# the held one, a battle at or before the last counted wave (a new run) starts the ledger anew.
#
# Per player: {sources: {key: [my_id, count, damage]}, total, hit: [damage, my_id], kills, taken}.
# The key groups what is one thing for the run: a weapon's tiers (weapon_id), the builder's
# turrets; my_id and count are the latest wave's.

var last_wave := 0  # the last counted wave, 0: none
var waves := 0
var time := 0.0  # seconds the counted waves' timers ran
var players := []

var _held = null  # [wave, time, players] of the frozen wave, as the ledger reads with it


func reset() -> void:
	last_wave = 0
	waves = 0
	time = 0.0
	players = []
	_held = null


func is_empty() -> bool:
	return waves == 0 and _held == null


# A battle starts: a wave held before never reached the shop or the end of the run.
func start_wave(wave: int) -> void:
	_held = null
	if wave <= last_wave:
		reset()


# The frozen wave; wave_players as `players` above, for that wave alone.
func hold(wave: int, wave_time: float, wave_players: Array) -> void:
	var merged := []
	for p in int(max(players.size(), wave_players.size())):
		var into: Dictionary = _copy(players[p]) if p < players.size() else _empty_player()
		if p < wave_players.size():
			_add(into, wave_players[p])
		merged.append(into)
	_held = [wave, time + wave_time, merged]


# The run went on to the shop or ended: the held wave counts.
func commit() -> void:
	if _held == null:
		return
	if _held[0] != last_wave:
		waves += 1
	last_wave = _held[0]
	time = _held[1]
	players = _held[2]
	_held = null


# What the board carries ("run"): the held wave included, `limit` sources per player.
#   {waves, time, players: [[total, [[my_id, count, damage], ...], [damage, my_id], kills, taken]]}
func wire(limit: int) -> Dictionary:
	var held: bool = _held != null
	var shown: Array = _held[2] if held else players
	var count := waves + (1 if held and _held[0] != last_wave else 0)
	var sent := []
	for player in shown:
		var sources := []
		for key in player.sources:
			var source: Array = player.sources[key]
			if source[2] > 0:
				sources.append(source.duplicate())
		sources.sort_custom(Order, "strongest_first")
		sent.append([
			player.total,
			sources.slice(0, limit - 1) if not sources.empty() else [],
			player.hit.duplicate(),
			player.kills,
			player.taken,
		])
	return {"waves": count, "time": stepify(_held[1] if held else time, 0.1), "players": sent}


static func _empty_player() -> Dictionary:
	return {"sources": {}, "total": 0, "hit": [0, ""], "kills": 0, "taken": 0}


static func _copy(player: Dictionary) -> Dictionary:
	return player.duplicate(true)


static func _add(into: Dictionary, wave: Dictionary) -> void:
	for key in wave.sources:
		var source: Array = wave.sources[key]
		var damage: int = source[2] + (into.sources[key][2] if into.sources.has(key) else 0)
		into.sources[key] = [source[0], source[1], damage]
	into.total += wave.total
	if wave.hit[0] > into.hit[0]:
		into.hit = wave.hit.duplicate()
	into.kills += wave.kills
	into.taken += wave.taken


class Order:
	static func strongest_first(a: Array, b: Array) -> bool:
		return a[2] > b[2] if a[2] != b[2] else a[0] < b[0]
