// display.js - the one place the dashboard turns record values into labels.
//
// The durable records carry host filesystem values: a task's project is
// registered as a clone path, a worktree is a .treehouse pool path, a report
// records where it was retained. None of that belongs on a read-only page a
// browser might show on a wall or a screenshot. The convention is this module:
// every value that reaches the DOM as a name passes through label(), and paths
// that carry no name of their own never render at all.
//
// label() keeps the final path segment of a path-shaped value (the clone's
// repo name), because that segment IS the project's display name in every
// registry this fleet uses. It is not a redaction layer bolted on top of a
// leaky renderer: it is the definition of what a project label is.

/** True when a value carries a filesystem path rather than a bare name. */
export function isPathish(value) {
  return typeof value === "string" && value.includes("/");
}

/**
 * The display label for a value that is sometimes a path and sometimes a name:
 * "/home/x/projects/firstmate" -> "firstmate", "firstmate" -> "firstmate",
 * null -> null. A trailing slash contributes nothing and is dropped.
 */
export function label(value) {
  if (typeof value !== "string" || value === "") return null;
  const trimmed = value.replace(/\/+$/, "");
  const cut = trimmed.lastIndexOf("/");
  return (cut === -1 ? trimmed : trimmed.slice(cut + 1)) || null;
}

/**
 * A path-shaped value reduced to its final segment for a compact line like a
 * GBrain index note, where the segment is the informative part: the index at
 * ".../data/gbrain/pglite" is "pglite". Non-path values pass through label().
 */
export function pathTail(value) {
  return label(value);
}
