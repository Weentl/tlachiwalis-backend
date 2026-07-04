# Google OAuth (comprador) — cómo conectarlo

El **código ya está listo**: botón "Continuar con Google" en `/entrar` y `/registrarse`, y el
callback `/auth/callback` (intercambia el `code` por la sesión, PKCE). Solo falta habilitar Google
en Google Cloud + Supabase. **Ahora que estás en Supabase Cloud (HTTPS incluido), es fácil** — se
configura desde el DASHBOARD, no por env vars de GoTrue.

## 1. Google Cloud Console
- APIs & Services → **Credentials** → *Create credentials* → **OAuth client ID** → tipo *Web
  application*.
- Configura la **OAuth consent screen** (User type: External; scopes `email` y `profile`; puedes
  dejarla en "Testing" y agregarte como test user).
- En el OAuth client, **Authorized redirect URIs**, agrega:
  `https://kroztevhrmcoofxhxfgn.supabase.co/auth/v1/callback`
  (el callback de tu proyecto Supabase — es HTTPS, Google lo acepta).
- Copia el **Client ID** y **Client Secret**.

## 2. Supabase Dashboard (tu proyecto)
- **Authentication → Providers → Google** → habilítalo → pega **Client ID** y **Client Secret** →
  Save.
- **Authentication → URL Configuration**:
  - *Site URL*: `http://localhost:3000` (en dev) — cámbialo a tu dominio en prod.
  - *Redirect URLs* (allow list): agrega `http://localhost:3000/auth/callback` (y tu prod
    `https://tudominio.com/auth/callback` cuando lo tengas). **Debe matchear EXACTO** o el redirect
    falla en silencio.

## 3. Listo
Recarga `/entrar` o `/registrarse` → "Continuar con Google" → consentimiento de Google → vuelve a
`/cuenta` ya logueado. El trigger `handle_new_user` (0023) crea el perfil con el nombre/avatar que
entrega Google.

## Notas
- El botón ya funciona en el código; hoy falla porque `external.google=false` en tu proyecto.
  Tras el paso 2 se activa.
- OAuth crea la cuenta aunque el signup por correo esté cerrado — es normal y seguro.
- Si luego muestras el avatar de Google, `next.config.ts` ya permite `*.stripe.com`/Supabase en
  `img-src`; para el avatar de Google añade `https://lh3.googleusercontent.com` a `img-src`.
- (Self-hosted, referencia) Si volvieras a GoTrue self-hosted: `GOTRUE_EXTERNAL_GOOGLE_ENABLED=true`
  + `_CLIENT_ID`/`_SECRET`/`_REDIRECT_URI` + `GOTRUE_URI_ALLOW_LIST` + `GOTRUE_SITE_URL`, y GoTrue
  DEBE estar por HTTPS (Google no acepta redirect http salvo localhost).
