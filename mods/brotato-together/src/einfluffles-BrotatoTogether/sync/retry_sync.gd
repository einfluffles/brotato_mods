extends Node
# The "wave failed" prompt (main.tscn > UI/RetryWave): main.gd shows it from
# _on_EndWaveTimer_timeout, which never runs on a client. Section RETRY is active while the host's
# prompt shows; the client shows its copy with presses disabled.

const StateStream := preload("res://mods-unpacked/einfluffles-BrotatoTogether/sync/state_stream.gd")
const WAITING_LABEL := "BrotatoTogetherRetryWaiting"
const DECIDING_PLAYER := 0  # player_index of RetryWave/FocusEmulator
const PENDING_TIMEOUT_SEC := 30.0

var session: Node = null
var state_stream: Node = null
var battle_host: Node = null
var battle_client: Node = null


func setup(netplay_session: Node, host_battle: Node, client_battle: Node) -> void:
	session = netplay_session
	battle_host = host_battle
	battle_client = client_battle
	state_stream.register_provider(StateStream.RETRY, self)
	state_stream.register_handler(StateStream.RETRY, self, PENDING_TIMEOUT_SEC)


func state_key(_section: int) -> String:
	if not battle_host.is_in_battle():
		return ""
	var retry = battle_host._main.get("_retry_wave")
	if retry == null or not retry.visible:
		return ""
	return var2str(state_body(StateStream.RETRY))


# battle_id, retry (the host's settings.retry_wave), retries, player (who decides), name
func state_body(_section: int):
	return {
		"battle_id": battle_host._battle_id,
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


func apply_state(_section: int, body, _revision: int) -> bool:
	if typeof(body) != TYPE_DICTIONARY or typeof(body.get("battle_id")) != TYPE_INT:
		return true
	if body.battle_id < battle_client._battle_id:
		return true
	if body.battle_id != battle_client._battle_id or not battle_client.is_in_battle():
		return false
	var retry = _client_prompt()
	if retry == null:
		return true
	# Clicking the client's copy must not change scenes locally: the host decides.
	retry.confirm_button_pressed = true
	retry.cancel_button_pressed = true
	var with_retry := bool(body.get("retry", false))
	retry._ok_button.visible = not with_retry
	retry._retry_wave_container.visible = with_retry
	retry._label_number_retry.text = Text.text("RETRY_NUMBER", [str(int(body.get("retries", 0)))])
	_waiting_label(retry).text = waiting_text(body, battle_client._you)
	retry.visible = true
	return true


func clear_state(_section: int) -> void:
	var retry = _client_prompt()
	if retry != null:
		retry.visible = false


func _client_prompt():
	if not battle_client.is_in_battle():
		return null
	var retry = battle_client._main.get("_retry_wave")
	return retry if retry != null and is_instance_valid(retry) else null


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
