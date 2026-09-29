#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

FAKE_AWS = """#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$AWS_CALLS_LOG"
args="$*"
case "$args" in
  *get-bucket-tagging*)
    case "$args" in *Project*) printf 's3-60-lab\\n' ;; esac
    case "$args" in *ManagedBy*) printf 'book-companion\\n' ;; esac
    ;;
  *delete-objects*)
    : > "$AWS_DELETED_FLAG"
    ;;
  *"{Objects:"*)
    printf '{}\\n'
    ;;
  *"DeleteMarkers ||"*)
    if [[ -f "$AWS_DELETED_FLAG" ]]; then printf '0\\n'; else printf '%s\\n' "$FAKE_MARKERS"; fi
    ;;
  *"Versions ||"*)
    if [[ -f "$AWS_DELETED_FLAG" ]]; then printf '0\\n'; else printf '%s\\n' "$FAKE_VERSIONS"; fi
    ;;
  *delete-bucket*) : ;;
  *wait*) : ;;
esac
exit 0
"""


def _run_cleanup(versions: int, markers: int) -> tuple[int, str, str]:
    """Run the real cleanup.sh against a simulated AWS CLI and report what it did.

    Returns (returncode, combined_output, calls_log). No AWS, no hashes: this is an
    ordinary offline behavioral test using a fake `aws` on PATH.
    """
    workdir = Path(tempfile.mkdtemp(prefix="s3-cleanup-test-"))
    try:
        (workdir / "scripts").mkdir()
        shutil.copy(ROOT / "scripts" / "cleanup.sh", workdir / "scripts" / "cleanup.sh")
        (workdir / ".lab-state.env").write_text(
            "LAB_BUCKET=s3-60-lab-offline-test\nAWS_REGION=ap-southeast-2\n",
            encoding="utf-8",
        )
        bindir = workdir / "bin"
        bindir.mkdir()
        fake = bindir / "aws"
        fake.write_text(FAKE_AWS, encoding="utf-8")
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

        calls_log = workdir / "aws-calls.log"
        deleted_flag = workdir / "deleted.flag"
        env = dict(os.environ)
        env["PATH"] = f"{bindir}{os.pathsep}{env.get('PATH', '')}"
        env["AWS_CALLS_LOG"] = str(calls_log)
        env["AWS_DELETED_FLAG"] = str(deleted_flag)
        env["FAKE_VERSIONS"] = str(versions)
        env["FAKE_MARKERS"] = str(markers)

        completed = subprocess.run(
            ["bash", str(workdir / "scripts" / "cleanup.sh")],
            env=env,
            capture_output=True,
            text=True,
        )
        log_text = calls_log.read_text(encoding="utf-8") if calls_log.is_file() else ""
        return completed.returncode, completed.stdout + completed.stderr, log_text
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


class CompanionTests(unittest.TestCase):
    def test_shell_syntax(self) -> None:
        for script in sorted((ROOT / "scripts").glob("*.sh")):
            subprocess.run(["bash", "-n", str(script)], check=True)

    def test_policy_is_valid_and_private(self) -> None:
        policy = json.loads(
            (ROOT / "policies/least-privilege-example.json").read_text()
        )
        self.assertEqual(policy["Version"], "2012-10-17")
        actions = {
            action
            for statement in policy["Statement"]
            for action in statement["Action"]
        }
        self.assertIn("s3:GetObject", actions)
        self.assertIn("s3:ListBucketVersions", actions)
        required_lab_actions = {
            "s3:CreateBucket",
            "s3:DeleteBucket",
            "s3:GetBucketTagging",
            "s3:PutBucketOwnershipControls",
            "s3:PutBucketPublicAccessBlock",
            "s3:PutBucketTagging",
            "s3:PutBucketVersioning",
            "s3:PutEncryptionConfiguration",
            "s3:DeleteObjectVersion",
        }
        self.assertTrue(required_lab_actions.issubset(actions))
        self.assertNotIn("s3:*", actions)

    def test_cleanup_has_ownership_and_version_guards(self) -> None:
        cleanup = (ROOT / "scripts/cleanup.sh").read_text()
        self.assertIn("s3-60-lab", cleanup)
        self.assertIn("book-companion", cleanup)
        self.assertIn("DeleteMarkers", cleanup)
        self.assertIn("wait bucket-not-exists", cleanup)

    def test_public_access_is_blocked(self) -> None:
        create = (ROOT / "scripts/create_lab.sh").read_text()
        self.assertIn('"BlockPublicAcls": true', create)
        self.assertIn('"BlockPublicPolicy": true', create)
        self.assertIn('"RestrictPublicBuckets": true', create)
        self.assertNotIn("public-read", create)

    def test_workflow_uses_simple_semantic_checks(self) -> None:
        workflow = (ROOT / "scripts/run_workflow.sh").read_text()
        self.assertIn("grep -Fxq", workflow)

    def test_workflow_honors_versioning_allowance(self) -> None:
        create = (ROOT / "scripts/create_lab.sh").read_text()
        workflow = (ROOT / "scripts/run_workflow.sh").read_text()
        self.assertIn("LAB_VERSIONING_READY_AT", create)
        self.assertIn("LAB_VERSIONING_READY_AT", workflow)

    def test_cleanup_preflight_refuses_before_deleting_versions_or_markers(self) -> None:
        # Audit case: 2 object versions + 101 delete markers must be refused in the
        # preflight, with nothing deleted first.
        code, output, log = _run_cleanup(versions=2, markers=101)
        self.assertNotEqual(code, 0, "cleanup should refuse an oversized plan")
        self.assertNotIn("delete-objects", log, "no deletion may occur before refusal")
        self.assertNotIn("delete-bucket", log, "the bucket must not be deleted on refusal")
        self.assertIn("Nothing was deleted", output)

    def test_cleanup_preflight_refuses_combined_over_limit(self) -> None:
        # Audit case: 60 versions + 60 markers (120 combined) must be refused, not
        # silently deleted and reported as success.
        code, output, log = _run_cleanup(versions=60, markers=60)
        self.assertNotEqual(code, 0, "cleanup should refuse when the combined total exceeds 100")
        self.assertNotIn("delete-objects", log, "no deletion may occur before refusal")
        self.assertNotIn("delete-bucket", log)
        self.assertNotIn("PASS", output)

    def test_cleanup_happy_path_small_inventory(self) -> None:
        # A small, in-limit inventory should proceed: delete versions and markers,
        # confirm empty, delete the bucket, and report success.
        code, output, log = _run_cleanup(versions=2, markers=1)
        self.assertEqual(code, 0, output)
        self.assertIn("delete-objects", log)
        self.assertIn("delete-bucket", log)
        self.assertIn("PASS", output)


if __name__ == "__main__":
    unittest.main()
