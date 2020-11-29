extends Control
tool


const VoronoiSeedMat = preload("./shaders/VoronoiSeed.tres")
const JumpFloodPassMat = preload("./shaders/JumpFloodPass.tres")
const DistanceFieldMat = preload("./shaders/DistanceField.tres")
const NavBoundaryMat = preload("./shaders/NavBoundary.tres")

const V_RIGHT = Vector2(1, 0)
const V_LEFT = Vector2(-1, 0)
const V_UP = Vector2(0, -1)
const V_DOWN = Vector2(0, 1)

var swap_rtts = []
var current_swap = 0
var poly_to_edit = null
var generate_clicked = false
var generating = false
var did_populate = false
var vector_arrays = []
var node_pool = []
var nodes_used = 0
var space_offset
var worker_thread = null
var worker_complete = false

var gpu_progress = 0.0
var worker_progress = 0.0
var polygon_progress = 0.0
var total_progress = 0.0

var worker_progress_mutex = null

onready var viewport = get_node("Viewport")
onready var viewport_preview = get_node("HSplitter/VBoxLeft/Preview")
onready var swap_a = get_node("SwapA")
onready var swap_b = get_node("SwapB")

onready var gui_agentradius_slider = get_node("HSplitter/VBoxLeft/AgentRadius/HSlider")
onready var gui_agentradius_value = get_node("HSplitter/VBoxLeft/AgentRadius/Value")
onready var gui_excludegroup_value = get_node("HSplitter/VBoxLeft/ExcludeGroup/LineEdit")
onready var gui_smoothing_slider = get_node("HSplitter/VBoxLeft/Smoothing/HSlider")
onready var gui_smoothing_value = get_node("HSplitter/VBoxLeft/Smoothing/Value")
onready var gui_simplify_slider = get_node("HSplitter/VBoxLeft/Simplify/HSlider")
onready var gui_simplify_value = get_node("HSplitter/VBoxLeft/Simplify/Value")

onready var gui_generate_button = get_node("HSplitter/VBoxRIght/HBoxContainer/GenerateButton")
onready var gui_generate_progressbar = get_node("HSplitter/VBoxRIght/HBoxContainer/ProgressBar")
onready var gui_infolabel = get_node("HSplitter/VBoxRIght/Panel/InfoLabel")


func setup(object):
	poly_to_edit = object
	viewport.render_target_update_mode = Viewport.UPDATE_DISABLED
	swap_a.render_target_update_mode = Viewport.UPDATE_DISABLED
	swap_b.render_target_update_mode = Viewport.UPDATE_DISABLED
	swap_rtts.append(swap_a)
	swap_rtts.append(swap_b)
	reset()
	_on_Welcome_pressed()
		
func reset():
	for child in viewport.get_children():
		child.queue_free()
		viewport.remove_child(child)
		
	node_pool.clear()
	for i in range(0, 100):
		var node = Node2D.new()
		node_pool.append(node)
		viewport.add_child(node)
		
	nodes_used = 0
	generating = false
	worker_progress = 0.0
	gpu_progress = 0.0
	polygon_progress = 0.0
	total_progress = 0.0
	if worker_progress_mutex:
		worker_progress_mutex.unlock()
	if worker_thread:
		worker_thread.wait_to_finish()
	worker_thread = null
	worker_progress_mutex = null
	worker_complete = false
	vector_arrays = []
	
func get_rtt():
	var ret =  swap_rtts[current_swap]
	current_swap = (current_swap + 1) % 2
	return ret
	
func _process(delta):
	if generate_clicked:
		generate();
		generate_clicked = false
		generating = true
		
	if generating:
		var cpu_progress = 0.0
		if worker_progress_mutex != null and worker_thread != null:
			worker_progress_mutex.lock()
			cpu_progress = worker_progress
			worker_progress_mutex.unlock()
		
		gui_generate_progressbar.value = ((gpu_progress * 0.1) + (cpu_progress * 0.8) + (polygon_progress * 0.1)) * gui_generate_progressbar.max_value
		
		if worker_complete:
			finish_gen()
			gui_generate_progressbar.value = ((gpu_progress * 0.1) + (cpu_progress * 0.8) + (polygon_progress * 0.1)) * gui_generate_progressbar.max_value
			reset()
	
	if gui_agentradius_slider:
		gui_agentradius_value.text = "%d" % gui_agentradius_slider.value
		
	if gui_smoothing_slider:
		gui_smoothing_value.text = "%.2f" % gui_smoothing_slider.value
		
	if gui_simplify_slider:
		gui_simplify_value.text = "%.2f" % gui_simplify_slider.value
		
