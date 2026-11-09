-- Órbita Zero: banco do modo online.
-- Como usar: Supabase → SQL Editor → New query → cole este arquivo inteiro → Run.
-- Pode rodar de novo sem problema: só cria o que ainda não existe e substitui a função.

-- Pilotos: o que aparece no ranking e nos duelos (público para leitura).
create table if not exists public.pilotos (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text unique not null check (nome ~ '^[A-Za-z0-9_]{3,16}$'),
  nave text not null default 'sucata' check (nave in ('sucata', 'faisca', 'ambar', 'vael')),
  nivel int not null default 1 check (nivel between 1 and 1000),
  abates int not null default 0 check (abates >= 0),
  poder int not null default 1 check (poder between 1 and 100000),      -- dano por segundo
  casco int not null default 150 check (casco between 1 and 1000000),
  escudo int not null default 80 check (escudo between 0 and 1000000),
  pontos int not null default 1000,                                     -- ranking de duelos: só a função duelar muda
  atualizado timestamptz not null default now()
);
alter table public.pilotos enable row level security;
drop policy if exists "ranking é público" on public.pilotos;
create policy "ranking é público" on public.pilotos for select using (true);
drop policy if exists "cria o próprio piloto" on public.pilotos;
create policy "cria o próprio piloto" on public.pilotos for insert to authenticated with check (auth.uid() = id);
drop policy if exists "atualiza o próprio piloto" on public.pilotos;
create policy "atualiza o próprio piloto" on public.pilotos for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
-- o jogador não escreve "pontos" direto, nem apaga linhas
revoke insert, update, delete on public.pilotos from anon, authenticated;
grant insert (id, nome, nave, nivel, abates, poder, casco, escudo) on public.pilotos to authenticated;
grant update (nave, nivel, abates, poder, casco, escudo, atualizado) on public.pilotos to authenticated;

-- Saves: o progresso completo de cada um (só o dono lê e escreve).
create table if not exists public.saves (
  id uuid primary key references auth.users(id) on delete cascade,
  dados jsonb not null check (pg_column_size(dados) < 100000),
  atualizado timestamptz not null default now()
);
alter table public.saves enable row level security;
drop policy if exists "dono lê o save" on public.saves;
create policy "dono lê o save" on public.saves for select to authenticated using (auth.uid() = id);
drop policy if exists "dono cria o save" on public.saves;
create policy "dono cria o save" on public.saves for insert to authenticated with check (auth.uid() = id);
drop policy if exists "dono atualiza o save" on public.saves;
create policy "dono atualiza o save" on public.saves for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
revoke delete on public.saves from anon, authenticated;

-- Duelos: histórico público; só a função abaixo grava.
create table if not exists public.duelos (
  id bigint generated always as identity primary key,
  atacante uuid not null references public.pilotos(id) on delete cascade,
  defensor uuid not null references public.pilotos(id) on delete cascade,
  venceu boolean not null,
  criado timestamptz not null default now()
);
alter table public.duelos enable row level security;
drop policy if exists "duelos são públicos" on public.duelos;
create policy "duelos são públicos" on public.duelos for select using (true);
revoke insert, update, delete on public.duelos from anon, authenticated;

-- O resultado é calculado aqui no servidor, com os atributos salvos dos dois pilotos.
-- Mesma conta da tela do jogo: quem derruba o outro primeiro vence; sorte de ±15% para quem desafia.
create or replace function public.duelar(defensor_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare
  a pilotos; d pilotos; t_a float; t_d float; v boolean; delta int := 20;
begin
  if auth.uid() is null then raise exception 'Entre na sua conta para duelar'; end if;
  if defensor_id = auth.uid() then raise exception 'Você não pode desafiar a si mesmo'; end if;
  select * into a from pilotos where id = auth.uid();
  select * into d from pilotos where id = defensor_id;
  if a.id is null or d.id is null then raise exception 'Piloto não encontrado'; end if;
  if exists (select 1 from duelos where atacante = a.id and defensor = d.id and criado > now() - interval '10 minutes') then
    raise exception 'Espere 10 minutos para desafiar este piloto de novo'; end if;
  if (select count(*) from duelos where atacante = a.id and criado > now() - interval '1 hour') >= 30 then
    raise exception 'Limite de 30 duelos por hora'; end if;
  t_a := (d.casco + d.escudo)::float / greatest(a.poder, 1) * (0.85 + random() * 0.3);   -- tempo para o atacante derrubar o defensor
  t_d := (a.casco + a.escudo)::float / greatest(d.poder, 1);                             -- tempo para o defensor derrubar o atacante
  v := t_a < t_d;
  insert into duelos (atacante, defensor, venceu) values (a.id, d.id, v);
  update pilotos set pontos = greatest(0, pontos + case when v then delta else -delta end) where id = a.id returning pontos into a.pontos;
  update pilotos set pontos = greatest(0, pontos + case when v then -delta / 2 else delta / 2 end) where id = d.id;
  return json_build_object('venceu', v, 'pontos', a.pontos, 'tempo', round(least(t_a, t_d)::numeric, 1));
end $$;
revoke all on function public.duelar(uuid) from public, anon;
grant execute on function public.duelar(uuid) to authenticated;
