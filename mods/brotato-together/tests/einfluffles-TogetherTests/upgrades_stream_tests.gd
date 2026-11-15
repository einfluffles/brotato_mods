extends Reference
# The level-up / crate panels on the state stream (section UPGRADES): UpgradesSync as the
# provider of a host stream and as the handler of a client stream, both on fake sessions
# (state_stream_tests.gd), with what goes over the wire in between. Part of the battle
# loopback: host_part while the host's panels show, client_part on the puppet.
#  - host: first check sends the panels, unchanged panels send nothing and encode no run, a
#    change goes out, peer_ready re-delivers the same revision, closed panels send null once
#  - client: the host's messages applied, a resync applied again without a rebuild, null
#    ends the panels' state

const StateStream := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd"
)
const StateStreamTests := preload(
	"res://mods-unpacked/einfluffles-TogetherTests/state_stream_tests.gd"
)
const HOST := 2
const P1 := 11
const P2 := 12
# UpgradesSync.CHECK_INTERVAL. Not preloaded: the test mod compiles its preloads before the
# mod's script extensions are installed, and upgrades_sync.gd's game classes then break them.
const CHECK_INTERVAL := 0.1

var _sent := []  # [section, revision, body] the host stream sent P1, then the resync to P2


# Counts the bodies the stream asks for: each one encodes the run.
class CountingProvider:
	extends Reference
	var target: Object = null
	var keys := 0
	var builds := 0

	func _init(provider: Object) -> void:
		target = provider

	func state_key(section: int) -> String:
		keys += 1
		return target.call("state_key", section)

	func state_body(section: int):
		builds += 1
		return target.call("state_body", section)


func _stream(host: bool, ready_peers: Array) -> Node:
	var session = StateStreamTests.FakeSession.new()
	session.transport = StateStreamTests.FakeTransport.new()
	session.transport.host_id = HOST
	session.host = host
	for peer in ready_peers:
		session.peers[peer] = {"ready": true}
	var stream: Node = StateStream.new()
	stream.setup(session)
	return stream


func _free(stream: Node) -> void:
	stream.session.free()
	stream.free()


# What the host sent since the last call, as [steam_id, [section, revision, body]].
static func _take(stream: Node) -> Array:
	var messages := []
	for sent in stream.session.sent:
		messages.append([sent[0], sent[2]])
	stream.session.sent.clear()
	return messages


# ui: the host's UpgradesUI, showing a level-up for player 0 and a crate for player 1. Leaves
# it as it was (shown, pages 0).
func host_part(t: Node, together: Node, ui: Node) -> void:
	var panels: Node = together.upgrades_sync
	var host := _stream(true, [P1])
	var provider := CountingProvider.new(panels)
	host.register_provider(StateStream.UPGRADES, provider, CHECK_INTERVAL)
	host.step(0.0)
	var sent := _take(host)
	var first: Array = sent[0][1] if sent.size() == 1 else [-1, -1, null]
	var body = first[2]
	t._check(
		sent.size() == 1 and sent[0][0] == P1 and first[0] == StateStream.UPGRADES and first[1] == 1,
		"host: the panels go out on the stream's first check (%s)" % [sent.size()]
	)
	t._check(
		typeof(body) == TYPE_DICTIONARY
		and body.get("battle_id") == together.battle_host._battle_id
		and body.get("players") == panels.capture(ui)
		and typeof(body.get("run")) == TYPE_DICTIONARY,
		"host: the body is the panels and the run"
	)
	for _i in 3:
		host.step(CHECK_INTERVAL)
	t._check(
		_take(host).empty() and provider.keys == 4 and provider.builds == 1,
		"host: unchanged panels checked every interval, the run encoded once (%d keys, %d bodies)"
		% [provider.keys, provider.builds]
	)
	_sent = [first]

	var other = ui._get_player_container(1)
	other.carousel.index = 1
	host.step(CHECK_INTERVAL)
	sent = _take(host)
	t._check(
		sent.size() == 1 and sent[0][1][1] == 2 and sent[0][1][2].pages == [0, 1],
		"host: a page flip goes out as a new revision"
	)
	if sent.size() == 1:
		_sent.append(sent[0][1])

	host.session.peers[P2] = {"ready": true}
	host.session.emit_signal("peer_ready", P2)
	sent = _take(host)
	t._check(
		sent.size() == 1 and sent[0][0] == P2 and sent[0][1][1] == 2 and provider.builds == 3,
		"host: peer_ready re-delivers the panels to that peer, same revision"
	)
	if sent.size() == 1:
		_sent.append(sent[0][1])
	other.carousel.index = 0

	ui.hide()
	host.step(CHECK_INTERVAL)
	sent = _take(host)
	t._check(
		sent.size() == 2 and sent[0][1][2] == null and sent[1][1][2] == null,
		"host: closed panels send null once to every ready peer"
	)
	if not sent.empty():
		_sent.append(sent[0][1])
	var builds := provider.builds
	host.step(CHECK_INTERVAL)
	t._check(_take(host).empty() and provider.builds == builds, "host: closed, nothing more")
	ui.show()
	_free(host)


# main: the puppet battle scene, this client a spectator (client._you -1). Plays the host's
# messages from host_part into a client stream, as they came off the wire.
func client_part(t: Node, together: Node, main: Node) -> void:
	var panels: Node = together.upgrades_sync
	var ui = main.get("_coop_upgrades_ui")
	var other = ui._get_player_container(1)
	if _sent.size() != 4:
		t._check(false, "client: the host's upgrades messages (%d)" % _sent.size())
		return
	var client := _stream(false, [])
	client.register_handler(StateStream.UPGRADES, panels)
	client.receive(_sent[0])
	t._check(
		not client.is_pending(StateStream.UPGRADES)
		and panels.capture(ui)[0] == _sent[0][2].players[0]
		and other._item_data != null
		and other._item_data.my_id == _sent[0][2].players[1][2],
		"client: the host's panels through the stream"
	)
	client.receive(_sent[1])
	t._check(other.carousel.index == 1, "client: the next revision moves another player's page")
	ui._get_player_container(0)._level = 99  # marker: an unchanged panel is not rebuilt
	client.receive(_sent[2])  # the resync, same revision
	t._check(
		not client.is_pending(StateStream.UPGRADES)
		and ui._get_player_container(0)._level == 99
		and other.carousel.index == 1,
		"client: a resync applies again without a rebuild"
	)
	client.receive(_sent[3])
	t._check(
		panels._applied.empty() and not panels._local_active and panels._own_seq == -1,
		"client: null clears the panels' state"
	)
	other.carousel.index = 0
	_free(client)