func generate():
	
	var input = viewport
	viewport_preview.flip_v = true
	var agent_radius = gui_agentradius_slider.value
	var exclude_group = gui_excludegroup_value.text
	
	var scene_tree = get_tree().get_edited_scene_root()
	var collision_shape_list = []
	get_all_nodes_recursive("CollisionShape2D", scene_tree, collision_shape_list)
	var collision_polygon_list = []
	get_all_nodes_recursive("CollisionPolygon2D", scene_tree, collision_polygon_list)
	
	var first = true
	var space_min = Vector2()
	var space_max = Vector2()
	
	for node in collision_shape_list:
		if not node.visible:
			continue
		if node.is_in_group(exclude_group):
			continue
			
		var collision_shape = node as CollisionShape2D
		var shape = collision_shape.shape as Shape2D
		var shape_canvas = node_pool[nodes_used]
		nodes_used += 1
		shape_canvas.transform = collision_shape.global_transform
		shape.draw(shape_canvas.get_canvas_item(), Color.black)
		
		var radius = 0.0
		if shape.is_class("CapsuleShape2D"):
			var s = shape as CapsuleShape2D
			radius = s.height * 0.5 + s.radius
		elif shape.is_class("CircleShape2D"):
			var s = shape as CircleShape2D
			radius = s.radius
		elif shape.is_class("ConcavePolygonShape2D"):
			var s = shape as ConcavePolygonShape2D
			for vert in s.segments:
				radius = max(radius, vert.length())
		elif shape.is_class("ConvexPolygonShape2D"):
			var s = shape as ConvexPolygonShape2D
			for vert in s.points:
				radius = max(radius, vert.length())
		elif shape.is_class("LineShape2D"):
			printerr("LineShape2D is not supported.")
		elif shape.is_class("RayShape2D"):
			printerr("RayShape2D is not supported.")
		elif shape.is_class("RectangleShape2D"):
			var s = shape as RectangleShape2D
			radius = s.extents.length()
		elif shape.is_class("SegmentShape2D"):
			var s = shape as SegmentShape2D
			radius = max(s.a.length(), s.b.length())
		else:
			printerr("Unknown shape!")
			
		var pos = shape_canvas.global_position
		if first:
			space_min = pos - Vector2(radius, radius)
			space_max = pos + Vector2(radius, radius)
			first = false
		else:
			space_min.x = min(space_min.x, pos.x - radius)
			space_min.y = min(space_min.y, pos.y - radius)
			space_max.x = max(space_max.x, pos.x + radius)
			space_max.y = max(space_max.y, pos.y + radius)
		
	for node in collision_polygon_list:
		if not node.visible:
			continue
		if node.is_in_group(exclude_group):
			continue
			
		var polygon = Polygon2D.new()
		polygon.polygon = (node as CollisionPolygon2D).polygon
		polygon.transform = (node as CollisionPolygon2D).global_transform
		input.add_child(polygon)
		
		var radius = 0.0
		for vert in polygon.polygon:
			radius = max(radius, vert.length())
		
		var pos = polygon.global_position
		if first:
			space_min = pos - Vector2(radius, radius)
			space_max = pos + Vector2(radius, radius)
			first = false
		else:
			space_min.x = min(space_min.x, pos.x - radius)
			space_min.y = min(space_min.y, pos.y - radius)
			space_max.x = max(space_max.x, pos.x + radius)
			space_max.y = max(space_max.y, pos.y + radius)
		
	var margin = Vector2(100, 100) + Vector2(agent_radius, agent_radius)
	var viewport_size = space_max - space_min + margin
	viewport_size.x = int(max(viewport_size.x, viewport_size.y))
	viewport_size.y = int(viewport_size.x)
	space_offset = space_min - (margin * 0.5)
	
	var camera_transform = Transform2D(Vector2(1.0, 0.0), Vector2(0.0, 1.0), -space_offset)
	input.canvas_transform = camera_transform
	
	var space = PoolVector2Array()
	space.append(space_offset + Vector2(0.0, 0.0))
	space.append(space_offset + Vector2(viewport_size.x, 0.0))
	space.append(space_offset + Vector2(viewport_size.x, viewport_size.y))
	space.append(space_offset + Vector2(0.0, viewport_size.y))
	
	poly_to_edit.clear_outlines()
	poly_to_edit.clear_polygons()
	poly_to_edit.add_outline(space)
	poly_to_edit.make_polygons_from_outlines()
	
	viewport_preview.rect_size = viewport_size
	gpu_progress = 0.1
				
	input.size = viewport_size
	input.render_target_update_mode = Viewport.UPDATE_ONCE
	input.update_worlds()
	
	yield(get_tree(), "idle_frame")
	viewport_preview.texture = input.get_texture()
	gpu_progress = 0.2
	yield(get_tree(), "idle_frame")
	
	for child in input.get_children():
		child.queue_free()
		input.remove_child(child)
	
	var rtt = get_rtt()
	var tex = rtt.get_node("TextureRect")
	tex.rect_size = viewport_size
	tex.material = VoronoiSeedMat.duplicate(true)
	tex.material.set_shader_param("u_input_tex", input.get_texture())
	rtt.size = viewport_size
	rtt.render_target_update_mode = Viewport.UPDATE_ONCE
	rtt.update_worlds()
	
	yield(get_tree(), "idle_frame")
	viewport_preview.texture = rtt.get_texture()
	gpu_progress = 0.3
	yield(get_tree(), "idle_frame")	
	
	var passes = ceil(log(max(viewport_size.x, viewport_size.y)) / log(2.0))
	for i in range(0, passes):
		var offset = pow(2, passes - i - 1)
		var input_texture = rtt.get_texture()
		
		rtt = get_rtt()
		tex = rtt.get_node("TextureRect")
	
		tex.rect_size = viewport_size
		tex.material = JumpFloodPassMat.duplicate(true)
		tex.material.set_shader_param("u_level", i)
		tex.material.set_shader_param("u_max_steps", passes)
		tex.material.set_shader_param("u_offset", offset)
		tex.material.set_shader_param("u_input_tex", input_texture)
		
		rtt.size = viewport_size
		rtt.render_target_update_mode = Viewport.UPDATE_ONCE
		rtt.update_worlds()
		
		yield(get_tree(), "idle_frame")
		viewport_preview.texture = rtt.get_texture()
		gpu_progress = 0.3 + (float(i) / float(passes)) * 0.6
		yield(get_tree(), "idle_frame")
	
	var voronoi_output = rtt.get_texture()
	rtt = get_rtt()
	tex = rtt.get_node("TextureRect")
	tex.rect_size = viewport_size
	tex.material = DistanceFieldMat.duplicate(true)
	tex.material.set_shader_param("u_input_tex", voronoi_output)
	
	rtt.render_target_update_mode = Viewport.UPDATE_ONCE
	rtt.update_worlds()
	
	yield(get_tree(), "idle_frame")
	gpu_progress = 0.9
	viewport_preview.texture = rtt.get_texture()
	yield(get_tree(), "idle_frame")
	
	var distance_field = rtt.get_texture()
	var prev_rtt_vflip = rtt.render_target_v_flip
	rtt = get_rtt()
	tex = rtt.get_node("TextureRect")
	tex.rect_size = viewport_size
	tex.material = NavBoundaryMat.duplicate(true)
	tex.material.set_shader_param("u_input_tex", distance_field)
	tex.material.set_shader_param("u_dist_threshold", agent_radius)
	
	rtt.render_target_update_mode = Viewport.UPDATE_ONCE
	rtt.update_worlds()
	
	yield(get_tree(), "idle_frame")
	gpu_progress = 1.0
	viewport_preview.texture = rtt.get_texture()
	yield(get_tree(), "idle_frame")
	
	var image = rtt.get_texture().get_data()
	image.flip_y()
	var width = image.get_width()
	var height = image.get_height()
	image.lock()
	
	var boundary_data = []
	for x in range(0, width):
		boundary_data.append([])
		for y in range(0, height):
			var pixel = image.get_pixel(x, y)
			if pixel == Color("000000"):
				boundary_data[x].append(0)
			else:
				boundary_data[x].append(1)
			
	var vec_arrays = []
	
	var worker_data = {}
	worker_data["width"] = width
	worker_data["height"] = height
	worker_data["data"] = boundary_data
	worker_data["output"] = vec_arrays
	worker_data["self"] = self
	worker_progress_mutex = Mutex.new()
	worker_thread = Thread.new()
	worker_thread.start(self, "worker_job", worker_data)
	worker_complete = false
	
