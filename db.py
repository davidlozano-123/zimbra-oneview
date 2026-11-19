"""Conexión a MySQL con pool de conexiones y manejo de transacciones."""
import os
from contextlib import contextmanager

import mysql.connector
from mysql.connector import pooling
from dotenv import load_dotenv

load_dotenv()

_config = {
    "host": os.getenv("DB_HOST", "127.0.0.1"),
    "port": int(os.getenv("DB_PORT", "3306")),
    "user": os.getenv("DB_USER", "root"),
    "password": os.getenv("DB_PASSWORD", ""),
    "database": os.getenv("DB_NAME", "zimbra_oneview"),
    "charset": "utf8mb4",
    "autocommit": False,  # las transacciones se controlan explícitamente
}

# El pool reutiliza conexiones: útil para el volumen de eventos web del caso
_pool = pooling.MySQLConnectionPool(
    pool_name="zimbra_pool",
    pool_size=int(os.getenv("DB_POOL_SIZE", "5")),
    **_config,
)


@contextmanager
def transaccion():
    """Entrega (conexion, cursor) dentro de una transacción.

    - Si el bloque termina bien  -> COMMIT
    - Si ocurre cualquier error  -> ROLLBACK y se vuelve a lanzar la excepción
    """
    conn = _pool.get_connection()
    cursor = conn.cursor(dictionary=True)
    try:
        yield conn, cursor
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cursor.close()
        conn.close()  # devuelve la conexión al pool


def consultar(sql, params=None):
    """Ejecuta un SELECT y devuelve una lista de diccionarios."""
    with transaccion() as (_, cur):
        cur.execute(sql, params or ())
        return cur.fetchall()


def probar_conexion() -> bool:
    try:
        return bool(consultar("SELECT 1 AS ok"))
    except mysql.connector.Error:
        return False
