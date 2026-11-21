extends Reference
# Not an extension: the backups the Mod Loader keeps of extended game scripts (mod_main.gd
# OWN_DUPLICATE). mod_main loads it only while the ModLoaderStore autoload exists, which a script
# naming it needs to compile.


# Mod Loader 6.3.0 internals: saved_scripts[path][0] is the game's script, put back if a mod is
# disabled while the game runs, and the loader only makes it when path has no entry. Another shape
# of the store is left to the loader.
static func store(path: String) -> void:
	var saved = ModLoaderStore.get("saved_scripts")
	if not saved is Dictionary or saved.has(path):
		return
	var copy = ResourceLoader.load(path, "", true)  # not the cached script the loader extends
	if copy is Script:
		saved[path] = [copy]
