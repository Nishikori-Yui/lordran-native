"""Exercise generated NVN alpha tests through the production pipeline builder."""
import ast
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent
tree = ast.parse((root / "../tools/dmsh_build.py").read_text())
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "alpha_test")
namespace = {"re": re}
exec(compile(ast.Module(body=[fn], type_ignores=[]), "alpha_test", "exec"), namespace)
source = """#include <metal_stdlib>
using namespace metal;
vertex float4 vertex0(uint n [[vertex_id]]) {
    float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return float4(p[n], 0.25, 1);
}
struct main0_out { float4 color0 [[color(0)]]; float4 color1 [[color(1)]]; };
fragment main0_out main0(constant float& alpha [[buffer(1)]]) {
    main0_out out = {};
    out.color0 = float4(1, 0, 0, alpha);
    out.color1 = float4(0, 1, 0, 1);
    return out;
}
"""
with tempfile.TemporaryDirectory(prefix="nvn-alpha-") as temp:
    for exports_alpha in (True, False):
        path = Path(temp) / "alpha.metal"
        path.write_text(namespace["alpha_test"](source, exports_alpha))
        subprocess.run([str(root / "t_alpha"), str(path), str(int(exports_alpha))], check=True)
