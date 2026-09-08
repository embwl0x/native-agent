"use strict";

const fs = require("fs");
const { spawnSync } = require("child_process");

// Capture dependencies only; daemon evidence is observed afresh on each call.
function createCodexWakeDaemonProbe({ socketPath: SOCKET_PATH, processStartIdentity }) {
function daemonVersionsMismatch(info) {
  return Boolean(
    info &&
    typeof info.cliVersion === "string" && info.cliVersion !== "" &&
    typeof info.appServerVersion === "string" && info.appServerVersion !== "" &&
    info.cliVersion !== info.appServerVersion
  );
}

function socketOwnerPid() {
  const result = spawnSync("/usr/sbin/lsof", ["-t", SOCKET_PATH], {
    encoding: "utf8",
    timeout: 5000,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const pid = parseInt(String(result.stdout || "").trim().split("\n")[0], 10);
  return Number.isFinite(pid) && pid > 1 ? pid : null;
}

function captureAppServerIdentity() {
  const pid = socketOwnerPid();
  if (pid == null) return null;
  return {
    pid,
    startIdentity: processStartIdentity(pid),
    socketPath: SOCKET_PATH,
  };
}

function parseLsofWorkingDirectory(output) {
  let pid = null;
  let inode = null;
  let cwd = null;
  for (const line of String(output || "").split("\n")) {
    if (line.startsWith("p")) {
      const value = parseInt(line.slice(1), 10);
      if (Number.isFinite(value) && value > 1) pid = value;
    } else if (line.startsWith("i")) {
      const value = line.slice(1).trim();
      if (value) inode = value;
    } else if (line.startsWith("n")) {
      const value = line.slice(1);
      if (value) cwd = value;
    }
  }
  return { pid, inode, cwd };
}

function daemonWorkingDirectoryMismatch(observed, current) {
  if (!observed || !current) return false;
  if (!observed.inode || current.inode == null) return false;
  return String(observed.inode) !== String(current.inode);
}

/// A bridge-owned Codex daemon can outlive an app uninstall. If its cwd was
/// the NativeAgent workspace, deleting and recreating that pathname leaves the
/// process pinned to the unlinked OLD inode. `thread/start` then fails with the
/// misleading app-server error "failed to load configuration: No such file or
/// directory" even though ~/.codex/config.toml and the new workspace exist.
/// lsof exposes the process-held inode; stat exposes the pathname's current
/// inode. Comparing both catches the replacement without guessing from the
/// RPC wording or restarting a healthy daemon whose cwd is simply elsewhere.
function daemonWorkingDirectoryState() {
  const pid = socketOwnerPid();
  if (pid == null) return { status: "no_owner", mismatch: false };
  const result = spawnSync("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Ffni"], {
    encoding: "utf8",
    timeout: 5000,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (result.status !== 0) {
    return { status: "cwd_unavailable", mismatch: false, pid };
  }
  const observed = parseLsofWorkingDirectory(result.stdout);
  if (!observed.cwd) {
    return { status: "cwd_unavailable", mismatch: false, pid };
  }
  const displayedPath = observed.cwd.replace(/\s+\(deleted\)$/, "");
  let current;
  try {
    const stat = fs.statSync(displayedPath);
    current = { inode: stat.ino, cwd: displayedPath };
  } catch {
    return {
      status: "cwd_missing",
      mismatch: true,
      pid,
      cwd: displayedPath,
      observedInode: observed.inode,
    };
  }
  const mismatch = daemonWorkingDirectoryMismatch(observed, current);
  return {
    status: mismatch ? "cwd_replaced" : "ok",
    mismatch,
    pid,
    cwd: displayedPath,
    observedInode: observed.inode,
    currentInode: String(current.inode),
  };
}

return {
  daemonVersionsMismatch,
  socketOwnerPid,
  captureAppServerIdentity,
  parseLsofWorkingDirectory,
  daemonWorkingDirectoryMismatch,
  daemonWorkingDirectoryState,
};
}

module.exports = { createCodexWakeDaemonProbe };
