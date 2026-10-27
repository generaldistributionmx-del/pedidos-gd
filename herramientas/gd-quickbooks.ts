// =====================================================================
//  gd-quickbooks — trae el catalogo directo de QuickBooks, sin archivo
//
//  QUE PUEDE Y QUE NO:
//    - Lee de QuickBooks: catalogo, fotos y clientes.
//    - ESCRIBE UNA SOLA COSA: el invoice de un pedido surtido en Bodega
//      (accion "invoice"), y solo cuando el dueno lo aprieta despues de ver
//      el ensayo. Manuel y Helen lo pidieron el 26 de octubre de 2026.
//      Nunca borra, nunca toca pagos ni otras facturas.
//    - Manuel puede cortarla cuando quiera, sin pedirmelo a mi:
//      desde el panel ("Desconectar") o desde su propia cuenta de Intuit.
//
//  DONDE VIVE EL SECRETO:
//    QB_CLIENT_ID y QB_CLIENT_SECRET viven en los secretos de Supabase.
//    No estan en este archivo, ni en el repositorio, ni en el panel, ni
//    pasaron por una conversacion. Si alguno paso por chat alguna vez,
//    se ROTA desde developer.intuit.com.
//
//  SI LOS SECRETOS NO ESTAN:
//    la funcion lo DICE, con el contador en cero. No falla callada.
//    (leccion "variable-de-entorno-subida-no-es-variable-activa")
//
//  Desplegar como:  gd-quickbooks   con verify_jwt APAGADO.
//  El verify_jwt va apagado porque Intuit regresa al usuario a esta
//  direccion sin sesion de Supabase. La revision de quien llama la hace
//  esta funcion a mano, abajo, en quienLlama().
// =====================================================================

const SB_URL   = Deno.env.get("SUPABASE_URL")!;
const SB_SERV  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CLIENTE  = Deno.env.get("QB_CLIENT_ID") ?? "";
const SECRETO  = Deno.env.get("QB_CLIENT_SECRET") ?? "";
const ENTORNO  = (Deno.env.get("QB_ENTORNO") ?? "produccion").toLowerCase();
const REGRESO  = Deno.env.get("QB_REDIRECT") ?? `${SB_URL}/functions/v1/gd-quickbooks`;

const INTUIT_AUTORIZA = "https://appcenter.intuit.com/connect/oauth2";
const INTUIT_TOKEN    = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer";
const INTUIT_REVOCA   = "https://developer.api.intuit.com/v2/oauth2/tokens/revoke";
const API_BASE = ENTORNO === "sandbox"
  ? "https://sandbox-quickbooks.api.intuit.com"
  : "https://quickbooks.api.intuit.com";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

const TANDA = 250;   // renglones por llamada a gd_qb_cargar

