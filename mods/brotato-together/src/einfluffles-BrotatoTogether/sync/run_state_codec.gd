extends Reference
# Run state <-> bytes through the game's own save-file path: serialize_run_state -> JSON text ->
# zstd ... -> JSON.parse -> deserialize_run_state. The JSON step is required: the game's
# deserializers expect JSON-shaped data (string keys, float numbers).

const ClientReport := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/sync/client_report.gd"
)
const EffectArgs := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/effect_args.gd")
const MAX_UNCOMPRESSED_SIZE := 8 * 1024 * 1024


# Returns {"size": int, "data": PoolByteArray}: plain data, safe for var2bytes. shop_args: the
# shop's own save_run_state arguments to include the shop (ShopSync.shop_args), or [] for none.
static func encode(shop_args := []) -> Dictionary:
	return pack(encode_json(shop_args))


static func encode_json(shop_args := []) -> String:
	return JSON.print(serialize(shop_args))


# The run state as the save file has it before JSON.print. Every effect in it carries its custom
# args, whether its text was shown or not (sync/effect_args.gd).
static func serialize(shop_args := []) -> Dictionary:
	var state: Dictionary = ProgressData.callv("get_run_state", shop_args)
	EffectArgs.settle(state, true)
	return ProgressDataLoaderV3.new().serialize_run_state(state)


static func pack(json: String) -> Dictionary:
	var text := json.to_utf8()
	return {"size": text.size(), "data": text.compress(File.COMPRESSION_ZSTD)}


# Returns the run state dictionary (game objects resolved), or {} if the payload is invalid.
static func decode(payload) -> Dictionary:
	return deserialize(parse(payload))


# The run state as it was sent (JSON-shaped: string keys, serialized items), or {} if the
# payload is invalid.
static func parse(payload) -> Dictionary:
	var started := OS.get_ticks_usec()
	if (
		typeof(payload) != TYPE_DICTIONARY
		or typeof(payload.get("size")) != TYPE_INT
		or typeof(payload.get("data")) != TYPE_RAW_ARRAY
		or payload.size <= 0
		or payload.size > MAX_UNCOMPRESSED_SIZE
	):
		return {}
	var raw: PoolByteArray = payload.data.decompress(payload.size, File.COMPRESSION_ZSTD)
	var text := raw.get_string_from_utf8()
	var parsed := JSON.parse(text)
	ClientReport.mark(ClientReport.Mark.PARSE, OS.get_ticks_usec() - started)
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return {}
	return parsed.result


static func deserialize(raw: Dictionary) -> Dictionary:
	if raw.empty():
		return {}
	var started := OS.get_ticks_usec()
	var state: Dictionary = ProgressDataLoaderV3.new().deserialize_run_state(raw)
	EffectArgs.settle(state, false)  # its custom args came with it
	ClientReport.mark(ClientReport.Mark.DESERIALIZE, OS.get_ticks_usec() - started)
	return state


# The game refreshes its item-count caches only when an item is added or removed, and
# resume_from_state reads them (LinkedStats): without the reset, item-counting stats go stale.
static func apply(state: Dictionary) -> void:
	var started := OS.get_ticks_usec()
	RunData.reset_run_caches()
	RunData.resume_from_state(state)
	ClientReport.mark(ClientReport.Mark.APPLY, OS.get_ticks_usec() - started)
