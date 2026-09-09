-- AWG quote builder: shared quotes, learned matches, and curated substitutions.
create sequence if not exists public.awg_quote_number_seq start 1;

create table if not exists public.awg_quotes (
  id uuid primary key default gen_random_uuid(),
  quote_number text not null unique,
  customer_id uuid not null references public.customer_price_access(id),
  job_name text not null default '',
  salesperson text not null default '',
  delivery_location text not null default '',
  status text not null default 'draft' check (status in ('draft','sent','accepted','declined','expired')),
  quote_date date not null default current_date,
  expires_at date,
  notes text not null default '',
  subtotal numeric(12,2) not null default 0,
  delivery_charge numeric(12,2) not null default 0,
  miscellaneous_charge numeric(12,2) not null default 0,
  tax numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.awg_quote_lines (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references public.awg_quotes(id) on delete cascade,
  line_number integer not null,
  requested_text text not null default '',
  requested_size text not null default '',
  quantity integer not null default 1 check (quantity > 0),
  botanical_name text not null default '',
  common_name text not null default '',
  container_size text not null default '',
  available boolean not null default false,
  unit_price numeric(12,2) not null default 0,
  line_total numeric(12,2) not null default 0,
  match_type text not null default 'manual',
  match_confidence numeric(5,4),
  is_substitution boolean not null default false,
  substitution_note text not null default '',
  remember_match boolean not null default false,
  unique (quote_id,line_number)
);

create table if not exists public.awg_quote_match_memory (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customer_price_access(id) on delete cascade,
  source_normalized text not null,
  source_text text not null,
  requested_size text not null default '',
  target_botanical_name text not null,
  target_common_name text not null default '',
  target_container_size text not null,
  use_count integer not null default 1,
  last_used_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique(customer_id,source_normalized,requested_size)
);

create table if not exists public.awg_quote_substitutions (
  id uuid primary key default gen_random_uuid(),
  source_pattern text not null,
  source_normalized text not null,
  requested_size text not null default '',
  target_botanical_name text not null,
  target_common_name text not null default '',
  target_container_size text not null,
  priority integer not null default 100,
  reason text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(source_normalized,requested_size,target_botanical_name,target_common_name,target_container_size)
);

alter table public.awg_quotes enable row level security;
alter table public.awg_quote_lines enable row level security;
alter table public.awg_quote_match_memory enable row level security;
alter table public.awg_quote_substitutions enable row level security;
revoke all on public.awg_quotes, public.awg_quote_lines, public.awg_quote_match_memory, public.awg_quote_substitutions from anon, authenticated;
grant all on public.awg_quotes, public.awg_quote_lines, public.awg_quote_match_memory, public.awg_quote_substitutions to service_role;

insert into public.awg_quote_substitutions
  (source_pattern,source_normalized,requested_size,target_botanical_name,target_common_name,target_container_size,priority,reason)
values
  ('Desert Museum Palo Verde','desert museum palo verde','15 gallon','Cercidium hybrid','''Sonoran Emerald'' tm - Single trunk','15 gallon',10,'AWG preferred proprietary replacement'),
  ('Desert Museum Palo Verde','desert museum palo verde','15 gallon','Cercidium hybrid','''Sonoran Emerald'' tm  - Multi trunk','15 gallon',20,'AWG preferred proprietary replacement'),
  ('Desert Museum Palo Verde','desert museum palo verde','24 inch box','Cercidium hybrid','''Sonoran Emerald'' tm - Single trunk','24 inch box',10,'AWG preferred proprietary replacement'),
  ('Desert Museum Palo Verde','desert museum palo verde','24 inch box','Cercidium hybrid','''Sonoran Emerald'' tm  - Multi trunk','24 inch box',20,'AWG preferred proprietary replacement'),
  ('Desert Museum Palo Verde','desert museum palo verde','36 inch box','Cercidium hybrid','''Sonoran Emerald'' tm - Single trunk','36 inch box',10,'AWG preferred proprietary replacement'),
  ('Desert Museum Palo Verde','desert museum palo verde','36 inch box','Cercidium hybrid','''Sonoran Emerald'' tm  - Multi trunk','36 inch box',20,'AWG preferred proprietary replacement'),
  ('Desert Museum Palo Verde','desert museum palo verde','48 inch box','Cercidium hybrid','''Sonoran Emerald'' tm - Single trunk','48 inch box',10,'AWG preferred proprietary replacement'),
  ('Desert Museum Palo Verde','desert museum palo verde','48 inch box','Cercidium hybrid','''Sonoran Emerald'' tm  - Multi trunk','48 inch box',20,'AWG preferred proprietary replacement')
on conflict do nothing;

create or replace function public.get_awg_quote_workspace(p_code text)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_customer public.customer_price_access%rowtype; v_result jsonb;
begin
  select * into v_customer from public.customer_price_access c
  where c.active and (c.expires_at is null or c.expires_at>now())
    and c.customer_code_lookup=encode(extensions.digest(upper(btrim(p_code)),'sha256'),'hex')
    and c.customer_code_hash=extensions.crypt(upper(btrim(p_code)),c.customer_code_hash) limit 1;
  if v_customer.id is null then raise exception 'Invalid or expired customer code.'; end if;
  select jsonb_build_object(
    'customer',jsonb_build_object('id',v_customer.id,'name',v_customer.customer_name,'tier',v_customer.pricing_tier),
    'catalog',coalesce((select jsonb_agg(jsonb_build_object('botanical',p.botanical_name,'common',p.common_name,'size',p.container_size,'price',case v_customer.pricing_tier when 'tier_2' then p.tier_2_price when 'tier_3' then p.tier_3_price else p.list_price end) order by p.botanical_name,p.common_name,p.container_size) from public.price_catalog p where p.active),'[]'::jsonb),
    'availability',coalesce((select jsonb_agg(jsonb_build_object('botanical',x.botanical_name,'common',x.common_name,'size',x.container_size,'ready',x.ready_count)) from (select botanical_name,common_name,container_size,sum(ready_count)::int ready_count from public.customer_availability_snapshots group by 1,2,3) x),'[]'::jsonb),
    'memory',coalesce((select jsonb_agg(to_jsonb(m)-'customer_id') from public.awg_quote_match_memory m where m.customer_id=v_customer.id),'[]'::jsonb),
    'substitutions',coalesce((select jsonb_agg(to_jsonb(s) order by s.priority) from public.awg_quote_substitutions s where s.active),'[]'::jsonb),
    'quotes',coalesce((select jsonb_agg(jsonb_build_object('id',q.id,'number',q.quote_number,'job',q.job_name,'date',q.quote_date,'status',q.status,'total',q.total) order by q.updated_at desc) from public.awg_quotes q where q.customer_id=v_customer.id),'[]'::jsonb)
  ) into v_result;
  return v_result;
end $$;

create or replace function public.save_awg_quote(p_code text,p_quote jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_customer public.customer_price_access%rowtype; v_id uuid; v_number text; v_line jsonb; v_n int:=0; v_source text;
begin
  select * into v_customer from public.customer_price_access c
  where c.active and (c.expires_at is null or c.expires_at>now())
    and c.customer_code_lookup=encode(extensions.digest(upper(btrim(p_code)),'sha256'),'hex')
    and c.customer_code_hash=extensions.crypt(upper(btrim(p_code)),c.customer_code_hash) limit 1;
  if v_customer.id is null then raise exception 'Invalid or expired customer code.'; end if;
  begin v_id=nullif(p_quote->>'id','')::uuid; exception when others then v_id:=null; end;
  if v_id is not null and not exists(select 1 from public.awg_quotes where id=v_id and customer_id=v_customer.id) then raise exception 'Quote not found.'; end if;
  if v_id is null then
    v_number:='AWG-'||extract(year from current_date)::int||'-'||lpad(nextval('public.awg_quote_number_seq')::text,6,'0');
    insert into public.awg_quotes(quote_number,customer_id) values(v_number,v_customer.id) returning id into v_id;
  end if;
  update public.awg_quotes set job_name=left(coalesce(p_quote->>'job_name',''),200),salesperson=left(coalesce(p_quote->>'salesperson',''),120),delivery_location=left(coalesce(p_quote->>'delivery_location',''),300),status=case when p_quote->>'status' in ('draft','sent','accepted','declined','expired') then p_quote->>'status' else 'draft' end,quote_date=coalesce(nullif(p_quote->>'quote_date','')::date,current_date),expires_at=nullif(p_quote->>'expires_at','')::date,notes=left(coalesce(p_quote->>'notes',''),4000),subtotal=coalesce((p_quote->>'subtotal')::numeric,0),delivery_charge=coalesce((p_quote->>'delivery_charge')::numeric,0),miscellaneous_charge=coalesce((p_quote->>'miscellaneous_charge')::numeric,0),tax=coalesce((p_quote->>'tax')::numeric,0),total=coalesce((p_quote->>'total')::numeric,0),updated_at=now() where id=v_id;
  delete from public.awg_quote_lines where quote_id=v_id;
  for v_line in select value from jsonb_array_elements(coalesce(p_quote->'lines','[]'::jsonb)) loop
    v_n:=v_n+1;
    insert into public.awg_quote_lines(quote_id,line_number,requested_text,requested_size,quantity,botanical_name,common_name,container_size,available,unit_price,line_total,match_type,match_confidence,is_substitution,substitution_note,remember_match)
    values(v_id,v_n,left(coalesce(v_line->>'requested_text',''),500),left(coalesce(v_line->>'requested_size',''),80),greatest(1,coalesce((v_line->>'quantity')::int,1)),left(coalesce(v_line->>'botanical_name',''),300),left(coalesce(v_line->>'common_name',''),300),left(coalesce(v_line->>'container_size',''),80),coalesce((v_line->>'available')::boolean,false),coalesce((v_line->>'unit_price')::numeric,0),coalesce((v_line->>'line_total')::numeric,0),left(coalesce(v_line->>'match_type','manual'),40),nullif(v_line->>'match_confidence','')::numeric,coalesce((v_line->>'is_substitution')::boolean,false),left(coalesce(v_line->>'substitution_note',''),500),coalesce((v_line->>'remember_match')::boolean,false));
    if coalesce((v_line->>'remember_match')::boolean,false) and coalesce(v_line->>'botanical_name','')<>'' then
      v_source=lower(regexp_replace(coalesce(v_line->>'requested_text',''),'[^a-zA-Z0-9]+',' ','g'));
      insert into public.awg_quote_match_memory(customer_id,source_normalized,source_text,requested_size,target_botanical_name,target_common_name,target_container_size)
      values(v_customer.id,btrim(v_source),left(v_line->>'requested_text',500),coalesce(v_line->>'requested_size',''),v_line->>'botanical_name',coalesce(v_line->>'common_name',''),v_line->>'container_size')
      on conflict(customer_id,source_normalized,requested_size) do update set target_botanical_name=excluded.target_botanical_name,target_common_name=excluded.target_common_name,target_container_size=excluded.target_container_size,use_count=public.awg_quote_match_memory.use_count+1,last_used_at=now();
    end if;
  end loop;
  select quote_number into v_number from public.awg_quotes where id=v_id;
  return jsonb_build_object('id',v_id,'quote_number',v_number);
end $$;

create or replace function public.get_awg_quote(p_code text,p_quote_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_customer_id uuid; v_result jsonb;
begin
  select customer_id into v_customer_id from public.validate_customer_price_code(p_code);
  if v_customer_id is null then raise exception 'Invalid or expired customer code.'; end if;
  select to_jsonb(q)||jsonb_build_object('lines',coalesce((select jsonb_agg(to_jsonb(l) order by l.line_number) from public.awg_quote_lines l where l.quote_id=q.id),'[]'::jsonb)) into v_result from public.awg_quotes q where q.id=p_quote_id and q.customer_id=v_customer_id;
  if v_result is null then raise exception 'Quote not found.'; end if;
  return v_result;
end $$;

revoke all on function public.get_awg_quote_workspace(text) from public;
revoke all on function public.save_awg_quote(text,jsonb) from public;
revoke all on function public.get_awg_quote(text,uuid) from public;
grant execute on function public.get_awg_quote_workspace(text),public.save_awg_quote(text,jsonb),public.get_awg_quote(text,uuid) to anon,authenticated,service_role;
