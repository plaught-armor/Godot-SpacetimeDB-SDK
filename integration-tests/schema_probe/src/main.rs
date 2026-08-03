// Prints the exact JSON a SpacetimeDB server would serve at
// GET /v1/database/<db>/schema?version=10 for a module that mounts a submodule,
// by running the same conversion + serializer the HTTP route uses
// (crates/client-api/src/routes/database.rs: RawModuleDefV10::from(module_def)
// wrapped in sats::serde::SerdeWrapper).
use spacetimedb_lib::db::raw_def::v10::{
    RawModuleDefV10, RawModuleDefV10Builder, RawModuleDefV10Section, RawSubmoduleV10,
};
use spacetimedb_lib::{AlgebraicType, ProductType};
use spacetimedb_schema::def::ModuleDef;

fn main() {
    // Submodule: one public table + one reducer, mounted under `lib`.
    let mut sub = RawModuleDefV10Builder::new();
    sub.build_table_with_new_type(
        "LibData",
        ProductType::from([("id", AlgebraicType::U64), ("value", AlgebraicType::String)]),
        true,
    )
    .finish();
    sub.add_reducer("libInsert", ProductType::from([("value", AlgebraicType::String)]));

    // Root module: its own table + reducer, plus the submodule.
    let mut root_builder = RawModuleDefV10Builder::new();
    root_builder
        .build_table_with_new_type(
            "RootThing",
            ProductType::from([("id", AlgebraicType::U64)]),
            true,
        )
        .finish();
    root_builder.add_reducer("rootInsert", ProductType::from([("n", AlgebraicType::U64)]));
    let mut root = root_builder.finish();
    root.sections
        .push(RawModuleDefV10Section::Submodules(vec![RawSubmoduleV10 {
            namespace: "lib".to_string(),
            module: sub.finish(),
        }]));

    // Validate, then convert back exactly as the schema route does.
    let def: ModuleDef = root.try_into().expect("valid module def");

    eprintln!("--- names as the engine registers them ---");
    for (prefix, _, table) in def.all_tables_with_prefix() {
        eprintln!("table: {}{}  (accessor {})", prefix, table.name, table.accessor_name);
    }
    for (prefix, _, reducer) in def.all_reducers_with_prefix() {
        eprintln!("reducer: {}  (prefix {:?})", reducer.name, prefix.to_string());
    }

    let raw = RawModuleDefV10::from(def);
    println!(
        "{}",
        serde_json::to_string_pretty(&spacetimedb_sats::serde::SerdeWrapper(raw)).unwrap()
    );
}
