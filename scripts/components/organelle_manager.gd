class_name OrganelleManager
extends RefCounted

var host: CharacterBody2D
var noise: FastNoiseLite
var data: Dictionary = {}

func _init(p_host: CharacterBody2D) -> void:
	host = p_host
	noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_generate_anatomy()

func _generate_anatomy() -> void:
	data["nucleus"] = {
		"pos": Vector2.ZERO,
		"drift_seed": randf() * 100.0, 
		"radius": host.base_radius * 0.3,
		"opacity": host.nucleus_opacity
	}

func process_drift(delta: float, time_passed: float, speed_ratio: float, active_deformations: Array[Dictionary]) -> void:
	noise.frequency = host.ripple_frequency
	noise.fractal_octaves = host.ripple_complexity
	
	var n = data["nucleus"]
	var drift = Vector2(noise.get_noise_1d(time_passed * 10.0 + n["drift_seed"]), 
						noise.get_noise_1d(time_passed * 10.0 - n["drift_seed"])) * 5.0
	
	var vel_norm = host.velocity.normalized() if host.velocity.length() > 0.1 else Vector2.ZERO
	var inertia = -vel_norm * speed_ratio * (host.base_radius * 0.3)
	
	var n_push = _calculate_contact_push(n["pos"], active_deformations)
	n["pos"] = n["pos"].lerp(drift + inertia + n_push, delta * 4.0)

func _calculate_contact_push(organelle_pos: Vector2, active_deformations: Array[Dictionary]) -> Vector2:
	var push = Vector2.ZERO
	if active_deformations.is_empty():
		return push
		
	var org_dir = organelle_pos.normalized() if organelle_pos.length() > 0.1 else Vector2.ZERO
	for def in active_deformations:
		var similarity = org_dir.dot(def["direction"])
		if similarity > 0.3:
			push -= def["direction"] * def["intensity"] * host.base_radius * 0.15
	return push
