const DISPLAY_ERROR_MESSAGES = Object.freeze({
  body_deadline: "the request body did not arrive before its deadline",
  body_too_large: "the request body exceeded the server limit",
  command_missing: "a required dashboard command is unavailable",
  command_error: "a dashboard command could not be started",
  credentials_unavailable: "the dashboard credentials could not be read",
  dashboard_read_failed: "a dashboard data source could not be read",
  event_store_unavailable: "the activity store could not be opened",
  exit_nonzero: "a dashboard data source reported a failure",
  gbrain_local_source_failed: "this home's knowledge corpus could not be read",
  gbrain_main_source_failed: "the shared knowledge corpus could not be read",
  gbrain_source_failed: "a knowledge corpus could not be read",
  gbrain_health_unavailable: "GBrain health could not be read",
  history_refresh_failed: "the completion history could not be read",
  http_error: "the dashboard server did not answer successfully",
  malformed_json: "a dashboard data source returned unreadable data",
  no_corpus_answered: "no configured corpus answered the search",
  output_too_large: "a dashboard data source returned too much data",
  query_too_large: "the search query exceeded the server limit",
  query_too_short: "the search query was too short",
  search_busy: "another semantic search is already running",
  search_failed: "the semantic search could not be answered",
  search_setup_failed: "the semantic search could not be started",
  server_unreachable: "the dashboard server could not be reached",
  service_unit_outdated: "the installed dashboard service is out of date; rerun bin/fm-dashboard-install.sh",
  snapshot_failed: "the fleet snapshot could not be read",
  store_write_failed: "the activity event could not be stored",
  timed_out: "a dashboard data source did not answer before its deadline",
  unsupported_envelope: "the dashboard returned an unsupported response",
  unsupported_schema: "a dashboard data source returned an unsupported format",
});

function normalizedKind(error, fallback) {
  const candidate = typeof error === "object" && error !== null ? error.kind : null;
  return typeof candidate === "string" && /^[a-z0-9_]+$/.test(candidate) ? candidate : fallback;
}

// The one funnel raw error text passes through on its way to a reader: what
// comes back carries a display-safe sentence for the kind, and the raw message
// and stderr on a NON-ENUMERABLE `diagnostic`. Non-enumerable is the whole
// mechanism - JSON.stringify skips it, so the record can be published as an
// envelope without the raw text crossing into the browser, while anything
// server-side still has it. bin/fm-dashboard-server.mjs's errorRecord() is that
// sink: it logs the diagnostic so an operator can read why a source failed.
export function displayError(error, fallback = "dashboard_read_failed", fields = {}) {
  const kind = normalizedKind(error, fallback);
  const record = { kind, message: DISPLAY_ERROR_MESSAGES[kind] || DISPLAY_ERROR_MESSAGES.dashboard_read_failed, ...fields };
  Object.defineProperty(record, "diagnostic", {
    value: {
      message: typeof error?.message === "string" ? error.message : null,
      stderr: typeof error?.stderr === "string" ? error.stderr : null,
    },
    enumerable: false,
  });
  return record;
}

export function displaySafeEnvelope(envelope, fallback = "dashboard_read_failed") {
  if (!envelope || typeof envelope !== "object" || !envelope.status?.error) return envelope;
  return {
    ...envelope,
    status: {
      ...envelope.status,
      error: displayError(envelope.status.error, fallback),
    },
  };
}
