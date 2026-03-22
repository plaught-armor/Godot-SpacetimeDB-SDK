extends Node2D

const PLAYER_COLORS: Array[Color] = [
	Color(1.0, 0.9, 0.2), # Yellow
	Color(0.7, 0.3, 0.9), # Purple
	Color(0.9, 0.2, 0.2), # Red
	Color(0.2, 0.6, 1.0), # Blue
	Color(1.0, 0.5, 0.2), # Orange
	Color(0.2, 0.9, 0.8), # Cyan
	Color(1.0, 0.4, 0.7), # Pink
	Color(0.5, 0.8, 0.2), # Lime
	Color(0.9, 0.9, 0.9), # White
]

const FOOD_COLORS: Array[Color] = [
	Color(0.2, 0.8, 0.2),
	Color(0.3, 0.9, 0.3),
	Color(0.1, 0.7, 0.3),
	Color(0.2, 0.6, 0.1),
	Color(0.4, 0.9, 0.2),
	Color(0.1, 0.8, 0.4),
]

const INPUT_RATE: float = 0.05 # 20Hz
const WORLD_SCALE: float = 5.0 # Match VISUAL_SCALE so collision radius aligns with visual

var entity_nodes: Dictionary[int, Node2D] = { }
var circle_to_player: Dictionary[int, int] = { }
var player_circles: Dictionary[int, Array] = { }
var player_names: Dictionary[int, String] = { }

var local_identity: PackedByteArray
var local_player_id: int = -1
var world_size: int = 1000
var input_timer: float = 0.0
var game_started: bool = false

@onready var entity_container: Node2D = $EntityContainer
@onready var camera: Camera2D = $Camera2D
@onready var username_screen: Control = $UI/UsernameScreen
@onready var death_screen: Control = $UI/DeathScreen
@onready var leaderboard: Control = $UI/Leaderboard
@onready var world_border: Node2D = $WorldBorder

const QUERIES: PackedStringArray = [
	"SELECT * FROM entity",
	"SELECT * FROM circle",
	"SELECT * FROM food",
	"SELECT * FROM player",
	"SELECT * FROM config",
	"SELECT * FROM consume_entity_event",
]


func _ready() -> void:
	var options := SpacetimeDBConnectionOptions.new()
	options.debug_mode = true
	options.compression = SpacetimeDBConnection.CompressionPreference.GZIP
	options.auto_reconnect = true

	SpacetimeDB.Blackholio.connect_db(
		"http://127.0.0.1:3000",
		"blackholio",
		options,
	)

	SpacetimeDB.Blackholio.connected.connect(_on_connected)
	SpacetimeDB.Blackholio.disconnected.connect(_on_disconnected)
	SpacetimeDB.Blackholio.connection_error.connect(_on_connection_error)

	death_screen.visible = false
	username_screen.visible = false


func _on_connected(identity: PackedByteArray, _token: String) -> void:
	local_identity = identity
	print("Connected! Identity: 0x%s" % identity.hex_encode())
	_subscribe_all()


func _on_disconnected() -> void:
	print("Disconnected from server")


func _on_connection_error(code: int, reason: String) -> void:
	printerr("Connection error %d: %s" % [code, reason])


func _subscribe_all() -> void:
	var sub := SpacetimeDB.Blackholio.subscribe(QUERIES)
	if sub.error:
		printerr("Subscription failed")
		return
	sub.applied.connect(_on_subscription_applied)


func _on_subscription_applied() -> void:
	print("Subscription applied")
	_setup_table_callbacks()

	# Read config
	var configs := SpacetimeDB.Blackholio.db.config.iter()
	print("Configs: %d" % configs.size())
	if configs.size() > 0:
		world_size = configs[0].world_size
		print("World size: %d" % world_size)
	_draw_world_border()

	# Load existing state
	_load_existing_data()
	print(
		"Loaded: %d entities, %d players, %d circles, %d food" % [
			SpacetimeDB.Blackholio.db.entity.count(),
			SpacetimeDB.Blackholio.db.player.count(),
			SpacetimeDB.Blackholio.db.circle.count(),
			SpacetimeDB.Blackholio.db.food.count(),
		],
	)

	# Check if we already have a player with circles
	if local_player_id >= 0 and player_circles.has(local_player_id) and player_circles[local_player_id].size() > 0:
		game_started = true
		username_screen.visible = false
	else:
		username_screen.visible = true


