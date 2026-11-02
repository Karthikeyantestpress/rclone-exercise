"""Call rclone from Python (e.g. inside a Celery task) without an rclone.conf.

Credentials are passed to the child process through its environment only:
they never appear in argv (visible to every user via `ps`), in a config file
on disk, or in log output. rclone's JSON log gives machine-readable stats.

    python3 examples/python/run_rclone.py data/source/pdfs :s3:python-demo/pdfs

Expects S3_A_ENDPOINT / S3_A_ACCESS_KEY / S3_A_SECRET_KEY in the environment
(in production these would come from a secrets manager, not a .env file).
"""

import json
import os
import subprocess
import sys


class TransferError(Exception):
    def __init__(self, returncode, errors):
        super().__init__(f"rclone exited with {returncode}: {errors[-1] if errors else 'no error message'}")
        self.returncode = returncode
        self.errors = errors


def s3_env(endpoint, access_key, secret_key):
    """Environment that defines the on-the-fly ':s3:' remote."""
    return {
        "RCLONE_CONFIG": "",  # in-memory config: never read or write a file
        "RCLONE_S3_PROVIDER": "Other",
        "RCLONE_S3_ENDPOINT": endpoint,
        "RCLONE_S3_ACCESS_KEY_ID": access_key,
        "RCLONE_S3_SECRET_ACCESS_KEY": secret_key,
    }


def rclone_copy(src, dst, env, transfers=4, timeout=3600):
    """Run `rclone copy` and return the final transfer stats as a dict.

    Raises TransferError on a non-zero exit, so a Celery task can decide to
    retry (rclone exit code 5 = temporary error) or fail permanently.
    """
    cmd = [
        "rclone", "copy", src, dst,
        "--transfers", str(transfers),
        "--retries", "3", "--low-level-retries", "10",
        "--use-json-log", "--log-level", "INFO",
        # a long interval means no periodic stats, just the final record on exit
        "--stats", "1h", "--stats-log-level", "NOTICE",
    ]
    # Inherit PATH etc., add the S3 settings. Only this child process sees them.
    child_env = {**os.environ, **env}
    proc = subprocess.run(cmd, env=child_env, capture_output=True, text=True, timeout=timeout)

    stats, errors = {}, []
    for line in proc.stderr.splitlines():  # rclone logs to stderr, one JSON object per line
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "stats" in record:
            stats = record["stats"]
        if record.get("level") in ("error", "critical"):
            errors.append(record.get("msg", ""))

    if proc.returncode != 0:
        raise TransferError(proc.returncode, errors)
    return stats


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    env = s3_env(os.environ["S3_A_ENDPOINT"], os.environ["S3_A_ACCESS_KEY"], os.environ["S3_A_SECRET_KEY"])
    try:
        stats = rclone_copy(src, dst, env)
    except TransferError as exc:
        print(f"transfer failed: {exc}", file=sys.stderr)
        sys.exit(exc.returncode)
    print(json.dumps({k: stats.get(k) for k in ("bytes", "transfers", "checks", "errors", "elapsedTime")}))
