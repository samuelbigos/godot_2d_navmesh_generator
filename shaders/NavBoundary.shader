shader_type canvas_item;

uniform sampler2D u_input_tex;
uniform float u_dist_threshold = 0.0;

void fragment() 
{
	vec4 pix = texture(u_input_tex, UV);
	
	float far = 0.0;
	float close = 1.0;
	ivec2 v_far = ivec2(0);
	ivec2 v_close = ivec2(0);
	
	for(int x = -1; x <= 1; x++)
	{
		for(int y = -1; y <= 1; y++)
		{
			if(x == 0 || y == 0)
				continue;
			
			vec2 offset = vec2(float(x), float(y)) * SCREEN_PIXEL_SIZE * 0.5;
			vec4 sample = texture(u_input_tex, UV + offset);
			float sample_dist = sample.r;
			if(sample_dist > far)
			{
				far = sample_dist;
				v_far = ivec2(x, y);
			}			
			if(sample_dist < close)
			{
				close = sample_dist;
				v_close = ivec2(x, y);
			}
		}
	}
	
	if(u_dist_threshold < far && u_dist_threshold > close)
	{
		COLOR = vec4(1.0, 0.0, 0.7, 1.0);
	}
	else
	{
		if(pix.r > u_dist_threshold)
			COLOR = vec4(vec3(1.0), 1.0);
		else
			COLOR = vec4(vec3(0.0), 1.0);
	}
}