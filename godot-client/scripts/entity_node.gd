extends Node2D

const LERP_DURATION: float = 0.1 # 100ms interpolation
const VISUAL_SCALE: float = 5.0 # Multiplier so circles are visible
const DESPAWN_DURATION: float = 0.2 # consume animation length

var lerp_start_pos: Vector2
var lerp_target_pos: Vector2
var lerp_time: float = LERP_DURATION

var current_radius: float = 1.0
var target_radius: float = 1.0
var current_mass: int = 1

var circle_color: Color = Color.WHITE
var is_food: bool = false
var player_id: int = -1
var player_name: String = ""

var is_despawning: bool = false
var _despawn_consumer: Node2D = null # eater to fly into; null/freed → shrink in place
var _despawn_time: float = 0.0
var _despawn_from: Vector2 = Vector2.ZERO
var _despawn_from_radius: float = 0.0
var _despawn_target: Vector2 = Vector2.ZERO # last-known consumer pos (survives its free)


func _ready() -> void:
	lerp_start_pos = position
	lerp_target_pos = position


func _process(delta: float) -> void:
	if is_despawning:
		_process_despawn(delta)
		return

	# Position interpolation
	lerp_time = minf(lerp_time + delta, LERP_DURATION)
	position = lerp_start_pos.lerp(lerp_target_pos, lerp_time / LERP_DURATION)

	# Radius interpolation
	if not is_equal_approx(current_radius, target_radius):
		current_radius = lerpf(current_radius, target_radius, delta * 8.0)
		queue_redraw()


func _draw() -> void:
	draw_circle(Vector2.ZERO, current_radius, circle_color)

	if not is_food and not player_name.is_empty():
		var font: Font = ThemeDB.fallback_font
		var font_size: int = clampi(int(current_radius * 0.5), 8, 48)
		var text_size: Vector2 = font.get_string_size(player_name, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		draw_string(
			font,
			Vector2(-text_size.x / 2.0, font_size / 3.0),
			player_name,
			HORIZONTAL_ALIGNMENT_CENTER,
			-1,
			font_size,
			Color.WHITE,
		)


func update_target(new_pos: Vector2, new_mass: int) -> void:
	lerp_start_pos = position
	lerp_target_pos = new_pos
	lerp_time = 0.0

	if new_mass != current_mass:
		current_mass = new_mass
		target_radius = sqrt(float(new_mass)) * VISUAL_SCALE
		queue_redraw()


func set_mass(mass: int) -> void:
	current_mass = mass
	target_radius = sqrt(float(mass)) * VISUAL_SCALE
	# Start at 0 so the circle grows in via the _process radius lerp (matches the
	# upstream client, which seeds radius 0 on spawn). Spawn-only — live mass changes
	# go through update_target and keep their smooth resize.
	current_radius = 0.0
	queue_redraw()


func set_circle_info(pid: int, pname: String, color: Color = Color.WHITE) -> void:
	player_id = pid
	player_name = pname
	circle_color = color
	is_food = false
	queue_redraw()


func set_food(color: Color) -> void:
	circle_color = color
	is_food = true
	queue_redraw()


## Starts the consume animation: fly into [param consumer] while shrinking to
## nothing, then free. [param consumer] may be null (consumer not spawned locally)
## — then it shrinks in place. Driven per-frame in [method _process_despawn] so it
## chases a moving consumer rather than aiming at a stale position.
func despawn_into(consumer: Node2D) -> void:
	if is_despawning:
		return
	is_despawning = true
	_despawn_consumer = consumer
	_despawn_time = 0.0
	_despawn_from = position
	_despawn_from_radius = current_radius
	_despawn_target = consumer.position if is_instance_valid(consumer) else position
	z_index += 10 # render over the consumer during the fly-in


func _process_despawn(delta: float) -> void:
	_despawn_time = minf(_despawn_time + delta, DESPAWN_DURATION)
	var t: float = _despawn_time / DESPAWN_DURATION

	# Re-read the consumer each frame so we chase it if it's still moving; cache the
	# last-known position so a consumer freed mid-animation doesn't strand us.
	if is_instance_valid(_despawn_consumer):
		_despawn_target = _despawn_consumer.position
	position = _despawn_from.lerp(_despawn_target, t)
	current_radius = lerpf(_despawn_from_radius, 0.0, t)
	queue_redraw()

	if _despawn_time >= DESPAWN_DURATION:
		queue_free()
