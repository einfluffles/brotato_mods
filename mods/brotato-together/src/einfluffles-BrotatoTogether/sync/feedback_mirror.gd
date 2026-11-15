extends Reference
# One-shot feedback that needs no game logic on the client (protocol 11). One instance per battle
# on each side (BattleHost / BattleClient replace it), holding no node references.
#
# Sent (sync/snapshot.gd events):
# - Player explosions (WeaponService.explode: rockets, grenades, mines, exploding hits) as
#   EVENT_EXPLOSION. The client plays the scene's own "explode" animation (flash, smoke) on a
#   pooled puppet without hitbox or physics: damage numbers and the sound are the host's events.
# - Bonus gold (the bag under player 1's life bar: value and visibility) and the wave's end (dim
#   screen, "wave completed" label) as state: sent when they change, repeated STATE_REPEAT times
#   and every STATE_REFRESH snapshots, so a lost snapshot does not lose them.
# - The "x2" over a boosted gold pickup (EVENT_GOLD_BOOST): the boost is host data.
# Derived by the client from what it already has (no bytes): screen shake (damage events), the
# level-up and heal texts (player stats), the gold pickup sparkle (a gold puppet that vanished).

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const PuppetEntity := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/puppet_entity.gd"
)
const PF := Snapshot.PlayerField
# Announced with BATTLE_START (rockets, grenades, landmines, ... all use it).
const EXPLOSION_SCENE := "res://projectiles/explosion.tscn"
const EXPLODE_ANIMATION := "explode"
const STATE_REPEAT := 4
const STATE_REFRESH := 15

# --- host ---
var _explosions := {}  # instance id -> animation position at the last capture
var _picked := []  # [position, boost] of boosted gold picked up since the last capture
var _bonus := []  # [value, visible] last captured
var _bonus_since := -STATE_REFRESH
var _wave_end := -1  # WAVE_* flags last captured, -1 while the wave runs
var _wave_end_since := -STATE_REFRESH
# --- client ---
var _last_stats := {}  # player index -> [health, max health, level] of the host's last stats
var _state_t := {}  # event kind -> host t of the last state event applied
var _wave_ended := false
var _label_shown := false


# --- host ---


# Appends this snapshot's feedback events (type_idx: BattleHost._type_idx).
func capture(main: Node, events: Array, snapshot_count: int, type_idx: FuncRef) -> void:
	_capture_explosions(main, events, type_idx)
	for picked in _picked:
		events.append([Snapshot.EVENT_GOLD_BOOST, picked[0], picked[1]])
	_picked.clear()
	var label = main.get("_ui_bonus_gold")
	var bonus := [int(RunData.bonus_gold), label != null and label.visible]
	if bonus != _bonus:
		_bonus = bonus
		_bonus_since = snapshot_count
	if _due(snapshot_count, _bonus_since):
		events.append([Snapshot.EVENT_BONUS_GOLD, bonus[0], bonus[1]])
	if main.get("_cleaning_up"):
		var flags := wave_end_flags(main)
		if flags != _wave_end:
			_wave_end = flags
			_wave_end_since = snapshot_count
		if _due(snapshot_count, _wave_end_since):
			events.append([Snapshot.EVENT_WAVE_END, flags])


static func _due(snapshot_count: int, since: int) -> bool:
	return snapshot_count - since < STATE_REPEAT or snapshot_count % STATE_REFRESH == 0


# Live explosions are the children of main._explosions (the pool takes finished ones out). One is
# new when it was not there at the last capture, or its animation started over (pooled and
# reused in between: the game's pools are LIFO).
func _capture_explosions(main: Node, events: Array, type_idx: FuncRef) -> void:
	var container = main.get("_explosions")
	var seen := {}
	if not is_instance_valid(container):
		_explosions = seen
		return
	for child in container.get_children():
		var animation_player = child.get("_animation_player")
		if not animation_player is AnimationPlayer or not animation_player.is_playing():
			continue
		var key: int = child.get_instance_id()
		var position: float = animation_player.current_animation_position
		seen[key] = position
		if position < _explosions.get(key, INF) and child.filename != "":
			var smoke = child.get("_explosion_smoke")
			events.append(
				[
					Snapshot.EVENT_EXPLOSION,
					type_idx.call_func(child.filename),
					child.global_position,
					child.scale.x,
					smoke.amount if smoke != null else 0,
				]
			)
	_explosions = seen


# What the end of the wave shows: main.clean_up_room's outcome, and whether the label is up
# (it starts later on a won run and is hidden again before the level-up panels).
static func wave_end_flags(main: Node) -> int:
	var flags := 0
	flags |= Snapshot.WAVE_FAILED if main.get("_is_wave_failed") else 0
	flags |= Snapshot.WAVE_LOST if main.get("_is_run_lost") else 0
	flags |= Snapshot.WAVE_WON if main.get("_is_run_won") else 0
	var label = main.get("_wave_cleared_label")
	if label != null and label.visible:
		var timer = label.get_node_or_null("Timer")
		if label.visible_characters != 0 or (timer != null and not timer.is_stopped()):
			flags |= Snapshot.WAVE_LABEL
	return flags


# A mirrored node enters the snapshots: gold gets the pickup hook (once per node, pools reuse it).
func track(node: Node) -> void:
	if node is Gold and not node.is_connected("picked_up", self, "_on_gold_picked_up"):
		node.connect("picked_up", self, "_on_gold_picked_up")


# Bag pickups (player -1) only happen while cleaning up, when the game shows no text either.
# A signal calls its targets in order of instance id: this object is made after main, so
# main.on_gold_picked_up has already doubled `boosted` (metal detector), and Gold.pickup resets
# it right after the signal. main's handler also pools the gold (out of the tree; its container
# sits at the origin).
func _on_gold_picked_up(gold: Node, player_index: int) -> void:
	if player_index < 0 or gold.get("boosted") == null or gold.boosted <= 1:
		return
	var position: Vector2 = gold.global_position if gold.is_inside_tree() else gold.position
	_picked.append([position, gold.boosted])


