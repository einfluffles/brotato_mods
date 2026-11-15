extends Reference
# The shop on the state stream (sections RUN_SHOP and PAUSE_SHOP). Host: ShopSync and
# PauseControl as the providers of a stream of its own on a fake session (stepped by hand): the
# shop goes out only when it changed (compressed once per change), again to a peer that becomes
# ready, in the frame after an applied intent and as null once the host left the shop; the
# pause goes out when it changes. Client: what that stream sent goes to the mod's own stream,
# whose handler is ShopSync. Used by the shop loopback suite (its host shop, then its client).

const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const StateStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/state_stream_tests.gd"
)
const PauseControl := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/pause_control.gd"
)
const PEER := 4343
const REMOTE := 1  # the player whose Go the intent check sets

var t: Node  # the test mod: _check, scene tree
var together: Node
var host: Node = null  # the host's stream
var paused_message := []  # PAUSE_SHOP as the host sent it while paused
var unpaused_message := []


func _init(test_mod: Node, mod: Node) -> void:
	t = test_mod
	together = mod


# A body as the client's stream gets it, at the revision it has (equal ones apply again).
static func deliver(stream: Node, section: int, body) -> void:
	var revision: int = stream._revs.get(section, 0)
	stream.receive(bytes2var(var2bytes([section, revision, body]), false))


# Host part, with the host's shop as the current scene and ShopSync._host_shop.
func run_host(shop: Node):
	var shop_sync: Node = together.shop_sync
	var session := StateStreamTests.FakeSession.new()
	session.transport = StateStreamTests.FakeTransport.new()
	session.peers[PEER] = {"ready": true}
	host = StateStream.new()
	host.setup(session)
	host.register_provider(StateStream.RUN_SHOP, shop_sync, shop_sync.CHECK_INTERVAL)
	host.register_provider(StateStream.PAUSE_SHOP, together.pause_control)
	shop_sync.state_stream = host  # host_apply_intent flushes this one

	var packed: int = shop_sync.run_cache.packs
	host.step(1.0)
	var sent := _take(StateStream.RUN_SHOP)
	var body = sent[0][2] if sent.size() == 1 else null
	t._check(
		sent.size() == 1 and sent[0][0] == PEER and typeof(body) == TYPE_DICTIONARY
		and body.shop_id == shop_sync._shop_id and body.get("you") == -1,
		"shop: the provider's state goes out on the stream, with the peer's own part"
	)
	var pause := _take(StateStream.PAUSE_SHOP)
	t._check(
		pause.size() == 1 and pause[0][2] == [false, "", 0], "shop pause: not paused %s" % [pause]
	)
	host.step(1.0)
	host.step(1.0)
	t._check(
		_take(StateStream.RUN_SHOP).empty() and shop_sync.run_cache.packs == packed + 1,
		"unchanged shop state compressed once, not every check"
	)
	session.emit_signal("peer_ready", PEER)
	host.step(0.0)  # the resync goes out in the stream's next step
	sent = _take(StateStream.RUN_SHOP)
	t._check(
		sent.size() == 1 and sent[0][1] == 1 and shop_sync.run_cache.packs == packed + 1,
		"shop: a peer that becomes ready gets it again, same revision, not compressed again"
	)
	t._check(_take(StateStream.PAUSE_SHOP).size() == 1, "and the shop pause too")
	_test_pause(session)
	yield(_test_flush(shop_sync, shop), "completed")


func _test_pause(session: Node) -> void:
	var tree := t.get_tree()
	tree.paused = true
	host.step(1.0)
	var sent := _take(StateStream.PAUSE_SHOP)
	tree.paused = false
	t._check(sent.size() == 1 and sent[0][2][0] == true, "shop pause: the host's pause goes out")
	paused_message = [StateStream.PAUSE_SHOP, sent[0][1], sent[0][2]] if sent.size() == 1 else []
	host.step(1.0)
	sent = _take(StateStream.PAUSE_SHOP)
	t._check(sent.size() == 1 and sent[0][2][0] == false, "shop pause: and the resume")
	unpaused_message = [StateStream.PAUSE_SHOP, sent[0][1], sent[0][2]] if sent.size() == 1 else []
	session.sent.clear()


# Buy and Steal run deferred in the game: an applied intent goes out in the next frame, and a
# check in its own frame sends nothing.
func _test_flush(shop_sync: Node, shop: Node):
	for wanted in [1, 0]:
		var go := {"shop_id": shop_sync._shop_id, "seq": 0, "kind": "go", "slot": -1, "id": ""}
		go["arg"] = wanted
		t._check(shop_sync.host_apply_intent(shop, REMOTE, go), "Go %d applied" % wanted)
		host.step(1.0)  # an interval check in the frame of the intent
		var early := _take(StateStream.RUN_SHOP)
		yield(t.get_tree(), "idle_frame")
		host.step(0.0)  # no interval left: only the flush checks
		var sent := _take(StateStream.RUN_SHOP)
		t._check(
			early.empty() and sent.size() == 1 and sent[0][2].go[REMOTE] == (wanted == 1),
			"applied intent (Go %d) goes out in the next frame, not before" % wanted
		)


# [section, revision, body] the host sends the peer for the shop now.
func send_shop() -> Array:
	host.step(1.0)
	var sent := _take(StateStream.RUN_SHOP)
	if sent.empty():
		return host.message_for(StateStream.RUN_SHOP, PEER)
	return [StateStream.RUN_SHOP, sent[-1][1], sent[-1][2]]


# The host leaves the shop: the shop and its pause are cleared once, then the stream is gone.
func end_host() -> void:
	var shop_sync: Node = together.shop_sync
	var shop: Node = shop_sync._host_shop
	shop_sync._host_shop = null
	host.step(1.0)
	var cleared := _take(StateStream.RUN_SHOP)
	host.step(1.0)
	t._check(
		cleared.size() == 1 and cleared[0][2] == null and _take(StateStream.RUN_SHOP).empty(),
		"the host left the shop: null once"
	)
	shop_sync._host_shop = shop
	shop_sync.state_stream = together.state_stream
	var session: Node = host.session
	host.free()
	session.free()
	host = null


# Client part, in the client's shop: the host's pause from the stream turns the own panel off
# and shows the banner; the resume undoes both.
func run_client(shop: Node) -> void:
	var stream: Node = together.state_stream
	var local = together.shop_sync.local
	stream._revs.erase(StateStream.PAUSE_SHOP)  # the revisions of the host stream above
	stream.receive(bytes2var(var2bytes(paused_message), false))
	var banner = shop.get_node_or_null(PauseControl.BANNER_NAME)
	t._check(
		local._paused and banner != null and banner.visible
		and banner.get_node("Label").text == "Paused by the host",
		"client: the host's pause from the stream shows the banner, own panel off"
	)
	stream.receive(bytes2var(var2bytes(unpaused_message), false))
	t._check(not local._paused and not banner.visible, "client: resumed")


# What the host sent since the last call for this section, as [steam_id, revision, body].
func _take(section: int) -> Array:
	var messages := []
	var rest := []
	for sent in host.session.sent:
		var message: Array = sent[2]
		if message[0] == section:
			messages.append([sent[0], message[1], message[2]])
		else:
			rest.append(sent)
	host.session.sent = rest
	return messages
