extends Node
# The "wave failed" prompt (main.tscn > UI/RetryWave, MenuRetryWave): main.gd shows it from
# _on_EndWaveTimer_timeout, which never runs on a client (timer callbacks are disconnected).
# Host: RETRY_PROMPT (reliable) whenever it appears/changes, with the host's retry setting (Retry /
# End run buttons vs a single OK) and retry count, plus who decides: the prompt's FocusEmulator
# is player 0's (retry_wave.tscn), the host's GUI focus answers to the host machine's keys/pad.
# Client: shows the same prompt on the puppet battle scene with presses disabled; FocusSync
# mirrors the cursor on Retry / End run.

const Protocol := preload("res://mods-unpacked/einfluffles-BrotatoTogether/net/protocol.gd")
const CHECK_INTERVAL := 0.1
const WAITING_LABEL := "BrotatoTogetherRetryWaiting"
const DECIDING_PLAYER := 0  # player_index of RetryWave/FocusEmulator

var session: Node = null
var state_stream: Node = null  # sync/state_stream.gd (set by mod_main.gd)
var battle_host: Node = null
var battle_client: Node = null

var _last_sent := ""
var _check_left := 0.0
var _state := {}  # client: latest RETRY_PROMPT body


func setup(netplay_session: Node, host_battle: Node, client_battle: Node) -> void:
	session = netplay_session
	battle_host = host_battle
	battle_client = client_battle
	session.connect("message", self, "_on_message")
	session.connect("peer_ready", self, "_on_peer_ready")
	battle_client.connect("battle_entered", self, "_apply")


func _ready() -> void:
	pause_mode = PAUSE_MODE_PROCESS


# --- host ---


func _process(delta: float) -> void:
	if not session.is_host() or not battle_host.is_in_battle():
		_last_sent = ""
		return
	_check_left -= delta
	if _check_left > 0.0:
		return
	_check_left = CHECK_INTERVAL
	var body := host_body()
	var key := var2str(body)
	if key != _last_sent and (body.visible or _last_sent != ""):
		_last_sent = key
		session.broadcast_reliable(Protocol.Msg.RETRY_PROMPT, body)


func host_body() -> Dictionary:
	var retry = battle_host._main.get("_retry_wave")
	return {
		"battle_id": battle_host._battle_id,
		"visible": retry != null and retry.visible,
		"retry": bool(ProgressData.settings.get("retry_wave", false)),
		"retries": int(RunData.retries),
		"player": DECIDING_PLAYER,
		"name": _name_of_player(DECIDING_PLAYER),
	}


func _name_of_player(player_index: int) -> String:
	if player_index < CoopService.connected_players.size():
		var device: int = CoopService.connected_players[player_index][0]
		for steam_id in battle_host.input_sync.devices:
			if battle_host.input_sync.devices[steam_id] == device and session.peers.has(steam_id):
				return session.peers[steam_id].name
	return session.transport.get_persona_name(session.transport.local_id)


func _on_peer_ready(_steam_id: int) -> void:
	_last_sent = ""


# --- client ---


func _on_message(steam_id: int, msg_type: int, body) -> void:
	if msg_type != Protocol.Msg.RETRY_PROMPT or not session.is_client():
		return
	if steam_id == session.transport.host_id:
		receive(body)


func receive(body) -> void:
	if typeof(body) != TYPE_DICTIONARY:
		return
	if typeof(body.get("battle_id")) != TYPE_INT or typeof(body.get("visible")) != TYPE_BOOL:
		return
	_state = body
	_apply()


# Also on battle_entered: the prompt can arrive before the puppet battle scene is ready.
func _apply() -> void:
	if _state.empty() or not battle_client.is_in_battle():
		return
	if _state.battle_id != battle_client._battle_id:
		return
	var retry = battle_client._main.get("_retry_wave")
	if retry == null or not is_instance_valid(retry):
		return
	# Clicking the client's copy must not change scenes locally: the host decides.
	retry.confirm_button_pressed = true
	retry.cancel_button_pressed = true
	var with_retry := bool(_state.get("retry", false))
	retry._ok_button.visible = not with_retry
	retry._retry_wave_container.visible = with_retry
	retry._label_number_retry.text = Text.text("RETRY_NUMBER", [str(int(_state.get("retries", 0)))])
	_waiting_label(retry).text = waiting_text(_state, battle_client._you)
	retry.visible = bool(_state.visible)


static func waiting_text(state: Dictionary, you: int) -> String:
	var player := int(state.get("player", 0))
	if player == you:
		return "Your choice (P%d)" % (player + 1)
	return "Waiting for P%d (%s) to choose…" % [player + 1, str(state.get("name", "host"))]


func _waiting_label(retry: Node) -> Label:
	var label := retry.get_node_or_null(WAITING_LABEL) as Label
	if label == null:
		label = Label.new()
		label.name = WAITING_LABEL
		label.align = Label.ALIGN_CENTER
		retry.add_child(label)
	return label
