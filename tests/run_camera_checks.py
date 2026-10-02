"""Compile the exact production geometry/countdown functions using macOS Swift."""
from pathlib import Path
import subprocess
import tempfile
source = Path("TANOO-PiP-POC/CameraStudio.swift").read_text()
geometry = source.split("// BEGIN CAMERA GEOMETRY\n", 1)[1].split("// END CAMERA GEOMETRY", 1)[0]
manual = source.split("// BEGIN MANUAL CAMERA MATH\n", 1)[1].split("// END MANUAL CAMERA MATH", 1)[0]
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
for fps in [24.0, 30, 60] {
    let frame = 1 / fps
    for requested in [0.0, -1, 1, 50, 60, 120, 1000000, Double.nan, Double.infinity] {
        let value = ManualCameraMath.exposureSeconds(denominator: requested, minimum: 1.0/10000, maximum: 1, frameSeconds: frame)
        precondition(value.isFinite && value >= 1.0/10000 && value <= frame)
    }
}
close(CGFloat(ManualCameraMath.exposureSeconds(denominator:60,minimum:0.0001,maximum:1,frameSeconds:1.0/30)),1.0/60)
for value in [Float(-10), 0, 1, 2, 99, Float.nan, Float.infinity] {
    let gain = ManualCameraMath.gain(value, maximum: 4)
    precondition(gain.isFinite && gain >= 1 && gain <= 4)
}
precondition(ManualCameraMath.gain(2.5,maximum:4) == 2.5)
print("PASS: exposure bounded by sensor/FPS; legal white-balance gains")
print("PASS: rear/front mirror, portrait bounds, mixed-resolution scaling, mandatory resume countdown")
"""
with tempfile.TemporaryDirectory() as folder:
    script = Path(folder)/"camera_checks.swift"
    script.write_text("import Foundation\nimport CoreGraphics\n" + geometry + manual + tests)
    subprocess.run(["swift", str(script)], check=True)
