use spacetimedb::{table, reducer, ReducerContext, Table, TimeDuration};

// G1/G2: overlapping-subscription refcount + unsubscribe prune.
#[table(accessor = thing, public)]
pub struct Thing { #[primary_key] pub id: u64, pub label: String }

// G3: event table — rows must fire on_insert but never be stored.
#[table(accessor = event_log, public, event)]
pub struct EventLog { pub msg: String }

// TimeDuration column (exposed as int micros client-side).
#[table(accessor = dur_row, public)]
pub struct DurRow { #[primary_key] pub id: u64, pub d: TimeDuration }

// default_values: auto_inc pk generates a default_values entry the parser drops.
#[table(accessor = seq_row, public)]
pub struct SeqRow { #[primary_key] #[auto_inc] pub id: u64, pub v: u32 }

#[reducer]
fn add_thing(ctx: &ReducerContext, id: u64, label: String) { ctx.db.thing().insert(Thing { id, label }); }
#[reducer]
fn del_thing(ctx: &ReducerContext, id: u64) { ctx.db.thing().id().delete(&id); }
#[reducer]
fn log_event(ctx: &ReducerContext, msg: String) { ctx.db.event_log().insert(EventLog { msg }); }
#[reducer]
fn add_dur(ctx: &ReducerContext, id: u64, micros: i64) { ctx.db.dur_row().insert(DurRow { id, d: TimeDuration::from_micros(micros) }); }
#[reducer]
fn add_seq(ctx: &ReducerContext, v: u32) { ctx.db.seq_row().insert(SeqRow { id: 0, v }); }
#[reducer]
fn fail_reducer(_ctx: &ReducerContext) -> Result<(), String> { Err("intentional failure".to_string()) }
