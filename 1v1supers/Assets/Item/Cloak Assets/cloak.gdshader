/*
void light() and corresponding variables and functions by (c) CaptainProton42's 
Flexible Toon Shader under the MIT license 

the rest was added by kmitt91; void fragment() + void vertex() and corresponding variables
*/

shader_type spatial;

render_mode blend_mix, cull_disabled, depth_prepass_alpha;

// PI is built-in in Godot 4, keep custom under different name for legacy code
const float CUSTOM_PI = 3.14159;

uniform vec4 color : source_color;
uniform sampler2D cape_texture : source_color;
uniform sampler2D normalmap_texture : hint_normal;
uniform sampler2D noise_texture : hint_default_black; 


// variables from CaptainProton42

uniform bool clamp_diffuse_to_max = false;

uniform int cuts : hint_range(1, 8) = 3;
uniform float wrap : hint_range(-2.0f, 2.0f) = 0.0f;
uniform float steepness : hint_range(1.0f, 8.0f) = 1.4f;

uniform bool use_attenuation = true;

uniform bool use_specular = true;
uniform float specular_strength : hint_range(0.0f, 1.0f) = 1.0f;
uniform float specular_shininess : hint_range(0.0f, 32.0f) = 16.0f;
uniform sampler2D specular_map : source_color;

uniform bool use_rim = true;
uniform float rim_width : hint_range(0.0f, 16.0f) = 8.0f;
uniform vec4 rim_color : source_color = vec4(1.0f);

uniform bool use_ramp = false;
uniform sampler2D ramp : source_color;

uniform bool use_borders = false;
uniform float border_width = 0.01;

// end from CaptainProton42 variables


uniform float strength = 0.07;
uniform float speed = 0.22;

void vertex() {
	// Smooth wind using two noise octaves + sine to avoid flicker
	vec2 uv_a = UV * 0.65 + vec2(TIME * speed * 0.22, TIME * speed * 0.04);
	vec2 uv_b = UV * 1.4 + vec2(4.7, 2.3) + vec2(TIME * speed * 0.12, -TIME * speed * 0.06);
	float n1 = texture(noise_texture, uv_a).r;
	float n2 = texture(noise_texture, uv_b).r;
	float noise = mix(n1, n2, 0.4);
	// Smoothstep to remove harsh flicker
	noise = smoothstep(0.28, 0.72, noise);
	float displacement = (noise * 2.0 - 1.0) * strength;
	// Height gradient - top (UV.y ~0) stays, bottom waves. Use pow for smooth falloff
	float height_factor = pow(clamp(UV.y, 0.0, 1.0), 1.35);
	displacement *= height_factor;
	// Gentle sine sway to add base motion and hide noise pops
	displacement += sin(TIME * 0.7 + UV.y * 2.5) * strength * 0.18 * height_factor;
	// Apply with slight forward bias to keep cape behind body and reduce clipping
	VERTEX.x += displacement;
	VERTEX.z += displacement * 0.45 - abs(displacement) * 0.15;
}


void fragment() {
	vec4 cape = texture(cape_texture, UV);
	ALBEDO = color.rgb * cape.rgb;
	ALPHA = color.a * cape.a;
	// No emission - ensure cloak does not glow
	EMISSION = vec3(0.0);
	// Fix normal map decoding (texture is 0..1, NORMAL_MAP expects -1..1)
	vec3 nmap = texture(normalmap_texture, UV).rgb;
	NORMAL_MAP = nmap * 2.0 - 1.0;
	// Alpha scissor to avoid sorting flicker on soft edges
	ALPHA_SCISSOR_THRESHOLD = 0.08;
}



// functions from CaptainProton42

float staircase(int n, float x) {
	float res = 0.0f;
	float inc = 1.0f / float(n+1);
	for (float edge = 0.0f; edge < 1.0f - inc; edge+=inc) {
		res += step(edge, x);
	}
	return res / float(n);
}

float split_diffuse(float diffuse) {
	return staircase(cuts, diffuse * steepness);
}

float split_specular(float specular) {
	return step(0.5f, specular);
}


void light() {
	// Attenuation.
	float attenuation = 1.0f;
	if (use_attenuation) {
		attenuation = ATTENUATION;
	}
	
	// Diffuse lighting.
	float NdotL = dot(NORMAL, LIGHT);
	float diffuse_amount = NdotL + (attenuation - 1.0) + wrap;
	//float diffuse_amount = NdotL * attenuation + wrap;
	diffuse_amount *= steepness;
	float cuts_inv = 1.0f / float(cuts);
	float diffuse_stepped = clamp(diffuse_amount + mod(1.0f - diffuse_amount, cuts_inv), 0.0f, 1.0f);

	// Calculate borders.
	float border = 0.0f;
	if (use_borders) {
		float corr_border_width = length(cross(NORMAL, LIGHT)) * border_width * steepness;
		border = step(diffuse_stepped - corr_border_width, diffuse_amount)
				 - step(1.0 - corr_border_width, diffuse_amount);
	}
	
	// Apply diffuse result to different styles.
	vec3 diffuse = ALBEDO.rgb * LIGHT_COLOR / PI;
	if (use_ramp) {
		diffuse *= texture(ramp, vec2(diffuse_stepped * (1.0f - border), 0.0f)).rgb;
	} else {
		diffuse *= diffuse_stepped * (1.0f - border);
	}
	
	if (clamp_diffuse_to_max) {
		// Clamp diffuse to max for multiple light sources.
		DIFFUSE_LIGHT = max(DIFFUSE_LIGHT, diffuse);
	} else {
		DIFFUSE_LIGHT += diffuse;
	}
	
	// Specular lighting.
	if (use_specular) {
		vec3 H = normalize(LIGHT + VIEW);
		float NdotH = dot(NORMAL, H);
		float specular_amount = max(pow(NdotH, specular_shininess*specular_shininess), 0.0f)
							    * texture(specular_map, UV).r
								* attenuation;
		specular_amount = split_specular(specular_amount);
		SPECULAR_LIGHT += specular_strength * specular_amount * LIGHT_COLOR;
	}
	
	// Simple rim lighting.
	if (use_rim) {
		float NdotV = dot(NORMAL, VIEW);
		float rim_light = pow(1.0 - NdotV, rim_width);
		DIFFUSE_LIGHT += rim_light * rim_color.rgb * rim_color.a * LIGHT_COLOR / PI;
	}
}