class_name BioluminescenceSystem
extends RefCounted

var host: CharacterBody2D
var current_luminescence: float = 0.0
var _bio_light: PointLight2D

func _init(p_host: CharacterBody2D) -> void:
	host = p_host
	_setup_light()

func _setup_light() -> void:
	_bio_light = PointLight2D.new()
	_bio_light.color = host.light_color
	_bio_light.energy = 0.0
	_bio_light.shadow_enabled = false 
	_bio_light.blend_mode = Light2D.BLEND_MODE_ADD

	var gradient = GradientTexture2D.new()
	var grad = Gradient.new()
	grad.set_color(0, Color.WHITE)
	grad.set_color(1, Color.TRANSPARENT)
	grad.set_offset(0, 0.0)
	grad.set_offset(1, 1.0)
	gradient.gradient = grad
	gradient.width = 256
	gradient.height = 256
	gradient.fill = GradientTexture2D.FILL_RADIAL
	gradient.fill_from = Vector2(0.5, 0.5)
	gradient.fill_to = Vector2(0.5, 0.0)

	_bio_light.texture = gradient
	_bio_light.texture_scale = host.light_scale_idle
	host.add_child(_bio_light)

func process_luminescence(delta: float, target_intensity: float) -> void:
	current_luminescence = lerp(current_luminescence, target_intensity, delta * 2.0)
	
	if _bio_light:
		_bio_light.energy = lerpf(_bio_light.energy, current_luminescence * host.light_energy_max, delta * 3.0)
		var scale_targ = lerpf(host.light_scale_idle, host.light_scale_active, current_luminescence)
		_bio_light.texture_scale = lerpf(_bio_light.texture_scale, scale_targ, delta * 3.0)

func get_luminescence() -> float:
	return current_luminescence
