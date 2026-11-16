extends Reference
# What the host's run earns for a client's own save (session/progress_share.gd, the
# ChallengeService / ProgressData extensions, session/puppet.gd): the host sends reached
# challenges once, its lifetime counters as counts and the win; a client that mirrors the run
# and uses the host's DLC completes them on its own lists and counters, and nothing else gets
# through. The last suite of its process: it leaves challenges completed.

const Puppet := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/puppet.gd")
const ProgressShare := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/session/progress_share.gd"
)

var _t: Node
var _popups := 0


func _init(test_mod: Node) -> void:
	_t = test_mod


func run(together: Node) -> void:
	var share: Node = together.progress_share
	var saving: bool = DebugService.disable_saving
	DebugService.disable_saving = true  # the container's save file stays as it is
	_test_host(share)
	_test_client(share)
	_test_won(share)
	DebugService.disable_saving = saving


# --- host ---


func _test_host(share: Node) -> void:
	share.test_sharing = true
	share._on_lobby_left()
	share.last_sent = {}
	var hoarder: int = ChallengeService.chal_hoarder_hash
	var goal: int = ChallengeService.get_chal(hoarder).value
	ChallengeService.try_complete_challenge(hoarder, goal - 1)
	share.flush()
	_t._check(share.last_sent.empty(), "a value short of a challenge sends nothing")
	ChallengeService.try_complete_challenge(hoarder, goal)
	_t._check(ChallengeService.is_challenge_completed(hoarder), "the host completes it as ever")
	ChallengeService.try_complete_challenge(hoarder, goal + 5)  # completed: the game returns early
	share.flush()
	_t._check(share.last_sent.get("challenges") == [hoarder], "a reached challenge is sent, once")
	share.last_sent = {}
	share._sent = {}  # another session: the host has it long since
	ChallengeService.try_complete_challenge(hoarder, goal)
	share.flush()
	_t._check(
		share.last_sent.get("challenges") == [hoarder],
		"also one the host completed before: its clients may not have"
	)
	share.last_sent = {}
	var survivor = null
	for chal in ChallengeService.challenges:
		if chal.name == "CHAL_SURVIVOR" and survivor == null:
			survivor = chal
	ChallengeService.complete_challenge(survivor.my_id_hash)
	ChallengeService.complete_challenge(Keys.generate_hash("chal_hourglass"))
	share.flush()
	_t._check(share.last_sent.empty(), "what hangs on the host's own history is not sent")
	for _i in 3:
		ProgressData.increment_stat("enemies_killed")
	ProgressData.increment_stat("run_started")
	share.flush()
	_t._check(
		share.last_sent.get("stats", {}).get("enemies_killed") == 3
		and share.last_sent.stats.size() == 1 and not share.last_sent.won,
		"lifetime counters go out as counts, the listed ones only %s" % [share.last_sent]
	)
	ProgressData.increment_stat("run_won")
	_t._check(share.last_sent.get("won") == true, "a won run goes out at once")
	share.test_sharing = false
	ProgressData.increment_stat("enemies_killed")
	share.last_sent = {}
	share.flush()
	_t._check(share.last_sent.empty(), "without a client nothing is collected")


# --- client ---


# A challenge with a character as its reward that this profile has not completed.
func _open_character_challenge():
	for chal in ChallengeService.challenges:
		if chal.reward_type == RewardType.CHARACTER and chal.reward != null:
			if not ChallengeService.is_challenge_completed(chal.my_id_hash):
				return chal
	return null


