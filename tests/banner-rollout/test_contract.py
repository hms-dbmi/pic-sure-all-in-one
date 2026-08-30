#!/usr/bin/env python3
import hashlib
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
JOBS = ROOT / "initial-configuration/jenkins/jenkins-docker/jobs"
CONTRACT = ROOT / "initial-configuration/jenkins/jenkins-docker/banner-rollout-contract.json"
CONTRACT_SOURCE = ROOT / "initial-configuration/jenkins/jenkins-docker/banner-rollout-source.json"
WORKFLOW_MANIFEST = ROOT / "initial-configuration/jenkins/jenkins-docker/aio-workflow-files.txt"
VALIDATOR = ROOT / "validate-build-spec.sh"
CHECKSUM_HELPER = ROOT / "aio-sha256.sh"
WORKFLOW_LOCATION_VARIABLES = (
    "AIO_WORKFLOW_SHA256_SCRIPT",
    "AIO_WORKFLOW_MODE",
    "AIO_WORKFLOW_MANIFEST",
    "AIO_WORKFLOW_REPO_ROOT",
    "AIO_WORKFLOW_JENKINS_HOME",
)
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


BUILD_JOB_PATTERN = re.compile(
    r"""\bbuild\s+job\s*:\s*(['"])([^'"]+)\1"""
)
SCHEDULE_JOB_PATTERN = re.compile(
    r"""\bgetItem(?:ByFullName)?\(\s*(['"])([^'"]+)\1\s*\)\s*\.scheduleBuild2\b"""
)


def without_matches(script: str, matches: list[re.Match]) -> str:
    result = script
    for match in reversed(matches):
        result = (
            result[: match.start()]
            + " " * (match.end() - match.start())
            + result[match.end() :]
        )
    return result


def scheduled_jobs(script: str) -> list[str]:
    matches = list(SCHEDULE_JOB_PATTERN.finditer(script))
    if re.search(r"\bscheduleBuild2\b", without_matches(script, matches)):
        raise AssertionError("unresolved Jenkins downstream trigger: scheduleBuild2")
    return [match.group(2) for match in matches]


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
    psama_calls = [
        match.start()
        for match in re.finditer(r"(?m)^\s*start_psama \|\| exit 2$", script)
    ]
    if len(psama_calls) != 2:
        raise AssertionError("start path must have forward and deferred PSAMA call sites")
    operations_position = script.index("docker run --name=pic-sure-operations-service")
    gateway_position = script.index("docker run --name=gateway")
    httpd_position = script.index("docker run --name=httpd")
    if not psama_calls[0] < operations_position < gateway_position < psama_calls[1]:
        raise AssertionError("PSAMA call sites do not implement forward and rollback order")
    for health_gate in (
        "wait_for_container_health psama",
        "wait_for_container_health pic-sure-operations-service",
        "wait_for_container_health pic-sure-hpds-query-service",
        "wait_for_container_health gateway",
    ):
        position = script.index(health_gate, gateway_position)
        if position >= httpd_position:
            raise AssertionError(f"{health_gate} must run before httpd")


def validate_migration_verifier(script: str) -> None:
    required = (
        'getItemByFullName("PIC-SURE Database Migrations")',
        "getBuildByNumber",
        "migrationRun == null",
        "migrationRun.result != Result.SUCCESS",
        "throw new Exception",
    )
    missing = [fragment for fragment in required if fragment not in script]
    if missing:
        raise AssertionError(f"migration success verifier is missing: {missing}")


def validate_pipeline_migration_order(script: str) -> None:
    stage_start = script.index("stage('Verify Migrations')")
    stage_end = script.index("stage('Maven Build')", stage_start)
    stage = script[stage_start:stage_end]
    positions = [
        stage.index("Verify PIC-SURE Database Migration"),
        stage.index("copyArtifacts filter: 'migration-release-control-commit.txt'"),
        stage.index("migratedCommit != params.release_control_commit"),
    ]
    if positions != sorted(positions):
        raise AssertionError("migration success must be verified before its commit marker is consumed")


def workflow_digest(root: Path = ROOT) -> str:
    manifest = root / WORKFLOW_MANIFEST.relative_to(ROOT)
    material = [f"{hashlib.sha256(manifest.read_bytes()).hexdigest()}  aio-workflow-files.txt\n"]
    for entry in manifest.read_text().splitlines():
        if not entry or entry.startswith("#"):
            continue
        source, relative = entry.split(":", 1)
        if source == "repo":
            path = root / relative
        elif source == "jenkins-home":
            path = root / "initial-configuration/jenkins/jenkins-docker" / relative
        else:
            raise AssertionError(f"unknown workflow manifest source: {source}")
        material.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {entry}\n")
    return hashlib.sha256("".join(material).encode()).hexdigest()


def synthetic_build_spec(aio_sha: str, workflow_sha: str, psa_sha=EXPECTED_CONTRACT_COMMIT):
    return {
        "application": [
            {"project_job_git_key": "PSA", "git_hash": psa_sha},
            {"project_job_git_key": "PSF", "git_hash": "b" * 40},
            {"project_job_git_key": "PSM", "git_hash": "c" * 40},
            {"project_job_git_key": "AIO", "git_hash": aio_sha},
        ],
        "bannerRollout": {
            "contractSourceCommit": EXPECTED_CONTRACT_COMMIT,
            "contractSha256": EXPECTED_CONTRACT_SHA256,
            "releaseControlCommitSource": "pipeline_git_commit.txt",
            "aioWorkflowSha256": workflow_sha,
            "forwardPhases": EXPECTED_FORWARD,
            "rollbackPhases": EXPECTED_ROLLBACK,
            "schemaRollback": "KEEP_FORWARD_SCHEMA",
            "downMigrationAllowed": False,
        },
    }


def run_validator(
    spec: dict, workflow_sha: str, aio_commit: str, extra_env=None
):
    with tempfile.TemporaryDirectory() as tmp:
        spec_path = Path(tmp) / "build-spec.json"
        spec_path.write_text(json.dumps(spec))
        env = os.environ.copy()
        env.update(
            {
                "AIO_ROLLOUT_CONTRACT_FILE": str(CONTRACT),
                "AIO_ROLLOUT_SOURCE_FILE": str(CONTRACT_SOURCE),
                "AIO_WORKFLOW_SHA256": workflow_sha,
                "AIO_WORKFLOW_COMMIT": aio_commit,
            }
        )
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", str(VALIDATOR), str(spec_path)],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )


