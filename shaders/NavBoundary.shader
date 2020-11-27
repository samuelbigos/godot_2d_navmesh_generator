shader_type canvas_item;

uniform sampler2D u_input_tex;
uniform float u_dist_threshold = 0.0;

void fragment() 
{
	vec4 pix = texture(u_input_tex, UV);
	pix /= 2.0;
	
	float threshold = u_dist_threshold / (1.0 / SCREEN_PIXEL_SIZE.y);
	if(pix.r > threshold)
		COLOR = vec4(vec3(0.0), 1.0);
	else
		COLOR = vec4(vec3(1.0), 1.0);
}