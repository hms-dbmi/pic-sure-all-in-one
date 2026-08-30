#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import NamedTuple
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


class GroovyToken(NamedTuple):
    kind: str
    value: str
    literal: bool = True


def groovy_tokens(script: str) -> list[GroovyToken]:
    tokens = []
    index = 0
    while index < len(script):
        character = script[index]
        if character in " \t\r":
            index += 1
            continue
        if character == "\n":
            tokens.append(GroovyToken("newline", "\n"))
            index += 1
            continue
        if script.startswith("//", index):
            end = script.find("\n", index + 2)
            index = len(script) if end < 0 else end
            continue
        if script.startswith("/*", index):
            end = script.find("*/", index + 2)
            if end < 0:
                raise AssertionError("unterminated Groovy block comment")
            tokens.extend(
                GroovyToken("newline", "\n")
                for _ in range(script.count("\n", index, end + 2))
            )
            index = end + 2
            continue
        if character in {"'", '"'}:
            quote = character
            triple = script.startswith(quote * 3, index)
            delimiter = quote * (3 if triple else 1)
            cursor = index + len(delimiter)
            value = []
            escaped = False
            while cursor < len(script):
                if not escaped and script.startswith(delimiter, cursor):
                    break
                current = script[cursor]
                value.append(current)
                if escaped:
                    escaped = False
                elif current == "\\":
                    escaped = True
                cursor += 1
            if cursor >= len(script):
                raise AssertionError("unterminated Groovy string")
            text = "".join(value)
            tokens.append(
                GroovyToken(
                    "string",
                    text,
                    not triple and "\\" not in text and "$" not in text,
                )
            )
            index = cursor + len(delimiter)
            continue
        if character.isalpha() or character in {"_", "$"}:
            cursor = index + 1
            while cursor < len(script) and (
                script[cursor].isalnum() or script[cursor] in {"_", "$"}
            ):
                cursor += 1
            tokens.append(GroovyToken("identifier", script[index:cursor]))
            index = cursor
            continue
        if character.isdigit():
            cursor = index + 1
            while cursor < len(script) and script[cursor].isdigit():
                cursor += 1
            tokens.append(GroovyToken("number", script[index:cursor]))
            index = cursor
            continue
        tokens.append(GroovyToken("symbol", character))
        index += 1
    return tokens


def next_token(tokens: list[GroovyToken], index: int) -> int:
    while index < len(tokens) and tokens[index].kind == "newline":
        index += 1
    return index


def matching_token(
    tokens: list[GroovyToken], start: int, opening: str, closing: str
) -> int:
    depth = 0
    for index in range(start, len(tokens)):
        if tokens[index].kind != "symbol":
            continue
        if tokens[index].value == opening:
            depth += 1
        elif tokens[index].value == closing:
            depth -= 1
            if depth == 0:
                return index
    raise AssertionError(f"unterminated Groovy {opening}{closing} group")


def previous_token(tokens: list[GroovyToken], index: int) -> int:
    index -= 1
    while index >= 0 and tokens[index].kind == "newline":
        index -= 1
    return index


def map_has_job_key(tokens: list[GroovyToken], start: int, end: int) -> bool:
    depth = 0
    for index in range(start + 1, end):
        token = tokens[index]
        if token.kind == "symbol" and token.value in {"(", "[", "{"}:
            depth += 1
        elif token.kind == "symbol" and token.value in {")", "]", "}"}:
            depth -= 1
        elif depth == 0 and token.kind == "identifier" and token.value == "job":
            colon = next_token(tokens, index + 1)
            if (
                colon < end
                and tokens[colon].kind == "symbol"
                and tokens[colon].value == ":"
            ):
                return True
    return False


def is_build_call(tokens: list[GroovyToken], index: int) -> bool:
    target = index + 1
    if target >= len(tokens) or tokens[target].kind == "newline":
        return False
    previous = previous_token(tokens, index)
    if previous >= 0 and (
        (
            tokens[previous].kind == "symbol"
            and tokens[previous].value in {".", "&"}
        )
        or (
            tokens[previous].kind == "identifier"
            and tokens[previous].value
            in {
                "def",
                "void",
                "boolean",
                "byte",
                "char",
                "double",
                "float",
                "int",
                "long",
                "short",
            }
        )
    ):
        return False

    token = tokens[target]
    if token.kind == "identifier":
        return token.value not in {"as", "in", "instanceof"}
    if token.kind in {"string", "number"}:
        return True
    if token.kind != "symbol":
        return False
    if token.value == "(":
        closing = matching_token(tokens, target, "(", ")")
        after = next_token(tokens, closing + 1)
        if (
            previous >= 0
            and tokens[previous].kind == "identifier"
            and tokens[previous].value not in {"return", "throw"}
            and after < len(tokens)
            and tokens[after].kind == "symbol"
            and tokens[after].value == "{"
        ):
            return False
        return True
    if token.value == "[":
        end = matching_token(tokens, target, "[", "]")
        return map_has_job_key(tokens, target, end)
    if token.value == "{":
        return True
    return False


def literal_job(token: GroovyToken) -> str:
    if token.kind != "string" or not token.literal or not token.value:
        raise AssertionError("unresolved Jenkins downstream trigger target")
    return token.value


def map_literal_job(tokens: list[GroovyToken], start: int, end: int) -> str:
    job = None
    index = start + 1
    depth = 0
    while index < end:
        token = tokens[index]
        if token.kind == "symbol" and token.value in {"(", "[", "{"}:
            depth += 1
        elif token.kind == "symbol" and token.value in {")", "]", "}"}:
            depth -= 1
        elif (
            depth == 0
            and token.kind == "identifier"
            and token.value == "job"
        ):
            colon = next_token(tokens, index + 1)
            target = next_token(tokens, colon + 1)
            if (
                colon >= end
                or tokens[colon].kind != "symbol"
                or tokens[colon].value != ":"
                or target >= end
            ):
                raise AssertionError("unresolved Jenkins downstream trigger target")
            after = next_token(tokens, target + 1)
            if after < end and not (
                tokens[after].kind == "symbol" and tokens[after].value == ","
            ):
                raise AssertionError("unresolved Jenkins downstream trigger target")
            if job is not None:
                raise AssertionError("duplicate Jenkins downstream job target")
            job = literal_job(tokens[target])
        index += 1
    if job is None:
        raise AssertionError("unresolved Jenkins downstream trigger target")
    return job


