// A vertex shader.
struct Out {
  @builtin(position) pos: vec4f,
};

/* entry */
@vertex
fn main(@location(0) p: vec3f) -> Out {
  var out: Out;
  out.pos = vec4f(p, 1.0);
  return out;
}
