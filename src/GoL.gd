extends Node
class_name Simulation

@export_range(0, 512, 20, "0 = no limit")
var cap_fps : int = 0
@export
var wrap_borders : bool
enum init_state {NO_LIFE, RANDOM, PATTERN}
@export
var init_with : init_state = init_state.NO_LIFE
#@export
#var world : Image
@export_file("*.rle") var rle_world : String

@export
var buffer_size = Vector2i(512, 288) # keep it 16:9 so the cells are displayed as squares
var shader_local_size_x := 16
var shader_local_size_y := 16

@export
var after_glow = 0.97
@export_range(0.25, 100.0, 0.25, "pointer radius in pixel/cells")
var pointer_radius = 1.0
var pointer
var pointer_buttons = 0.0 # -1 when RMB pressed, 1 when LMB pressed, 0 for nothing

var window_aspect_ratio:
	get: return Vector2(get_window().size) / minf(get_window().size.x, get_window().size.y)

var normalized_window_aspect_ratio:
	get: return Vector2(get_window().size) / maxf(get_window().size.x, get_window().size.y)
 
var max_zoom:
	get: return minf(normalized_window_aspect_ratio.x, normalized_window_aspect_ratio.y)

var zoom_amount := 1.0:
	set(value):
		#zoom_amount = clamp(value, 0.05, max_zoom)
		zoom_amount = clamp(value, 0.05, 1.0)
		render_material.set_shader_parameter("zoom", zoom_amount)

var zoom_pos := Vector2(0.5, 0.5):
	set(value):
		zoom_pos = value
		zoom_pos.x = clamp(value.x, 0., 1.)
		zoom_pos.y = clamp(value.y, 0., 1.)
		#zoom_pos.x = clamp(value.x, 0., 1.0 * normalized_window_aspect_ratio.y)
		#zoom_pos.y = clamp(value.y, 0., 1.0 * normalized_window_aspect_ratio.x)
		render_material.set_shader_parameter("zoom_center", zoom_pos)

@export var zoom_speed := 1.0
@export var pan_speed := 1.0
var zoom_smoothing:
	get:
		return (zoom_speed * pow(zoom_amount, 1.3))

var rdmain := RenderingServer.get_rendering_device()
var textureRD: Texture2DRD # render texture to use the store the simulation results in
var shader : RID
var pipeline : RID
var view := RDTextureView.new()
var input_buffer : RID
var output_buffer : RID

@export
var render_material := ShaderMaterial.new()

static var sim_paused :bool = true
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
		pointer = (((event.position / screen_size) * window_aspect_ratio - zoom_pos) * zoom_amount + zoom_pos) * Vector2(buffer_size)
		
		# pan the view with middle mouse drag
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			zoom_pos -= ((event.relative / screen_size) * window_aspect_ratio) * zoom_amount * pan_speed
	
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_pos = (((event.position / screen_size) * window_aspect_ratio - zoom_pos) * zoom_amount + zoom_pos)
			zoom_amount -= 0.05 * zoom_smoothing
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_pos = (((event.position / screen_size) * window_aspect_ratio - zoom_pos) * zoom_amount + zoom_pos)
			zoom_amount += 0.05 * zoom_smoothing

func _ready():
	Engine.max_fps = cap_fps
	
	#zoom_amount = max_zoom
	
	view = RDTextureView.new()
	textureRD = Texture2DRD.new()
	RenderingServer.call_on_render_thread(build_buffers)

func _process(_delta):
	if not sim_paused or sim_step_forward:
		sim_step_forward = false
		RenderingServer.call_on_render_thread(run_simulation)

func _exit_tree():
	if textureRD:
		textureRD.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_free_compute_resources)

