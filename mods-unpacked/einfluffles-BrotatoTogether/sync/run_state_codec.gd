extends Reference
# Run state <-> bytes, reusing the game's own save-file path exactly:
# serialize_run_state -> JSON text -> (zstd) ... -> JSON.parse -> deserialize_run_state.
# The game's deserializers expect JSON-shaped data (string keys, float numbers), so the JSON step
# is required, not cosmetic. Host: encode() and send reliably. Client: apply() before loading the
# battle scene.

const MAX_UNCOMPRESSED_SIZE := 8 * 1024 * 1024


# Returns {"size": int, "data": PoolByteArray} — plain data, safe for var2bytes.
static func encode() -> Dictionary:
	var state: Dictionary = ProgressData.get_run_state()
	var serialized: Dictionary = ProgressDataLoaderV3.new().serialize_run_state(state)
	var text := JSON.print(serialized).to_utf8()
	return {"size": text.size(), "data": text.compress(File.COMPRESSION_ZSTD)}


# Returns the run state dictionary (game objects resolved), or {} if the payload is invalid.
static func decode(payload) -> Dictionary:
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
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return {}
	return ProgressDataLoaderV3.new().deserialize_run_state(parsed.result)


static func apply(state: Dictionary) -> void:
	RunData.resume_from_state(state)
