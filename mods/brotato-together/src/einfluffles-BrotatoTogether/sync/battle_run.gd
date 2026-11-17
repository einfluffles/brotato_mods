extends Reference
# Client: the run a BATTLE_START starts the battle from (BattleClient). It travels in parts,
# only those this client lacks (sync/run_parts.gd, protocol 25; BattleHost._send_battle_start):
# after a shop state the common part "c", not the players' gear and stats, which the client's
# store (RunParts.Store, shared with ShopSync and UpgradesSync) already has.
# - take(store, body) as the message arrives, for every start: also one that is only adopted (a
#   resync of the battle this client is in) or queued (a scene still loading). The store must
#   see every body in the order the host sent them (its last ids are the host's record of this
#   client), and it keeps the parts of a queued start (two versions per key) until it runs.
#   A missing part asks the host for a full resync (RunParts.Store.take): the start is dropped,
#   the resync sends it again with every part.
# - state(store, body) when the start runs: the run state of its ids, parsed and deserialized
#   only where they changed since the store's last state, measured for the client's scene-change
#   report (sync/client_report.gd: run parse, deserialize; apply: RunStateCodec.apply).

const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)
const ClientReport := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/client_report.gd"
)


static func take(store, body) -> bool:
	return typeof(body) == TYPE_DICTIONARY and store.take(body.get("run"), "battle start")


# {} when a part is missing (a body that did not come through take: tests; the host is asked
# for a resync) or the run is unreadable.
static func state(store, body: Dictionary) -> Dictionary:
	var ids = store.ids_for(body.get("run"))
	if not store.has_all(ids):
		if store.session != null:
			store.session.ask_resync()
		return {}
	var started := OS.get_ticks_usec()
	store.raws(ids)  # decompresses and parses the parts not parsed yet
	ClientReport.mark(ClientReport.Mark.PARSE, OS.get_ticks_usec() - started)
	started = OS.get_ticks_usec()
	var state: Dictionary = store.state_for(ids)
	ClientReport.mark(ClientReport.Mark.DESERIALIZE, OS.get_ticks_usec() - started)
	return state


static func apply(state: Dictionary) -> void:
	RunStateCodec.apply(state)
