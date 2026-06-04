use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use extendr_api::prelude::*;
use sentry::{ClientInitGuard, ClientOptions, Level, TransactionContext, TransactionOrSpan};

static SENTRY_GUARD: OnceLock<Mutex<Option<ClientInitGuard>>> = OnceLock::new();

#[extendr]
#[derive(Clone)]
struct SentrySpan(TransactionOrSpan);

fn sentry_guard() -> &'static Mutex<Option<ClientInitGuard>> {
    SENTRY_GUARD.get_or_init(|| Mutex::new(None))
}

fn parse_level(level: &str) -> Level {
    match level.to_ascii_lowercase().as_str() {
        "debug" => Level::Debug,
        "info" => Level::Info,
        "warning" | "warn" => Level::Warning,
        "error" => Level::Error,
        "fatal" => Level::Fatal,
        _ => Level::Info,
    }
}

/// Initialize the global Sentry client.
#[extendr]
fn sentry_init(
    dsn: &str,
    environment: Option<String>,
    release: Option<String>,
    debug: bool,
    shutdown_timeout_ms: i32,
    traces_sample_rate: f64,
) -> bool {
    let mut options = ClientOptions::default();
    options.environment = environment.map(Into::into);
    options.release = release.map(Into::into);
    options.debug = debug;
    options.shutdown_timeout = Duration::from_millis(shutdown_timeout_ms.max(0) as u64);
    options.traces_sample_rate = traces_sample_rate as f32;

    let mut guard_slot = sentry_guard().lock().unwrap();
    if let Some(guard) = guard_slot.take() {
        guard.close(None);
    }

    let guard = sentry::init((dsn, options));
    let enabled = guard.is_enabled();
    *guard_slot = Some(guard);
    enabled
}

/// Report whether the global Sentry client is enabled.
#[extendr]
fn sentry_enabled() -> bool {
    sentry_guard()
        .lock()
        .unwrap()
        .as_ref()
        .map(ClientInitGuard::is_enabled)
        .unwrap_or(false)
}

/// Capture a Sentry message at the requested level.
/// @export
#[extendr]
fn sentry_capture_message(message: &str, level: &str) -> String {
    sentry::capture_message(message, parse_level(level)).to_string()
}

/// Flush pending Sentry envelopes.
#[extendr]
fn sentry_flush(timeout_ms: Option<i32>) -> bool {
    let timeout = timeout_ms.map(|ms| Duration::from_millis(ms.max(0) as u64));
    sentry_guard()
        .lock()
        .unwrap()
        .as_ref()
        .map(|guard| guard.flush(timeout))
        .unwrap_or(false)
}

/// Close the global Sentry client.
#[extendr]
fn sentry_close(timeout_ms: Option<i32>) -> bool {
    let timeout = timeout_ms.map(|ms| Duration::from_millis(ms.max(0) as u64));
    let mut guard_slot = sentry_guard().lock().unwrap();
    guard_slot
        .take()
        .map(|guard| guard.close(timeout))
        .unwrap_or(false)
}

/// Start a transaction, optionally continuing an inbound `sentry-trace` header.
#[extendr]
fn sentry_transaction_start(name: &str, op: &str, sentry_trace: Option<String>) -> SentrySpan {
    let ctx = match sentry_trace.as_deref().filter(|trace| !trace.is_empty()) {
        Some(trace) => TransactionContext::continue_from_headers(name, op, [("sentry-trace", trace)]),
        None => TransactionContext::new(name, op),
    };

    SentrySpan(sentry::start_transaction(ctx).into())
}

/// Start a child span from an existing transaction or span.
#[extendr]
fn sentry_span_start_child(parent: &SentrySpan, op: &str, description: &str) -> SentrySpan {
    SentrySpan(parent.0.start_child(op, description).into())
}

/// Set the active span on the current Sentry scope.
#[extendr]
fn sentry_set_current_span(span: &SentrySpan) {
    sentry::configure_scope(|scope| scope.set_span(Some(span.0.clone())));
}

/// Clear the active span from the current Sentry scope.
#[extendr]
fn sentry_clear_current_span() {
    sentry::configure_scope(|scope| scope.set_span(None));
}

/// Finish a transaction or span.
#[extendr]
fn sentry_span_finish(span: &SentrySpan) {
    match span.0.clone() {
        TransactionOrSpan::Transaction(transaction) => transaction.finish(),
        TransactionOrSpan::Span(child_span) => child_span.finish(),
    }
}

extendr_module! {
    mod sentry_sdk;
    fn sentry_init;
    fn sentry_enabled;
    fn sentry_capture_message;
    fn sentry_flush;
    fn sentry_close;
    fn sentry_transaction_start;
    fn sentry_span_start_child;
    fn sentry_set_current_span;
    fn sentry_clear_current_span;
    fn sentry_span_finish;
}
