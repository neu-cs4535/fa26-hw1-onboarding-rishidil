-- Gradebook column groups: create, rename, delete, reorder, and move columns between groups.
--
-- 20260924210008_add_gradebook_column_groups.sql made a group a row. This migration gives
-- instructors a way to change those rows. Every write goes through an RPC rather than a direct
-- table write, because the gradebook table draws a group's header across its columns
-- (scrollableRow1Segments in gradebookTable.tsx), so a group's columns must sit next to each other.
-- A plain UPDATE of group_id or sort_order can break that, and an RPC can keep it.
--
-- Invariants every function below keeps:
--   * A group's columns are contiguous in sort_order.
--   * Reordering never changes membership. Moving a column or a group changes sort_order only;
--     group_id changes only through gradebook_column_set_group / _group_create / _group_delete.
--   * No empty groups. A group whose last column leaves is deleted.
--
-- Reordering reuses the gradebook's existing sort_order values in their existing order and only
-- permutes which column holds which value. Gaps such as the 999 on "final-grade" therefore
-- survive, and a move between two adjacent columns is still a swap of their two values, which is
-- what gradebook_column_move_left/right did before this migration.

-- ---------------------------------------------------------------------------
-- Helpers (not callable by clients)
-- ---------------------------------------------------------------------------

-- Locks the gradebook and checks the caller is an instructor of its class.
-- The advisory lock is the same one gradebook_columns_reorder and the move functions take, so
-- every column-order change in a gradebook is serialised.
create or replace function public._gradebook_column_groups_authorize(p_gradebook_id bigint)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_class_id bigint;
begin
    select class_id into v_class_id from public.gradebooks where id = p_gradebook_id;
    if v_class_id is null then
        raise exception 'gradebook % not found', p_gradebook_id;
    end if;
    if not public.authorizeforclassinstructor(v_class_id) then
        raise exception 'insufficient permissions: instructor access required for class %', v_class_id;
    end if;
    perform pg_advisory_xact_lock(p_gradebook_id);
end;
$function$;

-- The gradebook's column ids, left to right.
create or replace function public._gradebook_column_order(p_gradebook_id bigint)
returns bigint[]
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select coalesce(array_agg(id order by sort_order asc nulls last, id asc), '{}')
    from public.gradebook_columns
    where gradebook_id = p_gradebook_id;
$function$;

-- Writes a new left-to-right order. p_ids must be a permutation of the gradebook's columns. The
-- column in position i gets the i-th smallest existing sort_order (NULLs are numbered past the
-- current maximum first), so only columns whose position changed are written. Group sort_order
-- is then re-derived as the smallest sort_order among its columns.
create or replace function public._gradebook_apply_column_order(p_gradebook_id bigint, p_ids bigint[])
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
    if (select count(*) from public.gradebook_columns where gradebook_id = p_gradebook_id)
       <> coalesce(array_length(p_ids, 1), 0) then
        raise exception 'column order for gradebook % is not a permutation of its columns', p_gradebook_id;
    end if;

    perform set_config('pawtograder.bypass_sort_order_trigger_' || p_gradebook_id::text, 'true', true);
    begin
        with slots as (
            select
                row_number() over (order by v) as position,
                v as sort_order
            from (
                select coalesce(
                    sort_order,
                    (select coalesce(max(sort_order), -1) from public.gradebook_columns where gradebook_id = p_gradebook_id)
                        + row_number() over (partition by sort_order is null order by id)::integer
                ) as v
                from public.gradebook_columns
                where gradebook_id = p_gradebook_id
            ) s
        ),
        wanted as (
            select t.id, slots.sort_order
            from unnest(p_ids) with ordinality as t(id, position)
            join slots on slots.position = t.position
        )
        update public.gradebook_columns c
        set sort_order = wanted.sort_order
        from wanted
        where c.id = wanted.id
          and c.gradebook_id = p_gradebook_id
          and c.sort_order is distinct from wanted.sort_order;
    exception
        when others then
            perform set_config('pawtograder.bypass_sort_order_trigger_' || p_gradebook_id::text, 'false', true);
            raise;
    end;
    perform set_config('pawtograder.bypass_sort_order_trigger_' || p_gradebook_id::text, 'false', true);

    update public.gradebook_column_groups g
    set sort_order = m.min_sort_order
    from (
        select group_id, min(sort_order) as min_sort_order
        from public.gradebook_columns
        where gradebook_id = p_gradebook_id and group_id is not null
        group by group_id
    ) m
    where g.id = m.group_id and g.sort_order <> m.min_sort_order;
