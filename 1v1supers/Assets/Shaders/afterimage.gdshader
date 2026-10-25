shader_type spatial;
// Super speed afterimage: a see-through phantom of the runner that glows at its
// silhouette's edges. `fade` runs from 1 to 0 as it disappears.
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;

uniform vec3 color : source_color = vec3(1.0, 0.6, 0.15);
uniform float fade : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.5);
	ALBEDO = color * (0.4 + 1.6 * rim);
	ALPHA = fade * (0.3 + 0.7 * rim);
}
