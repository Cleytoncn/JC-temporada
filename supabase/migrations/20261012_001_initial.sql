-- JC Temporada: esquema inicial isolado. NÃO executar no banco Sistema Financeiro.
-- Requer PostgreSQL 17/Supabase. Aplicar somente em um projeto exclusivo da JC Temporada.
create extension if not exists btree_gist;

create table public.jc_organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 2 and 120),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{2,62}$'),
  city text not null default 'Caldas Novas',
  state_code text not null default 'GO',
  country_code text not null default 'BR',
  business_timezone text not null default 'America/Sao_Paulo',
  created_at timestamptz not null default now()
);
create table public.jc_memberships (
  organization_id uuid not null references public.jc_organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','manager','agent','viewer')),
  created_at timestamptz not null default now(),
  primary key (organization_id,user_id)
);
-- SECURITY DEFINER avoids recursive RLS when verifying membership.
create function public.jc_is_member(p_org uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and exists (
    select 1 from public.jc_memberships m
     where m.organization_id=p_org and m.user_id=auth.uid()
  );
$$;
create function public.jc_can_write(p_org uuid) returns boolean
language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and exists (
    select 1 from public.jc_memberships m
     where m.organization_id=p_org and m.user_id=auth.uid()
       and m.role in ('owner','manager','agent')
  );
$$;
revoke all on function public.jc_is_member(uuid) from public;
revoke all on function public.jc_can_write(uuid) from public;
grant execute on function public.jc_is_member(uuid) to authenticated;
grant execute on function public.jc_can_write(uuid) to authenticated;

-- Initial onboarding; the caller is always the owner of the organization they create.
create function public.jc_create_organization(p_name text,p_slug text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if length(btrim(p_name)) < 2 then raise exception 'Invalid organization name'; end if;
  insert into public.jc_organizations(name,slug) values (btrim(p_name),p_slug)
  returning id into v_id;
  insert into public.jc_memberships(organization_id,user_id,role)
  values (v_id,auth.uid(),'owner');
  return v_id;
end; $$;
revoke all on function public.jc_create_organization(text,text) from public;
grant execute on function public.jc_create_organization(text,text) to authenticated;

create table public.jc_property_groups (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.jc_organizations(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  created_at timestamptz not null default now(),
  unique (organization_id,id),
  unique (organization_id,name)
);
create table public.jc_properties (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.jc_organizations(id) on delete cascade,
  group_id uuid,
  name text not null check (length(btrim(name)) > 0),
  internal_code text not null,
  capacity smallint not null default 4 check (capacity between 1 and 100),
  base_nightly_rate numeric(12,2) not null default 0 check (base_nightly_rate >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,id),
  unique (organization_id,internal_code),
  foreign key (organization_id,group_id)
    references public.jc_property_groups(organization_id,id)
);
create table public.jc_guests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.jc_organizations(id) on delete cascade,
  full_name text not null check (length(btrim(full_name)) > 1),
  email text,
  phone text,
  created_at timestamptz not null default now(),
  unique (organization_id,id)
);

-- Single occupancy table guarantees no double bookings ACROSS reservations, blocks and maintenance.
-- [check_in,check_out): check-out day is available for the next guest.
create table public.jc_calendar_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.jc_organizations(id) on delete cascade,
  property_id uuid not null,
  guest_id uuid,
  kind text not null check (kind in ('reservation','block','maintenance')),
  check_in date not null,
  check_out date not null,
  total_amount numeric(12,2) not null default 0 check (total_amount >= 0),
  source_channel text not null default 'direct'
    check (source_channel in ('direct','airbnb','booking','decolar','expedia','other')),
  external_reservation_id text,
  internal_reference text,
  notes text,
  cancelled_at timestamptz,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,id),
  foreign key (organization_id,property_id)
    references public.jc_properties(organization_id,id),
  foreign key (organization_id,guest_id)
    references public.jc_guests(organization_id,id),
  check (check_out > check_in),
  check (
    (kind='reservation' and total_amount>0 and guest_id is not null)
    or (kind in ('block','maintenance') and total_amount=0)
  )
);
alter table public.jc_calendar_entries add constraint jc_no_overlapping_occupancy
  exclude using gist (
    organization_id with =,
    property_id with =,
    daterange(check_in,check_out,'[)') with &&
  ) where (cancelled_at is null);
