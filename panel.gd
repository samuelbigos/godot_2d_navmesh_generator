extends Control
tool


const VoronoiSeedMat = preload("./shaders/VoronoiSeed.tres")
const JumpFloodPassMat = preload("./shaders/JumpFloodPass.tres")
const DistanceFieldMat = preload("./shaders/DistanceField.tres")
const NavBoundaryMat = preload("./shaders/NavBoundary.tres")

var swap_rtts = []
var current_swap = 0
var poly_to_edit = null


func setup(object):
	poly_to_edit = object
	$Viewport.render_target_update_mode = Viewport.UPDATE_DISABLED
	$SwapA.render_target_update_mode = Viewport.UPDATE_DISABLED
	$SwapB.render_target_update_mode = Viewport.UPDATE_DISABLED
	swap_rtts.append(get_node("SwapA"))
	swap_rtts.append(get_node("SwapB"))
	
func get_rtt():
	var ret =  swap_rtts[current_swap]
	current_swap = (current_swap + 1) % 2
	return ret

func generate():
	var viewport_size = Vector2(512, 512)
	var input = $Viewport
	var preview = $HSplitContainer/HSplitContainer/TextureRect
	
	var scene_tree = get_tree().get_edited_scene_root()
	var collision_shape_list = []
	get_all_nodes_recursive("CollisionShape2D", scene_tree, collision_shape_list)
	var collision_polygon_list = []
	get_all_nodes_recursive("CollisionPolygon2D", scene_tree, collision_polygon_list)
	
	for node in collision_shape_list:
		print(node)
		
	for node in collision_polygon_list:
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
	tex.material.set_shader_param("u_dist_threshold", 0.01)
	
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
	for x in range(0, width - 1):
		boundary_data.append([])
		for y in range(0, height - 1):
			var pixel = image.get_pixel(x, y)
			if pixel == Color("ffffff"):
				boundary_data[x].append(0)
			elif pixel == Color("000000"):
				boundary_data[x].append(2)
			else:
				boundary_data[x].append(1)
	
	var boundary_data_used = []
	for x in range(0, width - 1):
		boundary_data_used.append([])
		for y in range(0, height - 1):
			boundary_data_used[x].append(0)
			
	var vec_arrays = []
	
	# for every pixel in the image
	for x in range(0, width - 1):
		for y in range(0, height - 1):
			
			if boundary_data_used[x][y] == 1:
				continue
			
			# check if that pixel is on a boundary, and if so, generate a vector array of that boundary.
			if boundary_data[x][y] == 1:
				var vec_array = gen_verts_from_start(Vector2(x, y), width, height, boundary_data, boundary_data_used)
				for vert in vec_array:
					mark_used(vert, boundary_data_used)
					
				vec_arrays.append(vec_array)
					
	poly_to_edit.clear_outlines()
	poly_to_edit.clear_polygons()
	for vec_array in vec_arrays:
		poly_to_edit.add_outline(vec_array)
	poly_to_edit.make_polygons_from_outlines()
	
func gen_verts_from_start(real_start, width, height, boundary_data, boundary_data_used):
	var vec_array = PoolVector2Array()
	var current = real_start
	for i in range(0, 9999):
		var start = Vector2(-1, -1)
		if i > 2:
			start = real_start
			
		var next = find_next_pixel(current, start, 1, true, width, height, boundary_data, boundary_data_used)
		if next == start:
			break
			
		if next == current:
			print("Failed to find an unused neighbor. [%d, %d]" % [current.x, current.y])
			next = find_next_pixel(current, start, 2, false, width, height, boundary_data, boundary_data_used)
			
		boundary_data_used[current.x][current.y] = 1
		boundary_data_used[next.x][next.y] = 1
		vec_array.append(next)
		current = next
		
	return vec_array
	
func find_next_pixel(current, start, search_range, cardinal, width, height, boundary_data, boundary_data_used):
	
	for x in range(-search_range, search_range + 1):
		for y in range(-search_range, search_range + 1):
			
			var offset = current + Vector2(x, y)
			if offset == start:
				return start
			
			if x == 0 and y == 0:
				continue
			if cardinal and (x != 0 and y != 0):
				continue
			if offset.x <= 0 or offset.x >= width:
				continue
			if offset.y <= 0 or offset.y >= height:
				continue
			if boundary_data_used[offset.x][offset.y] == 1:
				continue
			if boundary_data[offset.x][offset.y] != 1:
				continue
			
			return offset
			
	return current
		
func print_output(boundary_data):
	var output_string = ""
	for x in range(0, boundary_data.size() - 1):
		for y in range(0, boundary_data[x].size() - 1):
			output_string += "%d" % boundary_data[y][x]
		output_string += "\n"
		
	print(output_string)
	
func mark_used(coord, boundary_data_used):
	for x in range(-1, 2):
		for y in range(-1, 2):
			var offset = coord + Vector2(x, y)
			boundary_data_used[offset.x][offset.y] = 1
			
func get_all_nodes_recursive(type, tree, array):
	for child in tree.get_children():
		if child.get_class() == type:
			array.append(child)
			continue
		
		get_all_nodes_recursive(type, child, array)

func _on_Button_pressed():
	generate()
