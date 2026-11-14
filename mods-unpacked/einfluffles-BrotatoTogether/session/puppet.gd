extends Reference
# Global "this client is mirroring the host's run" flag, readable from script extensions.
# While set, the client's own save file, challenges and achievements must not be touched.

const META_KEY := "brotato_together_puppet"


static func is_active() -> bool:
	return Engine.has_meta(META_KEY) and Engine.get_meta(META_KEY)


static func set_active(active: bool) -> void:
	Engine.set_meta(META_KEY, active)