def build_jobs(tokens: list[GroovyToken]) -> list[str]:
    jobs = []
    for index, token in enumerate(tokens):
        if (
            token.kind != "identifier"
            or token.value != "build"
            or not is_build_call(tokens, index)
        ):
            continue
        target = index + 1
        if target >= len(tokens):
            continue
        target_token = tokens[target]
        if target_token.kind == "newline":
            continue
        if target_token.kind == "symbol" and target_token.value in {".", ":", "="}:
            continue
        parenthesized = target_token.kind == "symbol" and target_token.value == "("
        if parenthesized:
            close = matching_token(tokens, target, "(", ")")
            target = next_token(tokens, target + 1)
            if target >= close:
                raise AssertionError("unresolved Jenkins downstream trigger target")
            target_token = tokens[target]
            if target_token.kind == "symbol" and target_token.value == "[":
                map_end = matching_token(tokens, target, "[", "]")
                if map_end >= close:
                    raise AssertionError("unresolved Jenkins downstream trigger target")
                after = next_token(tokens, map_end + 1)
                if after < close:
                    raise AssertionError("unresolved Jenkins downstream trigger target")
                jobs.append(map_literal_job(tokens, target, map_end))
                continue
        elif target_token.kind == "symbol" and target_token.value == "[":
            map_end = matching_token(tokens, target, "[", "]")
            after = map_end + 1
            if after < len(tokens) and tokens[after].kind != "newline" and not (
                tokens[after].kind == "symbol"
                and tokens[after].value in {";", "}"}
            ):
                raise AssertionError("unresolved Jenkins downstream trigger target")
            jobs.append(map_literal_job(tokens, target, map_end))
            continue

        if target_token.kind == "identifier" and target_token.value == "job":
            colon = next_token(tokens, target + 1)
            if (
                colon >= len(tokens)
                or tokens[colon].kind != "symbol"
                or tokens[colon].value != ":"
            ):
                raise AssertionError("unresolved Jenkins downstream trigger target")
            target = next_token(tokens, colon + 1)
            if target >= len(tokens):
                raise AssertionError("unresolved Jenkins downstream trigger target")
            target_token = tokens[target]
        job = literal_job(target_token)
        after = target + 1
        if parenthesized:
            after = next_token(tokens, after)
            if after < close and not (
                tokens[after].kind == "symbol" and tokens[after].value == ","
            ):
                raise AssertionError("unresolved Jenkins downstream trigger target")
        else:
            if after < len(tokens) and tokens[after].kind != "newline":
                if not (
                    tokens[after].kind == "symbol"
                    and tokens[after].value in {",", ";", "}"}
                ):
                    raise AssertionError(
                        "unresolved Jenkins downstream trigger target"
                    )
        jobs.append(job)
    return jobs


def scheduled_jobs_from_tokens(tokens: list[GroovyToken]) -> list[str]:
    jobs = []
    recognized = set()
    for index, token in enumerate(tokens):
        if token.kind != "identifier" or token.value not in {
            "getItem",
            "getItemByFullName",
        }:
            continue
        opening = next_token(tokens, index + 1)
        if (
            opening >= len(tokens)
            or tokens[opening].kind != "symbol"
            or tokens[opening].value != "("
        ):
            continue
        closing = matching_token(tokens, opening, "(", ")")
        dot = next_token(tokens, closing + 1)
        schedule = next_token(tokens, dot + 1)
        if (
            dot >= len(tokens)
            or schedule >= len(tokens)
            or tokens[dot].kind != "symbol"
            or tokens[dot].value != "."
            or tokens[schedule].kind != "identifier"
            or tokens[schedule].value != "scheduleBuild2"
        ):
            continue
        target = [
            item
            for item in tokens[opening + 1 : closing]
            if item.kind != "newline"
        ]
        if len(target) != 1:
            raise AssertionError("unresolved Jenkins downstream trigger: scheduleBuild2")
        jobs.append(literal_job(target[0]))
        recognized.add(schedule)
    for index, token in enumerate(tokens):
        if (
            token.kind == "identifier"
            and token.value == "scheduleBuild2"
            and index not in recognized
        ):
            raise AssertionError("unresolved Jenkins downstream trigger: scheduleBuild2")
    return jobs


def scheduled_jobs(script: str) -> list[str]:
    return scheduled_jobs_from_tokens(groovy_tokens(script))


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
    validator_source = validator.read_text()
    validator.write_text(
        validator_source.replace(
            '[[ "$SCRIPT_DIR" == "/scripts" ]]',
            f'[[ "$SCRIPT_DIR" == "{scripts.resolve()}" ]]',
        )
        .replace(
            "[[ -d /aio-workflow ]]",
            f"[[ -d {directory / 'aio-workflow'} ]]",
        )
        .replace("WORKFLOW_ROOT=/aio-workflow", f"WORKFLOW_ROOT={directory / 'aio-workflow'}")
        .replace(
            "WORKFLOW_JENKINS_HOME=/var/jenkins_home",
            f"WORKFLOW_JENKINS_HOME={directory / 'var/jenkins_home'}",
        )
    )
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


def create_source_validator_bundle(directory: Path) -> Path:
    source_root = directory / "scripts"
    source_root.mkdir()
    for source in (VALIDATOR, CHECKSUM_HELPER, ROOT / "workflow-sha256.sh"):
        shutil.copy2(source, source_root / source.name)
    workflow_directory = (
        source_root / "initial-configuration/jenkins/jenkins-docker"
    )
    workflow_directory.mkdir(parents=True)
    for source in (CONTRACT, CONTRACT_SOURCE, WORKFLOW_MANIFEST):
        shutil.copy2(source, workflow_directory / source.name)
    copy_installed_jenkins_jobs(workflow_directory)
    for entry in WORKFLOW_MANIFEST.read_text().splitlines():
        if not entry.startswith("repo:"):
            continue
        relative = Path(entry.split(":", 1)[1])
        source = ROOT / relative
        target = source_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    return source_root / VALIDATOR.name


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
  if [[ "$name" == "httpd" && -n "${MOCK_HTTPD_INSPECT_STDOUT:-}" ]]; then
    printf '%s\\n' "$MOCK_HTTPD_INSPECT_STDOUT"
  fi
  if [[ "$name" == "httpd" && -n "${MOCK_HTTPD_TERMINAL_INSPECT_ERROR:-}" && -f "$MOCK_DOCKER_STATE/gateway-health-checked" ]]; then
    printf '%s\\n' "$MOCK_HTTPD_TERMINAL_INSPECT_ERROR" >&2
    exit 42
  fi
  if [[ "$name" == "httpd" && -n "${MOCK_HTTPD_INSPECT_ERROR:-}" ]]; then
    printf '%s\\n' "$MOCK_HTTPD_INSPECT_ERROR" >&2
    exit 41
  fi
  if [[ "$name" == "httpd" && "${MOCK_HTTPD_INSPECT_NO_DIAGNOSTIC:-false}" == "true" ]]; then
    exit 43
  fi
  if [[ "$name" == "httpd" && "${MOCK_HTTPD_PRESENT:-false}" == "true" ]]; then
    if [[ -n "${MOCK_HTTPD_INSPECT_STDERR:-}" ]]; then
      printf '%s\\n' "$MOCK_HTTPD_INSPECT_STDERR" >&2
    fi
    if [[ "$*" == *"State.Running"*"RestartPolicy.Name"* ]]; then
      restart_policy="${MOCK_HTTPD_RESTART_POLICY:-no}"
      if [[ "${MOCK_HTTPD_EMPTY_RESTART_POLICY:-false}" == "true" ]]; then
        restart_policy=""
      fi
      printf '%s %s\\n' "${MOCK_HTTPD_RUNNING:-true}" "$restart_policy"
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
    tokens = groovy_tokens(script)
    children = set(build_jobs(tokens) + scheduled_jobs_from_tokens(tokens))
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


