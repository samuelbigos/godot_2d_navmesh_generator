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
var did_populate = false
var node_pool = []
var nodes_used = 0


func setup(object):
	poly_to_edit = object
	$Viewport.render_target_update_mode = Viewport.UPDATE_DISABLED
	$SwapA.render_target_update_mode = Viewport.UPDATE_DISABLED
	$SwapB.render_target_update_mode = Viewport.UPDATE_DISABLED
	swap_rtts.append(get_node("SwapA"))
	swap_rtts.append(get_node("SwapB"))
	
	for i in range(0, 100):
		var node = Node2D.new()
		node_pool.append(node)
		$Viewport.add_child(node)
	
func get_rtt():
	var ret =  swap_rtts[current_swap]
	current_swap = (current_swap + 1) % 2
	return ret
	
func _process(delta):
	if generate_clicked:
		generate()
		generate_clicked = false
		
	$HBoxContainer/VBoxContainer/AgentRadius/Label2.text = "%d" % $HBoxContainer/VBoxContainer/AgentRadius/HSlider.value
		
func generate():
	var viewport_size = Vector2(512, 512)
	var input = $Viewport
	var preview = $HBoxContainer/TextureRect
	preview.rect_size = Vector2(128, 128)
	var agent_radius = $HBoxContainer/VBoxContainer/AgentRadius/HSlider.value
	
	var scene_tree = get_tree().get_edited_scene_root()
	var collision_shape_list = []
	get_all_nodes_recursive("CollisionShape2D", scene_tree, collision_shape_list)
	var collision_polygon_list = []
	get_all_nodes_recursive("CollisionPolygon2D", scene_tree, collision_polygon_list)
	
	for node in collision_shape_list:
		if not node.visible:
			continue
			
		var collision_shape = node as CollisionShape2D
		var shape = collision_shape.shape as Shape2D
		var shape_canvas = node_pool[nodes_used]
		nodes_used += 1
		shape_canvas.transform = collision_shape.transform
		shape.draw(shape_canvas.get_canvas_item(), Color.black)
		
	for node in collision_polygon_list:
		if not node.visible:
			continue
			
		var polygon = Polygon2D.new()
		polygon.polygon = (node as CollisionPolygon2D).polygon
		polygon.transform = (node as CollisionPolygon2D).transform
		input.add_child(polygon)
			
	input.size = viewport_size
	input.render_target_update_mode = Viewport.UPDATE_ONCE
	input.update_worlds()
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
	
	preview.texture = input.get_texture()
	
	for child in input.get_children():
		print(child)
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
	yield(get_tree(), "idle_frame")
	
	preview.texture = rtt.get_texture()
	
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
		yield(get_tree(), "idle_frame")
	
		preview.texture = rtt.get_texture()
	
	var voronoi_output = rtt.get_texture()
	rtt = get_rtt()
	tex = rtt.get_node("TextureRect")
	tex.rect_size = viewport_size
	tex.material = DistanceFieldMat.duplicate(true)
	tex.material.set_shader_param("u_input_tex", voronoi_output)
	
	rtt.render_target_update_mode = Viewport.UPDATE_ONCE
	rtt.update_worlds()
	yield(get_tree(), "idle_frame")
	yield(get_tree(), "idle_frame")
		
	preview.texture = rtt.get_texture()

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
	yield(get_tree(), "idle_frame")
	
	preview.texture = rtt.get_texture()
	
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
	
	# for every pixel in the image
	for x in range(0, width):
		for y in range(0, height):
			
			# check if that pixel is on a boundary, and if so, generate a vector array of that boundary.
			if boundary_data[x][y] == 1:
				var vec_array = gen_verts_from_start(Vector2(x, y), width, height, boundary_data)
				vec_arrays.append(vec_array)
		
	poly_to_edit.clear_outlines()
	poly_to_edit.clear_polygons()
	for vec_array in vec_arrays:
		poly_to_edit.add_outline(vec_array)
	poly_to_edit.make_polygons_from_outlines()
	
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
		
	#print(start)
	#print(dir)
	#data[start.x][start.y] = 5
	#print_output(data)
	
	var maxrange = 999
	var current = start
	for i in range(0, maxrange):
		
		var last = current
		
		#print("%d pre - [%d, %d] - [%d, %d]" % [i, current.x, current.y, dir.x, dir.y])

		# up: [0][1]
		if dir == V_UP:

			# turn right
			if query(current + Vector2(-1, -1), data) == 0 and query(current + Vector2(0, -1), data) == 0:
				dir = V_RIGHT
			# turn left
			elif query(current + Vector2(-1, -1), data) == 1 and query(current + Vector2(0, -1), data) == 1:
				dir = V_LEFT
				current = current + Vector2(-1, -1)
			# continue up
			elif query(current + Vector2(-1, -1), data) == 0 and query(current + Vector2(0, -1), data) == 1:
				dir = V_UP
				current = current + Vector2(0, -1)
			else:
				printerr("up - something went wrong.")
			
		# right:
		# [0]
		# [1]
		elif dir == V_RIGHT:
			# turn down
			if query(current + Vector2(1, -1), data) == 0 and query(current + Vector2(1, 0), data) == 0:
				dir = V_DOWN
			# turn up
			elif query(current + Vector2(1, -1), data) == 1 and query(current + Vector2(1, 0), data) == 1:
				dir = V_UP
				current = current + Vector2(1, -1)
			# continue right
			elif query(current + Vector2(1, -1), data) == 0 and query(current + Vector2(1, 0), data) == 1:
				dir = V_RIGHT
				current = current + Vector2(1, 0)
			else:
				printerr("right - something went wrong.")
				
		# down: [1][0]
		elif dir == V_DOWN:
			# turn left
			if query(current + Vector2(0, 1), data) == 0 and query(current + Vector2(1, 1), data) == 0:
				dir = V_LEFT
			# turn right
			elif query(current + Vector2(0, 1), data) == 1 and query(current + Vector2(1, 1), data) == 1:
				dir = V_RIGHT
				current = current + Vector2(1, 1)
			# continue down
			elif query(current + Vector2(0, 1), data) == 1 and query(current + Vector2(1, 1), data) == 0:
				dir = V_DOWN
				current = current + Vector2(0, 1)
			else:
				printerr("down - something went wrong.")
			
		# left:
		# [1]
		# [0]
		elif dir == V_LEFT:
			# turn up
			if query(current + Vector2(-1, 0), data) == 0 and query(current + Vector2(-1, 1), data) == 0:
				dir = V_UP
			# turn down
			elif query(current + Vector2(-1, 0), data) == 1 and query(current + Vector2(-1, 1), data) == 1:
				dir = V_DOWN
				current = current + Vector2(-1, 1)
			elif query(current + Vector2(-1, 0), data) == 1 and query(current + Vector2(-1, 1), data) == 0:
				dir = V_LEFT
				current = current + Vector2(-1, 0)
			else:
				printerr("left - something went wrong.")
				
		if current != last:
			vec_array.append(current)
			
		if current == start:
			break
			
		#print("%d post - [%d, %d] - [%d, %d]" % [i, current.x, current.y, dir.x, dir.y])
		
		#data[current.x][current.y] = 5
		#if i == (maxrange - 1):
		#	data[current.x][current.y] = 3
		#	print_output(data)
			
	# remove this shape from data so we don't process it again
	flood_fill(start, data)
	#print_output(data)
		
	return vec_array
	
func query(coord, data):
	return data[coord.x][coord.y]
	
func flood_fill(coord, data):
	if data[coord.x][coord.y] == 0:
		return
	data[coord.x][coord.y] = 0
	flood_fill(coord + Vector2(0, 1), data)
	flood_fill(coord + Vector2(0, -1), data)
	flood_fill(coord + Vector2(1, 0), data)
	flood_fill(coord + Vector2(-1, 0), data)

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

func _on_Button_pressed():
	generate_clicked = true