def copy_installed_jenkins_jobs(jenkins_home: Path) -> None:
    for entry in WORKFLOW_MANIFEST.read_text().splitlines():
        if not entry.startswith("jenkins-home:"):
            continue
        relative = Path(entry.split(":", 1)[1])
        source = ROOT / "initial-configuration/jenkins/jenkins-docker" / relative
        target = jenkins_home / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def create_installed_validator_bundle(directory: Path) -> Path:
    scripts = directory / "scripts"
    scripts.mkdir()
    validator = scripts / "validate-build-spec.sh"
    shutil.copy2(VALIDATOR, validator)
    shutil.copy2(CONTRACT, scripts / "banner-rollout-contract.json")
    shutil.copy2(CONTRACT_SOURCE, scripts / "banner-rollout-source.json")
    if CHECKSUM_HELPER.exists():
        shutil.copy2(CHECKSUM_HELPER, scripts / CHECKSUM_HELPER.name)
    workflow_root = directory / "aio-workflow"
    workflow_root.mkdir()
    shutil.copy2(WORKFLOW_MANIFEST, workflow_root / "aio-workflow-files.txt")
    copy_installed_jenkins_jobs(directory / "var/jenkins_home")
    for entry in WORKFLOW_MANIFEST.read_text().splitlines():
        if not entry.startswith("repo:"):
            continue
        relative = entry.split(":", 1)[1]
        source = ROOT / relative
        target = workflow_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    return validator


def fake_bin(directory: Path) -> Path:
    bin_dir = directory / "bin"
    bin_dir.mkdir()
    docker = bin_dir / "docker"
    docker.write_text(
        """#!/usr/bin/env bash
set -u
printf '%s\\n' "$*" >> "$MOCK_DOCKER_LOG"
if [[ "${1:-}" == "run" ]]; then
  name=""
  health=""
  previous=""
  for argument in "$@"; do
    case "$argument" in
      --name=*) name="${argument#--name=}" ;;
      --health-cmd=*) health="${argument#--health-cmd=}" ;;
      *)
        if [[ "$previous" == "--name" ]]; then
          name="$argument"
        elif [[ "$previous" == "--health-cmd" ]]; then
          health="$argument"
        fi
        ;;
    esac
    previous="$argument"
  done
  if [[ -n "$name" && -n "$health" ]]; then
    printf '%s\\n' "$health" > "$MOCK_DOCKER_STATE/$name.health"
  fi
elif [[ "$*" == *"inspect --format={{.State.Running}}"* && "$*" != *"RestartPolicy.Name"* ]]; then
  name="${*: -1}"
  if [[ "$name" == "httpd" ]]; then
    printf '%s\\n' "${MOCK_HTTPD_RUNNING:-true}"
  else
    printf '%s\\n' true
  fi
elif [[ "$*" == *"inspect --format={{.HostConfig.RestartPolicy.Name}}"* ]]; then
  printf '%s\\n' "${MOCK_HTTPD_RESTART_POLICY:-no}"
elif [[ "$*" == *"inspect --format={{.State.Health.Status}}"* ]]; then
  name="${*: -1}"
  if [[ "${MOCK_UNHEALTHY_CONTAINER:-}" == "$name" ]]; then
    printf '%s\\n' unhealthy
  elif [[ -f "$MOCK_DOCKER_STATE/$name.health" ]]; then
    IFS= read -r health < "$MOCK_DOCKER_STATE/$name.health"
    if bash -c "$health"; then
      if [[ "$name" == "gateway" ]]; then
        touch "$MOCK_DOCKER_STATE/gateway-health-checked"
      fi
      printf '%s\\n' healthy
    else
      printf '%s\\n' unhealthy
    fi
  else
    printf '%s\\n' healthy
  fi
elif [[ "$1 ${2:-}" == "container inspect" ]]; then
  name="${*: -1}"
  if [[ "$name" == "httpd" && -n "${MOCK_HTTPD_TERMINAL_INSPECT_ERROR:-}" && -f "$MOCK_DOCKER_STATE/gateway-health-checked" ]]; then
    printf '%s\\n' "$MOCK_HTTPD_TERMINAL_INSPECT_ERROR" >&2
    exit 42
  fi
  if [[ "$name" == "httpd" && -n "${MOCK_HTTPD_INSPECT_ERROR:-}" ]]; then
    printf '%s\\n' "$MOCK_HTTPD_INSPECT_ERROR" >&2
    exit 41
  fi
  if [[ "$name" == "httpd" && "${MOCK_HTTPD_PRESENT:-false}" == "true" ]]; then
    if [[ "$*" == *"State.Running"*"RestartPolicy.Name"* ]]; then
      printf '%s %s\\n' "${MOCK_HTTPD_RUNNING:-true}" "${MOCK_HTTPD_RESTART_POLICY:-no}"
    fi
    exit 0
  fi
  if [[ "$name" == "httpd" && "${MOCK_HTTPD_REAPPEARS:-false}" == "true" && -f "$MOCK_DOCKER_STATE/gateway-health-checked" ]]; then
    if [[ "$*" == *"State.Running"*"RestartPolicy.Name"* ]]; then
      printf '%s %s\\n' "${MOCK_HTTPD_RUNNING:-true}" "${MOCK_HTTPD_RESTART_POLICY:-no}"
    fi
    exit 0
  fi
  printf '%s\\n' "Error response from daemon: No such container: $name" >&2
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
    wget = bin_dir / "wget"
    wget.write_text(
        """#!/usr/bin/env bash
set -u
printf '%s\\n' "$*" >> "$MOCK_WGET_LOG"
if [[ -n "${MOCK_FAILED_HEALTH_PATH:-}" && "$*" == *"$MOCK_FAILED_HEALTH_PATH"* ]]; then
  exit 1
fi
"""
    )
    wget.chmod(0o755)
    curl = bin_dir / "curl"
    curl.write_text(
        """#!/usr/bin/env bash
set -u
printf '%s\\n' "$*" >> "$MOCK_CURL_LOG"
if [[ -n "${MOCK_FAILED_HEALTH_PATH:-}" && "$*" == *"$MOCK_FAILED_HEALTH_PATH"* ]]; then
  exit 1
fi
"""
    )
    curl.chmod(0o755)
    git = bin_dir / "git"
    git.write_text(
        """#!/usr/bin/env bash
set -u
printf '%s\\n' "$*" >> "$MOCK_GIT_LOG"
if [[ "${MOCK_GIT_MODE:-unavailable}" != "safe" || "$*" != *"-c safe.directory="* ]]; then
  exit 1
fi
if [[ "$*" == *"rev-parse --is-inside-work-tree"* ]]; then
  printf '%s\\n' true
elif [[ "$*" == *"rev-parse HEAD"* ]]; then
  printf '%s\\n' "${MOCK_GIT_COMMIT:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
else
  exit 1
fi
"""
    )
    git.chmod(0o755)
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
    state = work / "docker-state"
    state.mkdir()
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{fake_bin(work)}:{env['PATH']}",
            "MOCK_DOCKER_LOG": str(log),
            "MOCK_DOCKER_STATE": str(state),
            "MOCK_WGET_LOG": str(work / "wget.log"),
            "MOCK_CURL_LOG": str(work / "curl.log"),
            "MOCK_GIT_LOG": str(work / "git.log"),
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


def split_job_names(value: str) -> set[str]:
    return {name.strip() for name in value.split(",") if name.strip()}


def jenkins_job_references(config: Path) -> set[str]:
    root = ET.parse(config).getroot()
    script = xml_script(config)
    build_matches = list(BUILD_JOB_PATTERN.finditer(script))
    schedule_matches = list(SCHEDULE_JOB_PATTERN.finditer(script))
    unresolved = without_matches(script, build_matches + schedule_matches)
    if re.search(r"\bbuild\s+job\s*:|\bscheduleBuild2\b", unresolved):
        raise AssertionError(
            f"unresolved Jenkins downstream trigger in {config}"
        )
    children = {match.group(2) for match in build_matches + schedule_matches}
    recognized = set()
    for node in root.findall(".//hudson.tasks.BuildTrigger/childProjects"):
        recognized.add(id(node))
        children.update(split_job_names(node.text or ""))
    for node in root.findall(
        ".//hudson.plugins.parameterizedtrigger.BuildTrigger/"
        "configs/hudson.plugins.parameterizedtrigger.BuildTriggerConfig/projects"
    ):
        recognized.add(id(node))
        children.update(split_job_names(node.text or ""))
    for node in root.iter():
        if node.tag in {"projects", "childProjects"} and (node.text or "").strip():
            if id(node) not in recognized:
                raise AssertionError(
                    f"unknown Jenkins downstream trigger form in {config}: {node.tag}"
                )
    return children


def validate_declarative_convergence(config: Path) -> None:
    root = ET.parse(config).getroot()
    script = xml_script(config)
    if "pipeline {" not in script:
        return
    property_class = (
        "org.jenkinsci.plugins.workflow.job.properties."
        "DisableConcurrentBuildsJobProperty"
    )
    tracker = root.find(
        ".//org.jenkinsci.plugins.pipeline.modeldefinition.actions."
        "DeclarativeJobPropertyTrackerAction"
    )
    if tracker is None:
        raise AssertionError(f"declarative property tracker is missing: {config}")
    tracked = {
        node.text or "" for node in tracker.findall("./jobProperties/string")
    }
    has_directive = "disableConcurrentBuilds()" in script
    has_tracker = property_class in tracked
    property_node = root.find(f"./properties/{property_class}")
    has_property = property_node is not None
    if len({has_directive, has_tracker, has_property}) != 1:
        raise AssertionError(
            f"disableConcurrentBuilds is not converged in {config}: "
            f"directive={has_directive}, tracker={has_tracker}, property={has_property}"
        )
    if has_property and property_node.findtext("abortPrevious") != "false":
        raise AssertionError(
            f"disableConcurrentBuilds abortPrevious is not false in {config}"
        )


def transitive_release_jobs(roots: set[str]) -> set[str]:
    discovered = set()
    pending = list(roots)
    while pending:
        job = pending.pop()
        if job in discovered:
            continue
        config = JOBS / job / "config.xml"
        if not config.exists():
            raise AssertionError(f"release job is missing: {job}")
        discovered.add(job)
        children = jenkins_job_references(config)
        pending.extend(children - discovered)
    return discovered


def rollback_state() -> dict:
    return {
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
            key: "sha256:" + "a" * 64
            for key in ("frontend", "psama", "operations", "query", "gateway")
        },
    }


def update_git_mock() -> str:
    return """#!/usr/bin/env bash
set -u
printf '%s\\n' "$*" >> "$MOCK_GIT_LOG"
state=$(cat "$MOCK_GIT_STATE")
case "$*" in
  *"cat-file -e "*) exit 0 ;;
  *"symbolic-ref --short HEAD"*)
    [[ "$state" == "pin" ]] && printf '%s\\n' picsure-aio-release-pin || printf '%s\\n' main
    ;;
  *"config --get picsure.updateBranch"*) printf '%s\\n' main ;;
  *"config picsure.updateBranch "*) exit 0 ;;
  *"checkout -B picsure-aio-release-pin "*)
    [[ "${MOCK_CHECKOUT_FAIL:-false}" != "true" ]] || exit 1
    printf '%s\\n' pin > "$MOCK_GIT_STATE"
    ;;
  *"checkout main"*) printf '%s\\n' main > "$MOCK_GIT_STATE" ;;
  *"rev-parse HEAD"*) printf '%s\\n' "$MOCK_AIO_REF" ;;
  *"pull --ff-only"*) [[ "$state" == "main" ]] ;;
  *" pull") [[ "$state" == "main" ]] ;;
  *) exit 1 ;;