func _setup_table_callbacks() -> void:
	SpacetimeDB.Blackholio.db.entity.on_insert(_on_entity_insert)
	SpacetimeDB.Blackholio.db.entity.on_update(_on_entity_update)
	SpacetimeDB.Blackholio.db.entity.on_delete(_on_entity_delete)
	SpacetimeDB.Blackholio.db.circle.on_insert(_on_circle_insert)
	SpacetimeDB.Blackholio.db.circle.on_delete(_on_circle_delete)
	SpacetimeDB.Blackholio.db.food.on_insert(_on_food_insert)
	SpacetimeDB.Blackholio.db.player.on_insert(_on_player_insert)
	SpacetimeDB.Blackholio.db.player.on_delete(_on_player_delete)
	SpacetimeDB.Blackholio.db.consume_entity_event.on_insert(_on_consume_event)


func _load_existing_data() -> void:
	# Load players first
	for player in SpacetimeDB.Blackholio.db.player.iter():
		_register_player(player)

	# Load entities
	for entity in SpacetimeDB.Blackholio.db.entity.iter():
		_spawn_entity_node(entity)

	# Load circles (associate with players)
	for circle in SpacetimeDB.Blackholio.db.circle.iter():
		_register_circle(circle)

	# Load food
	for food in SpacetimeDB.Blackholio.db.food.iter():
		_mark_as_food(food.entity_id)

# --- Entity callbacks ---


func _on_entity_insert(entity: Resource) -> void:
	_spawn_entity_node(entity)


func _on_entity_update(_old: Resource, new: Resource) -> void:
	var node: Node2D = entity_nodes.get(new.entity_id)
	if node and node.has_method("update_target"):
		node.update_target(
			Vector2(new.position.x, new.position.y) * WORLD_SCALE,
			new.mass,
		)


func _on_entity_delete(entity: Resource) -> void:
	var node: Node2D = entity_nodes.get(entity.entity_id)
	if node:
		node.queue_free()
		entity_nodes.erase(entity.entity_id)

	# Clean up circle tracking
	if circle_to_player.has(entity.entity_id):
		var pid: int = circle_to_player[entity.entity_id]
		circle_to_player.erase(entity.entity_id)
		_remove_circle_from_player(pid, entity.entity_id)

# --- Circle callbacks ---


func _on_circle_insert(circle: Resource) -> void:
	_register_circle(circle)


func _on_circle_delete(circle: Resource) -> void:
	var eid: int = circle.entity_id
	if circle_to_player.has(eid):
		var pid: int = circle_to_player[eid]
		circle_to_player.erase(eid)
		_remove_circle_from_player(pid, eid)

	# Reset entity node to default appearance
	var node: Node2D = entity_nodes.get(eid)
	if node and node.has_method("set_circle_info"):
		node.set_circle_info(-1, "")


func _register_circle(circle: Resource) -> void:
	var eid: int = circle.entity_id
	var pid: int = circle.player_id
	circle_to_player[eid] = pid

	if not player_circles.has(pid):
		player_circles[pid] = []
	if eid not in player_circles[pid]:
		player_circles[pid].append(eid)

	# Update visual
	var node: Node2D = entity_nodes.get(eid)
	if node and node.has_method("set_circle_info"):
		var color: Color = PLAYER_COLORS[pid % PLAYER_COLORS.size()]
		var pname: String = player_names.get(pid, "")
		node.set_circle_info(pid, pname, color)


func _remove_circle_from_player(pid: int, eid: int) -> void:
	if not player_circles.has(pid):
		return
	var circles: Array = player_circles[pid]
	circles.erase(eid)
	if pid == local_player_id and circles.is_empty():
		_on_local_player_died()

# --- Food callbacks ---


func _on_food_insert(food: Resource) -> void:
	_mark_as_food(food.entity_id)


func _mark_as_food(entity_id: int) -> void:
	var node: Node2D = entity_nodes.get(entity_id)
	if node and node.has_method("set_food"):
		var color: Color = FOOD_COLORS[entity_id % FOOD_COLORS.size()]
		node.set_food(color)

# --- Player callbacks ---


func _on_player_insert(player: Resource) -> void:
	_register_player(player)


func _on_player_delete(player: Resource) -> void:
	var pid: int = player.player_id
	player_names.erase(pid)
	player_circles.erase(pid)


func _register_player(player: Resource) -> void:
	var pid: int = player.player_id
	player_names[pid] = player.name

	if player.identity == local_identity:
		local_player_id = pid

# --- Consume event ---


func _on_consume_event(event: Resource) -> void:
	var consumed_node: Node2D = entity_nodes.get(event.consumed_entity_id)
	var consumer_node: Node2D = entity_nodes.get(event.consumer_entity_id)
	if consumed_node and consumer_node and consumed_node.has_method("despawn_toward"):
		consumed_node.despawn_toward(consumer_node.position)

# --- Entity spawning ---


