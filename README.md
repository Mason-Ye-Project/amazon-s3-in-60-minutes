# Amazon S3 in 60 Minutes companion

This repository supports the private, versioned S3 workflow in *Amazon S3 in 60 Minutes* by Mason Ye.

The lab creates one small bucket in `ap-southeast-2`, uploads two tiny versions of a synthetic file, tests a short-lived presigned download, demonstrates a delete marker and restore, then removes every version and the bucket.

Prerequisites: Bash, Python 3, curl, AWS CLI v2, and credentials with the required S3 permissions.

`policies/least-privilege-example.json` covers the complete lab lifecycle. Replace
`REPLACE_WITH_BUCKET_NAME` with the exact bucket name you will use before attaching
the policy, then export that same globally unique name as `LAB_BUCKET` before running
`create_lab.sh`. The scripts do not attach or change IAM policies for you.

```bash
chmod +x scripts/*.sh
python3 -m unittest discover -s tests -v
./scripts/create_lab.sh
./scripts/run_workflow.sh
./scripts/cleanup.sh
```

Safety boundaries:

- the bucket name must begin with `s3-60-lab-`;
- the bucket uses the traditional shared per-partition S3 general-purpose namespace, so its name keeps a timestamp-and-random suffix (the optional account-level bucket namespace is not used);
- Block Public Access remains enabled;
- no customer or personal data belongs in the lab;
- cleanup verifies ownership tags and removes versions plus delete markers;
- the presigned URL is short-lived and is not printed or stored as evidence;
- the entire experiment is designed to remain far below US$3.

Code is licensed under 0BSD. The book prose is not included in that license.