const B_CHAR = "b"
func init_world() -> Image:
	var world_texture := Image.create_empty(
		buffer_size.x,
		buffer_size.y,
		false,
		Image.FORMAT_RGF
		#Image.FORMAT_RF
	)
	
	match init_with:
		init_state.NO_LIFE: # simulation starts with every cell being dead
			world_texture.fill(Color.BLACK);
		init_state.RANDOM: # simulation starts with each cell being in a random state
			for i in (buffer_size.x * buffer_size.y) - 1:
				var x :int= i % buffer_size.x
				@warning_ignore("integer_division")
				var y :int= i / buffer_size.x
				world_texture.set_pixel(x, y, Color(randi_range(0, 1), 0.0, 0.0, 0.0))
		init_state.PATTERN: # simulation starts with cell states loaded from a pattern file (.rle)
				# I'm gonna use RegEx to decode the RLEs, it's not the fastest but perhaps the simplest
				# way to do this. I am aware that there are more performant ways to decode run legth files
				var content  = FileAccess.open(rle_world, FileAccess.READ).get_as_text()
				var pattern_size : Vector2i
				# finds digits of any length '\d+' after 'x = '
				var pattern_size_regex = RegEx.create_from_string(r'(?<=x = )\d+')
				pattern_size.x = int(pattern_size_regex.search(content).get_string())
				# finds digits of any length '\d+' after 'y = '
				pattern_size_regex.compile(r'(?<=y = )\d+')
				pattern_size.y = int(pattern_size_regex.search(content).get_string())
				
				# match lines starting with # or x
				# those are the comments and the header lines 
				var not_data = RegEx.create_from_string(r'#.+\s|x.+\n|\n')
				var data : String = not_data.sub(content, "", true) # strip away the comments and the header
				
				# the pattern should fit inside the world
				print("Pattern Size: ", pattern_size)
				print("Buffer Size: ", buffer_size)
				
				# place the pattern at the center of the world
				var pattern_pos : Vector2i = (buffer_size / 2) - (pattern_size / 2)
				world_texture.fill(Color.BLACK)

				var pixel_index_in_row : int = 0
				# any number of digits followed by any one of these characters b o $ !
				var run_length = RegEx.create_from_string(r'\d*[bo\$!]')
				for r in run_length.search_all(data):
					
					# the integer number before the symbol is a multiplier of it's occurance
					# if there's no number before the symbol it means the occurance multiplier is 1
					var length : int = int(r.get_string())
					if r.get_string().length() == 1: length = 1
					
					# the $ symbol means go to the next row
					if r.get_string().ends_with("$"):
						pattern_pos.y += length
						pixel_index_in_row = 0
						continue
					
					# o means alive and b means dead
					var dead : bool = r.get_string().ends_with(B_CHAR)
					if dead:
						pixel_index_in_row += length
					else:
						for i in range(length):
							world_texture.set_pixel(pattern_pos.x + pixel_index_in_row, pattern_pos.y, 
							Color.WHITE)
							pixel_index_in_row += 1
	
	return world_texture


func build_buffers():
	var world_texture := init_world()
	var data := world_texture.get_data()
	var fmt := RDTextureFormat.new()
	#if init_with == init_state.IMAGE:
		#buffer_size.x = world_texture.get_width()
		#buffer_size.y = world_texture.get_height()
	
	fmt.width = buffer_size.x
	fmt.height = buffer_size.y
	fmt.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	#fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
					| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
					| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	
	input_buffer = rdmain.texture_create(fmt, RDTextureView.new(), [data])
	output_buffer = rdmain.texture_create(fmt, RDTextureView.new(), [data])
	
	# Output texture
	textureRD.texture_rd_rid = output_buffer

	# to see the first frame of the sim / the init world
	render_material.set_shader_parameter("buffer", textureRD)
	render_material.set_shader_parameter("zoom_center", zoom_pos)
	render_material.set_shader_parameter("zoom", zoom_amount)
	#render_material.set_shader_parameter("zoom_correction", corrective_zoom)	
	render_material.set_shader_parameter("resolution", get_window().size)
	
	
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
			pointer.x,
			pointer.y,
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
	render_material.set_shader_parameter("resolution", get_window().size) # buffer_size)
	
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
