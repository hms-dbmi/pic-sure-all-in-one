#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
JOBS = ROOT / "initial-configuration/jenkins/jenkins-docker/jobs"
CONTRACT = ROOT / "initial-configuration/jenkins/jenkins-docker/banner-rollout-contract.json"
CONTRACT_SOURCE = ROOT / "initial-configuration/jenkins/jenkins-docker/banner-rollout-source.json"
EXPECTED_CONTRACT_COMMIT = "0178bbd2d1753e07dcead77a6d0e8ca37bf76dd8"
EXPECTED_CONTRACT_SHA256 = "f8cb265d735b757872391e04fdcd5b999b785eaa427ca13f8f2eefd493715359"
EXPECTED_FORWARD = [
    "APPLY_AUTHORIZATION_AND_PIC_SURE_MIGRATIONS",
    "RECREATE_PSAMA",
    "VERIFY_OPERATIONS_AND_GATEWAY_HEALTH",
    "PUBLISH_FRONTEND_ACTIVE_V2",
]
EXPECTED_ROLLBACK = [
    "FREEZE_BANNER_MANAGEMENT_WRITES",
    "ROLL_BACK_FRONTEND",
    "DISABLE_ACTIVE_AND_SCHEDULED_TARGETED_BANNERS_BEFORE_LEGACY_ACTIVE_FEED_BACKEND",
    "ROLL_BACK_OPERATIONS_AND_GATEWAY",
    "KEEP_BANNER_MANAGEMENT_WRITES_FROZEN_BELOW_TARGETING_CAPABLE_BACKEND",
    "RECREATE_PSAMA",
]


def xml_script(path: Path) -> str:
    root = ET.parse(path).getroot()
    scripts = [node.text or "" for node in root.findall(".//script")]
    return "\n".join(scripts)


def scheduled_jobs(script: str) -> list[str]:
    return re.findall(
        r'getItemByFullName\("([^"]+)"\)\s*\.scheduleBuild2', script
    )


def validate_update_script(script: str) -> None:
    jobs = scheduled_jobs(script)
    required = ["PIC-SURE Database Migrations", "PIC-SURE Pipeline"]
    if jobs != required:
        raise AssertionError(f"update jobs must be exactly {required}, got {jobs}")
    if "release_control_commit" not in script:
        raise AssertionError("update must pin downstream jobs to its release-control commit")
    migrations_position = script.index('getItemByFullName("PIC-SURE Database Migrations")')
    pipeline_position = script.index('getItemByFullName("PIC-SURE Pipeline")')
    migrations_guard = script[migrations_position:pipeline_position]
    if "migrationsRun.result != Result.SUCCESS" not in migrations_guard or "throw new Exception" not in migrations_guard:
        raise AssertionError("migration failure must stop the update before the application pipeline")
    pipeline_guard = script[pipeline_position:]
    if "migration_build_number" not in pipeline_guard or "migrationsRun.number.toString()" not in pipeline_guard:
        raise AssertionError("application pipeline must consume proof from the successful migration build")
    if "pipelineRun.result != Result.SUCCESS" not in pipeline_guard or "throw new Exception" not in pipeline_guard:
        raise AssertionError("application pipeline failure must fail the update")


def validate_start_script(script: str) -> None:
    containers = re.findall(
        r"(?m)^\s*docker run --name(?:=|\s+)([a-z0-9-]+)", script
    )
    required = [
        "psama",
        "pic-sure-operations-service",
        "pic-sure-hpds-query-service",
        "gateway",
        "httpd",
    ]
    try:
        positions = [containers.index(container) for container in required]
    except ValueError as error:
        raise AssertionError(f"start path omits a mandatory service: {error}") from error
    if positions != sorted(positions):
        raise AssertionError(f"mandatory service order is wrong: {containers}")
    gateway_position = script.index("docker run --name=gateway")
    httpd_position = script.index("docker run --name=httpd")
    for health_gate in (
        "wait_for_container_health psama",
        "wait_for_container_health pic-sure-operations-service",
        "wait_for_container_health pic-sure-hpds-query-service",
        "wait_for_container_health gateway",
    ):
        position = script.index(health_gate, gateway_position)
        if position >= httpd_position:
            raise AssertionError(f"{health_gate} must run before httpd")


