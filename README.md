# sentry.sdk

Rust-powered Sentry SDK bindings for R.

This package provides a small R interface for initializing Sentry, capturing messages, forwarding `lgr` logs, and tracing `plumber` requests or explicit code blocks.

## Installation

The package builds native Rust code, so the build environment needs Cargo, `rustc`, and `xz`.

Install the current pinned revision:

```r
remotes::install_github("finccam/sentry-sdk-r@ba7ace15a594761c0a0b2606ffdb3e26f8bc2f25")
```

## Initialize Sentry

Initialize the global Sentry client once during application startup. A missing or empty DSN should usually disable Sentry explicitly in the consuming application instead of calling `sentry_initialize()`.

```r
library(sentry.sdk)

sentry_initialize(
  dsn = Sys.getenv("SENTRY_DSN"),
  environment = Sys.getenv("SENTRY_ENVIRONMENT"),
  release = Sys.getenv("SENTRY_RELEASE"),
  traces_sample_rate = 1,
  enable_logs = TRUE
)
```

`environment` and `release` can be `NULL` if they are not configured.

```r
sentry_initialize(
  dsn = Sys.getenv("SENTRY_DSN"),
  environment = if (nzchar(Sys.getenv("SENTRY_ENVIRONMENT"))) Sys.getenv("SENTRY_ENVIRONMENT") else NULL,
  release = if (nzchar(Sys.getenv("SENTRY_RELEASE"))) Sys.getenv("SENTRY_RELEASE") else NULL,
  traces_sample_rate = 1,
  enable_logs = TRUE
)
```

## Capture Messages

Use `sentry_capture_message()` for explicit events.

```r
sentry_capture_message("Portfolio import started", "info")
sentry_capture_message("Portfolio import failed", "error")
```

Supported levels are `debug`, `info`, `warning` or `warn`, `error`, and `fatal`. Unknown levels are sent as `info`.

## Forward lgr Logs

Set `enable_logs = TRUE` during initialization, then attach the Sentry appender to an `lgr` logger.

```r
logger <- lgr::get_logger()
sentry_attach_lgr(logger)

logger$info("PM container started")
logger$error("PM container request failed")
```

If `lgr` is not installed, `sentry_attach_lgr()` returns `FALSE` invisibly.

## Instrument plumber

Call `sentry_plumber_instrument()` from a plumber router hook before the API starts serving requests.

```r
#* @plumber
function(pr) {
  sentry.sdk::sentry_plumber_instrument(pr)
}
```

The instrumentation creates a Sentry transaction per request, continues an inbound `sentry-trace` header when present, captures handler errors, and flushes pending envelopes after each request.

The default transaction name is `METHOD PATH`. Override it with `transaction_namer` if the application needs route-based names.

```r
sentry_plumber_instrument(
  pr,
  transaction_namer = function(req) paste(req$REQUEST_METHOD, req$PATH_INFO)
)
```

## Manual Transactions and Spans

Wrap code in a Sentry transaction when it is not already covered by plumber instrumentation.

```r
result <- with_sentry_transaction("daily-risk-run", "job", {
  run_daily_risk()
})
```

Use `with_sentry_span()` for child work inside a transaction.

```r
result <- with_sentry_transaction("daily-risk-run", "job", {
  with_sentry_span(tx, "db.query", "Load portfolio data", {
    load_portfolio_data()
  })
})
```

The transaction object is available inside `with_sentry_transaction()` as `tx`.

## Consumer Startup Example

For an application that should run without Sentry when the package or DSN is unavailable:

```r
initialize_sentry <- function() {
  if (!requireNamespace("sentry.sdk", quietly = TRUE)) {
    return(invisible(FALSE))
  }

  sentry_dsn <- Sys.getenv("SENTRY_DSN")
  if (!nzchar(sentry_dsn)) {
    return(invisible(FALSE))
  }

  sentry.sdk::sentry_initialize(
    dsn = sentry_dsn,
    environment = if (nzchar(Sys.getenv("SENTRY_ENVIRONMENT"))) Sys.getenv("SENTRY_ENVIRONMENT") else NULL,
    release = if (nzchar(Sys.getenv("SENTRY_RELEASE"))) Sys.getenv("SENTRY_RELEASE") else NULL,
    traces_sample_rate = 1,
    enable_logs = TRUE
  )
  sentry.sdk::sentry_attach_lgr(lgr::get_logger())

  invisible(TRUE)
}
```

## Runtime Environment

Common application variables:

- `SENTRY_DSN`: Sentry project DSN. Required to enable Sentry.
- `SENTRY_ENVIRONMENT`: Optional environment name, for example `dev`, `staging`, or `production`.
- `SENTRY_RELEASE`: Optional release identifier for grouping events by deployed version.
