#!/usr/bin/env python3

import base64
import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request


BACKEND_COMMIT = "0178bbd2d1753e07dcead77a6d0e8ca37bf76dd8"
FRONTEND_COMMIT = "7b69aa960ff98f97c1a2d026b7137b0e3dcdf603"
MIGRATIONS_COMMIT = "05b1a77512dc0921570f0d442853fdcee75b8131"
RELEASE_CONTROL_COMMIT = "bfb07196be55f7f121dc250f7aa51d826642ff86"
BDC_MIGRATION_COMMIT = "5d2ba9f59f161ace5e807c82a0580518a9d44d16"
AIO_PROOF_BASE = "715857456594814957d9abc26ad14efbccb65e11"
AIO_RELEASE_COMMIT = "715857456594814957d9abc26ad14efbccb65e11"
ROLLOUT_SHA256 = "f8cb265d735b757872391e04fdcd5b999b785eaa427ca13f8f2eefd493715359"
MYSQL_IMAGE = "mysql:8.0.43@sha256:ccf4fed7ff4b886aeb3573a1f5d5b509525ecff55a2d1e2653c27a5abdded309"
FLYWAY_IMAGE = "flyway/flyway:11.7.2@sha256:8ace7d9825bb3ad1d6e14ee27b3a830b638ac841ba424b99b2d92aa65a99d484"
BUILD_IMAGE = "maven:3-amazoncorretto-25@sha256:de7a3e517efac1b933af6ceb375974a061ba71c908ea51a18bd937716a8ade93"
RUNTIME_IMAGE = "amazoncorretto:25@sha256:397edfaaa0fdfc95001d4c4a4ab82174073277a5d630fd9375c94dca25b5991d"
PLAYWRIGHT_IMAGE = "mcr.microsoft.com/playwright:v1.60.0-noble@sha256:9bd26ad900bb5e0f4dee75839e957a89ae89c2b7ab1e76050e559790e946b948"
SYNTHETIC_PASSWORD = "t22a-local-password"
SYNTHETIC_LOGGING_KEY = "t22a-local-logging-key"
SYNTHETIC_CLIENT_SECRET = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
APPLICATION_UUID = "11111111-1111-1111-1111-111111111111"
TICKET15_RELEASE_CONTROL_COMMIT = "78c8a9efde3989afae9f137dac583c739667f59d"
TICKET15_PSAMA_COMMIT = "ca8ac3641ba122a93cda8a5d7cad7f23f7a46bb6"
TICKET15_PSA_COMMIT = "88a767c273af776ca1edeb7be4d4365393e376f7"
TICKET15_MIGRATIONS_COMMIT = "84ad03076ce9f69f27ebb51d0efa5d3d43114ea4"
TICKET18_FINAL_BACKEND_COMMIT = "9c17b0caecbee1b7f2231ca974b8b8b59ba7f211"
OWNER_DIAGNOSTIC_FILENAMES = {
    "browser-config.json",
    "browser-result.json",
    "failed-cell.json",
    "observed-matrix.tsv",
    "provenance.json",
    "rollback-order.json",
    "ticket17-result.json",
}


class ProofError(RuntimeError):
    pass


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command(arguments, *, cwd=None, env=None, capture=False, timeout=1800, check=True, stdin=None):
    result = subprocess.run(
        [str(value) for value in arguments], cwd=cwd, env=env, input=stdin,
        text=True, capture_output=capture, timeout=timeout, check=False,
    )
    if check and result.returncode != 0:
        output = ""
        if capture:
            output = f"\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        raise ProofError(f"command failed with status {result.returncode}: {' '.join(map(str, arguments))}{output}")
    return result


def repository_head(root):
    return command(["git", "-C", root, "rev-parse", "HEAD"], capture=True, timeout=30).stdout.strip()


def require_repository(root, expected, label):
    head = repository_head(root)
    if head != expected:
        raise ProofError(f"{label} commit drift: expected {expected}, got {head}")
    status = command(
        ["git", "-C", root, "status", "--porcelain", "--untracked-files=all"],
        capture=True, timeout=30,
    ).stdout
    if status:
        raise ProofError(f"{label} source is dirty:\n{status.rstrip()}")
    return head


def require_current_repository(root, label):
    return require_repository(root, repository_head(root), label)


def copy_owner_diagnostics(runtime_root, diagnostics_root):
    runtime_root = Path(runtime_root)
    diagnostics_root = Path(diagnostics_root)
    copied = 0
    if not runtime_root.is_dir():
        return copied
    for source in sorted(runtime_root.rglob("*")):
        if source.is_symlink() or not source.is_file():
            continue
        if source.name not in OWNER_DIAGNOSTIC_FILENAMES and source.suffix != ".log":
            continue
        destination = diagnostics_root / source.relative_to(runtime_root)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        copied += 1
    return copied


def validate_composed_owner_results(feed_root, feed_matrix, binary_matrix, binary_owner_head):
    feed_root = Path(feed_root)
    feed_observed = feed_root / "observed-matrix.tsv"
    if not feed_observed.is_file() or feed_observed.read_bytes() != Path(feed_matrix).read_bytes():
        raise ProofError("Ticket 18 runtime matrix does not match its authoritative matrix")

    result_path = feed_root / "ticket17-result.json"
    if not result_path.is_file():
        raise ProofError("Ticket 17 runtime result is missing from Ticket 18 composition")
    result = json.loads(result_path.read_text(encoding="utf-8"))
    expected_result = {
        "command": "tests/operations-binary-compatibility/test.sh all",
        "matrixSha256": sha256_file(binary_matrix),
        "proofOwnerHead": binary_owner_head,
        "status": 0,
        "passed": True,
    }
    if result != expected_result:
        raise ProofError(f"Ticket 17 runtime result is invalid: {result}")

    binary_roots = sorted(
        path for path in (feed_root / "ticket17-temp").glob("operations-binary-*")
        if path.is_dir()
    )
    if len(binary_roots) != 1:
        raise ProofError(
            f"Ticket 17 runtime evidence is ambiguous: found {len(binary_roots)} owner roots"
        )
    binary_observed = binary_roots[0] / "observed-matrix.tsv"
    if not binary_observed.is_file() or binary_observed.read_bytes() != Path(binary_matrix).read_bytes():
        raise ProofError("Ticket 17 runtime matrix does not match its authoritative matrix")


