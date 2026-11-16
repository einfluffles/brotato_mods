extends Node
# What a run with the host earns counts for every player's own save, like in local co-op, where
# one profile gets whatever any player achieves. Until protocol 20 a client earned nothing: its
# copy of the game decides nothing, and its save is closed while it mirrors.
#
# Host -> clients, PROGRESS (reliable, at most once a second): {challenges, stats, won}.
# - challenges: ids the host's game found reached just now (ChallengeService extension: every
#   try_complete_challenge whose value is there, every complete_challenge), each once per
#   session, also when the host completed it long ago.
# - stats: how often the host's lifetime counters went up (ProgressData.increment_stat: enemies
#   killed, materials collected, trees, ...). Each client adds them to its own counters; the
#   challenges that hang on a lifetime counter (LIFETIME_*) are never sent, each client reaches
#   them with its own count.
# - won: the run was won. The client runs the game's own RunData.apply_run_won on its mirrored
#   run: the characters' challenges and the danger levels, as local co-op gives them.
# The client completes a challenge with the game's own code (popup, platform achievement, the
# reward) under Puppet.own_progress, and its save is written with its own values
# (ProgressData.bt_save_own). A reward behind a DLC the client only has from the host is kept
# unlocked in its save; without the DLC the game does not offer it.
# Not yet: the species lists (trophy hunter, clever girl, egg hunt) and the codex's kill counts.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const LOG_NAME := "einfluffles-BrotatoTogether:ProgressShare"
const SEND_SEC := 1.0
const SAVE_SEC := 60.0  # counters alone: the save follows at most this late
const MAX_CHALLENGES := 64  # per message (network data)
const MAX_COUNT := 100000
# Lifetime counters a client counts for itself -> the challenge names the game checks them for
# (ChallengeService.check_counted_challenges) or the one challenge it tries.
const LIFETIME_NAMES := {
	"enemies_killed": "CHAL_SURVIVOR",
	"materials_collected": "CHAL_GATHERER",
	"trees_killed": "CHAL_LUMBERJACK",
	"enemies_killed_far_away": "CHAL_CAUTIOUS",
	"evil_mob_killed": "CHAL_EVIL_HAT",
}
const LIFETIME_IDS := {
	"dig_sites_dug_up": "chal_dig_site",
	"fruit_eaten_full_hp": "chal_fruit_basket",
	"whip_jungle_kills": "chal_whip_it",
}
# Counters that are sent; the rest of ProgressData.data is not the host's to write.
const STATS := [
	"enemies_killed", "materials_collected", "trees_killed", "enemies_killed_far_away",
	"evil_mob_killed", "evil_mob_killed_by", "dig_sites_dug_up", "fruit_eaten_full_hp",
	"whip_jungle_kills", "run_won",
]
# Reached with the host's own history, not in this run: never sent.
const HOST_ONLY := ["chal_hourglass", "chal_trophy_hunter", "chal_clever_girl", "chal_egg_hunt"]
const WON := "run_won"

var session: Node = null
var last_sent := {}  # host: the last PROGRESS body (tests)
var test_sharing := false  # tests: a host with a ready peer, without a session

var _sent := {}  # host: challenge ids sent in this session
var _challenges := []  # host: ids waiting for the next message
var _stats := {}  # host: counter -> count waiting
var _since := 0.0
var _excluded := {}  # host: ids of the lifetime and host-only challenges
var _dirty := false  # client: counters changed since the last save
var _unsaved := 0.0


func setup(netplay_session: Node) -> void:
	session = netplay_session
	session.connect("message", self, "_on_message")
	session.connect("peer_ready", self, "_on_peer_changed")
	session.transport.connect("lobby_left", self, "_on_lobby_left")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


func _process(delta: float) -> void:
	_since += delta
	if _since >= SEND_SEC:
		_since = 0.0
		flush()
	if _dirty:
		_unsaved += delta
		if _unsaved >= SAVE_SEC:
			_save()


# --- host ---


func sharing() -> bool:
	if test_sharing:
		return true
	if session == null or not session.is_host():
		return false
	for steam_id in session.peers:
		if session.peers[steam_id].ready:
			return true
	return false


# A value the game holds against a challenge (ChallengeService.try_complete_challenge).
func host_met(chal_id: int, value: int, check_below: bool) -> void:
	if _sent.has(chal_id) or not sharing():
		return
	var chal = ChallengeService.get_chal(chal_id)
	if chal == null:
		return
	if (not check_below and value >= chal.value) or (check_below and value <= chal.value):
		host_completed(chal_id)


