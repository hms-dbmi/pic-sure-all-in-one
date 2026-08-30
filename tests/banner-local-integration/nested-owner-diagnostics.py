#!/usr/bin/env python3

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
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


def write_executable(path, source):
    path.write_text(source, encoding="utf-8")
    path.chmod(0o755)


def run_ticket17_child(backend):
    retention = {
        name: os.environ.get(name)
        for name in ("KEEP_COMPAT_TEMP", "KEEP_COMPAT_TEMP_ON_FAILURE")
    }
    if set(retention.values()) != {"true"}:
        raise RuntimeError(f"Ticket 18 did not propagate Ticket 17 retention: {retention}")
    temp_parent = Path(os.environ["TMPDIR"])
    temp_root = temp_parent / "operations-binary-proof"
    temp_root.mkdir(parents=True)
    (temp_root / "retention.log").write_text(
        json.dumps(retention, sort_keys=True) + "\n", encoding="utf-8"
    )
    ticket17_dir = backend / "tests/operations-binary-compatibility"
    ticket17 = load_owner(ticket17_dir, "ticket17_run_nested_child")
    force_ticket17_failure(ticket17, temp_root)
    print("synthetic Ticket 17 child exited after owner failure diagnostics", file=sys.stderr)
    raise SystemExit(23)


