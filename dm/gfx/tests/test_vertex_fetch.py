"""Run the generated vertex-fetch adapter through the production PSO builder."""
import ast
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent
tree = ast.parse((root / "../tools/dmsh_build.py").read_text())
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "vertex_fetch")
namespace = {"re": re}
exec(compile(ast.Module(body=[fn], type_ignores=[]), "vertex_fetch", "exec"), namespace)

source = """#include <metal_stdlib>
using namespace metal;
struct main0_in { TYPE uv [[attribute(4)]]; };
struct main0_out { float4 position [[position]]; uint4 value [[flat]]; };
vertex main0_out main0(main0_in in [[stage_in]], uint n [[vertex_id]]) {
    main0_out out = {};
    float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    out.position = float4(p[n], 0, 1);
    out.value = as_type<uint4>(in.uv);
    return out;
}
fragment uint4 pixel(main0_out in [[stage_in]]) { return in.value; }
"""
with tempfile.TemporaryDirectory(prefix="nvn-vertex-fetch-") as temp:
    for typ in ("float4", "uint4", "int4"):
        adapted, changed = namespace["vertex_fetch"](source.replace("TYPE", typ))
        assert changed
        path = Path(temp) / f"{typ}.metal"
        path.write_text(adapted)
        subprocess.run([str(root / "t_vertex_fetch"), str(path), typ], check=True)