func host_completed(chal_id: int) -> void:
	if _sent.has(chal_id) or not sharing() or _excluded_ids().has(chal_id):
		return
	_sent[chal_id] = true
	_challenges.append(chal_id)


func host_stat(key: String) -> void:
	if not key in STATS or not sharing():
		return
	_stats[key] = _stats.get(key, 0) + 1
	if key == WON:
		flush()  # with the counters up to it; the challenges of the win follow


func flush() -> void:
	if _challenges.empty() and _stats.empty():
		return
	var now := []
	while not _challenges.empty() and now.size() < MAX_CHALLENGES:
		now.append(_challenges.pop_front())
	last_sent = {"challenges": now, "stats": _stats, "won": _stats.has(WON)}
	_stats = {}
	if session != null and session.is_host():
		session.broadcast_reliable(Protocol.Msg.PROGRESS, last_sent)


func _excluded_ids() -> Dictionary:
	if _excluded.empty():
		for chal in ChallengeService.challenges:
			if chal.name in LIFETIME_NAMES.values():
				_excluded[chal.my_id_hash] = true
		for id in LIFETIME_IDS.values() + HOST_ONLY:
			_excluded[Keys.generate_hash(id)] = true
	return _excluded


# A peer that joins later earns what comes from then on.
func _on_peer_changed(_steam_id: int) -> void:
	_since = 0.0


func _on_lobby_left() -> void:
	_sent = {}
	_challenges = []
	_stats = {}
	if _dirty:
		_save()


# --- client ---


func _on_message(steam_id: int, msg_type: int, body) -> void:
	if msg_type != Protocol.Msg.PROGRESS or not session.is_client():
		return
	if steam_id == session.transport.host_id:
		client_apply(body)


# Returns how many challenges it completed.
func client_apply(body) -> int:
	if typeof(body) != TYPE_DICTIONARY:
		return 0
	var before: int = ProgressData.challenges_completed.size()
	Puppet.set_own_progress(true)
	var counted := _add_stats(body.get("stats"))
	var ids = body.get("challenges")
	if typeof(ids) == TYPE_ARRAY:
		for id in ids.slice(0, MAX_CHALLENGES - 1):
			if typeof(id) == TYPE_INT and ChallengeService.get_chal(id) != null:
				ChallengeService.complete_challenge(id)
	for key in counted:
		_check_lifetime(key)
	# The game's own end of a won run, on the run this client mirrors.
	if body.get("won") == true and Puppet.is_active() and RunData.get_player_count() > 0:
		RunData.apply_run_won()
	Puppet.set_own_progress(false)
	var completed: int = ProgressData.challenges_completed.size() - before
	if completed > 0 or body.get("won") == true:
		_save()
	elif not counted.empty():
		_dirty = true
	if completed > 0:
		ModLoaderLog.info("%d challenge(s) completed in the host's run" % completed, LOG_NAME)
	return completed


# Adds the host's counts to this client's own counters; returns the counters that moved.
func _add_stats(stats) -> Array:
	var counted := []
	if typeof(stats) != TYPE_DICTIONARY:
		return counted
	var own: Dictionary = Puppet.own_data()
	for key in stats:
		var count = stats[key]
		if not key in STATS or typeof(count) != TYPE_INT or count <= 0:
			continue
		if typeof(own.get(key)) in [TYPE_INT, TYPE_REAL]:
			own[key] += int(min(count, MAX_COUNT))
			counted.append(key)
	return counted


# The challenges that hang on this counter, against this client's own count.
func _check_lifetime(key: String) -> void:
	var count: int = int(Puppet.own_data().get(key, 0))
	if LIFETIME_IDS.has(key):
		var chal_id: int = Keys.generate_hash(LIFETIME_IDS[key])
		var chal = ChallengeService.get_chal(chal_id)
		if chal != null and count >= chal.value and not ChallengeService.is_challenge_completed(chal_id):
			ChallengeService.complete_challenge(chal_id)
	if not LIFETIME_NAMES.has(key):
		return
	for chal in ChallengeService.challenges:
		if chal.name == LIFETIME_NAMES[key] and count >= chal.value:
			if not ChallengeService.is_challenge_completed(chal.my_id_hash):
				ChallengeService.complete_challenge(chal.my_id_hash)


func _save() -> void:
	_dirty = false
	_unsaved = 0.0
	ProgressData.bt_save_own()
