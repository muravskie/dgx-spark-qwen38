#!/usr/bin/env python3
"""Refuse legacy lifecycle writers after an explicit model-controller handoff."""
import os
from pathlib import Path
import sys


def main():
    config = Path(os.environ.get("CONFIG_DIR", Path.home() / ".config/qwen38"))
    if (config / "controller-managed").exists():
        print("ERROR: spark-model-controller owns this host's GPU workloads. "
              "Merge serving changes manually and update Cockpit with "
              "dashboard/install-dashboard.sh; manage models through the controller.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
