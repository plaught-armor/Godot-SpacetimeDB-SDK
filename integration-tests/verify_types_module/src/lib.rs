use spacetimedb::{table, reducer, ReducerContext, Table, Uuid, ScheduleAt, TimeDuration};
use spacetimedb::sats::{i256, u256};

#[table(accessor = one_u128, public)]
pub struct OneU128 { pub n: u128 }
#[table(accessor = one_i128, public)]
pub struct OneI128 { pub n: i128 }
#[table(accessor = one_u256, public)]
pub struct OneU256 { pub n: u256 }
#[table(accessor = one_i256, public)]
pub struct OneI256 { pub n: i256 }
#[table(accessor = one_uuid, public)]
pub struct OneUuid { pub u: Uuid }

#[table(accessor = my_schedule, public, scheduled(on_schedule))]
pub struct MySchedule {
    #[primary_key]
    #[auto_inc]
    pub scheduled_id: u64,
    pub scheduled_at: ScheduleAt,
}

#[reducer]
fn insert_one_u128(ctx: &ReducerContext, n: u128) { ctx.db.one_u128().insert(OneU128 { n }); }
#[reducer]
fn insert_one_i128(ctx: &ReducerContext, n: i128) { ctx.db.one_i128().insert(OneI128 { n }); }
#[reducer]
fn insert_one_u256(ctx: &ReducerContext, n: u256) { ctx.db.one_u256().insert(OneU256 { n }); }
#[reducer]
fn insert_one_i256(ctx: &ReducerContext, n: i256) { ctx.db.one_i256().insert(OneI256 { n }); }
#[reducer]
fn insert_one_uuid(ctx: &ReducerContext, u: Uuid) { ctx.db.one_uuid().insert(OneUuid { u }); }

#[reducer]
fn add_schedule(ctx: &ReducerContext, micros: i64) {
    ctx.db.my_schedule().insert(MySchedule {
        scheduled_id: 0,
        scheduled_at: ScheduleAt::Interval(TimeDuration::from_micros(micros)),
    });
}

#[reducer]
fn on_schedule(_ctx: &ReducerContext, _arg: MySchedule) {}