func _spawn_entity_node(entity: Resource) -> void:
	if entity_nodes.has(entity.entity_id):
		return
	var node: Node2D = preload("res://scripts/entity_node.gd").new()
	node.position = Vector2(entity.position.x, entity.position.y) * WORLD_SCALE
	node.set_mass(entity.mass)
	entity_container.add_child(node)
	entity_nodes[entity.entity_id] = node

# --- Input ---


func _process(delta: float) -> void:
	if not game_started:
		return

	input_timer += delta
	if input_timer >= INPUT_RATE:
		input_timer = 0.0
		_send_input()

	_update_camera(delta)
	leaderboard.update_leaderboard(self)


func _unhandled_input(event: InputEvent) -> void:
	if not game_started or not SpacetimeDB.Blackholio.is_connected_db():
		return

	if event.is_action_pressed("split"):
		SpacetimeDB.Blackholio.reducers.player_split()
	elif event.is_action_pressed("suicide"):
		SpacetimeDB.Blackholio.reducers.suicide()


func _send_input() -> void:
	if not SpacetimeDB.Blackholio.is_connected_db():
		return
	var screen_center: Vector2 = get_viewport_rect().size / 2.0
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var direction: Vector2 = (mouse_pos - screen_center) / (get_viewport_rect().size.y / 3.0)

	var db_dir := BlackholioDbVector2.create(direction.x, direction.y)
	SpacetimeDB.Blackholio.reducers.update_player_input(db_dir)

# --- Camera ---


func _update_camera(delta: float) -> void:
	if local_player_id < 0 or not player_circles.has(local_player_id):
		return

	var circle_count: int = player_circles[local_player_id].size()
	if circle_count == 0:
		return

	# Calculate center of mass
	var total_mass: float = 0.0
	var weighted_pos: Vector2 = Vector2.ZERO
	for eid: int in player_circles[local_player_id]:
		var node: Node2D = entity_nodes.get(eid)
		if node:
			var entity: Resource = SpacetimeDB.Blackholio.db.entity.entity_id.find(eid)
			if entity:
				var m: float = float(entity.mass)
				weighted_pos += node.position * m
				total_mass += m

	if total_mass > 0:
		var center: Vector2 = weighted_pos / total_mass
		camera.position = camera.position.lerp(center, delta * 5.0)

	# Zoom based on mass + split bonus
	var base_zoom: float = 1.0
	var mass_bonus: float = clampf(total_mass / 50.0, 0.0, 10.0) * 0.05
	var split_bonus: float = 0.3 if circle_count >= 2 else 0.0
	var target_zoom: float = base_zoom - mass_bonus - split_bonus
	target_zoom = clampf(target_zoom, 0.2, 1.0)
	var z: float = lerpf(camera.zoom.x, target_zoom, delta * 2.0)
	camera.zoom = Vector2(z, z)

# --- Death / Respawn ---


func _on_local_player_died() -> void:
	game_started = false
	death_screen.visible = true


func on_enter_game(player_name: String) -> void:
	var name_to_send: String = player_name.strip_edges()
	if name_to_send.is_empty():
		name_to_send = "Player"
	print("Entering game as: %s" % name_to_send)
	var enter_game := SpacetimeDB.Blackholio.reducers.enter_game(name_to_send)
	print("enter_game reducer call sent, outcome: %s" % enter_game.outcome)
	username_screen.visible = false
	game_started = true


func on_respawn() -> void:
	SpacetimeDB.Blackholio.reducers.respawn()
	death_screen.visible = false
	game_started = true

# --- World border ---


func _draw_world_border() -> void:
	var line := Line2D.new()
	var s: float = float(world_size) * WORLD_SCALE
	line.points = PackedVector2Array(
		[
			Vector2(0, 0),
			Vector2(s, 0),
			Vector2(s, s),
			Vector2(0, s),
			Vector2(0, 0),
		],
	)
	line.width = 2.0
	line.default_color = Color(0.4, 0.4, 0.4, 0.8)
	world_border.add_child(line)

# --- Leaderboard helpers ---


func get_leaderboard_data() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for pid: int in player_circles:
		var circles: Array = player_circles[pid]
		if circles.is_empty():
			continue
		var total_mass: int = 0
		for eid: int in circles:
			var entity: Resource = SpacetimeDB.Blackholio.db.entity.entity_id.find(eid)
			if entity:
				total_mass += entity.mass
		if total_mass > 0:
			entries.append(
				{
					"player_id": pid,
					"name": player_names.get(pid, "???"),
					"mass": total_mass,
					"is_local": pid == local_player_id,
				},
			)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.mass > b.mass)
	return entries
