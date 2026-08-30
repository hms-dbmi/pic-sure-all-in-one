#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import sys
import tempfile


TEST_DIR = Path(__file__).resolve().parent


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_owner(owner_dir, name):
    sys.modules.pop("contract", None)
    sys.path.insert(0, str(owner_dir))
    try:
        return load_module(owner_dir / "run.py", name)
    finally:
        sys.path.pop(0)


def force_ticket17_failure(module, temp_root):
    harness = module.Harness.__new__(module.Harness)
    harness.selection = "final-http-contract"
    harness.temp_root = temp_root
    harness.observations = []
    harness.expected_by_cell = {}
    for phase in (
        "require_tools",
        "require_runtime_pin",
        "prepare_sources",
        "verify_migration_contracts",
        "build_binaries",
        "create_network",
    ):
        setattr(harness, phase, lambda: None)
    harness.cleanup_cell_resources = lambda: []

    def fail_cell():
        (temp_root / "operations.log").write_text("synthetic Ticket 17 service failure\n")
        raise module.contract.ContractError("synthetic Ticket 17 nested-owner failure")

    harness.cell_final_http_contract = fail_cell
    try:
        harness.run()
    except module.contract.ContractError as error:
        if str(error) != "synthetic Ticket 17 nested-owner failure":
            raise
    else:
        raise RuntimeError("Ticket 17 forced failure unexpectedly passed")


def force_ticket18_failure(module, temp_root):
    harness = module.Harness.__new__(module.Harness)
    harness.selection = "final-backend-final-frontend"
    harness.temp_root = temp_root
    harness.observations = []
    harness.current_phase = "initialization"
    for phase in (
        "require_tools_and_runtime",
        "prepare_sources",
        "verify_static_inputs",
        "prepare_exports",
        "build_backend_binaries",
        "build_frontend_images",
        "build_browser_probe",
        "create_network",
    ):
        setattr(harness, phase, lambda: None)
    harness.cleanup_cell_resources = lambda: []
    harness.write_provenance = lambda: None

    def fail_cell():
        browser_root = temp_root / "final-backend-final-frontend"
        browser_root.mkdir()
        (browser_root / "browser-result.json").write_text(
            '{"regionPresent":false,"synthetic":true}\n', encoding="utf-8"
        )
        logs = temp_root / "logs"
        logs.mkdir()
        (logs / "gateway.log").write_text("synthetic Ticket 18 service failure\n")
        raise module.contract.ContractError("synthetic Ticket 18 nested-owner failure")

    harness.cell_final_backend_final_frontend = fail_cell
    try:
        harness.run()
    except module.contract.ContractError as error:
        if str(error) != "synthetic Ticket 18 nested-owner failure":
            raise
    else:
        raise RuntimeError("Ticket 18 forced failure unexpectedly passed")


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: nested-owner-diagnostics.py <backend-root>")
    backend = Path(sys.argv[1]).resolve()
    ticket17_dir = backend / "tests/operations-binary-compatibility"
    ticket18_dir = backend / "tests/banner-feed-compatibility"
    outer = load_module(TEST_DIR / "run.py", "banner_local_run_nested_diagnostics")
    ticket17 = load_owner(ticket17_dir, "ticket17_run_nested_diagnostics")
    ticket18 = load_owner(ticket18_dir, "ticket18_run_nested_diagnostics")

    with tempfile.TemporaryDirectory() as directory:
        runtime = Path(directory) / "owner-runtime"
        feed_root = runtime / "banner-feed-proof"
        binary_root = feed_root / "ticket17-temp/operations-binary-proof"
        binary_root.mkdir(parents=True)
        force_ticket17_failure(ticket17, binary_root)
        force_ticket18_failure(ticket18, feed_root)

        diagnostics = Path(directory) / "owner-diagnostics"
        outer.copy_owner_diagnostics(runtime, diagnostics)
        for relative in (
            "banner-feed-proof/observed-matrix.tsv",
            "banner-feed-proof/failed-cell.json",
            "banner-feed-proof/logs/gateway.log",
            "banner-feed-proof/final-backend-final-frontend/browser-result.json",
            "banner-feed-proof/ticket17-temp/operations-binary-proof/observed-matrix.tsv",
            "banner-feed-proof/ticket17-temp/operations-binary-proof/failed-cell.json",
            "banner-feed-proof/ticket17-temp/operations-binary-proof/operations.log",
        ):
            if not (diagnostics / relative).is_file():
                raise RuntimeError(f"nested owner diagnostic was not retained: {relative}")

    print("Ticket 22A real nested-owner failure diagnostics PASS")


if __name__ == "__main__":
    main()
