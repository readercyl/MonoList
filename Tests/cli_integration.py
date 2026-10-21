"""Exercise the built development app and its real IPC in an isolated directory."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

root = Path(__file__).resolve().parents[1]
binary = root / "build/local/MonoList 开发版.app/Contents/MacOS/MonoList"
with tempfile.TemporaryDirectory(prefix="monolist-cli-integration-") as directory:
    env = dict(os.environ, MONOLIST_CLI_TEST_DIRECTORY=directory)
    Path(directory, "settings.json").write_text(json.dumps({"schemaVersion": 1, "values": {
        "reminderEnabled": False, "reminderSoundEnabled": False, "automaticUpdatesEnabled": False}}))
    process = subprocess.Popen([str(binary)], env=env, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
    def call(command, payload=None, ok=True):
        result = subprocess.run([str(binary), "--cli", command], env=env,
            input=json.dumps(payload or {}).encode(), capture_output=True, timeout=30)
        response = json.loads(result.stdout)
        assert response["ok"] == ok, (command, response)
        assert (result.returncode == 0) == ok, command
        return response.get("result", response)
    try:
        for _ in range(80):
            probe = subprocess.run([str(binary), "--cli", "status"], env=env,
                capture_output=True, timeout=3)
            if probe.returncode == 0:
                break
            assert process.poll() is None, "isolated app exited before startup"
            time.sleep(0.1)
        else:
            raise AssertionError("isolated CLI startup timed out")
        assert call("status")["development"] is True
        assert call("list")["tasks"] == []
        parent, child = str(uuid.uuid4()), str(uuid.uuid4())
        snapshot = call("list")
        snapshot = call("apply", {"expectedRevision": snapshot["revision"], "operations": [
            {"kind": "add", "id": parent, "text": "Synthetic parent"},
            {"kind": "add", "id": child, "text": "Synthetic child", "parentID": parent}]})
        assert len(snapshot["tasks"]) == 2
        call("apply", {"expectedRevision": snapshot["revision"], "operations": [
            {"kind": "edit", "id": child, "text": "Synthetic revised child"}]})
        call("apply", {"expectedRevision": snapshot["revision"], "operations": [
            {"kind": "edit", "id": child, "text": "stale"}]}, ok=False)
        assert call("list")["tasks"][1]["text"] == "Synthetic revised child"
        call("apply", {"expectedRevision": call("list")["revision"], "operations": [
            {"kind": "delete", "id": parent}]}, ok=False)
        call("view.set", {"collapsedIDs": [parent], "homeHistory": False, "panelHistory": True})
        view = call("view.get")
        assert view["collapsedIDs"] == [parent.upper()]
        assert not view["homeHistory"] and view["panelHistory"]
        settings = call("settings.get")
        updated = call("settings.set", {"expectedRevision": settings["revision"], "values": {
            "reminderIntervalMinutes": 90, "reminderStartMinuteOfDay": 600,
            "reminderEndMinuteOfDay": 1200, "reminderPosition": "topRight",
            "reminderSoundName": "Glass", "automaticUpdatesEnabled": False}})
        assert updated["values"]["reminderIntervalMinutes"] == 90
        call("settings.set", {"expectedRevision": settings["revision"],
                              "values": {"reminderEnabled": True}}, ok=False)
        call("settings.set", {"expectedRevision": updated["revision"],
                              "values": {"reminderIntervalMinutes": 17}}, ok=False)
        assert call("settings.get")["revision"] == updated["revision"]
        call("login.set", {"enabled": True, "confirm": True}, ok=False)
        call("update.install", {"confirm": True}, ok=False)
        call("update.status")
        for command in ["window.home", "window.settings", "window.panel", "window.hide",
                        "reminder.test", "reminder.close", "data.retry-save"]:
            call(command)
        call("data.retry-load", {"confirm": True}, ok=False)
        call("view.set", {"collapsedIDs": [], "homeHistory": "invalid"}, ok=False)
        assert call("view.get")["collapsedIDs"] == [parent.upper()]
        call("unknown", {}, ok=False)
        malformed = subprocess.run([str(binary), "--cli", "apply"], env=env,
            input=b"not-json", capture_output=True, timeout=5)
        assert malformed.returncode == 1 and not json.loads(malformed.stdout)["ok"]
        too_large = subprocess.run([str(binary), "--cli", "apply"], env=env,
            input=b"x" * (1_048_576 + 1), capture_output=True, timeout=5)
        assert too_large.returncode == 1 and not json.loads(too_large.stdout)["ok"]
        call("app.quit", {}, ok=False)
        call("app.quit", {"confirm": True})
        process.wait(timeout=10)
        call("status", ok=False)
        assert Path(directory, "tasks.cli-backup.json").exists()
        assert Path(directory, "settings.cli-backup.json").exists()
        assert Path(directory, "tasks.cli-backup.json").stat().st_mode & 0o777 == 0o600
        assert Path(directory, "settings.cli-backup.json").stat().st_mode & 0o777 == 0o600
        print("CLI integration passed: isolated app, IPC, task/settings conflicts, view/window/reminder commands, development guards.")
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