func finish_gen():
	for vec_array in vector_arrays:
		for i in range(0, vec_array.size()):
			vec_array[i] += space_offset
		poly_to_edit.add_outline(vec_array)
		
	poly_to_edit.make_polygons_from_outlines()
	polygon_progress = 1.0
	
func worker_complete(data):
	vector_arrays = data
	worker_complete = true
	
func worker_progress(progress):
	worker_progress_mutex.lock()
	worker_progress = progress
	worker_progress_mutex.unlock()
	
func worker_job(worker_data):
	var width = worker_data["width"]
	var height = worker_data["width"]
	var boundary_data = worker_data["data"]
	var vec_arrays = worker_data["output"]
	var parent_self = worker_data["self"]
		
	# for every pixel in the image
	for x in range(0, width):
		for y in range(0, height):
			
			# check if that pixel is on a boundary, and if so, generate a vector array of that boundary.
			if boundary_data[x][y] == 1:
				var vec_array = gen_verts_from_start(Vector2(x, y), width, height, boundary_data)
				
				var curve = Curve2D.new()
				for i in range(0, vec_array.size()):
					var c0 = Vector2(0.0, 0.0)
					var c1 = Vector2(0.0, 0.0)
					if i > 0:
						c0 = (vec_array[i - 1] - vec_array[i]) * 1.0
					if i < vec_array.size() - 1:
						c1 = (vec_array[i + 1] - vec_array[i]) * 1.0
					curve.add_point(vec_array[i], c0, c1)
				
				var interval_min = 1.5
				var interval_max = 7.5
				curve.bake_interval = lerp(interval_min, interval_max, gui_smoothing_slider.value)
				
				var new_path := PoolVector2Array()
				var baked_length = curve.get_baked_length()
				var offset = 0.0
				var step = 2.0
				while offset < baked_length - (step * 2.0):
					new_path.append(curve.interpolate_baked(offset, true))
					offset += step
			
				vec_arrays.append(optimise_boundary(new_path))
			
			var progress = float((float(x * height) + float(y)) / float(width * height))
			parent_self.worker_progress(progress)
				
	parent_self.worker_complete(vec_arrays)
	