def fake_bin(directory: Path) -> Path:
    bin_dir = directory / "bin"
    bin_dir.mkdir()
    docker = bin_dir / "docker"
    docker.write_text(
        """#!/usr/bin/env bash
set -u
printf '%s\\n' "$*" >> "$MOCK_DOCKER_LOG"
if [[ "$*" == *"inspect --format={{.State.Running}}"* ]]; then
  printf '%s\\n' true
elif [[ "$*" == *"inspect --format={{.State.Health.Status}}"* ]]; then
  name="${*: -1}"
  if [[ "${MOCK_UNHEALTHY_CONTAINER:-}" == "$name" ]]; then
    printf '%s\\n' unhealthy
  else
    printf '%s\\n' healthy
  fi
elif [[ "$1 ${2:-}" == "container inspect" ]]; then
  exit 1
elif [[ "$1 ${2:-}" == "image inspect" ]]; then
  if [[ "$*" == *"--format={{.Id}}"* ]]; then
    printf '%s\\n' sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  else
    printf '%s\\n' "image-${*: -1}"
  fi
fi
"""
    )
    docker.chmod(0o755)
    sleep = bin_dir / "sleep"
    sleep.write_text("#!/usr/bin/env bash\nexit 0\n")
    sleep.chmod(0o755)
    return bin_dir


def required_config(directory: Path) -> Path:
    for service in ("httpd", "psama", "operations", "query", "gateway"):
        (directory / service).mkdir(parents=True)
    for path in (
        "httpd/httpd.env",
        "httpd/httpd-vhosts.conf",
        "psama/psama.env",
        "operations/operations.env",
        "query/query.env",
        "gateway/gateway.env",
    ):
        (directory / path).write_text("SYNTHETIC=true\n")
    (directory / "httpd/cert").mkdir()
    return directory


