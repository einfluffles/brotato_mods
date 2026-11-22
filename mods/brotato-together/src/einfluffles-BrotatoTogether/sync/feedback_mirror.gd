extends Reference
# One-shot feedback that needs no game logic on the client, sent as snapshot events: explosions,
# bonus gold, the wave's end, gold boost and stat texts, whip and flail animations. One instance
# per battle on each side, holding no node references.

const Snapshot := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/snapshot.gd")
const PuppetEntity := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/puppet_entity.gd"
)
const AnimMirror := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/anim_mirror.gd")
const WarmPools := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/warm_pools.gd")
const ClientReport := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/client_report.gd"
)
const PF := Snapshot.PlayerField
# Announced with BATTLE_START (rockets, grenades, landmines, ... all use it).
const EXPLOSION_SCENE := "res://projectiles/explosion.tscn"
const EXPLODE_ANIMATION := "explode"
const STATE_REPEAT := 4  # snapshots a state event is sent for after it changes
const STATE_REFRESH := 15  # snapshots between resends, so a lost snapshot does not lose it
const MAX_STAT_TEXTS := 16  # per snapshot (a build can add a stat with every kill)

var fresh := {}  # scene path -> explosions instanced (not taken from main's pool)
var taken := {}  # scene path -> explosions made while the scene loaded and used (WarmPools)
var _explosions := {}  # instance id -> animation position at the last capture
var _picked := []  # [position, boost] of boosted gold picked up since the last capture
var _stat_texts := []  # [player, stat, value] added (removed: negative) since the last capture
var _lashes := {}  # weapon instance id -> its attack animation's position at the last capture
var _bonus := []  # [value, visible] last captured
var _bonus_since := -STATE_REFRESH
var _wave_end := -1  # WAVE_* flags last captured, -1 while the wave runs
var _wave_end_since := -STATE_REFRESH
var _last_levels := {}  # player index -> the host's last level
var _state_t := {}  # event kind -> host t of the last state event applied
var _wave_ended := false
var _label_shown := false
var _anims = AnimMirror.new()  # weapon animations without their method tracks


# type_idx: BattleHost._type_idx.
func capture(main: Node, events: Array, snapshot_count: int, type_idx: FuncRef) -> void:
	_capture_explosions(main, events, type_idx)
	_capture_weapon_anims(main, events)
	for picked in _picked:
		events.append([Snapshot.EVENT_GOLD_BOOST, picked[0], picked[1]])
	_picked.clear()
	for text in _stat_texts:
		events.append([Snapshot.EVENT_STAT, text[0], text[1], text[2]])
	_stat_texts.clear()
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


# Live explosions are the children of main._explosions. One is new when it was not there at the
# last capture or its animation started over (pooled and reused in between).
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


# A whip or flail plays its attack animation from the start with every attack
# (AnimatedHitboxShootingBehavior.shoot): new when it was not playing at the last capture or its
# position went back.
func _capture_weapon_anims(main: Node, events: Array) -> void:
	var seen := {}
	var players: Array = main.get("_players")
	for p in players.size():
		var weapons: Array = players[p].current_weapons
		for k in weapons.size():
			var player = attack_player(weapons[k])
			if player == null or not player.is_playing():
				continue
			if player.current_animation != weapons[k]._shooting_behavior.animation_name:
				continue
			var key: int = weapons[k].get_instance_id()
			var position: float = player.current_animation_position
			seen[key] = position
			if position < _lashes.get(key, INF):
				events.append([Snapshot.EVENT_WEAPON_ANIM, p, k, position])
	_lashes = seen


static func attack_player(weapon: Node):
	if not is_instance_valid(weapon):
		return null
	var behavior = weapon.get("_shooting_behavior")
	if not behavior is AnimatedHitboxShootingBehavior:
		return null
	var player = weapon.get_node_or_null("AnimationPlayer")
	if not player is AnimationPlayer or not player.has_animation(behavior.animation_name):
		return null
	return player


# main.clean_up_room's outcome, and whether the label is up: it starts later on a won run and is
# hidden again before the level-up panels.
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


# RunData.stat_added / stat_removed, which a client's puppet run never emits.
func stat_changed(stat: int, value: int, player_index: int) -> void:
	if player_index >= 0 and _stat_texts.size() < MAX_STAT_TEXTS:
		_stat_texts.append([player_index, stat, value])


func track(node: Node) -> void:
	if node is Gold and not node.is_connected("picked_up", self, "_on_gold_picked_up"):
		node.connect("picked_up", self, "_on_gold_picked_up")


# Bag pickups (player -1) happen while cleaning up, when the game shows no text either. By now
# main.on_gold_picked_up has doubled `boosted` (metal detector) and pooled the gold (off the tree).
func _on_gold_picked_up(gold: Node, player_index: int) -> void:
	if player_index < 0 or gold.get("boosted") == null or gold.boosted <= 1:
		return
	var position: Vector2 = gold.global_position if gold.is_inside_tree() else gold.position
	_picked.append([position, gold.boosted])


