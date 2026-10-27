-- ============================================================================
--  GENERAL DISTRIBUTION - la base de datos completa, desde cero
--
--  Se pega TAL CUAL en: Supabase -> SQL Editor -> New query -> Run.
--  Levanta el sistema entero en un proyecto nuevo y vacio.
--
--  NO CONTIENE NI UN DATO: ni clientes, ni precios, ni pedidos. Solo la
--  estructura. El catalogo se llena despues desde QuickBooks, con el boton
--  del panel.
--
--  ANTES DE CORRERLO, comprueba que estas en TU proyecto de Supabase.
--
--  Generado el 20 de octubre de 2026 desde el proyecto donde el sistema
--  corre hoy. Cada bloque se comprobo caracter por caracter (md5) contra
--  la base: no es una transcripcion a mano.
--
--  Que lleva:
--    9 tablas    gd_productos gd_tiendas gd_pedidos gd_pedido_lineas
--                gd_pedido_historial gd_inventario_mov gd_precio_tienda
--                gd_perfiles gd_qb_import  (+ gd_qb_conexion y su estado)
--    2 vistas    gd_catalogo  gd_tienda_publica
--    1 bucket    gd-fotos
--
--  Las funciones del refresh van en su VERSION FINAL, la que corre hoy:
--  trae dentro los cinco arreglos que costaron encontrar (ver el Skill,
--  errores-ya-pagados.md). No se incluyen las versiones intermedias
--  porque se sobrescriben entre si y no aportan nada a una instalacion
--  nueva.
-- ============================================================================


-- --------------------------------------------------------------------------
--  Los pedidos
-- --------------------------------------------------------------------------
-- General Distribution (el negocio del hermano de Maria). Prefijo gd_.
-- Vive en jema-app porque el plan gratis de Supabase solo deja 2 proyectos activos.

create table if not exists public.gd_pedidos (
  id          uuid primary key,                      -- lo genera el telefono, para no depender de leer de vuelta
  folio       bigint generated always as identity,
  tienda      text        not null,
  nota        text,
  articulos   integer     not null default 0,
  total       numeric(10,2) not null default 0,
  es_prueba   boolean     not null default false,    -- nada se borra: lo de prueba se marca
  creado      timestamptz not null default now()
);
comment on table public.gd_pedidos is 'Pedidos levantados en tienda con la app de General Distribution.';

create table if not exists public.gd_pedido_lineas (
  id          uuid primary key,
  pedido_id   uuid        not null references public.gd_pedidos(id) on delete cascade,
  producto_id text        not null,                  -- id del producto en Shopify
  producto    text        not null,                  -- nombre congelado al momento del pedido
  categoria   text,
  precio      numeric(10,2) not null default 0,      -- precio congelado: el de Shopify puede cambiar despues
  cantidad    integer     not null check (cantidad > 0),
  importe     numeric(10,2) not null default 0
);
comment on table public.gd_pedido_lineas is 'Renglones del pedido. Nombre y precio quedan congelados como estaban ese dia.';

create index if not exists gd_pedidos_creado_idx  on public.gd_pedidos (creado desc);
create index if not exists gd_pedidos_tienda_idx  on public.gd_pedidos (tienda);
create index if not exists gd_lineas_pedido_idx   on public.gd_pedido_lineas (pedido_id);
create index if not exists gd_lineas_producto_idx on public.gd_pedido_lineas (producto_id);

alter table public.gd_pedidos       enable row level security;
alter table public.gd_pedido_lineas enable row level security;

-- La app solo PUEDE ESCRIBIR. No hay permiso de lectura para el publico:
-- si alguien consigue la llave publica, puede mandar un pedido, pero NO puede
-- leer los pedidos ni los precios de nadie.
drop policy if exists gd_pedidos_insert_anon on public.gd_pedidos;
create policy gd_pedidos_insert_anon
  on public.gd_pedidos for insert to anon, authenticated with check (true);

drop policy if exists gd_lineas_insert_anon on public.gd_pedido_lineas;
create policy gd_lineas_insert_anon
  on public.gd_pedido_lineas for insert to anon, authenticated with check (true);

-- --------------------------------------------------------------------------
--  Quien puede entrar al panel
-- --------------------------------------------------------------------------
-- El gafete de General Distribution. Mismo patron que pin_perfiles y ops_perfiles.
create table if not exists public.gd_perfiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  nombre     text,
  email      text,
  rol        text        not null default 'vendedor',   -- 'dueno' ve todo; 'vendedor' tambien, por ahora
  activo     boolean     not null default true,         -- nunca se borra a nadie: se apaga
  creado_en  timestamptz not null default now()
);
comment on table public.gd_perfiles is 'Quien puede entrar al panel de General Distribution. No se borra a nadie: activo=false.';

-- Solo le hace gafete a las cuentas que nacieron PARA esta app (app='gd').
-- Sin valor por omision, para que ninguna cuenta vieja de las otras apps caiga aqui.
create or replace function public.gd_nuevo_usuario()
returns trigger
language plpgsql
security definer
set search_path to 'public','auth'
as $$
declare v_rol text;
begin
  if coalesce(new.raw_user_meta_data->>'app','') <> 'gd' then
    return new;
  end if;
  -- El primero que entra es el dueno; los demas nacen vendedores.
  if not exists (select 1 from gd_perfiles) then v_rol := 'dueno'; else v_rol := 'vendedor'; end if;
  insert into gd_perfiles (id, nombre, email, rol)
  values (new.id,
          coalesce(nullif(new.raw_user_meta_data->>'nombre',''), split_part(new.email,'@',1)),
          new.email, v_rol)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists gd_on_auth_user_created on auth.users;
create trigger gd_on_auth_user_created
  after insert on auth.users
  for each row execute function public.gd_nuevo_usuario();

alter table public.gd_perfiles enable row level security;

drop policy if exists gd_perfiles_lee_lo_suyo on public.gd_perfiles;
create policy gd_perfiles_lee_lo_suyo
  on public.gd_perfiles for select to authenticated
  using (id = auth.uid());

-- LEER los pedidos: solo quien tiene gafete activo de General Distribution.
-- El publico (anon) sigue sin poder leer nada; solo escribir.
drop policy if exists gd_pedidos_select_equipo on public.gd_pedidos;
create policy gd_pedidos_select_equipo
  on public.gd_pedidos for select to authenticated
  using (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo));

