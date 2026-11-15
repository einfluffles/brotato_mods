extends Control
# Client waiting screen: shown while the host is on a screen the client has no copy of (the
# title screen and its pages), and for the moment between two mirrored screens. The host's
# selection screens and the end of run are the game's own scenes (sync/menu_puppet.gd).
# Replaces the local game scene so the client's own menus don't react to its input (all input
# goes to the host).

const TitleBackground := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/title_background.gd"
)
# Between two mirrored screens (battle -> shop) the view may show for a moment: stay neutral
# instead of flashing "Waiting for the host" unless nothing arrives for this long.
const WAITING_DELAY_SEC := 1.5
const KIND_TITLES := {"title_screen": "The host is in the main menu"}

var session: Node = null

var _status := Label.new()
var _title := Label.new()
var _age := 0.0


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	add_child(TitleBackground.new())
	var column := VBoxContainer.new()
	column.anchor_right = 1.0
	column.anchor_bottom = 1.0
	column.alignment = BoxContainer.ALIGN_CENTER
	column.add_constant_override("separation", 24)
	add_child(column)
	for label in [_status, _title]:
		label.align = Label.ALIGN_CENTER
		column.add_child(label)


func _process(delta: float) -> void:
	_age += delta
	if session == null:
		return
	var host_id: int = session.transport.host_id
	var host_name := "host"
	var rtt := "-"
	if session.peers.has(host_id):
		host_name = session.peers[host_id].name
		if session.peers[host_id].rtt_ms >= 0:
			rtt = "%d ms" % session.peers[host_id].rtt_ms
	_status.text = "brotato:together — connected to %s (rtt %s) — F9: menu" % [host_name, rtt]
	if _title.text == "" and _age >= WAITING_DELAY_SEC:
		_title.text = "Waiting for the host…"


func show_menu(state: Dictionary) -> void:
	_title.text = KIND_TITLES.get(state.kind, "The host is in a menu (%s)" % state.kind)
