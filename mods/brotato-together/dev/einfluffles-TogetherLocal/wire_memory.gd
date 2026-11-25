extends Reference
# A wire for two or more steam_emulator.gd objects in one process, for deterministic tests: a
# packet goes straight to the emulator it names, through var2bytes as a socket wire would carry
# it (so nothing is shared, and what is sent is known to survive a socket). All emulators on the
# wire share one clock that only moves in step().
#
#   var wire = WireMemory.new()
#   var host = SteamEmulator.new(1, "Host")
#   wire.add(host)        # host now runs on wire.clock and sends through the wire
#   wire.step(10)         # clock 10 ms on, then every emulator's poll()
#   wire.unplug(host.steam_id)  # its game is gone: the others see sessions fail, members leave


var clock = null  # ManualClock
var packets := 0  # carried so far
var bytes := 0
var _emulators := {}  # steam id -> emulator


class ManualClock:
	extends Reference
	var usec := 0

	func now_usec() -> int:
		return usec


func _init() -> void:
	clock = ManualClock.new()


func add(node) -> void:
	_emulators[node.steam_id] = node
	node.clock = clock
	node.attach_wire(self)


func get_emulator(steam_id: int):
	return _emulators.get(steam_id)


# The emulator leaves the wire as a game that quits: every other one loses it, and it loses them.
func unplug(steam_id: int) -> void:
	var gone = _emulators.get(steam_id)
	if gone == null:
		return
	_emulators.erase(steam_id)
	gone.attach_wire(null)
	for id in _ids():
		_emulators[id].wire_lost(steam_id)
		gone.wire_lost(id)


func send_packet(packet: Dictionary) -> bool:
	var target = _emulators.get(int(packet.get("to", 0)))
	if target == null or not _emulators.has(int(packet.get("from", 0))):
		return false
	var data := var2bytes(packet)
	packets += 1
	bytes += data.size()
	target.receive_packet(bytes2var(data, false))
	return true


func now_msec() -> int:
	return clock.usec / 1000


# The clock msec on, then each emulator's poll() (by steam id: the same order every run).
func step(msec := 0) -> void:
	clock.usec += msec * 1000
	for id in _ids():
		var node = _emulators.get(id)
		if node != null:
			node.poll()


func _ids() -> Array:
	var ids := _emulators.keys()
	ids.sort()
	return ids