function json(cuerpo: unknown, status = 200) {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function pagina(titulo: string, cuerpo: string, bien = true) {
  return new Response(
    `<!doctype html><html lang="es"><head><meta charset="utf-8">
     <meta name="viewport" content="width=device-width,initial-scale=1">
     <title>${titulo}</title><style>
     body{font-family:-apple-system,"Segoe UI",Roboto,sans-serif;background:#f4f5f7;
          margin:0;padding:38px 20px;color:#16191d}
     .c{max-width:420px;margin:0 auto;background:#fff;border-radius:12px;padding:26px;
        box-shadow:0 1px 3px rgba(16,24,40,.1);text-align:center}
     h1{font-size:19px;margin:0 0 10px;color:${bien ? "#065f2b" : "#991b1b"}}
     p{color:#4b5563;line-height:1.5;font-size:15px;margin:0 0 8px}
     </style></head><body><div class="c"><h1>${titulo}</h1>${cuerpo}</div></body></html>`,
    { status: 200, headers: { ...CORS, "Content-Type": "text/html; charset=utf-8" } },
  );
}

// ---------- la base, con la llave de servicio ----------
async function base(ruta: string, opciones: RequestInit = {}) {
  const r = await fetch(`${SB_URL}/rest/v1/${ruta}`, {
    ...opciones,
    headers: {
      apikey: SB_SERV,
      Authorization: `Bearer ${SB_SERV}`,
      "Content-Type": "application/json",
      ...(opciones.headers ?? {}),
    },
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`base ${r.status}: ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : null;
}

// ---------- quien esta llamando ----------
// Devuelve el id del usuario SOLO si trae sesion valida y es dueno activo.
async function quienLlama(req: Request): Promise<string> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) {
    throw new Error("401|Entra al panel primero.");
  }
  const r = await fetch(`${SB_URL}/auth/v1/user`, {
    headers: { apikey: SB_SERV, Authorization: auth },
  });
  if (!r.ok) throw new Error("401|Tu sesion ya vencio. Vuelve a entrar al panel.");
  const u = await r.json();
  if (!u?.id) throw new Error("401|Tu sesion ya vencio. Vuelve a entrar al panel.");

  const perfil = await base(`gd_perfiles?select=rol,activo&id=eq.${u.id}`);
  if (!perfil?.length || !perfil[0].activo || perfil[0].rol !== "dueno") {
    throw new Error("403|Solo el dueno puede conectar o refrescar el catalogo.");
  }
  return u.id as string;
}

function faltanSecretos() {
  return !CLIENTE || !SECRETO;
}

// ---------- tokens de Intuit ----------
function basica() {
  return "Basic " + btoa(`${CLIENTE}:${SECRETO}`);
}

async function pideTokens(cuerpo: string) {
  const r = await fetch(INTUIT_TOKEN, {
    method: "POST",
    headers: {
      Authorization: basica(),
      "Content-Type": "application/x-www-form-urlencoded",
      Accept: "application/json",
    },
    body: cuerpo,
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`Intuit no dio el token (${r.status}): ${t.slice(0, 300)}`);
  return JSON.parse(t);
}

async function conexion() {
  const c = await base("gd_qb_conexion?select=*&id=eq.1");
  return c?.length ? c[0] : null;
}

// Un access_token de Intuit dura una hora. El refresh_token dura 100 dias
// y ROTA cada vez que se usa: hay que guardar el nuevo o se pierde el acceso.
async function accesoFresco() {
  const c = await conexion();
  if (!c) throw new Error("400|QuickBooks no esta conectado todavia.");

  const vence = c.access_vence ? new Date(c.access_vence).getTime() : 0;
  if (c.access_token && vence > Date.now() + 120_000) {
    return { token: c.access_token as string, realm: c.realm_id as string };
  }

  const d = await pideTokens(
    `grant_type=refresh_token&refresh_token=${encodeURIComponent(c.refresh_token)}`,
  );
  await base("gd_qb_conexion?id=eq.1", {
    method: "PATCH",
    body: JSON.stringify({
      refresh_token: d.refresh_token ?? c.refresh_token,
      access_token: d.access_token,
      access_vence: new Date(Date.now() + (d.expires_in ?? 3600) * 1000).toISOString(),
      ultimo_refresh: new Date().toISOString(),
      ultimo_error: null,
    }),
  });
  return { token: d.access_token as string, realm: c.realm_id as string };
}

// ---------- el catalogo, pagina por pagina ----------
async function traeArticulos(token: string, realm: string) {
  const todos: Record<string, unknown>[] = [];
  let desde = 1;
  for (let vueltas = 0; vueltas < 40; vueltas++) {
    const q = `select * from Item where Active = true startposition ${desde} maxresults 1000`;
    const r = await fetch(
      `${API_BASE}/v3/company/${realm}/query?query=${encodeURIComponent(q)}`,
      { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } },
    );
    const t = await r.text();
    if (!r.ok) throw new Error(`QuickBooks respondio ${r.status}: ${t.slice(0, 300)}`);
    const d = JSON.parse(t);
    const tanda = d?.QueryResponse?.Item ?? [];
    todos.push(...tanda);
    if (tanda.length < 1000) break;
    desde += 1000;
  }
  return todos;
}

// Igual que en el panel: decide si lo que trae el campo SKU es de verdad
// un codigo de barras. Ver la nota "el-sku-de-quickbooks-no-siempre-es-codigo".
function codigoDeBarras(sku: string, nombre: string) {
  if (!sku || sku === nombre) return "";
  if (sku.toUpperCase().includes("E")) return "";
  const d = sku.replace(/[^0-9]/g, "");
  return d.length >= 8 && d.length <= 14 ? d : "";
}

function limpia(s: unknown) {
  return String(s ?? "").replace(/\|/g, " ").replace(/\s+/g, " ").trim();
}

function arma(articulos: Record<string, any>[]) {
  // Las "categorias" de QuickBooks son articulos de tipo Category; los
  // productos las apuntan con ParentRef. Pero ParentRef tambien se usa
  // para sub-articulos de un producto normal: por eso el mapa se arma
  // SOLO con los de tipo Category, y lo demas cae en "Otros".
  const cats = new Map<string, string>();
  for (const a of articulos) {
    if (a.Type === "Category") cats.set(String(a.Id), limpia(a.Name));
  }

  const lineas: string[] = [];
  const cuenta = { total: 0, codigo: 0, nombre: 0, vacio: 0, raro: 0, categorias: cats.size };
  const porTipo: Record<string, number> = {};

  const servicios: string[] = [];
  for (const a of articulos) {
    if (a.Type === "Category") continue;
    const nom = limpia(a.Name);
    if (!nom) continue;
    // Los conceptos de servicio (Flete, Sales...) sirven para facturar en
    // QuickBooks, no son mercancia: no van al catalogo de la app. Manuel
    // lo pidio el 22 de octubre de 2026. Se cuentan para que el ensayo lo diga.
    if (a.Type === "Service") {
      servicios.push(nom);
      porTipo.Service = (porTipo.Service ?? 0) + 1;
      continue;
    }
    const sku = limpia(a.Sku);
    const cod = codigoDeBarras(sku, nom);

    cuenta.total++;
    if (cod) cuenta.codigo++;
    else if (!sku) cuenta.vacio++;
    else if (sku === nom) cuenta.nombre++;
    else cuenta.raro++;
    porTipo[a.Type ?? "?"] = (porTipo[a.Type ?? "?"] ?? 0) + 1;

    const cat = cats.get(String(a.ParentRef?.value ?? "")) ?? "Otros";
    lineas.push([
      nom,
      cod,
      sku,
      cat || "Otros",
      Number(a.UnitPrice ?? 0).toFixed(2),
      Number(a.PurchaseCost ?? 0).toFixed(2),
      String(Math.round(Number(a.QtyOnHand ?? 0))),
    ].join("|"));
  }
  return { lineas, cuenta: { ...cuenta, servicios: servicios.length }, porTipo, servicios };
}

// ---------- los clientes (tiendas) de QuickBooks ----------
// Manuel mantiene telefonos y direcciones en QuickBooks: de ahi bajan solos.
// Se empareja por qb_id (el Id del Customer), nunca por nombre: dos tiendas
// pueden llamarse igual. El codigo del link se hace UNA vez y no se cambia,
// para que el link de la tienda siga sirviendo. Lo que QuickBooks ya no trae
// activo se APAGA, no se borra. Las tiendas dadas de alta a mano en el panel
// (sin qb_id) no se tocan.
const RUTA_DE: Record<string, string> = { UT: "Utah", CO: "Colorado", ID: "Idaho" };

async function traeClientes(token: string, realm: string) {
  const todos: Record<string, any>[] = [];
  let desde = 1;
  for (let vueltas = 0; vueltas < 40; vueltas++) {
    const q = `select * from Customer where Active = true startposition ${desde} maxresults 1000`;
    const r = await fetch(
      `${API_BASE}/v3/company/${realm}/query?query=${encodeURIComponent(q)}`,
      { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } },
    );
    const t = await r.text();
    if (!r.ok) throw new Error(`QuickBooks respondio ${r.status} al pedir los clientes: ${t.slice(0, 300)}`);
    const tanda = JSON.parse(t)?.QueryResponse?.Customer ?? [];
    todos.push(...tanda);
    if (tanda.length < 1000) break;
    desde += 1000;
  }
  return todos;
}

function codigoDeTienda(nombre: string, qbId: string) {
  const base = norm(nombre).replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 24).replace(/-+$/, "");
  return `${base || "tienda"}-${qbId}`;
}

function tiendaDeCliente(c: Record<string, any>) {
  const dir = (c.ShipAddr && (c.ShipAddr.Line1 || c.ShipAddr.City)) ? c.ShipAddr : (c.BillAddr ?? {});
  const estado = limpia(dir.CountrySubDivisionCode).toUpperCase();
  const lineas = [dir.Line1, dir.Line2, dir.Line3].map(limpia).filter(Boolean).join(", ");
  const contacto = [limpia(c.GivenName), limpia(c.FamilyName)].filter(Boolean).join(" ");
  const nulo = (s: string) => (s ? s : null);
  return {
    qb_id: String(c.Id),
    nombre: limpia(c.DisplayName) || limpia(c.CompanyName) || `Cliente ${c.Id}`,
    telefono: nulo(limpia(c.PrimaryPhone?.FreeFormNumber) || limpia(c.Mobile?.FreeFormNumber)),
    direccion: nulo(lineas),
    ciudad: nulo(limpia(dir.City)),
    estado: nulo(estado),
    ruta: RUTA_DE[estado] ?? nulo(estado),
    contacto: nulo(contacto),
  };
}

const CAMPOS_TIENDA = ["nombre", "telefono", "direccion", "ciudad", "estado", "ruta", "contacto"] as const;

async function planClientes(token: string, realm: string) {
  const clientes = await traeClientes(token, realm);
  const vienen = clientes.map(tiendaDeCliente);
  const yaHay = await base("gd_tiendas?select=id,codigo,qb_id,activo," + CAMPOS_TIENDA.join(",") +
                           "&qb_id=not.is.null&limit=10000") ?? [];
  const porQb = new Map<string, Record<string, any>>();
  for (const t of yaHay) porQb.set(String(t.qb_id), t);

  const nuevas: Record<string, any>[] = [];
  const cambian: { id: string; campos: Record<string, any> }[] = [];
  let iguales = 0, revividas = 0;
  const llegan = new Set<string>();
  for (const v of vienen) {
    llegan.add(v.qb_id);
    const t = porQb.get(v.qb_id);
    if (!t) { nuevas.push({ ...v, codigo: codigoDeTienda(v.nombre, v.qb_id) }); continue; }
    const campos: Record<string, any> = {};
    for (const k of CAMPOS_TIENDA) if ((t[k] ?? null) !== (v[k] ?? null)) campos[k] = v[k];
    if (!t.activo) { campos.activo = true; revividas++; }
    if (Object.keys(campos).length) cambian.push({ id: t.id, campos });
    else iguales++;
  }
  const seApagan = yaHay.filter((t: Record<string, any>) => t.activo && !llegan.has(String(t.qb_id)));

  const porRuta: Record<string, number> = {};
  for (const v of vienen) porRuta[v.ruta ?? "Sin estado"] = (porRuta[v.ruta ?? "Sin estado"] ?? 0) + 1;

  return {
    resumen: {
      en_quickbooks: vienen.length,
      nuevas: nuevas.length,
      se_actualizan: cambian.length,
      iguales,
      se_vuelven_a_prender: revividas,
      se_apagan: seApagan.length,
      sin_telefono: vienen.filter((v) => !v.telefono).length,
      sin_direccion: vienen.filter((v) => !v.direccion).length,
      por_ruta: porRuta,
    },
    nuevas,
    cambian,
    seApagan,
  };
}

// ---------- las fotos de QuickBooks ----------
// En QuickBooks la foto de un articulo es un "Attachable" amarrado al Item.
// Decision de Manuel (22 oct 2026): si el articulo tiene foto en QuickBooks,
// GANA esa, aunque el producto ya tenga una de la camara o de Shopify. Si no
// tiene, se respeta la que ya esta. Las fotos de QuickBooks viven aparte, en
// gd-fotos/qb/<id>, y foto_qb guarda cual se puso: asi la segunda pasada sabe
// que ya esta al dia y no la vuelve a subir.
const FOTO_MAX = 5 * 1024 * 1024;   // el mismo limite que el deposito gd-fotos
const LOTE_FOTOS = 15;              // fotos por llamada: cada una se baja y se sube
const EXT: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };

// La misma cuenta que gd_norm() en la base: sin acentos, minusculas, un espacio.
function norm(t: string) {
  const de = "áéíóúàèìòùäëïöüâêîôûñ", a = "aeiouaeiouaeiouaeioun";
  let s = "";
  for (const ch of String(t ?? "").toLowerCase()) {
    const i = de.indexOf(ch);
    s += i >= 0 ? a[i] : ch;
  }
  return s.replace(/\s+/g, " ");
}

async function traeAdjuntos(token: string, realm: string) {
  const todos: Record<string, any>[] = [];
  // Primero se le pide a QuickBooks solo los de articulos; si no acepta el
  // filtro, se piden todos y se filtran aqui.
  let filtro = " where AttachableRef.EntityRef.Type = 'Item'";
  let desde = 1;
  for (let vueltas = 0; vueltas < 40; vueltas++) {
    const q = `select * from Attachable${filtro} startposition ${desde} maxresults 1000`;
    const r = await fetch(
      `${API_BASE}/v3/company/${realm}/query?query=${encodeURIComponent(q)}`,
      { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } },
    );
    const t = await r.text();
    if (!r.ok) {
      if (filtro && desde === 1) { filtro = ""; continue; }
      throw new Error(`QuickBooks respondio ${r.status} al pedir las fotos: ${t.slice(0, 300)}`);
    }
    const tanda = JSON.parse(t)?.QueryResponse?.Attachable ?? [];
    todos.push(...tanda);
    if (tanda.length < 1000) break;
    desde += 1000;
  }
  return todos;
}

async function planFotos(token: string, realm: string) {
  const articulos = await traeArticulos(token, realm) as Record<string, any>[];
  const nombreDeItem = new Map<string, string>();
  for (const a of articulos) {
    if (a.Type === "Category" || a.Type === "Service") continue;
    nombreDeItem.set(String(a.Id), limpia(a.Name));
  }

  // La foto mas reciente de cada articulo.
  const adjuntos = await traeAdjuntos(token, realm);
  const fotoDeItem = new Map<string, Record<string, any>>();
  for (const at of adjuntos) {
    if (!String(at.ContentType ?? "").toLowerCase().startsWith("image/")) continue;
    for (const ref of at.AttachableRef ?? []) {
      const e = ref?.EntityRef;
      if (!e || String(e.type ?? e.Type ?? "").toLowerCase() !== "item") continue;
      const id = String(e.value);
      const ya = fotoDeItem.get(id);
      if (!ya || String(at.MetaData?.LastUpdatedTime ?? "") > String(ya.MetaData?.LastUpdatedTime ?? "")) {
        fotoDeItem.set(id, at);
      }
    }
  }

  const productos = await base("gd_productos?select=id,nombre,foto,foto_qb&activo=is.true&limit=5000");
  const porNombre = new Map<string, Record<string, any>>();
  for (const p of productos ?? []) porNombre.set(norm(p.nombre), p);

  let iguales = 0, nuevas = 0, reemplazan = 0, sinProducto = 0;
  const sinProductoNombres: string[] = [];
  const pendientes: { prod: Record<string, any>; at: Record<string, any>; llave: string; nombre: string }[] = [];
  for (const [itemId, at] of fotoDeItem) {
    const nom = nombreDeItem.get(itemId);
    const p = nom ? porNombre.get(norm(nom)) : undefined;
    if (!p) {
      sinProducto++;
      if (nom) sinProductoNombres.push(nom);
      continue;
    }
    const llave = `${at.Id}:${at.SyncToken ?? ""}`;
    const esLaDeQb = String(p.foto ?? "").includes(`/gd-fotos/qb/${p.id}.`);
    if (p.foto_qb === llave && esLaDeQb) { iguales++; continue; }
    if (p.foto) reemplazan++; else nuevas++;
    pendientes.push({ prod: p, at, llave, nombre: String(p.nombre) });
  }
  pendientes.sort((x, y) => x.nombre.localeCompare(y.nombre));

  return {
    resumen: {
      con_foto_en_quickbooks: fotoDeItem.size,
      iguales,
      nuevas,
      reemplazan,
      sin_producto: sinProducto,
      sin_producto_nombres: sinProductoNombres.slice(0, 20),
      pendientes: pendientes.length,
    },
    pendientes,
  };
}

async function ponFoto(token: string, realm: string, x: { prod: Record<string, any>; at: Record<string, any>; llave: string }) {
  let liga = String(x.at.TempDownloadUri ?? "");
  if (!liga) {
    const r = await fetch(`${API_BASE}/v3/company/${realm}/download/${x.at.Id}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!r.ok) throw new Error(`QuickBooks no dio la liga de la foto (${r.status})`);
    liga = (await r.text()).trim();
  }
  const r = await fetch(liga);
  if (!r.ok) throw new Error(`no se pudo bajar de QuickBooks (${r.status})`);
  const bytes = new Uint8Array(await r.arrayBuffer());
  let tipo = String(r.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (!EXT[tipo]) tipo = String(x.at.ContentType ?? "").toLowerCase();
  if (tipo === "image/jpg") tipo = "image/jpeg";
  if (!EXT[tipo]) throw new Error(`es ${tipo || "un archivo raro"}; solo se aceptan JPG, PNG o WEBP`);
  if (bytes.length > FOTO_MAX) throw new Error(`pesa ${(bytes.length / 1048576).toFixed(1)} MB (el maximo es 5)`);

  const ruta = `qb/${x.prod.id}.${EXT[tipo]}`;
  const s = await fetch(`${SB_URL}/storage/v1/object/gd-fotos/${ruta}`, {
    method: "POST",
    headers: {
      apikey: SB_SERV,
      Authorization: `Bearer ${SB_SERV}`,
      "Content-Type": tipo,
      "x-upsert": "true",
    },
    body: bytes,
  });
  if (!s.ok) throw new Error(`no se pudo guardar (${s.status}): ${(await s.text()).slice(0, 150)}`);

  // El ?v= obliga al telefono a pedir la nueva y no la que ya tenia guardada.
  const url = `${SB_URL}/storage/v1/object/public/gd-fotos/${ruta}?v=${Date.now()}`;
  await base(`gd_productos?id=eq.${x.prod.id}`, {
    method: "PATCH",
    body: JSON.stringify({ foto: url, foto_qb: x.llave }),
  });
}

// ---------- ruta y vendedor: los campos propios de los invoices ----------
// En QuickBooks cada invoice ya lleva la ruta y el vendedor en campos propios
// (CustomField). Aqui se leen los ultimos invoices para saber como se llaman
// esos campos y que valores se usan: esa es la lista que escoge el vendedor.
// Los campos "nuevos" de QuickBooks (Sales Rep, Ruta de Manuel) SOLO llegan
// con include=enhancedAllCustomFields: sin eso, 3,000 invoices salen sin campos.
function rolDeCampo(nombre: string) {
  const n = norm(nombre);
  if (/\bruta\b|route/.test(n)) return "ruta";
  if (/vend|rep|sales|seller/.test(n)) return "vendedor";
  return null;
}

async function planCampos(token: string, realm: string) {
  const campos = new Map<string, { campo_id: string; campo: string; rol: string | null; valores: Map<string, number> }>();
  let leidos = 0, desde = 1;
  for (let vueltas = 0; vueltas < 3; vueltas++) {
    const q = `select * from Invoice orderby MetaData.CreateTime desc startposition ${desde} maxresults 1000`;
    const r = await fetch(
      `${API_BASE}/v3/company/${realm}/query?query=${encodeURIComponent(q)}&minorversion=75&include=enhancedAllCustomFields`,
      { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } },
    );
    const t = await r.text();
    if (!r.ok) throw new Error(`QuickBooks respondio ${r.status} al pedir los invoices: ${t.slice(0, 300)}`);
    const tanda = JSON.parse(t)?.QueryResponse?.Invoice ?? [];
    for (const inv of tanda) {
      for (const cf of inv.CustomField ?? []) {
        const id = String(cf.DefinitionId ?? "");
        const nombre = limpia(cf.Name);
        const valor = limpia(cf.StringValue);
        if (!id || !nombre) continue;
        if (!campos.has(id)) campos.set(id, { campo_id: id, campo: nombre, rol: rolDeCampo(nombre), valores: new Map() });
        if (valor) {
          const v = campos.get(id)!.valores;
          v.set(valor, (v.get(valor) ?? 0) + 1);
        }
      }
    }
    leidos += tanda.length;
    if (tanda.length < 1000) break;
    desde += 1000;
  }
  const lista = [...campos.values()].map((c) => ({
    campo_id: c.campo_id, campo: c.campo, rol: c.rol,
    valores: [...c.valores.entries()].sort((a, b) => b[1] - a[1]).map(([valor, veces]) => ({ valor, veces })),
  }));
  return { invoices_leidos: leidos, campos: lista };
}

// ---------- el invoice de un pedido surtido en bodega ----------
// Manuel y Helen, 26 de octubre de 2026: al terminar el picking se crea el
// invoice en QuickBooks con lo que de verdad se surtio. Es la UNICA escritura
// de esta funcion, y solo pasa cuando el dueno aprieta el boton despues de ver
// el ensayo. El pedido guarda el Id del invoice: no se puede crear dos veces.
async function planInvoice(token: string, realm: string, pedidoId: string) {
  const ped = (await base(
    `gd_pedidos?id=eq.${encodeURIComponent(pedidoId)}&select=id,folio,tienda,tienda_id,estado,es_prueba,` +
    `picking_por,vendedor,ruta,qb_invoice_id,qb_invoice_num,gd_pedido_lineas(id,producto_id,producto,precio,cantidad,surtido,quitado)`,
  ))?.[0];
  if (!ped) throw new Error("No encontre ese pedido.");

  let tienda: Record<string, any> | null = null;
  if (ped.tienda_id) {
    tienda = (await base(`gd_tiendas?id=eq.${ped.tienda_id}&select=id,nombre,qb_id`))?.[0] ?? null;
  }
  const nombreTienda = String(tienda?.nombre ?? ped.tienda ?? "");

  // El cliente: por su Id de QuickBooks si ya lo tenemos; si no, por nombre.
  const clientes = await traeClientes(token, realm);
  let cliente = tienda?.qb_id ? clientes.find((c) => String(c.Id) === String(tienda!.qb_id)) : undefined;
  if (!cliente) {
    const n = norm(nombreTienda);
    const iguales = clientes.filter((c) => norm(limpia(c.DisplayName)) === n);
    if (iguales.length === 1) cliente = iguales[0];
  }

  // Los productos: por nombre, que es como el refresh los da de alta.
  const articulos = await traeArticulos(token, realm);
  const porNombre = new Map<string, Record<string, any>>();
  for (const a of articulos) {
    if (a.Type === "Category") continue;
    porNombre.set(norm(limpia(a.Name)), a);
  }
  const lineas = (ped.gd_pedido_lineas ?? [])
    .filter((l: Record<string, any>) => !l.quitado)
    .map((l: Record<string, any>) => {
      const it = porNombre.get(norm(limpia(l.producto)));
      const cant = Number(l.cantidad);
      const precio = Number(l.precio);
      return {
        producto: l.producto, cantidad: cant, precio,
        importe: Math.round(cant * precio * 100) / 100,
        surtido: Number(l.surtido), item_id: it ? String(it.Id) : null,
      };
    });
  const total = Math.round(lineas.reduce((s: number, l: any) => s + l.importe, 0) * 100) / 100;

  // Ruta y vendedor van en los campos propios del invoice, como ya los usa Manuel.
  // Solo los campos que vinieron de QuickBooks (campo_id = su DefinitionId).
  // Las rutas que Manuel dio a mano (campo_id 'manual') son la lista de la
  // app, no un campo de QuickBooks.
  const defs = await base("gd_qb_valores?select=campo_id,campo,rol&rol=in.(ruta,vendedor)&campo_id=neq.manual&limit=1000") ?? [];
  const campoDe = (rol: string) => defs.find((x: Record<string, any>) => x.rol === rol);
  const extras: Record<string, unknown>[] = [];
  for (const [rol, valor] of [["ruta", ped.ruta], ["vendedor", ped.vendedor]] as [string, string | null][]) {
    const c = campoDe(rol);
    // En QuickBooks la ruta se escribe sin la palabra (Colorado, Provo...): la
    // app dice "Ruta Colorado" y aqui se le quita "Ruta " para que cuadre.
    const texto = rol === "ruta" ? String(valor).replace(/^ruta\s+/i, "") : String(valor);
    if (c && texto) extras.push({ DefinitionId: String(c.campo_id), Name: c.campo, Type: "StringType", StringValue: texto.slice(0, 31) });
  }
  const sinItem = lineas.filter((l: any) => !l.item_id).map((l: any) => l.producto);
  const sinSurtir = lineas.filter((l: any) => l.surtido < l.cantidad).map((l: any) => l.producto);

  const problemas: string[] = [];
  if (ped.qb_invoice_id) problemas.push(`Este pedido ya tiene el invoice #${ped.qb_invoice_num ?? ped.qb_invoice_id} en QuickBooks.`);
  if (!["preparado", "en_camino", "entregado", "pagado"].includes(ped.estado)) {
    problemas.push("Primero hay que terminar el picking en Bodega.");
  }
  if (!cliente) problemas.push(`No encontre a "${nombreTienda}" como cliente en QuickBooks (tiene que llamarse igual).`);
  if (sinItem.length) problemas.push(`No encontre en QuickBooks: ${sinItem.join(", ")}.`);
  if (sinSurtir.length) problemas.push(`Faltan por surtir: ${sinSurtir.join(", ")}.`);
  if (!lineas.length) problemas.push("El pedido no tiene productos.");

  return {
    ped, lineas, total, problemas,
    resumen: {
      folio: ped.folio,
      tienda: nombreTienda,
      cliente_qb: cliente ? limpia(cliente.DisplayName) : null,
      productos: lineas.length,
      piezas: lineas.reduce((s: number, l: any) => s + l.cantidad, 0),
      total,
      es_prueba: !!ped.es_prueba,
      ruta: ped.ruta ?? null,
      vendedor: ped.vendedor ?? null,
      campos_en_invoice: extras.map((x) => `${x.Name}: ${x.StringValue}`),
      problemas,
    },
    clienteId: cliente ? String(cliente.Id) : null,
    extras,
  };
}

async function creaInvoice(token: string, realm: string, plan: Awaited<ReturnType<typeof planInvoice>>) {
  const hoy = new Date().toLocaleDateString("en-CA", { timeZone: "America/Denver" });
  const cuerpo = {
    CustomerRef: { value: plan.clienteId },
    TxnDate: hoy,
    ...(plan.extras.length ? { CustomField: plan.extras } : {}),
    PrivateNote: `App General Distribution · folio ${plan.ped.folio}` +
                 (plan.ped.picking_por ? ` · surtio ${plan.ped.picking_por}` : ""),
    Line: plan.lineas.map((l: any) => ({
      DetailType: "SalesItemLineDetail",
      Amount: l.importe,
      Description: l.producto,
      SalesItemLineDetail: { ItemRef: { value: l.item_id }, Qty: l.cantidad, UnitPrice: l.precio },
    })),
  };
  const r = await fetch(`${API_BASE}/v3/company/${realm}/invoice?minorversion=75&include=enhancedAllCustomFields`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify(cuerpo),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`QuickBooks no acepto el invoice (${r.status}): ${t.slice(0, 400)}`);
  return JSON.parse(t)?.Invoice;
}

// ---------- las funciones de la base, con la sesion de quien llamo ----------
// A proposito se usa SU sesion y no la llave de servicio: asi la revision
// de "solo el dueno" vive en un solo lugar, dentro de gd_qb_aplicar.
async function rpc(auth: string, fn: string, cuerpo: unknown) {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: SB_SERV, Authorization: auth, "Content-Type": "application/json" },
    body: JSON.stringify(cuerpo),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`${fn} respondio ${r.status}: ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : null;
}

// =====================================================================
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const url = new URL(req.url);

  // ---------- 1. el regreso de Intuit (es el navegador, sin sesion) ----------
  if (req.method === "GET" && (url.searchParams.has("code") || url.searchParams.has("error"))) {
    const err = url.searchParams.get("error");
    if (err) {
      return pagina("No se conecto", `<p>Intuit contesto: <b>${err}</b></p>
        <p>Puedes cerrar esta pestaña e intentar de nuevo desde el panel.</p>`, false);
    }
    try {
      const estado = url.searchParams.get("state") ?? "";
      const code   = url.searchParams.get("code") ?? "";
      const realm  = url.searchParams.get("realmId") ?? "";
      if (!realm) throw new Error("Intuit no dijo de que empresa se trata.");

      const fila = await base(
        `gd_qb_oauth_estado?select=*&estado=eq.${encodeURIComponent(estado)}&usado=eq.false`,
      );
      if (!fila?.length) throw new Error("Esta liga ya se uso o ya vencio. Pide una nueva desde el panel.");
      const edad = Date.now() - new Date(fila[0].creado).getTime();
      if (edad > 20 * 60 * 1000) throw new Error("La liga vencio (dura 20 minutos). Pide una nueva desde el panel.");

      const d = await pideTokens(
        `grant_type=authorization_code&code=${encodeURIComponent(code)}` +
        `&redirect_uri=${encodeURIComponent(REGRESO)}`,
      );

      await base("gd_qb_conexion", {
        method: "POST",
        headers: { Prefer: "resolution=merge-duplicates" },
        body: JSON.stringify({
          id: 1,
          realm_id: realm,
          refresh_token: d.refresh_token,
          access_token: d.access_token,
          access_vence: new Date(Date.now() + (d.expires_in ?? 3600) * 1000).toISOString(),
          entorno: ENTORNO,
          conectado_por: fila[0].usuario,
          conectado_el: new Date().toISOString(),
          ultimo_refresh: new Date().toISOString(),
          ultimo_error: null,
        }),
      });
      await base(`gd_qb_oauth_estado?estado=eq.${encodeURIComponent(estado)}`, {
        method: "PATCH",
        body: JSON.stringify({ usado: true }),
      });

      return pagina("Ya quedo conectado", `
        <p>QuickBooks y la aplicacion ya se hablan.</p>
        <p><b>Cierra esta pestaña y vuelve al panel.</b> Ahi aprieta
        <i>Revisar sin cambiar nada</i> y te dira que va a pasar.</p>
        <p style="font-size:13px;color:#6b7280;margin-top:14px">Esta conexion
        <b>solo lee</b> de QuickBooks. Puedes cortarla cuando quieras desde el panel.</p>`);
    } catch (e) {
      return pagina("No se conecto", `<p>${String(e.message ?? e)}</p>`, false);
    }
  }

  if (req.method !== "POST") {
    return pagina("Funcion de QuickBooks",
      `<p>Esta direccion la usa el panel. No hay nada que ver aqui.</p>`);
  }

  // ---------- 2. todo lo demas: lo pide el panel, con sesion de dueno ----------
  let usuario: string;
  try {
    usuario = await quienLlama(req);
  } catch (e) {
    const [cod, msg] = String(e.message ?? e).split("|");
    return json({ ok: false, error: msg ?? cod }, Number(cod) || 400);
  }

  let cuerpo: Record<string, unknown> = {};
  try { cuerpo = await req.json(); } catch { /* sin cuerpo */ }
  const accion = String(cuerpo.accion ?? "estado");

  try {
    // --- esta todo puesto? Lo contesta el proceso, no el panel de Supabase ---
    if (accion === "estado") {
      const c = await conexion();
      return json({
        ok: true,
        secretos_puestos: !faltanSecretos(),
        entorno: ENTORNO,
        regreso: REGRESO,
        conectado: !!c,
        empresa: c?.realm_id ?? null,
        conectado_el: c?.conectado_el ?? null,
        ultimo_refresh: c?.ultimo_refresh ?? null,
        ultimo_error: c?.ultimo_error ?? null,
        aviso: faltanSecretos()
          ? "Faltan los secretos QB_CLIENT_ID y QB_CLIENT_SECRET en Supabase. Sin ellos no se puede conectar."
          : null,
      });
    }

    if (accion === "autorizar") {
      if (faltanSecretos()) {
        return json({
          ok: false,
          productos: 0,
          error: "Faltan los secretos QB_CLIENT_ID y QB_CLIENT_SECRET en Supabase.",
        }, 400);
      }
      const estado = crypto.randomUUID();
      await base("gd_qb_oauth_estado", {
        method: "POST",
        body: JSON.stringify({ estado, usuario }),
      });
      const u = new URL(INTUIT_AUTORIZA);
      u.searchParams.set("client_id", CLIENTE);
      u.searchParams.set("response_type", "code");
      u.searchParams.set("scope", "com.intuit.quickbooks.accounting");
      u.searchParams.set("redirect_uri", REGRESO);
      u.searchParams.set("state", estado);
      return json({ ok: true, url: u.toString() });
    }

    if (accion === "desconectar") {
      const c = await conexion();
      if (c && !faltanSecretos()) {
        // Se le avisa a Intuit, no nada mas se borra de aqui.
        try {
          await fetch(INTUIT_REVOCA, {
            method: "POST",
            headers: { Authorization: basica(), "Content-Type": "application/json" },
            body: JSON.stringify({ token: c.refresh_token }),
          });
        } catch { /* si Intuit no contesta, igual se corta de este lado */ }
      }
      await base("gd_qb_conexion?id=eq.1", { method: "DELETE" });
      return json({ ok: true, conectado: false });
    }

    if (accion === "refrescar") {
      if (faltanSecretos()) {
        return json({
          ok: false,
          productos: 0,
          error: "Faltan los secretos QB_CLIENT_ID y QB_CLIENT_SECRET en Supabase.",
        }, 400);
      }
      const deVerdad = cuerpo.de_verdad === true;
      const auth = req.headers.get("Authorization")!;

      // --- FRENO 1: la empresa de pruebas de Intuit NUNCA aplica de verdad ---
      // Con llaves de Development se conecta una empresa inventada con unos
      // pocos productos de muestra. Aplicar eso apagaria el catalogo real.
      if (deVerdad && ENTORNO === "sandbox") {
        return json({
          ok: false,
          productos: 0,
          error: "Estas conectado a la empresa de PRUEBAS de Intuit (QB_ENTORNO=sandbox). " +
                 "Aqui solo se puede revisar, nunca aplicar: aplicar los productos de prueba " +
                 "apagaria el catalogo de verdad. Cuando tengas las llaves de Production, " +
                 "quita el secreto QB_ENTORNO y vuelve a conectar.",
        }, 400);
      }

      let acceso;
      try {
        acceso = await accesoFresco();
      } catch (e) {
        await base("gd_qb_conexion?id=eq.1", {
          method: "PATCH",
          body: JSON.stringify({ ultimo_error: String(e.message ?? e).slice(0, 400) }),
        }).catch(() => {});
        throw e;
      }

      const articulos = await traeArticulos(acceso.token, acceso.realm);
      const { lineas, cuenta, porTipo, servicios } = arma(articulos);

      if (!lineas.length) {
        return json({
          ok: false,
          productos: 0,
          error: "QuickBooks contesto bien pero no mando ningun producto. No se toco nada.",
        }, 400);
      }

      for (let i = 0; i < lineas.length; i += TANDA) {
        await rpc(auth, "gd_qb_cargar", {
          p_lineas: lineas.slice(i, i + TANDA).join("\n"),
          p_primera: i === 0,
        });
      }
      // --- FRENO 2: si se apagaria casi todo, algo esta mal conectado ---
      // El caso real que esto ataja: quedarse con las llaves de prueba, o
      // autorizar una empresa de QuickBooks que no es la suya. Entonces
      // llegan poquitos productos y "lo que no vino" es casi el catalogo.
      // Se mide SIEMPRE con un ensayo antes de aplicar.
      const ensayo = await rpc(auth, "gd_qb_aplicar", { p_de_verdad: false });
      if (deVerdad && cuerpo.forzar !== true) {
        const tocados = Number(ensayo?.actualizados ?? 0) + Number(ensayo?.se_apagan ?? 0);
        const apagar  = Number(ensayo?.se_apagan ?? 0);
        if (tocados > 0 && apagar / tocados > 0.8) {
          return json({
            ok: false,
            productos: lineas.length,
            resumen: ensayo,
            error: `Me freno: se apagarian ${apagar} de ${tocados} productos ` +
                   `(mas del 80%). QuickBooks solo mando ${lineas.length}. ` +
                   `Eso casi siempre significa que quedaron puestas las llaves de prueba, ` +
                   `o que se autorizo una empresa de QuickBooks que no es la tuya. ` +
                   `Revisa la empresa en el panel antes de seguir.`,
          }, 400);
        }
      }

      const resumen = deVerdad
        ? await rpc(auth, "gd_qb_aplicar", { p_de_verdad: true })
        : ensayo;

      return json({
        ok: true,
        de_verdad: deVerdad,
        articulos_de_intuit: articulos.length,
        productos: lineas.length,
        cuenta,
        por_tipo: porTipo,
        servicios,
        resumen,
      });
    }

    // --- las fotos: primero el ensayo, despues de a poquito ---
    if (accion === "fotos") {
      if (faltanSecretos()) {
        return json({ ok: false, error: "Faltan los secretos QB_CLIENT_ID y QB_CLIENT_SECRET en Supabase." }, 400);
      }
      const deVerdad = cuerpo.de_verdad === true;
      const acceso = await accesoFresco();
      const plan = await planFotos(acceso.token, acceso.realm);
      if (!deVerdad) return json({ ok: true, de_verdad: false, resumen: plan.resumen });

      // Las que ya fallaron en esta misma corrida se saltan, para no ciclarse.
      const saltar = new Set(Array.isArray(cuerpo.saltar) ? (cuerpo.saltar as unknown[]).map(String) : []);
      const cola = plan.pendientes.filter((x) => !saltar.has(String(x.prod.id)));
      const lote = cola.slice(0, LOTE_FOTOS);
      let hechas = 0;
      const fallas: { id: string; nombre: string; error: string }[] = [];
      for (const x of lote) {
        try {
          await ponFoto(acceso.token, acceso.realm, x);
          hechas++;
        } catch (e) {
          fallas.push({ id: String(x.prod.id), nombre: x.nombre, error: String(e.message ?? e).slice(0, 200) });
        }
      }
      return json({ ok: true, de_verdad: true, hechas, fallas, quedan: cola.length - lote.length, resumen: plan.resumen });
    }

    // --- los clientes: primero el ensayo, luego de una vez ---
    if (accion === "clientes") {
      if (faltanSecretos()) {
        return json({ ok: false, error: "Faltan los secretos QB_CLIENT_ID y QB_CLIENT_SECRET en Supabase." }, 400);
      }
      const deVerdad = cuerpo.de_verdad === true;
      const acceso = await accesoFresco();
      const plan = await planClientes(acceso.token, acceso.realm);
      if (!deVerdad) return json({ ok: true, de_verdad: false, resumen: plan.resumen });

      // El mismo freno que el catalogo: si se apagaria casi todo, algo esta mal conectado.
      const tocadas = plan.cambian.length + plan.seApagan.length;
      if (tocadas > 0 && plan.seApagan.length / tocadas > 0.8 && cuerpo.forzar !== true) {
        return json({
          ok: false,
          resumen: plan.resumen,
          error: `Me freno: se apagarian ${plan.seApagan.length} tiendas. ` +
                 `QuickBooks solo mando ${plan.resumen.en_quickbooks} clientes. Revisa la empresa conectada.`,
        }, 400);
      }

      for (let i = 0; i < plan.nuevas.length; i += 200) {
        await base("gd_tiendas", { method: "POST", body: JSON.stringify(plan.nuevas.slice(i, i + 200)) });
      }
      for (const c of plan.cambian) {
        await base(`gd_tiendas?id=eq.${c.id}`, { method: "PATCH", body: JSON.stringify(c.campos) });
      }
      for (const t of plan.seApagan) {
        await base(`gd_tiendas?id=eq.${t.id}`, {
          method: "PATCH",
          body: JSON.stringify({ activo: false }),
        });
      }
      return json({ ok: true, de_verdad: true, resumen: plan.resumen });
    }

    // --- ruta y vendedor de los invoices: primero ver, luego guardar la lista ---
    if (accion === "campos") {
      if (faltanSecretos()) {
        return json({ ok: false, error: "Faltan los secretos QB_CLIENT_ID y QB_CLIENT_SECRET en Supabase." }, 400);
      }
      const acceso = await accesoFresco();
      const plan = await planCampos(acceso.token, acceso.realm);
      if (cuerpo.de_verdad !== true) return json({ ok: true, de_verdad: false, resumen: plan });
      const filas: Record<string, unknown>[] = [];
      const ahora = new Date().toISOString();
      for (const c of plan.campos) {
        for (const v of c.valores) {
          filas.push({ campo_id: c.campo_id, campo: c.campo, rol: c.rol, valor: v.valor, veces: v.veces, actualizado: ahora });
        }
      }
      for (let i = 0; i < filas.length; i += 500) {
        await base("gd_qb_valores", {
          method: "POST",
          headers: { Prefer: "resolution=merge-duplicates" },
          body: JSON.stringify(filas.slice(i, i + 500)),
        });
      }
      return json({ ok: true, de_verdad: true, resumen: plan, guardados: filas.length });
    }

    // --- el invoice de un pedido de bodega: primero el ensayo, luego de verdad ---
    if (accion === "invoice") {
      if (faltanSecretos()) {
        return json({ ok: false, error: "Faltan los secretos QB_CLIENT_ID y QB_CLIENT_SECRET en Supabase." }, 400);
      }
      const pedidoId = String(cuerpo.pedido ?? "");
      if (!pedidoId) return json({ ok: false, error: "Falta el pedido." }, 400);
      const deVerdad = cuerpo.de_verdad === true;
      const acceso = await accesoFresco();
      const plan = await planInvoice(acceso.token, acceso.realm, pedidoId);
      if (!deVerdad || plan.problemas.length) {
        return json({ ok: !plan.problemas.length, de_verdad: false, resumen: plan.resumen });
      }
      // Se aparta el pedido ANTES de llamar a Intuit: si alguien aprieta dos
      // veces, la segunda ya no encuentra el pedido libre.
      const apartado = await base(
        `gd_pedidos?id=eq.${encodeURIComponent(pedidoId)}&qb_invoice_id=is.null`,
        { method: "PATCH", headers: { Prefer: "return=representation" },
          body: JSON.stringify({ qb_invoice_id: "creando" }) },
      );
      if (!apartado?.length) return json({ ok: false, error: "Este pedido ya tiene invoice o se esta creando." }, 400);
      let inv;
      try {
        inv = await creaInvoice(acceso.token, acceso.realm, plan);
      } catch (e) {
        await base(`gd_pedidos?id=eq.${encodeURIComponent(pedidoId)}`, {
          method: "PATCH", body: JSON.stringify({ qb_invoice_id: null }),
        }).catch(() => {});
        throw e;
      }
      await base(`gd_pedidos?id=eq.${encodeURIComponent(pedidoId)}`, {
        method: "PATCH",
        body: JSON.stringify({
          qb_invoice_id: String(inv?.Id ?? ""),
          qb_invoice_num: inv?.DocNumber ? String(inv.DocNumber) : null,
          qb_invoice_total: inv?.TotalAmt ?? plan.total,
          qb_invoice_el: new Date().toISOString(),
        }),
      });
      return json({
        ok: true, de_verdad: true, resumen: plan.resumen,
        invoice: { id: inv?.Id, numero: inv?.DocNumber ?? null, total: inv?.TotalAmt ?? plan.total },
      });
    }

    return json({ ok: false, error: `No conozco la accion "${accion}".` }, 400);
  } catch (e) {
    return json({ ok: false, productos: 0, error: String(e.message ?? e) }, 400);
  }
});