def local_checkout(source, destination, commit):
    command(
        ["git", "clone", "--quiet", "--local", "--no-hardlinks", "--no-checkout", source, destination],
        timeout=300,
    )
    command(
        ["git", "-C", destination, "-c", "advice.detachedHead=false", "checkout", "--quiet", "--detach", commit],
        timeout=60,
    )
    require_repository(destination, commit, f"historical owner input {destination.name}")


def export_head(repository, destination):
    destination.mkdir(parents=True)
    archive = destination.parent / f"{destination.name}.tar"
    with archive.open("wb") as output:
        result = subprocess.run(
            ["git", "-C", str(repository), "archive", "HEAD"], stdout=output,
            stderr=subprocess.PIPE, timeout=60, check=False,
        )
    if result.returncode != 0:
        raise ProofError(f"cannot export {repository}: {result.stderr.decode(errors='replace')}")
    with tarfile.open(archive) as bundle:
        resolved = destination.resolve()
        for member in bundle.getmembers():
            target = (destination / member.name).resolve()
            if target != resolved and resolved not in target.parents:
                raise ProofError(f"unsafe archive member: {member.name}")
        bundle.extractall(destination)
    archive.unlink()


def jwt(subject, uuid, email, secret=SYNTHETIC_CLIENT_SECRET):
    now = int(time.time())
    header = {"alg": "HS256"}
    payload = {
        "sub": subject, "uuid": uuid, "email": email, "name": "T22A synthetic user",
        "iss": "t22a-local-proof", "jti": uuid, "iat": now, "exp": now + 3600,
    }

    def encode(value):
        raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        return base64.urlsafe_b64encode(raw).rstrip(b"=")

    unsigned = encode(header) + b"." + encode(payload)
    signature = base64.urlsafe_b64encode(hmac.new(secret.encode(), unsigned, hashlib.sha256).digest()).rstrip(b"=")
    return (unsigned + b"." + signature).decode()


def expected_privileged_statuses(route_name):
    expected = {
        "list": {200},
        "create": {400},
        "save": {400},
        "order": {200},
        "update": {400},
        "publish": {400},
        "disable": {409},
        "archive": {409},
        "restore": {400},
    }
    return expected[route_name]


def validate_runtime_result(contract, result):
    runtime = result.get("observations", {}).get("runtimeArtifacts")
    if not isinstance(runtime, dict):
        raise ProofError("runtime observations are required")
    if set(result) != set(contract["required"]):
        raise ProofError("runtime result fields do not match the result schema")
    if result.get("schemaVersion") != contract["properties"]["schemaVersion"]["const"]:
        raise ProofError("runtime result schema version drift")
    if result.get("deployment") not in contract["properties"]["deployment"]["enum"]:
        raise ProofError("runtime result deployment is invalid")
    statuses = set(contract["properties"]["status"]["enum"])
    if result.get("status") not in statuses:
        raise ProofError("runtime result status is invalid")

    commit_pattern = re.compile(contract["$defs"]["commit"]["pattern"])
    source_commits = result.get("sourceCommits")
    required_sources = set(contract["properties"]["sourceCommits"]["required"])
    if not isinstance(source_commits, dict) or not required_sources.issubset(source_commits):
        raise ProofError("runtime source commits are incomplete")
    if any(not isinstance(value, str) or not commit_pattern.fullmatch(value) for value in source_commits.values()):
        raise ProofError("runtime source commit is not an exact Git SHA")

    image_pattern = re.compile(contract["$defs"]["digestImage"]["pattern"])
    images = result.get("images")
    if not isinstance(images, dict) or not images or any(
        not isinstance(value, str) or not image_pattern.fullmatch(value) for value in images.values()
    ):
        raise ProofError("runtime image provenance is incomplete or not digest-pinned")
    sha_pattern = re.compile(contract["$defs"]["sha256"]["pattern"])
    if not isinstance(result.get("rolloutContractSha256"), str) or not sha_pattern.fullmatch(
        result["rolloutContractSha256"]
    ):
        raise ProofError("runtime rollout contract checksum is invalid")

    for field in ("checks", "limitations"):
        values = result.get(field)
        required = set(contract["properties"][field]["required"])
        if not isinstance(values, dict) or set(values) != required:
            raise ProofError(f"runtime {field} are incomplete")
        if any(value not in statuses for value in values.values()):
            raise ProofError(f"runtime {field} contain an invalid status")

    observations = result.get("observations")
    required_observations = set(contract["properties"]["observations"]["required"])
    if not isinstance(observations, dict) or set(observations) != required_observations:
        raise ProofError("runtime observations are incomplete")
    for field in (
        "emptyFeedCount",
        "emptyBannerRegionCount",
        "managementRouteCount",
        "publishedFeedCount",
        "publishedBannerRegionCount",
    ):
        if not isinstance(observations[field], int) or observations[field] < 0:
            raise ProofError(f"runtime observation {field} is invalid")
    if not isinstance(observations["auditAction"], str) or not observations["auditAction"]:
        raise ProofError("runtime audit observation is invalid")
    if set(runtime) != {
        "applicationArtifactDigests",
        "builtImageIds",
        "publishedBannerUuid",
    }:
        raise ProofError("runtime artifact observations are incomplete")
    artifact_digests = runtime["applicationArtifactDigests"]
    if not isinstance(artifact_digests, dict) or not artifact_digests or any(
        not isinstance(value, str) or not sha_pattern.fullmatch(value)
        for value in artifact_digests.values()
    ):
        raise ProofError("runtime application artifact digests are invalid")
    built_images = runtime["builtImageIds"]
    if not isinstance(built_images, dict) or not built_images or any(
        not isinstance(value, str) or not value for value in built_images.values()
    ):
        raise ProofError("runtime built image identifiers are invalid")
    if not re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}",
        runtime["publishedBannerUuid"],
        flags=re.IGNORECASE,
    ):
        raise ProofError("runtime published banner UUID is invalid")
    extensions = result.get("deploymentExtensions")
    if not isinstance(extensions, dict) or result["deployment"] not in extensions:
        raise ProofError("runtime deployment extension is missing")