esac
"""


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
        self.assertIn("/scripts/validate-build-spec.sh build-spec.json", shell)
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
        self.assertIn("/actuator/health/liveness", source)
        self.assertIn("/operations/banners/active/v2", source)
        self.assertNotIn("/system/status", source)
        with self.assertRaises(AssertionError):
            validate_start_script(source.replace("docker run --name=psama", "docker run --name=omitted", 1))
        reordered = source.replace("docker run --name=psama", "docker run --name=TEMP", 1)
        reordered = reordered.replace("docker run --name=gateway", "docker run --name=psama", 1)
        reordered = reordered.replace("docker run --name=TEMP", "docker run --name=gateway", 1)
        with self.assertRaises(AssertionError):
            validate_start_script(reordered)
        missing_deferred_call = source.rsplit("start_psama || exit 2", 1)
        with self.assertRaises(AssertionError):
            validate_start_script(": # omitted deferred PSAMA call".join(missing_deferred_call))

        with tempfile.TemporaryDirectory() as tmp:
            config = required_config(Path(tmp) / "config")
            result, commands = run_script(ROOT / "start-picsure.sh", config)
            health_commands = (Path(tmp) / "wget.log").read_text().splitlines()
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
        self.assertEqual(
            health_commands,
            [
                "-q --spider http://127.0.0.1:8090/auth/actuator/health",
                "-q --spider http://127.0.0.1:8080/operations/actuator/health/readiness",
                "-q --spider http://127.0.0.1:8080/actuator/health/liveness",
                "-q --spider http://127.0.0.1:8080/operations/banners/active/v2",
            ],
        )

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
                {"MOCK_FAILED_HEALTH_PATH": "/operations/banners/active/v2"},
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

    def test_caller_controlled_frontend_publish_flag_must_be_unset(self):
        for value in ("yes", "false", ""):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as tmp:
                config = required_config(Path(tmp) / "config")
                result, commands = run_script(
                    ROOT / "start-picsure.sh",
                    config,
                    {"AIO_PUBLISH_FRONTEND": value},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(commands, [])

    def test_rollback_rejects_running_httpd_before_image_or_service_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            state = tmp_path / "state.json"
            state.write_text(json.dumps(rollback_state()))
            result, commands = run_script(
                ROOT / "rollback-picsure.sh",
                config,
                {
                    "MOCK_HTTPD_PRESENT": "true",
                    "MOCK_HTTPD_RUNNING": "true",
                    "MOCK_HTTPD_RESTART_POLICY": "no",
                },
                str(state),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("httpd is running", result.stderr)
        self.assertFalse(any(command.startswith("image inspect") for command in commands))
        self.assertFalse(any(command.startswith("tag ") for command in commands))
        self.assertFalse(any("run --name=" in command for command in commands))

    def test_rollback_rejects_restartable_stopped_httpd_without_side_effects(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            state = tmp_path / "state.json"
            state.write_text(json.dumps(rollback_state()))
            result, commands = run_script(
                ROOT / "rollback-picsure.sh",
                config,
                {
                    "MOCK_HTTPD_PRESENT": "true",
                    "MOCK_HTTPD_RUNNING": "false",
                    "MOCK_HTTPD_RESTART_POLICY": "always",
                },
                str(state),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restart policy", result.stderr)
        self.assertFalse(any(command.startswith("image inspect") for command in commands))
        self.assertFalse(any(command.startswith("tag ") for command in commands))
        self.assertFalse(any("run --name=" in command for command in commands))

    def test_rollback_rejects_initial_httpd_inspect_error_without_side_effects(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            state = tmp_path / "state.json"
            state.write_text(json.dumps(rollback_state()))
            result, commands = run_script(
                ROOT / "rollback-picsure.sh",
                config,
                {"MOCK_HTTPD_INSPECT_ERROR": "synthetic Docker API failure"},
                str(state),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("synthetic Docker API failure", result.stderr)
        self.assertFalse(any(command.startswith("image inspect") for command in commands))
        self.assertFalse(any(command.startswith("tag ") for command in commands))
        self.assertFalse(any("run --name=" in command for command in commands))

    def test_rollback_rejects_terminal_httpd_inspect_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            state = tmp_path / "state.json"
            state.write_text(json.dumps(rollback_state()))
            result, commands = run_script(
                ROOT / "rollback-picsure.sh",
                config,
                {"MOCK_HTTPD_TERMINAL_INSPECT_ERROR": "synthetic terminal API failure"},
                str(state),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("synthetic terminal API failure", result.stderr)
        self.assertFalse(any("run --name=httpd" in command for command in commands))
        self.assertNotIn(
            "Rollback backend started with the forward schema retained",
            result.stdout,
        )

    def test_rollback_accepts_present_stopped_httpd_with_restart_disabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            state = tmp_path / "state.json"
            state.write_text(json.dumps(rollback_state()))
            result, commands = run_script(
                ROOT / "rollback-picsure.sh",
                config,
                {
                    "MOCK_HTTPD_PRESENT": "true",
                    "MOCK_HTTPD_RUNNING": "false",
                    "MOCK_HTTPD_RESTART_POLICY": "no",
                },
                str(state),
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(any(command.startswith("tag ") for command in commands))
        self.assertFalse(any("run --name=httpd" in command for command in commands))
        httpd_inspections = [
            command
            for command in commands
            if "inspect" in command and command.endswith(" httpd")
        ]
        self.assertEqual(len(httpd_inspections), 3)
        self.assertTrue(
            all(
                command.startswith(
                    "container inspect --format={{.State.Running}} "
                    "{{.HostConfig.RestartPolicy.Name}}"
                )
                for command in httpd_inspections
            )
        )

    def test_rollback_mode_start_independently_requires_restart_proof(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            state = tmp_path / "state.json"
            state.write_text(json.dumps(rollback_state()))
            result, commands = run_script(
                ROOT / "start-picsure.sh",
                config,
                {
                    "MOCK_HTTPD_PRESENT": "true",
                    "MOCK_HTTPD_RUNNING": "false",
                    "MOCK_HTTPD_RESTART_POLICY": "unless-stopped",
                },
                "--rollback-state",
                str(state),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("restart policy", result.stderr)
        self.assertFalse(any(command.startswith("image inspect") for command in commands))
        self.assertFalse(any("run --name=" in command for command in commands))

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

    def test_rollback_uses_gateway_liveness_and_reaches_final_httpd_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            state = tmp_path / "state.json"
            state.write_text(json.dumps(rollback_state()))
            result, commands = run_script(
                ROOT / "rollback-picsure.sh",
                config,
                {
                    "MOCK_FAILED_HEALTH_PATH": "/operations/banners/active/v2",
                    "MOCK_HTTPD_REAPPEARS": "true",
                },
                str(state),
            )
            health_commands = (tmp_path / "wget.log").read_text().splitlines()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("httpd restarted during fail-closed rollback", result.stderr)
        self.assertEqual(
            health_commands[-1],
            "-q --spider http://127.0.0.1:8080/actuator/health/liveness",
        )
        self.assertFalse(
            any("/operations/banners/active/v2" in command for command in health_commands)
        )
        self.assertFalse(any("/system/status" in command for command in health_commands))
        self.assertFalse(any("run --name=httpd" in command for command in commands))

    def test_normal_start_rejects_inherited_rollback_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = required_config(Path(tmp) / "config")
            result, commands = run_script(
                ROOT / "start-picsure.sh",
                config,
                {
                    "AIO_PUBLISH_FRONTEND": "false",
                    "AIO_RECREATE_PSAMA_AFTER_BACKEND": "true",
                    "AIO_GATEWAY_HEALTH_MODE": "legacy",
                    "AIO_ROLLBACK_STATE_VERIFIED": "true",
                },
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands, [])

    def test_start_rejects_missing_rollback_state_handoff(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            result, commands = run_script(
                ROOT / "start-picsure.sh",
                config,
                None,
                "--rollback-state",
                str(tmp_path / "missing.json"),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands, [])

    def test_start_rejects_tampered_rollback_state_handoff(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            state = tmp_path / "state.json"
            tampered = rollback_state()
            tampered["completedPhases"] = list(reversed(EXPECTED_ROLLBACK[:3]))
            state.write_text(json.dumps(tampered))
            result, commands = run_script(
                ROOT / "start-picsure.sh",
                config,
                None,
                "--rollback-state",
                str(state),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands, [])

    def test_start_rejects_stale_rollback_contract_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            state = tmp_path / "state.json"
            stale = rollback_state()
            stale["contractSourceCommit"] = "0" * 40
            state.write_text(json.dumps(stale))
            result, commands = run_script(
                ROOT / "start-picsure.sh",
                config,
                None,
                "--rollback-state",
                str(state),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands, [])

    def test_start_accepts_valid_explicit_rollback_state_handoff(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            state = tmp_path / "state.json"
            state.write_text(json.dumps(rollback_state()))
            result, commands = run_script(
                ROOT / "start-picsure.sh",
                config,
                None,
                "--rollback-state",
                str(state),
            )
            health_commands = (tmp_path / "wget.log").read_text().splitlines()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            health_commands[-1],
            "-q --spider http://127.0.0.1:8080/actuator/health/liveness",
        )
        self.assertFalse(
            any("/operations/banners/active/v2" in command for command in health_commands)
        )
        self.assertLess(index_of(commands, "run --name=gateway"), index_of(commands, "run --name=psama"))
        self.assertFalse(any("run --name=httpd" in command for command in commands))

    def test_start_job_forces_forward_v2_and_frontend(self):
        start = ET.parse(JOBS / "Start PIC-SURE/config.xml").getroot()
        command = start.findtext(".//hudson.tasks.Shell/command") or ""
        self.assertIn("./start-picsure.sh --forward", command)

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            config = required_config(tmp_path / "config")
            result, commands = run_script(
                ROOT / "start-picsure.sh", config, None, "--forward"
            )
            health_commands = (tmp_path / "wget.log").read_text().splitlines()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            health_commands[-1],
            "-q --spider http://127.0.0.1:8080/operations/banners/active/v2",
        )
        self.assertTrue(any("run --name=httpd" in command for command in commands))

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

    def test_shared_validator_executes_tuple_and_workflow_content_predicates(self):
        digest = workflow_digest()
        aio_commit = "a" * 40
        spec = synthetic_build_spec(aio_commit, digest)
        result = run_validator(spec, digest, aio_commit)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        stale_boot_digest = run_validator(spec, "d" * 64, aio_commit)
        self.assertEqual(
            stale_boot_digest.returncode,
            0,
            stale_boot_digest.stdout + stale_boot_digest.stderr,
        )

        wrong_workflow = synthetic_build_spec(aio_commit, "d" * 64)
        dirty = run_validator(wrong_workflow, digest, aio_commit)
        self.assertNotEqual(dirty.returncode, 0)
        self.assertIn("workflow content", dirty.stderr)

        wrong_commit = run_validator(spec, digest, "e" * 40)
        self.assertNotEqual(wrong_commit.returncode, 0)
        self.assertIn(f"--aio-ref {aio_commit}", wrong_commit.stderr)

        wrong_psa = synthetic_build_spec(aio_commit, digest, psa_sha="f" * 40)
        mismatch = run_validator(wrong_psa, digest, aio_commit)
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn("PSA", mismatch.stderr)

        unavailable = run_validator(spec, digest, "UNAVAILABLE")
        self.assertEqual(unavailable.returncode, 0, unavailable.stdout + unavailable.stderr)

    def test_validator_rejects_every_caller_controlled_workflow_location(self):
        digest = workflow_digest()
        aio_commit = "a" * 40
        spec = synthetic_build_spec(aio_commit, digest)
        for variable in WORKFLOW_LOCATION_VARIABLES:
            with self.subTest(variable=variable):
                hostile_value = (
                    "source"
                    if variable == "AIO_WORKFLOW_MODE"
                    else "/tmp/hostile-workflow-location"
                )
                result = run_validator(
                    spec,
                    digest,
                    aio_commit,
                    {variable: hostile_value},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{variable} is caller-controlled", result.stderr)

    def test_validator_rehashes_active_jenkins_jobs_for_each_rollout(self):
        digest = workflow_digest()
        aio_commit = "a" * 40
        spec = synthetic_build_spec(aio_commit, digest)
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            validator = create_installed_validator_bundle(tmp_path)
            spec_path = tmp_path / "build-spec.json"
            spec_path.write_text(json.dumps(spec))
            environment = os.environ.copy()
            environment.update(
                {
                    "AIO_WORKFLOW_SHA256": "d" * 64,
                    "AIO_WORKFLOW_COMMIT": aio_commit,
                }
            )
            coherent = subprocess.run(
                ["bash", str(validator), str(spec_path)],
                cwd=tmp_path,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            hostile_script = tmp_path / "scripts/workflow-sha256.sh"
            hostile_script.write_text(f"#!/usr/bin/env bash\nprintf '%s\\n' {digest}\n")
            hostile_script.chmod(0o755)
            active_pipeline = (
                tmp_path / "var/jenkins_home/jobs/PIC-SURE Pipeline/config.xml"
            )
            active_pipeline.write_text(active_pipeline.read_text() + "\n")
            drifted = subprocess.run(
                ["bash", str(validator), str(spec_path)],
                cwd=tmp_path,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(coherent.returncode, 0, coherent.stdout + coherent.stderr)
        self.assertNotEqual(drifted.returncode, 0)
        self.assertIn("workflow content", drifted.stderr)

    def test_validator_defaults_work_at_repo_root_and_direct_validator_mount(self):
        digest = workflow_digest()
        aio_commit = "a" * 40
        spec = synthetic_build_spec(aio_commit, digest)
        root_result = run_validator(spec, digest, aio_commit)
        self.assertEqual(root_result.returncode, 0, root_result.stdout + root_result.stderr)

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            validator = create_installed_validator_bundle(tmp_path)
            spec_path = tmp_path / "build-spec.json"
            spec_path.write_text(json.dumps(spec))
            env = os.environ.copy()
            env.update(
                {
                    "AIO_WORKFLOW_SHA256": digest,
                    "AIO_WORKFLOW_COMMIT": aio_commit,
                }
            )
            mounted_result = subprocess.run(
                ["bash", str(validator), str(spec_path)],
                cwd=tmp,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(
            mounted_result.returncode,
            0,
            mounted_result.stdout + mounted_result.stderr,
        )

    def test_validator_reports_malformed_rollout_source(self):
        digest = workflow_digest()
        aio_commit = "a" * 40
        spec = synthetic_build_spec(aio_commit, digest)
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            source = tmp_path / "banner-rollout-source.json"
            source.write_text("{not-json")
            spec_path = tmp_path / "build-spec.json"
            spec_path.write_text(json.dumps(spec))
            env = os.environ.copy()
            env.update(
                {
                    "AIO_ROLLOUT_CONTRACT_FILE": str(CONTRACT),
                    "AIO_ROLLOUT_SOURCE_FILE": str(source),
                    "AIO_WORKFLOW_SHA256": digest,
                    "AIO_WORKFLOW_COMMIT": aio_commit,
                }
            )
            result = subprocess.run(
                ["bash", str(VALIDATOR), str(spec_path)],
                cwd=tmp,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("rollout source metadata", result.stderr)

    def test_workflow_checksum_rejects_bad_mode_without_printing_a_digest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copy2(ROOT / "workflow-sha256.sh", root / "workflow-sha256.sh")
            if CHECKSUM_HELPER.exists():
                shutil.copy2(CHECKSUM_HELPER, root / CHECKSUM_HELPER.name)
            manifest = root / "initial-configuration/jenkins/jenkins-docker/aio-workflow-files.txt"
            manifest.parent.mkdir(parents=True)
            manifest.write_text("repo:present.txt\n")
            (root / "present.txt").write_text("present\n")
            invalid_mode = subprocess.run(
                ["bash", str(root / "workflow-sha256.sh")],
                cwd=root,
                env={**os.environ, "AIO_WORKFLOW_MODE": "typo"},
                text=True,
                capture_output=True,
                check=False,
            )
            manifest.write_text("repo:missing.txt\n")
            missing_file = subprocess.run(
                ["bash", str(root / "workflow-sha256.sh")],
                cwd=root,
                env={**os.environ, "AIO_WORKFLOW_MODE": "source"},
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(invalid_mode.returncode, 2)
        self.assertIn("workflow mode", invalid_mode.stderr)
        self.assertEqual(invalid_mode.stdout, "")
        self.assertEqual(missing_file.returncode, 2)
        self.assertEqual(missing_file.stdout, "")

    def test_workflow_checksum_propagates_hash_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copy2(ROOT / "workflow-sha256.sh", root / "workflow-sha256.sh")
            shutil.copy2(CHECKSUM_HELPER, root / "aio-sha256.sh")
            self.assertEqual(
                (root / "aio-sha256.sh").read_bytes(), CHECKSUM_HELPER.read_bytes()
            )
            bin_dir = root / "bin"
            bin_dir.mkdir()
            sha256sum = bin_dir / "sha256sum"
            sha256sum.write_text(
                """#!/usr/bin/env bash
