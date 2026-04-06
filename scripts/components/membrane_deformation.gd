class_name MembraneDeformation
extends RefCounted

var host: CharacterBody2D
var active_deformations: Array[Dictionary] = [] # [{"direction": Vector2, "intensity": float}]

func _init(p_host: CharacterBody2D) -> void:
	host = p_host

func process_deformations(delta: float) -> void:
	# 1. Springback decay
	var i = active_deformations.size() - 1
	while i >= 0:
		active_deformations[i]["intensity"] -= delta * host.deformation_springback
		if active_deformations[i]["intensity"] <= 0.0:
			active_deformations.remove_at(i)
		i -= 1
	
	# 2. Inject new collisions safely
	for ci in range(host.get_slide_collision_count()):
		var collision = host.get_slide_collision(ci)
		var contact_dir = -collision.get_normal()
		
		# Combine similar directions to cap max arrays and improve efficiency
		var merged = false
		for def in active_deformations:
			if def["direction"].dot(contact_dir) > 0.9:
				def["intensity"] = clampf(def["intensity"] + delta * 15.0, 0.0, 1.0)
				def["direction"] = def["direction"].lerp(contact_dir, 0.3).normalized()
				merged = true
				break
		
		if not merged:
			active_deformations.append({
				"direction": contact_dir,
				"intensity": 0.6
			})

# CPU getter for shader parsing or inner organelle push computations
func get_active_deformations() -> Array[Dictionary]:
	return active_deformations

func get_contact_indent_at(dir: Vector2) -> float:
	var total_indent = 0.0
	for def in active_deformations:
		var similarity = dir.dot(def["direction"])
		if similarity > 0.0:
			var falloff = pow(similarity, host.deformation_spread)
			total_indent += falloff * def["intensity"]
	return clampf(total_indent, 0.0, 1.0) * host.base_radius * host.deformation_max_indent