def create_ticket17_fixture(fixture, backend):
    fixture.mkdir()
    shutil.copy2(
        backend / "tests/operations-binary-compatibility/matrix.tsv",
        fixture / "matrix.tsv",
    )
    write_executable(
        fixture / "test.sh",
        """#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == all ]] || { echo "Ticket 17 fixture requires all" >&2; exit 2; }
exec python3 "${T22A_NESTED_DIAGNOSTICS_SCRIPT:?}" \
  ticket17-child "${T22A_NESTED_BACKEND_ROOT:?}"
""",
    )
    write_executable(
        fixture / "cleanup-resources.sh",
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${1:?run ID is required}" >> "${T22A_NESTED_CLEANUP_MARKER:?}"
""",
    )
    return fixture


def fake_feed_cell(temp_root, cell, observation):
    cell_root = temp_root / cell
    cell_root.mkdir()
    (cell_root / "browser-result.json").write_text(
        json.dumps({"cell": cell, "synthetic": True}) + "\n", encoding="utf-8"
    )
    logs = temp_root / "logs"
    logs.mkdir(exist_ok=True)
    (logs / "gateway.log").write_text(
        f"synthetic Ticket 18 {cell} service log\n", encoding="utf-8"
    )
    return dict(observation)


def force_composed_ticket17_failure(module, backend, temp_root, fixture, cleanup_marker):
    harness = module.Harness(backend, temp_root, "proof", "all")
    harness.ticket17_dir = fixture
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
    for cell in module.contract.REQUIRED_CELLS:
        method = "cell_" + cell.replace("-", "_")
        observation = harness.expected_by_cell[cell]
        setattr(
            harness,
            method,
            lambda cell=cell, observation=observation: fake_feed_cell(
                temp_root, cell, observation
            ),
        )
    harness.write_provenance = lambda: None

    environment = {
        "KEEP_BANNER_FEED_TEMP": "true",
        "KEEP_BANNER_FEED_TEMP_ON_FAILURE": "true",
        "T22A_NESTED_BACKEND_ROOT": str(backend),
        "T22A_NESTED_CLEANUP_MARKER": str(cleanup_marker),
        "T22A_NESTED_DIAGNOSTICS_SCRIPT": str(Path(__file__).resolve()),
    }
    keys = set(environment) | {"KEEP_COMPAT_TEMP", "KEEP_COMPAT_TEMP_ON_FAILURE"}
    previous = {key: os.environ.get(key) for key in keys}
    for key in ("KEEP_COMPAT_TEMP", "KEEP_COMPAT_TEMP_ON_FAILURE"):
        os.environ.pop(key, None)
    os.environ.update(environment)
    try:
        harness.run()
    except module.contract.ContractError as error:
        expected = (
            "Ticket 17 authoritative all entrypoint failed with status 23; "
            "see ticket17.log"
        )
        if str(error) != expected:
            raise
    else:
        raise RuntimeError("Ticket 18 composed Ticket 17 failure unexpectedly passed")
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def require_file(root, relative):
    path = root / relative
    if not path.is_file():
        raise RuntimeError(f"nested owner diagnostic was not retained: {relative}")
    return path


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "ticket17-child":
        run_ticket17_child(Path(sys.argv[2]).resolve())
        return
    if len(sys.argv) != 2:
        raise SystemExit("usage: nested-owner-diagnostics.py <backend-root>")
    backend = Path(sys.argv[1]).resolve()
    ticket18_dir = backend / "tests/banner-feed-compatibility"
    outer = load_module(TEST_DIR / "run.py", "banner_local_run_nested_diagnostics")
    ticket18 = load_owner(ticket18_dir, "ticket18_run_nested_diagnostics")

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        runtime = root / "outer-runtime"
        owner_runtime = runtime / "owner-runtime"
        feed_root = owner_runtime / "banner-feed-proof"
        feed_root.mkdir(parents=True)
        cleanup_marker = root / "ticket17-cleanup.log"
        fixture = create_ticket17_fixture(root / "ticket17-fixture", backend)
        force_composed_ticket17_failure(
            ticket18, backend, feed_root, fixture, cleanup_marker
        )

        failure = json.loads(
            require_file(feed_root, "failed-cell.json").read_text(encoding="utf-8")
        )
        if failure.get("failed_phase") != "ticket17-composition":
            raise RuntimeError(f"Ticket 18 did not record composed failure phase: {failure}")
        child_result = json.loads(
            require_file(feed_root, "ticket17-result.json").read_text(encoding="utf-8")
        )
        expected_child_result = {
            "command": "tests/operations-binary-compatibility/test.sh all",
            "matrixSha256": ticket18.contract.sha256_file(
                backend / "tests/operations-binary-compatibility/matrix.tsv"
            ),
            "proofOwnerHead": ticket18.FINAL_BACKEND_COMMIT,
            "status": 23,
            "passed": False,
        }
        if child_result != expected_child_result:
            raise RuntimeError(f"Ticket 18 recorded invalid Ticket 17 result: {child_result}")
        child_log = require_file(feed_root, "ticket17.log").read_text(encoding="utf-8")
        if "synthetic Ticket 17 child exited after owner failure diagnostics" not in child_log:
            raise RuntimeError("Ticket 18 did not retain the failed Ticket 17 child output")
        child_root = feed_root / "ticket17-temp/operations-binary-proof"
        retention = json.loads(
            require_file(child_root, "retention.log").read_text(encoding="utf-8")
        )
        if set(retention.values()) != {"true"}:
            raise RuntimeError(f"Ticket 17 retention environment drifted: {retention}")
        child_failure = json.loads(
            require_file(child_root, "failed-cell.json").read_text(encoding="utf-8")
        )
        if child_failure.get("failed_cell") != "final-http-contract":
            raise RuntimeError(f"Ticket 17 failure diagnostic drifted: {child_failure}")
        feed_matrix = require_file(feed_root, "observed-matrix.tsv")
        expected_feed_matrix = backend / "tests/banner-feed-compatibility/matrix.tsv"
        if feed_matrix.read_bytes() != expected_feed_matrix.read_bytes():
            raise RuntimeError("Ticket 18 partial failure matrix drifted")
        child_matrix = require_file(child_root, "observed-matrix.tsv")
        expected_child_header = (
            backend / "tests/operations-binary-compatibility/matrix.tsv"
        ).read_bytes().splitlines(keepends=True)[0]
        if child_matrix.read_bytes() != expected_child_header:
            raise RuntimeError("Ticket 17 partial failure matrix drifted")
        operations_log = require_file(child_root, "operations.log").read_text(encoding="utf-8")
        if operations_log != "synthetic Ticket 17 service failure\n":
            raise RuntimeError("Ticket 17 service log drifted before outer preservation")
        if cleanup_marker.read_text(encoding="utf-8") != "proof\n":
            raise RuntimeError("Ticket 18 did not clean the failed Ticket 17 run exactly once")

        owner_artifacts = (
            "banner-feed-proof/observed-matrix.tsv",
            "banner-feed-proof/failed-cell.json",
            "banner-feed-proof/ticket17-result.json",
            "banner-feed-proof/ticket17.log",
            "banner-feed-proof/logs/gateway.log",
            "banner-feed-proof/final-backend-final-frontend/browser-result.json",
            "banner-feed-proof/ticket17-temp/operations-binary-proof/observed-matrix.tsv",
            "banner-feed-proof/ticket17-temp/operations-binary-proof/failed-cell.json",
            "banner-feed-proof/ticket17-temp/operations-binary-proof/operations.log",
            "banner-feed-proof/ticket17-temp/operations-binary-proof/retention.log",
        )
        expected_artifacts = {
            relative: require_file(owner_runtime, relative).read_bytes()
            for relative in owner_artifacts
        }
        diagnostics = runtime / "owner-diagnostics"
        outer.copy_owner_diagnostics(owner_runtime, diagnostics)
        (runtime / "failed-result.json").write_text(
            '{"status":"FAIL","phase":"composed-owner"}\n', encoding="utf-8"
        )
        stable = root / "stable-diagnostics"
        subprocess.run(
            [TEST_DIR / "preserve-diagnostics.sh", runtime, stable],
            check=True,
            capture_output=True,
            text=True,
        )
        shutil.rmtree(runtime)
        if runtime.exists():
            raise RuntimeError("Ticket 22A outer runtime cleanup failed")
        require_file(stable, "failed-result.json")
        for relative, expected in expected_artifacts.items():
            preserved = require_file(stable / "owner-diagnostics", relative)
            if preserved.read_bytes() != expected:
                raise RuntimeError(f"stable nested owner diagnostic drifted: {relative}")

    print("Ticket 22A real nested-owner failure diagnostics PASS")


if __name__ == "__main__":
    main()
