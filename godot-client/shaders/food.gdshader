// SDF food pellet for the MultiMesh food field. One draw call renders every food
// instance; this shader reproduces the layered look of entity_node._draw_food
// (halo, shaded shell, inner disk, bright center, pulse) analytically, per instance.
//
// Per-instance inputs:
//   COLOR             — instance color (the food's palette color)
//   INSTANCE_CUSTOM.x — animation seed (desyncs the pulse between pellets)
// The instance transform scales a 2x2 quad by radius * HALO_EXTENT, so the quad's
// local coords reach [-1,1]; the shell (food radius) sits at fraction 1/HALO_EXTENT.
// We read the quad-local position from VERTEX (reliable for a mesh; mesh UV does not
// interpolate dependably through a 2D MultiMesh).
shader_type canvas_item;
render_mode blend_mix;

const float HALO_EXTENT = 1.5;

varying vec2 v_local; // quad-local position, [-1, 1]

void vertex() {
	v_local = VERTEX; // QuadMesh size (2,2) centered → local verts are ±1
}

void fragment() {
	float d = length(v_local);
	float r = d * HALO_EXTENT; // r == 1.0 at the food radius (the shell edge)

	float seed = INSTANCE_CUSTOM.x;
	float pulse = 0.5 + 0.5 * sin(TIME * 5.0 + seed);
	float halo_r = 1.32 + pulse * 0.09;
	vec3 base = COLOR.rgb;
	float aa = max(fwidth(r), 0.0001) * 1.2;

	// Translucent halo: strongest at the shell edge, fading out to halo_r.
	float halo = (1.0 - smoothstep(1.0, halo_r, r)) * 0.10;
	vec4 col = vec4(base, halo);

	// Shell (r < 1): darker shade.
	float shell = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, r);
	col = mix(col, vec4(base * 0.72, 1.0), shell);

	// Inner disk (r < 0.64): full color.
	float disk = 1.0 - smoothstep(0.64 - aa, 0.64 + aa, r);
	col = mix(col, vec4(base, 1.0), disk);

	// Bright center (r < 0.24).
	vec3 bright = clamp(base * 1.55, vec3(0.0), vec3(1.0));
	float ctr = 1.0 - smoothstep(0.24 - aa, 0.24 + aa, r);
	col = mix(col, vec4(bright, 1.0), ctr * 0.86);

	COLOR = col;
}
