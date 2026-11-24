extends Control
# Client waiting screen: shown while the host is on a screen the client has no copy of (a solo
# run's screens) and for the moment between two mirrored screens.
# It replaces the local scene, so the client's own menus do not react to its input.

const TitleBackground := preload(
	"res://mods-unpacked/einfluffles-BrotatoTogether/ui/title_background.gd"
)
# Between two mirrored screens (battle -> shop) the view may show for a moment: stay neutral
# instead of flashing "Waiting for the host" unless nothing arrives for this long.
const WAITING_DELAY_SEC := 1.5
# The game's theme: its fonts have Chinese, Japanese and Korean glyphs (Godot's default not).
const THEME_PATH := "res://resources/themes/base_theme.tres"
# Translation keys: the title label translates its key itself, also after a language switch.
const KIND_TITLES := {"title_screen": "BT_HOST_IN_MAIN_MENU"}
const IN_MENU_TITLE := "BT_HOST_IN_MENU"
const WAITING_TITLE := "BT_WAITING_HOST"

var session: Node = null

var _status := Label.new()
var _title := Label.new()
var _age := 0.0


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	theme = load(THEME_PATH)
	add_child(TitleBackground.new())
	var column := VBoxContainer.new()
	column.anchor_right = 1.0
	column.anchor_bottom = 1.0
	column.alignment = BoxContainer.ALIGN_CENTER
	column.add_constant_override("separation", 24)
	add_child(column)
	for label in [_status, _title]:
		label.align = Label.ALIGN_CENTER
		label.autowrap = true  # a long translation wraps instead of widening the screen
		column.add_child(label)


func _process(delta: float) -> void:
	_age += delta
	if session == null:
		return
	var host_id: int = session.transport.host_id
	var host_name := tr("BT_THE_HOST")
	var rtt := "-"
	if session.peers.has(host_id):
		host_name = session.peers[host_id].name
		if session.peers[host_id].rtt_ms >= 0:
			rtt = "%d ms" % session.peers[host_id].rtt_ms
	_status.text = Text.text("BT_CLIENT_STATUS", [host_name, rtt])
	if _title.text == "" and _age >= WAITING_DELAY_SEC:
		_title.text = WAITING_TITLE


func show_menu(state: Dictionary) -> void:
	_title.text = KIND_TITLES.get(state.kind, IN_MENU_TITLE)