# t: host time of the event's snapshot; types: BattleClient._types.
func fire(main: Node, types: Dictionary, t: int, event: Array) -> void:
	match event[0]:
		Snapshot.EVENT_EXPLOSION:
			explode(main, types.get(event[1]), event[2], event[3], event[4])
		Snapshot.EVENT_GOLD_BOOST:
			_show_boost(main, event[1], event[2])
		Snapshot.EVENT_STAT:
			_show_stat(main, event[1], event[2], event[3])
		Snapshot.EVENT_WEAPON_ANIM:
			lash(main, event[1], event[2], event[3])
		Snapshot.EVENT_BONUS_GOLD, Snapshot.EVENT_WAVE_END:
			# Repeated state: an older copy that arrives late must not undo a newer one.
			if t < _state_t.get(event[0], -1):
				return
			_state_t[event[0]] = t
			if event[0] == Snapshot.EVENT_BONUS_GOLD:
				_show_bonus_gold(main, event[1], event[2])
			else:
				_show_wave_end(main, event[1])


# The visual part of WeaponService.explode + PlayerExplosion.start_explosion, through main's
# pool. No hitbox and no physics: the damage and the sound (first physics frame) are the host's.
func explode(main: Node, scene, position: Vector2, scale: float, smoke: int) -> Node:
	if not scene is PackedScene:
		return null
	var container = main.get("_explosions")
	var pool_id: int = scene.get_instance_id()
	var explosion = main.get_node_from_pool(pool_id, container)
	var started := -1  # instanced: when, else -1
	if explosion == null:
		started = OS.get_ticks_usec()
		explosion = scene.instance()
		if not explosion is PlayerExplosion:  # the path comes from the network
			explosion.free()
			return null
		main.add_explosion(explosion)
	var prepared := WarmPools.take(explosion)
	if prepared != "":
		taken[prepared] = taken.get(prepared, 0) + 1
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
	if started >= 0:
		ClientReport.fresh(scene.resource_path.get_file(), OS.get_ticks_usec() - started)
		fresh[scene.resource_path] = fresh.get(scene.resource_path, 0) + 1
	return explosion


# The puppet weapon's own attack animation from where the host's was, without its method track:
# that opens the hitbox and plays the sound, which are the host's (damage events, EVENT_SOUND).
func lash(main: Node, player_index: int, weapon_index: int, position: float) -> bool:
	var players: Array = main.get("_players")
	if player_index >= players.size() or players[player_index].dead:
		return false
	var weapons: Array = players[player_index].current_weapons
	var player = attack_player(weapons[weapon_index]) if weapon_index < weapons.size() else null
	if player == null:
		return false
	var name: String = weapons[weapon_index]._shooting_behavior.animation_name
	var animation: Animation = _anims._without_method_tracks(player, name)
	player.stop()
	player.play(name)
	player.seek(clamp(position, 0.0, animation.length), true)
	return true


func _show_boost(main: Node, position: Vector2, boost: int) -> void:
	var texts = main.get("_floating_text_manager")
	if boost <= 1 or texts == null or texts._cleaning_up:
		return
	var color := Color(ProgressData.settings.color_positive)
	texts.display(
		"x%d" % boost, position, color, null, texts.duration, false, texts.direction, false
	)


# FloatingTextManager.on_stat_added itself (which stats it skips, a dead player, the place over
# the player, the stacking, the colours), without its sounds: those are the host's events.
func _show_stat(main: Node, player_index: int, stat: int, value: int) -> void:
	var texts = main.get("_floating_text_manager")
	if texts == null or player_index >= texts.players.size():
		return
	if player_index >= texts.players_add_stats_count.size():
		return
	texts.on_stat_added(stat, value, 0.0, player_index, [], [])


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


# The text the game shows from RunData.levelled_up, from the host's level compared with its
# previous one (not this client's start value). Heals come as EVENT_HEAL (sync/hit_numbers.gd).
func player_stats(main: Node, i: int, entry: Array) -> void:
	var level: int = entry[PF.LEVEL]
	var last = _last_levels.get(i)
	if last == level:
		return
	_last_levels[i] = level
	var texts = main.get("_floating_text_manager")
	if last == null or texts == null or i >= texts.players.size():
		return
	if level > last:
		texts.on_levelled_up(i)


# A gold puppet the host no longer lists was picked up (main.on_gold_picked_up is the only way
# out of main._active_golds): EffectsManager.on_gold_picked_up's sparkle where it was.
static func gold_gone(main: Node, node) -> void:
	if not is_instance_valid(node) or not node is Gold or not node.is_inside_tree():
		return
	var effects = main.get("_effects_manager")
	if effects != null and not effects._cleaning_up:
		effects.play_gold_pickup_effect(node.global_position)
