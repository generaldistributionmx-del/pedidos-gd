// ============================================================================
//  Funcion de servidor: da de alta a alguien del equipo de General Distribution.
//
//  POR QUE EXISTE: crear una cuenta necesita la llave MAESTRA de Supabase
//  (service_role), que abre TODA la base. Esa llave nunca puede estar en el
//  navegador ni en el telefono de nadie. Aqui vive segura, en el servidor.
//
//  Quien llama manda su sesion; esta funcion revisa que sea dueno ACTIVO
//  antes de hacer nada.
//
//  Se despliega en: Supabase -> Edge Functions -> nombre: gd-crear-usuario
//  Con verify_jwt ACTIVADO.
// ============================================================================
import { createClient } from 'jsr:@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function resp(cuerpo: unknown, status: number) {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return resp({ error: 'Solo POST.' }, 405)

  try {
    const jwt = (req.headers.get('Authorization') ?? '').replace('Bearer ', '').trim()
    if (!jwt) return resp({ error: 'Falta la sesion.' }, 401)

    // Estas dos variables las pone Supabase solo. No se escriben a mano.
    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )

    const { data: quien, error: eQuien } = await admin.auth.getUser(jwt)
    if (eQuien || !quien?.user) return resp({ error: 'Tu sesion ya vencio. Vuelve a entrar.' }, 401)

    // LA REVISION QUE IMPORTA: solo un dueno activo puede dar de alta.
    const { data: perfil } = await admin
      .from('gd_perfiles')
      .select('rol, activo')
      .eq('id', quien.user.id)
      .maybeSingle()

    if (!perfil || perfil.activo !== true || !['dueno', 'oficina'].includes(perfil.rol)) {
      return resp({ error: 'Solo el dueno o la oficina pueden dar de alta a alguien.' }, 403)
    }

    const body = await req.json().catch(() => ({}))
    const nombre = String(body.nombre ?? '').trim()
    const email = String(body.email ?? '').trim().toLowerCase()
    const clave = String(body.clave ?? '')

    if (!nombre) return resp({ error: 'Falta el nombre.' }, 400)
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return resp({ error: 'Ese correo no se ve bien. Revisa que no traiga espacios.' }, 400)
    }
    if (clave.length < 8) return resp({ error: 'La contrasena debe tener al menos 8 letras o numeros.' }, 400)

    // app:'gd' es lo que hace que el disparador le cree su gafete en gd_perfiles.
    // Sin eso, la cuenta nace pero no puede entrar al panel.
    const { data: nuevo, error: eCrear } = await admin.auth.admin.createUser({
      email,
      password: clave,
      email_confirm: true,
      user_metadata: { app: 'gd', nombre },
    })

    if (eCrear) {
      const m = eCrear.message || ''
      if (m.toLowerCase().includes('already')) return resp({ error: 'Ese correo ya tiene cuenta.' }, 400)
      return resp({ error: m }, 400)
    }

    return resp({ ok: true, id: nuevo.user?.id, nombre, email }, 200)
  } catch (e) {
    return resp({ error: 'Algo fallo: ' + String(e) }, 500)
  }
})
