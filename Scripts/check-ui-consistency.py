#!/usr/bin/env python3
"""Run semantic SwiftUI and design system checks."""
import sys
sys.dont_write_bytecode = True
from ui_rules import *
from ui_rule_tests import ast_marker_boundary_findings, source_boundary_findings, map_theme_color_contract_findings

if __name__ == "__main__":
    raise SystemExit(main())
