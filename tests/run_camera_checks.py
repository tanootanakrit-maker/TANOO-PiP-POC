"""Compile the exact production geometry/countdown functions using macOS Swift."""
from pathlib import Path
import subprocess
import tempfile
source = Path("TANOO-PiP-POC/CameraStudio.swift").read_text()
geometry = source.split("// BEGIN CAMERA GEOMETRY\n", 1)[1].split("// END CAMERA GEOMETRY", 1)[0]
tests = r"""
func close(_ a: CGFloat, _ b: CGFloat) { precondition(abs(a-b) < 0.001, "Geometry mismatch") }
let target = CGSize(width: 1080, height: 1920)
let landscape = CGSize(width: 1920, height: 1080)
let rear = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
let front = rear.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1080, ty: 0))
for transform in [rear, front] {
    let output = CameraGeometry.exportTransform(naturalSize: landscape, preferred: transform, target: target)
    let bounds = CGRect(origin: .zero, size: landscape).applying(output)
    close(bounds.minX, 0); close(bounds.minY, 0)
    close(bounds.width, 1080); close(bounds.height, 1920)
    for point in [CGPoint(x: 0,y: 0), CGPoint(x: 1920,y: 1080), CGPoint(x: 500,y: 200)] {
        let original = point.applying(transform), rendered = point.applying(output)
        close(original.x, rendered.x); close(original.y, rendered.y)
    }
}
let fourK = CameraGeometry.exportTransform(naturalSize: landscape, preferred: rear, target: CGSize(width:2160,height:3840))
let bounds = CGRect(origin:.zero, size:landscape).applying(fourK)
close(bounds.width,2160); close(bounds.height,3840)
precondition(CameraGeometry.countdown(configured:0,resuming:true) == 3)
precondition(CameraGeometry.countdown(configured:5,resuming:true) == 5)
precondition(CameraGeometry.countdown(configured:0,resuming:false) == 0)
precondition(CameraGeometry.countdown(configured:3,resuming:false) == 3)
print("PASS: rear/front mirror, portrait bounds, mixed-resolution scaling, mandatory resume countdown")
"""
with tempfile.TemporaryDirectory() as folder:
    script = Path(folder)/"camera_checks.swift"
    script.write_text("import Foundation\nimport CoreGraphics\n" + geometry + tests)
    subprocess.run(["swift", str(script)], check=True)