DECLARATIVE_TRACKER_CATEGORIES = {
    "jobProperties",
    "triggers",
    "parameters",
    "options",
}
DECLARATIVE_PROPERTY_OPTIONS = {
    "disableConcurrentBuilds": (
        "org.jenkinsci.plugins.workflow.job.properties."
        "DisableConcurrentBuildsJobProperty"
    ),
    "buildDiscarder": "jenkins.model.BuildDiscarderProperty",
}
DECLARATIVE_TRIGGER_CLASSES = {
    "cron": "hudson.triggers.TimerTrigger",
    "pollSCM": "hudson.triggers.SCMTrigger",
    "upstream": "jenkins.triggers.ReverseBuildTrigger",
}
DECLARATIVE_STANDALONE_OPTIONS = {
    "checkoutToSubdirectory",
    "disableResume",
    "newContainerPerStage",
    "overrideIndexTriggers",
    "parallelsAlwaysFailFast",
    "preserveStashes",
    "quietPeriod",
    "retry",
    "skipDefaultCheckout",
    "skipStagesAfterUnstable",
    "timeout",
    "timestamps",
}


def child_block(
    tokens: list[GroovyToken], name: str
) -> list[GroovyToken] | None:
    depth = 0
    for index, token in enumerate(tokens):
        if token.kind == "symbol" and token.value == "{":
            depth += 1
            continue
        if token.kind == "symbol" and token.value == "}":
            depth -= 1
            continue
        if token.kind != "identifier" or token.value != name or depth != 0:
            continue
        opening = next_token(tokens, index + 1)
        if (
            opening < len(tokens)
            and tokens[opening].kind == "symbol"
            and tokens[opening].value == "{"
        ):
            closing = matching_token(tokens, opening, "{", "}")
            return tokens[opening + 1 : closing]
    return None


def top_level_invocations(
    tokens: list[GroovyToken],
) -> list[tuple[str, list[GroovyToken]]]:
    invocations = []
    depths = {"(": 0, "[": 0, "{": 0}
    closing = {")": "(", "]": "[", "}": "{"}
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token.kind == "symbol" and token.value in depths:
            depths[token.value] += 1
            index += 1
            continue
        if token.kind == "symbol" and token.value in closing:
            depths[closing[token.value]] -= 1
            index += 1
            continue
        if token.kind == "identifier" and all(
            depth == 0 for depth in depths.values()
        ):
            opening = next_token(tokens, index + 1)
            if (
                opening < len(tokens)
                and tokens[opening].kind == "symbol"
                and tokens[opening].value == "("
            ):
                end = matching_token(tokens, opening, "(", ")")
                invocations.append((token.value, tokens[opening + 1 : end]))
                index = end + 1
                continue
        index += 1
    return invocations


def split_top_level(
    tokens: list[GroovyToken], separator: str
) -> list[list[GroovyToken]]:
    parts = []
    start = 0
    depths = {"(": 0, "[": 0, "{": 0}
    closing = {")": "(", "]": "[", "}": "{"}
    for index, token in enumerate(tokens):
        if token.kind == "symbol" and token.value in depths:
            depths[token.value] += 1
        elif token.kind == "symbol" and token.value in closing:
            depths[closing[token.value]] -= 1
        elif (
            token.kind == "symbol"
            and token.value == separator
            and all(depth == 0 for depth in depths.values())
        ):
            parts.append(tokens[start:index])
            start = index + 1
    parts.append(tokens[start:])
    return parts


def cleaned_tokens(tokens: list[GroovyToken]) -> list[GroovyToken]:
    return [token for token in tokens if token.kind != "newline"]


def literal_value(tokens: list[GroovyToken]):
    tokens = cleaned_tokens(tokens)
    if len(tokens) == 1:
        token = tokens[0]
        if token.kind == "string" and token.literal:
            return token.value
        if token.kind == "number":
            return token.value
        if token.kind == "identifier" and token.value in {"true", "false"}:
            return token.value == "true"
        if token.kind == "identifier" and token.value == "null":
            return None
    if (
        len(tokens) >= 2
        and tokens[0].kind == "symbol"
        and tokens[0].value == "["
        and matching_token(tokens, 0, "[", "]") == len(tokens) - 1
    ):
        contents = tokens[1:-1]
        if not cleaned_tokens(contents):
            return ()
        return tuple(
            literal_value(part)
            for part in split_top_level(contents, ",")
        )
    if (
        len(tokens) >= 3
        and tokens[0].kind == "identifier"
        and tokens[1].kind == "symbol"
        and tokens[1].value == "("
        and matching_token(tokens, 1, "(", ")") == len(tokens) - 1
    ):
        named, positional = call_arguments(tokens[2:-1])
        return {
            "call": tokens[0].value,
            "named": named,
            "positional": positional,
        }
    raise AssertionError("declarative value is not a supported literal")


def call_arguments(
    tokens: list[GroovyToken],
) -> tuple[dict[str, object], tuple[object, ...]]:
    named = {}
    positional = []
    if not cleaned_tokens(tokens):
        return named, ()
    for part in split_top_level(tokens, ","):
        part = cleaned_tokens(part)
        colon = None
        depth = 0
        for index, token in enumerate(part):
            if token.kind == "symbol" and token.value in {"(", "[", "{"}:
                depth += 1
            elif token.kind == "symbol" and token.value in {")", "]", "}"}:
                depth -= 1
            elif (
                token.kind == "symbol"
                and token.value == ":"
                and depth == 0
            ):
                colon = index
                break
        if colon is None:
            positional.append(literal_value(part))
            continue
        if (
            colon != 1
            or part[0].kind != "identifier"
            or part[0].value in named
        ):
            raise AssertionError("declarative named argument is unresolved")
        named[part[0].value] = literal_value(part[colon + 1 :])
    return named, tuple(positional)