func _test_client(share: Node) -> void:
	var chal = _open_character_challenge()
	_t._check(chal != null, "the test profile has an open challenge with a character as reward")
	if chal == null:
		return
	var reward: int = Keys.generate_hash(chal.reward.my_id)
	ProgressData.characters_unlocked.erase(reward)
	Puppet.set_active(true)
	# As session/dlc_borrow.gd puts this client's own lists aside while it uses the host's DLC.
	var own_characters: Array = ProgressData.characters_unlocked.duplicate()
	Engine.set_meta(Puppet.DLC_BORROW_META_KEY, {"ids": [], "progress": {
		"characters_unlocked": own_characters,
	}})
	var live_data: Dictionary = ProgressData.data
	var own_kills: int = Puppet.own_data().enemies_killed
	var live_kills: int = live_data.enemies_killed
	ChallengeService.connect("challenge_completed", self, "_on_challenge_completed")

	ChallengeService.complete_challenge(chal.my_id_hash)
	_t._check(
		not ChallengeService.is_challenge_completed(chal.my_id_hash),
		"mirroring, the client's own copy of the game completes nothing"
	)
	var done: int = share.client_apply({"challenges": [chal.my_id_hash, 123456], "stats": {
		"enemies_killed": 5, "is_unlock_all_save": 1, "materials_collected": "9",
	}})
	_t._check(
		done == 1 and ChallengeService.is_challenge_completed(chal.my_id_hash) and _popups == 1,
		"a challenge the host's run reached is completed here, with the game's own popup"
	)
	_t._check(
		own_characters.has(reward),
		"its reward is on the client's own list, also while it only has the content from the host"
	)
	_t._check(
		Puppet.own_data().enemies_killed == own_kills + 5 and live_data.enemies_killed == live_kills,
		"the counts go onto the client's own counters, not the mirrored run's"
	)
	_t._check(
		not Puppet.own_data().has("is_unlock_all_save") or Puppet.own_data().is_unlock_all_save != 1,
		"a counter that is not on the list is not the host's to write"
	)
	_t._check(not Puppet.own_progress(), "and the way in is closed again")

	# A lifetime challenge, by the client's own count.
	var survivor = null
	for other in ChallengeService.challenges:
		var open: bool = not ChallengeService.is_challenge_completed(other.my_id_hash)
		if other.name == "CHAL_SURVIVOR" and open and survivor == null:
			survivor = other
	if survivor != null:
		Puppet.own_data().enemies_killed = survivor.value - 2
		share.client_apply({"stats": {"enemies_killed": 1}})
		_t._check(
			not ChallengeService.is_challenge_completed(survivor.my_id_hash),
			"a lifetime challenge waits for the client's own count"
		)
		share.client_apply({"stats": {"enemies_killed": 1}})
		_t._check(
			ChallengeService.is_challenge_completed(survivor.my_id_hash),
			"and is completed when that count is there"
		)
	_t._check(share.client_apply("challenges") == 0 and share.client_apply({}) == 0, "junk is ignored")

	# The save is written with what was put aside, and the mirrored state is back after it.
	var run_state = ProgressData.saved_run_state
	own_characters.append(-7)  # only on the client's own list
	var saved: Dictionary = ProgressData.bt_own_save_object()
	_t._check(
		saved.characters_unlocked.has(reward) and saved.characters_unlocked.has(-7)
		and saved.challenges_completed.has(chal.my_id_hash)
		and saved.data.enemies_killed == Puppet.own_data().enemies_killed,
		"the client's save holds its own lists and counters with what it earned"
	)
	ProgressData.bt_save_own()
	own_characters.erase(-7)
	_t._check(
		ProgressData.data == live_data and ProgressData.saved_run_state == run_state
		and not ProgressData.characters_unlocked.has(-7),
		"and saving leaves the mirrored state in place"
	)
	ChallengeService.disconnect("challenge_completed", self, "_on_challenge_completed")
	Engine.remove_meta(Puppet.DLC_BORROW_META_KEY)
	Puppet.set_active(false)
	_t._check(
		ProgressData.data.enemies_killed >= own_kills + 5,
		"back in its own game, the client has what it earned"
	)


func _on_challenge_completed(_challenge) -> void:
	_popups += 1


# The win: the game's own apply_run_won on the mirrored run.
func _test_won(share: Node) -> void:
	_t.coop_run(3)
	RunData.current_difficulty = 1
	Puppet.set_active(true)
	var character = RunData.get_player_character(0)
	var chal_name: String = "chal_" + character.name.to_lower().replace("character_", "")
	var chal_id: int = Keys.generate_hash(chal_name)
	var zone: int = RunData.current_zone
	var info = ProgressData.get_character_difficulty_info(character.my_id_hash, zone)
	var before: int = info.max_selectable_difficulty
	var wins: int = Puppet.own_data().run_won
	share.client_apply({"stats": {"run_won": 1}, "won": true})
	_t._check(
		ChallengeService.get_chal(chal_id) == null or ChallengeService.is_challenge_completed(chal_id),
		"a won run completes the characters' challenges for the client"
	)
	_t._check(
		info.max_selectable_difficulty >= 2 and info.max_selectable_difficulty >= before,
		"and opens the next danger level (%d -> %d)" % [before, info.max_selectable_difficulty]
	)
	_t._check(Puppet.own_data().run_won == wins + 1, "the win is counted on its own counters")
	Puppet.set_active(false)