end;
$function$;

-- The order as "units": a group is one unit, an ungrouped column is a unit of its own. Returned
-- as unit keys ('g<group id>' / 'c<column id>') left to right.
create or replace function public._gradebook_column_units(p_gradebook_id bigint)
returns text[]
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    with cols as (
        select
            case when group_id is null then 'c' || id else 'g' || group_id end as unit,
            row_number() over (order by sort_order asc nulls last, id asc) as position
        from public.gradebook_columns
        where gradebook_id = p_gradebook_id
    )
    select coalesce(array_agg(unit order by first_position), '{}')
    from (select unit, min(position) as first_position from cols group by unit) u;
$function$;

-- Expands a unit order back to column ids, keeping each unit's columns in their current order.
create or replace function public._gradebook_columns_for_units(p_gradebook_id bigint, p_units text[])
returns bigint[]
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select coalesce(array_agg(id order by array_position(p_units, unit), position), '{}')
    from (
        select
            id,
            case when group_id is null then 'c' || id else 'g' || group_id end as unit,
            row_number() over (order by sort_order asc nulls last, id asc) as position
        from public.gradebook_columns
        where gradebook_id = p_gradebook_id
    ) cols;
$function$;

revoke all on function public._gradebook_column_groups_authorize(bigint) from public, anon, authenticated;
revoke all on function public._gradebook_column_order(bigint) from public, anon, authenticated;
revoke all on function public._gradebook_apply_column_order(bigint, bigint[]) from public, anon, authenticated;
revoke all on function public._gradebook_column_units(bigint) from public, anon, authenticated;
revoke all on function public._gradebook_columns_for_units(bigint, text[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Membership
-- ---------------------------------------------------------------------------

-- Moves a column into p_group_id, or out of any group when p_group_id is NULL.
--   * Joining a group that has columns: the column is placed after that group's last column.
--   * Leaving a group: the column is placed just after what remains of its old group, so the
--     old group stays contiguous.
--   * Otherwise the column keeps its position.
-- A group left with no columns is deleted.
create or replace function public.gradebook_column_set_group(p_column_id bigint, p_group_id bigint)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_gradebook_id bigint;
    v_old_group_id bigint;
    v_ids bigint[];
    v_rest bigint[];
    v_anchor_group bigint;
    v_insert_at integer;
begin
    select gradebook_id, group_id into v_gradebook_id, v_old_group_id
    from public.gradebook_columns where id = p_column_id;
    if v_gradebook_id is null then
        raise exception 'gradebook column % not found', p_column_id;
    end if;

    perform public._gradebook_column_groups_authorize(v_gradebook_id);

    if p_group_id is not distinct from v_old_group_id then
        return;
    end if;
    if p_group_id is not null and not exists (
        select 1 from public.gradebook_column_groups where id = p_group_id and gradebook_id = v_gradebook_id
    ) then
        raise exception 'column group % is not in the same gradebook as column %', p_group_id, p_column_id;
    end if;

    v_ids := public._gradebook_column_order(v_gradebook_id);
    v_rest := array_remove(v_ids, p_column_id);

    -- Which group's block the column should follow, if any.
    if p_group_id is not null and exists (
        select 1 from public.gradebook_columns where group_id = p_group_id and id <> p_column_id
    ) then
        v_anchor_group := p_group_id;
    elsif v_old_group_id is not null and exists (
        select 1 from public.gradebook_columns where group_id = v_old_group_id and id <> p_column_id
    ) then
        v_anchor_group := v_old_group_id;
    end if;

    if v_anchor_group is not null then
        select max(array_position(v_rest, id)) into v_insert_at
        from public.gradebook_columns where group_id = v_anchor_group and id <> p_column_id;
    else
        v_insert_at := array_position(v_ids, p_column_id) - 1;
    end if;

    update public.gradebook_columns set group_id = p_group_id where id = p_column_id;

    perform public._gradebook_apply_column_order(
        v_gradebook_id,
        v_rest[1:v_insert_at] || p_column_id || v_rest[v_insert_at + 1:]
    );

    if v_old_group_id is not null and not exists (
        select 1 from public.gradebook_columns where group_id = v_old_group_id
    ) then
        delete from public.gradebook_column_groups where id = v_old_group_id;
    end if;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Group CRUD
-- ---------------------------------------------------------------------------

-- Creates a group containing p_column_id and returns its id. A group always has at least one
-- column, so there is no way to create an empty one. More columns join through
-- gradebook_column_set_group.
create or replace function public.gradebook_column_group_create(p_column_id bigint, p_name text)
returns bigint
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_col public.gradebook_columns;
    v_name text := btrim(coalesce(p_name, ''));
    v_group_id bigint;
begin
    select * into v_col from public.gradebook_columns where id = p_column_id;
    if v_col.id is null then
        raise exception 'gradebook column % not found', p_column_id;
    end if;
    if v_name = '' then
        raise exception 'column group name cannot be empty';
    end if;

    perform public._gradebook_column_groups_authorize(v_col.gradebook_id);

    -- group_key only has to be unique within the gradebook. Backfilled groups use the key the
    -- old heuristic produced; groups made here use a random one, which can never collide with a
    -- backfilled key.
    insert into public.gradebook_column_groups (class_id, gradebook_id, group_key, name, sort_order)
    values (v_col.class_id, v_col.gradebook_id, 'group-' || gen_random_uuid(), v_name, coalesce(v_col.sort_order, 0))
    returning id into v_group_id;

    perform public.gradebook_column_set_group(p_column_id, v_group_id);
    return v_group_id;
end;
$function$;

create or replace function public.gradebook_column_group_rename(p_group_id bigint, p_name text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_gradebook_id bigint;
    v_name text := btrim(coalesce(p_name, ''));
begin
    select gradebook_id into v_gradebook_id from public.gradebook_column_groups where id = p_group_id;
    if v_gradebook_id is null then
        raise exception 'column group % not found', p_group_id;
    end if;
    if v_name = '' then
        raise exception 'column group name cannot be empty';
    end if;
    perform public._gradebook_column_groups_authorize(v_gradebook_id);
    update public.gradebook_column_groups set name = v_name where id = p_group_id;
end;
$function$;

-- Deletes the group. Its columns stay where they are and become ungrouped
-- (gradebook_columns.group_id is ON DELETE SET NULL). No column or grade is deleted.
create or replace function public.gradebook_column_group_delete(p_group_id bigint)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_gradebook_id bigint;
begin
    select gradebook_id into v_gradebook_id from public.gradebook_column_groups where id = p_group_id;
    if v_gradebook_id is null then
        raise exception 'column group % not found', p_group_id;
    end if;
    perform public._gradebook_column_groups_authorize(v_gradebook_id);
    delete from public.gradebook_column_groups where id = p_group_id;
end;
$function$;

-- Moves a whole group one unit left (p_direction = -1) or right (+1). The unit it trades places
-- with is either another whole group or a single ungrouped column. Membership is untouched.
create or replace function public.gradebook_column_group_move(p_group_id bigint, p_direction integer)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_gradebook_id bigint;
    v_units text[];
    v_idx integer;
    v_other integer;
begin
    if p_direction not in (-1, 1) then
        raise exception 'direction must be -1 or 1, got %', p_direction;
    end if;
    select gradebook_id into v_gradebook_id from public.gradebook_column_groups where id = p_group_id;
    if v_gradebook_id is null then
        raise exception 'column group % not found', p_group_id;
    end if;
    perform public._gradebook_column_groups_authorize(v_gradebook_id);

    v_units := public._gradebook_column_units(v_gradebook_id);
    v_idx := array_position(v_units, 'g' || p_group_id);
    v_other := v_idx + p_direction;
    if v_idx is null or v_other < 1 or v_other > array_length(v_units, 1) then
        return; -- already at the edge
    end if;

    v_units[v_idx] := v_units[v_other];
    v_units[v_other] := 'g' || p_group_id;
    perform public._gradebook_apply_column_order(
        v_gradebook_id, public._gradebook_columns_for_units(v_gradebook_id, v_units)
    );
end;
$function$;

-- ---------------------------------------------------------------------------
-- Column Move Left / Move Right, now membership-preserving
--
-- Replaces 20260329000000_gradebook_column_move_swap.sql. Same signature and return value.
--   * A grouped column moves within its group only. At the group's edge the call raises, and the
--     menu shows the message; leaving a group is gradebook_column_set_group's job.
--   * An ungrouped column steps over its neighbouring unit: another ungrouped column, or a whole
--     group, never landing inside one.
-- ---------------------------------------------------------------------------

create or replace function public._gradebook_column_step(p_column_id bigint, p_direction integer)
returns public.gradebook_columns
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
    v_col public.gradebook_columns;
    v_ids bigint[];
    v_idx integer;
    v_neighbor_id bigint;
    v_units text[];
    v_other integer;
begin
    select * into v_col from public.gradebook_columns where id = p_column_id;
    if v_col.id is null then
        raise exception 'gradebook column % not found', p_column_id;
    end if;
    perform public._gradebook_column_groups_authorize(v_col.gradebook_id);

    if v_col.group_id is not null then
        v_ids := public._gradebook_column_order(v_col.gradebook_id);
        v_idx := array_position(v_ids, p_column_id);
        v_neighbor_id := v_ids[v_idx + p_direction];
        if v_neighbor_id is null or not exists (
            select 1 from public.gradebook_columns where id = v_neighbor_id and group_id = v_col.group_id
        ) then
            raise exception '"%" is already the % column in its group. Use "Change group" to move it out.',
                v_col.name, case when p_direction < 0 then 'first' else 'last' end;
        end if;
        v_ids[v_idx] := v_neighbor_id;
        v_ids[v_idx + p_direction] := p_column_id;
    else
        v_units := public._gradebook_column_units(v_col.gradebook_id);
        v_idx := array_position(v_units, 'c' || p_column_id);
        v_other := v_idx + p_direction;
        if v_other < 1 or v_other > array_length(v_units, 1) then
            return v_col;
        end if;
        v_units[v_idx] := v_units[v_other];
        v_units[v_other] := 'c' || p_column_id;
        v_ids := public._gradebook_columns_for_units(v_col.gradebook_id, v_units);
    end if;

    perform public._gradebook_apply_column_order(v_col.gradebook_id, v_ids);

    select * into v_col from public.gradebook_columns where id = p_column_id;
    return v_col;
end;
$function$;

revoke all on function public._gradebook_column_step(bigint, integer) from public, anon, authenticated;

create or replace function public.gradebook_column_move_left(p_column_id bigint)
returns public.gradebook_columns
language sql
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select * from public._gradebook_column_step(p_column_id, -1);
$function$;

create or replace function public.gradebook_column_move_right(p_column_id bigint)
returns public.gradebook_columns
language sql
security definer
set search_path to 'public', 'pg_temp'
as $function$
    select * from public._gradebook_column_step(p_column_id, 1);
$function$;

-- Client-callable surface: instructors, checked inside each function.
revoke all on function public.gradebook_column_set_group(bigint, bigint) from public, anon;
revoke all on function public.gradebook_column_group_create(bigint, text) from public, anon;
revoke all on function public.gradebook_column_group_rename(bigint, text) from public, anon;
revoke all on function public.gradebook_column_group_delete(bigint) from public, anon;
revoke all on function public.gradebook_column_group_move(bigint, integer) from public, anon;
revoke all on function public.gradebook_column_move_left(bigint) from public, anon;
revoke all on function public.gradebook_column_move_right(bigint) from public, anon;
grant execute on function public.gradebook_column_set_group(bigint, bigint) to authenticated, service_role;
grant execute on function public.gradebook_column_group_create(bigint, text) to authenticated, service_role;
grant execute on function public.gradebook_column_group_rename(bigint, text) to authenticated, service_role;
grant execute on function public.gradebook_column_group_delete(bigint) to authenticated, service_role;
grant execute on function public.gradebook_column_group_move(bigint, integer) to authenticated, service_role;
grant execute on function public.gradebook_column_move_left(bigint) to authenticated, service_role;
grant execute on function public.gradebook_column_move_right(bigint) to authenticated, service_role;
