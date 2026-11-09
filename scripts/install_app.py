#!/usr/bin/env python3
"""Verify a staged bundle before replacing an installed app; preserve the old one."""
import pathlib
import shutil
import subprocess
import sys
import tempfile


def install(source: pathlib.Path, destination: pathlib.Path) -> None:
    source = source.resolve()
    destination = destination.absolute()
    if destination.is_symlink() or source == destination.resolve():
        raise ValueError("Source and destination must be distinct, non-symlink app paths")
    stage = pathlib.Path(tempfile.mkdtemp(prefix=".workspace-tabs-install-", dir=destination.parent))
    candidate, previous = stage / "candidate.app", stage / "previous.app"
    installed = False
    try:
        subprocess.run(["ditto", str(source), str(candidate)], check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(candidate)], check=True)
        if destination.exists():
            destination.rename(previous)
        try:
            candidate.rename(destination)
            installed = True
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(destination)], check=True)
        except BaseException:
            if installed:
                destination.rename(candidate)
            if previous.exists():
                previous.rename(destination)
            raise
        if previous.exists():
            # Keep the old bundle for rollback and any process still using it.
            backup = pathlib.Path(tempfile.mkdtemp(prefix="Workspace-Tabs-previous-")) / destination.name
            try:
                shutil.move(str(previous), str(backup))
                print(f"Previous app: {backup}")
            except OSError:
                print(f"Previous app retained: {previous}")
        print(f"Installed: {destination}")
    finally:
        # Never delete an old bundle if its backup/rollback failed.
        if not previous.exists():
            shutil.rmtree(stage, ignore_errors=True)


if __name__ == "__main__":
    install(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
