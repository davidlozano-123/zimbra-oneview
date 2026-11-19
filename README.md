# Zimbra OneView

Sistema de gestión de prospectos y ventas: **MySQL** (base de datos) + **FastAPI** (backend) + **HTML/CSS/JS** (frontend).

```
zimbra-oneview/
├── database/zimbra2.sql   Script completo de la base (tablas, triggers, procedimientos, datos)
├── db.py                  Conexión a MySQL con pool y transacciones
├── main.py                API REST (FastAPI) y servidor del frontend
├── requirements.txt       Dependencias de Python
├── .env.example           Plantilla de credenciales (se copia a .env)
└── frontend/
    ├── index.html         Estructura de las pantallas
    ├── styles.css         Estilos
    ├── app.js             Lógica: llama a la API y pinta los datos
    └── config.js          URL base de la API
```

Cómo se conectan las piezas:

```
Navegador (frontend)  ──HTTP/JSON──▶  FastAPI (main.py)  ──mysql-connector──▶  MySQL (zimbra_oneview)
```

El navegador nunca habla con MySQL. Solo habla con la API, y la API es la única que tiene las credenciales.

## Ejecutar en tu computador

1. Crear la base: abre `database/zimbra2.sql` en MySQL Workbench y ejecútalo completo (recrea `zimbra_oneview` desde cero).
2. Crear el entorno e instalar dependencias:
   ```bash
   python -m venv .venv
   source .venv/bin/activate        # Windows: .venv\Scripts\activate
   pip install -r requirements.txt
   ```
3. Configurar credenciales: copia `.env.example` como `.env` y escribe tu contraseña de MySQL.
4. Arrancar:
   ```bash
   uvicorn main:app --reload
   ```
5. Abrir:
   - Aplicación: http://127.0.0.1:8000
   - Documentación de la API: http://127.0.0.1:8000/docs

El indicador de la esquina superior derecha debe decir "API y base de datos conectadas".

## Subir a GitHub

```bash
cd zimbra-oneview
git init
git add .
git status          # verifica que .env NO aparezca en la lista
git commit -m "Zimbra OneView: base de datos, API y frontend"
git branch -M main
```

Crea un repositorio vacío en github.com (botón **New**, sin README ni .gitignore) y luego:

```bash
git remote add origin https://github.com/TU_USUARIO/zimbra-oneview.git
git push -u origin main
```

Si GitHub pide contraseña, usa un **Personal Access Token** (Settings → Developer settings → Tokens) o inicia sesión con `gh auth login`.

Para que otra persona (o tú en otro equipo) lo use: `git clone ...`, crear su propio `.env` y seguir los pasos de arriba.

## Importante sobre la base de datos y GitHub

- GitHub **no aloja MySQL en ejecución**. El repositorio guarda el *script* (`zimbra2.sql`), no los datos vivos. Cada persona crea su base ejecutando ese script.
- **Nunca subas `.env`**: contiene tu contraseña. Ya está en `.gitignore`; solo se sube `.env.example`.
- GitHub Pages solo sirve archivos estáticos, así que no puede ejecutar FastAPI. Si quieres publicar en línea, el backend y la base van en un servicio aparte (Railway, Render, Fly.io, un VPS) y el frontend apunta a él con `config.js` (`API_BASE`) y `CORS_ORIGINS` en el `.env` del servidor.
- Para un despliegue en línea necesitas una MySQL accesible por el backend (Railway, PlanetScale, Aiven, o la de tu servidor) y cargar `zimbra2.sql` allí.

## Pantallas

| Pantalla | Qué hace | Endpoint |
|---|---|---|
| Resumen | Indicadores del embudo y prospectos calificados | `GET /reportes/conversion`, `GET /reportes/prospectos-calificados` |
| Prospectos | Listado con filtros, búsqueda y cambio de estado | `GET /prospectos`, `PUT /prospectos/{id}/estado` |
| Nueva descarga | Registra la prueba de 60 días | `POST /prospectos/descarga` |
| Cerrar venta | Venta con savepoints; muestra si hubo commit o rollback | `POST /ventas` |
| Alertas | Alertas de un vendedor | `GET /alertas/{id}` |
| Cartera | Reasigna prospectos entre vendedores | `POST /vendedores/reasignar`, `GET /vendedores` |
