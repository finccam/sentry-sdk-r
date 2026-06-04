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

sentry_plumber_default_transaction_name <- function(req) {
  paste(req$REQUEST_METHOD, req$PATH_INFO)
}

sentry_plumber_state <- function(req) {
  if (is.null(req$.internal$sentrySdkState)) {
    req$.internal$sentrySdkState <- new.env(parent = emptyenv())
  }

  req$.internal$sentrySdkState
}

sentry_plumber_finalize <- function(req, flush_timeout_ms) {
  if (is.null(req$.internal)) {
    return(invisible(FALSE))
  }

  state <- sentry_plumber_state(req)
  if (isTRUE(state$finished) || is.null(state$transaction)) {
    return(invisible(FALSE))
  }

  state$finished <- TRUE
  sentry_clear_current_span()
  sentry_span_finish(state$transaction)
  sentry_flush(flush_timeout_ms)
  invisible(TRUE)
}

sentry_plumber_default_error_handler <- function(req, res, error) {
  print(error)

  res$serializer <- plumber::serializer_unboxed_json()

  if (res$status == 200L) {
    res$status <- 500L
    payload <- list(error = "500 - Internal server error")
  } else {
    payload <- list(error = "Internal error")
  }

  if (is.function(req$pr$getDebug) && isTRUE(req$pr$getDebug())) {
    payload$message <- as.character(error)
  }

  payload
}

#' Instrument a plumber router with Sentry request tracing.
#' @export
sentry_plumber_instrument <- function(
  pr,
  transaction_namer = NULL,
  flush_timeout_ms = 2000L,
  error_handler = NULL
) {
  if (!requireNamespace("plumber", quietly = TRUE)) {
    stop("Package 'plumber' must be installed to instrument plumber routers.")
  }

  if (is.null(transaction_namer)) {
    transaction_namer <- sentry_plumber_default_transaction_name
  }
  if (is.null(error_handler)) {
    error_handler <- sentry_plumber_default_error_handler
  }

  flush_timeout_ms <- as.integer(flush_timeout_ms)

  plumber::pr_hook(pr, "preroute", function(data, req, res) {
    if (!sentry_enabled()) {
      return(invisible(NULL))
    }

    state <- sentry_plumber_state(req)
    state$finished <- FALSE
    transaction_name <- tryCatch(
      transaction_namer(req),
      error = function(error) sentry_plumber_default_transaction_name(req)
    )
    if (!is.character(transaction_name) || length(transaction_name) != 1 || !nzchar(transaction_name)) {
      transaction_name <- sentry_plumber_default_transaction_name(req)
    }

    state$transaction <- sentry_transaction_start(
      name = transaction_name,
      op = "http.server",
      sentry_trace = req$HTTP_SENTRY_TRACE
    )
    sentry_set_current_span(state$transaction)
    invisible(NULL)
  })

  plumber::pr_hook(pr, "postserialize", function(data, req, res, value) {
    if (sentry_enabled()) {
      sentry_plumber_finalize(req, flush_timeout_ms)
    }

    value
  })

  plumber::pr_set_error(pr, function(req, res, error) {
    if (sentry_enabled()) {
      sentry_capture_message(
        paste(req$REQUEST_METHOD, req$PATH_INFO, conditionMessage(error), sep = " "),
        "error"
      )
      sentry_plumber_finalize(req, flush_timeout_ms)
    }

    error_handler(req, res, error)
  })

  pr
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
