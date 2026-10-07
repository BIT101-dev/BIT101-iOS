#!/usr/bin/env python3
"""Run source quality checks through the shared rule module."""
import sys
sys.dont_write_bytecode = True
from code_quality_rules import *

if __name__ == "__main__":
    raise SystemExit(combined_main() if "--combined" in sys.argv else main())
