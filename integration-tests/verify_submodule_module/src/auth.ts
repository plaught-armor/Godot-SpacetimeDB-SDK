// Middle submodule: holds a table of its own and nests `baz` beneath it.
import { schema, table, t } from 'spacetimedb/server';
import * as baz from './baz';

export const authSession = table(
  { public: true },
  {
    id: t.u64().primaryKey(),
    token: t.string(),
  }
);

const authSchema = schema({ authSession, baz });
export default authSchema;

export const authInsert = authSchema.reducer({ n: t.u64() }, (ctx, { n }) => {
  ctx.db.authSession.insert({ id: n, token: `token-${n}` });
});
