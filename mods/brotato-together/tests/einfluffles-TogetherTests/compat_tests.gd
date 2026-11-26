extends Reference
# Join compatibility (session/compat.gd): what the host compares on HELLO and the rejection's codes.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const Compat := preload("res://mods-unpacked/einfluffles-BrotatoTogether/session/compat.gd")

var t: Node = null


func run(test_mod: Node) -> void:
	t = test_mod
	var host := Compat.local_info("host")
	host.dlcs = ["abyssal_terrors"]
	var client := host.duplicate()
	t._check(Compat.incompatibility(host, client) == "", "same versions and DLCs join")
	client.dlcs = ["abyssal_terrors", "primal_dread"]
	t._check(Compat.incompatibility(host, client) == "", "extra client DLC is fine")
	client.dlcs = []
	t._check(Compat.incompatibility(host, client) == "", "client without the host's DLC joins")
	t._check(Compat.missing_dlcs(host.dlcs, client.dlcs) == host.dlcs, "its missing DLC listed")
	client.dlcs = "abyssal_terrors"
	t._check("DLC" in Compat.incompatibility(host, client), "malformed DLC list rejected")
	client = host.duplicate()
	client.dlcs = []
	client.game_version = "0.0.0"
	t._check(
		"game version" in Compat.incompatibility(host, client),
		"other game version rejected, DLC or not"
	)
	client = host.duplicate()
	client.mod_version = "0.0.1"
	t._check("0.0.1" in Compat.incompatibility(host, client), "other mod version rejected")
	client = host.duplicate()
	client.version = Protocol.VERSION - 1
	t._check("protocol" in Compat.incompatibility(host, client), "other protocol rejected")
	t._check(Compat.incompatibility(host, "x") != "", "malformed HELLO rejected")
	var codes := []
	var changes := [
		["version", 0], ["game_version", "0.0.0"], ["mod_version", "0.0.1"], ["mods", {"a-b": "1"}]
	]
	for change in changes:
		client = host.duplicate()
		client[change[0]] = change[1]
		codes.append(Compat.rejection(host, client).code)
	codes.append(Compat.rejection(host, "x").code)
	t._check(codes == ["protocol", "game", "mod", "mods", ""], "rejection codes %s" % [codes])
	var two := ["1", "2"]
	t._check(
		Compat.describe({"code": "game", "args": two, "reason": "r"})
		== Text.text("BT_REJECT_GAME", two)
		and Compat.describe({"code": "game", "args": ["1"], "reason": "r"}) == "r"
		and Compat.describe({"reason": "r"}) == "r",
		"a rejection's text: by its code, else its reason"
	)
	_test_mod_lists(host)


