"""Back-end inicial del caso Zimbra / OneView (FastAPI + MySQL).

Ejecutar:   uvicorn main:app --reload
Pruebas:    http://127.0.0.1:8000/docs   (Swagger, sin necesitar Postman)
"""
from typing import Literal, Optional

import os
from pathlib import Path

import mysql.connector
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, EmailStr, Field

import db

app = FastAPI(title="Zimbra OneView API", version="0.2.0")

# CORS: solo hace falta si el frontend se publica en OTRO dominio (p. ej. GitHub Pages).
# Con el frontend servido por este mismo FastAPI no se usa. Ejemplo en .env:
#   CORS_ORIGINS=https://tu-usuario.github.io
_origenes = [o.strip() for o in os.getenv("CORS_ORIGINS", "").split(",") if o.strip()]
if _origenes:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=_origenes,
        allow_methods=["*"],
        allow_headers=["*"],
    )

# Carpeta del frontend (se sirve al final de este archivo, en la raíz "/")
FRONTEND_DIR = Path(__file__).parent / "frontend"


# ---------------------------------------------------------------------
# Esquemas de entrada (validan los datos antes de llegar a la BD)
# ---------------------------------------------------------------------
class DescargaIn(BaseModel):
    nombre: str = Field(min_length=2, max_length=100)
    empresa: Optional[str] = None
    cargo: Optional[str] = None
    correo: EmailStr
    telefono: Optional[str] = None
    pais: Optional[str] = None
    id_version: int = 2          # 2 = prueba de 60 días
    cookie: str = Field(min_length=3, max_length=64)


class VisitaIn(BaseModel):
    id_prospecto: Optional[int] = None   # None = visitante anónimo
    cookie: str = Field(min_length=3, max_length=64)
    pagina: str
    tipo_evento: Literal["pagina", "precios", "descarga", "uso_prueba", "contacto"] = "pagina"


class EstadoIn(BaseModel):
    estado: Literal["nuevo", "contactado", "en_negociacion", "ganado", "perdido"]


class VentaIn(BaseModel):
    correo: EmailStr
    id_version: int
    modelo_licencia: Literal["lugares_ilimitados", "pagar_por_usar"]
    num_usuarios: int
    monto: float


class ReasignacionIn(BaseModel):
    id_origen: int
    id_destino: int


def _error_bd(e: mysql.connector.Error) -> HTTPException:
    """Traduce errores de MySQL a respuestas HTTP claras."""
    if e.errno == 1062:                      # clave duplicada
        return HTTPException(409, "Registro duplicado")
    if e.errno in (1451, 1452):              # violación de llave foránea
        return HTTPException(400, "Referencia inválida (llave foránea)")
    if e.errno == 3819:                      # violación de CHECK
        return HTTPException(400, "Valor fuera de las reglas de la tabla")
    if e.errno == 1644:                      # SIGNAL de un trigger o procedimiento (regla de negocio)
        return HTTPException(422, e.msg)
    return HTTPException(500, f"Error de base de datos: {e.msg}")


# ---------------------------------------------------------------------
# Salud
# ---------------------------------------------------------------------
@app.get("/health")
def health():
    return {"api": "ok", "base_de_datos": "ok" if db.probar_conexion() else "sin conexión"}


# ---------------------------------------------------------------------
# Catálogos (alimentan las listas desplegables del frontend)
# ---------------------------------------------------------------------
@app.get("/vendedores")
def listar_vendedores():
    try:
        return db.consultar(
            """SELECT v.id_vendedor, v.nombre, v.rol, v.activo,
                      (SELECT COUNT(*) FROM prospecto p
                       WHERE p.id_vendedor = v.id_vendedor
                         AND p.estado NOT IN ('ganado','perdido')) AS prospectos_activos
               FROM vendedor v ORDER BY v.nombre"""
        )
    except mysql.connector.Error as e:
        raise _error_bd(e)


