shader_type canvas_item;

uniform sampler2D buffer : filter_nearest, repeat_disable;
uniform ivec2 resolution; // draw the grid with this
uniform vec3 color : source_color = vec3(0.8);


vec3 hsv2rgb(vec3 c)
{
	vec4 k = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + k.xyz) * 6.0 - k.www);
	return c.z * mix(k.xxx, clamp(p - k.xxx, 0.0, 1.0), c.y);
}

void fragment()
{
	vec2 cell = texture(buffer, UV).rg;
	vec3 c = vec3(hsv2rgb(vec3(mod(0.8 * TIME + 0.7, 1.0), (1.0 - cell.g), cell.g)));
	COLOR.rgb = c;
	//COLOR.rgb = color * cell.g;
}