extends CharacterBody2D

# ==========================================
# Parameters Noctiluca Crobiaris (Player)
# ==========================================
@export_group("Physics & Cell Shape")
@export var base_radius: float = 50.0
@export var pulse_speed: float = 1.0
@export var ripple_ratio: float = 0.1
@export var ripple_frequency: float = 0.005 
@export var ripple_complexity: int = 2  
@export var active_ripple_multiplier: float = 1.5
@export var max_stretch: float = 0.3
@export var rotation_smoothness: float = 6.0 
@export_range(8, 256) var cell_segments: int = 64
@export_range(8, 128) var collision_segments: int = 32

@export_group("Player Controls")
@export var move_speed: float = 220.0
@export var fluid_friction: float = 3.5

@export_group("Bioluminescence")
@export var color_idle: Color = Color(0.0, 0.2, 0.5, 0.5) 
@export var color_active: Color = Color(0.4, 1.0, 0.9, 0.9) 

@export_group("Internal Anatomy")
@export var nucleus_stiffness: float = 0.5 
@export var nucleus_ripple_factor: float = 0.2 
@export var nucleus_rotational_inertia: float = 0.1 
@export_range(0.0, 1.0) var nucleus_opacity: float = 1.0
@export var nucleus_structural_offset: float = 25.0 # How far back the nucleus rests
@export var fiber_count: int = 14
@export var fiber_opacity: float = 0.35
@export var fiber_segments: int = 6

@export_group("Anomalous Morphology")
@export var tail_length: float = 180.0
@export_range(4, 128) var tail_segments: int = 24
@export var tail_wobble_speed: float = 8.0
@export var tail_wobble_amp: float = 20.0
@export var tail_base_width: float = 8.0
@export_range(5.0, 90.0) var tail_max_bend_angle: float = 30.0
@export var tail_straightening_speed: float = 3.0

@export_group("Contact Deformation")
@export var deformation_max_indent: float = 0.35
@export var deformation_springback: float = 6.0
@export var deformation_spread: float = 3.5

@export_group("Physical Interaction")
@export var cell_mass: float = 5.0
@export_range(0.0, 1.0) var push_efficiency: float = 0.7

@export_group("Bioluminescence Light")
@export var light_energy_max: float = 1.5 
@export var light_scale_idle: float = 0.8
@export var light_scale_active: float = 2.5
@export var light_color: Color = Color(0.3, 0.9, 0.8, 1.0)

var time_passed: float = 0.0

# ------------------------------------------
# Modular Architecture (SRP)
# ------------------------------------------
var _locomotion: CellLocomotion
var _deformation: MembraneDeformation
var _biolum: BioluminescenceSystem
var _organelles: OrganelleManager
var _renderer: MembraneRenderer
var _collision_poly: CollisionPolygon2D

func _ready() -> void:
	# Initialize Collision Polygon for dynamic deformation
	_collision_poly = get_node_or_null("CollisionPolygon2D")
	if not _collision_poly:
		_collision_poly = CollisionPolygon2D.new()
		_collision_poly.name = "CollisionPolygon2D"
		add_child(_collision_poly)
	
	# Disable old static collision shape if it exists
	var col_node = get_node_or_null("CollisionShape2D")
	if col_node:
		col_node.disabled = true
		col_node.visible = false
		
	# Initialize SOLID components
	_locomotion = CellLocomotion.new(self)
	_deformation = MembraneDeformation.new(self)
	_biolum = BioluminescenceSystem.new(self)
	_organelles = OrganelleManager.new(self)
	_renderer = MembraneRenderer.new(self, _organelles, _biolum, _deformation)

func _physics_process(delta: float) -> void:
	time_passed += delta
	
	_locomotion.process_movement(delta)
	_deformation.process_deformations(delta)
	_locomotion.process_push_impulses()
	
	var speed_ratio = velocity.length() / move_speed
	
	_biolum.process_luminescence(delta, speed_ratio if speed_ratio > 0.1 else 0.0)
	_organelles.process_drift(delta, time_passed, speed_ratio, _deformation.get_active_deformations())
	_renderer.process_rendering(delta, time_passed)
	_sync_collision_polygon()
	
	queue_redraw()

func _sync_collision_polygon() -> void:
	if _renderer and _collision_poly:
		var pts = _renderer.get_membrane_points(time_passed, collision_segments)
		_collision_poly.polygon = pts

func _draw() -> void:
	if _renderer:
		_renderer.draw_cell(time_passed)