@app.get("/versiones")
def listar_versiones(tipo: Optional[Literal["gratuita", "prueba", "comercial"]] = None):
    sql = "SELECT id_version, nombre, tipo FROM version_producto"
    params = []
    if tipo:
        sql += " WHERE tipo = %s"
        params.append(tipo)
    sql += " ORDER BY nombre"
    try:
        return db.consultar(sql, params)
    except mysql.connector.Error as e:
        raise _error_bd(e)


# ---------------------------------------------------------------------
# Prospectos
# ---------------------------------------------------------------------
@app.get("/prospectos")
def listar_prospectos(
    calificado: Optional[bool] = None,
    estado: Optional[str] = None,
    limite: int = Query(50, ge=1, le=200),
):
    sql = """SELECT p.id_prospecto, p.nombre, p.empresa, p.correo, p.puntaje,
                    p.calificado, p.estado, v.nombre AS vendedor
             FROM prospecto p LEFT JOIN vendedor v ON v.id_vendedor = p.id_vendedor
             WHERE 1=1"""
    params = []
    if calificado is not None:
        sql += " AND p.calificado = %s"
        params.append(int(calificado))
    if estado:
        sql += " AND p.estado = %s"
        params.append(estado)
    sql += " ORDER BY p.puntaje DESC LIMIT %s"
    params.append(limite)
    try:
        return db.consultar(sql, params)
    except mysql.connector.Error as e:
        raise _error_bd(e)


@app.get("/prospectos/{id_prospecto}")
def obtener_prospecto(id_prospecto: int):
    try:
        filas = db.consultar("SELECT * FROM prospecto WHERE id_prospecto = %s", (id_prospecto,))
    except mysql.connector.Error as e:
        raise _error_bd(e)
    if not filas:
        raise HTTPException(404, "Prospecto no encontrado")
    return filas[0]


@app.put("/prospectos/{id_prospecto}/estado")
def cambiar_estado(id_prospecto: int, datos: EstadoIn):
    """Transacción controlada desde Python: estado + contacto, o nada."""
    try:
        with db.transaccion() as (_, cur):
            cur.execute(
                "SELECT id_vendedor FROM prospecto WHERE id_prospecto = %s FOR UPDATE",
                (id_prospecto,),
            )
            fila = cur.fetchone()
            if fila is None:
                raise HTTPException(404, "Prospecto no encontrado")
            cur.execute(
                "UPDATE prospecto SET estado = %s WHERE id_prospecto = %s",
                (datos.estado, id_prospecto),
            )
            if fila["id_vendedor"] is not None:
                cur.execute(
                    """INSERT INTO contacto_seguimiento
                       (id_prospecto, id_vendedor, medio, resultado, notas)
                       VALUES (%s, %s, 'correo', %s, 'Cambio de estado desde la API')""",
                    (id_prospecto, fila["id_vendedor"], f"Estado: {datos.estado}"),
                )
        # el COMMIT ocurre al salir del bloque "with"
        return {"mensaje": "Estado actualizado", "estado": datos.estado}
    except mysql.connector.Error as e:   # el ROLLBACK ya se hizo en db.transaccion
        raise _error_bd(e)


@app.post("/prospectos/descarga", status_code=201)
def registrar_descarga(d: DescargaIn):
    """Descarga de la prueba de 60 días: usa el procedimiento almacenado."""
    try:
        with db.transaccion() as (_, cur):
            cur.callproc(
                "sp_registrar_descarga",
                [d.nombre, d.empresa, d.cargo, d.correo, d.telefono, d.pais, d.id_version, d.cookie],
            )
            for _ in cur.stored_results():
                pass
            cur.execute("SELECT id_prospecto, puntaje, calificado FROM prospecto WHERE correo = %s", (d.correo,))
            return cur.fetchone()
    except mysql.connector.Error as e:
        raise _error_bd(e)


