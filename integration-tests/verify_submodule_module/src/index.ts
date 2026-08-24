// Root module. Registers two namespaces: `lib` (one level) and `auth` (which
// nests `baz` inside itself).
import { schema, table, t } from 'spacetimedb/server';
import * as lib from './lib';
import * as auth from './auth';

const rootPoint = t.object('RootPoint', {
  x: t.u64(),
});

const rootThing = table(
  { public: true },
  {
    id: t.u64().primaryKey(),
    point: rootPoint,
  }
);

const spacetimedb = schema({ rootThing, lib, auth });
export default spacetimedb;

export const rootInsert = spacetimedb.reducer({ n: t.u64() }, (ctx, { n }) => {
  ctx.db.rootThing.insert({ id: n, point: { x: n } });
});