drop policy if exists gd_lineas_select_equipo on public.gd_pedido_lineas;
create policy gd_lineas_select_equipo
  on public.gd_pedido_lineas for select to authenticated
  using (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo));

-- --------------------------------------------------------------------------
--  El dueno administra a su equipo
-- --------------------------------------------------------------------------
-- Funcion aparte para preguntar "¿es dueno?" sin que la politica se muerda la cola.
-- (Una politica sobre gd_perfiles que consulte gd_perfiles entra en recursion infinita.)
create or replace function public.gd_es_dueno()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from public.gd_perfiles
    where id = auth.uid() and activo and rol = 'dueno'
  );
$$;

-- El dueno ve a todo su equipo; cada quien se ve a si mismo.
drop policy if exists gd_perfiles_lee_lo_suyo on public.gd_perfiles;
create policy gd_perfiles_lectura
  on public.gd_perfiles for select to authenticated
  using (id = auth.uid() or public.gd_es_dueno());

-- El dueno puede prender y apagar gente, y cambiarle el rol. NUNCA borrar.
drop policy if exists gd_perfiles_dueno_actualiza on public.gd_perfiles;
create policy gd_perfiles_dueno_actualiza
  on public.gd_perfiles for update to authenticated
  using (public.gd_es_dueno())
  with check (public.gd_es_dueno());

-- A proposito NO hay politica de DELETE: nadie puede borrar a nadie desde la app.

-- --------------------------------------------------------------------------
--  Productos, tiendas e inventario
-- --------------------------------------------------------------------------
-- ============================================================
--  PRODUCTOS. El catalogo deja de vivir dentro del HTML y pasa a la base,
--  para que Manuel pueda crear y editar productos desde la app.
--  QuickBooks manda en precio (decision de Manuel, 11-oct-2026).
-- ============================================================
create table if not exists public.gd_productos (
  id          uuid primary key default gen_random_uuid(),
  nombre      text        not null,
  descripcion text,
  sku         text,                                   -- de QuickBooks
  upc         text,                                   -- codigo de barras, para escanear
  categoria   text,
  precio      numeric(10,2) not null default 0,
  foto        text,                                   -- direccion de la imagen
  existencia  integer     not null default 0,         -- la lleva el disparador, NO se edita a mano
  activo      boolean     not null default true,      -- nada se borra: se desactiva
  origen      text        not null default 'manual',  -- 'shopify' | 'quickbooks' | 'manual'
  shopify_id  text,
  qb_id       text,
  creado      timestamptz not null default now(),
  actualizado timestamptz not null default now()
);
comment on column public.gd_productos.existencia is
  'Lo calcula el disparador desde gd_inventario_mov. Nunca se escribe a mano.';

create index if not exists gd_prod_nombre_idx on public.gd_productos (lower(nombre));
create index if not exists gd_prod_upc_idx    on public.gd_productos (upc) where upc is not null;
create index if not exists gd_prod_sku_idx    on public.gd_productos (sku) where sku is not null;
create unique index if not exists gd_prod_shopify_idx on public.gd_productos (shopify_id) where shopify_id is not null;

-- ============================================================
--  MOVIMIENTOS DE INVENTARIO. Aqui vive la verdad; la existencia es su resultado.
--  Nada se borra: un error se corrige con otro movimiento.
-- ============================================================
create table if not exists public.gd_inventario_mov (
  id          uuid primary key default gen_random_uuid(),
  producto_id uuid        not null references public.gd_productos(id),
  tipo        text        not null check (tipo in ('entrada','salida','ajuste')),
  cantidad    integer     not null check (cantidad <> 0),  -- con signo: +entra, -sale
  motivo      text        not null,                        -- 'recepcion' | 'pedido' | 'conteo' | 'merma'
  referencia  text,                                        -- folio del pedido, numero de recepcion
  nota        text,
  usuario_id  uuid,
  creado      timestamptz not null default now()
);
create index if not exists gd_mov_prod_idx on public.gd_inventario_mov (producto_id, creado desc);

-- La existencia SIEMPRE cuadra con la suma de los movimientos.
create or replace function public.gd_aplica_movimiento()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  update public.gd_productos
     set existencia = existencia + new.cantidad,
         actualizado = now()
   where id = new.producto_id;
  return new;
end $$;

drop trigger if exists gd_mov_aplica on public.gd_inventario_mov;
create trigger gd_mov_aplica after insert on public.gd_inventario_mov
  for each row execute function public.gd_aplica_movimiento();

-- ============================================================
--  TIENDAS. Cada una con su codigo, que es lo que va en su link.
--  Asi el tendero ya no escribe el nombre a mano.
-- ============================================================
create table if not exists public.gd_tiendas (
  id         uuid primary key default gen_random_uuid(),
  codigo     text        not null unique,     -- va en el link: ?t=lapl4x
  nombre     text        not null,
  ruta       text,                            -- 'Colorado', 'Utah', 'Idaho'...
  direccion  text,
  ciudad     text,
  estado     text,
  telefono   text,
  contacto   text,
  qb_id      text,                            -- cliente de QuickBooks, cuando se importe
  revisar    boolean     not null default false, -- nombre dudoso que hay que confirmar
  activo     boolean     not null default true,
  notas      text,
  creado     timestamptz not null default now()
);
create index if not exists gd_tiendas_ruta_idx on public.gd_tiendas (ruta, nombre);

-- Los pedidos se amarran a la tienda, SIN perder el texto viejo.
alter table public.gd_pedidos add column if not exists tienda_id uuid references public.gd_tiendas(id);
create index if not exists gd_pedidos_tienda_id_idx on public.gd_pedidos (tienda_id);

-- ============================================================
--  QUIEN VE QUE
-- ============================================================
alter table public.gd_productos      enable row level security;
alter table public.gd_inventario_mov enable row level security;
alter table public.gd_tiendas        enable row level security;

-- El equipo con gafete activo administra todo.
drop policy if exists gd_prod_equipo on public.gd_productos;
create policy gd_prod_equipo on public.gd_productos for all to authenticated
  using (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo))
  with check (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo));

drop policy if exists gd_mov_equipo on public.gd_inventario_mov;
create policy gd_mov_equipo on public.gd_inventario_mov for all to authenticated
  using (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo))
  with check (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo));

drop policy if exists gd_tiendas_equipo on public.gd_tiendas;
create policy gd_tiendas_equipo on public.gd_tiendas for all to authenticated
  using (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo))
  with check (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo));

