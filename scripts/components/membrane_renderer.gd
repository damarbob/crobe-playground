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

var _tail_renderer: Node2D
var _nucleus_renderer: Node2D
var _cached_time: float = 0.0
var _cached_rim_points: PackedVector2Array

var accumulated_tail_phase: float = 0.0
var _tail_points: Array[Vector2] = []
var _last_n_trans_pos: Vector2 = Vector2.ZERO

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

	_tail_renderer = Node2D.new()
	_tail_renderer.name = "TailRenderer"
	_tail_renderer.show_behind_parent = true
	var t_mat = CanvasItemMaterial.new()
	t_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MIX
	_tail_renderer.material = t_mat
	_tail_renderer.draw.connect(_on_tail_draw)
	host.add_child(_tail_renderer)

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
	
	# Determine clamped nucleus visually anchored position
	var stretch = 1.0 + (speed_ratio * host.max_stretch)
	var squash = 1.0 / stretch
	var n = _organelle_mgr.data["nucleus"]
	var structural_offset = Vector2(-host.nucleus_structural_offset, 0).rotated(nucleus_stretch_angle)
	var combined_pos = n["pos"] + structural_offset
	combined_pos = combined_pos.limit_length(host.base_radius * 0.55)
	_last_n_trans_pos = _apply_internal_displacement(combined_pos, stretch, squash, nucleus_stretch_angle)
	
	# Process tail physics
	var tail_speed = max(0.1, speed_ratio) # Idle sway fallback
	accumulated_tail_phase += delta * host.tail_wobble_speed * tail_speed
	
	var segments = 16
	var seg_len = host.tail_length / float(segments - 1)
	
	# Initialize tail points along a trailing line (prevents solid-circle startup)
	if _tail_points.is_empty():
		var init_dir = Vector2(-1, 0).rotated(smoothed_stretch_angle)
		for i in range(segments):
			_tail_points.append(_last_n_trans_pos + init_dir * seg_len * i)
	
	# Step 1: Anchor at nucleus
	_tail_points[0] = _last_n_trans_pos
	
	# Step 2: Velocity shift (inertial drag on trailing points)
	var local_shift = -host.velocity * delta
	for i in range(1, _tail_points.size()):
		_tail_points[i] += local_shift
	
	# Step 2b: Straightening spring — gradually relax bends toward straight
	var straighten_factor = 1.0 - exp(-host.tail_straightening_speed * delta)
	for i in range(1, _tail_points.size() - 1):
		var dir_in = (_tail_points[i] - _tail_points[i-1])
		var dir_out = (_tail_points[i+1] - _tail_points[i])
		if dir_in.length_squared() < 0.01 or dir_out.length_squared() < 0.01:
			continue
		var angle = dir_in.angle_to(dir_out)
		var relaxed_angle = angle * (1.0 - straighten_factor)
		var new_dir = dir_in.normalized().rotated(relaxed_angle)
		_tail_points[i+1] = _tail_points[i] + new_dir * dir_out.length()
	
	
	# Step 3: Distance constraint (normalize lengths before angle work)
	for i in range(1, _tail_points.size()):
		var target_dist = _tail_points[i-1].distance_to(_tail_points[i])
		var diff = target_dist - seg_len
		if target_dist > 0:
			var correction = (_tail_points[i-1] - _tail_points[i]).normalized() * diff
			_tail_points[i] += correction
	
	# Step 4: Curvature constraint — prevent sharp bending and self-overlap
	# Uses seg_len (not actual distance) to enforce angle + distance simultaneously
	var max_bend_rad = deg_to_rad(host.tail_max_bend_angle)
	for i in range(1, _tail_points.size() - 1):
		var dir_in = (_tail_points[i] - _tail_points[i-1])
		var dir_out = (_tail_points[i+1] - _tail_points[i])
		
		if dir_in.length_squared() < 0.01 or dir_out.length_squared() < 0.01:
			continue
		
		var angle = dir_in.angle_to(dir_out)
		if abs(angle) > max_bend_rad:
			var clamped_angle = clamp(angle, -max_bend_rad, max_bend_rad)
			var new_dir = dir_in.normalized().rotated(clamped_angle)
			_tail_points[i+1] = _tail_points[i] + new_dir * seg_len
	
	# Step 5: Membrane repulsion — push tail segments outside the cell body
	var repulsion_radius = host.base_radius * stretch * 0.9
	for i in range(1, _tail_points.size()):
		var dist_from_center = _tail_points[i].length()
		if dist_from_center < repulsion_radius and dist_from_center > 0.01:
			_tail_points[i] = _tail_points[i].normalized() * repulsion_radius
	
	# Step 6: Distance constraint (second pass — repair chain after repulsion)
	for i in range(1, _tail_points.size()):
		var target_dist = _tail_points[i-1].distance_to(_tail_points[i])
		var diff = target_dist - seg_len
		if target_dist > 0:
			var correction = (_tail_points[i-1] - _tail_points[i]).normalized() * diff
			_tail_points[i] += correction

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
	
	var segments = host.cell_segments
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
		
		var edge_pt = dir_vec * current_radius
		edge_pt = _apply_stretch(edge_pt, stretch, squash, smoothed_stretch_angle)
		
		# Glow buffer: geometry is 50% larger than the cell body to allow the shader to draw the halo
		var glow_pt = edge_pt * 1.5 
		
		points.append(glow_pt)
		uvs.append(dir_vec * 1.5 + Vector2(100.0, 100.0))
		colors.append(body_color)
	
	for i in range(segments):
		indices.append(0)
		indices.append(i + 1)
		indices.append(i + 2)

	RenderingServer.canvas_item_add_triangle_array(host.get_canvas_item(), indices, points, colors, uvs)
	
	# Outlining and organelle trigger
	var rim_points = PackedVector2Array()
	for i in range(1, points.size()):
		rim_points.append(points[i] / 1.5) # Scale back to true edge for outline
	
	host.draw_polyline(rim_points, body_color.lightened(0.4), 1.5, true)
	
	_cached_rim_points = rim_points
	
	# Trigger redraw for the Additive organelle layer and Tail
	_cached_time = time_passed
	_tail_renderer.queue_redraw()
	_nucleus_renderer.queue_redraw()