if [[ "$1" == */present.txt ]]; then
  echo "synthetic checksum read failure" >&2
  exit 23
fi
printf '%064d  %s\\n' 0 "$1"
"""
            )
            sha256sum.chmod(0o755)
            manifest = root / "initial-configuration/jenkins/jenkins-docker/aio-workflow-files.txt"
            manifest.parent.mkdir(parents=True)
            manifest.write_text("repo:present.txt\n")
            (root / "present.txt").write_text("present\n")
            result = subprocess.run(
                ["bash", str(root / "workflow-sha256.sh")],
                cwd=root,
                env={
                    **os.environ,
                    "PATH": f"{bin_dir}:{os.environ['PATH']}",
                    "AIO_WORKFLOW_MODE": "source",
                },
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 23)
        self.assertEqual(result.stdout, "")
        self.assertIn("synthetic checksum read failure", result.stderr)

    def test_transitive_release_jobs_are_bound_by_the_workflow_manifest(self):
        release_jobs = transitive_release_jobs(
            {"Check For Updates", "Initial Configuration Pipeline", "Rollback PIC-SURE"}
        )
        self.assertIn("Migrate Dictionary Database", release_jobs)
        self.assertIn("Retrieve Build Spec", release_jobs)
        bound_jobs = {
            entry.removeprefix("jenkins-home:jobs/").removesuffix("/config.xml")
            for entry in WORKFLOW_MANIFEST.read_text().splitlines()
            if entry.startswith("jenkins-home:jobs/")
        }
        self.assertEqual(release_jobs - bound_jobs, set())

    def test_bound_declarative_jobs_are_persisted_without_first_run_rewrite(self):
        bound_configs = [
            ROOT / "initial-configuration/jenkins/jenkins-docker" / entry.split(":", 1)[1]
            for entry in WORKFLOW_MANIFEST.read_text().splitlines()
            if entry.startswith("jenkins-home:jobs/")
        ]
        declarative_configs = [
            config for config in bound_configs if "pipeline {" in xml_script(config)
        ]
        self.assertIn(JOBS / "PIC-SURE Pipeline/config.xml", declarative_configs)
        for config in declarative_configs:
            with self.subTest(config=config):
                validate_declarative_convergence(config)

    def test_transitive_scanner_fails_closed_on_unknown_trigger_form(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.xml"
            config.write_text(
                "<project><publishers><mystery.Trigger>"
                "<projects>Unbound Release Job</projects>"
                "</mystery.Trigger></publishers></project>"
            )
            with self.assertRaisesRegex(
                AssertionError, "unknown Jenkins downstream trigger form"
            ):
                jenkins_job_references(config)

    def test_trigger_scanner_discovers_supported_literal_groovy_forms(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.xml"
            config.write_text(
                "<flow-definition><definition><script><![CDATA["
                'build job: "Double Quoted Build"\n'
                "Jenkins.instance.getItem('Literal Scheduled Job').scheduleBuild2(0)"
                "]]></script></definition></flow-definition>"
            )
            self.assertEqual(
                jenkins_job_references(config),
                {"Double Quoted Build", "Literal Scheduled Job"},
            )

    def test_trigger_scanner_rejects_dynamic_groovy_forms(self):
        for groovy in (
            "build job: targetJob",
            "Jenkins.instance.getItemByFullName(targetJob).scheduleBuild2(0)",
            "resolvedJob.scheduleBuild2(0)",
        ):
            with self.subTest(groovy=groovy), tempfile.TemporaryDirectory() as tmp:
                config = Path(tmp) / "config.xml"
                config.write_text(
                    "<flow-definition><definition><script><![CDATA["
                    f"{groovy}"
                    "]]></script></definition></flow-definition>"
                )
                with self.assertRaisesRegex(
                    AssertionError, "unresolved Jenkins downstream trigger"
                ):
                    jenkins_job_references(config)

    def test_exact_ref_update_handles_absent_jenkins_and_restores_branch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shutil.copy2(ROOT / "update-jenkins.sh", root / "update-jenkins.sh")
            shutil.copy2(ROOT / "stop-jenkins.sh", root / "stop-jenkins.sh")
            (root / "start-jenkins.sh").write_text(
                "#!/usr/bin/env bash\nprintf 'start\\n' >> \"$MOCK_JENKINS_LOG\"\n"
            )
            (root / "stop-jenkins.sh").chmod(0o755)
            (root / "start-jenkins.sh").chmod(0o755)
            (root / "initial-configuration/jenkins/jenkins-docker/jobs").mkdir(parents=True)
            (root / "initial-configuration/jenkins/jenkins-docker/jobs/job.xml").write_text("<job/>\n")
            config = root / "config/jenkins_home/jobs"
            config.mkdir(parents=True)
            (config / "old.xml").write_text("<old/>\n")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            docker = bin_dir / "docker"
            docker.write_text(
                """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$MOCK_UPDATE_DOCKER_LOG"
