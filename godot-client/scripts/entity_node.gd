extends Node2D

const LERP_DURATION: float = 0.1 # 100ms interpolation
const VISUAL_SCALE: float = 5.0 # Multiplier so circles are visible

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


func _ready() -> void:
	lerp_start_pos = position
	lerp_target_pos = position


func _process(delta: float) -> void:
	if is_despawning:
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
			Color.WHITE
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
	current_radius = sqrt(float(mass)) * VISUAL_SCALE
	target_radius = current_radius
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


func despawn_toward(target_pos: Vector2) -> void:
	if is_despawning:
		return
	is_despawning = true
	var tween: Tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "position", target_pos, 0.2)
	tween.tween_property(self, "scale", Vector2.ZERO, 0.2)
	tween.chain().tween_callback(queue_free)