func gen_verts_from_start(start, width, height, data):
	
	var vec_array = PoolVector2Array()
	var dir = Vector2()
	
	# get the initial direction to crawl the edge, always go clockwise
	if query(start + Vector2(-1, 0), data) == 0:
		dir = V_UP
		
	if query(start + Vector2(0, -1), data) == 0:
		dir = V_RIGHT
		
	if query(start + Vector2(1, 0), data) == 0:
		dir = V_DOWN
		
	if query(start + Vector2(0, 1), data) == 0:
		dir = V_LEFT
	
	var maxrange = 99999
	var current = start
	for i in range(0, maxrange):
		
		var last = current
		var error = false
		
		# up: [0][1]
		if dir == V_UP:

			# turn right
			if query(current + Vector2(-1, -1), data) == 0 and query(current + Vector2(0, -1), data) == 0:
				dir = V_RIGHT
			# turn left
			elif query(current + Vector2(-1, -1), data) == 1:
				dir = V_LEFT
				current = current + Vector2(-1, -1)
			# continue up
			elif query(current + Vector2(-1, -1), data) == 0 and query(current + Vector2(0, -1), data) == 1:
				dir = V_UP
				current = current + Vector2(0, -1)
			else:
				printerr("up - something went wrong.")
				error = true
			
		# right:
		# [0]
		# [1]
		elif dir == V_RIGHT:
			# turn down
			if query(current + Vector2(1, -1), data) == 0 and query(current + Vector2(1, 0), data) == 0:
				dir = V_DOWN
			# turn up
			elif query(current + Vector2(1, -1), data) == 1:
				dir = V_UP
				current = current + Vector2(1, -1)
			# continue right
			elif query(current + Vector2(1, -1), data) == 0 and query(current + Vector2(1, 0), data) == 1:
				dir = V_RIGHT
				current = current + Vector2(1, 0)
			else:
				printerr("right - something went wrong.")
				error = true
				
		# down: [1][0]
		elif dir == V_DOWN:
			# turn left
			if query(current + Vector2(0, 1), data) == 0 and query(current + Vector2(1, 1), data) == 0:
				dir = V_LEFT
			# turn right
			elif query(current + Vector2(1, 1), data) == 1:
				dir = V_RIGHT
				current = current + Vector2(1, 1)
			# continue down
			elif query(current + Vector2(0, 1), data) == 1 and query(current + Vector2(1, 1), data) == 0:
				dir = V_DOWN
				current = current + Vector2(0, 1)
			else:
				printerr("down - something went wrong.")
				error = true
			
		# left:
		# [1]
		# [0]
		elif dir == V_LEFT:
			# turn up
			if query(current + Vector2(-1, 0), data) == 0 and query(current + Vector2(-1, 1), data) == 0:
				dir = V_UP
			# turn down
			elif query(current + Vector2(-1, 1), data) == 1:
				dir = V_DOWN
				current = current + Vector2(-1, 1)
			elif query(current + Vector2(-1, 0), data) == 1 and query(current + Vector2(-1, 1), data) == 0:
				dir = V_LEFT
				current = current + Vector2(-1, 0)
			else:
				printerr("left - something went wrong.")
				error = true
				
		if error:
			print("%d pre - [%d, %d] - [%d, %d]" % [i, current.x, current.y, dir.x, dir.y])
			break
				
		if current != last:
			vec_array.append(current)
			
		# if we got back round to the start, finish.
		# it's possible the first pixel doesn't move us, so make sure we moved a bit first.
		if current == start and i > 1:
			break
			
	# remove this shape from data so we don't process it again
	flood_fill(start, data)
		
	return vec_array
	