-- ============================================================
--  LO QUE EL PUBLICO SI PUEDE VER: solo el catalogo y el nombre de su tienda.
--  Por VISTAS, para que NUNCA se asome la existencia ni los datos del cliente.
-- ============================================================
create or replace view public.gd_catalogo
with (security_invoker = false) as
  select id, nombre, descripcion, categoria, precio, foto, upc
  from public.gd_productos
  where activo;
comment on view public.gd_catalogo is 'Lo que ve el tendero. A proposito NO trae existencia ni costos.';

create or replace view public.gd_tienda_publica
with (security_invoker = false) as
  select codigo, nombre, ruta
  from public.gd_tiendas
  where activo;
comment on view public.gd_tienda_publica is 'Solo para que el link ?t=codigo sepa de que tienda es.';

grant select on public.gd_catalogo       to anon, authenticated;
grant select on public.gd_tienda_publica to anon, authenticated;

-- --------------------------------------------------------------------------
--  Permitir que la base traiga datos de fuera
-- --------------------------------------------------------------------------
-- Permite que la base traiga el catalogo publico de Shopify por si misma.
-- Asi no hay que abrir ningun permiso de escritura al publico.
create extension if not exists http with schema extensions;

-- --------------------------------------------------------------------------
--  La vista de la tienda, con su id
-- --------------------------------------------------------------------------
drop view if exists public.gd_tienda_publica;
create view public.gd_tienda_publica
with (security_invoker = false) as
  select id, codigo, nombre, ruta
  from public.gd_tiendas
  where activo;
comment on view public.gd_tienda_publica is
  'Solo para que el link ?t=codigo sepa de que tienda es. No expone direccion, telefono ni contacto.';
grant select on public.gd_tienda_publica to anon, authenticated;

-- --------------------------------------------------------------------------
--  Los estados del pedido
-- --------------------------------------------------------------------------
-- El camino del pedido, tal como lo describio Manuel en su documento (seccion 22),
-- pero solo con los pasos que YA se pueden dar sin escaner.
-- Picking e invoice entran despues, cuando lleguen los lectores.

alter table public.gd_pedidos
  add column if not exists estado text not null default 'nuevo';

alter table public.gd_pedidos
  drop constraint if exists gd_pedidos_estado_ok;
alter table public.gd_pedidos
  add constraint gd_pedidos_estado_ok check (estado in
    ('nuevo','preparado','en_camino','entregado','pagado','cancelado'));

comment on column public.gd_pedidos.estado is
  'nuevo -> preparado -> en_camino -> entregado -> pagado. cancelado es salida lateral.';

-- Cuando cambia de estado, queda la huella: quien y cuando. Nada se pisa.
create table if not exists public.gd_pedido_historial (
  id         uuid primary key default gen_random_uuid(),
  pedido_id  uuid        not null references public.gd_pedidos(id),
  estado     text        not null,
  nota       text,
  usuario_id uuid,
  creado     timestamptz not null default now()
);
create index if not exists gd_hist_pedido_idx on public.gd_pedido_historial (pedido_id, creado desc);

alter table public.gd_pedido_historial enable row level security;

drop policy if exists gd_hist_equipo on public.gd_pedido_historial;
create policy gd_hist_equipo on public.gd_pedido_historial for all to authenticated
  using (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo))
  with check (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo));

-- El equipo puede mover el estado de un pedido; el publico NO (solo escribe pedidos nuevos).
drop policy if exists gd_pedidos_update_equipo on public.gd_pedidos;
create policy gd_pedidos_update_equipo
  on public.gd_pedidos for update to authenticated
  using (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo))
  with check (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo));

-- Cada cambio de estado se anota solo.
create or replace function public.gd_anota_estado()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.estado is distinct from old.estado then
    insert into public.gd_pedido_historial (pedido_id, estado, usuario_id)
    values (new.id, new.estado, auth.uid());
  end if;
  return new;
end $$;

drop trigger if exists gd_pedidos_anota_estado on public.gd_pedidos;
create trigger gd_pedidos_anota_estado after update on public.gd_pedidos
  for each row execute function public.gd_anota_estado();

-- --------------------------------------------------------------------------
--  La mesa de trabajo de QuickBooks
-- --------------------------------------------------------------------------
-- Mesa de trabajo donde se deja la exportacion de QuickBooks antes de aplicarla.
-- Nunca es la fuente de verdad: se vacia y se vuelve a llenar en cada refresh.
create table if not exists public.gd_qb_import (
  nombre     text not null,
  codigo     text,            -- el SKU de QuickBooks, SOLO si parece codigo de barras
  sku_crudo  text,            -- lo que venia en la columna SKU, tal cual
  categoria  text,
  precio     numeric,
  costo      numeric,
  cantidad   integer,
  cargado    timestamptz not null default now()
);

alter table public.gd_qb_import enable row level security;
revoke all on public.gd_qb_import from anon, authenticated;

-- Normaliza un nombre para comparar: sin acentos, sin dobles espacios, en minusculas.
create or replace function public.gd_norm(t text)
returns text language sql immutable as $$
  select nullif(regexp_replace(lower(translate(coalesce(t,''),
           'áéíóúàèìòùäëïöüâêîôûñÑÁÉÍÓÚÜ','aeiouaeiouaeiouaeiounnaeiouu')),
         '\s+', ' ', 'g'), '')
$$;

create index if not exists gd_productos_norm_idx on public.gd_productos (public.gd_norm(nombre));
create index if not exists gd_qb_import_codigo_idx on public.gd_qb_import (codigo);

-- --------------------------------------------------------------------------
--  La conexion con QuickBooks
-- --------------------------------------------------------------------------
-- ============================================================
--  La conexion con QuickBooks (API de Intuit)
--
--  Nadie llega a estas dos tablas desde la app ni desde el panel:
--  RLS prendida, todo revocado, y las toca SOLO la funcion de
--  servidor gd-quickbooks con la llave de servicio.
--
--  Lo que el panel si puede ver va por gd_qb_estado_conexion(),
--  que a proposito NO devuelve ningun token.
-- ============================================================

create table if not exists public.gd_qb_conexion (
  id             integer primary key default 1 check (id = 1),
  realm_id       text not null,            -- la empresa de QuickBooks
  refresh_token  text not null,            -- dura 100 dias y ROTA en cada uso
  access_token   text,
  access_vence   timestamptz,
  entorno        text not null default 'produccion',
  conectado_por  uuid,
  conectado_el   timestamptz not null default now(),
  ultimo_refresh timestamptz,
  ultimo_error   text
);

