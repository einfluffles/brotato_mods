extends Control
# Client screen while connected. Replaces the local game scene so the client's own menus don't
# react to its input (all input goes to the host). Battle/menu mirroring comes later.

var session: Node = null

var _label := Label.new()


func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	var background := ColorRect.new()
	background.color = Color(0.08, 0.08, 0.1)
	background.anchor_right = 1.0
	background.anchor_bottom = 1.0
	add_child(background)
	_label.anchor_right = 1.0
	_label.anchor_bottom = 1.0
	_label.align = Label.ALIGN_CENTER
	_label.valign = Label.VALIGN_CENTER
	add_child(_label)


func _process(_delta: float) -> void:
	if session == null:
		return
	var host_id: int = session.transport.host_id
	var host_name := "host"
	var rtt := "-"
	if session.peers.has(host_id):
		host_name = session.peers[host_id].name
		if session.peers[host_id].rtt_ms >= 0:
			rtt = "%d ms" % session.peers[host_id].rtt_ms
	_label.text = (
		"brotato:together\n\nConnected to %s  (rtt %s)\n\n" % [host_name, rtt]
		+ "Your controls are sent to the host.\n"
		+ "Hold accept on the host's co-op character selection to join.\n"
		+ "Until the client view exists, watch the host's screen share.\n\n"
		+ "F8: leave"
	)
