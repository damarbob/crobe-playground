extends Node2D

const BackgroundFluidScript = preload("res://scripts/background_fluid.gd")
const PostProcessingScript = preload("res://scripts/post_processing.gd")
const AmbientMicrobeScript = preload("res://scripts/ambient_microbe.gd")

# ==========================================
# Procedural Generation Parameters (Microscopic Biome)
# ==========================================
@export_group("Map Configuration")
@export var map_radius: float = 4000.0
@export var spawn_density: int = 500

@export_group("Entity Scenes")
@export var obstacle_scene: PackedScene ## Obstacle.tscn
@export var organic_debris_scene: PackedScene ## OrganicDebris.tscn

@export_group("Fluid Physics Characteristics")
@export var fluid_linear_damping: float = 8.0
@export var fluid_angular_damping: float = 10.0

@export_group("Biome Palette")
@export var obstacle_color_deep: Color = Color(0.05, 0.12, 0.08, 0.9)
@export var obstacle_color_shallow: Color = Color(0.12, 0.22, 0.15, 0.8)
@export var debris_color_warm: Color = Color(0.8, 0.55, 0.15, 0.85)
@export var debris_color_cool: Color = Color(0.5, 0.65, 0.25, 0.8)

@export_group("Ambient Life")
@export var ambient_microbe_count: int = 300
@export var ambient_depth_debris_count: int = 80 ## Extra defocused debris for visual depth

var terrain_noise: FastNoiseLite
var nutrient_noise: FastNoiseLite
var color_noise: FastNoiseLite # Biome-zone color variation

func _ready() -> void:
	PhysicsServer2D.area_set_param(get_viewport().find_world_2d().space, PhysicsServer2D.AREA_PARAM_GRAVITY, 0.0)

	_initialize_noise()
	_generate_microbiome()
	_spawn_ambient_life()
	_spawn_depth_debris()
	_setup_ambient_layers()

func _setup_ambient_layers() -> void:
	# Background fluid medium (CanvasLayer -100: behind everything)
	var bg_fluid = BackgroundFluidScript.new()
	add_child(bg_fluid)

	# Post-processing microscope optics (CanvasLayer 100: on top of everything)
	var post_process = PostProcessingScript.new()
	add_child(post_process)

func _initialize_noise() -> void:
	terrain_noise = FastNoiseLite.new()
	terrain_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	terrain_noise.seed = randi()
	terrain_noise.frequency = 0.002
	terrain_noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE

	nutrient_noise = FastNoiseLite.new()
	nutrient_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	nutrient_noise.seed = randi()
	nutrient_noise.frequency = 0.005

	color_noise = FastNoiseLite.new()
	color_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	color_noise.seed = randi()
	color_noise.frequency = 0.001 # Large-scale biome zones

func _generate_microbiome() -> void:
	for i in range(spawn_density):
		var angle = randf() * TAU
		var radius = sqrt(randf()) * map_radius
		var spawn_pos = Vector2(cos(angle), sin(angle)) * radius

		var terrain_val = terrain_noise.get_noise_2d(spawn_pos.x, spawn_pos.y)
		var nutrient_val = nutrient_noise.get_noise_2d(spawn_pos.x, spawn_pos.y)

		if terrain_val > 0.6:
			_spawn_obstacle(spawn_pos, terrain_val)
		elif terrain_val < -0.2 and nutrient_val > 0.4:
			_spawn_organic_debris(spawn_pos, nutrient_val)

# ==========================================
# Instantiation with Biome Variation
# ==========================================

func _spawn_obstacle(pos: Vector2, scale_factor: float) -> void:
	if not obstacle_scene:
		push_error("MicrobiomeGenerator: obstacle_scene is not assigned!")
		return
	var obstacle = obstacle_scene.instantiate()
	obstacle.position = pos
	obstacle.base_size = 50.0 + (scale_factor * 100.0)
	obstacle.sides = randi_range(5, 8)
	obstacle.rotation = randf() * TAU

	# Biome-zone color variation
	var zone = color_noise.get_noise_2d(pos.x, pos.y) * 0.5 + 0.5 # 0..1
	obstacle.color_primary = obstacle_color_deep.lerp(obstacle_color_shallow, zone)
	obstacle.color_secondary = obstacle.color_primary.lightened(0.15)
	obstacle.color_secondary.a = 0.35

	# Per-instance parameter variation
	obstacle.grain_intensity = randf_range(0.1, 0.2)
	obstacle.internal_vein_count = randi_range(2, 5)
	obstacle.membrane_thickness = randf_range(1.5, 3.0)
	obstacle.sway_amplitude = randf_range(1.5, 4.0)
	obstacle.sway_speed = randf_range(0.15, 0.4)

	add_child(obstacle)

