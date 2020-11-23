tool
extends EditorPlugin


const EditPanel = preload("./panel.tscn")


var panel = null
var nav_poly_to_edit = null


func _enter_tree():
	pass

func _exit_tree():
	pass

func handles(object):
	if object.is_class("NavigationPolygon"):
		return true
	return false 

func edit(object):
	nav_poly_to_edit = object

func make_visible(visible):
	if visible and panel == null:
		panel = EditPanel.instance()
		add_control_to_bottom_panel(panel, "Nav2DGen")
		panel.setup(nav_poly_to_edit)
	elif panel != null:
		remove_control_from_bottom_panel(panel)
		panel.free()
