#!/usr/bin/env node
// refcheck_sql.mjs <refs.json>
// Turns db_refs.mjs output into ONE read-only SELECT, to run on your PRODUCTION Supabase project (SQL editor,
// or a Supabase MCP execute_sql tool). Every row it returns is a problem:
//   present=false  production lacks a table / column / function / bucket the new code uses
//   auth_ok=false  it exists, but signed-in users (role `authenticated`) aren't allowed to use it
// Zero rows = pass.
// The references travel as hex digits, so nothing taken from your files (a file name, say) can end the quoted
// text early and turn into SQL.
import { readFileSync } from 'node:fs';

const j = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const refs = j.refs.filter((r) => ['table', 'column', 'embed', 'rpc', 'bucket'].includes(r.k))
  .map(({ k, t, n, args, src }) => ({ k, t, n, args, src }));
if (!refs.length) { process.stdout.write("select 0 as checked, 'no database references on new lines' as note;\n"); process.exit(0); }
const hex = Buffer.from(JSON.stringify(refs), 'utf8').toString('hex');
process.stdout.write(`-- launchcodes reference check: read-only. Every returned row is a problem.
with ref as (
  select * from jsonb_to_recordset(convert_from(decode('${hex}', 'hex'), 'UTF8')::jsonb)
    as r(k text, t text, n text, args jsonb, src text)
),
rel as (
  select c.oid, c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace
  where s.nspname = 'public' and c.relkind in ('r','v','m','p','f')
),
fn as (
  select p.oid, p.proname,
    coalesce(array_agg(u.nm order by u.ord) filter (where u.md in ('i','b','v')), '{}') as in_args
  from pg_proc p join pg_namespace s on s.oid = p.pronamespace and s.nspname = 'public'
  left join lateral unnest(coalesce(p.proargnames, '{}'::text[]),
    coalesce(p.proargmodes, array_fill('i'::"char", array[cardinality(coalesce(p.proargnames, '{}'::text[]))])))
    with ordinality as u(nm, md, ord) on true
  group by p.oid, p.proname
),
chk as (
  select ref.k, coalesce(ref.t || '.', '') || ref.n as ref, ref.src,
    case ref.k
      when 'table'  then exists (select 1 from rel where rel.relname = ref.n)
      when 'column' then exists (select 1 from rel join pg_attribute a on a.attrelid = rel.oid
                                 where rel.relname = ref.t and a.attname = ref.n and a.attnum > 0 and not a.attisdropped)
      when 'rpc'    then exists (select 1 from fn where fn.proname = ref.n and (ref.args is null or not exists (
                                   select 1 from jsonb_array_elements_text(ref.args) x(a) where x.a <> all(fn.in_args))))
      when 'bucket' then exists (select 1 from storage.buckets b where b.id = ref.n)
      when 'embed'  then exists (select 1 from pg_constraint fk join pg_class b on b.oid = fk.conrelid join pg_class f on f.oid = fk.confrelid
                                 where fk.contype = 'f' and (
                                   (b.relname = ref.t and (f.relname = ref.n or exists (select 1 from pg_attribute a where a.attrelid = b.oid and a.attnum = any(fk.conkey) and a.attname = ref.n)))
                                   or (f.relname = ref.t and b.relname = ref.n)))
    end as present,
    case ref.k
      when 'table'  then (select bool_or(has_table_privilege('authenticated', rel.oid, 'SELECT') or has_any_column_privilege('authenticated', rel.oid, 'SELECT')) from rel where rel.relname = ref.n)
      when 'column' then (select bool_or(has_column_privilege('authenticated', rel.oid, ref.n, 'SELECT'))
                          from rel join pg_attribute a on a.attrelid = rel.oid
                          where rel.relname = ref.t and a.attname = ref.n and a.attnum > 0 and not a.attisdropped)
      when 'rpc'    then (select bool_or(has_function_privilege('authenticated', fn.oid, 'EXECUTE')) from fn where fn.proname = ref.n)
    end as auth_ok
  from ref
)
select k, ref, present, auth_ok, src from chk
where not present or auth_ok is false
order by present, k, ref;
`);
