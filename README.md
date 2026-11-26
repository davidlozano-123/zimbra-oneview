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
Navegador (frontend)  ──HTTP/JSON──▶  FastAPI (main.py)  ──mysql-connector──▶  MySQL (zimbra2)
```

El navegador nunca habla con MySQL. Solo habla con la API, y la API es la única que tiene las credenciales.

## Requisitos

- Python 3.10 o superior (en Windows, marca **Add python.exe to PATH** al instalar)
- MySQL Server 8 y MySQL Workbench
- Git (opcional, para clonar el repositorio)

## Ejecutar en tu computador

1. **Descargar el proyecto**
   ```bash
   git clone https://github.com/davidlozano-123/zimbra-oneview.git
   cd zimbra-oneview
   ```
   Sin Git: botón verde **Code → Download ZIP** y descomprimir.

2. **Crear la base de datos**: abre `database/zimbra2.sql` en MySQL Workbench y ejecútalo completo (ícono del rayo). Recrea la base `zimbra2` desde cero.
   - Revisa que debajo de `USE zimbra2;` esté la línea `SET SQL_SAFE_UPDATES = 0;`. Sin ella, Workbench detiene el script con el error 1175.
   - Anota el puerto de tu MySQL: `SHOW VARIABLES LIKE 'port';` (normalmente 3306).

3. **Configurar credenciales**: copia `.env.example` como `.env` y escribe tus datos de MySQL.
   ```
   DB_HOST=127.0.0.1
   DB_PORT=3306
   DB_USER=root
   DB_PASSWORD=tu_password
   DB_NAME=zimbra2
   ```
   `DB_NAME` debe coincidir con el nombre que crea el script. El archivo `.env` no se sube a GitHub.

4. **Crear el entorno e instalar dependencias**

   Windows (PowerShell):
   ```powershell
   python -m venv .venv
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .venv\Scripts\Activate.ps1
   pip install -r requirements.txt
   ```
   Mac / Linux:
   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   pip install -r requirements.txt
   ```

5. **Arrancar**
   ```bash
   uvicorn main:app --reload
   ```

6. **Abrir**
   - Aplicación: http://127.0.0.1:8000
   - Documentación de la API: http://127.0.0.1:8000/docs

El indicador de la esquina superior derecha debe decir "API y base de datos conectadas".

Cada vez que vuelvas a trabajar, repite solo los pasos de activar el entorno (4, sin `pip install`) y arrancar (5). Si cambias `.env`, reinicia Uvicorn: el archivo se lee solo al arrancar.

## Problemas frecuentes

| Lo que ves | Solución |
|---|---|
| `Can't connect to MySQL server ... (10061)` | Revisa `DB_PORT` en `.env` y que el servicio MySQL esté iniciado |
| `Access denied for user` | Corrige `DB_USER` y `DB_PASSWORD` en `.env` |
| `Unknown database` | `DB_NAME` no coincide con la base creada por el script |
| Todos los prospectos con puntaje 20 y estado Nuevo | El script quedó a medias o `DB_NAME` apunta a otra base. Ejecuta el script completo y reinicia Uvicorn |
| Error 1175 en Workbench | Falta `SET SQL_SAFE_UPDATES = 0;` en el script |
| `source` no se reconoce en Windows | Usa `.venv\Scripts\Activate.ps1` |

## Subir cambios a GitHub

```bash
git status          # verifica que .env NO aparezca en la lista
git add .
git commit -m "Describe lo que cambiaste"
git pull --rebase origin main
git push origin main
```

El `pull --rebase` evita el rechazo del `push` cuando otra persona del equipo subió cambios antes. No uses `git push --force`.

## Importante sobre la base de datos y GitHub

- GitHub **no aloja MySQL en ejecución**. El repositorio guarda el *script* (`zimbra2.sql`), no los datos vivos. Cada persona crea su base ejecutando ese script.
- **Nunca subas `.env`**: contiene tu contraseña. Ya está en `.gitignore`; solo se sube `.env.example`.
- GitHub Pages solo sirve archivos estáticos, así que no puede ejecutar FastAPI. Si quieres publicar en línea, el backend y la base van en un servicio aparte (Railway, Render, Fly.io, un VPS) y el frontend apunta a él con `config.js` (`API_BASE`) y `CORS_ORIGINS` en el `.env` del servidor.
- Para un despliegue en línea necesitas una MySQL accesible por el backend y cargar `zimbra2.sql` allí.

## Pantallas

| Pantalla | Qué hace | Endpoint |
|---|---|---|
| Resumen | Indicadores del embudo y prospectos calificados | `GET /reportes/conversion`, `GET /reportes/prospectos-calificados` |
| Prospectos | Listado con filtros, búsqueda y cambio de estado | `GET /prospectos`, `PUT /prospectos/{id}/estado` |
| Nueva descarga | Registra la prueba de 60 días | `POST /prospectos/descarga` |
| Cerrar venta | Venta con savepoints; muestra si hubo commit o rollback | `POST /ventas` |
| Alertas | Alertas de un vendedor | `GET /alertas/{id}` |
| Cartera | Reasigna prospectos entre vendedores | `POST /vendedores/reasignar`, `GET /vendedores` |
