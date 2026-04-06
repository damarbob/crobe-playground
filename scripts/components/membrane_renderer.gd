class_name MembraneRenderer
extends RefCounted

var host: CharacterBody2D
var material: ShaderMaterial
var noise: FastNoiseLite

var _organelle_mgr: OrganelleManager
var _biolum: BioluminescenceSystem
var _deformation: MembraneDeformation

var accumulated_flow: Vector2 = Vector2.ZERO
var accumulated_noise_time: float = 0.0
var smoothed_stretch_angle: float = 0.0
var nucleus_stretch_angle: float = 0.0

var _nucleus_renderer: Node2D
var _cached_time: float = 0.0

const CELL_SHADER = preload("res://shaders/cell_membrane.gdshader")

func _init(p_host: CharacterBody2D, org_mgr: OrganelleManager, biolum: BioluminescenceSystem, def_mgr: MembraneDeformation) -> void:
	host = p_host
	_organelle_mgr = org_mgr
	_biolum = biolum
	_deformation = def_mgr
	
	material = ShaderMaterial.new()
	material.shader = CELL_SHADER
	host.material = material
	
	noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX

	_nucleus_renderer = Node2D.new()
	_nucleus_renderer.name = "NucleusRenderer"
	var n_mat = CanvasItemMaterial.new()
	n_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_nucleus_renderer.material = n_mat
	_nucleus_renderer.draw.connect(_on_nucleus_draw)
	host.add_child(_nucleus_renderer)

func process_rendering(delta: float, time_passed: float) -> void:
	var speed_ratio = host.velocity.length() / host.move_speed
	accumulated_flow += (host.velocity / host.move_speed) * 15.0 * delta
	var noise_time_speed = 1.5 + (speed_ratio * 4.0)
	accumulated_noise_time += delta * noise_time_speed
	
	if host.velocity.length() > 5.0:
		var target_angle = host.velocity.angle()
		smoothed_stretch_angle = lerp_angle(smoothed_stretch_angle, target_angle, delta * host.rotation_smoothness)

	# The nucleus chases the cell's main orientation, hampered by its own rotational inertia
	var n_chase_speed = host.rotation_smoothness / max(1.0, host.nucleus_rotational_inertia * 15.0)
	nucleus_stretch_angle = lerp_angle(nucleus_stretch_angle, smoothed_stretch_angle, delta * n_chase_speed)

	# Pass properties to shader material
	material.set_shader_parameter("luminescence", _biolum.get_luminescence())
	material.set_shader_parameter("time", time_passed)
	material.set_shader_parameter("active_color", host.color_active)

func get_stretch_angle() -> float:
	return smoothed_stretch_angle

func draw_cell(time_passed: float) -> void:
	noise.frequency = host.ripple_frequency
	noise.fractal_octaves = host.ripple_complexity
	
	var speed_ratio = host.velocity.length() / host.move_speed
	var stretch = 1.0 + (speed_ratio * host.max_stretch)
	var squash = 1.0 / stretch
	var current_luminescence = _biolum.get_luminescence()
	
	var points = PackedVector2Array()
	var uvs = PackedVector2Array()
	var colors = PackedColorArray()
	var indices = PackedInt32Array()
	
	var segments = 64 
	var flow_offset = accumulated_flow
	var dynamic_ripple_ratio = host.ripple_ratio * (1.0 + (speed_ratio * host.active_ripple_multiplier))
	var ripple_amp = host.base_radius * dynamic_ripple_ratio
	var body_color = host.color_idle.lerp(host.color_active, current_luminescence)
	
	points.append(Vector2.ZERO)
	uvs.append(Vector2(100.0, 100.0))
	colors.append(body_color)
	
	for i in range(segments + 1): 
		var angle = (float(i) / segments) * TAU
		var dir_vec = Vector2(cos(angle), sin(angle))
		
		var distortion = noise.get_noise_3d(dir_vec.x * 100.0 - flow_offset.x, 
											dir_vec.y * 100.0 - flow_offset.y, 
											accumulated_noise_time)
		
		var current_radius = host.base_radius + (distortion * ripple_amp) + (sin(time_passed * host.pulse_speed) * (host.base_radius * 0.05))
		
		var contact_indent = _deformation.get_contact_indent_at(dir_vec)
		current_radius -= contact_indent
		
		var local_pt = dir_vec * current_radius
		local_pt = _apply_stretch(local_pt, stretch, squash, smoothed_stretch_angle)
		
		points.append(local_pt)
		uvs.append(dir_vec + Vector2(100.0, 100.0))
		colors.append(body_color)
	
	for i in range(segments):
		indices.append(0)
		indices.append(i + 1)
		indices.append(i + 2)

	var rim_points = points.slice(1)
	_draw_soft_glow(rim_points, body_color, current_luminescence)
	
	RenderingServer.canvas_item_add_triangle_array(host.get_canvas_item(), indices, points, colors, uvs)
	host.draw_polyline(rim_points, body_color.lightened(0.4), 1.5, true)
	
	# Trigger redraw for the Additive organelle layer
	_cached_time = time_passed
	_nucleus_renderer.queue_redraw()

