extends Reference
# Named link profiles for the local-play emulator (link.gd's settings), calibrated from the real
# sessions in docs/implementation.md, "Measurements and session findings". A profile is what one
# side sends over: the launcher sets the same one on every game (BT_LOCAL_PROFILE), and switching
# one game (-Profile <name> -On <instance>) changes only the direction it sends.
#
# Keys (link.gd, DEFAULT): one-way latency_msec on any path, relay_latency_msec more when the
# session is relayed (Steam ping = both sides' one-way sums), jitter_msec +- per message, loss per
# message (an unreliable one is dropped, a reliable one comes retransmit_msec later per loss),
# line_rate in B/s (0: the line carries Steam's send rate; less: Steam's queue fills as on a slow
# upload), stalls (each kind: every [min, max] msec, chance per turn, msec [min, max] during which
# nothing this side sends moves), pop_switch_msec (the relay POP changes, as link_watch logs).
#
# Sources, per profile (dates of the sessions in the findings table):
# - lan: no session; the floor of a wired LAN, for checking that the rest stays quiet.
# - relay-good: 2026-11-16, two players relayed via fra for 8 waves: no network stall, the relay POP
#   changed once mid-session. Direct ping on the same lines 15 to 18 ms; the relayed ping was not
#   logged, the relay's 10 ms are an estimate.
# - relay-typical: the clients of the stall tests' session (Steam ping 25 ms) through a relay, and
#   the three-player session of 2026-11-16 (43 waves): gaps of 200 ms and more there were almost
#   all the games' own scene changes, so network stalls are rare and short. Loss was never logged:
#   0.5 % is an assumption.
# - bad: the worst of every measurement at once and more often, for a few minutes of play to show
#   every diagnostic line: the ping of a far relay (200 ms; the three-player session's pings of
#   about 1 s were its queue), a slow upload (64 KB/s per client: section 4, "more than many home
#   uploads"), so the shop's 30 KB states back up as in that session (20 to 250 KB), the direct
#   route's stalls of 300 to 500 ms (2026-11-16) up to 800 ms and every 4 to 10 s instead of 20 to
#   50 s, a relay POP change every minute, 3 % loss (assumed).
# - stall: the direct route of 2026-11-16 as measured: ping 15 to 18 ms, network stalls of 300 to
#   500 ms every 20 to 50 s, and 22 stalls of 0.5 to 3.3 s in 10 minutes, all within a second of
#   a 12 s beat (50 beats: 0.44 a beat).

const NAMES := ["lan", "relay-good", "relay-typical", "bad", "stall"]

const PROFILES := {
	"lan":
	{
		"latency_msec": 1,
		"relay_latency_msec": 0,
		"jitter_msec": 0,
		"loss": 0.0,
		"retransmit_msec": 10,
		"line_rate": 0,
		"stalls": [],
		"pop_switch_msec": 0,
	},
	"relay-good":
	{
		"latency_msec": 8,
		"relay_latency_msec": 5,
		"jitter_msec": 2,
		"loss": 0.0,
		"retransmit_msec": 40,
		"line_rate": 0,
		"stalls": [],
		"pop_switch_msec": 600000,
	},
	"relay-typical":
	{
		"latency_msec": 12,
		"relay_latency_msec": 8,
		"jitter_msec": 6,
		"loss": 0.005,
		"retransmit_msec": 80,
		"line_rate": 0,
		"stalls": [{"every": [60000, 120000], "chance": 1.0, "msec": [150, 300]}],
		"pop_switch_msec": 0,
	},
	"bad":
	{
		"latency_msec": 70,
		"relay_latency_msec": 30,
		"jitter_msec": 25,
		"loss": 0.03,
		"retransmit_msec": 250,
		"line_rate": 65536,
		"stalls": [{"every": [4000, 10000], "chance": 1.0, "msec": [300, 800]}],
		"pop_switch_msec": 60000,
	},
	"stall":
	{
		"latency_msec": 8,
		"relay_latency_msec": 0,
		"jitter_msec": 2,
		"loss": 0.0,
		"retransmit_msec": 40,
		"line_rate": 0,
		"stalls":
		[
			{"every": [20000, 50000], "chance": 1.0, "msec": [300, 500]},
			{"every": [11500, 12500], "chance": 0.44, "msec": [500, 3300]},
		],
		"pop_switch_msec": 0,
	},
}


static func has(name: String) -> bool:
	return PROFILES.has(name)


# A copy of the profile's settings ({} for an unknown name).
static func settings(name: String) -> Dictionary:
	return PROFILES.get(name, {}).duplicate(true)
