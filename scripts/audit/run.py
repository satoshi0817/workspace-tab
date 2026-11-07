"""Copy sources to a temporary package and replace only OS access for fault injection."""
import pathlib, shutil, subprocess, sys, tempfile
repo = pathlib.Path(__file__).resolve().parents[2]
source = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else repo
with tempfile.TemporaryDirectory(prefix="workspace-tabs-audit-") as folder:
    work = pathlib.Path(folder)
    shutil.copytree(source / "Sources", work / "Sources")
    shutil.copytree(source / "Tests", work / "Tests")
    shutil.copyfile(source / "Package.swift", work / "Package.swift")
    access = work / "Sources/WorkspaceTabs/Accessibility.swift"
    prefix = access.read_text().split("enum WindowAccess {")[0]
    access.write_text(prefix + (repo / "scripts/audit/WindowAccess.stub.swift").read_text())
    shutil.copyfile(repo / "scripts/audit/main.swift", work / "Sources/WorkspaceTabs/main.swift")
    p = subprocess.run(["rtk", "proxy", "swift", "run", "--package-path", str(work),
                        "--scratch-path", str(work / "scratch"), "WorkspaceTabs"], text=True, capture_output=True)
    sys.stderr.write(p.stderr)
    sys.stdout.write(p.stdout)
    sys.exit(p.returncode)
