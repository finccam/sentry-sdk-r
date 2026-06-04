#' Initialize the global Sentry client.
#' @export
sentry_initialize <- function(
  dsn,
  environment = NULL,
  release = NULL,
  debug = FALSE,
  shutdown_timeout_ms = 2000L,
  traces_sample_rate = 1
) {
  sentry_init(
    dsn = dsn,
    environment = environment,
    release = release,
    debug = debug,
    shutdown_timeout_ms = as.integer(shutdown_timeout_ms),
    traces_sample_rate = as.numeric(traces_sample_rate)
  )
}

#' Run code inside a Sentry transaction.
#' @export
with_sentry_transaction <- function(name, op, code, sentry_trace = NULL) {
  expr <- substitute(code)
  tx <- sentry_transaction_start(name = name, op = op, sentry_trace = sentry_trace)
  sentry_set_current_span(tx)

  on.exit({
    sentry_clear_current_span()
    sentry_span_finish(tx)
    sentry_flush(2000L)
  }, add = TRUE)

  tryCatch(
    eval.parent(expr),
    error = function(e) {
      sentry_capture_message(conditionMessage(e), "error")
      stop(e)
    }
  )
}

#' Run code inside a child Sentry span.
#' @export
with_sentry_span <- function(parent, op, description, code) {
  expr <- substitute(code)
  span <- sentry_span_start_child(parent = parent, op = op, description = description)
  sentry_set_current_span(span)

  on.exit({
    sentry_set_current_span(parent)
    sentry_span_finish(span)
  }, add = TRUE)

  eval.parent(expr)
}
