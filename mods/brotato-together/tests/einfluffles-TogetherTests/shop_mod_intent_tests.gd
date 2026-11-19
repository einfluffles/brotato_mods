extends Reference
# Another mod's decision on a shop panel (ShopSync.register_intent / send_intent): the host runs
# its handler for a remote player's press like for the game's own kinds, and a client only sends
# what the host handles. Part of the local shop suite (local_shop_tests.gd; s: that suite).

const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const KIND := "test.poke"
const FREE := "test.give"  # registered without the panel revision
const REMOTE := 1

var calls := []  # what the handler got: [player, slot, id, arg]
var answer := true


func on_poke(_shop: Node, player: int, slot: int, id: String, arg: int) -> bool:
	calls.append([player, slot, id, arg])
	return answer


# Host, before the states the client part receives are captured (they then name the kind).
func host(s) -> void:
	var shop_sync: Node = s._sync
	s._t._check(not shop_sync.register_intent("buy", self, "on_poke"), "a mod cannot take a game kind")
	s._t._check(not s._apply(KIND, 3, "x", 9), "a kind nobody registered is dropped")
	s._t._check(shop_sync.register_intent(KIND, self, "on_poke"), "a mod registers its own kind")
	s._t._check(
		shop_sync.state_body(StateStream.RUN_SHOP).kinds == [KIND], "the state names the host's kinds"
	)
	var seq: int = s._seq()
	s._t._check(not s._apply(KIND, 3, "x", 9, -1), "its press on an old panel is dropped")
	s._t._check(calls.empty(), "without its handler running")
	var press: Dictionary = s._intent(KIND, 3, "x", 9)
	s._t._check(shop_sync.host_apply_intent(s._shop, REMOTE, press), "its press is applied")
	s._t._check(calls == [[REMOTE, 3, "x", 9]], "by its handler, as the sender's player %s" % [calls])
	s._t._check(s._seq() > seq, "and makes the panel's revision stale")
	s._t._check(not shop_sync.host_apply_intent(s._shop, REMOTE, press), "the same press twice: once")
	answer = false
	s._t._check(not s._apply(KIND, 3, "x", 9), "a press its handler refuses counts as dropped")
	s._t.get_tree().paused = true
	calls = []
	s._t._check(not s._apply(KIND, 3, "x", 9) and calls.empty(), "nothing runs while paused")
	s._t.get_tree().paused = false
	answer = true
	s._t._check(shop_sync.register_intent(FREE, self, "on_poke", false), "a kind without revision")
	calls = []
	var stale: Dictionary = s._intent(FREE, 3, "x", 9, -1)
	s._t._check(shop_sync.host_apply_intent(s._shop, REMOTE, stale), "its press on an old panel runs")
	s._t._check(
		shop_sync.host_apply_intent(s._shop, REMOTE, stale) and calls.size() == 2,
		"and a second one made on that panel too"
	)
	shop_sync._mod_kinds.erase(FREE)


# Client, own player 0, after a state that names the kind.
func client(s, shop: Node) -> void:
	var shop_sync: Node = s._sync
	var local = shop_sync.local
	s._t._check(
		shop_sync.is_puppet_shop(shop) and shop_sync.own_player() == 0,
		"a mod can tell a client's shop and its own player"
	)
	s._t._check(
		shop_sync.host_handles(KIND) and not shop_sync.host_handles("test.other"),
		"and what the host handles"
	)
	local.last_intent = {}
	s._t._check(shop_sync.send_intent(shop, 0, KIND, 2, "y", 5), "a press on the own panel is sent")
	var sent: Dictionary = local.last_intent
	var named: bool = sent.get("slot") == 2 and sent.get("id") == "y" and sent.get("arg") == 5
	s._t._check(
		sent.get("kind") == KIND and named and sent.get("seq") == local.seq,
		"as that kind, with the panel's revision (%s)" % [sent]
	)
	local.last_intent = {}
	s._t._check(
		not shop_sync.send_intent(shop, REMOTE, KIND, 2, "y", 5), "not for another player's panel"
	)
	s._t._check(
		not shop_sync.send_intent(shop, 0, "test.other", 2, "y", 5), "not a kind the host lacks"
	)
	var plain: Dictionary = s._states.own_gear_changed.duplicate()
	plain.kinds = []
	s._receive(plain)
	s._t._check(
		not shop_sync.send_intent(shop, 0, KIND, 2, "y", 5), "not to a host without the mod"
	)
	s._t._check(local.last_intent.empty(), "nothing left for any of them")
	s._receive(s._states.own_gear_changed)
	shop_sync._mod_kinds.erase(KIND)