func _on_tail_draw() -> void:
	if _tail_points.size() < 2: return
	
	var current_luminescence = _biolum.get_luminescence()
	var body_color = host.color_idle.lerp(host.color_active, current_luminescence)
	var t_color = body_color
	t_color.a = 0.6 + current_luminescence * 0.4
	
	# Step 1: Build a clean centerline with minimum-distance collapse guard.
	# Points too close together produce degenerate perpendiculars.
	var clean_pts: Array[Vector2] = []
	var clean_ts: Array[float] = []  # Corresponding parametric t values
	var segments = _tail_points.size()
	var min_dist_sq = 4.0  # 2px minimum gap
	
	for i in range(segments):
		var t = float(i) / (segments - 1)
		var phase = accumulated_tail_phase - t * PI * 2.5
		var wobble_amp = host.tail_wobble_amp * (0.3 + (host.velocity.length() / host.move_speed) * 0.7)
		var wobble = sin(phase) * wobble_amp * t
		
		# Stable perpendicular from the physical segment direction
		var perp = Vector2.UP.rotated(smoothed_stretch_angle)
		if i < segments - 1:
			var seg_dir = _tail_points[i+1] - _tail_points[i]
			if seg_dir.length_squared() > 0.01:
				perp = seg_dir.normalized().orthogonal()
		elif i > 0:
			var seg_dir = _tail_points[i] - _tail_points[i-1]
			if seg_dir.length_squared() > 0.01:
				perp = seg_dir.normalized().orthogonal()
		
		var pt = _tail_points[i] + perp * wobble
		
		# Collapse guard: skip points too close to the previous accepted point
		if clean_pts.size() > 0 and pt.distance_squared_to(clean_pts[clean_pts.size() - 1]) < min_dist_sq:
			if i < segments - 1:  # Always keep the last point
				continue
		clean_pts.append(pt)
		clean_ts.append(t)
	
	if clean_pts.size() < 2: return
	
	# Step 2: Compute consistent, smoothed perpendiculars for the ribbon.
	# Use a running reference perpendicular to prevent sign flips on sharp bends.
	var perps: Array[Vector2] = []
	var ref_perp = Vector2.UP.rotated(smoothed_stretch_angle)
	
	for i in range(clean_pts.size()):
		var raw_perp: Vector2
		if i < clean_pts.size() - 1:
			raw_perp = (clean_pts[i+1] - clean_pts[i]).normalized().orthogonal()
		else:
			raw_perp = (clean_pts[i] - clean_pts[i-1]).normalized().orthogonal()
		
		# Ensure consistent winding: flip if it disagrees with our running reference
		if raw_perp.dot(ref_perp) < 0:
			raw_perp = -raw_perp
		
		ref_perp = raw_perp  # Track orientation
		perps.append(raw_perp)
	
	# Step 3: Build the ribbon polygon (left edge forward, right edge backward)
	var poly_pts = PackedVector2Array()
	var n_clean = clean_pts.size()
	
	for i in range(n_clean):
		var w = lerp(host.tail_base_width, 0.5, clean_ts[i])
		poly_pts.append(clean_pts[i] + perps[i] * w)
	
	for i in range(n_clean - 1, -1, -1):
		var w = lerp(host.tail_base_width, 0.5, clean_ts[i])
		poly_pts.append(clean_pts[i] - perps[i] * w)
	
	# Explicitly close the polygon to prevent rendering gaps
	if poly_pts.size() > 2:
		poly_pts.append(poly_pts[0])
	
	if poly_pts.size() >= 3:
		_tail_renderer.draw_colored_polygon(poly_pts, t_color)
	# Rounded cap at the base for smooth membrane blend
	_tail_renderer.draw_circle(clean_pts[0], host.tail_base_width, t_color)