# Every other mod must be the same on both sides, in the same version.
func _test_mod_lists(host: Dictionary) -> void:
	var mods: Dictionary = host.mods
	t._check(
		mods.get("einfluffles-TogetherTests") == "0.1.0" and not Compat.MOD_ID in mods,
		"the other loaded mods with their versions, not brotato:together itself %s" % [mods]
	)
	var own = ModLoaderMod.get_mod_data("einfluffles-TogetherTests")
	for flag in ["is_active", "is_loadable"]:
		own.set(flag, false)
		var listed: bool = Compat.local_mods().has("einfluffles-TogetherTests")
		own.set(flag, true)
		t._check(not listed, "a mod with %s false is not listed" % flag)
	var crowded := host.duplicate()
	crowded.mods = {}
	for i in Compat.MODS_LOGGED + 10:
		crowded.mods["m-Mod%03d" % i] = "1.0.0"
	var logged: String = Compat.rejection(host, crowded).reason
	t._check(
		"+10" in logged and not "m-Mod%03d" % Compat.MODS_LOGGED in logged,
		"the host's log line names at most %d mods per side" % Compat.MODS_LOGGED
	)
	var same := {"a-One": "1.0.0", "b-Two": "2.0.0"}
	var diff := Compat.mod_differences(same, same.duplicate())
	t._check(diff.client.empty() and diff.host.empty(), "the same mods: no difference")
	var extra := {"a-One": "1.0.0", "b-Two": "2.0.0", "c-Three": "1.0.0", "0-Zero": "1.0.0"}
	diff = Compat.mod_differences(same, extra)
	t._check(
		diff.client == ["0-Zero 1.0.0", "c-Three 1.0.0"] and diff.host.empty(),
		"the client's extra mods, sorted %s" % [diff]
	)
	diff = Compat.mod_differences(extra, same)
	t._check(
		diff.host == ["0-Zero 1.0.0", "c-Three 1.0.0"] and diff.client.empty(),
		"the host's extra mods, sorted %s" % [diff]
	)
	diff = Compat.mod_differences(same, {"a-One": "1.0.1", "b-Two": "2.0.0"})
	t._check(
		diff.client == ["a-One 1.0.1"] and diff.host == ["a-One 1.0.0"],
		"another version on both sides %s" % [diff]
	)
	var long_mods := same.duplicate()
	long_mods["x".repeat(5000)] = "9".repeat(5000)
	diff = Compat.mod_differences(same, long_mods)
	t._check(
		(
			diff.client.size() == 1
			and diff.client[0].length() == Compat.MOD_ENTRY_MAX
			and diff.client[0].begins_with("xxx")
			and diff.client[0].ends_with("...")
		),
		"a very long mod id and version cut to %d characters" % Compat.MOD_ENTRY_MAX
	)

	var host_info := host.duplicate()
	host_info.mods = same
	var client := host_info.duplicate()
	client.mods = same.duplicate()
	t._check(Compat.rejection(host_info, client).code == "", "the same mods join")
	client.mods = extra
	var rejection := Compat.rejection(host_info, client)
	t._check(
		rejection.code == "mods" and rejection.args == ["0-Zero 1.0.0, c-Three 1.0.0", "-"]
		and "c-Three 1.0.0" in rejection.reason,
		"an extra mod on the client rejected with both sides (%s)" % [rejection]
	)
	client.mods = {"a-One": "1.0.0"}
	rejection = Compat.rejection(host_info, client)
	t._check(
		rejection.code == "mods" and rejection.args == ["-", "b-Two 2.0.0"],
		"a mod only the host has rejected (%s)" % [rejection]
	)
	client.mods = {"a-One": "1.0.1", "b-Two": "2.0.0"}
	rejection = Compat.rejection(host_info, client)
	t._check(
		rejection.code == "mods" and rejection.args == ["a-One 1.0.1", "a-One 1.0.0"],
		"another version of a mod rejected (%s)" % [rejection]
	)
	for malformed in [["a-One"], "a-One", null]:
		client.mods = malformed
		rejection = Compat.rejection(host_info, client)
		t._check(
			rejection.code == "" and "malformed mod list" in rejection.reason,
			"a malformed mod list rejected (%s)" % [malformed]
		)
	client.erase("mods")
	t._check(
		"malformed mod list" in Compat.rejection(host_info, client).reason,
		"a HELLO without mods is malformed"
	)

	var many := {}
	for i in 5:
		many["m-Mod%d" % i] = "1.0.0"
	client.mods = many
	rejection = Compat.rejection(host_info, client)
	t._check(
		rejection.args[0] == "m-Mod0 1.0.0, m-Mod1 1.0.0, m-Mod2 1.0.0 +2"
		and "m-Mod4 1.0.0" in rejection.reason,
		"a long list shows %d mods and the count of the rest, the log all (%s)" % [
			Compat.MODS_SHOWN, rejection
		]
	)
	var saved_locale := TranslationServer.get_locale()
	TranslationServer.set_locale("de")
	var german := Compat.describe(rejection)
	TranslationServer.set_locale(saved_locale)
	t._check(
		german
		== (
			"abweichende Mods (du: m-Mod0 1.0.0, m-Mod1 1.0.0, m-Mod2 1.0.0 +2;"
			+ " Host: a-One 1.0.0, b-Two 2.0.0)"
		),
		"the mods rejection in the client's language ('%s')" % german
	)