def invocation_map(
    tokens: list[GroovyToken] | None,
) -> dict[str, tuple[dict[str, object], tuple[object, ...]]]:
    if tokens is None:
        return {}
    result = {}
    for name, arguments in top_level_invocations(tokens):
        if name in result:
            raise AssertionError(f"duplicate declarative directive: {name}")
        result[name] = call_arguments(arguments)
    return result


def tracker_values(tracker: ET.Element, category: str) -> set[str]:
    nodes = tracker.findall(f"./{category}/string")
    values = [node.text or "" for node in nodes]
    if len(values) != len(set(values)) or "" in values:
        raise AssertionError(f"invalid declarative tracker values in {category}")
    return set(values)


PARAMETER_TYPES = {
    "booleanParam": "hudson.model.BooleanParameterDefinition",
    "choice": "hudson.model.ChoiceParameterDefinition",
    "file": "hudson.model.FileParameterDefinition",
    "password": "hudson.model.PasswordParameterDefinition",
    "string": "hudson.model.StringParameterDefinition",
    "text": "hudson.model.TextParameterDefinition",
}


def normalized_parameter_directives(
    invocations: list[tuple[str, list[GroovyToken]]],
    config: Path,
) -> dict[str, dict[str, object]]:
    normalized = {}
    for parameter_type, arguments in invocations:
        named, positional = call_arguments(arguments)
        if parameter_type not in PARAMETER_TYPES or positional:
            raise AssertionError(
                f"unknown declarative parameter in {config}: {parameter_type}"
            )
        name = named.get("name")
        if not isinstance(name, str) or not name or name in normalized:
            raise AssertionError(
                f"declarative parameter name is unresolved in {config}"
            )
        description = named.get("description", "")
        if not isinstance(description, str):
            raise AssertionError(
                f"declarative parameter description is unresolved in {config}"
            )
        result = {
            "type": PARAMETER_TYPES[parameter_type],
            "description": description,
        }
        allowed = {"name", "description"}
        if parameter_type == "choice":
            choices = named.get("choices")
            if not isinstance(choices, tuple) or not all(
                isinstance(choice, str) for choice in choices
            ):
                raise AssertionError(
                    f"declarative parameter choices are unresolved in {config}"
                )
            result["choices"] = choices
            allowed.add("choices")
        elif parameter_type == "booleanParam":
            result["defaultValue"] = named.get("defaultValue", False)
            allowed.add("defaultValue")
        elif parameter_type in {"string", "text", "password"}:
            result["defaultValue"] = named.get("defaultValue", "")
            allowed.add("defaultValue")
            if parameter_type == "string":
                result["trim"] = named.get("trim", False)
                allowed.add("trim")
        if set(named) - allowed:
            raise AssertionError(
                f"unknown declarative parameter value in {config}: "
                f"{sorted(set(named) - allowed)}"
            )
        normalized[name] = result
    return normalized


def normalized_persisted_parameters(root: ET.Element) -> dict[str, dict[str, object]]:
    normalized = {}
    definitions = root.findall(
        "./properties/hudson.model.ParametersDefinitionProperty/"
        "parameterDefinitions/*"
    )
    for definition in definitions:
        name = definition.findtext("name") or ""
        if not name or name in normalized:
            raise AssertionError("persisted parameter name is missing or duplicated")
        result = {
            "type": definition.tag,
            "description": definition.findtext("description") or "",
        }
        if definition.tag == PARAMETER_TYPES["choice"]:
            result["choices"] = tuple(
                node.text or "" for node in definition.findall("./choices//string")
            )
        elif definition.tag == PARAMETER_TYPES["booleanParam"]:
            result["defaultValue"] = (
                definition.findtext("defaultValue") or "false"
            ) == "true"
        elif definition.tag in {
            PARAMETER_TYPES["string"],
            PARAMETER_TYPES["text"],
            PARAMETER_TYPES["password"],
        }:
            result["defaultValue"] = definition.findtext("defaultValue") or ""
            if definition.tag == PARAMETER_TYPES["string"]:
                result["trim"] = (
                    definition.findtext("trim") or "false"
                ) == "true"
        normalized[name] = result
    return normalized


def normalized_trigger_directives(
    invocations: dict[str, tuple[dict[str, object], tuple[object, ...]]],
    config: Path,
) -> dict[str, dict[str, object]]:
    normalized = {}
    for trigger, (named, positional) in invocations.items():
        if trigger not in DECLARATIVE_TRIGGER_CLASSES:
            raise AssertionError(
                f"unknown declarative trigger in {config}: {trigger}"
            )
        if trigger in {"cron", "pollSCM"}:
            if named or len(positional) != 1 or not isinstance(positional[0], str):
                raise AssertionError(
                    f"declarative trigger value is unresolved in {config}"
                )
            value = {"spec": positional[0]}
        else:
            if positional or not isinstance(named.get("upstreamProjects"), str):
                raise AssertionError(
                    f"declarative upstream trigger is unresolved in {config}"
                )
            value = {
                "upstreamProjects": named["upstreamProjects"],
                "threshold": named.get("threshold", "SUCCESS"),
            }
        normalized[DECLARATIVE_TRIGGER_CLASSES[trigger]] = value
    return normalized


def normalized_persisted_triggers(root: ET.Element) -> dict[str, dict[str, object]]:
    normalized = {}
    nodes = root.findall(
        "./properties/org.jenkinsci.plugins.workflow.job.properties."
        "PipelineTriggersJobProperty/triggers/*"
    )
    for node in nodes:
        if node.tag in {
            DECLARATIVE_TRIGGER_CLASSES["cron"],
            DECLARATIVE_TRIGGER_CLASSES["pollSCM"],
        }:
            value = {"spec": node.findtext("spec") or ""}
        elif node.tag == DECLARATIVE_TRIGGER_CLASSES["upstream"]:
            value = {
                "upstreamProjects": node.findtext("upstreamProjects") or "",
                "threshold": node.findtext("threshold/name") or "SUCCESS",
            }
        else:
            value = {"unknown": node.tag}
        normalized[node.tag] = value
    return normalized


