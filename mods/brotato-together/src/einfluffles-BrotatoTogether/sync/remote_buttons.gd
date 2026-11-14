extends Reference
# Host: one remote player's buttons on its virtual device, from the INPUT held mask plus the
# client's press counters (sync/press_counter.gd).
# - A press needs a counted edge: a button still held after a timeout release (or at rejoin) does
#   nothing until the client releases it, so a held accept can't accept twice.
# - A tap lost in a loss burst (counter moved, button no longer held) is replayed once.
# - ui_pause is never held here: the game pauses on its release (main._check_for_pause,
#   BaseShop._is_pause_requested), so it's delivered as press + release when the client releases
#   it. A timeout or a disconnect therefore never synthesizes a pause.
# - Menu directions repeat while held, like InputService's echo for real pads (devices 0..7 only).

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const PressCounter := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/press_counter.gd"
)
# InputService._echo_delay / _echo_interval
const ECHO_DELAY := 0.3
const ECHO_INTERVAL := 0.09

var device := -1
var last_pause_msec := -1  # when ui_pause was last delivered (tells PauseControl who paused)

var _counts := -1  # last counters seen; -1 until the first packet
var _down := 0  # pressed on the virtual device
var _blocked := 0  # held by the client without a counted press since a timeout / rejoin
var _pause_held := false  # client holds pause after a counted press
var _echo_left := -1.0


func _init(virtual_device: int) -> void:
	device = virtual_device


func apply(held: int, counts: int) -> void:
	if _counts < 0:
		_counts = counts
		_blocked = held
		return
	for i in VirtualDevices.BUTTON_ACTIONS.size():
		var bit: int = 1 << i
		var is_held := bool(held & bit)
		var presses: int = PressCounter.presses_between(_counts, counts, i)
		if i == VirtualDevices.PAUSE_INDEX:
			_apply_pause(is_held, presses)
		elif presses > 0:
			if _down & bit:
				_send(i, false)  # its release was lost
			_send(i, true)
			if not is_held:
				_send(i, false)
			_blocked &= ~bit
		elif not is_held:
			_blocked &= ~bit
			if _down & bit:
				_send(i, false)
	_counts = counts


# No input for a while: let go of everything; whatever the client still holds stays blocked.
func release_held() -> void:
	for i in VirtualDevices.BUTTON_ACTIONS.size():
		if _down & (1 << i):
			_blocked |= 1 << i
			_send(i, false)
	_echo_left = -1.0


func is_down(i: int) -> bool:
	return bool(_down & (1 << i))


# Called every frame on the host; enabled mirrors the game's own echo switch.
func process_echo(delta: float, enabled: bool) -> void:
	var nav_down := false
	for i in VirtualDevices.NAV_INDICES:
		nav_down = nav_down or is_down(i)
	if not nav_down or not enabled:
		_echo_left = -1.0
		return
	if _echo_left < 0.0:
		_echo_left = ECHO_DELAY
		return
	_echo_left -= delta
	if _echo_left > 0.0:
		return
	_echo_left = ECHO_INTERVAL
	# Like InputService._emulate_action: a pressed event for every held direction, no release.
	for i in VirtualDevices.NAV_INDICES:
		if is_down(i):
			VirtualDevices.press_button(_action(i), device, true)


# Releases since the last packet: presses - (still held) + (was held).
func _apply_pause(is_held: bool, presses: int) -> void:
	var releases := presses - int(is_held) + int(_pause_held)
	if releases > 0:
		VirtualDevices.press_button(_action(VirtualDevices.PAUSE_INDEX), device, true)
		VirtualDevices.press_button(_action(VirtualDevices.PAUSE_INDEX), device, false)
		last_pause_msec = OS.get_ticks_msec()
	_pause_held = is_held and (presses > 0 or _pause_held)


func _send(i: int, pressed: bool) -> void:
	VirtualDevices.press_button(_action(i), device, pressed)
	if pressed:
		_down |= 1 << i
	else:
		_down &= ~(1 << i)


func _action(i: int) -> String:
	return VirtualDevices.action(VirtualDevices.BUTTON_ACTIONS[i], device)
