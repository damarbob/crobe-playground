class_name CellLocomotion
extends RefCounted

var host: CharacterBody2D
var _pre_slide_velocity: Vector2 = Vector2.ZERO

func _init(p_host: CharacterBody2D) -> void:
	host = p_host

func process_movement(delta: float) -> void:
	var input_dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	host.velocity = host.velocity.lerp(input_dir * host.move_speed, delta * host.fluid_friction)
	_pre_slide_velocity = host.velocity
	host.move_and_slide()

func process_push_impulses() -> void:
	if _pre_slide_velocity.length() < 1.0:
		return
		
	for ci in range(host.get_slide_collision_count()):
		var collision = host.get_slide_collision(ci)
		var collider = collision.get_collider()
		
		# Momentum-based Elastic Collision rule
		if collider is RigidBody2D:
			var normal = collision.get_normal()
			var impact_speed = max(-_pre_slide_velocity.dot(normal), 0.0)
			
			if impact_speed < 1.0:
				continue
			
			var combined_mass = host.cell_mass + collider.mass
			var impulse_magnitude = (2.0 * host.cell_mass * collider.mass / combined_mass) * impact_speed * host.push_efficiency
			
			collider.apply_central_impulse(-normal * impulse_magnitude)

func get_pre_slide_velocity() -> Vector2:
	return _pre_slide_velocity
