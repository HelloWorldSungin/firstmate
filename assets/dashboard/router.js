// router.js - the hash router for the fleet dashboard.
//
// Five primary destinations plus a task detail route:
//   #/needs  #/fleet  #/backlog  #/history  #/knowledge  #/task/<id>
//
// The contract this module owns: a route resolves to EXACTLY ONE view.
// activeViews() exists so a test can assert the others are absent, because a
// page that renders every section and scrolls between them would pass every
// "the active view is present" check ever written. The original dashboard had
// exactly that shape, which is why the router is a module with its own tests
// rather than four lines at the top of app.js.
//
// Unknown or malformed hashes resolve to the Needs you view, never to a blank
// page: an operator's stale bookmark must land somewhere real.

export const VIEWS = ["needs", "fleet", "backlog", "history", "knowledge"];
export const DEFAULT_VIEW = "needs";
export const TASK_VIEW = "task";

const TASK_PATTERN = /^#\/task\/([A-Za-z0-9][A-Za-z0-9._-]*)$/;

/** The route object for a view destination, or null for anything else. */
export function viewRoute(view) {
  return VIEWS.includes(view) ? { view } : null;
}

/** The route object for a task detail destination. */
export function taskRoute(taskId) {
  const id = typeof taskId === "string" ? taskId : "";
  return TASK_PATTERN.test(`#/task/${id}`) ? { view: TASK_VIEW, taskId: id } : null;
}

/**
 * Parse a location hash into exactly one route.
 * Returns { view, taskId? } - always, including for "", "#", "#/", garbage,
 * and legacy "#inbox"-style section hashes, which all resolve to Needs you.
 */
export function parseHash(hash) {
  const raw = typeof hash === "string" ? hash : "";
  const match = TASK_PATTERN.exec(raw);
  if (match) return { view: TASK_VIEW, taskId: match[1] };
  const view = raw.replace(/^#\/?/, "").split(/[/?]/)[0];
  return viewRoute(view) || { view: DEFAULT_VIEW };
}

/** The canonical hash for a route, so links and history entries stay stable. */
export function hashFor(route) {
  if (!route || typeof route !== "object") return `#/${DEFAULT_VIEW}`;
  if (route.view === TASK_VIEW) return `#/task/${route.taskId || ""}`;
  return `#/${viewRoute(route.view)?.view || DEFAULT_VIEW}`;
}

/**
 * The complete set of views a route renders: the active one, and nothing else.
 * This is the mutual-exclusivity contract. It includes the task view, so a
 * caller can check every view name it knows against one return value.
 */
export function activeViews(route) {
  const parsed = typeof route === "string" ? parseHash(route) : route;
  const view = parsed?.view === TASK_VIEW ? TASK_VIEW : viewRoute(parsed?.view)?.view;
  return [view || DEFAULT_VIEW];
}

/** Every view that must NOT be on the page for this route. */
export function inactiveViews(route) {
  const active = activeViews(route)[0];
  return [...VIEWS, TASK_VIEW].filter((view) => view !== active);
}
