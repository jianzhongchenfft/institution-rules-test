-- Team messages stable baseline verification (READ ONLY)
-- Baseline: V35 frontend + V36 direct INSERT hardening, 2026-10-09
-- TEST PROJECT ONLY; do not use this as a migration or database restore script.
-- Compare results with database-catalog.json.

-- 1) Five tables: RLS and role capabilities.
select c.relname as table_name, c.relrowsecurity as rls_enabled,
 c.relforcerowsecurity as force_rls,
 has_table_privilege('authenticated',c.oid,'SELECT') as authenticated_select,
 has_table_privilege('authenticated',c.oid,'INSERT') as authenticated_insert,
 has_table_privilege('authenticated',c.oid,'UPDATE') as authenticated_update,
 has_table_privilege('authenticated',c.oid,'DELETE') as authenticated_delete,
 has_table_privilege('authenticated',c.oid,'TRUNCATE') as authenticated_truncate,
 has_table_privilege('anon',c.oid,'SELECT') as anon_select
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='r' and c.relname like 'team_message%'
order by c.relname;

-- 2) Column-level permissions needed for read confirmation, reports and closing.
select table_name,column_name,privilege_type
from information_schema.column_privileges
where table_schema='public' and grantee='authenticated'
  and table_name like 'team_message%' and privilege_type<>'SELECT'
order by table_name,column_name,privilege_type;

-- 3) Active RLS policy fingerprints. Same expression as database-catalog.json.
select tablename,policyname,cmd,roles,permissive,
 md5(coalesce(qual,'')||'|'||coalesce(with_check,'')) as policy_logic_md5
from pg_policies where schemaname='public' and tablename like 'team_message%'
order by tablename,policyname;

-- 4) Function source fingerprints. Based on pg_proc.prosrc, not full DDL.
select p.oid::regprocedure::text as signature,p.prosecdef as security_definer,
 md5(p.prosrc) as body_md5,
 has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute,
 has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and
 (p.proname like 'team_message%' or
  p.proname in ('create_team_message','add_team_message_task','void_team_message_update'))
order by p.proname;

-- 5) Constraint and index fingerprints.
select c.relname as table_name,
 (select count(*) from pg_constraint x where x.conrelid=c.oid) as constraints_count,
 (select md5(string_agg(x.conname||':'||pg_get_constraintdef(x.oid),'|' order by x.conname))
  from pg_constraint x where x.conrelid=c.oid) as constraints_md5,
 (select count(*) from pg_index i where i.indrelid=c.oid) as indexes_count,
 (select md5(string_agg(pg_get_indexdef(i.indexrelid),'|' order by i.indexrelid))
  from pg_index i where i.indrelid=c.oid) as indexes_md5
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='r' and c.relname like 'team_message%'
order by c.relname;

-- 6) Essential permission assertions, expected boolean values:
-- first three FALSE, next five TRUE, last FALSE.
select
 has_table_privilege('authenticated','public.team_messages','INSERT') as direct_message_insert,
 has_table_privilege('authenticated','public.team_message_tasks','INSERT') as direct_task_insert,
 has_table_privilege('authenticated','public.team_message_recipients','INSERT') as direct_recipient_insert,
 has_column_privilege('authenticated','public.team_message_recipients','read_at','UPDATE') as self_read_allowed,
 has_column_privilege('authenticated','public.team_messages','closed_at','UPDATE') as creator_close_column_allowed,
 has_function_privilege('authenticated','public.create_team_message(text,jsonb,uuid[])','EXECUTE') as create_rpc_allowed,
 has_function_privilege('authenticated','public.add_team_message_task(uuid,text,uuid)','EXECUTE') as append_rpc_allowed,
 has_function_privilege('authenticated','public.team_message_task_action(uuid,text,text)','EXECUTE') as task_rpc_allowed,
 has_function_privilege('anon','public.create_team_message(text,jsonb,uuid[])','EXECUTE') as anonymous_create_allowed;

-- 7) Current record counts for monitoring ONLY; these are expected to change.
select
 (select count(*) from public.team_messages) as messages,
 (select count(*) from public.team_message_tasks) as tasks,
 (select count(*) from public.team_message_recipients) as recipients,
 (select count(*) from public.team_message_updates) as reports,
 (select count(*) from public.team_message_favorites) as favorites;