func _spawn_organic_debris(pos: Vector2, richness: float) -> void:
	if not organic_debris_scene:
		push_error("MicrobiomeGenerator: organic_debris_scene is not assigned!")
		return
	var debris = organic_debris_scene.instantiate()
	debris.position = pos
	debris.radius = 10.0 + (richness * 20.0)
	debris.is_bubble = richness > 0.7
	debris.fluid_linear_damping = fluid_linear_damping
	debris.fluid_angular_damping = fluid_angular_damping

	# Biome-zone color variation
	var zone = color_noise.get_noise_2d(pos.x, pos.y) * 0.5 + 0.5
	if not debris.is_bubble:
		debris.color_organic = debris_color_warm.lerp(debris_color_cool, zone)
	else:
		# Bubbles: subtle blue variation
		var blue_shift = randf_range(0.0, 0.15)
		debris.color_bubble_rim = Color(0.65 + blue_shift, 0.82 + blue_shift * 0.5, 1.0, randf_range(0.25, 0.4))

	# Per-instance parameter randomization (desync animations)
	debris.pulse_speed = randf_range(1.0, 2.5)
	debris.pulse_amount = randf_range(0.03, 0.08)
	debris.brownian_force = randf_range(4.0, 12.0)

	# Depth layering — most debris near focal plane, some drift out of focus
	debris.z_depth = randf_range(-0.3, 0.3) # Mild defocus range for interactive debris

	# Decomposition lifecycle (60-180s) — bubbles are immortal
	if not debris.is_bubble:
		debris.decomposition_lifetime = randf_range(60.0, 180.0)

	add_child(debris)

# ==========================================
# Ambient Microbe Spawning
# ==========================================

func _spawn_ambient_life() -> void:
	## Populate the world with passive, non-physics micro-organisms
	## at various scales and types for visual density.
	var types = [
		{"type": 0, "weight": 0.45, "size_range": [2.0, 5.0],
		 "color": Color(0.4, 0.5, 0.35, 0.45)}, # Bacteria
		{"type": 1, "weight": 0.2, "size_range": [4.0, 8.0],
		 "color": Color(0.35, 0.55, 0.4, 0.5)}, # Flagellate
		{"type": 2, "weight": 0.15, "size_range": [6.0, 12.0],
		 "color": Color(0.5, 0.6, 0.45, 0.45)}, # Ciliate
		{"type": 3, "weight": 0.2, "size_range": [5.0, 10.0],
		 "color": Color(0.5, 0.65, 0.7, 0.25)}, # Diatom
	]

	for i in range(ambient_microbe_count):
		var angle = randf() * TAU
		var dist = sqrt(randf()) * map_radius
		var pos = Vector2(cos(angle), sin(angle)) * dist

		# Weighted random type selection
		var roll = randf()
		var cumulative = 0.0
		var chosen = types[0]
		for t in types:
			cumulative += t["weight"]
			if roll <= cumulative:
				chosen = t
				break

		var microbe = AmbientMicrobeScript.new()
		microbe.type = chosen["type"]
		microbe.microbe_size = randf_range(chosen["size_range"][0], chosen["size_range"][1])
		microbe.global_position = pos

		# Biome color variation
		var zone = color_noise.get_noise_2d(pos.x, pos.y) * 0.5 + 0.5
		microbe.base_color = chosen["color"].lerp(chosen["color"].lightened(0.15), zone)

		# Depth layering for ambient microbes (wide range — many will be out of focus)
		var depth = randf_range(-0.9, 0.9)
		var defocus = abs(depth)
		microbe.modulate.a *= lerpf(1.0, 0.2, defocus)
		microbe.scale *= lerpf(1.0, 0.6, defocus)
		microbe.z_index = int(depth * 10)

		add_child(microbe)

func _spawn_depth_debris() -> void:
	## Spawn extra defocused, non-collidable debris purely for visual depth.
	## These exist behind or in front of the focal plane as ghostly blobs.
	if not organic_debris_scene:
		return

	for i in range(ambient_depth_debris_count):
		var angle = randf() * TAU
		var dist = sqrt(randf()) * map_radius
		var pos = Vector2(cos(angle), sin(angle)) * dist

		var debris = organic_debris_scene.instantiate()
		debris.position = pos
		debris.radius = randf_range(8.0, 25.0)
		debris.is_bubble = randf() > 0.85
		debris.fluid_linear_damping = fluid_linear_damping
		debris.fluid_angular_damping = fluid_angular_damping

		# Strong defocus — these are clearly out of the focal plane
		debris.z_depth = randf_range(-0.9, -0.5) if randf() > 0.5 else randf_range(0.5, 0.9)

		# Biome color variation
		var zone = color_noise.get_noise_2d(pos.x, pos.y) * 0.5 + 0.5
		if not debris.is_bubble:
			debris.color_organic = debris_color_warm.lerp(debris_color_cool, zone)

		debris.pulse_speed = randf_range(0.8, 2.0)
		debris.pulse_amount = randf_range(0.04, 0.1)
		debris.brownian_force = randf_range(3.0, 8.0)

		add_child(debris)