class Harness:
    def __init__(self, aio_root, temp_root, run_id):
        self.aio_root = Path(aio_root).resolve()
        self.test_dir = self.aio_root / "tests" / "banner-local-integration"
        self.temp_root = Path(temp_root).resolve()
        self.run_id = run_id
        self.label = f"org.pic-sure.banner-local-integration={run_id}"
        self.network = f"banner-local-{run_id}"
        self.contract = json.loads((self.test_dir / "contract.json").read_text(encoding="utf-8"))
        self.expected = json.loads((self.test_dir / "expected-result.json").read_text(encoding="utf-8"))
        self.backend = Path(os.environ["BANNER_LOCAL_BACKEND_ROOT"]).resolve()
        self.frontend = Path(os.environ["BANNER_LOCAL_FRONTEND_ROOT"]).resolve()
        self.migrations = Path(os.environ["BANNER_LOCAL_MIGRATIONS_ROOT"]).resolve()
        self.release_control = Path(os.environ["BANNER_LOCAL_RELEASE_CONTROL_ROOT"]).resolve()
        self.bdc = Path(os.environ["BANNER_LOCAL_BDC_ROOT"]).resolve()
        self.legacy_psama = Path(os.environ["BANNER_LOCAL_LEGACY_PSAMA_ROOT"]).resolve()
        self.backend_export = self.temp_root / "source" / "backend"
        self.frontend_export = self.temp_root / "source" / "frontend"
        self.logs = self.temp_root / "logs"
        self.logs.mkdir(parents=True, exist_ok=True)
        self.containers = {}
        self.urls = {}
        self.tokens = {}
        check_names = self.contract["properties"]["checks"]["required"]
        limitation_names = self.contract["properties"]["limitations"]["required"]
        self.observed = {
            "schemaVersion": 1,
            "deployment": "AIO",
            "status": "FAIL",
            "sourceCommits": {},
            "images": {},
            "rolloutContractSha256": "",
            "checks": {name: "NOT_RUN" for name in check_names},
            "observations": {},
            "limitations": {name: "NOT_RUN" for name in limitation_names},
            "deploymentExtensions": {"AIO": {}},
        }

    def docker(self, *arguments, capture=False, timeout=300, check=True, stdin=None):
        return command(
            ["docker", *arguments], capture=capture, timeout=timeout, check=check, stdin=stdin
        )

    def verify_inputs(self):
        aio_head = require_current_repository(self.aio_root, "executing AIO")
        ancestry = command(
            ["git", "-C", self.aio_root, "merge-base", "--is-ancestor", AIO_PROOF_BASE, aio_head],
            check=False, timeout=30,
        )
        if ancestry.returncode != 0:
            raise ProofError(f"AIO proof is not descended from required base {AIO_PROOF_BASE}")
        if (
            self.contract.get("properties", {}).get("schemaVersion", {}).get("const")
            != self.expected.get("schemaVersion")
            or self.expected.get("deployment") not in self.contract["properties"]["deployment"]["enum"]
            or set(self.contract["properties"]["checks"]["required"])
            != set(self.expected.get("checks", {}))
            or set(self.contract["properties"]["limitations"]["required"])
            != set(self.expected.get("limitations", {}))
        ):
            raise ProofError("checked-in result contract and expected AIO row disagree")
        source_commits = {
            "deploymentConfig": aio_head,
            "backend": require_repository(self.backend, BACKEND_COMMIT, "backend"),
            "frontend": require_repository(self.frontend, FRONTEND_COMMIT, "frontend"),
            "migrationSource": require_repository(self.migrations, MIGRATIONS_COMMIT, "migrations"),
            "releaseControl": require_repository(
                self.release_control, RELEASE_CONTROL_COMMIT, "release control"
            ),
        }
        require_repository(self.bdc, BDC_MIGRATION_COMMIT, "BDC/AIM migration proof")
        legacy_status = command(
            ["git", "-C", self.legacy_psama, "status", "--porcelain", "--untracked-files=all"],
            capture=True,
            timeout=30,
        ).stdout
        legacy_tag = command(
            ["git", "-C", self.legacy_psama, "rev-parse", "refs/tags/v4.2.2^{}"],
            capture=True,
            timeout=30,
        ).stdout.strip()
        if legacy_status or legacy_tag != TICKET15_PSAMA_COMMIT:
            raise ProofError("legacy PSAMA owner input is dirty or missing exact v4.2.2 commit")
        rollout = self.backend / ".github" / "banner-rollout-contract.json"
        if sha256_file(rollout) != ROLLOUT_SHA256:
            raise ProofError("authoritative rollout contract checksum drift")
        source = json.loads(
            (self.aio_root / "initial-configuration/jenkins/jenkins-docker/banner-rollout-source.json").read_text()
        )
        if source != {"contractSourceCommit": BACKEND_COMMIT, "contractSha256": ROLLOUT_SHA256}:
            raise ProofError(f"AIO rollout source drift: {source}")
        spec = json.loads((self.release_control / "build-spec.json").read_text())
        entries = {item["project_job_git_key"]: item["git_hash"] for item in spec["application"]}
        expected = {"PSA": BACKEND_COMMIT, "PSF": FRONTEND_COMMIT, "PSM": MIGRATIONS_COMMIT, "AIO": AIO_RELEASE_COMMIT}
        if {key: entries.get(key) for key in expected} != expected:
            raise ProofError(f"release tuple drift: {entries}")
        workflow = command(
            ["bash", self.aio_root / "workflow-sha256.sh"], cwd=self.aio_root,
            env={**os.environ, "AIO_WORKFLOW_MODE": "source"}, capture=True,
        ).stdout.strip()
        if workflow != spec["bannerRollout"]["aioWorkflowSha256"]:
            raise ProofError(f"AIO workflow checksum drift: {workflow}")
        browser_from = (self.test_dir / "browser.Dockerfile").read_text(encoding="utf-8")
        if not browser_from.startswith(f"FROM {PLAYWRIGHT_IMAGE}\n"):
            raise ProofError("browser image provenance drift")
        self.observed["sourceCommits"] = source_commits
        self.observed["images"] = {
            "mysql": MYSQL_IMAGE,
            "flyway": FLYWAY_IMAGE,
            "javaBuild": BUILD_IMAGE,
            "javaRuntime": RUNTIME_IMAGE,
            "playwright": PLAYWRIGHT_IMAGE,
        }
        self.observed["rolloutContractSha256"] = sha256_file(rollout)
        self.observed["deploymentExtensions"]["AIO"].update(
            {"proofBase": AIO_PROOF_BASE, "releaseWorkflowCommit": entries["AIO"]}
        )
        self.observed["checks"]["releaseTupleAndRolloutContract"] = "PASS"

    def compose_owner_contracts(self):
        paths = {
            "ticket15EntrypointSha256": self.migrations / "tests/aio-deployment-migration/test.sh",
            "ticket15MatrixSha256": self.migrations / "tests/aio-deployment-migration/matrix.tsv",
            "ticket17EntrypointSha256": self.backend / "tests/operations-binary-compatibility/test.sh",
            "ticket17MatrixSha256": self.backend / "tests/operations-binary-compatibility/matrix.tsv",
            "ticket18EntrypointSha256": self.backend / "tests/banner-feed-compatibility/test.sh",
            "ticket18MatrixSha256": self.backend / "tests/banner-feed-compatibility/matrix.tsv",
        }
        artifacts = {field: sha256_file(path) for field, path in paths.items()}
        expected_artifacts = self.expected["deploymentExtensions"]["AIO"]["ownerArtifacts"]
        if artifacts != expected_artifacts:
            raise ProofError(f"owner artifact drift: {artifacts}")
        self.observed["deploymentExtensions"]["AIO"]["ownerArtifacts"] = artifacts

        historical = self.temp_root / "ticket15-owner-inputs"
        historical.mkdir()
        local_checkout(
            self.release_control, historical / "release-control", TICKET15_RELEASE_CONTROL_COMMIT
        )
        local_checkout(self.legacy_psama, historical / "psama", TICKET15_PSAMA_COMMIT)
        local_checkout(self.backend, historical / "psa", TICKET15_PSA_COMMIT)
        local_checkout(self.migrations, historical / "migrations", TICKET15_MIGRATIONS_COMMIT)
        env = {
            **os.environ,
            "PYTHONDONTWRITEBYTECODE": "1",
            "AIO_PROOF_SOURCE_ROOT": str(historical),
        }
        command(
            [self.migrations / "tests/aio-deployment-migration/test.sh", "all"],
            cwd=self.migrations,
            env=env,
            timeout=3600,
        )
        self.observed["checks"]["migrationOwner"] = "PASS"

        compatibility_env = {
            **os.environ,
            "PYTHONDONTWRITEBYTECODE": "1",
            "OPERATIONS_COMPAT_SOURCE_ROOT": str(self.backend),
            "FRONTEND_COMPAT_SOURCE_ROOT": str(self.frontend),
            "AIO_PROOF_SOURCE_ROOT": str(self.migrations),
            "BDC_PROOF_SOURCE_ROOT": str(self.bdc),
            "COMPAT_M2_ROOT": os.environ.get(
                "BANNER_LOCAL_M2_ROOT", str(self.temp_root / "m2")
            ),
            "BANNER_FEED_M2_ROOT": os.environ.get(
                "BANNER_LOCAL_M2_ROOT", str(self.temp_root / "m2")
            ),
        }
        owner_runtime = self.temp_root / "owner-runtime"
        owner_runtime.mkdir()
        compatibility_env.update(
            {
                "TMPDIR": str(owner_runtime),
                "KEEP_BANNER_FEED_TEMP": "true",
                "KEEP_BANNER_FEED_TEMP_ON_FAILURE": "true",
                "KEEP_COMPAT_TEMP": "true",
                "KEEP_COMPAT_TEMP_ON_FAILURE": "true",
            }
        )
        owner_result = command(
            [self.backend / "tests/banner-feed-compatibility/test.sh", "all"],
            cwd=self.backend,
            env=compatibility_env,
            timeout=7200,
            capture=True,
            check=False,
        )
        owner_output = (owner_result.stdout or "") + (owner_result.stderr or "")
        (self.logs / "ticket18-owner.log").write_text(owner_output, encoding="utf-8")
        copy_owner_diagnostics(owner_runtime, self.temp_root / "owner-diagnostics")
        if owner_result.returncode != 0:
            raise ProofError(
                "Ticket 18 authoritative all entrypoint failed with status "
                f"{owner_result.returncode}; see logs/ticket18-owner.log and owner-diagnostics"
            )
        feed_roots = sorted(
            path for path in owner_runtime.glob("banner-feed-*") if path.is_dir()
        )
        if len(feed_roots) != 1:
            raise ProofError(
                f"Ticket 18 runtime evidence is ambiguous: found {len(feed_roots)} owner roots"
            )
        validate_composed_owner_results(
            feed_roots[0],
            self.backend / "tests/banner-feed-compatibility/matrix.tsv",
            self.backend / "tests/operations-binary-compatibility/matrix.tsv",
            TICKET18_FINAL_BACKEND_COMMIT,
        )
        self.observed["checks"]["binarySchemaOwner"] = "PASS"
        self.observed["checks"]["feedRollbackOwner"] = "PASS"

        release_workflow_root = self.temp_root / "reviewed-release-workflow"
        local_checkout(self.aio_root, release_workflow_root, AIO_RELEASE_COMMIT)
        for optimized in (False, True):
            owner_env = {
                **os.environ,
                "PYTHONDONTWRITEBYTECODE": "1",
                "AIO_PIN_VALIDATION_ROOT": str(release_workflow_root),
            }
            if optimized:
                owner_env["PYTHONOPTIMIZE"] = "1"
            command(
                [sys.executable, self.aio_root / "tests/banner-rollout/test_contract.py"],
                cwd=self.aio_root,
                env=owner_env,
                timeout=300,
            )
            command(
                [sys.executable, self.release_control / "tests/test_build_spec.py"],
                cwd=self.release_control,
                env=owner_env,
                timeout=300,
            )
        self.observed["checks"]["deploymentRolloutOwner"] = "PASS"

    def prepare_sources(self):
        export_head(self.backend, self.backend_export)
        export_head(self.frontend, self.frontend_export)
        (self.frontend_export / ".env").write_text(
            "VITE_APPLICATION_NAME=Ticket 22A local proof\n"
            "VITE_ORIGIN=http://frontend\n"
            "VITE_CONFIG_MODE=override\n"
            "VITE_API_CONFIG_FEATURES=\nVITE_API_CONFIG_SETTINGS=\nVITE_API_CONFIG_BRANDING=\n"
            "VITE_MAX_CONFIG_RETRIES=0\n",
            encoding="utf-8",
        )
        generated = self.temp_root / "generated"
        generated.mkdir()
        (generated / "httpd-vhosts.conf").write_text(
            "<VirtualHost *:80>\n"
            "  ServerName frontend\n  ProxyRequests Off\n  ProxyPreserveHost On\n"
            "  ProxyPass /picsure/ http://gateway:8080/\n"
            "  ProxyPassReverse /picsure/ http://gateway:8080/\n"
            "  ProxyPass / http://127.0.0.1:3000/\n"
            "  ProxyPassReverse / http://127.0.0.1:3000/\n"
            "  ErrorLog /dev/stderr\n  CustomLog /dev/stdout combined\n</VirtualHost>\n",
            encoding="utf-8",
        )

    def build(self):
        m2 = Path(os.environ.get("BANNER_LOCAL_M2_ROOT", self.temp_root / "m2")).resolve()
        m2.mkdir(parents=True, exist_ok=True)
        modules = (
            "services/pic-sure-operations-service,services/pic-sure-gateway,"
            "services/pic-sure-auth-microapp/pic-sure-auth-services,services/pic-sure-logging"
        )
        self.docker(
            "run", "--rm", "--label", self.label, "--user", f"{os.getuid()}:{os.getgid()}",
            "-e", "HOME=/tmp/t22a-home", "-e", "MAVEN_CONFIG=/m2",
            "-v", f"{self.backend_export}:/source", "-v", f"{m2}:/m2", "-w", "/source", BUILD_IMAGE,
            "mvn", "-q", "-B", "-Dmaven.repo.local=/m2", "-DskipTests", "-pl", modules, "-am", "package",
            timeout=1800,
        )
        self.docker(
            "run", "--rm", "--label", self.label, "--user", f"{os.getuid()}:{os.getgid()}",
            "-e", "HOME=/tmp/t22a-home", "-e", "MAVEN_CONFIG=/m2",
            "-v", f"{self.backend_export}:/source", "-v", f"{m2}:/m2", "-w", "/source", BUILD_IMAGE,
            "mvn", "-q", "-B", "-Dmaven.repo.local=/m2",
            "-Dtest=BannerManagementCacheRefreshIntegrationTest,BannerRolloutContractTest",
            "-Dsurefire.failIfNoSpecifiedTests=false", "-pl",
            "services/pic-sure-auth-microapp/pic-sure-auth-services", "-am", "test", timeout=900,
        )
        self.observed["checks"]["authorizationCacheOwner"] = "PASS"
        self.jars = {
            "operations": self.backend_export / "services/pic-sure-operations-service/target/pic-sure-operations-service-3.0.0.jar",
            "gateway": self.backend_export / "services/pic-sure-gateway/target/pic-sure-gateway-3.0.0.jar",
            "psama": self.backend_export / "services/pic-sure-auth-microapp/pic-sure-auth-services/target/pic-sure-auth-services-3.0.0.jar",
            "logging": self.backend_export / "services/pic-sure-logging/target/pic-sure-logging-3.0.0.jar",
        }
        missing = [name for name, path in self.jars.items() if not path.is_file()]
        if missing:
            raise ProofError(f"missing real application jars: {missing}")
        self.observed["observations"]["runtimeArtifacts"] = {
            "applicationArtifactDigests": {
                name: sha256_file(path) for name, path in self.jars.items()
            }
        }
        frontend_image = f"banner-local-frontend:{self.run_id.lower()}"
        self.docker(
            "build", "--label", self.label, "--tag", frontend_image,
            "--file", self.frontend_export / "Dockerfile", self.frontend_export,
            capture=True, timeout=1800,
        )
        browser_image = f"banner-local-browser:{self.run_id.lower()}"
        self.docker(
            "build", "--label", self.label, "--tag", browser_image,
            "--file", self.test_dir / "browser.Dockerfile", self.test_dir,
            capture=True, timeout=900,
        )
        self.images = {"frontend": frontend_image, "browser": browser_image}
        self.observed["observations"]["runtimeArtifacts"]["builtImageIds"] = {
            name: self.docker("image", "inspect", "--format", "{{.Id}}", image, capture=True).stdout.strip()
            for name, image in self.images.items()
        }

    def start_mysql_and_migrate(self):
        self.docker("network", "create", "--label", self.label, self.network)
        name = f"banner-local-{self.run_id}-mysql"
        self.docker(
            "run", "--detach", "--name", name, "--label", self.label, "--network", self.network,
            "--network-alias", "mysql", "-e", f"MYSQL_ROOT_PASSWORD={SYNTHETIC_PASSWORD}", MYSQL_IMAGE,
        )
        self.containers["mysql"] = name
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            result = self.docker(
                "exec", "-e", f"MYSQL_PWD={SYNTHETIC_PASSWORD}", name,
                "mysqladmin", "ping", "-h127.0.0.1", "-uroot", "--silent", check=False,
            )
            if result.returncode == 0:
                break
            time.sleep(1)
        else:
            raise ProofError("MySQL did not become ready")
        self.mysql("CREATE DATABASE auth; CREATE DATABASE picsure;", database=None)
        migration_root = self.temp_root / "migrations"
        shutil.copytree(self.backend_export / "services/pic-sure-auth-microapp/pic-sure-auth-db/db/sql", migration_root / "core-auth")
        shutil.copytree(self.backend_export / "services/pic-sure-operations-service/db/sql", migration_root / "core-picsure")
        shutil.copytree(self.migrations / "Baseline/auth", migration_root / "custom-auth")
        shutil.copytree(self.migrations / "Baseline/picsure", migration_root / "custom-picsure")
        for path in (migration_root / "custom-auth").glob("*.sql"):
            path.write_text(path.read_text().replace("__APPLICATION_UUID__", APPLICATION_UUID.replace("-", "")))
        for path in (migration_root / "custom-picsure").glob("*.sql"):
            path.write_text(path.read_text().replace("__RESOURCE_UUID__", "22222222222222222222222222222222"))
        self.flyway("auth", migration_root / "core-auth", "flyway_schema_history", False)
        self.flyway("picsure", migration_root / "core-picsure", "flyway_schema_history", False)
        self.flyway("picsure", migration_root / "custom-picsure", "flyway_custom_schema_history", True)
        self.flyway("auth", migration_root / "custom-auth", "flyway_custom_schema_history", True)
        maxima = self.mysql(
            "SELECT CONCAT((SELECT MAX(CAST(version AS UNSIGNED)) FROM auth.flyway_custom_schema_history WHERE success=1),':',"
            "(SELECT MAX(CAST(version AS UNSIGNED)) FROM picsure.flyway_custom_schema_history WHERE success=1));",
            database=None,
        ).strip()
        if maxima != "11:12":
            raise ProofError(f"AIO migration maxima drift: {maxima}")
        self.observed["checks"]["authorizationAndApplicationMigrations"] = "PASS"

    def flyway(self, schema, directory, history, baseline):
        options = [
            f"-url=jdbc:mysql://mysql:3306/{schema}?allowPublicKeyRetrieval=true&useSSL=false&serverTimezone=UTC",
            "-user=root", f"-password={SYNTHETIC_PASSWORD}", f"-table={history}",
            "-locations=filesystem:/flyway/sql", "-connectRetries=30", "-validateMigrationNaming=true",
        ]
        if baseline:
            options.append("-baselineOnMigrate=true")
        self.docker(
            "run", "--rm", "--label", self.label, "--network", self.network,
            "-v", f"{directory.resolve()}:/flyway/sql:ro", FLYWAY_IMAGE, *options, "migrate", timeout=300,
        )

    def mysql(self, sql, database="auth"):
        arguments = [
            "exec", "--interactive", "-e", f"MYSQL_PWD={SYNTHETIC_PASSWORD}", self.containers["mysql"],
            "mysql", "-h127.0.0.1", "-uroot", "--batch", "--skip-column-names",
        ]
        if database:
            arguments.append(database)
        return self.docker(*arguments, capture=True, stdin=sql).stdout

    def seed_auth(self):
        subjects = {
            "ordinary": ("20000000-0000-4000-8000-000000000001", "t22a-ordinary", "797FD002DC366B0D8420F998F885D0ED"),
            "admin": ("20000000-0000-4000-8000-000000000002", "t22a-admin", "8F885D0ED797FD002DC366B0D8420F99"),
            "super": ("20000000-0000-4000-8000-000000000003", "t22a-super", "002DC366B0D8420F998F885D0ED797FD"),
        }
        app_token = jwt(
            f"PSAMA_APPLICATION|{APPLICATION_UUID}", APPLICATION_UUID, "application@synthetic.invalid"
        )
        statements = [
            f"UPDATE application SET token='{app_token}' WHERE name='PICSURE';",
        ]
        for identity, (uuid, subject, role_hex) in subjects.items():
            email = f"{identity}@synthetic.invalid"
            user_token = jwt(f"LONG_TERM_TOKEN|{subject}", uuid, email)
            statements.append(
                "INSERT INTO user (uuid,auth0_metadata,general_metadata,connectionId,email,matched,subject,is_active,long_term_token) VALUES "
                f"(UUID_TO_BIN('{uuid}'),'{{}}','{{\"name\":\"T22A {identity}\"}}',"
                "0x97FD002DC366B0D8420F998F885D0ED7,"
                f"'{email}',b'1','{subject}',b'1','{user_token}');"
            )
            statements.append(f"INSERT INTO user_role VALUES (UUID_TO_BIN('{uuid}'),0x{role_hex});")
            self.tokens[identity] = user_token
        self.tokens["application"] = app_token
        self.mysql("\n".join(statements))

    def start_services(self):
        log_dir = self.temp_root / "audit-logs"
        log_dir.mkdir()
        self.start_jar(
            "logging", self.jars["logging"], "80", [
                "-e", f"LOGGING_API_KEY={SYNTHETIC_LOGGING_KEY}", "-e", "APP=pic-sure",
                "-e", "PLATFORM=all-in-one", "-e", "ENVIRONMENT=local-proof", "-e", "PORT=80",
                "-e", "ALLOWED_ORIGIN=*", "-v", f"{log_dir}:/app/logs",
            ], ["java", "-jar", "/application.jar"], "/health",
        )
        self.start_jar(
            "operations", self.jars["operations"], "8080", [
                "-e", "SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/picsure?serverTimezone=UTC",
                "-e", "SPRING_DATASOURCE_USERNAME=root", "-e", f"SPRING_DATASOURCE_PASSWORD={SYNTHETIC_PASSWORD}",
                "-e", "QUERY_SERVICE_INTERNAL_TOKEN=t22a-internal", "-e", "PICSURE_ACTUATOR_EXPOSURE=health",
                "-e", "PICSURE_ACTUATOR_REQUIRE_TOKEN=false", "-e", "LOGGING_SERVICE_URL=http://pic-sure-logging",
                "-e", f"LOGGING_API_KEY={SYNTHETIC_LOGGING_KEY}",
            ], ["java", "-jar", "/application.jar", "--logging.level.root=WARN"], "/operations/actuator/health/readiness",
        )
        self.start_jar(
            "psama", self.jars["psama"], "8090", [
                "-e", "DATASOURCE_URL=jdbc:mysql://mysql:3306/auth?serverTimezone=UTC", "-e", "DATASOURCE_USERNAME=root",
                "-e", f"DATASOURCE_PASSWORD={SYNTHETIC_PASSWORD}", "-e", f"APPLICATION_CLIENT_SECRET={SYNTHETIC_CLIENT_SECRET}",
                "-e", "APPLICATION_CLIENT_SECRET_IS_BASE_64=false", "-e", "TOS_ENABLED=false",
                "-e", f"STACK_SPECIFIC_APPLICATION_ID={APPLICATION_UUID}", "-e", "AUTH0_IDP_PROVIDER_IS_ENABLED=false",
                "-e", "OPEN_IDP_PROVIDER_IS_ENABLED=false", "-e", "PICSURE_ACTUATOR_EXPOSURE=health",
                "-e", "LOGGING_SERVICE_URL=http://pic-sure-logging", "-e", f"LOGGING_API_KEY={SYNTHETIC_LOGGING_KEY}",
                "-e", "JAVA_OPTS=-Xms128m -Xmx512m", "-v", f"{self.logs}:/var/log",
            ], ["sh", "-c", "java ${JAVA_OPTS} -jar /application.jar --logging.level.root=WARN"], "/auth/actuator/health",
        )
        self.start_jar(
            "gateway", self.jars["gateway"], "8080", [
                "-e", "SPRING_PROFILE=aio", "-e", "OPERATIONS_SERVICE_URL=http://operations:8080",
                "-e", "TOKEN_INTROSPECTION_URL=http://psama:8090/auth/token/inspect",
                "-e", "OPEN_ACCESS_VALIDATE_URL=http://psama:8090/auth/open/validate",
                "-e", f"TOKEN_INTROSPECTION_TOKEN={self.tokens['application']}",
                "-e", "GATEWAY_OPEN_ACCESS_ENABLED=false", "-e", "QUERY_SERVICE_INTERNAL_TOKEN=t22a-internal",
                "-e", "PICSURE_ACTUATOR_EXPOSURE=health", "-e", "PICSURE_ACTUATOR_REQUIRE_TOKEN=false",
                "-e", "LOGGING_SERVICE_URL=http://pic-sure-logging", "-e", f"LOGGING_API_KEY={SYNTHETIC_LOGGING_KEY}",
            ], ["java", "-jar", "/application.jar", "--logging.level.root=WARN"], "/actuator/health/liveness",
        )
        name = f"banner-local-{self.run_id}-frontend"
        self.docker(
            "run", "--detach", "--name", name, "--label", self.label, "--network", self.network,
            "--network-alias", "frontend", "-p", "127.0.0.1::80", "--no-healthcheck",
            "-v", f"{self.temp_root / 'generated/httpd-vhosts.conf'}:/usr/local/apache2/conf/extra/httpd-vhosts.conf:ro",
            self.images["frontend"],
        )
        self.containers["frontend"] = name
        self.urls["frontend"] = self.container_url(name, "80/tcp")
        self.wait_http(self.urls["frontend"] + "/login", "frontend")

    def start_jar(self, service, jar, port, docker_options, java_command, health_path):
        name = f"banner-local-{self.run_id}-{service}"
        aliases = ["--network-alias", service]
        if service == "logging":
            aliases.extend(["--network-alias", "pic-sure-logging"])
        self.docker(
            "run", "--detach", "--name", name, "--label", self.label, "--network", self.network,
            *aliases, "-p", f"127.0.0.1::{port}", *docker_options,
            "-v", f"{jar}:/application.jar:ro", RUNTIME_IMAGE, *java_command,
        )
        self.containers[service] = name
        self.urls[service] = self.container_url(name, f"{port}/tcp")
        self.wait_http(self.urls[service] + health_path, service)

    def container_url(self, name, port):
        mapping = self.docker("port", name, port, capture=True).stdout.strip()
        if not mapping:
            raise ProofError(f"container {name} has no host port for {port}")
        return "http://127.0.0.1:" + mapping.rsplit(":", 1)[1]

    def wait_http(self, url, service):
        deadline = time.monotonic() + 150
        last = "not attempted"
        while time.monotonic() < deadline:
            status, body = self.http("GET", url)
            if status == 200:
                return
            last = f"HTTP {status}: {body[:200]}"
            running = self.docker("inspect", "-f", "{{.State.Running}}", self.containers[service], capture=True, check=False)
            if running.returncode != 0 or running.stdout.strip() != "true":
                self.capture_logs()
                raise ProofError(f"{service} exited before readiness: {last}")
            time.sleep(1)
        self.capture_logs()
        raise ProofError(f"{service} readiness timed out: {last}")

    def http(self, method, url, payload=None, token=None):
        data = None if payload is None else json.dumps(payload).encode()
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                return response.status, response.read().decode()
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode()
        except (urllib.error.URLError, http.client.HTTPException, ConnectionError, TimeoutError) as error:
            return 0, str(error)

    def browser(self, mode):
        output = self.temp_root / f"browser-{mode}.json"
        self.docker(
            "run", "--rm", "--label", self.label, "--network", self.network,
            "-v", f"{self.temp_root}:/results", self.images["browser"], mode, f"/results/{output.name}", timeout=120,
        )
        return json.loads(output.read_text())

    def prove_path(self):
        public_url = self.urls["frontend"] + "/picsure/operations/banners/active/v2"
        status, body = self.http("GET", public_url)
        if status != 200 or json.loads(body) != []:
            raise ProofError(f"empty v2 feed drift: HTTP {status} {body}")
        self.observed["checks"]["emptyAnonymousV2Feed"] = "PASS"
        empty_browser = self.browser("empty")
        if empty_browser.get("feedCount") != 0 or empty_browser.get("regionCount") != 0:
            raise ProofError(f"empty browser observation drift: {empty_browser}")
        self.observed["checks"]["emptyBrowserRegion"] = "PASS"

        base = self.urls["frontend"] + "/picsure/operations"
        payload = {
            "htmlContent": "<p>T22A synthetic banner</p>", "title": "T22A synthetic banner",
            "appearance": "PRIMARY", "icon": "INFORMATION", "dismissible": False,
            "audience": "EVERYONE", "placement": "SITE_TOP", "pageTargets": [{"kind": "ALL"}],
            "startAt": None, "endAt": None,
        }
        status, body = self.http("POST", base + "/banners", payload, self.tokens["admin"])
        if status != 201:
            raise ProofError(f"publish through Gateway failed: HTTP {status} {body}")
        published = json.loads(body)
        banner_uuid = published.get("uuid")
        if not banner_uuid:
            raise ProofError(f"publish omitted UUID: {published}")
        self.observed["checks"]["publishThroughEdge"] = "PASS"

        draft_payload = {**payload, "title": "T22A synthetic route draft"}
        status, body = self.http("POST", base + "/banners/saved", draft_payload, self.tokens["admin"])
        if status != 201 or not json.loads(body).get("uuid"):
            raise ProofError(f"route-proof draft creation failed: HTTP {status} {body}")
        draft_uuid = json.loads(body)["uuid"]

        routes = [
            ("list", "GET", "/banners", None),
            ("create", "POST", "/banners", {}),
            ("save", "POST", "/banners/saved", {}),
            ("order", "PUT", "/banners/order", {"bannerUuids": [banner_uuid]}),
            ("update", "PUT", f"/banners/{banner_uuid}", {}),
            ("publish", "POST", f"/banners/{draft_uuid}/publish", {}),
            ("disable", "POST", f"/banners/{draft_uuid}/disable", None),
            ("archive", "POST", f"/banners/{banner_uuid}/archive", None),
            ("restore", "POST", f"/banners/{draft_uuid}/restore", {}),
        ]
        for route_name, method, path, route_payload in routes:
            anonymous = self.http(method, base + path, route_payload)[0]
            ordinary = self.http(
                method, base + path, route_payload, self.tokens["ordinary"]
            )[0]
            if anonymous != 401 or ordinary != 403:
                raise ProofError(
                    f"management denial drift for {method} {path}: "
                    f"anonymous={anonymous}, ordinary={ordinary}"
                )
            expected_statuses = expected_privileged_statuses(route_name)
            for identity in ("admin", "super"):
                allowed = self.http(
                    method, base + path, route_payload, self.tokens[identity]
                )[0]
                if allowed in {0, 401, 403, 404, 405, 502} or allowed >= 500:
                    raise ProofError(
                        f"{identity} did not reach management route {method} {path}: HTTP {allowed}"
                    )
                if allowed not in expected_statuses:
                    raise ProofError(
                        f"{identity} route result drift for {method} {path}: "
                        f"expected {sorted(expected_statuses)}, got HTTP {allowed}"
                    )
        self.observed["checks"]["managementAuthorization"] = "PASS"

        deadline = time.monotonic() + 20
        audit_text = ""
        while time.monotonic() < deadline:
            audit_logs = self.docker(
                "logs", self.containers["logging"], capture=True, check=False, timeout=30
            )
            audit_text = (audit_logs.stdout or "") + (audit_logs.stderr or "")
            if "banner.published" in audit_text and banner_uuid in audit_text:
                break
            time.sleep(0.25)
        else:
            raise ProofError("normal logging service did not record the banner.published audit event")
        if "<p>T22A synthetic banner</p>" in audit_text:
            raise ProofError("audit log contains raw banner HTML")
        self.observed["checks"]["auditReceipt"] = "PASS"

        status, body = self.http("GET", public_url)
        feed = json.loads(body) if status == 200 else None
        if not isinstance(feed, list) or len(feed) != 1 or feed[0].get("uuid") != banner_uuid:
            raise ProofError(f"published anonymous v2 feed drift: HTTP {status} {body}")
        self.observed["checks"]["publishedAnonymousV2Feed"] = "PASS"
        browser = self.browser("published")
        if browser.get("feedCount") != 1 or browser.get("regionCount") != 1:
            raise ProofError(f"published Chromium observation drift: {browser}")
        self.observed["checks"]["publishedBrowserRender"] = "PASS"
        self.observed["observations"].update(
            {
                "emptyFeedCount": 0, "emptyBannerRegionCount": 0, "managementRouteCount": len(routes),
                "publishedFeedCount": 1, "publishedBannerRegionCount": 1,
                "auditAction": "banner.published",
            }
        )
        self.observed["observations"]["runtimeArtifacts"]["publishedBannerUuid"] = banner_uuid

    def capture_logs(self):
        for service, container in self.containers.items():
            result = self.docker("logs", container, capture=True, check=False, timeout=30)
            (self.logs / f"{service}.log").write_text((result.stdout or "") + (result.stderr or ""), errors="replace")

    def write_result(self):
        self.observed["status"] = "PASS"
        path = self.temp_root / "observed-result.json"
        path.write_text(json.dumps(self.observed, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"Ticket 22A pre-cleanup result: {path}", flush=True)
        return path

    def run(self):
        phases = (
            self.verify_inputs, self.compose_owner_contracts, self.prepare_sources, self.build,
            self.start_mysql_and_migrate, self.seed_auth, self.start_services, self.prove_path,
        )
        try:
            for phase in phases:
                print(f"Ticket 22A phase: {phase.__name__}", flush=True)
                phase()
            return self.write_result()
        except Exception:
            self.capture_logs()
            (self.temp_root / "failed-result.json").write_text(
                json.dumps(self.observed, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            raise


def finalize(aio_root, result_path):
    root = Path(aio_root)
    result = json.loads(Path(result_path).read_text())
    contract = json.loads((root / "tests/banner-local-integration/contract.json").read_text())
    expected = json.loads((root / "tests/banner-local-integration/expected-result.json").read_text())
    validate_runtime_result(contract, result)
    executing_head = require_current_repository(root, "executing AIO")
    if result["sourceCommits"].get("deploymentConfig") != executing_head:
        raise ProofError(
            "runtime deploymentConfig commit does not match the exact executing AIO HEAD"
        )
    result["checks"]["cleanup"] = "PASS"
    for field in (
        "schemaVersion",
        "deployment",
        "status",
        "rolloutContractSha256",
        "images",
        "checks",
        "limitations",
        "deploymentExtensions",
    ):
        if result.get(field) != expected.get(field):
            raise ProofError(f"observed result field drift: {field}")
    for field, value in expected["sourceCommits"].items():
        if result["sourceCommits"].get(field) != value:
            raise ProofError(f"observed source commit drift for {field}")
    for field, value in expected["observations"].items():
        if result["observations"].get(field) != value:
            raise ProofError(f"observed result drift for {field}")
    validate_runtime_result(contract, result)
    Path(result_path).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(Path(result_path).read_text(), end="")
    print("AIO deployment-local banner integration PASS", flush=True)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--finalize":
        finalize(sys.argv[2], sys.argv[3])
        return
    if len(sys.argv) != 4:
        raise SystemExit("usage: run.py <aio-root> <temp-root> <run-id>")
    Harness(sys.argv[1], sys.argv[2], sys.argv[3]).run()


if __name__ == "__main__":
    main()
