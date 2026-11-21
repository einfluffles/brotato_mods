extends Reference
# Client: the run a BATTLE_START starts the battle from, sent in parts (sync/run_parts.gd).
# take() must see every body in the order the host sent them, also a start that is only adopted
# or queued; state() runs when the start does.

const RunStateCodec := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/run_state_codec.gd"
)


static func take(store, body) -> bool:
	return typeof(body) == TYPE_DICTIONARY and store.take(body.get("run"), "battle start")


# {} when a part is missing (the host is asked for a resync) or the run is unreadable.
static func state(store, body: Dictionary) -> Dictionary:
	var ids = store.ids_for(body.get("run"))
	if not store.has_all(ids):
		if store.session != null:
			store.session.ask_resync()
		return {}
	return store.timed_state(ids)


static func apply(state: Dictionary) -> void:
	RunStateCodec.apply(state)
