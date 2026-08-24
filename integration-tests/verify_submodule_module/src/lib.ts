// First-level submodule. `LibPoint` deliberately sits at the same typespace
// index as the root module's `RootPoint` while having a different shape, so a
// parser that resolved submodule type refs against the root typespace would
// bind these rows to the wrong type instead of failing loudly.
import { schema, table, t } from 'spacetimedb/server';

const libPoint = t.object('LibPoint', {
  a: t.string(),
  b: t.string(),
});

export const libData = table(
  { public: true },
  {
    id: t.u64().primaryKey(),
    point: libPoint,
  }
);

// Private: the client is not meant to see this table at all.
export const libSecret = table(
  { },
  {
    id: t.u64().primaryKey(),
    secret: t.string(),
  }
);

const libSchema = schema({ libData, libSecret });
export default libSchema;

export const libInsert = libSchema.reducer({ n: t.u64() }, (ctx, { n }) => {
  ctx.db.libData.insert({ id: n, point: { a: `a-${n}`, b: `b-${n}` } });
  ctx.db.libSecret.insert({ id: n, secret: `secret-${n}` });
});
