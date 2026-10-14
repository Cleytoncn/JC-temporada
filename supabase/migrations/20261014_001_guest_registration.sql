-- JC Temporada: dados completos do hóspede exigidos na interface para novos cadastros.
-- Novas colunas são nullable para preservar os hóspedes existentes.
begin;
alter table public.jc_guests
  add column if not exists rg text,
  add column if not exists cpf text,
  add column if not exists address text,
  add column if not exists postal_code text,
  add column if not exists city text,
  add column if not exists neighborhood text,
  add column if not exists birth_date date;
create unique index if not exists jc_guests_organization_cpf_uq
  on public.jc_guests (organization_id,cpf) where cpf is not null;
comment on column public.jc_guests.cpf is 'CPF normalizado para 11 dígitos, restrito por RLS à organização.';
comment on column public.jc_guests.postal_code is 'CEP normalizado para 8 dígitos.';
commit;