if [[ "${1:-}" == "stop" || "${1:-}" == "rm" ]]; then
  exit 1
fi
if [[ "${1:-} ${2:-}" == "container inspect" ]]; then
  if [[ -n "${MOCK_DOCKER_INSPECT_ERROR:-}" ]]; then
    echo "synthetic Docker daemon failure" >&2
    exit "$MOCK_DOCKER_INSPECT_ERROR"
  fi
  echo "Error: No such container: jenkins" >&2
  exit 1
fi
exit 0
"""
            )
            docker.chmod(0o755)
            git = bin_dir / "git"
            git.write_text(update_git_mock())
            git.chmod(0o755)
            state = root / "git-state"
            state.write_text("main\n")
            aio_ref = "a" * 40
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "DOCKER_CONFIG_DIR": str(root / "config"),
                    "MOCK_GIT_LOG": str(root / "git.log"),
                    "MOCK_GIT_STATE": str(state),
                    "MOCK_AIO_REF": aio_ref,
                    "MOCK_JENKINS_LOG": str(root / "jenkins.log"),
                    "MOCK_UPDATE_DOCKER_LOG": str(root / "update-docker.log"),
                }
            )
            pinned = subprocess.run(
                ["bash", str(root / "update-jenkins.sh"), "--jobs-only", "--aio-ref", aio_ref],
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            normal = subprocess.run(
                ["bash", str(root / "update-jenkins.sh"), "--jobs-only"],
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            git_commands = (root / "git.log").read_text()
            update_docker_commands = (root / "update-docker.log").read_text()
            final_state = state.read_text().strip()
            (root / "jenkins.log").write_text("")
            docker_log_before_failure = (root / "update-docker.log").read_text()
            failed_checkout = subprocess.run(
                ["bash", str(root / "update-jenkins.sh"), "--jobs-only", "--aio-ref", aio_ref],
                cwd=root,
                env={**env, "MOCK_CHECKOUT_FAIL": "true"},
                text=True,
                capture_output=True,
                check=False,
            )
            jenkins_commands_after_failure = (root / "jenkins.log").read_text()
            docker_log_after_failure = (root / "update-docker.log").read_text()
            (root / "jenkins.log").write_text("")
            inspect_failure = subprocess.run(
                ["bash", str(root / "update-jenkins.sh"), "--jobs-only"],
                cwd=root,
                env={**env, "MOCK_DOCKER_INSPECT_ERROR": "42"},
                text=True,
                capture_output=True,
                check=False,
            )
            jenkins_commands_after_inspect_failure = (root / "jenkins.log").read_text()
        self.assertEqual(pinned.returncode, 0, pinned.stdout + pinned.stderr)
        self.assertEqual(normal.returncode, 0, normal.stdout + normal.stderr)
        self.assertIn("checkout -B picsure-aio-release-pin", git_commands)
        self.assertIn("pull --ff-only", git_commands)
        self.assertEqual(final_state, "main")
        self.assertGreaterEqual(update_docker_commands.count("container inspect jenkins"), 2)
        self.assertNotIn("stop jenkins", update_docker_commands)
        self.assertNotEqual(failed_checkout.returncode, 0)
        self.assertEqual(jenkins_commands_after_failure, "")
        self.assertEqual(docker_log_after_failure, docker_log_before_failure)
        self.assertEqual(inspect_failure.returncode, 42)
        self.assertIn("synthetic Docker daemon failure", inspect_failure.stderr)
        self.assertEqual(jenkins_commands_after_inspect_failure, "")

    def test_start_jenkins_rejects_host_workflow_location_overrides(self):
        for variable in WORKFLOW_LOCATION_VARIABLES:
            with self.subTest(variable=variable), tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                bin_dir = fake_bin(tmp_path)
                env = os.environ.copy()
                env.update(
                    {
                        "PATH": f"{bin_dir}:{env['PATH']}",
                        "MOCK_DOCKER_LOG": str(tmp_path / "docker.log"),
                        "MOCK_DOCKER_STATE": str(tmp_path / "docker-state"),
                        "MOCK_WGET_LOG": str(tmp_path / "wget.log"),
                        "MOCK_CURL_LOG": str(tmp_path / "curl.log"),
                        "MOCK_GIT_LOG": str(tmp_path / "git.log"),
                        "DOCKER_CONFIG_DIR": str(tmp_path / "config"),
                        variable: (
                            "source"
                            if variable == "AIO_WORKFLOW_MODE"
                            else "/tmp/hostile-workflow-location"
                        ),
                    }
                )
                (tmp_path / "docker-state").mkdir()
                copy_installed_jenkins_jobs(tmp_path / "config/jenkins_home")
                result = subprocess.run(
                    ["bash", str(ROOT / "start-jenkins.sh")],
                    cwd=tmp_path,
                    env=env,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                docker_commands = (
                    (tmp_path / "docker.log").read_text().splitlines()
                    if (tmp_path / "docker.log").exists()
                    else []
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{variable} is caller-controlled", result.stderr)
                self.assertEqual(docker_commands, [])

    def test_start_jenkins_binds_content_in_safe_git_and_non_git_installs(self):
        for git_mode, expected_commit in (
            ("safe", "a" * 40),
            ("unavailable", "UNAVAILABLE"),
        ):
            with self.subTest(git_mode=git_mode), tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                bin_dir = fake_bin(tmp_path)
                env = os.environ.copy()
                env.update(
                    {
                        "PATH": f"{bin_dir}:{env['PATH']}",
                        "MOCK_DOCKER_LOG": str(tmp_path / "docker.log"),
                        "MOCK_DOCKER_STATE": str(tmp_path / "docker-state"),
                        "MOCK_WGET_LOG": str(tmp_path / "wget.log"),
                        "MOCK_CURL_LOG": str(tmp_path / "curl.log"),
                        "MOCK_GIT_LOG": str(tmp_path / "git.log"),
                        "MOCK_GIT_MODE": git_mode,
                        "MOCK_GIT_COMMIT": "a" * 40,
                        "DOCKER_CONFIG_DIR": str(tmp_path / "config"),
                    }
                )
                (tmp_path / "docker-state").mkdir()
                copy_installed_jenkins_jobs(tmp_path / "config/jenkins_home")
                result = subprocess.run(
                    ["bash", str(ROOT / "start-jenkins.sh")],
                    cwd=tmp_path,
                    env=env,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                docker_command = (tmp_path / "docker.log").read_text()
                git_commands = (tmp_path / "git.log").read_text()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(
                    f"AIO_WORKFLOW_COMMIT={expected_commit}", docker_command
                )
                for variable in WORKFLOW_LOCATION_VARIABLES:
                    self.assertNotIn(f"-e {variable}=", docker_command)
                self.assertNotIn("-e AIO_WORKFLOW_SHA256=", docker_command)
                for entry in WORKFLOW_MANIFEST.read_text().splitlines():
                    if entry.startswith("repo:"):
                        relative = entry.removeprefix("repo:")
                        self.assertIn(f":/aio-workflow/{relative}:ro", docker_command)
                self.assertIn("--network picsure", docker_command)
                if git_mode == "safe":
                    self.assertIn("-c safe.directory=", git_commands)

    def test_jenkins_jobs_preserve_release_pin_and_call_real_rollback_script(self):
        for job in ("PIC-SURE Database Migrations", "PIC-SURE Pipeline"):
            script = xml_script(JOBS / job / "config.xml")
            self.assertIn("release_control_commit", script)
            self.assertIn("Retrieve Pinned Build Spec", script)
            self.assertIn("projectName: 'Retrieve Pinned Build Spec'", script)
            self.assertIn("/scripts/validate-build-spec.sh build-spec.json", script)
        migrations = xml_script(JOBS / "PIC-SURE Database Migrations/config.xml")
        self.assertIn("migration-release-control-commit.txt", migrations)
        pipeline = xml_script(JOBS / "PIC-SURE Pipeline/config.xml")
        self.assertIn("migration_build_number", pipeline)
        self.assertIn("migration-release-control-commit.txt", pipeline)
        self.assertIn("Verify PIC-SURE Database Migration", pipeline)
        validate_pipeline_migration_order(pipeline)
        reordered_verification = pipeline.replace(
            "build job: 'Verify PIC-SURE Database Migration'",
            "build job: 'TEMP Verification'",
            1,
        ).replace(
            "if (migratedCommit != params.release_control_commit)",
            "build job: 'Verify PIC-SURE Database Migration'\n                    if (migratedCommit != params.release_control_commit)",
            1,
        )
        with self.assertRaises(AssertionError):
            validate_pipeline_migration_order(reordered_verification)
        ET.parse(JOBS / "Verify PIC-SURE Database Migration/config.xml")
        verifier_script = xml_script(JOBS / "Verify PIC-SURE Database Migration/config.xml")
        validate_migration_verifier(verifier_script)
        with self.assertRaises(AssertionError):
            validate_migration_verifier(
                verifier_script.replace("migrationRun.result != Result.SUCCESS", "false")
            )
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
        self.assertIn("aio-sha256.sh:/scripts/aio-sha256.sh:ro", mounts)
        self.assertIn("validate-build-spec.sh:/scripts/validate-build-spec.sh", mounts)
        self.assertIn("banner-rollout-contract.json:/scripts/banner-rollout-contract.json:ro", mounts)
        self.assertIn("banner-rollout-source.json:/scripts/banner-rollout-source.json:ro", mounts)
        self.assertIn('AIO_WORKFLOW_MANIFEST="$WORKFLOW_MANIFEST"', mounts)
        self.assertIn('AIO_WORKFLOW_REPO_ROOT="$SCRIPT_DIR"', mounts)
        self.assertIn(
            'AIO_WORKFLOW_JENKINS_HOME="$DOCKER_CONFIG_DIR/jenkins_home"',
            mounts,
        )
        for script in ("start-picsure.sh", "rollback-picsure.sh", "stop-picsure.sh"):
            self.assertIn(f"{script}:/scripts/{script}:ro", mounts)
        for script in (VALIDATOR, ROOT / "workflow-sha256.sh", ROOT / "rollback-picsure.sh"):
            source = script.read_text()
            self.assertIn("aio-sha256.sh", source)
            self.assertNotIn("sha256_file()", source)
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
        self.assertIn("shared `picsure` Docker network", readme)
        self.assertIn("ordinary `--restart always` policy", readme)
        self.assertNotRegex(readme, r"internal\s+`picsure` Docker network")
        self.assertIn("--aio-ref", readme)
        update = (ROOT / "update-jenkins.sh").read_text()
        self.assertIn("--aio-ref", update)
        self.assertEqual(subprocess.run(["bash", "-n", str(ROOT / "update-jenkins.sh")]).returncode, 0)
        invalid_ref = subprocess.run(
            ["bash", str(ROOT / "update-jenkins.sh"), "--aio-ref", "moving-branch"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(invalid_ref.returncode, 0)
        self.assertIn("exact 40-character commit", invalid_ref.stderr)

        rollback = ET.parse(JOBS / "Rollback PIC-SURE/config.xml").getroot()
        command = rollback.findtext(".//hudson.tasks.Shell/command") or ""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bin_dir = fake_bin(tmp_path)
            (tmp_path / "docker-state").mkdir()
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "MOCK_DOCKER_LOG": str(tmp_path / "docker.log"),
                    "MOCK_DOCKER_STATE": str(tmp_path / "docker-state"),
                    "MOCK_WGET_LOG": str(tmp_path / "wget.log"),
                    "MOCK_CURL_LOG": str(tmp_path / "curl.log"),
                    "MOCK_GIT_LOG": str(tmp_path / "git.log"),
                }
            )
            rollback_stub = tmp_path / "rollback-picsure.sh"
            rollback_stub.write_text(
                "#!/usr/bin/env bash\ntouch \"$MOCK_ROLLBACK_CALLED\"\n"
            )
            rollback_stub.chmod(0o755)
            executable_command = command.replace(
                "/scripts/rollback-picsure.sh rollback-state.json",
                f"{rollback_stub} rollback-state.json",
            )
            env["MOCK_FAILED_HEALTH_PATH"] = "/operations/banners/active/v2"
            env["MOCK_ROLLBACK_CALLED"] = str(tmp_path / "rollback-called")
            result = subprocess.run(
                ["bash", "-c", executable_command],
                cwd=tmp_path,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            rollback_called = (tmp_path / "rollback-called").exists()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(rollback_called)
        self.assertNotIn("/operations/banners/active/v2", command)
        initial = xml_script(JOBS / "Initial Configuration Pipeline/config.xml")
        self.assertNotIn("Initial Config and Build", initial)


if __name__ == "__main__":
    unittest.main()
