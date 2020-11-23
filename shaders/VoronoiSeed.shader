shader_type canvas_item;

uniform sampler2D u_input_tex;

void fragment() 
{
	// for the voronoi seed texture we just store the UV of the pixel if the pixel is part
	// of an object (emissive or occluding), or black otherwise.
	vec4 scene_col = texture(u_input_tex, UV);
	scene_col.a = floor(scene_col.a + 0.5);
	COLOR = vec4(UV.x * scene_col.a, UV.y * scene_col.a, 0.0, 1.0);
}