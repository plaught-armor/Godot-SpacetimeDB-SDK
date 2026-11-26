// Middle submodule: holds a table of its own and nests `baz` beneath it, mounted as
// `bazStore` so the server (2.10.2+) canonicalizes the namespace to `baz_store`.
import { schema, table, t } from 'spacetimedb/server';
import * as baz from './baz';

export const authSession = table(
  { public: true },
  {
    id: t.u64().primaryKey(),
    token: t.string(),
  }
);

const authSchema = schema({ authSession, bazStore: baz });
export default authSchema;

export const authInsert = authSchema.reducer({ n: t.u64() }, (ctx, { n }) => {
  ctx.db.authSession.insert({ id: n, token: `token-${n}` });
});