func optimise_boundary(boundary):
	var threshold_min = 0.95
	var threshold_max = 0.99999
	var threshold = lerp(threshold_min, threshold_max, 1.0 - pow(gui_simplify_slider.value, 2))
	var size = boundary.size()
	var new = []
	var i = 0
	while true:
		if i >= size - 1:
			break
			
		new.append(boundary[i])
		var v_a = boundary[i]
		i += 1
		var v_b = boundary[i]
		var dir_a = (v_b - v_a).normalized()
		
		for j in range(i, size - 1):
			v_a = boundary[j]
			v_b = boundary[j + 1]
			var dir_b = (v_b - v_a).normalized()
			var dot = dir_a.dot(dir_b)
			i = j
			if dot < threshold:
				break

	return new
	
func query(coord, data):
	return data[coord.x][coord.y]
	
func flood_fill(coord, data):
	if data[coord.x][coord.y] == 0: return
	data[coord.x][coord.y] = 0
	var queue = []
	queue.append(coord)
	while queue.size() > 0:
		var node = queue.pop_front()
		var xy = node + Vector2(0, 1)
		if data[xy.x][xy.y] == 1:
			data[xy.x][xy.y] = 0
			queue.append(xy)
		xy = node + Vector2(0, -1)
		if data[xy.x][xy.y] == 1:
			data[xy.x][xy.y] = 0
			queue.append(xy)
		xy = node + Vector2(1, 0)
		if data[xy.x][xy.y] == 1:
			data[xy.x][xy.y] = 0
			queue.append(xy)
		xy = node + Vector2(-1, 0)
		if data[xy.x][xy.y] == 1:
			data[xy.x][xy.y] = 0
			queue.append(xy)

func print_output(data):
	var output_string = ""
	for x in range(0, data.size() - 1):
		for y in range(0, data[x].size() - 1):
			output_string += "%d" % data[y][x]
		output_string += "\n"
		
	print(output_string)
	