def normalized_log_rotator(value: object, config: Path) -> dict[str, object]:
    if (
        not isinstance(value, dict)
        or value.get("call") != "logRotator"
        or value.get("positional")
    ):
        raise AssertionError(f"build discarder is unresolved in {config}")
    named = value["named"]
    allowed = {
        "daysToKeepStr",
        "numToKeepStr",
        "artifactDaysToKeepStr",
        "artifactNumToKeepStr",
    }
    if set(named) - allowed or not all(
        isinstance(item, str) for item in named.values()
    ):
        raise AssertionError(f"build discarder is unresolved in {config}")
    return {
        "strategy": "hudson.tasks.LogRotator",
        "daysToKeep": named.get("daysToKeepStr", "-1"),
        "numToKeep": named.get("numToKeepStr", "-1"),
        "artifactDaysToKeep": named.get("artifactDaysToKeepStr", "-1"),
        "artifactNumToKeep": named.get("artifactNumToKeepStr", "-1"),
    }


def normalized_persisted_log_rotator(
    property_node: ET.Element, config: Path
) -> dict[str, object]:
    strategy = property_node.find("./strategy")
    if strategy is None:
        raise AssertionError(f"build discarder is not converged in {config}")
    strategy_type = strategy.get("class") or strategy.tag
    return {
        "strategy": strategy_type,
        "daysToKeep": strategy.findtext("daysToKeep") or "-1",
        "numToKeep": strategy.findtext("numToKeep") or "-1",
        "artifactDaysToKeep": strategy.findtext("artifactDaysToKeep") or "-1",
        "artifactNumToKeep": strategy.findtext("artifactNumToKeep") or "-1",
    }


