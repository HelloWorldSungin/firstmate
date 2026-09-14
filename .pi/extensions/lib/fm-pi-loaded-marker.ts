import { readFileSync } from "node:fs";

// Writer rule for the Pi primary extensions' loaded-generation markers
// (state/.pi-watch-extension-loaded and state/.pi-turnend-extension-loaded).
// bin/fm-wake-lib.sh fm_pi_extension_loaded owns what a marker proves: the
// build it names was loaded by exactly the process recorded in state/.lock.
//
// So a marker may be recorded only by that process itself, or while no live
// process holds the lock yet (a fresh or dead lock, which the session that
// takes it next rewrites from its own session_start or arm). A live descendant
// of the lock holder - such as a `pi --list-models` probe the primary runs from
// its bash tool, which loads the same extension factories from disk - can never
// satisfy the proof, so it must never overwrite the holder's evidence with a
// newer build hash and its own pid. Callers also write only from a started
// session, never from factory load, because such a probe never starts one.
export function markerWriterMayRecord(lockFile: string): boolean {
  let lockPid = "";
  try {
    lockPid = readFileSync(lockFile, "utf8").trim();
  } catch {
    return true;
  }
  if (lockPid === String(process.pid)) return true;
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return false;
  try {
    process.kill(Number(lockPid), 0);
    return false;
  } catch (error) {
    return (error as { code?: unknown }).code === "ESRCH";
  }
}
