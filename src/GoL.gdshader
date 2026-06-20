shader_type canvas_item;

uniform sampler2D buffer : filter_nearest;
uniform ivec2 resolution; // draw the grid with this
uniform vec3 color : source_color = vec3(0.8);

uniform float zoom = 1.0;
uniform vec2 zoom_center = vec2(0.5);

vec3 hsv2rgb(vec3 c)
{
	vec4 k = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + k.xyz) * 6.0 - k.www);
	return c.z * mix(k.xxx, clamp(p - k.xxx, 0.0, 1.0), c.y);
}

void fragment()
{
	vec2 aspect_ratio = vec2(resolution) / float(min(resolution.x, resolution.y));
	
	vec2 uv = clamp((UV * aspect_ratio - zoom_center) * zoom + zoom_center, vec2(0.), vec2(1.));
	//vec2 uv = (UV * aspect_ratio - zoom_center * aspect_ratio) * zoom * zoom_correction + zoom_center * aspect_ratio;
	vec2 cell = texture(buffer, uv).rg;
	COLOR.rgb = color * cell.g;
	//COLOR.rg = fract(uv);
	//vec3 c = vec3(hsv2rgb(vec3(mod(0.8 * TIME + 0.7, 1.0), (1.0 - cell.g), cell.g)));
	//COLOR.rgb = c;
}