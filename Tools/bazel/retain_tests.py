"""Copy test reports referenced by a Bazel event file onto durable storage."""

import json
from pathlib import Path
import shutil
import sys
from urllib.parse import unquote, urlparse


def retain(events_path):
    """Preserve each attempt and its label; never overwrite an earlier attempt."""
    destination = events_path.with_suffix(".tests")
    reports = []
    for line in events_path.read_text().splitlines():
        event = json.loads(line)
        result = event.get("testResult")
        if result is None:
            continue
        record = {"id": event["id"], "status": result["status"], "files": []}
        for output in result.get("testActionOutput", []):
            uri = urlparse(output.get("uri", ""))
            if uri.scheme != "file":
                continue
            source = Path(unquote(uri.path))
            target = destination / str(len(reports)) / source.name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            record["files"].append(str(target.relative_to(destination)))
        reports.append(record)
    destination.mkdir(exist_ok=True)
    (destination / "index.json").write_text(json.dumps(reports, indent=2) + "\n")


if __name__ == "__main__":
    retain(Path(sys.argv[1]))
