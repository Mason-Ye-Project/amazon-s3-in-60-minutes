#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


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
        self.assertIn("BlockPublicAcls=true", create)
        self.assertIn("BlockPublicPolicy=true", create)
        self.assertNotIn("public-read", create)

    def test_workflow_uses_simple_semantic_checks(self) -> None:
        workflow = (ROOT / "scripts/run_workflow.sh").read_text()
        self.assertIn("grep -Fxq", workflow)


if __name__ == "__main__":
    unittest.main()
