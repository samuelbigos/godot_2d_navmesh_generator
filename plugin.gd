tool
extends EditorPlugin


const EditPanel = preload("./2d_navmesh_generator.tscn")

var panel = null
var nav_poly_to_edit = null


func handles(object):
	if object.is_class("NavigationPolygon"):
		return true
	return false 

func edit(object):
	nav_poly_to_edit = object

func make_visible(visible):
	if visible and not is_instance_valid(panel):
		panel = EditPanel.instance()
		add_control_to_bottom_panel(panel, "NavmeshGen")
		panel.setup(nav_poly_to_edit)
	elif is_instance_valid(panel):
		remove_control_from_bottom_panel(panel)
		panel.shutdown()
		panel.queue_free()

func _exit_tree():
	if panel != null:
		remove_control_from_bottom_panel(panel)
		panel.shutdown()
		panel.queue_free()
