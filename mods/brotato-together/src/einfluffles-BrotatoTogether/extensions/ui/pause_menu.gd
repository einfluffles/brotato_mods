extends "res://ui/menus/ingame/pause_menu.gd"
# Live mode: the menu opens over the running game instead of pausing it (sync/pause_control.gd
# turns it on during a wave of an online session, where a pause would freeze everybody). The
# game's callers all end in pause(), which opens the menu or, once it is open, goes a step back.

signal live_changed(open)

var live := false
var live_open := false
# Esc is pause and cancel at once and can arrive as two events (a client's buttons are
# synthetic): one step back per window, and no reopening inside it.
var back_guard_msec := 200

var _live_owner := -1
var _back_msec := 0


func pause(player_index: int) -> void:
	if live_open:
		_player_index = _live_owner  # the base _input sets it before it calls
		if player_index == _live_owner:
			live_back()
		return
	if not live or get_tree().paused:
		.pause(player_index)
		return
	if enabled:
		open_live(player_index)


func open_live(player_index: int) -> void:
	if live_open or get_tree().paused or OS.get_ticks_msec() - _back_msec < back_guard_msec:
		return
	live_open = true
	_live_owner = player_index
	_back_msec = OS.get_ticks_msec()
	set_process_input(true)
	_focus_emulator.set_process_input(true)
	_player_index = player_index
	_focus_emulator.player_index = player_index
	if not _menus.is_connected("menu_page_switched", self, "_on_live_page_switched"):
		_menus.connect("menu_page_switched", self, "_on_live_page_switched")
	emit_signal("paused")  # the game's listeners (main: menu echo on)
	show()
	Utils.set_default_cursor()
	_main_menu.init(player_index)
	emit_signal("live_changed", true)


func unpause() -> void:
	if not live_open:
		.unpause()
		return
	live_open = false
	_back_msec = OS.get_ticks_msec()
	_drop_codex()
	set_process_input(false)
	_focus_emulator.set_process_input(false)
	_focus_emulator.player_index = -1
	hide()
	_menus.reset()
	emit_signal("unpaused")
	emit_signal("live_changed", false)


func live_back() -> void:
	var now := OS.get_ticks_msec()
	if not live_open or codex_is_opened or now - _back_msec < back_guard_msec:
		return
	_back_msec = now
	manage_back()


# A page that went back by itself (the confirm pages take the plain "ui_cancel") counts as the
# step: the same Esc is still to come as pause from main's polling.
func _on_live_page_switched(_from, _to) -> void:
	if live_open:
		_back_msec = OS.get_ticks_msec()


func _input(event: InputEvent) -> void:
	if not live_open or not Utils.is_player_cancel_released(event, _live_owner):
		return
	if codex_is_opened:
		# The codex closes on the plain "ui_cancel", which a client's own device never sends.
		if not event.is_action_released("ui_cancel"):
			_menus._codex._on_BackButton_pressed()
	else:
		live_back()
	get_viewport().set_input_as_handled()


# Closed from outside (the wave ended) with the codex up: without its closing animation.
func _drop_codex() -> void:
	if not codex_is_opened:
		return
	var codex = _menus._codex
	codex.hide()
	codex.animation_tree.active = false
	if Utils._popup == codex:
		Utils._popup = null
	codex_is_opened = false


# Nothing to pause in live mode: the game runs on for the others.
func on_game_lost_focus() -> void:
	if live and not get_tree().paused:
		return
	.on_game_lost_focus()