-- El 'state' del vaiven de OAuth: de un solo uso y de vida corta.
-- Sin esto, cualquiera que adivine la direccion de la funcion podria
-- colgarle a Manuel una empresa de QuickBooks que no es la suya.
create table if not exists public.gd_qb_oauth_estado (
  estado  text primary key,
  usuario uuid not null,
  creado  timestamptz not null default now(),
  usado   boolean not null default false
);

alter table public.gd_qb_conexion     enable row level security;
alter table public.gd_qb_oauth_estado enable row level security;
revoke all on public.gd_qb_conexion     from anon, authenticated;
revoke all on public.gd_qb_oauth_estado from anon, authenticated;

-- Lo que el dueno puede saber de la conexion: si existe y de cuando es.
-- Ningun token sale de aqui.
create or replace function public.gd_qb_estado_conexion()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rol text;
  v_c   public.gd_qb_conexion;
begin
  select rol into v_rol from public.gd_perfiles where id = auth.uid() and activo;
  if v_rol is distinct from 'dueno' then
    raise exception 'Solo el dueno puede ver la conexion con QuickBooks';
  end if;

  select * into v_c from public.gd_qb_conexion where id = 1;
  if v_c.realm_id is null then
    return jsonb_build_object('conectado', false);
  end if;

  return jsonb_build_object(
    'conectado',      true,
    'empresa',        v_c.realm_id,
    'entorno',        v_c.entorno,
    'conectado_el',   v_c.conectado_el,
    'ultimo_refresh', v_c.ultimo_refresh,
    'ultimo_error',   v_c.ultimo_error,
    -- El refresh token de Intuit muere a los 100 dias de no usarse.
    'dias_para_caducar',
      greatest(0, 100 - extract(day from now() - coalesce(v_c.ultimo_refresh, v_c.conectado_el))::integer)
  );
end $$;

revoke all on function public.gd_qb_estado_conexion() from anon;
grant execute on function public.gd_qb_estado_conexion() to authenticated;

-- --------------------------------------------------------------------------
--  Por que se apago un producto
-- --------------------------------------------------------------------------
-- Por que se apago un producto. Sale de la nota del cerebro colectivo
-- "el-upsert-es-un-trinquete": lo que desaparece del origen no se borra,
-- se apaga CON LA RAZON ESCRITA. Sin eso no hay como auditar la diferencia.
alter table public.gd_productos add column if not exists apagado_motivo text;
alter table public.gd_productos add column if not exists apagado_el timestamptz;

create or replace function public.gd_qb_aplicar(p_de_verdad boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rol text;
  v_act integer := 0;
  v_nue integer := 0;
  v_apa integer := 0;
  v_res jsonb;
begin
  select rol into v_rol from public.gd_perfiles where id = auth.uid() and activo;
  if v_rol is distinct from 'dueno' then
    raise exception 'Solo el dueno puede refrescar el catalogo';
  end if;

  create temp table qb on commit drop as
    select distinct on (coalesce(codigo, gd_norm(nombre)))
           nombre, codigo, categoria, precio, cantidad,
           coalesce(codigo, gd_norm(nombre)) as llave
      from public.gd_qb_import
     order by coalesce(codigo, gd_norm(nombre)), cantidad desc nulls last;

  create temp table par on commit drop as
    select q.llave, q.nombre, q.categoria, q.precio, p.id
      from qb q
      join public.gd_productos p
        on (q.codigo is not null and p.upc = q.codigo)
        or (q.codigo is null and gd_norm(p.nombre) = gd_norm(q.nombre));

  select count(distinct id) into v_act from par;
  select count(*) into v_nue from qb where llave not in (select llave from par);
  select count(*) into v_apa from public.gd_productos
   where activo and id not in (select id from par);

  v_res := jsonb_build_object(
    'de_verdad',     p_de_verdad,
    'en_quickbooks', (select count(*) from qb),
    'actualizados',  v_act,
    'nuevos',        v_nue,
    'revividos',     (select count(*) from public.gd_productos
                       where not activo and id in (select id from par)),
    'se_apagan',     v_apa,
    'se_apagan_con_mercancia',
      (select count(*) from public.gd_productos
        where activo and existencia <> 0 and id not in (select id from par)),
    'piezas_que_se_apagan',
      (select coalesce(sum(existencia),0) from public.gd_productos
        where activo and existencia > 0 and id not in (select id from par)),
    'se_apagan_ya_pedidos',
      (select count(distinct p.id) from public.gd_productos p
        where p.activo and p.id not in (select id from par)
          and exists (select 1 from public.gd_pedido_lineas l
                       where l.producto_id = p.id::text
                          or gd_norm(l.producto) = gd_norm(p.nombre)))
  );

  if not p_de_verdad then
    return v_res || jsonb_build_object('nota','ENSAYO: no se toco nada');
  end if;

  update public.gd_productos p
     set nombre      = par.nombre,
         categoria   = coalesce(par.categoria, p.categoria),
         precio      = coalesce(par.precio, p.precio),
         activo      = true,
         origen      = 'quickbooks',
         apagado_motivo = null,
         apagado_el     = null,
         actualizado = now()
    from par
   where p.id = par.id;

  insert into public.gd_productos (nombre, upc, categoria, precio, existencia, activo, origen)
  select q.nombre, q.codigo, q.categoria, coalesce(q.precio,0), 0, true, 'quickbooks'
    from qb q where q.llave not in (select llave from par);

  update public.gd_productos
     set activo = false,
         apagado_motivo = 'Ya no venia en la exportacion de QuickBooks',
         apagado_el = now(),
         actualizado = now()
   where activo and id not in (select id from par);

  return v_res;
end $$;

revoke all on function public.gd_qb_aplicar(boolean) from anon;
grant execute on function public.gd_qb_aplicar(boolean) to authenticated;

-- --------------------------------------------------------------------------
--  Las dos columnas que faltan
-- --------------------------------------------------------------------------
-- Dos columnas que el refresh final necesita. Vienen de dos arreglos:
--   fusionado_en  -> un duplicado ya limpiado no revive en el siguiente refresh
--   precio_fijo   -> el candado: QuickBooks no pisa un precio puesto a mano
alter table public.gd_productos add column if not exists fusionado_en uuid;
alter table public.gd_productos add column if not exists precio_fijo boolean not null default false;

-- --------------------------------------------------------------------------
--  El precio de cada tienda
-- --------------------------------------------------------------------------
-- ============================================================
--  EL PRECIO DE CADA TIENDA
--
--  Manuel: "cuando este vendiendo yo tenga la opcion de cambiar el
--  precio y poner un candado para que no se vaya a QuickBooks, pero
--  guardarlo para cuando la proxima semana visite al cliente".
--
--  El candado sale solo: estos precios viven en SU PROPIA TABLA, y
--  gd_qb_aplicar solo toca gd_productos. QuickBooks no los ve ni los
--  puede pisar, pase lo que pase.
--
--  De donde sale el precio de una tienda, en este orden:
--    1. El que el dueno le puso a proposito        (gd_precio_tienda)
--    2. El ultimo que de verdad se le cobro         (de sus pedidos)
--    3. El del catalogo                             (QuickBooks)
-- ============================================================

create table if not exists public.gd_precio_tienda (
  tienda_id   uuid not null references public.gd_tiendas(id) on delete cascade,
  producto_id uuid not null references public.gd_productos(id) on delete cascade,
  precio      numeric(12,2) not null check (precio >= 0),
  nota        text,
  puesto_por  uuid,
  creado      timestamptz not null default now(),
  actualizado timestamptz not null default now(),
  primary key (tienda_id, producto_id)
);

create index if not exists gd_precio_tienda_idx on public.gd_precio_tienda (tienda_id);

alter table public.gd_precio_tienda enable row level security;
revoke all on public.gd_precio_tienda from anon;

drop policy if exists gd_precio_tienda_equipo on public.gd_precio_tienda;
create policy gd_precio_tienda_equipo on public.gd_precio_tienda
  for all to authenticated
  using     (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo))
  with check (exists (select 1 from public.gd_perfiles p where p.id = auth.uid() and p.activo));

