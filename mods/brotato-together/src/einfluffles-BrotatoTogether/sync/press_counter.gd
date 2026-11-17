extends Reference
# Client: per button a 4-bit press counter, packed into one int (bit 4*i for BUTTON_ACTIONS[i]),
# sent next to the held mask. INPUT is unreliable: a tap that falls into a loss burst never shows
# up in any held mask, but the host still sees the counter move and replays it once.

const VirtualDevices := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/virtual_devices.gd"
)
const BITS := 4
const MASK := 15

var counts := 0

var _prev := 0  # held mask of the previous sample
var _latched := 0  # buttons with a press event since the previous sample


static func counter(packed: int, i: int) -> int:
	return (packed >> (BITS * i)) & MASK


# Presses between two packed counter values (wraps at 16; more than 15 lost presses collapse).
static func presses_between(old: int, new: int, i: int) -> int:
	return (counter(new, i) - counter(old, i)) & MASK


# Catches taps shorter than one sample (pressed and released within a physics frame).
func on_event(event: InputEvent) -> void:
	for i in VirtualDevices.BUTTON_ACTIONS.size():
		if event.is_action_pressed(VirtualDevices.BUTTON_ACTIONS[i]):
			_latched |= 1 << i


# held: buttons held right now; dropped: buttons whose presses count for nothing (still held
# afterwards, they need a new press). Returns the packed counters to send.
func sample(held: int, dropped := 0) -> int:
	var pressed := ((held & ~_prev) | (_latched & ~_prev & ~held)) & ~dropped
	for i in VirtualDevices.BUTTON_ACTIONS.size():
		if pressed & (1 << i):
			var shift: int = BITS * i
			var next: int = (counter(counts, i) + 1) & MASK
			counts = (counts & ~(MASK << shift)) | (next << shift)
	_prev = held
	_latched = 0
	return counts


# The buttons went elsewhere for a while (this client's own menu): what is held now was not
# pressed for the host.
func resume(held: int) -> void:
	_prev = held
	_latched = 0