def run_script(script: Path, config: Path, extra_env=None, *args: str):
    work = config.parent
    log = work / "docker.log"
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{fake_bin(work)}:{env['PATH']}",
            "MOCK_DOCKER_LOG": str(log),
            "DOCKER_CONFIG_DIR": str(config),
            "CURRENT_FS_DOCKER_CONFIG_DIR": str(config),
            "AIO_HEALTH_TIMEOUT_SECONDS": "1",
            "AIO_HEALTH_POLL_SECONDS": "1",
        }
    )
    if extra_env:
        env.update(extra_env)
    result = subprocess.run(
        ["bash", str(script), *args],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    commands = log.read_text().splitlines() if log.exists() else []
    return result, commands


def index_of(commands: list[str], fragment: str) -> int:
    return next(index for index, command in enumerate(commands) if fragment in command)


class RolloutContractTest(unittest.TestCase):
    def test_exact_shared_contract_is_checked_in(self):
        raw = CONTRACT.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), EXPECTED_CONTRACT_SHA256)
        contract = json.loads(raw)
        self.assertEqual(contract["forwardPhases"], EXPECTED_FORWARD)
        self.assertEqual(contract["rollbackPhases"], EXPECTED_ROLLBACK)
        self.assertEqual(contract["deploymentWideCacheRefresh"], "PSAMA_PROCESS_RESTART")
        self.assertEqual(contract["schemaRollback"], "KEEP_FORWARD_SCHEMA")
        self.assertFalse(contract["downMigrationAllowed"])
        source = json.loads(CONTRACT_SOURCE.read_text())
        self.assertEqual(source["contractSourceCommit"], EXPECTED_CONTRACT_COMMIT)
        self.assertEqual(source["contractSha256"], EXPECTED_CONTRACT_SHA256)

    def test_update_parses_real_jenkins_xml_and_pins_one_release_checkout(self):
        config = ET.parse(JOBS / "Check For Updates/config.xml").getroot()
        script = xml_script(JOBS / "Check For Updates/config.xml")
        validate_update_script(script)
        shell = config.findtext(".//hudson.tasks.Shell/command") or ""
        self.assertIn('(["PSA", "PSF", "PSM", "AIO"]', shell)
        self.assertNotIn(EXPECTED_CONTRACT_COMMIT, shell)
        self.assertNotIn(EXPECTED_CONTRACT_SHA256, shell)
        self.assertIn("AIO_WORKFLOW_COMMIT", shell)
        self.assertIn('project_job_git_key == "PSA"', shell)
        self.assertIn("banner-rollout-source.json", shell)
        syntax = subprocess.run(
            ["bash", "-n"], input=shell, text=True, capture_output=True, check=False
        )
        self.assertEqual(syntax.returncode, 0, syntax.stderr)

        with self.assertRaises(AssertionError):
            validate_update_script(script.replace("PIC-SURE Database Migrations", "", 1))
        first, second = scheduled_jobs(script)
        reordered = script.replace(first, "TEMP", 1).replace(second, first, 1).replace(
            "TEMP", second, 1
        )
        with self.assertRaises(AssertionError):
            validate_update_script(reordered)

    def test_update_mock_stops_when_migrations_fail(self):
        script = xml_script(JOBS / "Check For Updates/config.xml")
        validate_update_script(script)
        invoked = []
        results = {"PIC-SURE Database Migrations": "FAILURE", "PIC-SURE Pipeline": "SUCCESS"}
        for job in scheduled_jobs(script):
            invoked.append(job)
            if results[job] != "SUCCESS":
                break
        self.assertEqual(invoked, ["PIC-SURE Database Migrations"])

    def test_start_executes_backend_before_public_httpd(self):
        source = (ROOT / "start-picsure.sh").read_text()
        validate_start_script(source)
        self.assertIn("/operations/actuator/health/readiness", source)
        self.assertIn("/system/status", source)
        self.assertIn("RUNNING", source)
        self.assertNotIn("# shellcheck disable=SC1091,SC2086", source)
        with self.assertRaises(AssertionError):
            validate_start_script(source.replace("docker run --name=psama", "docker run --name=omitted", 1))
        reordered = source.replace("docker run --name=psama", "docker run --name=TEMP", 1)
        reordered = reordered.replace("docker run --name=gateway", "docker run --name=psama", 1)
        reordered = reordered.replace("docker run --name=TEMP", "docker run --name=gateway", 1)
        with self.assertRaises(AssertionError):
            validate_start_script(reordered)

        with tempfile.TemporaryDirectory() as tmp:
            config = required_config(Path(tmp) / "config")
            result, commands = run_script(ROOT / "start-picsure.sh", config)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        ordered = [
            "run --name=psama",
            "run --name=pic-sure-operations-service",
            "run --name=pic-sure-hpds-query-service",
            "run --name=gateway",
            "inspect --format={{.State.Health.Status}} psama",
            "inspect --format={{.State.Health.Status}} pic-sure-operations-service",
            "inspect --format={{.State.Health.Status}} pic-sure-hpds-query-service",
            "inspect --format={{.State.Health.Status}} gateway",
            "run --name=httpd",
        ]
        positions = [index_of(commands, fragment) for fragment in ordered]
        self.assertEqual(positions, sorted(positions))

    def test_start_fails_before_docker_when_required_backend_config_is_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = required_config(Path(tmp) / "config")
            (config / "gateway/gateway.env").unlink()
            result, commands = run_script(ROOT / "start-picsure.sh", config)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands, [])

    def test_start_does_not_publish_frontend_after_gateway_health_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = required_config(Path(tmp) / "config")
            result, commands = run_script(
                ROOT / "start-picsure.sh",
                config,
                {"MOCK_UNHEALTHY_CONTAINER": "gateway"},
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("run --name=httpd" in command for command in commands))

    def test_zero_health_poll_interval_fails_before_docker_commands(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = required_config(Path(tmp) / "config")
            result, commands = run_script(
                ROOT / "start-picsure.sh",
                config,
                {"AIO_HEALTH_POLL_SECONDS": "0"},
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands, [])

    def test_rollback_executes_only_after_ordered_attestations_and_keeps_httpd_down(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            state = tmp_path / "state.json"
            state.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "contractSourceCommit": EXPECTED_CONTRACT_COMMIT,
                        "contractSha256": EXPECTED_CONTRACT_SHA256,
                        "completedPhases": EXPECTED_ROLLBACK[:3],
                        "forwardSchemaRetained": True,
                        "downMigrationRequested": False,
                        "rollbackImages": {
                            "frontend": "synthetic/frontend:old",
                            "psama": "synthetic/psama:old",
                            "operations": "synthetic/operations:old",
                            "query": "synthetic/query:old",
                            "gateway": "synthetic/gateway:old",
                        },
                        "rollbackImageIds": {
                            key: "sha256:" + "a" * 64
                            for key in ("frontend", "psama", "operations", "query", "gateway")
                        },
                    }
                )
            )
            result, commands = run_script(ROOT / "rollback-picsure.sh", config, None, str(state))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertLess(
            index_of(commands, "image inspect synthetic/frontend:old"),
            index_of(commands, "tag synthetic/operations:old hms-dbmi/pic-sure-operations-service:LATEST"),
        )
        self.assertLess(
            index_of(commands, "tag synthetic/gateway:old hms-dbmi/pic-sure-gateway:LATEST"),
            index_of(commands, "run --name=pic-sure-operations-service"),
        )
        self.assertLess(index_of(commands, "run --name=gateway"), index_of(commands, "run --name=psama"))
        self.assertFalse(any("run --name=httpd" in command for command in commands))

    def test_rollback_rejects_an_image_id_that_changed_after_attestation(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            state = tmp_path / "state.json"
            state.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "contractSourceCommit": EXPECTED_CONTRACT_COMMIT,
                        "contractSha256": EXPECTED_CONTRACT_SHA256,
                        "completedPhases": EXPECTED_ROLLBACK[:3],
                        "forwardSchemaRetained": True,
                        "downMigrationRequested": False,
                        "rollbackImages": {
                            key: f"synthetic/{key}:old"
                            for key in ("frontend", "psama", "operations", "query", "gateway")
                        },
                        "rollbackImageIds": {
                            key: "sha256:" + ("b" if key == "gateway" else "a") * 64
                            for key in ("frontend", "psama", "operations", "query", "gateway")
                        },
                    }
                )
            )
            result, commands = run_script(ROOT / "rollback-picsure.sh", config, None, str(state))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(command.startswith("tag ") for command in commands))

    def test_rollback_rejects_omitted_or_reordered_preconditions(self):
        for phases in (EXPECTED_ROLLBACK[:2], list(reversed(EXPECTED_ROLLBACK[:3]))):
            with self.subTest(phases=phases), tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                config = required_config(tmp_path / "config")
                state = tmp_path / "state.json"
                state.write_text(
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "contractSourceCommit": EXPECTED_CONTRACT_COMMIT,
                            "contractSha256": EXPECTED_CONTRACT_SHA256,
                            "completedPhases": phases,
                            "forwardSchemaRetained": True,
                            "downMigrationRequested": False,
                            "rollbackImages": {},
                            "rollbackImageIds": {},
                        }
                    )
                )
                result, commands = run_script(
                    ROOT / "rollback-picsure.sh", config, None, str(state)
                )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any(command.startswith("tag ") for command in commands))

    def test_mysql_compose_keeps_database_on_migration_network_with_healthcheck(self):
        compose = (ROOT / "initial-configuration/mysql-docker/docker-compose.yml").read_text()
        self.assertRegex(compose, r"(?m)^\s+healthcheck:$")
        self.assertRegex(compose, r"(?m)^\s+- picsure$")
        self.assertRegex(compose, r"(?ms)^networks:\n\s+picsure:\n\s+external: true$")

    def test_jenkins_jobs_preserve_release_pin_and_call_real_rollback_script(self):
        for job in ("PIC-SURE Database Migrations", "PIC-SURE Pipeline"):
            script = xml_script(JOBS / job / "config.xml")
            self.assertIn("release_control_commit", script)
            self.assertIn("Retrieve Pinned Build Spec", script)
            self.assertIn("projectName: 'Retrieve Pinned Build Spec'", script)
        migrations = xml_script(JOBS / "PIC-SURE Database Migrations/config.xml")
        self.assertIn("migration-release-control-commit.txt", migrations)
        pipeline = xml_script(JOBS / "PIC-SURE Pipeline/config.xml")
        self.assertIn("migration_build_number", pipeline)
        self.assertIn("migration-release-control-commit.txt", pipeline)
        retrieve = ET.parse(JOBS / "Retrieve Pinned Build Spec/config.xml").getroot()
        branch = retrieve.findtext(".//hudson.plugins.git.BranchSpec/name")
        self.assertEqual(branch, "${release_control_commit}")
        retrieve_shell = retrieve.findtext(".//hudson.tasks.Shell/command") or ""
        self.assertIn('test "$GIT_COMMIT" = "$release_control_commit"', retrieve_shell)
        initial = xml_script(JOBS / "Initial Configuration Pipeline/config.xml")
        migration = initial.index("build job: 'PIC-SURE Database Migrations'")
        application = initial.index("build job: 'PIC-SURE Pipeline'")
        self.assertLess(migration, application)
        self.assertIn("release_control_commit", initial[migration:application + 500])
        self.assertIn("migration_build_number", initial[migration:application + 500])
        for image_job in (
            "PIC-SURE Auth Micro-App Build - Jenkinsfile",
            "PIC-SURE Operations Service Build and Deploy",
            "PIC-SURE HPDS Query Service Build and Deploy",
            "PIC-SURE Gateway Build and Deploy",
            "PIC-SURE Frontend Build",
        ):
            self.assertIn(image_job, pipeline)
        rollback = ET.parse(JOBS / "Rollback PIC-SURE/config.xml").getroot()
        command = rollback.findtext(".//hudson.tasks.Shell/command") or ""
        self.assertIn("/scripts/rollback-picsure.sh rollback-state.json", command)
        syntax = subprocess.run(
            ["bash", "-n"], input=command, text=True, capture_output=True, check=False
        )
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        self.assertIsNotNone(rollback.find(".//hudson.plugins.ws__cleanup.PreBuildCleanup"))
        mounts = (ROOT / "start-jenkins.sh").read_text()
        self.assertIn("./rollback-picsure.sh:/scripts/rollback-picsure.sh", mounts)
        self.assertIn("banner-rollout-contract.json:/scripts/banner-rollout-contract.json:ro", mounts)
        self.assertIn("banner-rollout-source.json:/scripts/banner-rollout-source.json:ro", mounts)
        self.assertIn("AIO_WORKFLOW_COMMIT", mounts)
        replace_frontend = ET.parse(JOBS / "Replace Frontend/config.xml").getroot()
        self.assertEqual(replace_frontend.findtext("disabled"), "true")
        jenkins = ET.parse(
            ROOT / "initial-configuration/jenkins/jenkins-docker/config.xml"
        ).getroot()
        deployment_jobs = [
            name.text
            for view in jenkins.findall(".//listView")
            if view.findtext("name") == "Deployment"
            for name in view.findall("./jobNames/string")
        ]
        self.assertIn("Rollback PIC-SURE", deployment_jobs)

    def test_documented_rollback_can_reach_gateway_while_httpd_is_stopped(self):
        readme = (ROOT / "README.md").read_text()
        self.assertIn("http://gateway:8080", readme)
        self.assertIn("Jenkins container", readme)
        initial = xml_script(JOBS / "Initial Configuration Pipeline/config.xml")
        self.assertNotIn("Initial Config and Build", initial)


if __name__ == "__main__":
    unittest.main()
