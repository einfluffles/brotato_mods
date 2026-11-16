extends "res://ui/menus/global/focus_emulator.gd"
# Online, a grid several cursors share scrolls after this machine's own players only
# (ui/shared_scroll.gd); every other scroll is the game's.
#
# A control freed while it holds the cursor (an inventory rebuilt under it) is dropped here
# before the game's code touches it. The game reads focused_control in _draw, _input, the
# setter and on a player change (disconnect, restyle, focus signals): a debug build reads a
# freed control as null or raises a script error, a released build dereferences it and the
# game crashes natively. The mod moves its own cursors off a control before it frees one
# (sync/upgrades_sync.gd, sync/shop_sync.gd); this is the safety net for any other path, and
# its warning (at most one per WARN_INTERVAL_MSEC per emulator) says that one was taken.

const SharedScroll := preload("res://mods-unpacked/einfluffles-BrotatoTogether/ui/shared_scroll.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:FocusEmulator"
const WARN_INTERVAL_MSEC := 10000

var freed_drops := 0  # controls dropped because they were freed (tests)
# Instance id of focused_control, 0 without one: a freed control cannot be asked anything, and
# a debug build even reads it as null, so whether it still exists is looked up by id.
var _cursor_id := 0
var _warned_msec := -WARN_INTERVAL_MSEC
var _unwarned := 0  # drops since the last warning that did not log one


func _ensure_control_visible(control: Control) -> void:
	var scroll = _find_parent_scroll_container(control)
	if scroll != null and not SharedScroll.follows(self, scroll):
		return
	._ensure_control_visible(control)


# Godot 3 calls _input and _process of every script level, this extension's first: the game's
# own (input on the cursor, the redraw) then finds a live control or none.
func _input(_event: InputEvent) -> void:
	_drop_freed_control()


func _process(_delta: float) -> void:
	_drop_freed_control()


func _set_focused_control(control: Control) -> void:
	_drop_freed_control(false)  # the caller names the next control
	._set_focused_control(control)


func _set_player_index(value: int) -> void:
	_drop_freed_control(false)
	._set_player_index(value)


func _set_focused_control_with_style(control: Control, emit_signals: bool) -> void:
	._set_focused_control_with_style(control, emit_signals)
	_cursor_id = focused_control.get_instance_id() if is_instance_valid(focused_control) else 0


func _clear_focused_control() -> void:
	if _cursor_freed():
		_drop_freed_control(false)
	else:
		._clear_focused_control()
	_cursor_id = 0


func _cursor_freed() -> bool:
	return _cursor_id != 0 and instance_from_id(_cursor_id) == null


# Forgets a freed focused_control without touching it (nothing to disconnect or restyle: it is
# gone). move: the cursor goes to the control now at its place (the game's own recovery in
# _handle_input picks the same one, but through the freed control).
func _drop_freed_control(move := true) -> void:
	if not _cursor_freed():
		return
	var parent = _focused_parent
	var index := _focused_control_index
	focused_control = null
	_focused_control_index = -1
	_focused_parent = null
	_cursor_id = 0
	freed_drops += 1
	var replacement: Control = _control_at(parent, index) if move and player_index >= 0 else null
	_warn_freed(parent, index, replacement)
	if replacement != null:
		_set_focused_control_with_style(replacement, true)


# The live, visible control at index in parent (the last one if there are fewer), one this
# emulator can focus; null if none.
func _control_at(parent, index: int) -> Control:
	if not is_instance_valid(parent) or not parent.is_inside_tree() or index < 0:
		return null
	var count: int = parent.get_child_count()
	if count == 0:
		return null
	var control = parent.get_child(int(min(index, count - 1)))
	if (
		not (control is Control)
		or control.is_queued_for_deletion()
		or not control.is_visible_in_tree()
		or _find_control_base_data(control) == null
	):
		return null
	return control


func _warn_freed(parent, index: int, replacement: Control) -> void:
	var now := OS.get_ticks_msec()
	if now - _warned_msec < WARN_INTERVAL_MSEC:
		_unwarned += 1
		return
	var where := "a freed parent"
	if is_instance_valid(parent) and parent.is_inside_tree():
		where = str(parent.get_path())
	var text := "Player %d's cursor was on a control that was freed (child %d of %s); %s" % [
		player_index,
		index,
		where,
		"moved to %s" % replacement.name if replacement != null else "the cursor is cleared",
	]
	if _unwarned > 0:
		text += " (%d more since the last warning)" % _unwarned
	ModLoaderLog.warning(text, LOG_NAME)
	_warned_msec = now
	_unwarned = 0