# ---------------------------------------------------------------------
# Rastreo web y alertas
# ---------------------------------------------------------------------
@app.post("/visitas", status_code=201)
def registrar_visita(v: VisitaIn):
    """Registra la visita; el trigger suma puntos y genera alertas."""
    try:
        with db.transaccion() as (_, cur):
            cur.execute(
                """INSERT INTO visita_web (id_prospecto, cookie_visitante, pagina, tipo_evento)
                   VALUES (%s, %s, %s, %s)""",
                (v.id_prospecto, v.cookie, v.pagina, v.tipo_evento),
            )
            resultado = {"id_visita": cur.lastrowid}
            if v.id_prospecto:
                cur.execute(
                    "SELECT puntaje, calificado FROM prospecto WHERE id_prospecto = %s",
                    (v.id_prospecto,),
                )
                resultado.update(cur.fetchone() or {})
            return resultado
    except mysql.connector.Error as e:
        raise _error_bd(e)


@app.get("/alertas/{id_vendedor}")
def alertas_vendedor(id_vendedor: int, solo_no_leidas: bool = True):
    sql = "SELECT * FROM alerta WHERE id_vendedor = %s"
    if solo_no_leidas:
        sql += " AND leida = 0"
    sql += " ORDER BY fecha_hora DESC"
    try:
        return db.consultar(sql, (id_vendedor,))
    except mysql.connector.Error as e:
        raise _error_bd(e)


# ---------------------------------------------------------------------
# Ventas y cartera (procedimientos con transacciones y savepoints)
# ---------------------------------------------------------------------
@app.post("/ventas")
def cerrar_venta(v: VentaIn):
    """Llama a sp_cerrar_venta_savepoints. Devuelve qué pasó (commit o rollback)."""
    try:
        with db.transaccion() as (_, cur):
            args = cur.callproc(
                "sp_cerrar_venta_savepoints",
                [v.correo, v.id_version, v.modelo_licencia, v.num_usuarios, v.monto, ""],
            )
            for _ in cur.stored_results():
                pass
            resultado = args[5]
    except mysql.connector.Error as e:
        raise _error_bd(e)

    if isinstance(resultado, bytes):
        resultado = resultado.decode("utf-8")
    exito = str(resultado).startswith("COMMIT")
    if not exito:
        # No es un fallo del servidor: la BD se recuperó (rollback total o parcial)
        raise HTTPException(status_code=422, detail=resultado)
    return {"exito": True, "resultado": resultado}


@app.post("/vendedores/reasignar")
def reasignar_cartera(r: ReasignacionIn):
    try:
        with db.transaccion() as (_, cur):
            args = cur.callproc("sp_reasignar_cartera", [r.id_origen, r.id_destino, ""])
            for _ in cur.stored_results():
                pass
            resultado = args[2]
    except mysql.connector.Error as e:
        raise _error_bd(e)

    if isinstance(resultado, bytes):
        resultado = resultado.decode("utf-8")
    if not str(resultado).startswith("COMMIT"):
        raise HTTPException(status_code=422, detail=resultado)
    return {"exito": True, "resultado": resultado}


# ---------------------------------------------------------------------
# Reportes (usan las vistas del script SQL)
# ---------------------------------------------------------------------
@app.get("/reportes/conversion")
def reporte_conversion():
    try:
        return db.consultar("SELECT * FROM v_conversion")[0]
    except mysql.connector.Error as e:
        raise _error_bd(e)


@app.get("/reportes/prospectos-calificados")
def reporte_calificados():
    try:
        return db.consultar("SELECT * FROM v_prospectos_calificados")
    except mysql.connector.Error as e:
        raise _error_bd(e)


# ---------------------------------------------------------------------
# Frontend (archivos estáticos)
# Debe ir AL FINAL: si se montara antes, "/" taparía las rutas de la API.
# ---------------------------------------------------------------------
if FRONTEND_DIR.exists():
    app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="frontend")
