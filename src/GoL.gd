extends Node
class_name Simulation

@export_range(0, 512, 20, "0 = no limit")
var cap_fps : int = 0
@export
var wrap_borders : bool
enum init_state {NO_LIFE, RANDOM, WORLD}
@export
var init_with : init_state = init_state.NO_LIFE
@export
var init_world : Image

@export
var buffer_size = Vector2i(512, 288) # keep it 16:9 so the cells are displayed as squares
var shader_local_size_x := 16
var shader_local_size_y := 16

@export
var after_glow = 0.97
@export_range(0.25, 100.0, 0.25, "pointer radius in pixel/cells")
var pointer_radius = 1.0
var pointer_x = 128.0
var pointer_y = 72.0
var pointer_buttons = 0.0 # -1 when RMB pressed, 1 when LMB pressed, 0 for nothing


var rdmain := RenderingServer.get_rendering_device()
var textureRD: Texture2DRD # render texture to use the store the simulation results in
var shader : RID
var pipeline : RID
var fmt := RDTextureFormat.new()
var view := RDTextureView.new()
var input_buffer : RID
var output_buffer : RID

@export
var render_material := ShaderMaterial.new()

#@onready var screen_size := get_viewport().get_visible_rect().size
static var sim_paused :bool = false
var sim_step_forward :bool = false


func _input(event: InputEvent) -> void:
	pointer_buttons = 1.0 if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) else 0.0
	pointer_buttons = -1.0 if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) else pointer_buttons
	
	if event.is_action_released("pause_resume"):
		sim_paused = not sim_paused
	if event.is_action_released("step_forward"):
		sim_step_forward = true
	
	var screen_size := get_viewport().get_visible_rect().size
	
	if event is InputEventMouseMotion:
		pointer_x = (event.position.x / screen_size.x) * buffer_size.x
		pointer_y = (event.position.y / screen_size.y) * buffer_size.y


func _ready():
	Engine.max_fps = cap_fps
	
	if init_with == init_state.WORLD:
		buffer_size.x = init_world.get_width()
		buffer_size.y = init_world.get_height()
	
	# way better performance without scaling
	get_window().size = buffer_size
	
	fmt.width = buffer_size.x
	fmt.height = buffer_size.y
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	#fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	#fmt.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
					| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
					#| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
					| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	view = RDTextureView.new()
	textureRD = Texture2DRD.new()
	RenderingServer.call_on_render_thread(rebuild_buffers)

func _process(_delta):
	if not sim_paused or sim_step_forward:
		sim_step_forward = false
		RenderingServer.call_on_render_thread(run_simulation)

func _exit_tree():
	if textureRD:
		textureRD.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_free_compute_resources)


func rebuild_buffers():
	var empty_texture := Image.create_empty(
		buffer_size.x,
		buffer_size.y,
		false,
		Image.FORMAT_RGF
		#Image.FORMAT_RF
	)
	
	
	
	# INITIALIZE THE WORLD
	var color :Color = Color.BLACK
	for i in (buffer_size.x * buffer_size.y) - 1:
		var x :int= i % buffer_size.x
		@warning_ignore("integer_division")
		var y :int= i / buffer_size.x
		match init_with:
			init_state.RANDOM:
				color = Color(randi_range(0, 1), 0.0, 0.0, 0.0)
			init_state.WORLD:
				color = init_world.get_pixel(x, y)
		
		empty_texture.set_pixel(
			x, y,
			color
		)
	
	var data := empty_texture.get_data()
	input_buffer = rdmain.texture_create(fmt, RDTextureView.new(), [data])
	output_buffer = rdmain.texture_create(fmt, RDTextureView.new(), [data])
	
	# Output texture
	textureRD.texture_rd_rid = output_buffer

	# to see the first frame of the sim / the init world
	render_material.set_shader_parameter("buffer", textureRD)

	# SHADER + PIPELINE
	var shader_file := load("res://src/GoL.glsl") as RDShaderFile
	shader = rdmain.shader_create_from_spirv(shader_file.get_spirv())
	pipeline = rdmain.compute_pipeline_create(shader)


func run_simulation():
	# Flip buffers via uniformsets
	var frame_flip = flip_buffers()
	var input_set  = frame_flip[0]
	var output_set = frame_flip[1]
	
	# compute shader dispatching
	
	var global_size_x = int(ceil(float(buffer_size.x) / float(shader_local_size_x)))
	var global_size_y = int(ceil(float(buffer_size.y) / float(shader_local_size_y)))

	var compute_list := rdmain.compute_list_begin()
	rdmain.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rdmain.compute_list_bind_uniform_set(compute_list, input_set, 0)
	rdmain.compute_list_bind_uniform_set(compute_list, output_set, 1)
	
	
	# PUSH CONSTANT PARAMETERS
	var params := PackedFloat32Array(
		[
			after_glow,
			pointer_radius,
			pointer_x,
			pointer_y,
			pointer_buttons,
			buffer_size.x,
			buffer_size.y,
			wrap_borders
		]
	)

	var params_bytes := PackedByteArray()
	params_bytes.append_array(params.to_byte_array())
	rdmain.compute_list_set_push_constant(compute_list, params_bytes, params_bytes.size())

	# finish list and proceed to compute
	rdmain.compute_list_dispatch(compute_list, global_size_x, global_size_y, 1)
	rdmain.compute_list_end()

	# pass the render target texture to a shader uniform for displaying it
	render_material.set_shader_parameter("buffer", textureRD)
	render_material.set_shader_parameter("resolution", buffer_size);
	
	rdmain.free_rid(input_set)
	rdmain.free_rid(output_set)


var ping : bool = false
func flip_buffers():
	# Flip buffers
	ping = !ping
	var read_main  : RID
	var write_main : RID
	if ping:
		read_main  = output_buffer
		write_main = input_buffer
	else:
		read_main  = input_buffer
		write_main = output_buffer

	# use correct output image
	if textureRD:
		textureRD.texture_rd_rid = write_main
	
	# Create uniform sets
	var input_set  := _create_uniform_set(read_main, 0)
	var output_set := _create_uniform_set(write_main, 1)
	
	return [input_set,output_set]

func _create_uniform_set(texture_rd: RID, _uniform_set: int) -> RID:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(texture_rd)
	var new_set = [uniform]
	return rdmain.uniform_set_create(new_set, shader, _uniform_set)


func _free_compute_resources():
	if input_buffer:
		rdmain.free_rid(input_buffer)
	if output_buffer:
		rdmain.free_rid(output_buffer)
	if shader:
		rdmain.free_rid(shader)
	# TODO: consider other RIDs