create unique index jc_unique_channel_reservation
  on public.jc_calendar_entries(organization_id,source_channel,external_reservation_id)
  where external_reservation_id is not null and kind='reservation' and cancelled_at is null;
create index jc_calendar_property_dates on public.jc_calendar_entries
  (organization_id,property_id,check_in,check_out) where cancelled_at is null;
create index jc_calendar_org_dates on public.jc_calendar_entries
  (organization_id,check_in,check_out) where cancelled_at is null;

-- Append-only payment ledger for this initial migration. No direct UPDATE/DELETE policies.
-- Cancelling/adjusting payments requires a future audited correction workflow.
create table public.jc_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.jc_organizations(id) on delete cascade,
  calendar_entry_id uuid not null,
  amount numeric(12,2) not null check (amount > 0),
  paid_on date not null default current_date,
  method text not null default 'other',
  note text,
  recorded_by uuid references auth.users(id) on delete set null default auth.uid(),
  recorded_at timestamptz not null default now(),
  foreign key (organization_id,calendar_entry_id)
    references public.jc_calendar_entries(organization_id,id)
);
create index jc_payments_by_entry on public.jc_payments(organization_id,calendar_entry_id);

-- Serialize payment inserts through the booking row; refuse overpayment atomically.
create function public.jc_guard_payment() returns trigger
language plpgsql security invoker set search_path='' as $$
declare v_total numeric(12,2);v_paid numeric(12,2);v_kind text;v_cancelled timestamptz;
begin
  select e.total_amount,e.kind,e.cancelled_at
    into v_total,v_kind,v_cancelled
    from public.jc_calendar_entries e
    where e.organization_id=new.organization_id and e.id=new.calendar_entry_id
    for update;
  if not found or v_kind<>'reservation' or v_cancelled is not null then
    raise exception 'Payment is allowed only for active reservations';
  end if;
  select coalesce(sum(p.amount),0) into v_paid from public.jc_payments p
    where p.organization_id=new.organization_id and p.calendar_entry_id=new.calendar_entry_id;
  if v_paid+new.amount>v_total then raise exception 'Payment exceeds remaining balance'; end if;
  return new;
end; $$;
create trigger jc_payment_guard before insert on public.jc_payments
for each row execute function public.jc_guard_payment();

-- Do not allow lowering a reservation below received money.
create function public.jc_guard_entry_update() returns trigger
language plpgsql security invoker set search_path='' as $$
declare v_received numeric(12,2);
begin
  select coalesce(sum(amount),0) into v_received
    from public.jc_payments
    where organization_id=old.organization_id and calendar_entry_id=old.id;
  if v_received>0 and (new.kind<>'reservation' or new.total_amount<v_received) then
    raise exception 'Cannot reduce booking below already received payments';
  end if;
  return new;
end; $$;
create trigger jc_entry_guard before update on public.jc_calendar_entries
for each row execute function public.jc_guard_entry_update();

-- Status is derived from actual recorded receipts: yellow -> blue -> green.
create view public.jc_reservations_with_balance
with (security_invoker=true) as
select e.*,
       coalesce(p.received_amount,0)::numeric(12,2) as received_amount,
       greatest(0,e.total_amount-coalesce(p.received_amount,0))::numeric(12,2) as balance_due,
       case
         when e.kind='block' then 'blocked'
         when e.kind='maintenance' then 'maintenance'
         when coalesce(p.received_amount,0)=0 then 'pre_reservation'
         when coalesce(p.received_amount,0)>=e.total_amount then 'paid_in_full'
         else 'partially_paid'
       end as occupancy_status
from public.jc_calendar_entries e
left join (
  select organization_id,calendar_entry_id,sum(amount) as received_amount
  from public.jc_payments group by organization_id,calendar_entry_id
) p on p.organization_id=e.organization_id and p.calendar_entry_id=e.id;

-- Audit trail of calendar and payment changes.
create table public.jc_audit_log (
  id bigint generated always as identity primary key,
  organization_id uuid not null references public.jc_organizations(id) on delete cascade,
  actor_id uuid default auth.uid(),
  entity_kind text not null,
  entity_id uuid not null,
  action text not null,
  created_at timestamptz not null default now(),
  before_value jsonb,
  after_value jsonb
);
create index jc_audit_by_org on public.jc_audit_log(organization_id,created_at desc);

