extends Reference
# SHOP_TEXT (sync/shop_sync.gd): the icon and number the shop floats over a player's reroll button
# when a reroll gave a stat (bone dice). Part of the local shop suite (local_shop_tests.gd, s
# below: its shop, helpers and checks), in its own file for the file length limit.

const REMOTE := 1  # the remote player's slot on the host


# Host, before the remote player's reroll: bone dice that always gives 2 max HP. Returns the
# effect list it was added to.
func host_before() -> Array:
	var dice: Array = RunData.get_player_effect(Keys.gain_stats_on_reroll_hash, REMOTE)
	dice.append([Keys.stat_max_hp_hash, 2, 100])
	RunData.add_stat(Keys.stat_max_hp_hash, 1, REMOTE)  # no reroll: the shop shows nothing
	return dice


# One frame after the reroll was applied.
func host_after(s, dice: Array) -> void:
	dice.pop_back()
	var text: Dictionary = s._sync.last_text
	s._t._check(
		(
			text.get("player") == REMOTE
			and text.get("stat") == Keys.stat_max_hp_hash
			and text.get("value") == 2
			and text.get("shop_id") == s._sync._shop_id
		),
		"a reroll that gives a stat sends its text, a gain without a reroll none %s" % [text]
	)


# Client: shown with the game's own floating text over that player's reroll button.
func client(s, shop: Node) -> void:
	var sync: Node = s._sync
	var texts: Node = shop._floating_texts
	var before := texts.get_child_count()
	var text := {
		"shop_id": sync._client_shop_id, "player": REMOTE, "stat": Keys.stat_max_hp_hash, "value": 2
	}
	s._t._check(sync.client_show_text(text), "the client shows the host's reroll text")
	var count := texts.get_child_count()
	var shown = texts.get_child(count - 1) if count > before else null
	var button: Control = shop._get_reroll_button(REMOTE)
	s._t._check(
		shown != null and abs(shown.rect_global_position.x - button.rect_global_position.x) < 400,
		"over that player's reroll button"
	)
	for bad in [{"shop_id": sync._client_shop_id + 1}, {"player": 7}, {"stat": 12345}, {"value": "2"}]:
		var broken := text.duplicate()
		for key in bad:
			broken[key] = bad[key]
		s._t._check(not sync.client_show_text(broken), "malformed shop text ignored %s" % [bad])
	s._t._check(texts.get_child_count() == count, "and nothing shown for them")
