use spacetimedb::{table, reducer, ReducerContext, Table, SpacetimeType};

#[derive(SpacetimeType, Clone)]
pub enum Shape {
    Circle(u32),
    Square(u32),
    Nothing,
}

#[table(accessor = shape_row, public)]
pub struct ShapeRow {
    #[primary_key]
    pub id: u64,
    pub shape: Shape,
}

#[table(accessor = res_row, public)]
pub struct ResRow {
    #[primary_key]
    pub id: u64,
    pub r: Result<i32, String>,
}

#[reducer]
fn add_shape(ctx: &ReducerContext, id: u64, radius: u32) {
    ctx.db.shape_row().insert(ShapeRow { id, shape: Shape::Circle(radius) });
}
#[reducer]
fn add_res(ctx: &ReducerContext, id: u64, ok: bool) {
    ctx.db.res_row().insert(ResRow { id, r: if ok { Ok(42) } else { Err("bad".to_string()) } });
}