create function public.jc_track_change() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_org uuid;v_id uuid;v_old jsonb;v_new jsonb;
begin
  if tg_op='INSERT' then
    v_org:=new.organization_id;v_id:=new.id;v_new:=to_jsonb(new);v_old:=null;
  elsif tg_op='DELETE' then
    v_org:=old.organization_id;v_id:=old.id;v_old:=to_jsonb(old);v_new:=null;
  else
    v_org:=new.organization_id;v_id:=new.id;v_old:=to_jsonb(old);v_new:=to_jsonb(new);
  end if;
  insert into public.jc_audit_log
    (organization_id,actor_id,entity_kind,entity_id,action,before_value,after_value)
  values (v_org,auth.uid(),tg_table_name,v_id,tg_op,v_old,v_new);
  if tg_op='DELETE' then return old; end if;
  return new;
end; $$;
revoke all on function public.jc_track_change() from public;

create trigger jc_calendar_audit after insert or update or delete on public.jc_calendar_entries
for each row execute function public.jc_track_change();
create trigger jc_payment_audit after insert on public.jc_payments
for each row execute function public.jc_track_change();

-- Access isolation for every organization and staff permission.
alter table public.jc_organizations enable row level security;
alter table public.jc_memberships enable row level security;
alter table public.jc_property_groups enable row level security;
alter table public.jc_properties enable row level security;
alter table public.jc_guests enable row level security;
alter table public.jc_calendar_entries enable row level security;
alter table public.jc_payments enable row level security;
alter table public.jc_audit_log enable row level security;

create policy jc_org_read on public.jc_organizations for select to authenticated
using (public.jc_is_member(id));
create policy jc_members_read on public.jc_memberships for select to authenticated
using (public.jc_is_member(organization_id));

create policy jc_groups_read on public.jc_property_groups for select to authenticated
using (public.jc_is_member(organization_id));
create policy jc_groups_insert on public.jc_property_groups for insert to authenticated
with check (public.jc_can_write(organization_id));
create policy jc_groups_update on public.jc_property_groups for update to authenticated
using (public.jc_can_write(organization_id)) with check (public.jc_can_write(organization_id));

create policy jc_properties_read on public.jc_properties for select to authenticated
using (public.jc_is_member(organization_id));
create policy jc_properties_insert on public.jc_properties for insert to authenticated
with check (public.jc_can_write(organization_id));
create policy jc_properties_update on public.jc_properties for update to authenticated
using (public.jc_can_write(organization_id)) with check (public.jc_can_write(organization_id));

create policy jc_guests_read on public.jc_guests for select to authenticated
using (public.jc_is_member(organization_id));
create policy jc_guests_insert on public.jc_guests for insert to authenticated
with check (public.jc_can_write(organization_id));
create policy jc_guests_update on public.jc_guests for update to authenticated
using (public.jc_can_write(organization_id)) with check (public.jc_can_write(organization_id));

create policy jc_entries_read on public.jc_calendar_entries for select to authenticated
using (public.jc_is_member(organization_id));
create policy jc_entries_insert on public.jc_calendar_entries for insert to authenticated
with check (public.jc_can_write(organization_id));
create policy jc_entries_update on public.jc_calendar_entries for update to authenticated
using (public.jc_can_write(organization_id)) with check (public.jc_can_write(organization_id));

create policy jc_payments_read on public.jc_payments for select to authenticated
using (public.jc_is_member(organization_id));
create policy jc_payments_insert on public.jc_payments for insert to authenticated
with check (public.jc_can_write(organization_id));

create policy jc_audit_read on public.jc_audit_log for select to authenticated
using (public.jc_is_member(organization_id));

-- Explicit table grants; RLS still gates every row.
grant select on public.jc_organizations,public.jc_memberships,public.jc_audit_log to authenticated;
grant select,insert,update on public.jc_property_groups,public.jc_properties,public.jc_guests,public.jc_calendar_entries to authenticated;
grant select,insert on public.jc_payments to authenticated;
grant select on public.jc_reservations_with_balance to authenticated;
grant usage on schema public to authenticated;

-- No policy for direct deletes, cross-organization reads, or unauthenticated access.
-- Must be reviewed/tested in the dedicated JC database before production use.
