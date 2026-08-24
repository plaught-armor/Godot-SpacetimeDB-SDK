// Innermost submodule: registered by `auth.ts`, so its table lands on the wire
// as `auth.baz.baz_items` — a name carrying more than one dot.
import { schema, table, t } from 'spacetimedb/server';

const bazItem = t.object('BazItem', {
  label: t.string(),
});

export const bazItems = table(
  { public: true },
  {
    id: t.u64().primaryKey(),
    item: bazItem,
  }
);

const bazSchema = schema({ bazItems });
export default bazSchema;

export const bazInsert = bazSchema.reducer({ n: t.u64() }, (ctx, { n }) => {
  ctx.db.bazItems.insert({ id: n, item: { label: `baz-${n}` } });
});
