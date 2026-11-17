extends Reference
# This mod's settings on this machine, in the Mod Loader's own config store
# (ModLoaderConfig: user://mod_configs/<mod id>/, checked against the config_schema of
# manifest.json, which also gives the defaults). The loader's "default" config cannot be
# written, so the values live in a config of their own, made with the first change.

const MOD_ID := "einfluffles-BrotatoTogether"
const CONFIG := "settings"
const DEFAULTS := "default"


static func read(key: String, fallback):
	var configs := _configs()
	for name in [CONFIG, DEFAULTS]:
		if configs.has(name) and configs[name].data.has(key):
			return configs[name].data[key]
	return fallback


static func write(key: String, value) -> bool:
	var configs := _configs()
	if configs.has(CONFIG):
		configs[CONFIG].data[key] = value
		return ModLoaderConfig.update_config(configs[CONFIG]) != null
	if not configs.has(DEFAULTS):
		return false  # no schema loaded: nothing to check a config against
	var data: Dictionary = configs[DEFAULTS].data.duplicate(true)
	data[key] = value
	return ModLoaderConfig.create_config(MOD_ID, CONFIG, data) != null


static func _configs() -> Dictionary:
	if not ModLoaderStore.mod_data.has(MOD_ID):
		return {}
	return ModLoaderStore.mod_data[MOD_ID].configs