func _on_nucleus_draw() -> void:
	var speed_ratio = host.velocity.length() / host.move_speed
	var stretch = 1.0 + (speed_ratio * host.max_stretch)
	var squash = 1.0 / stretch
	var current_luminescence = _biolum.get_luminescence()
	var body_color = host.color_idle.lerp(host.color_active, current_luminescence)
	
	var n = _organelle_mgr.data["nucleus"]
	var n_trans_pos = _apply_internal_displacement(n["pos"], stretch, squash, nucleus_stretch_angle)
	var n_pulse = (sin(_cached_time * host.pulse_speed * 1.5) * 0.5 + 0.5) * 0.2
	
	var dynamic_n_color = body_color
	# For ADD mode, we scale down the alpha to prevent blow-out while matching shade
	dynamic_n_color.a = clamp(n["opacity"] * 0.3 + n_pulse * 0.6, 0.0, 1.0)
	
	_draw_stiff_organelle(_nucleus_renderer, n_trans_pos, n["radius"], dynamic_n_color, stretch, squash, nucleus_stretch_angle, host.nucleus_stiffness, host.nucleus_ripple_factor)
	var nucleolus_radius = n["radius"] * (0.4 + n_pulse)
	_draw_stiff_organelle(_nucleus_renderer, n_trans_pos, nucleolus_radius, Color(1, 1, 1, 0.15 + current_luminescence * 0.2), stretch, squash, nucleus_stretch_angle, 0.9, 0.02)

func _apply_stretch(pos: Vector2, stretch: float, squash: float, angle: float) -> Vector2:
	var p = pos.rotated(-angle)
	p.x *= stretch
	p.y *= squash
	return p.rotated(angle)

func _apply_internal_displacement(pos: Vector2, stretch: float, squash: float, angle: float) -> Vector2:
	var p = pos.rotated(-angle)
	p.x *= stretch * 1.1 
	p.y *= squash * 0.9  
	return p.rotated(angle)

func _draw_stiff_organelle(target: Node2D, pos: Vector2, radius: float, color: Color, stretch: float, squash: float, angle: float, stiffness: float, ripple_factor: float = 0.0) -> void:
	var circle_pts = PackedVector2Array()
	var res = 24 
	var local_stretch = lerp(stretch, 1.0, stiffness)
	var local_squash = lerp(squash, 1.0, stiffness)
	
	for i in range(res + 1):
		var a = (float(i) / res) * TAU
		var dir = Vector2(cos(a), sin(a))
		
		var distortion = 0.0
		if ripple_factor > 0:
			distortion = noise.get_noise_3d(dir.x * 100.0, dir.y * 100.0, accumulated_noise_time * 0.5)
		
		var r = radius + (distortion * radius * ripple_factor)
		var pt = dir * r
		
		pt.x *= local_stretch
		pt.y *= local_squash
		circle_pts.append(pos + pt.rotated(angle))
	
	target.draw_colored_polygon(circle_pts, color)

func _draw_soft_glow(pts: PackedVector2Array, color: Color, lum: float) -> void:
	for r in range(3):
		var alpha = (0.15 - r * 0.04) * lum
		var scale = 1.1 + (r * 0.15)
		var glow_pts = PackedVector2Array()
		for p in pts: glow_pts.append(p * scale)
		host.draw_colored_polygon(glow_pts, Color(color.r, color.g, color.b, alpha))
