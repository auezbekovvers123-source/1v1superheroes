shader_type spatial;
// World-space health bar: a quad that always faces the camera and draws its own fill.
render_mode unshaded, cull_disabled, shadows_disabled;

uniform float fill : hint_range(0.0, 1.0) = 1.0;
uniform vec4 fill_color : source_color = vec4(0.18, 1.0, 0.35, 0.95);
uniform vec4 back_color : source_color = vec4(0.08, 0.08, 0.08, 0.82);
// Border thickness in UV units (x, y); the bar is wide, so y needs a larger value.
uniform vec2 border = vec2(0.02, 0.18);

void vertex() {
	// Billboard: keep the node's position, take the orientation from the camera.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0],
		INV_VIEW_MATRIX[1],
		INV_VIEW_MATRIX[2],
		MODEL_MATRIX[3]);
}

void fragment() {
	vec2 inner = (UV - border) / (vec2(1.0) - border * 2.0);
	bool inside = inner.x >= 0.0 && inner.x <= 1.0 && inner.y >= 0.0 && inner.y <= 1.0;
	vec4 c = (inside && inner.x <= fill) ? fill_color : back_color;
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