-- Los precios de UNA tienda, para la app de pedidos.
-- La app no tiene sesion: entra con el codigo que trae su propio link,
-- el mismo con el que ya ve su nombre. No expone nada de otras tiendas.
create or replace function public.gd_precios_de_la_tienda(p_codigo text)
returns table (producto_id uuid, precio numeric, de_donde text)
language sql stable security definer set search_path = public as $$
  with t as (
    select id from public.gd_tiendas
     where activo and lower(codigo) = lower(trim(p_codigo))
  ),
  -- 2. lo ultimo que de verdad se le cobro
  historico as (
    select distinct on (pr.id) pr.id as producto_id, l.precio
      from t
      join public.gd_pedidos d   on d.tienda_id = t.id
                                and d.estado is distinct from 'cancelado'
                                and not coalesce(d.es_prueba, false)
      join public.gd_pedido_lineas l on l.pedido_id = d.id
      join public.gd_productos pr on pr.id::text = l.producto_id
                                  or gd_norm(pr.nombre) = gd_norm(l.producto)
     where pr.activo
     order by pr.id, d.creado desc
  ),
  -- 1. lo que el dueno le puso a proposito (manda sobre lo anterior)
  puesto as (
    select pt.producto_id, pt.precio
      from t join public.gd_precio_tienda pt on pt.tienda_id = t.id
  )
  select coalesce(p.producto_id, h.producto_id) as producto_id,
         coalesce(p.precio, h.precio)           as precio,
         case when p.producto_id is not null then 'puesto a proposito'
              else 'ultimo que se le cobro' end as de_donde
    from puesto p
    full outer join historico h on h.producto_id = p.producto_id;
$$;

revoke all on function public.gd_precios_de_la_tienda(text) from public;
grant execute on function public.gd_precios_de_la_tienda(text) to anon, authenticated;

