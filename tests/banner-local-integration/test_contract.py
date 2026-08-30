#!/usr/bin/env python3

import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
TEST_DIR = ROOT / "tests" / "banner-local-integration"


class BannerLocalIntegrationContractTest(unittest.TestCase):
    def test_checked_in_aio_local_proof_is_complete(self):
        required = (
            TEST_DIR / "README.md",
            TEST_DIR / "contract.json",
            TEST_DIR / "expected-result.json",
            TEST_DIR / "run.py",
            TEST_DIR / "browser.mjs",
            TEST_DIR / "browser.Dockerfile",
            TEST_DIR / "browser-package.json",
            TEST_DIR / "browser-package-lock.json",
            TEST_DIR / "cleanup-resources.sh",
            TEST_DIR / "preserve-diagnostics.sh",
            TEST_DIR / "test-failure-diagnostics.sh",
            TEST_DIR / "test-cleanup.sh",
            TEST_DIR / "test.sh",
            ROOT / ".github" / "workflows" / "banner-local-integration.yml",
        )
        missing = [str(path.relative_to(ROOT)) for path in required if not path.is_file()]
        self.assertEqual([], missing, f"missing AIO local proof files: {missing}")

    def test_result_contract_and_expected_row_are_closed_and_complete(self):
        contract = json.loads((TEST_DIR / "contract.json").read_text(encoding="utf-8"))
        expected = json.loads((TEST_DIR / "expected-result.json").read_text(encoding="utf-8"))
        self.assertEqual(1, contract["properties"]["schemaVersion"]["const"])
        self.assertIn("AIO", contract["properties"]["deployment"]["enum"])
        self.assertEqual(
            ["PASS", "FAIL", "NOT_RUN"], contract["properties"]["status"]["enum"]
        )
        self.assertEqual(
            set(contract["properties"]["checks"]["required"]), set(expected["checks"])
        )
        self.assertEqual(
            set(contract["properties"]["limitations"]["required"]),
            set(expected["limitations"]),
        )
        self.assertTrue(all(value == "PASS" for value in expected["checks"].values()))
        self.assertTrue(all(value == "NOT_RUN" for value in expected["limitations"].values()))
        self.assertEqual(
            "f8cb265d735b757872391e04fdcd5b999b785eaa427ca13f8f2eefd493715359",
            expected["rolloutContractSha256"],
        )
        self.assertEqual(
            {
                "releaseControl": "53802f3efbd030042fab442f9c5a3a29770528ca",
                "backend": "0178bbd2d1753e07dcead77a6d0e8ca37bf76dd8",
                "frontend": "7b69aa960ff98f97c1a2d026b7137b0e3dcdf603",
                "migrationSource": "05b1a77512dc0921570f0d442853fdcee75b8131",
            },
            expected["sourceCommits"],
        )
        self.assertNotIn("deploymentConfig", expected["sourceCommits"])
        self.assertNotIn("runtimeArtifacts", expected["observations"])
        self.assertEqual(
            "8830fbf9dffe69b273a51d35410413115878841f",
            expected["deploymentExtensions"]["AIO"]["proofBase"],
        )
        self.assertTrue(all("@sha256:" in image for image in expected["images"].values()))

    def test_harness_uses_real_services_and_composes_exact_proof_owners(self):
        source = (TEST_DIR / "run.py").read_text(encoding="utf-8")
        for required in (
            "services/pic-sure-operations-service",
            "services/pic-sure-gateway",
            "services/pic-sure-auth-microapp/pic-sure-auth-services",
            "services/pic-sure-logging",
            "tests/aio-deployment-migration/test.sh",
            "tests/operations-binary-compatibility/test.sh",
            "tests/banner-feed-compatibility/test.sh",
            "BannerRolloutContractTest",
            "/picsure/operations/banners/active/v2",
            "banner.published",
            "pic-sure-logging",
        ):
            self.assertIn(required, source)
        self.assertNotIn("route.fulfill", source)
        self.assertNotIn("page.route", source)
        self.assertIsNone(re.search(r"^\s*assert\s", source, flags=re.MULTILINE))

    def test_authoritative_owner_entrypoints_are_executed(self):
        source = (TEST_DIR / "run.py").read_text(encoding="utf-8")
        for pattern in (
            r"aio-deployment-migration/test\.sh.*all",
            r"operations-binary-compatibility/test\.sh.*all",
            r"banner-feed-compatibility/test\.sh.*all",
            r"BannerManagementCacheRefreshIntegrationTest",
            r"tests/banner-rollout",
            r"test_build_spec\.py",
        ):
            self.assertRegex(source, re.compile(pattern, flags=re.DOTALL))

    def test_expected_only_row_is_rejected_and_executing_head_is_required(self):
        expected = json.loads((TEST_DIR / "expected-result.json").read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as directory:
            result_path = Path(directory) / "result.json"
            result_path.write_text(json.dumps(expected), encoding="utf-8")
            completed = subprocess.run(
                ["python3", str(TEST_DIR / "run.py"), "--finalize", str(ROOT), str(result_path)],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertNotEqual(0, completed.returncode, completed.stdout)
        self.assertIn("runtime", completed.stderr + completed.stdout)

        source = (TEST_DIR / "run.py").read_text(encoding="utf-8")
        self.assertIn('"deploymentConfig": repository_head(self.aio_root)', source)

    def test_privileged_route_proof_rejects_missing_and_wrong_method(self):
        source = (TEST_DIR / "run.py").read_text(encoding="utf-8")
        self.assertRegex(source, r"allowed in \{[^}]*404[^}]*405[^}]*\}")
        self.assertIn("expected_privileged_statuses", source)
        spec = importlib.util.spec_from_file_location("banner_local_run", TEST_DIR / "run.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for route_name in (
            "list", "create", "save", "order", "update", "publish", "disable", "archive", "restore"
        ):
            self.assertNotIn(404, module.expected_privileged_statuses(route_name))
            self.assertNotIn(405, module.expected_privileged_statuses(route_name))

    def test_workflow_is_read_only_bounded_and_exactly_pinned(self):
        workflow = (ROOT / ".github/workflows/banner-local-integration.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn("timeout-minutes: 45", workflow)
        self.assertNotIn("pull-requests: write", workflow)
        self.assertNotIn("@main", workflow)
        self.assertNotIn("@v", workflow)
        for commit in (
            "0178bbd2d1753e07dcead77a6d0e8ca37bf76dd8",
            "7b69aa960ff98f97c1a2d026b7137b0e3dcdf603",
            "05b1a77512dc0921570f0d442853fdcee75b8131",
            "53802f3efbd030042fab442f9c5a3a29770528ca",
            "5d2ba9f59f161ace5e807c82a0580518a9d44d16",
            "ca8ac3641ba122a93cda8a5d7cad7f23f7a46bb6",
        ):
            self.assertIn(f"ref: {commit}", workflow)

    def test_failure_diagnostics_survive_runtime_cleanup_and_ci_uploads_them(self):
        runner = (TEST_DIR / "test.sh").read_text(encoding="utf-8")
        workflow = (ROOT / ".github/workflows/banner-local-integration.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("BANNER_LOCAL_DIAGNOSTICS_ROOT", runner)
        self.assertIn("test-failure-diagnostics.sh", runner)
        self.assertIn("actions/upload-artifact@", workflow)
        self.assertIn("if: failure()", workflow)
        completed = subprocess.run(
            ["bash", str(TEST_DIR / "test-failure-diagnostics.sh")],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn("runtime cleanup PASS", completed.stdout)

    def test_cleanup_is_run_scoped_and_tested(self):
        cleanup = (TEST_DIR / "cleanup-resources.sh").read_text(encoding="utf-8")
        cleanup_test = (TEST_DIR / "test-cleanup.sh").read_text(encoding="utf-8")
        runner = (TEST_DIR / "test.sh").read_text(encoding="utf-8")
        label = "org.pic-sure.banner-local-integration"
        self.assertIn(label, cleanup)
        self.assertIn(label, cleanup_test)
        self.assertIn("trap cleanup EXIT INT TERM", runner)
        self.assertIn('"$test_dir/cleanup-resources.sh" "$run_id"', runner)
        self.assertIn("--finalize", runner)

    def test_operations_receives_the_existing_logging_client_environment(self):
        operations_env = (
            ROOT / "initial-configuration" / "config" / "operations" / "operations.env"
        ).read_text(encoding="utf-8")
        self.assertIn("LOGGING_API_KEY=__LOGGING_API_KEY__", operations_env)
        self.assertIn("LOGGING_SERVICE_URL=http://pic-sure-logging", operations_env)

        configure = (ROOT / "initial-configuration" / "configure-service-envs.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            '"$GATEWAY_ENV" "$OPERATIONS_ENV" "$LOGGING_ENV"',
            configure,
        )

        migrate = (ROOT / "initial-configuration" / "migrate-env.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            'local operations_keys="SPRING_DATASOURCE_PASSWORD QUERY_SERVICE_INTERNAL_TOKEN '
            'PICSURE_APPLICATION_TOKEN LOGGING_API_KEY LOGGING_SERVICE_URL"',
            migrate,
        )
        self.assertIn(
            "upsert_env LOGGING_SERVICE_URL http://pic-sure-logging \"$operations_env\"",
            migrate,
        )

    def test_normal_configuration_renders_one_logging_key_for_operations(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config"
            shutil.copytree(ROOT / "initial-configuration/config", config)
            operations = config / "operations/operations.env"
            operations.write_text(
                operations.read_text(encoding="utf-8").replace(
                    "SPRING_DATASOURCE_PASSWORD=__PICSURE_MYSQL_PASSWORD__",
                    "SPRING_DATASOURCE_PASSWORD=t22a-synthetic-password",
                ),
                encoding="utf-8",
            )
            gateway = config / "gateway/gateway.env"
            gateway.write_text(
                gateway.read_text(encoding="utf-8").replace(
                    "TOKEN_INTROSPECTION_TOKEN=__TOKEN_INTROSPECTION_TOKEN__",
                    "TOKEN_INTROSPECTION_TOKEN=t22a-synthetic-introspection",
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                ["bash", str(ROOT / "initial-configuration/configure-service-envs.sh")],
                env={**os.environ, "DOCKER_CONFIG_DIR": str(config)},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)

            def value(path, key):
                prefix = key + "="
                return next(
                    line.removeprefix(prefix)
                    for line in path.read_text(encoding="utf-8").splitlines()
                    if line.startswith(prefix)
                )

            logging_key = value(config / "logging/logging.env", "LOGGING_API_KEY")
            self.assertRegex(logging_key, r"^[0-9a-f]{64}$")
            self.assertEqual(logging_key, value(operations, "LOGGING_API_KEY"))
            self.assertEqual(logging_key, value(config / "gateway/gateway.env", "LOGGING_API_KEY"))
            self.assertEqual(
                "http://pic-sure-logging", value(operations, "LOGGING_SERVICE_URL")
            )

            operations.write_text(
                "\n".join(
                    line
                    for line in operations.read_text(encoding="utf-8").splitlines()
                    if not line.startswith(("LOGGING_API_KEY=", "LOGGING_SERVICE_URL="))
                )
                + "\n",
                encoding="utf-8",
            )
            migrated = subprocess.run(
                ["bash", str(ROOT / "initial-configuration/migrate-env.sh")],
                env={
                    **os.environ,
                    "DOCKER_CONFIG_DIR": str(config),
                    "MIGRATION_TEMPLATE_DIR": str(ROOT / "initial-configuration/config"),
                },
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, migrated.returncode, migrated.stderr)
            self.assertEqual(logging_key, value(operations, "LOGGING_API_KEY"))
            self.assertEqual(
                "http://pic-sure-logging", value(operations, "LOGGING_SERVICE_URL")
            )

    def test_configure_logging_rotates_operations_with_other_clients(self):
        job = ROOT / "initial-configuration/jenkins/jenkins-docker/jobs/Configure Logging/config.xml"
        shell = "\n".join(node.text or "" for node in ET.parse(job).getroot().findall(".//command"))
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config"
            shutil.copytree(ROOT / "initial-configuration/config", config)
            operations = config / "operations/operations.env"
            operations.write_text(
                operations.read_text(encoding="utf-8").replace(
                    "SPRING_DATASOURCE_PASSWORD=__PICSURE_MYSQL_PASSWORD__",
                    "SPRING_DATASOURCE_PASSWORD=t22a-synthetic-password",
                ),
                encoding="utf-8",
            )
            gateway = config / "gateway/gateway.env"
            gateway.write_text(
                gateway.read_text(encoding="utf-8").replace(
                    "TOKEN_INTROSPECTION_TOKEN=__TOKEN_INTROSPECTION_TOKEN__",
                    "TOKEN_INTROSPECTION_TOKEN=t22a-synthetic-introspection",
                ),
                encoding="utf-8",
            )
            configured = subprocess.run(
                ["bash", str(ROOT / "initial-configuration/configure-service-envs.sh")],
                env={**os.environ, "DOCKER_CONFIG_DIR": str(config)},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, configured.returncode, configured.stderr)
            for service in ("gateway", "operations", "logging"):
                env_path = config / service / f"{service}.env"
                env_path.write_text(
                    re.sub(
                        r"^LOGGING_API_KEY=.*$",
                        f"LOGGING_API_KEY={'new-key' if service == 'logging' else 'old-key'}",
                        env_path.read_text(encoding="utf-8"),
                        flags=re.MULTILINE,
                    ),
                    encoding="utf-8",
                )
            completed = subprocess.run(
                ["bash", "-c", shell.replace("/usr/local/docker-config", str(config))],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, completed.returncode, completed.stderr)
            for service in ("gateway", "operations", "logging"):
                value = (config / service / f"{service}.env").read_text(encoding="utf-8")
                self.assertIn("LOGGING_API_KEY=new-key\n", value, service)
            migrated = subprocess.run(
                ["bash", str(ROOT / "initial-configuration/migrate-env.sh")],
                env={
                    **os.environ,
                    "DOCKER_CONFIG_DIR": str(config),
                    "MIGRATION_TEMPLATE_DIR": str(ROOT / "initial-configuration/config"),
                },
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(0, migrated.returncode, migrated.stderr)

    def test_result_contract_is_deployment_neutral_and_typed(self):
        contract = json.loads((TEST_DIR / "contract.json").read_text(encoding="utf-8"))
        self.assertNotIn("deployment", contract)
        self.assertEqual("object", contract["type"])
        self.assertEqual(
            ["AIO", "BDC", "AIM_AHEAD"],
            contract["properties"]["deployment"]["enum"],
        )
        self.assertIn("deploymentExtensions", contract["properties"])
        for field in (
            "schemaVersion", "deployment", "status", "sourceCommits", "images", "checks",
            "observations", "limitations", "deploymentExtensions",
        ):
            self.assertIn(field, contract["required"])


if __name__ == "__main__":
    unittest.main()