def validate_declarative_convergence(config: Path) -> None:
    root = ET.parse(config).getroot()
    script = xml_script(config)
    pipeline = child_block(groovy_tokens(script), "pipeline")
    if pipeline is None:
        return
    tracker = root.find(
        ".//org.jenkinsci.plugins.pipeline.modeldefinition.actions."
        "DeclarativeJobPropertyTrackerAction"
    )
    if tracker is None:
        raise AssertionError(f"declarative property tracker is missing: {config}")
    categories = {child.tag for child in tracker}
    unknown_categories = categories - DECLARATIVE_TRACKER_CATEGORIES
    missing_categories = DECLARATIVE_TRACKER_CATEGORIES - categories
    if unknown_categories:
        raise AssertionError(
            f"unknown declarative tracker category in {config}: "
            f"{sorted(unknown_categories)}"
        )
    if missing_categories:
        raise AssertionError(
            f"declarative tracker categories are missing in {config}: "
            f"{sorted(missing_categories)}"
        )

    options = invocation_map(child_block(pipeline, "options"))
    unknown_options = set(options) - (
        DECLARATIVE_PROPERTY_OPTIONS.keys() | DECLARATIVE_STANDALONE_OPTIONS
    )
    if unknown_options:
        raise AssertionError(
            f"unknown declarative option in {config}: {sorted(unknown_options)}"
        )
    expected_properties = {
        property_class
        for option, property_class in DECLARATIVE_PROPERTY_OPTIONS.items()
        if option in options
    }
    tracked_properties = tracker_values(tracker, "jobProperties")
    unknown_properties = tracked_properties - set(
        DECLARATIVE_PROPERTY_OPTIONS.values()
    )
    persisted_properties = {
        property_class
        for property_class in DECLARATIVE_PROPERTY_OPTIONS.values()
        if root.find(f"./properties/{property_class}") is not None
    }
    if unknown_properties:
        raise AssertionError(
            f"unknown declarative job property in {config}: "
            f"{sorted(unknown_properties)}"
        )
    if not expected_properties == tracked_properties == persisted_properties:
        raise AssertionError(
            f"declarative job properties are not converged in {config}: "
            f"directives={sorted(expected_properties)}, "
            f"tracker={sorted(tracked_properties)}, "
            f"persisted={sorted(persisted_properties)}"
        )

    disable_class = DECLARATIVE_PROPERTY_OPTIONS["disableConcurrentBuilds"]
    disable_node = root.find(f"./properties/{disable_class}")
    expected_disable = None
    if "disableConcurrentBuilds" in options:
        named, positional = options["disableConcurrentBuilds"]
        if positional or set(named) - {"abortPrevious"}:
            raise AssertionError(
                f"disableConcurrentBuilds is unresolved in {config}"
            )
        expected_disable = named.get("abortPrevious", False)
        if not isinstance(expected_disable, bool):
            raise AssertionError(
                f"disableConcurrentBuilds is unresolved in {config}"
            )
    if disable_node is not None:
        persisted_disable = (
            disable_node.findtext("abortPrevious") or "false"
        ) == "true"
        if persisted_disable != expected_disable:
            raise AssertionError(
                f"disableConcurrentBuilds is not converged in {config}: "
                f"directive={expected_disable}, persisted={persisted_disable}"
            )
        if disable_node.get("plugin") != root.get("plugin"):
            raise AssertionError(
                f"disableConcurrentBuilds plugin identity is not converged in {config}"
            )
    discarder_node = root.find(
        f"./properties/{DECLARATIVE_PROPERTY_OPTIONS['buildDiscarder']}"
    )
    if discarder_node is not None:
        named, positional = options["buildDiscarder"]
        if named or len(positional) != 1:
            raise AssertionError(f"build discarder is unresolved in {config}")
        expected_discarder = normalized_log_rotator(positional[0], config)
        persisted_discarder = normalized_persisted_log_rotator(
            discarder_node, config
        )
        if expected_discarder != persisted_discarder:
            raise AssertionError(
                f"build discarder is not converged in {config}: "
                f"directive={expected_discarder}, persisted={persisted_discarder}"
            )

    parameter_directives = normalized_parameter_directives(
        top_level_invocations(child_block(pipeline, "parameters") or []), config
    )
    tracked_parameters = tracker_values(tracker, "parameters")
    persisted_parameters = normalized_persisted_parameters(root)
    if set(parameter_directives) != tracked_parameters:
        raise AssertionError(
            f"declarative parameters are not converged in {config}: "
            f"directives={sorted(parameter_directives)}, "
            f"tracker={sorted(tracked_parameters)}"
        )
    for name, directive in parameter_directives.items():
        persisted = persisted_parameters.get(name)
        if directive != persisted:
            raise AssertionError(
                f"declarative parameter {name} is not converged in {config}: "
                f"directive={directive}, persisted={persisted}"
            )

    expected_triggers = normalized_trigger_directives(
        invocation_map(child_block(pipeline, "triggers")), config
    )
    tracked_triggers = tracker_values(tracker, "triggers")
    persisted_triggers = normalized_persisted_triggers(root)
    if not set(expected_triggers) == tracked_triggers == set(persisted_triggers):
        raise AssertionError(
            f"declarative triggers are not converged in {config}: "
            f"directives={sorted(expected_triggers)}, "
            f"tracker={sorted(tracked_triggers)}, "
            f"persisted={sorted(persisted_triggers)}"
        )
    for trigger, directive in expected_triggers.items():
        if directive != persisted_triggers[trigger]:
            raise AssertionError(
                f"declarative trigger {trigger} is not converged in {config}: "
                f"directive={directive}, persisted={persisted_triggers[trigger]}"
            )

    expected_standalone_options = set(options) - DECLARATIVE_PROPERTY_OPTIONS.keys()
    for option in expected_standalone_options:
        named, positional = options[option]
        if option == "skipDefaultCheckout":
            if named or len(positional) > 1 or (
                positional and not isinstance(positional[0], bool)
            ):
                raise AssertionError(
                    f"declarative option {option} is unresolved in {config}"
                )
    tracked_options = tracker_values(tracker, "options")
    unknown_tracked_options = tracked_options - DECLARATIVE_STANDALONE_OPTIONS
    if unknown_tracked_options:
        raise AssertionError(
            f"unknown tracked declarative option in {config}: "
            f"{sorted(unknown_tracked_options)}"
        )
    if expected_standalone_options != tracked_options:
        raise AssertionError(
            f"declarative options are not converged in {config}: "
            f"directives={sorted(expected_standalone_options)}, "
            f"tracker={sorted(tracked_options)}"
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
                {
                    "MOCK_HTTPD_INSPECT_ERROR": "synthetic Docker API failure",
                    "MOCK_HTTPD_INSPECT_STDOUT": "false no",
                },
                str(state),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("synthetic Docker API failure", result.stderr)
        self.assertFalse(any(command.startswith("image inspect") for command in commands))
        self.assertFalse(any(command.startswith("tag ") for command in commands))
        self.assertFalse(any("run --name=" in command for command in commands))

    def test_httpd_inspect_errors_without_diagnostics_fail_closed(self):
        for script, arguments in (
            (ROOT / "rollback-picsure.sh", ()),
            (ROOT / "start-picsure.sh", ("--rollback-state",)),
        ):
            with self.subTest(script=script.name), tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                config = required_config(tmp_path / "config")
                state = tmp_path / "state.json"
                state.write_text(json.dumps(rollback_state()))
                if script.name == "rollback-picsure.sh":
                    script_arguments = (str(state),)
                else:
                    script_arguments = (*arguments, str(state))
                result, commands = run_script(
                    script,
                    config,
                    {"MOCK_HTTPD_INSPECT_NO_DIAGNOSTIC": "true"},
                    *script_arguments,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("without a diagnostic", result.stderr)
                self.assertFalse(any("run --name=" in command for command in commands))

    def test_httpd_inspection_mktemp_failure_has_explicit_exit_two_diagnostic(self):
        for script in (ROOT / "rollback-picsure.sh", ROOT / "start-picsure.sh"):
            with self.subTest(script=script.name), tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                config = required_config(tmp_path / "config")
                state = tmp_path / "state.json"
                state.write_text(json.dumps(rollback_state()))
                arguments = (
                    (str(state),)
                    if script.name == "rollback-picsure.sh"
                    else ("--rollback-state", str(state))
                )
                result, commands = run_script(
                    script,
                    config,
                    {"TMPDIR": str(tmp_path / "missing")},
                    *arguments,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn(
                    "could not create temporary file for httpd inspection",
                    result.stderr,
                )
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

    def test_rollback_classifies_inspect_stdout_separately_from_stderr(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = required_config(Path(tmp) / "config")
            state = Path(tmp) / "rollback-state.json"
            state.write_text(json.dumps(rollback_state()))
            result, _ = run_script(
                ROOT / "rollback-picsure.sh",
                config,
                {
                    "MOCK_HTTPD_PRESENT": "true",
                    "MOCK_HTTPD_RUNNING": "false",
                    "MOCK_HTTPD_RESTART_POLICY": "no",
                    "MOCK_HTTPD_INSPECT_STDERR": "benign Docker diagnostic",
                },
                str(state),
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rollback_reports_empty_restart_policy_explicitly(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = required_config(Path(tmp) / "config")
            state = Path(tmp) / "rollback-state.json"
            state.write_text(json.dumps(rollback_state()))
            result, _ = run_script(
                ROOT / "rollback-picsure.sh",
                config,
                {
                    "MOCK_HTTPD_PRESENT": "true",
                    "MOCK_HTTPD_RUNNING": "false",
                    "MOCK_HTTPD_EMPTY_RESTART_POLICY": "true",
                },
                str(state),
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("httpd restart policy is empty", result.stderr)

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

    def test_installed_validator_never_falls_back_to_source_helper(self):
        digest = workflow_digest()
        aio_commit = "a" * 40
        spec = synthetic_build_spec(aio_commit, digest)
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            validator = create_installed_validator_bundle(tmp_path)
            (tmp_path / "aio-workflow/workflow-sha256.sh").unlink()
            fake_source_helper = tmp_path / "scripts/workflow-sha256.sh"
            fake_source_helper.write_text(
                f"#!/usr/bin/env bash\nprintf '%s\\n' {digest}\n"
            )
            fake_source_helper.chmod(0o755)
            spec_path = tmp_path / "build-spec.json"
            spec_path.write_text(json.dumps(spec))
            result = subprocess.run(
                ["bash", str(validator), str(spec_path)],
                cwd=tmp_path,
                env={**os.environ, "AIO_WORKFLOW_COMMIT": aio_commit},
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installed workflow checksum script", result.stderr)

    def test_installed_validator_requires_every_trusted_input(self):
        digest = workflow_digest()
        aio_commit = "a" * 40
        spec = synthetic_build_spec(aio_commit, digest)
        for missing, diagnostic in (
            ("aio-workflow", "installed workflow root"),
            (
                "aio-workflow/aio-workflow-files.txt",
                "installed workflow manifest",
            ),
            ("var/jenkins_home/jobs", "installed Jenkins jobs"),
            (
                "var/jenkins_home/jobs/PIC-SURE Pipeline/config.xml",
                "could not fingerprint",
            ),
        ):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                validator = create_installed_validator_bundle(tmp_path)
                missing_path = tmp_path / missing
                if missing_path.is_dir():
                    shutil.rmtree(missing_path)
                else:
                    missing_path.unlink()
                spec_path = tmp_path / "build-spec.json"
                spec_path.write_text(json.dumps(spec))
                result = subprocess.run(
                    ["bash", str(validator), str(spec_path)],
                    cwd=tmp_path,
                    env={**os.environ, "AIO_WORKFLOW_COMMIT": aio_commit},
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)

    def test_source_layout_named_scripts_is_not_misclassified_as_installed(self):
        digest = workflow_digest()
        aio_commit = "a" * 40
        spec = synthetic_build_spec(aio_commit, digest)
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            validator = create_source_validator_bundle(tmp_path)
            spec_path = tmp_path / "build-spec.json"
            spec_path.write_text(json.dumps(spec))
            result = subprocess.run(
                ["bash", str(validator), str(spec_path)],
                cwd=tmp_path,
                env={**os.environ, "AIO_WORKFLOW_COMMIT": aio_commit},
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_source_layout_requires_its_checksum_helper(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            validator = create_source_validator_bundle(tmp_path)
            (validator.parent / "workflow-sha256.sh").unlink()
            result = subprocess.run(
                ["bash", str(validator), str(tmp_path / "missing.json")],
                cwd=tmp_path,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("trusted workflow checksum script", result.stderr)

    def test_installed_discriminator_is_only_canonical_resolved_scripts_path(self):
        source = VALIDATOR.read_text()
        self.assertIn('pwd -P)', source)
        self.assertIn('[[ "$SCRIPT_DIR" == "/scripts" ]]', source)
        self.assertNotIn('*/scripts', source)

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

    def test_declarative_convergence_covers_every_tracker_category(self):
        converged = """<flow-definition plugin="workflow-job@synthetic">
  <actions>
    <org.jenkinsci.plugins.pipeline.modeldefinition.actions.DeclarativeJobPropertyTrackerAction>
      <jobProperties><string>jenkins.model.BuildDiscarderProperty</string><string>org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty</string></jobProperties>
      <triggers><string>hudson.triggers.TimerTrigger</string></triggers>
      <parameters><string>release</string><string>enabled</string><string>target</string></parameters>
      <options><string>skipDefaultCheckout</string></options>
    </org.jenkinsci.plugins.pipeline.modeldefinition.actions.DeclarativeJobPropertyTrackerAction>
  </actions>
  <properties>
    <jenkins.model.BuildDiscarderProperty><strategy class="hudson.tasks.LogRotator"><daysToKeep>-1</daysToKeep><numToKeep>10</numToKeep><artifactDaysToKeep>-1</artifactDaysToKeep><artifactNumToKeep>-1</artifactNumToKeep></strategy></jenkins.model.BuildDiscarderProperty>
    <org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty plugin="workflow-job@synthetic"><abortPrevious>true</abortPrevious></org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty>
    <org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
      <triggers><hudson.triggers.TimerTrigger><spec>@daily</spec></hudson.triggers.TimerTrigger></triggers>
    </org.jenkinsci.plugins.workflow.job.properties.PipelineTriggersJobProperty>
    <hudson.model.ParametersDefinitionProperty><parameterDefinitions>
      <hudson.model.StringParameterDefinition><name>release</name><description>Release branch</description><defaultValue>main</defaultValue><trim>true</trim></hudson.model.StringParameterDefinition>
      <hudson.model.BooleanParameterDefinition><name>enabled</name><description>Enable rollout</description><defaultValue>true</defaultValue></hudson.model.BooleanParameterDefinition>
      <hudson.model.ChoiceParameterDefinition><name>target</name><description>Target deployment</description><choices><a><string>AIO</string><string>BDC</string></a></choices></hudson.model.ChoiceParameterDefinition>
    </parameterDefinitions></hudson.model.ParametersDefinitionProperty>
  </properties>
  <definition><script><![CDATA[pipeline {
    agent any
    parameters {
      string(name: 'release', defaultValue: 'main', description: 'Release branch', trim: true)
      booleanParam(name: 'enabled', defaultValue: true, description: 'Enable rollout')
      choice(name: 'target', choices: ['AIO', 'BDC'], description: 'Target deployment')
    }
    options { buildDiscarder(logRotator(numToKeepStr: '10')); disableConcurrentBuilds(abortPrevious: true); skipDefaultCheckout(false) }
    triggers { cron('@daily') }
    stages { stage('synthetic') { options { timeout(time: params.dynamic) }; steps { echo 'synthetic' } } }
  }]]></script></definition>
</flow-definition>"""
        tracked = {
            "parameter": "<parameters><string>release</string><string>enabled</string><string>target</string></parameters>",
            "trigger": "<triggers><string>hudson.triggers.TimerTrigger</string></triggers>",
            "option": "<options><string>skipDefaultCheckout</string></options>",
            "build discarder": (
                "<jobProperties><string>jenkins.model.BuildDiscarderProperty</string><string>org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty</string></jobProperties>"
            ),
        }
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.xml"
            config.write_text(converged)
            validate_declarative_convergence(config)
            for category, value in tracked.items():
                with self.subTest(category=category):
                    config.write_text(
                        converged.replace(
                            value, f"<{ET.fromstring(value).tag}/>"
                        )
                    )
                    with self.assertRaisesRegex(AssertionError, "not converged"):
                        validate_declarative_convergence(config)

            value_mutations = {
                "parameter type": ("string(name: 'release'", "text(name: 'release'"),
                "parameter default": ("<defaultValue>main</defaultValue>", "<defaultValue>dev</defaultValue>"),
                "parameter choice": ("<string>BDC</string>", "<string>Other</string>"),
                "parameter description": ("<description>Release branch</description>", "<description>Persisted drift</description>"),
                "trigger spec": ("<spec>@daily</spec>", "<spec>@hourly</spec>"),
                "discarder strategy": ('class="hudson.tasks.LogRotator"', 'class="synthetic.OtherRotator"'),
                "discarder count": ("<numToKeep>10</numToKeep>", "<numToKeep>9</numToKeep>"),
                "disable concurrent": ("<abortPrevious>true</abortPrevious>", "<abortPrevious>false</abortPrevious>"),
                "standalone option": ("skipDefaultCheckout(false)", "skipDefaultCheckout(params.dynamic)"),
            }
            for case, (current, mutation) in value_mutations.items():
                with self.subTest(case=case):
                    config.write_text(converged.replace(current, mutation, 1))
                    with self.assertRaises(AssertionError):
                        validate_declarative_convergence(config)

    def test_declarative_convergence_rejects_unknown_tracker_category(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.xml"
            config.write_text(
                """<flow-definition><actions>
<org.jenkinsci.plugins.pipeline.modeldefinition.actions.DeclarativeJobPropertyTrackerAction>
<jobProperties/><triggers/><parameters/><options/><mystery><string>unknown</string></mystery>
</org.jenkinsci.plugins.pipeline.modeldefinition.actions.DeclarativeJobPropertyTrackerAction>
</actions><definition><script>pipeline { agent any; stages {} }</script></definition></flow-definition>"""
            )
            with self.assertRaisesRegex(
                AssertionError, "unknown declarative tracker category"
            ):
                validate_declarative_convergence(config)

    def test_disable_concurrent_property_has_canonical_plugin_identity(self):
        root = ET.parse(JOBS / "PIC-SURE Pipeline/config.xml").getroot()
        property_node = root.find(
            "./properties/org.jenkinsci.plugins.workflow.job.properties."
            "DisableConcurrentBuildsJobProperty"
        )
        self.assertIsNotNone(property_node)
        self.assertEqual(property_node.get("plugin"), root.get("plugin"))

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
                "build(job: 'Parenthesized Named Build', wait: true)\n"
                "build 'Single Quoted Positional Build'\n"
                'build "Double Quoted Positional Build"\n'
                "build('Parenthesized Positional Build')\n"
                "build [job: 'Map Literal Build', wait: true]\n"
                "build([job: 'Parenthesized Map Literal Build', wait: true])\n"
                "build job: 'Trailing Comment Build' // build targetJob\n"
                "Jenkins.instance.getItem('Literal Scheduled Job').scheduleBuild2(0)\n"
                'Jenkins.instance.getItemByFullName("Full Name Scheduled Job").scheduleBuild2(0)'
                "]]></script></definition></flow-definition>"
            )
            self.assertEqual(
                jenkins_job_references(config),
                {
                    "Double Quoted Build",
                    "Parenthesized Named Build",
                    "Single Quoted Positional Build",
                    "Double Quoted Positional Build",
                    "Parenthesized Positional Build",
                    "Map Literal Build",
                    "Parenthesized Map Literal Build",
                    "Trailing Comment Build",
                    "Literal Scheduled Job",
                    "Full Name Scheduled Job",
                },
            )

    def test_trigger_scanner_discovers_supported_xml_forms(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.xml"
            config.write_text(
                """<project><publishers>
<hudson.tasks.BuildTrigger><childProjects>Freestyle One, Freestyle Two</childProjects></hudson.tasks.BuildTrigger>
<hudson.plugins.parameterizedtrigger.BuildTrigger><configs>
<hudson.plugins.parameterizedtrigger.BuildTriggerConfig><projects>Parameterized Job</projects></hudson.plugins.parameterizedtrigger.BuildTriggerConfig>
</configs></hudson.plugins.parameterizedtrigger.BuildTrigger>
</publishers></project>"""
            )
            self.assertEqual(
                jenkins_job_references(config),
                {"Freestyle One", "Freestyle Two", "Parameterized Job"},
            )

    def test_trigger_scanner_rejects_dynamic_groovy_forms(self):
        for groovy in (
            "build job: targetJob",
            "build(job: targetJob)",
            "build targetJob",
            "build params.targetJob",
            "build job: 'Known Job' + suffix",
            "build(job: 'Known Job' + suffix)",
            'build "Known " + suffix',
            'build(job: "Known ${suffix}")',
            "build targetJob + suffix",
            "build targetJob.toString()",
            "build resolveTarget()",
            "build targetJob ?: 'Fallback Job'",
            "build getJobName()",
            "build jobs[0]",
            "build targetJob.trim()",
            "build map.get('k')",
            "build this.name + suffix",
            "build targetJob as String",
            "build 'Known Job'.toString()",
            "build [job: targetJob]",
            "build [job: 'Known Job'] + extra",
            "if (ready) build targetJob",
            "wrap(build(resolveTarget()))",
            "def values = [build(job: targetJob)]",
            "def result = ready ? build([job: targetJob]) : null",
            "Jenkins.instance.getItemByFullName(targetJob).scheduleBuild2(0)",
            "Jenkins.instance.getItem('Known Job' + suffix).scheduleBuild2(0)",
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

    def test_trigger_scanner_resolves_literal_calls_in_expression_contexts(self):
        contexts = {
            "if": ("if (ready) build 'If Job'", "If Job"),
            "while": ('while (ready) build "While Job"', "While Job"),
            "case": (
                "switch (kind) { case 'x': build job: 'Case Job'; break }",
                "Case Job",
            ),
            "ternary": (
                "def result = ready ? build('Ternary Job') : null",
                "Ternary Job",
            ),
            "list": (
                "def results = [build(job: 'List Job', wait: true)]",
                "List Job",
            ),
            "nested argument": (
                "wrap(build([job: 'Nested Job', wait: true]))",
                "Nested Job",
            ),
            "map value": (
                "def results = [downstream: build('Map Value Job')]",
                "Map Value Job",
            ),
        }
        for context, (groovy, job) in contexts.items():
            with self.subTest(context=context), tempfile.TemporaryDirectory() as tmp:
                config = Path(tmp) / "config.xml"
                config.write_text(
                    "<flow-definition><definition><script><![CDATA["
                    f"{groovy}"
                    "]]></script></definition></flow-definition>"
                )
                self.assertEqual(jenkins_job_references(config), {job})

    def test_trigger_scanner_ignores_non_step_build_tokens(self):
        controls = {
            "comments": "// build targetJob\n/* build resolveTarget() */",
            "string": 'def message = "build job: targetJob"',
            "closure parameter": "items.each { build -> echo build }",
            "multiple closure parameters": (
                "items.inject(null) { value, build -> echo build }"
            ),
            "loop parameter": "for (build in builds) { echo build }",
            "method declaration": "def build(String name) { return name }",
            "typed declaration": "void build(String name) { echo name }",
            "custom typed declaration": (
                "SyntheticResult build(String name) { return null }"
            ),
            "variable declaration": "def build = 'ordinary variable'",
            "assignment": "build = targetJob",
            "compound assignment": "build += suffix",
            "map key": "def value = [build: 'ordinary map value']",
            "receiver call": "b.build 'Receiver Call'",
            "property call": "b?.build('Property Call')",
            "ordinary argument": "consume(build)",
            "ordinary return": "return build",
            "ordinary list value": "def values = [build]",
            "ordinary property": "build.toString()",
        }
        for control, groovy in controls.items():
            with self.subTest(control=control), tempfile.TemporaryDirectory() as tmp:
                config = Path(tmp) / "config.xml"
                config.write_text(
                    "<flow-definition><definition><script><![CDATA["
                    f"{groovy}"
                    "]]></script></definition></flow-definition>"
                )
                self.assertEqual(jenkins_job_references(config), set())

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
                self.assertIn(
                    f"{tmp_path / 'config/jenkins_home'}:/var/jenkins_home",
                    docker_command,
                )
                self.assertIn(
                    f"{ROOT / 'validate-build-spec.sh'}:/scripts/validate-build-spec.sh:ro",
                    docker_command,
                )
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