# --- client ---


# Protocol 11 events at render time (t: host time of their snapshot; types: BattleClient._types).
func fire(main: Node, types: Dictionary, t: int, event: Array) -> void:
	match event[0]:
		Snapshot.EVENT_EXPLOSION:
			explode(main, types.get(event[1]), event[2], event[3], event[4])
		Snapshot.EVENT_GOLD_BOOST:
			_show_boost(main, event[1], event[2])
		Snapshot.EVENT_BONUS_GOLD, Snapshot.EVENT_WAVE_END:
			# Repeated state: an older copy that arrives late must not undo a newer one.
			if t < _state_t.get(event[0], -1):
				return
			_state_t[event[0]] = t
			if event[0] == Snapshot.EVENT_BONUS_GOLD:
				_show_bonus_gold(main, event[1], event[2])
			else:
				_show_wave_end(main, event[1])


# The visual part of WeaponService.explode + PlayerExplosion.start_explosion, through main's pool
# like the game's. No hitbox (it would find nothing: puppets have no layers, but its damage is
# the host's), no physics (its first physics frame plays the sound, which is the host's event).
func explode(main: Node, scene, position: Vector2, scale: float, smoke: int) -> Node:
	if not scene is PackedScene:
		return null
	var container = main.get("_explosions")
	var pool_id: int = scene.get_instance_id()
	var explosion = main.get_node_from_pool(pool_id, container)
	if explosion == null:
		explosion = scene.instance()
		if not explosion is PlayerExplosion:  # the path comes from the network
			explosion.free()
			return null
		main.add_explosion(explosion)
	explosion.pool_id = pool_id  # end_explosion pools it when "explode" ends, like the game's
	explosion.global_position = position
	explosion.scale = Vector2(scale, scale)
	PuppetEntity.puppetize(explosion)
	explosion.sound_played = true
	explosion._hitbox.disable()
	explosion._explosion_smoke.amount = int(max(1, smoke))
	explosion._sprite.modulate.a = ProgressData.settings.explosion_opacity  # this player's option
	if main.get("_is_fog_wave"):
		main._fog_viewport._on_spawn_explosion(explosion)
	var animation_player: AnimationPlayer = explosion._animation_player
	animation_player.stop(true)
	animation_player.play(EXPLODE_ANIMATION)
	return explosion


func _show_boost(main: Node, position: Vector2, boost: int) -> void:
	var texts = main.get("_floating_text_manager")
	if boost <= 1 or texts == null or texts._cleaning_up:
		return
	var color := Color(ProgressData.settings.color_positive)
	texts.display(
		"x%d" % boost, position, color, null, texts.duration, false, texts.direction, false
	)


func _show_bonus_gold(main: Node, value: int, visible: bool) -> void:
	RunData.bonus_gold = value  # the label's tooltip reads it
	var label = main.get("_ui_bonus_gold")
	if label != null:
		label.update_value(value)
		label.visible = visible


# main.clean_up_room's visible part; the wave itself ends on the host (BATTLE_END).
func _show_wave_end(main: Node, flags: int) -> void:
	if not _wave_ended:
		_wave_ended = true
		main._ui_dim_screen.dim()
		main._floating_text_manager.clean_up_room()  # no more gold texts, like the host's
		main._effects_manager.clean_up_room()  # no more gold sparkles (golds fly to the bag)
		main._stop_ambient()
	var label = main.get("_wave_cleared_label")
	var shown := bool(flags & Snapshot.WAVE_LABEL)
	if label == null or shown == _label_shown:
		return
	_label_shown = shown
	if shown:
		label.show()
		label.start(
			bool(flags & Snapshot.WAVE_FAILED),
			bool(flags & Snapshot.WAVE_LOST),
			bool(flags & Snapshot.WAVE_WON)
		)
	else:
		label.hide()


# Screenshaker's handlers, connected by main to the players and to every enemy / neutral.
static func shake(main: Node, target: Node, args: Array) -> void:
	var shaker = main.get("_screenshaker")
	if shaker == null:
		return
	if target is Player:
		shaker.callv("_on_player_took_damage", args)
	elif target is Enemy or target is Neutral:
		shaker.callv("_on_unit_took_damage", args)


# Texts the game shows from RunData.levelled_up and Player.healed, from the host's stats: compared
# with the host's previous ones (not this client's start values). A heal and a hit inside one
# snapshot (1/30 s) show as their sum; a heal that also raised max health shows nothing.
func player_stats(main: Node, i: int, entry: Array) -> void:
	var stats := [entry[PF.HEALTH], entry[PF.MAX_HEALTH], entry[PF.LEVEL]]
	var last = _last_stats.get(i)
	if last == stats:
		return
	_last_stats[i] = stats
	var texts = main.get("_floating_text_manager")
	if last == null or texts == null or i >= texts.players.size():
		return
	if stats[0] > last[0] and stats[1] == last[1]:
		texts._on_player_healed(stats[0] - last[0], i)
	if stats[2] > last[2]:
		texts.on_levelled_up(i)


# A gold puppet the host no longer lists was picked up (main.on_gold_picked_up is the only way
# out of main._active_golds): EffectsManager.on_gold_picked_up's sparkle where it was.
static func gold_gone(main: Node, node) -> void:
	if not is_instance_valid(node) or not node is Gold or not node.is_inside_tree():
		return
	var effects = main.get("_effects_manager")
	if effects != null and not effects._cleaning_up:
		effects.play_gold_pickup_effect(node.global_position)