func get_all_nodes_recursive(type, tree, array):
	for child in tree.get_children():
		if child.get_class() == type:
			array.append(child)
			continue
		
		get_all_nodes_recursive(type, child, array)

func shutdown():
	if worker_progress_mutex:
		worker_progress_mutex.unlock()
	if worker_thread:
		worker_thread.wait_to_finish()
	
func _exit_tree():
	if worker_progress_mutex:
		worker_progress_mutex.unlock()
	if worker_thread:
		worker_thread.wait_to_finish()
	
func _on_Button_pressed():
	generate_clicked = true

func _on_AgentRadiusInfo_pressed():
	gui_infolabel.bbcode_text = "[color=#6a9dea]Agent Radius[/color]\n"
	gui_infolabel.bbcode_text += "Defines amount of padding the navmesh is generated with. Generally you will set this to the max radius of entities you're doing navigation on, but you could also create a separate navmesh for each entity type."

func _on_ExcludeGroupInfo_pressed():
	gui_infolabel.bbcode_text = "[color=#6a9dea]Exclude Group[/color]\n"
	gui_infolabel.bbcode_text += "Any collision shapes/polygons in this group will be ignored when generating the navmesh."

func _on_SmoothingInfo_pressed():
	gui_infolabel.bbcode_text = "[color=#6a9dea]Smoothing[/color]\n"
	gui_infolabel.bbcode_text += "Defines amount of smoothing done to the navmesh boundary. Higher values will give smoother tracking around corners but will lose finer detail. In general, you want more smoothing when using a higher agent radius."

func _on_SimplifyInfo_pressed():
	gui_infolabel.bbcode_text = "[color=#6a9dea]Simplify[/color]\n"
	gui_infolabel.bbcode_text += "Defines the threshold used when optimising the amount of vertices in the navmesh. Higher values will remove more verts; lowering detail, but increasing performance."

func _on_GenerateInfo_pressed():
	gui_infolabel.bbcode_text = "[color=#6a9dea]Generate[/color]\n"
	gui_infolabel.bbcode_text += "Generate the navmesh from all collision objects in the open scene, using settings on the left.\n"

func _on_Welcome_pressed():
	gui_infolabel.bbcode_text = "[color=#6a9dea]v0.1 Alpha - Welcome[/color]\n"
	gui_infolabel.bbcode_text += "REMEMBER! This is an alpha version, issues are expected. Please report problems on the GitHub page: https://github.com/samuelbigos/godot_2d_navmesh_generator\n"
	gui_infolabel.bbcode_text += "\n"
	gui_infolabel.bbcode_text += "[color=#aaaaaa]Quick-start:[/color]\n"
	gui_infolabel.bbcode_text += "  1. Make sure there are some collision nodes (CollisionShape2D or CollisionPolygon2D) in your scene.\n"
	gui_infolabel.bbcode_text += "  2. Tweak settings on the left. Click on the info buttons to see what they do.\n"
	gui_infolabel.bbcode_text += "  3. Click Generate and wait a bit.\n"
	gui_infolabel.bbcode_text += "\n"
	gui_infolabel.bbcode_text += "[color=#aaaaaa]Known issues and Gotchas:[/color]\n"
	gui_infolabel.bbcode_text += "  * 'Holes' in topology are not supported (yet). This means if you have a donut shape, the hole will be filled in. The solution for now is to leave a gap somewhere (and make it big enough for your agent width), then fill in the gap manually. \n"
	gui_infolabel.bbcode_text += "  * After generating, re-select the NavigationPolygonInstance node a few times in the editor to bring up the polygon editing interface. \n"
	gui_infolabel.bbcode_text += "  * Settings are not saved and will reset to default when re-selecting the node. \n"
	gui_infolabel.bbcode_text += "  * Generation time cost increases with square of scene size, which can be unoptimal for large scenes. Try and split your scenes up into multiple navmeshes if possible.\n"
	gui_infolabel.bbcode_text += "  * Works better if most straight lines are axis-aligned. This is because the scene is rasterized before being converted to a mesh, and diagonal lines introduce aliasing. \n"
	gui_infolabel.bbcode_text += "  * Only tested on Godot 3.2.3 and GLES3, might not work on other versions. \n"