func _on_nucleus_draw() -> void:
	var speed_ratio = host.velocity.length() / host.move_speed
	var stretch = 1.0 + (speed_ratio * host.max_stretch)
	var squash = 1.0 / stretch
	var current_luminescence = _biolum.get_luminescence()
	var body_color = host.color_idle.lerp(host.color_active, current_luminescence)
	
	var n = _organelle_mgr.data["nucleus"]
	
	# Apply anomalous structural offset to the back side & clamp properly 
	var structural_offset = Vector2(-host.nucleus_structural_offset, 0).rotated(nucleus_stretch_angle)
	var combined_pos = n["pos"] + structural_offset
	combined_pos = combined_pos.limit_length(host.base_radius * 0.55)
	
	var n_trans_pos = _apply_internal_displacement(combined_pos, stretch, squash, nucleus_stretch_angle)
	var n_pulse = (sin(_cached_time * host.pulse_speed * 1.5) * 0.5 + 0.5) * 0.2
	
	var dynamic_n_color = body_color
	# For ADD mode, we scale down the alpha to prevent blow-out while matching shade
	dynamic_n_color.a = clamp(n["opacity"] * 0.3 + n_pulse * 0.6, 0.0, 1.0)
	
	# Draw Cytoplasmic Fibers
	if host.fiber_count > 0 and _cached_rim_points.size() > 0:
		var total_rim_pts = _cached_rim_points.size()
		var unique_rim_pts = total_rim_pts - 1 # Remove duplicate endpoint (0 == 360)
		var f_color = dynamic_n_color
		f_color.a *= host.fiber_opacity
		
		for i in range(host.fiber_count):
			# Map fiber index to rim point using stable floating point sampling
			var rim_idx = roundi(float(i) * unique_rim_pts / host.fiber_count)
			var end_pt = _cached_rim_points[rim_idx]
			
			var fiber_pts = PackedVector2Array()
			var f_segments = host.fiber_segments
			for j in range(f_segments + 1):
				var t = float(j) / f_segments
				var pt = n_trans_pos.lerp(end_pt, t)
				if j > 0 and j < f_segments:
					var noise_val = noise.get_noise_3d(pt.x * 2.0, pt.y * 2.0, accumulated_noise_time * 2.0)
					var perp = (end_pt - n_trans_pos).normalized().orthogonal()
					pt += perp * noise_val * (10.0 + speed_ratio * 15.0) # Wavy organic strands
				fiber_pts.append(pt)
			_nucleus_renderer.draw_polyline(fiber_pts, f_color, 1.2, true)
	
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
	var res = 16 
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
