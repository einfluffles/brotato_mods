extends Reference
# Shop locks (sync/shop_sync.gd: the lock per slot in the state; sync/shop_local.gd: the own
# press shown at once). Part of the local shop suite (local_shop_tests.gd, s below: its shop,
# helpers and checks), in its own file for the file length limit.

const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const REMOTE := 1  # the remote player's slot on the host


# The remote player's lock per slot, as the host's state carries it.
func sent(s) -> Array:
	return s._sync.state_body(StateStream.RUN_SHOP).locks[REMOTE]


# Host. With a slot bought, a locked item's place in the offered list is no longer its slot:
# the state names the slot ("locked_after_buy": what a client must show).
func host_after_buy(s, bought: int) -> void:
	var target := -1
	for slot in s._slots(REMOTE).size():
		var node = s._node(REMOTE, slot)
		if slot != bought and node.active and node.item_data.is_lockable:
			target = slot  # the last one: behind the bought slot when there is one
	if target < 0:
		print("  info: no lockable slot left, lock after a buy not tested")
		return
	if target < bought:
		print("  info: no slot behind the bought one, lock after a buy only tested in place")
	var id: String = s._node(REMOTE, target).item_data.my_id
	s._t._check(s._apply("lock", target, id, 1), "lock applied after a buy")
	s._t._check(
		sent(s)[target] and sent(s).count(true) == 1,
		"the state names the locked slot after a buy %s" % [sent(s)]
	)
	s._capture("locked_after_buy")
	s._t._check(s._apply("lock", target, id, 0), "and unlocked again")


# Client, own panel, right after the lock shortcut on node sent its intent: the lock shows
# without the host's answer, survives an older state, and goes when the host never agrees.
func client_own(s, shop: Node, node: Node, before: String):
	var local = s._sync.local
	var popup = shop._get_item_popup(0)
	s._t._check(
		node.locked and s._run_view(shop) == before,
		"the lock shows at once, the run is the host's"
	)
	s._t._check(
		popup._coop_unlock_hint.visible and not popup._coop_lock_hint.visible,
		"and its hint offers to unlock"
	)
	s._receive(s._states.start)  # sent before the host heard of the press
	s._t._check(node.locked, "an older state does not take the pressed lock back")
	yield(s._tap("ui_select"), "completed")
	var intent: Dictionary = local.last_intent
	s._t._check(
		intent.get("kind") == "lock" and intent.get("arg") == 0 and not node.locked,
		"a second press unlocks (%s)" % [intent]
	)
	s._receive(s._states.start)
	s._t._check(
		not node.locked and local._locks.empty(), "the host's state agrees: nothing pending"
	)
	yield(s._tap("ui_select"), "completed")
	local._locks[node.get_instance_id()][1] -= local.LOCK_WAIT_MSEC + 1
	local.process()
	s._t._check(
		not node.locked and popup._coop_lock_hint.visible,
		"a lock the host never confirmed is taken back"
	)


# Client: the other player's lock shows on the slot the host locked, also with a slot bought
# before it.
func client_other(s) -> void:
	if not s._states.has("locked_after_buy"):
		return
	var body: Dictionary = s._states.locked_after_buy
	s._receive(body)
	var shown := _shown(s)
	s._t._check(
		shown == body.locks[REMOTE] and shown.count(true) == 1,
		"a lock shows on the host's slot after a buy (%s, host %s)" % [shown, body.locks[REMOTE]]
	)
	s._receive(s._states.start)
	s._t._check(not (true in _shown(s)), "and is gone with the host's")


func _shown(s) -> Array:
	var shown := []
	for node in s._shop._get_shop_items_container(REMOTE)._shop_items:
		shown.append(node.active and node.locked)
	return shown