-- --------------------------------------------------------------------------
--  Cargar la exportacion de QuickBooks
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gd_qb_cargar(p_lineas text, p_primera boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rol text;
  v_n   integer;
begin
  select rol into v_rol from public.gd_perfiles where id = auth.uid() and activo;
  if v_rol is distinct from 'dueno' then
    raise exception 'Solo el dueno puede refrescar el catalogo';
  end if;

  if p_primera then
    delete from public.gd_qb_import where true;  -- el WHERE lo exige pg_safeupdate en proyectos nuevos
  end if;

  with r as (
    select trim(l) as l from unnest(string_to_array(p_lineas, chr(10))) l
  ), p as (
    select split_part(l,'|',1) as nombre,
           nullif(split_part(l,'|',2),'') as codigo,
           nullif(split_part(l,'|',3),'') as sku_crudo,
           nullif(split_part(l,'|',4),'') as categoria,
           nullif(split_part(l,'|',5),'')::numeric as precio,
           nullif(split_part(l,'|',6),'')::numeric as costo,
           nullif(split_part(l,'|',7),'')::integer as cantidad
      from r where l <> '' and split_part(l,'|',1) <> ''
  )
  insert into public.gd_qb_import (nombre,codigo,sku_crudo,categoria,precio,costo,cantidad)
  select nombre,codigo,sku_crudo,categoria,precio,costo,cantidad from p;

  get diagnostics v_n = row_count;
  return v_n;
end $function$;

-- --------------------------------------------------------------------------
--  Aplicar el refresh (la version final)
-- --------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gd_qb_aplicar(p_de_verdad boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rol text;
  v_act integer := 0;
  v_nue integer := 0;
  v_apa integer := 0;
  v_cod integer := 0;
  v_res jsonb;
begin
  select rol into v_rol from public.gd_perfiles where id = auth.uid() and activo;
  if v_rol is distinct from 'dueno' then
    raise exception 'Solo el dueno puede refrescar el catalogo';
  end if;

  create temp table qb on commit drop as
    select distinct on (coalesce(codigo, gd_norm(nombre)), gd_norm(nombre))
           nombre, codigo, categoria, precio, cantidad,
           coalesce(codigo, gd_norm(nombre)) as llave,
           gd_norm(nombre) as nnom
      from public.gd_qb_import
     order by coalesce(codigo, gd_norm(nombre)), gd_norm(nombre), cantidad desc nulls last;

  create temp table qbrep on commit drop as
    select llave, count(*) as veces from qb group by llave;

  create temp table par on commit drop as
    select distinct on (p.id)
           p.id, q.nombre, q.codigo, q.categoria, q.precio, q.llave, q.nnom
      from public.gd_productos p
      join qb q
        on gd_norm(p.nombre) = q.nnom
        or (q.codigo is not null and p.upc = q.codigo)
      join qbrep r on r.llave = q.llave
     where p.fusionado_en is null
     order by p.id,
              (gd_norm(p.nombre) = q.nnom) desc,
              (r.veces = 1) desc,
              q.nnom;

  select count(*) into v_act from par;
  select count(*) into v_nue from qb q
   where not exists (select 1 from par where par.llave = q.llave and par.nnom = q.nnom);
  select count(*) into v_apa from public.gd_productos
   where activo and id not in (select id from par);
  select count(*) into v_cod from public.gd_productos p join par on par.id = p.id
   where p.upc is distinct from par.codigo;

  v_res := jsonb_build_object(
    'de_verdad',     p_de_verdad,
    'en_quickbooks', (select count(*) from qb),
    'codigos_repetidos_en_quickbooks', (select count(*) from qbrep where veces > 1),
    'actualizados',  v_act,
    'les_cambia_el_codigo', v_cod,
    'precios_con_candado_que_NO_se_tocan',
      (select count(*) from public.gd_productos p join par on par.id = p.id where p.precio_fijo),
    'nuevos',        v_nue,
    'revividos',     (select count(*) from public.gd_productos
                       where not activo and id in (select id from par)
                         and coalesce(apagado_motivo,'') not like 'Manuel lo pidio%'),
    'se_apagan',     v_apa,
    'se_apagan_con_mercancia',
      (select count(*) from public.gd_productos
        where activo and existencia <> 0 and id not in (select id from par)),
    'piezas_que_se_apagan',
      (select coalesce(sum(existencia),0) from public.gd_productos
        where activo and existencia > 0 and id not in (select id from par)),
    'se_apagan_ya_pedidos',
      (select count(distinct p.id) from public.gd_productos p
        where p.activo and p.id not in (select id from par)
          and exists (select 1 from public.gd_pedido_lineas l
                       where l.producto_id = p.id::text
                          or gd_norm(l.producto) = gd_norm(p.nombre)))
  );

  -- INVENTARIO: QuickBooks manda tambien la existencia (QtyOnHand). Lo que
  -- no cuadra se corrige con un movimiento de ajuste, nunca editando el
  -- numero: asi queda el rastro de cuanto se movio y cuando.
  create temp table inv on commit drop as
    select distinct on (p.id) p.id, q.cantidad - p.existencia as dif
      from public.gd_productos p
      join qb q on q.nnom = gd_norm(p.nombre)
     where p.fusionado_en is null and q.cantidad is not null
       and q.cantidad <> p.existencia
     order by p.id, q.cantidad desc;
  v_res := v_res || jsonb_build_object(
    'existencias_que_cambian', (select count(*) from inv),
    'piezas_que_entran',       (select coalesce(sum(dif),0) from inv where dif > 0),
    'piezas_que_salen',        (select coalesce(-sum(dif),0) from inv where dif < 0));

  if not p_de_verdad then
    return v_res || jsonb_build_object('nota','ENSAYO: no se toco nada');
  end if;

  update public.gd_productos p
     set nombre      = par.nombre,
         upc         = par.codigo,
         categoria   = coalesce(par.categoria, p.categoria),
         -- EL CANDADO: si el precio es fijo, QuickBooks no lo toca.
         precio      = case when p.precio_fijo then p.precio
                            else coalesce(par.precio, p.precio) end,
         -- Lo que Manuel quito a mano de la app NO lo revive el refresh.
         activo      = (coalesce(p.apagado_motivo, '') not like 'Manuel lo pidio%'),
         origen      = 'quickbooks',
         apagado_motivo = case when p.apagado_motivo like 'Manuel lo pidio%' then p.apagado_motivo end,
         apagado_el     = case when p.apagado_motivo like 'Manuel lo pidio%' then p.apagado_el end,
         actualizado = now()
    from par
   where p.id = par.id;

  update public.gd_productos
     set activo = false,
         apagado_motivo = 'Ya no venia en la exportacion de QuickBooks',
         apagado_el = now(),
         actualizado = now()
   where activo and id not in (select id from par);

  insert into public.gd_productos (nombre, upc, categoria, precio, existencia, activo, origen)
  select q.nombre, q.codigo, q.categoria, coalesce(q.precio,0), 0, true, 'quickbooks'
    from qb q
   where not exists (select 1 from par where par.llave = q.llave and par.nnom = q.nnom);

  -- Ya con los nuevos dentro: cuadrar la existencia de todos con QuickBooks.
  insert into public.gd_inventario_mov (producto_id, tipo, cantidad, motivo, referencia, nota, usuario_id)
  select x.id, 'ajuste', x.dif, 'quickbooks',
         'Refresh ' || to_char(now() at time zone 'America/Denver', 'YYYY-MM-DD HH24:MI'),
         'Cuadre con la existencia de QuickBooks', auth.uid()
    from (select distinct on (p.id) p.id, q.cantidad - p.existencia as dif
            from public.gd_productos p
            join qb q on q.nnom = gd_norm(p.nombre)
           where p.activo and p.fusionado_en is null and q.cantidad is not null
             and q.cantidad <> p.existencia
           order by p.id, q.cantidad desc) x;

  return v_res;
end $function$;

-- --------------------------------------------------------------------------
--  Quien puede llamar al refresh
-- --------------------------------------------------------------------------
-- Las dos funciones del refresh solo las puede llamar alguien con sesion.
-- El publico (anon) no las alcanza.
revoke all on function public.gd_qb_cargar(text,boolean) from anon;
grant execute on function public.gd_qb_cargar(text,boolean) to authenticated;
revoke all on function public.gd_qb_aplicar(boolean) from anon;
grant execute on function public.gd_qb_aplicar(boolean) to authenticated;

-- --------------------------------------------------------------------------
--  Las fotos que toma el equipo
-- --------------------------------------------------------------------------
-- Cual foto de QuickBooks se puso (Attachable Id:SyncToken). Con esto la
-- siguiente pasada de fotos sabe que ya esta al dia y no la vuelve a subir.
alter table public.gd_productos add column if not exists foto_qb text;

-- Donde viven las fotos que toma el equipo con el celular.
-- Publico para LEER: la app de pedidos no tiene sesion, tiene que poder verlas.
-- Para ESCRIBIR, solo el equipo activo.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('gd-fotos', 'gd-fotos', true, 5242880,
        array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
   set public = true,
       file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "gd_fotos_lee_cualquiera" on storage.objects;
create policy "gd_fotos_lee_cualquiera"
  on storage.objects for select
  using (bucket_id = 'gd-fotos');

drop policy if exists "gd_fotos_sube_el_equipo" on storage.objects;
create policy "gd_fotos_sube_el_equipo"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'gd-fotos'
              and exists (select 1 from public.gd_perfiles p
                           where p.id = auth.uid() and p.activo));

drop policy if exists "gd_fotos_reemplaza_el_equipo" on storage.objects;
create policy "gd_fotos_reemplaza_el_equipo"
  on storage.objects for update to authenticated
  using (bucket_id = 'gd-fotos'
         and exists (select 1 from public.gd_perfiles p
                      where p.id = auth.uid() and p.activo))
  with check (bucket_id = 'gd-fotos');

-- --------------------------------------------------------------------------
--  Cerrar la lista de clientes
-- --------------------------------------------------------------------------
-- CERRAR LA FUGA DE LA LISTA DE CLIENTES
--
-- gd_tienda_publica dejaba LISTAR las 108 tiendas prendidas (nombre, codigo
-- y ruta) a cualquiera con la llave publica, que esta en el HTML. O sea:
-- cualquiera con un link de tienda se bajaba la lista de clientes de Manuel.
--
-- Ahora, sin sesion solo se puede preguntar por UNA tienda y sabiendo su
-- codigo exacto. Listar o buscar por nombre exige sesion de equipo.

-- 1. Una sola tienda, con su codigo exacto. Es lo que necesita el tendero
--    cuando abre su propio link.
create or replace function public.gd_tienda_por_codigo(p_codigo text)
returns table (id uuid, codigo text, nombre text, ruta text)
language sql stable security definer set search_path = public as $$
  select t.id, t.codigo, t.nombre, t.ruta
    from public.gd_tiendas t
   where t.activo
     and lower(t.codigo) = lower(trim(p_codigo))
   limit 1;
$$;

revoke all on function public.gd_tienda_por_codigo(text) from public;
grant execute on function public.gd_tienda_por_codigo(text) to anon, authenticated;

-- 2. Se cierra la vista para quien no tiene sesion.
--    El equipo la sigue leyendo; el panel usa gd_tiendas y no se entera.
revoke select on public.gd_tienda_publica from anon;
grant  select on public.gd_tienda_publica to authenticated;

-- --------------------------------------------------------------------------
--  Bodega: picking con escaner (pedido por Manuel y Helen, 26 de octubre de 2026)
-- --------------------------------------------------------------------------
-- El bodeguero escanea cada pieza antes de empacarla. Si el codigo no es de un
-- producto del pedido, no cuenta: asi no sale el Carlos V chico por el grande.
-- Lo que se surte se cuenta en el renglon; el precio y el nombre congelados no
-- se tocan. Al terminar, el pedido pasa a 'preparado' (queda en el historial).

alter table public.gd_pedido_lineas
  add column if not exists surtido      integer not null default 0,
  add column if not exists surtido_mano integer not null default 0;   -- de esos, cuantos sin escanear (producto sin codigo)

alter table public.gd_pedidos
  add column if not exists picking_por    text,
  add column if not exists picking_inicio timestamptz,
  add column if not exists picking_fin    timestamptz;

comment on column public.gd_pedido_lineas.surtido is
  'Piezas que el bodeguero ya escaneo (o confirmo a mano). Nunca pasa de cantidad.';

-- Los renglones no tienen permiso de UPDATE para nadie: el conteo solo se
-- mueve por estas funciones, que revisan el gafete y los topes.
create or replace function public.gd_bodega_suma(p_linea uuid, p_cuantas integer default 1, p_mano boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v public.gd_pedido_lineas;
begin
  if not exists (select 1 from public.gd_perfiles where id = auth.uid() and activo) then
    raise exception 'Sin permiso';
  end if;
  update public.gd_pedido_lineas
     set surtido      = least(cantidad, surtido + greatest(p_cuantas, 0)),
         surtido_mano = surtido_mano + case when p_mano
                          then least(cantidad, surtido + greatest(p_cuantas, 0)) - surtido else 0 end
   where id = p_linea
  returning * into v;
  if v.id is null then raise exception 'No existe ese renglon'; end if;
  return jsonb_build_object('surtido', v.surtido, 'cantidad', v.cantidad);
end $$;

create or replace function public.gd_bodega_empieza(p_pedido uuid, p_nombre text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not exists (select 1 from public.gd_perfiles where id = auth.uid() and activo) then
    raise exception 'Sin permiso';
  end if;
  update public.gd_pedidos
     set picking_por = nullif(trim(p_nombre), ''),
         picking_inicio = coalesce(picking_inicio, now())
   where id = p_pedido;
end $$;

-- Volver a contar desde cero (si se empaco mal y se deshace la caja).
create or replace function public.gd_bodega_reinicia(p_pedido uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not exists (select 1 from public.gd_perfiles where id = auth.uid() and activo) then
    raise exception 'Sin permiso';
  end if;
  update public.gd_pedido_lineas set surtido = 0, surtido_mano = 0 where pedido_id = p_pedido;
  update public.gd_pedidos set picking_fin = null where id = p_pedido;
end $$;

-- Terminar: solo si TODO esta completo. Lo valida la base, no el telefono.
create or replace function public.gd_bodega_termina(p_pedido uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_falta integer;
begin
  if not exists (select 1 from public.gd_perfiles where id = auth.uid() and activo) then
    raise exception 'Sin permiso';
  end if;
  select count(*) into v_falta from public.gd_pedido_lineas
   where pedido_id = p_pedido and surtido < cantidad;
  if v_falta > 0 then
    return jsonb_build_object('ok', false, 'faltan', v_falta);
  end if;
  update public.gd_pedidos
     set picking_fin = now(),
         estado = case when estado = 'nuevo' then 'preparado' else estado end
   where id = p_pedido;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.gd_bodega_suma(uuid, integer, boolean) from public, anon;
revoke all on function public.gd_bodega_empieza(uuid, text)          from public, anon;
revoke all on function public.gd_bodega_reinicia(uuid)               from public, anon;
revoke all on function public.gd_bodega_termina(uuid)                from public, anon;
grant execute on function public.gd_bodega_suma(uuid, integer, boolean) to authenticated;
grant execute on function public.gd_bodega_empieza(uuid, text)          to authenticated;
grant execute on function public.gd_bodega_reinicia(uuid)               to authenticated;
grant execute on function public.gd_bodega_termina(uuid)                to authenticated;

-- --------------------------------------------------------------------------
--  Bodega 2: preparar la orden, ajustar lo que no hay y sacar el invoice
--  (Manuel y Helen, 26 de octubre de 2026)
-- --------------------------------------------------------------------------
-- Un paso mas en el camino del pedido: 'preparando' (alguien ya esta surtiendo).
alter table public.gd_pedidos drop constraint if exists gd_pedidos_estado_ok;
alter table public.gd_pedidos add constraint gd_pedidos_estado_ok check (estado in
  ('nuevo','preparando','preparado','en_camino','entregado','pagado','cancelado'));

-- Lo que bodega cambia del pedido NO se borra: se marca.
alter table public.gd_pedido_lineas
  add column if not exists quitado         boolean not null default false,
  add column if not exists agregado_bodega boolean not null default false,
  add column if not exists cantidad_pedida integer;          -- lo que pidio la tienda, si bodega lo cambio

-- El invoice que se creo en QuickBooks, para no crearlo dos veces.
alter table public.gd_pedidos
  add column if not exists qb_invoice_id    text,
  add column if not exists qb_invoice_num   text,
  add column if not exists qb_invoice_total numeric(12,2),
  add column if not exists qb_invoice_el    timestamptz;

create or replace function public.gd_bodega_equipo()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.gd_perfiles where id = auth.uid() and activo);
$$;

-- Total y articulos del pedido, siempre sin lo quitado.
create or replace function public.gd_bodega_recalcula(p_pedido uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  update public.gd_pedidos d
     set total     = coalesce((select sum(importe)  from public.gd_pedido_lineas where pedido_id = d.id and not quitado), 0),
         articulos = coalesce((select sum(cantidad) from public.gd_pedido_lineas where pedido_id = d.id and not quitado), 0)
   where d.id = p_pedido;
end $$;
revoke all on function public.gd_bodega_recalcula(uuid) from public, anon, authenticated;

create or replace function public.gd_bodega_empieza(p_pedido uuid, p_nombre text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.gd_bodega_equipo() then raise exception 'Sin permiso'; end if;
  update public.gd_pedidos
     set picking_por = nullif(trim(p_nombre), ''),
         picking_inicio = coalesce(picking_inicio, now()),
         estado = case when estado = 'nuevo' then 'preparando' else estado end
   where id = p_pedido;
end $$;

-- Cambiar cuantas van (no hay suficientes). Minimo 1; para cero se quita.
create or replace function public.gd_bodega_cantidad(p_linea uuid, p_cantidad integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v public.gd_pedido_lineas;
begin
  if not public.gd_bodega_equipo() then raise exception 'Sin permiso'; end if;
  if p_cantidad < 1 then raise exception 'Para dejarlo en cero, quitalo'; end if;
  update public.gd_pedido_lineas
     set cantidad_pedida = coalesce(cantidad_pedida, cantidad),
         cantidad = p_cantidad,
         importe  = round(precio * p_cantidad, 2),
         surtido  = least(surtido, p_cantidad),
         surtido_mano = least(surtido_mano, p_cantidad)
   where id = p_linea
  returning * into v;
  if v.id is null then raise exception 'No existe ese renglon'; end if;
  perform public.gd_bodega_recalcula(v.pedido_id);
  return to_jsonb(v);
end $$;

-- Quitar (o regresar) un producto del pedido. No se borra: queda marcado.
create or replace function public.gd_bodega_quita(p_linea uuid, p_quitar boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v public.gd_pedido_lineas;
begin
  if not public.gd_bodega_equipo() then raise exception 'Sin permiso'; end if;
  update public.gd_pedido_lineas set quitado = p_quitar where id = p_linea returning * into v;
  if v.id is null then raise exception 'No existe ese renglon'; end if;
  perform public.gd_bodega_recalcula(v.pedido_id);
  return to_jsonb(v);
end $$;

-- Agregar un producto. El precio: el de esa tienda si lo tiene, si no el del catalogo.
create or replace function public.gd_bodega_agrega(p_pedido uuid, p_producto uuid, p_cantidad integer default 1)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare p public.gd_productos; v_precio numeric; v_tienda uuid; v public.gd_pedido_lineas;
begin
  if not public.gd_bodega_equipo() then raise exception 'Sin permiso'; end if;
  if p_cantidad < 1 then raise exception 'La cantidad tiene que ser 1 o mas'; end if;
  select * into p from public.gd_productos where id = p_producto;
  if p.id is null then raise exception 'No existe ese producto'; end if;
  select tienda_id into v_tienda from public.gd_pedidos where id = p_pedido;
  select pt.precio into v_precio from public.gd_precio_tienda pt
   where pt.tienda_id = v_tienda and pt.producto_id = p.id;
  v_precio := coalesce(v_precio, p.precio, 0);
  insert into public.gd_pedido_lineas
    (id, pedido_id, producto_id, producto, categoria, precio, cantidad, importe, agregado_bodega)
  values (gen_random_uuid(), p_pedido, p.id::text, p.nombre, p.categoria, v_precio, p_cantidad,
          round(v_precio * p_cantidad, 2), true)
  returning * into v;
  perform public.gd_bodega_recalcula(p_pedido);
  return to_jsonb(v);
end $$;

-- Terminar: solo con todo completo (lo quitado no cuenta).
create or replace function public.gd_bodega_termina(p_pedido uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_falta integer;
begin
  if not public.gd_bodega_equipo() then raise exception 'Sin permiso'; end if;
  select count(*) into v_falta from public.gd_pedido_lineas
   where pedido_id = p_pedido and not quitado and surtido < cantidad;
  if v_falta > 0 then
    return jsonb_build_object('ok', false, 'faltan', v_falta);
  end if;
  perform public.gd_bodega_recalcula(p_pedido);
  update public.gd_pedidos
     set picking_fin = now(),
         estado = case when estado in ('nuevo','preparando') then 'preparado' else estado end
   where id = p_pedido;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.gd_bodega_equipo()                          from public, anon;
revoke all on function public.gd_bodega_cantidad(uuid, integer)           from public, anon;
revoke all on function public.gd_bodega_quita(uuid, boolean)              from public, anon;
revoke all on function public.gd_bodega_agrega(uuid, uuid, integer)       from public, anon;
grant execute on function public.gd_bodega_equipo()                       to authenticated;
grant execute on function public.gd_bodega_cantidad(uuid, integer)        to authenticated;
grant execute on function public.gd_bodega_quita(uuid, boolean)           to authenticated;
grant execute on function public.gd_bodega_agrega(uuid, uuid, integer)    to authenticated;
