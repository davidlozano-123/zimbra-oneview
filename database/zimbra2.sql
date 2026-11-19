-- =====================================================================
-- CASO ZIMBRA / ONEVIEW  -  SCRIPT COMPLETO (MySQL 8.x / Workbench)
-- Sesión 1: tablas, procedimientos, triggers, vistas y datos de prueba
-- Sesión 2: transacciones ACID, savepoints, simulación de errores
-- Ejecutar completo (rayo / Ctrl+Shift+Enter). Recrea la base desde cero.
--
-- ACID en este script:
--   Atomicidad    -> una operación de varios pasos se guarda completa o no se
--                    guarda (START TRANSACTION / COMMIT / ROLLBACK / SAVEPOINT)
--   Consistencia  -> CHECK, FOREIGN KEY, UNIQUE, ENUM y triggers con SIGNAL
--                    impiden datos inválidos
--   Aislamiento   -> SELECT ... FOR UPDATE bloquea la fila mientras se modifica
--                    (nivel por defecto de InnoDB: REPEATABLE READ)
--   Durabilidad   -> InnoDB + COMMIT: los cambios confirmados permanecen
--
-- Datos simulados: cada tabla tiene como mínimo 30 registros (ver la
-- consulta de verificación al final del script).
-- =====================================================================

DROP DATABASE IF EXISTS zimbra_oneview;
CREATE DATABASE zimbra_oneview CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE zimbra_oneview;

-- Workbench activa el "modo seguro" (error 1175) y bloquea los UPDATE sin WHERE sobre
-- una columna clave. Este script los necesita para repartir fechas y preferencias de
-- los datos de prueba, así que se desactiva SOLO para esta sesión.
SET SQL_SAFE_UPDATES = 0;

-- =====================================================================
-- 1. TABLAS
-- =====================================================================

-- Fuerza de ventas (hasta ~30 vendedores)  [RNF: escalabilidad de usuarios]
CREATE TABLE vendedor (
    id_vendedor     INT AUTO_INCREMENT PRIMARY KEY,
    nombre          VARCHAR(100) NOT NULL,
    correo          VARCHAR(120) NOT NULL UNIQUE,
    rol             ENUM('vendedor','marketing','gerente','administrador') NOT NULL DEFAULT 'vendedor',
    activo          TINYINT(1) NOT NULL DEFAULT 1,
    fecha_ingreso   DATE NOT NULL DEFAULT (CURRENT_DATE)
) ENGINE=InnoDB;

-- Catálogo: versión gratuita y versiones comerciales
CREATE TABLE version_producto (
    id_version      INT AUTO_INCREMENT PRIMARY KEY,
    nombre          VARCHAR(80) NOT NULL UNIQUE,
    tipo            ENUM('gratuita','prueba','comercial') NOT NULL,
    descripcion     VARCHAR(255)
) ENGINE=InnoDB;

-- Prospectos de ventas  [RF 2, 7, 8, 9]
CREATE TABLE prospecto (
    id_prospecto        INT AUTO_INCREMENT PRIMARY KEY,
    nombre              VARCHAR(100) NOT NULL,
    empresa             VARCHAR(120),
    cargo               VARCHAR(80),
    correo              VARCHAR(120) NOT NULL UNIQUE,      -- evita duplicados
    telefono            VARCHAR(30),
    pais                VARCHAR(60),
    origen              ENUM('sitio_web','referido','campana') NOT NULL DEFAULT 'sitio_web',
    preferencia_contacto ENUM('telefono','correo') NOT NULL DEFAULT 'correo',
    horario_preferido   VARCHAR(40),
    puntaje             INT NOT NULL DEFAULT 0 CHECK (puntaje >= 0),
    calificado          TINYINT(1) NOT NULL DEFAULT 0,
    estado              ENUM('nuevo','contactado','en_negociacion','ganado','perdido') NOT NULL DEFAULT 'nuevo',
    id_vendedor         INT NULL,
    acepta_rastreo      TINYINT(1) NOT NULL DEFAULT 1,     -- consentimiento de rastreo
    acepta_correos      TINYINT(1) NOT NULL DEFAULT 1,     -- baja de comunicaciones
    fecha_registro      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_prospecto_vendedor FOREIGN KEY (id_vendedor) REFERENCES vendedor(id_vendedor),
    INDEX idx_prospecto_estado (estado),
    INDEX idx_prospecto_calificado (calificado)
) ENGINE=InnoDB;

-- Descarga de la versión de prueba de 60 días  [RF 2, 7, 8]
CREATE TABLE descarga_prueba (
    id_descarga         INT AUTO_INCREMENT PRIMARY KEY,
    id_prospecto        INT NOT NULL,
    id_version          INT NOT NULL,
    fecha_inicio        DATE NOT NULL,
    fecha_vencimiento   DATE NOT NULL,
    estado              ENUM('activa','vencida','convertida') NOT NULL DEFAULT 'activa',
    CONSTRAINT chk_descarga_fechas CHECK (fecha_vencimiento >= fecha_inicio),
    CONSTRAINT fk_descarga_prospecto FOREIGN KEY (id_prospecto) REFERENCES prospecto(id_prospecto),
    CONSTRAINT fk_descarga_version   FOREIGN KEY (id_version)   REFERENCES version_producto(id_version),
    INDEX idx_descarga_venc (fecha_vencimiento, estado)
) ENGINE=InnoDB;

-- Rastreo de visitas al sitio web (~200.000 visitantes por semana)  [RF 1, 2, 6, 9]
-- id_prospecto es NULL mientras el visitante es anónimo.
CREATE TABLE visita_web (
    id_visita       BIGINT AUTO_INCREMENT PRIMARY KEY,
    id_prospecto    INT NULL,
    cookie_visitante VARCHAR(64) NOT NULL,
    pagina          VARCHAR(255) NOT NULL,
    tipo_evento     ENUM('pagina','precios','descarga','uso_prueba','contacto') NOT NULL DEFAULT 'pagina',
    fecha_hora      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_visita_prospecto FOREIGN KEY (id_prospecto) REFERENCES prospecto(id_prospecto),
    INDEX idx_visita_prospecto_fecha (id_prospecto, fecha_hora),
    INDEX idx_visita_fecha (fecha_hora)
) ENGINE=InnoDB;

-- Reglas de calificación configurables sin programar  [RF 8, 10]
-- pagina_patron = '%' es la regla general del tipo de evento; un patrón más
-- específico (LIKE) tiene prioridad. Así el puntaje se puede ajustar por página.
CREATE TABLE regla_puntaje (
    id_regla        INT AUTO_INCREMENT PRIMARY KEY,
    tipo_evento     ENUM('pagina','precios','descarga','uso_prueba','contacto') NOT NULL,
    pagina_patron   VARCHAR(100) NOT NULL DEFAULT '%',
    puntos          INT NOT NULL CHECK (puntos >= 0),
    activo          TINYINT(1) NOT NULL DEFAULT 1,
    descripcion     VARCHAR(150),
    UNIQUE KEY uq_regla (tipo_evento, pagina_patron)
) ENGINE=InnoDB;

CREATE TABLE configuracion (
    clave           VARCHAR(50) PRIMARY KEY,
    valor           VARCHAR(100) NOT NULL,
    descripcion     VARCHAR(200)
) ENGINE=InnoDB;

-- Alertas a vendedores cuando un prospecto calificado visita el sitio  [RF 3]
CREATE TABLE alerta (
    id_alerta       INT AUTO_INCREMENT PRIMARY KEY,
    id_prospecto    INT NOT NULL,
    id_vendedor     INT NOT NULL,
    mensaje         VARCHAR(255) NOT NULL,
    fecha_hora      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    leida           TINYINT(1) NOT NULL DEFAULT 0,
    CONSTRAINT fk_alerta_prospecto FOREIGN KEY (id_prospecto) REFERENCES prospecto(id_prospecto),
    CONSTRAINT fk_alerta_vendedor  FOREIGN KEY (id_vendedor)  REFERENCES vendedor(id_vendedor),
    INDEX idx_alerta_vendedor (id_vendedor, leida)
) ENGINE=InnoDB;

-- Seguimiento: llamadas y correos del vendedor
CREATE TABLE contacto_seguimiento (
    id_contacto     INT AUTO_INCREMENT PRIMARY KEY,
    id_prospecto    INT NOT NULL,
    id_vendedor     INT NOT NULL,
    medio           ENUM('llamada','correo') NOT NULL,
    fecha_hora      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    resultado       VARCHAR(120),
    notas           TEXT,
    proximo_seguimiento DATE NULL,
    CONSTRAINT fk_cont_prospecto FOREIGN KEY (id_prospecto) REFERENCES prospecto(id_prospecto),
    CONSTRAINT fk_cont_vendedor  FOREIGN KEY (id_vendedor)  REFERENCES vendedor(id_vendedor)
) ENGINE=InnoDB;

-- Cliente y venta cerrada con modelo de licenciamiento  [RNF: flexibilidad de costos]
CREATE TABLE venta (
    id_venta        INT AUTO_INCREMENT PRIMARY KEY,
    id_prospecto    INT NOT NULL,
    id_vendedor     INT NOT NULL,
    id_version      INT NOT NULL,
    modelo_licencia ENUM('lugares_ilimitados','pagar_por_usar') NOT NULL,
    num_usuarios    INT NOT NULL CHECK (num_usuarios > 0),
    monto           DECIMAL(12,2) NOT NULL CHECK (monto >= 0),
    fecha_venta     DATE NOT NULL DEFAULT (CURRENT_DATE),
    fecha_renovacion DATE NULL,
    CONSTRAINT chk_venta_renovacion CHECK (fecha_renovacion IS NULL OR fecha_renovacion >= fecha_venta),
    CONSTRAINT fk_venta_prospecto FOREIGN KEY (id_prospecto) REFERENCES prospecto(id_prospecto),
    CONSTRAINT fk_venta_vendedor  FOREIGN KEY (id_vendedor)  REFERENCES vendedor(id_vendedor),
    CONSTRAINT fk_venta_version   FOREIGN KEY (id_version)   REFERENCES version_producto(id_version)
) ENGINE=InnoDB;

-- Campañas y comunicación automatizada por correo  [RF 5]
CREATE TABLE campana (
    id_campana      INT AUTO_INCREMENT PRIMARY KEY,
    nombre          VARCHAR(100) NOT NULL,
    asunto          VARCHAR(150) NOT NULL,
    disparador      ENUM('manual','descarga_prueba','prueba_por_vencer','prospecto_calificado') NOT NULL DEFAULT 'manual',
    activa          TINYINT(1) NOT NULL DEFAULT 1,
    fecha_creacion  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE envio_correo (
    id_envio        BIGINT AUTO_INCREMENT PRIMARY KEY,
    id_campana      INT NOT NULL,
    id_prospecto    INT NOT NULL,
    fecha_envio     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    abierto         TINYINT(1) NOT NULL DEFAULT 0,
    clic            TINYINT(1) NOT NULL DEFAULT 0,
    convirtio       TINYINT(1) NOT NULL DEFAULT 0,
    CONSTRAINT fk_envio_campana   FOREIGN KEY (id_campana)   REFERENCES campana(id_campana),
    CONSTRAINT fk_envio_prospecto FOREIGN KEY (id_prospecto) REFERENCES prospecto(id_prospecto),
    INDEX idx_envio_campana (id_campana)
) ENGINE=InnoDB;

-- Campos de datos configurables sin programar lógica condicional  [RF 10]
CREATE TABLE campo_personalizado (
    id_campo        INT AUTO_INCREMENT PRIMARY KEY,
    nombre          VARCHAR(60) NOT NULL UNIQUE,
    tipo_dato       ENUM('texto','numero','fecha','booleano') NOT NULL DEFAULT 'texto'
) ENGINE=InnoDB;

CREATE TABLE valor_campo_prospecto (
    id_prospecto    INT NOT NULL,
    id_campo        INT NOT NULL,
    valor           VARCHAR(255),
    PRIMARY KEY (id_prospecto, id_campo),
    CONSTRAINT fk_vcp_prospecto FOREIGN KEY (id_prospecto) REFERENCES prospecto(id_prospecto),
    CONSTRAINT fk_vcp_campo     FOREIGN KEY (id_campo)     REFERENCES campo_personalizado(id_campo)
) ENGINE=InnoDB;

-- Integración con Salesforce.com  [RF 4]
CREATE TABLE sincronizacion_crm (
    id_sync         BIGINT AUTO_INCREMENT PRIMARY KEY,
    id_prospecto    INT NOT NULL,
    id_externo_crm  VARCHAR(40),
    direccion       ENUM('hacia_crm','desde_crm') NOT NULL,
    estado          ENUM('pendiente','exitosa','error') NOT NULL DEFAULT 'pendiente',
    fecha_hora      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    detalle         VARCHAR(255),
    CONSTRAINT fk_sync_prospecto FOREIGN KEY (id_prospecto) REFERENCES prospecto(id_prospecto),
    INDEX idx_sync_estado (estado)
) ENGINE=InnoDB;

-- Bitácora de cambios
CREATE TABLE bitacora (
    id_bitacora     BIGINT AUTO_INCREMENT PRIMARY KEY,
    tabla           VARCHAR(40) NOT NULL,
    id_registro     INT NOT NULL,
    accion          VARCHAR(40) NOT NULL,
    detalle         VARCHAR(255),
    fecha_hora      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- =====================================================================
-- 2. DATOS DE CONFIGURACIÓN (catálogos: 30 registros cada uno)
-- =====================================================================

INSERT INTO configuracion (clave, valor, descripcion) VALUES
('umbral_calificacion', '50', 'Puntaje mínimo para considerar calificado a un prospecto'),
('dias_prueba', '60', 'Duración de la versión de prueba en días'),
('dias_aviso_vencimiento', '7', 'Días antes del vencimiento para avisar al prospecto'),
('max_vendedores', '30', 'Máximo de vendedores en la fuerza de ventas'),
('visitantes_semana_objetivo', '200000', 'Visitantes semanales que debe soportar el sitio'),
('moneda', 'USD', 'Moneda de las ventas'),
('iva_pct', '19', 'Porcentaje de IVA aplicado en cotizaciones'),
('dias_renovacion', '365', 'Días para la renovación de la licencia'),
('max_intentos_sync_crm', '3', 'Reintentos de sincronización con el CRM'),
('horario_inicio_contacto', '08:00', 'Hora inicial de contacto a prospectos'),
('horario_fin_contacto', '18:00', 'Hora final de contacto a prospectos'),
('zona_horaria', 'America/Bogota', 'Zona horaria del sistema'),
('prefijo_cookie', 'ck-', 'Prefijo de las cookies de visitante'),
('retencion_visitas_dias', '365', 'Días de retención de visitas web'),
('correo_remitente', 'marketing@zimbra.com', 'Remitente de campañas'),
('alerta_prospecto_calificado', '1', 'Activa alertas por prospecto calificado'),
('max_alertas_por_dia', '20', 'Máximo de alertas diarias por vendedor'),
('dias_sin_contacto_alerta', '5', 'Días sin contacto para alertar al vendedor'),
('descuento_max_pct', '15', 'Descuento máximo permitido en una venta'),
('usuarios_min_venta', '1', 'Usuarios mínimos por venta'),
('usuarios_max_venta', '10000', 'Usuarios máximos por venta'),
('url_sitio', 'https://www.zimbra.com', 'Sitio web principal'),
('idioma_defecto', 'es', 'Idioma por defecto de la interfaz'),
('crm_destino', 'Salesforce', 'CRM externo integrado'),
('crm_sync_minutos', '15', 'Frecuencia de sincronización con el CRM'),
('puntos_max_por_dia', '100', 'Puntos máximos que un prospecto suma por día'),
('filas_por_pagina_reportes', '50', 'Filas por página en reportes'),
('dias_vigencia_cotizacion', '30', 'Días de vigencia de una cotización'),
('version_prueba_defecto', '2', 'Versión de prueba que se ofrece por defecto'),
('modelo_licencia_defecto', 'pagar_por_usar', 'Modelo de licenciamiento sugerido');

INSERT INTO regla_puntaje (tipo_evento, pagina_patron, puntos, descripcion) VALUES
('pagina', '%', 1, 'Visita a cualquier página'),
('precios', '%', 10, 'Visita a la página de precios'),
('descarga', '%', 20, 'Descarga de la versión de prueba'),
('uso_prueba', '%', 15, 'Uso de la versión de prueba'),
('contacto', '%', 25, 'Solicitud de contacto'),
('pagina', '/producto/correo', 2, 'Interés en correo'),
('pagina', '/producto/calendario', 2, 'Interés en calendario'),
('pagina', '/producto/seguridad', 3, 'Interés en seguridad'),
('pagina', '/producto/migracion', 4, 'Interés en migración'),
('pagina', '/producto/colaboracion', 3, 'Interés en colaboración'),
('pagina', '/producto/movil', 3, 'Interés en móvil'),
('pagina', '/producto/archivado', 3, 'Interés en archivado'),
('pagina', '/casos-de-exito', 3, 'Lectura de casos de éxito'),
('pagina', '/webinars', 4, 'Visita a webinars'),
('pagina', '/documentacion%', 2, 'Lectura de documentación'),
('pagina', '/blog%', 1, 'Lectura del blog'),
('pagina', '/empresa/acerca', 0, 'Página informativa sin puntos'),
('precios', '/precios/enterprise', 15, 'Precios de la edición Enterprise'),
('precios', '/precios/comparar', 12, 'Comparador de precios'),
('precios', '/precios/educacion', 8, 'Precios para educación'),
('descarga', '/descargas/open-source', 5, 'Descarga de la versión gratuita'),
('descarga', '/descargas/prueba-profesional', 25, 'Descarga de prueba Professional'),
('uso_prueba', '/prueba/uso/admin', 20, 'Uso del panel de administración'),
('uso_prueba', '/prueba/uso/migracion', 18, 'Uso de la herramienta de migración'),
('uso_prueba', '/prueba/uso/correo', 12, 'Uso del correo en la prueba'),
('contacto', '/contacto/ventas', 30, 'Contacto con ventas'),
('contacto', '/contacto/soporte', 5, 'Contacto con soporte'),
('contacto', '/contacto/cotizacion', 28, 'Solicitud de cotización'),
('contacto', '/contacto/demo', 27, 'Solicitud de demostración'),
('contacto', '/contacto/partners', 10, 'Contacto de partners');

INSERT INTO version_producto (nombre, tipo, descripcion) VALUES
('Zimbra Collaboration Open Source', 'gratuita', 'Versión básica sin costo'),
('Zimbra Trial 60 días', 'prueba', 'Prueba de la versión comercial por 60 días'),
('Zimbra Collaboration Standard', 'comercial', 'Versión comercial estándar'),
('Zimbra Collaboration Professional', 'comercial', 'Versión comercial completa'),
('Zimbra Open Source 8.8.15', 'gratuita', 'Edición comunitaria rama 8.8'),
('Zimbra Open Source 9.0', 'gratuita', 'Edición comunitaria rama 9.0'),
('Zimbra Open Source 10.0', 'gratuita', 'Edición comunitaria rama 10.0'),
('Zimbra Open Source 10.1', 'gratuita', 'Edición comunitaria rama 10.1'),
('Zimbra Desktop', 'gratuita', 'Cliente de escritorio sin costo'),
('Zimbra Connector Community', 'gratuita', 'Conector comunitario para clientes de correo'),
('Zimbra Docs Community', 'gratuita', 'Edición comunitaria de documentos'),
('Zimbra Trial Standard 60 días', 'prueba', 'Prueba de la edición Standard'),
('Zimbra Trial Professional 60 días', 'prueba', 'Prueba de la edición Professional'),
('Zimbra Trial Mobile 60 días', 'prueba', 'Prueba del módulo móvil'),
('Zimbra Trial Backup 60 días', 'prueba', 'Prueba del módulo de respaldo'),
('Zimbra Trial Archiving 60 días', 'prueba', 'Prueba del módulo de archivado'),
('Zimbra Trial Chat 60 días', 'prueba', 'Prueba del módulo de mensajería'),
('Zimbra Trial Voice 60 días', 'prueba', 'Prueba del módulo de voz'),
('Zimbra Trial Connector Outlook 60 días', 'prueba', 'Prueba del conector para Outlook'),
('Zimbra Collaboration Enterprise', 'comercial', 'Edición para grandes organizaciones'),
('Zimbra Mobile', 'comercial', 'Sincronización móvil empresarial'),
('Zimbra Backup Plus', 'comercial', 'Respaldo y recuperación avanzados'),
('Zimbra Archiving and Discovery', 'comercial', 'Archivado y descubrimiento legal'),
('Zimbra Connector for Outlook', 'comercial', 'Conector comercial para Outlook'),
('Zimbra Voice', 'comercial', 'Telefonía integrada'),
('Zimbra Chat Pro', 'comercial', 'Mensajería instantánea corporativa'),
('Zimbra Standard Plus 100 usuarios', 'comercial', 'Paquete Standard de 100 buzones'),
('Zimbra Professional Plus 500 usuarios', 'comercial', 'Paquete Professional de 500 buzones'),
('Zimbra Education Edition', 'comercial', 'Licenciamiento para instituciones educativas'),
('Zimbra Government Edition', 'comercial', 'Licenciamiento para entidades públicas');

-- =====================================================================
-- 3. PROCEDIMIENTOS ALMACENADOS
-- =====================================================================
DELIMITER $$

-- Registra la descarga de la prueba: crea o reutiliza al prospecto, lo asigna
-- a un vendedor (el de menos prospectos activos), crea la descarga con
-- vencimiento a 60 días y registra el evento en el rastreo web.
-- ATOMICIDAD: los 4 pasos van en una sola transacción; si uno falla se
-- hace ROLLBACK y no queda un prospecto a medias.
CREATE PROCEDURE sp_registrar_descarga(
    IN p_nombre   VARCHAR(100),
    IN p_empresa  VARCHAR(120),
    IN p_cargo    VARCHAR(80),
    IN p_correo   VARCHAR(120),
    IN p_telefono VARCHAR(30),
    IN p_pais     VARCHAR(60),
    IN p_id_version INT,
    IN p_cookie   VARCHAR(64)
)
BEGIN
    DECLARE v_id_prospecto INT DEFAULT NULL;
    DECLARE v_id_vendedor  INT DEFAULT NULL;
    DECLARE v_dias         INT DEFAULT 60;
    DECLARE v_tipo         VARCHAR(20) DEFAULT NULL;
    DECLARE v_correo       VARCHAR(120);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET v_correo = LOWER(TRIM(p_correo));

    -- CONSISTENCIA: validaciones antes de tocar los datos
    IF v_correo NOT LIKE '_%@_%.__%' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El correo del prospecto no es válido';
    END IF;

    SELECT tipo INTO v_tipo FROM version_producto WHERE id_version = p_id_version;
    IF v_tipo IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La versión del producto no existe';
    END IF;
    IF v_tipo = 'comercial' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo se descargan versiones gratuitas o de prueba';
    END IF;

    SELECT COALESCE(CAST(valor AS UNSIGNED), 60) INTO v_dias
    FROM configuracion WHERE clave = 'dias_prueba';

    START TRANSACTION;

    SELECT id_prospecto INTO v_id_prospecto FROM prospecto WHERE correo = v_correo FOR UPDATE;

    IF v_id_prospecto IS NULL THEN
        SELECT v.id_vendedor INTO v_id_vendedor
        FROM vendedor v
        LEFT JOIN prospecto p ON p.id_vendedor = v.id_vendedor AND p.estado NOT IN ('ganado','perdido')
        WHERE v.activo = 1 AND v.rol = 'vendedor'
        GROUP BY v.id_vendedor
        ORDER BY COUNT(p.id_prospecto), v.id_vendedor
        LIMIT 1;

        INSERT INTO prospecto (nombre, empresa, cargo, correo, telefono, pais, origen, id_vendedor)
        VALUES (p_nombre, p_empresa, p_cargo, v_correo, p_telefono, p_pais, 'sitio_web', v_id_vendedor);
        SET v_id_prospecto = LAST_INSERT_ID();
    END IF;

    INSERT INTO descarga_prueba (id_prospecto, id_version, fecha_inicio, fecha_vencimiento)
    VALUES (v_id_prospecto, p_id_version, CURRENT_DATE, DATE_ADD(CURRENT_DATE, INTERVAL v_dias DAY));

    -- El evento dispara el trigger de puntaje y alerta
    INSERT INTO visita_web (id_prospecto, cookie_visitante, pagina, tipo_evento)
    VALUES (v_id_prospecto, p_cookie, '/descargas/prueba', 'descarga');

    INSERT INTO bitacora (tabla, id_registro, accion, detalle)
    VALUES ('descarga_prueba', v_id_prospecto, 'DESCARGA', CONCAT('Prueba de ', v_dias, ' días'));

    COMMIT;
END$$

-- Registra una venta. El trigger trg_venta_ai marca al prospecto como ganado y
-- convierte su prueba; aquí se valida y se deja todo en una transacción.
CREATE PROCEDURE sp_registrar_venta(
    IN p_id_prospecto INT,
    IN p_id_version   INT,
    IN p_modelo       VARCHAR(30),
    IN p_num_usuarios INT,
    IN p_monto        DECIMAL(12,2)
)
BEGIN
    DECLARE v_id_vendedor INT DEFAULT NULL;
    DECLARE v_estado      VARCHAR(20) DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    -- AISLAMIENTO: se bloquea la fila del prospecto mientras se cierra la venta
    SELECT id_vendedor, estado INTO v_id_vendedor, v_estado
    FROM prospecto WHERE id_prospecto = p_id_prospecto FOR UPDATE;

    IF v_estado IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El prospecto no existe';
    END IF;
    IF v_id_vendedor IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El prospecto no tiene vendedor asignado';
    END IF;

    INSERT INTO venta (id_prospecto, id_vendedor, id_version, modelo_licencia, num_usuarios, monto, fecha_renovacion)
    VALUES (p_id_prospecto, v_id_vendedor, p_id_version, p_modelo, p_num_usuarios, p_monto,
            DATE_ADD(CURRENT_DATE, INTERVAL 1 YEAR));

    INSERT INTO bitacora (tabla, id_registro, accion, detalle)
    VALUES ('venta', p_id_prospecto, 'VENTA', CONCAT(p_modelo, ' - usuarios: ', p_num_usuarios));

    COMMIT;
END$$

-- Marca como vencidas las pruebas que pasaron su fecha y deja constancia.
CREATE PROCEDURE sp_vencer_pruebas()
BEGIN
    DECLARE v_n INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    UPDATE descarga_prueba
    SET estado = 'vencida'
    WHERE estado = 'activa' AND fecha_vencimiento < CURRENT_DATE;
    SET v_n = ROW_COUNT();

    IF v_n > 0 THEN
        INSERT INTO bitacora (tabla, id_registro, accion, detalle)
        VALUES ('descarga_prueba', 0, 'VENCIMIENTO', CONCAT(v_n, ' pruebas marcadas como vencidas'));
    END IF;

    COMMIT;
END$$

-- REPORTE MENSUAL: tres resultados para un año/mes dado
--   1) resumen general  2) ventas por vendedor  3) ventas por modelo de licencia
-- Uso: CALL sp_reporte_mensual(2026, 11);
CREATE PROCEDURE sp_reporte_mensual(IN p_anio INT, IN p_mes INT)
BEGIN
    DECLARE v_ini DATE;
    DECLARE v_fin DATE;

    IF p_mes IS NULL OR p_mes NOT BETWEEN 1 AND 12 OR p_anio IS NULL OR p_anio NOT BETWEEN 2000 AND 2100 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Año o mes inválido (mes 1-12, año 2000-2100)';
    END IF;

    SET v_ini = STR_TO_DATE(CONCAT(p_anio, '-', p_mes, '-01'), '%Y-%m-%d');
    SET v_fin = DATE_ADD(v_ini, INTERVAL 1 MONTH);

    SELECT p_anio AS anio, p_mes AS mes,
           (SELECT COUNT(*) FROM prospecto       WHERE fecha_registro >= v_ini AND fecha_registro < v_fin) AS prospectos_nuevos,
           (SELECT COUNT(*) FROM descarga_prueba WHERE fecha_inicio   >= v_ini AND fecha_inicio   < v_fin) AS pruebas_iniciadas,
           (SELECT COUNT(*) FROM visita_web      WHERE fecha_hora     >= v_ini AND fecha_hora     < v_fin) AS eventos_web,
           (SELECT COUNT(*) FROM alerta          WHERE fecha_hora     >= v_ini AND fecha_hora     < v_fin) AS alertas,
           (SELECT COUNT(*) FROM venta           WHERE fecha_venta    >= v_ini AND fecha_venta    < v_fin) AS ventas,
           (SELECT COALESCE(SUM(monto), 0) FROM venta WHERE fecha_venta >= v_ini AND fecha_venta < v_fin) AS monto_total;

    SELECT vd.nombre AS vendedor, COUNT(s.id_venta) AS ventas, COALESCE(SUM(s.monto), 0) AS monto
    FROM vendedor vd
    LEFT JOIN venta s ON s.id_vendedor = vd.id_vendedor AND s.fecha_venta >= v_ini AND s.fecha_venta < v_fin
    WHERE vd.rol = 'vendedor'
    GROUP BY vd.id_vendedor, vd.nombre
    HAVING COUNT(s.id_venta) > 0
    ORDER BY monto DESC;

    SELECT modelo_licencia, COUNT(*) AS ventas, SUM(num_usuarios) AS usuarios, SUM(monto) AS monto
    FROM venta
    WHERE fecha_venta >= v_ini AND fecha_venta < v_fin
    GROUP BY modelo_licencia;
END$$

-- =====================================================================
-- 4. TRIGGERS
-- =====================================================================

-- Cada evento web suma puntos al prospecto, recalcula si está calificado y,
-- si ya era calificado y tiene vendedor, emite la alerta de actividad.
-- CORRECCIÓN: antes el umbral se comparaba con (puntaje + puntos) DESPUÉS de
-- haber sumado los puntos, por lo que se contaban dos veces y el prospecto
-- quedaba calificado antes de tiempo. Ahora son dos UPDATE separados.
CREATE TRIGGER trg_visita_puntaje_alerta
AFTER INSERT ON visita_web
FOR EACH ROW
BEGIN
    DECLARE v_pts         INT DEFAULT 0;
    DECLARE v_umbral      INT DEFAULT 50;
    DECLARE v_calif_prev  TINYINT DEFAULT 0;
    DECLARE v_vendedor    INT DEFAULT NULL;
    DECLARE v_nombre      VARCHAR(100) DEFAULT NULL;
    DECLARE v_rastreo     TINYINT DEFAULT 1;

    IF NEW.id_prospecto IS NOT NULL THEN
        SELECT acepta_rastreo, calificado, id_vendedor, nombre
          INTO v_rastreo, v_calif_prev, v_vendedor, v_nombre
        FROM prospecto WHERE id_prospecto = NEW.id_prospecto;

        IF v_rastreo = 1 THEN
            -- Regla más específica primero; si no hay ninguna activa, 0 puntos
            SET v_pts = COALESCE((SELECT puntos FROM regla_puntaje
                                  WHERE tipo_evento = NEW.tipo_evento AND activo = 1
                                    AND NEW.pagina LIKE pagina_patron
                                  ORDER BY (pagina_patron = '%'), CHAR_LENGTH(pagina_patron) DESC
                                  LIMIT 1), 0);

            SET v_umbral = COALESCE((SELECT CAST(valor AS UNSIGNED) FROM configuracion
                                     WHERE clave = 'umbral_calificacion'), 50);

            UPDATE prospecto SET puntaje = puntaje + v_pts
            WHERE id_prospecto = NEW.id_prospecto;

            UPDATE prospecto SET calificado = IF(puntaje >= v_umbral, 1, 0)
            WHERE id_prospecto = NEW.id_prospecto;

            IF v_calif_prev = 1 AND v_vendedor IS NOT NULL THEN
                INSERT INTO alerta (id_prospecto, id_vendedor, mensaje)
                VALUES (NEW.id_prospecto, v_vendedor,
                        CONCAT(v_nombre, ' (prospecto calificado) está visitando: ', NEW.pagina));
            END IF;
        END IF;
    END IF;
END$$

-- Normaliza los datos de entrada del prospecto (evita duplicados por mayúsculas/espacios).
CREATE TRIGGER trg_prospecto_bi_normaliza
BEFORE INSERT ON prospecto
FOR EACH ROW
BEGIN
    SET NEW.correo = LOWER(TRIM(NEW.correo));
    SET NEW.nombre = TRIM(NEW.nombre);
END$$

-- Un prospecto ganado o perdido ya está cerrado: no puede cambiar de estado.
CREATE TRIGGER trg_prospecto_bu_estado
BEFORE UPDATE ON prospecto
FOR EACH ROW
BEGIN
    IF OLD.estado IN ('ganado','perdido') AND NEW.estado <> OLD.estado THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Un prospecto ganado o perdido no puede cambiar de estado';
    END IF;
END$$

-- Bitácora de cambios de estado del prospecto.
CREATE TRIGGER trg_prospecto_estado
AFTER UPDATE ON prospecto
FOR EACH ROW
BEGIN
    IF OLD.estado <> NEW.estado THEN
        INSERT INTO bitacora (tabla, id_registro, accion, detalle)
        VALUES ('prospecto', NEW.id_prospecto, 'CAMBIO_ESTADO',
                CONCAT(OLD.estado, ' -> ', NEW.estado));
    END IF;
END$$

-- La prueba no puede vencer antes de empezar (mensaje claro además del CHECK).
CREATE TRIGGER trg_descarga_bi_valida
BEFORE INSERT ON descarga_prueba
FOR EACH ROW
BEGIN
    IF NEW.fecha_vencimiento < NEW.fecha_inicio THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'La fecha de vencimiento no puede ser anterior a la de inicio';
    END IF;
END$$

-- Validaciones de negocio antes de guardar una venta.
-- (Si la versión no existe se deja que actúe la FOREIGN KEY.)
CREATE TRIGGER trg_venta_bi_valida
BEFORE INSERT ON venta
FOR EACH ROW
BEGIN
    DECLARE v_tipo   VARCHAR(20) DEFAULT NULL;
    DECLARE v_estado VARCHAR(20) DEFAULT NULL;

    SELECT tipo INTO v_tipo FROM version_producto WHERE id_version = NEW.id_version;
    IF v_tipo IS NOT NULL AND v_tipo <> 'comercial' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo se pueden vender versiones comerciales';
    END IF;

    SELECT estado INTO v_estado FROM prospecto WHERE id_prospecto = NEW.id_prospecto;
    IF v_estado = 'perdido' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No se puede vender a un prospecto en estado perdido';
    END IF;
END$$

-- Al registrar una venta el prospecto pasa a "ganado" y su prueba activa a
-- "convertida" (actualización automática de estado, sin depender del programa).
CREATE TRIGGER trg_venta_ai
AFTER INSERT ON venta
FOR EACH ROW
BEGIN
    UPDATE prospecto SET estado = 'ganado'
    WHERE id_prospecto = NEW.id_prospecto AND estado <> 'ganado';

    UPDATE descarga_prueba SET estado = 'convertida'
    WHERE id_prospecto = NEW.id_prospecto AND estado = 'activa';
END$$

DELIMITER ;

-- Ejecución diaria automática (requiere: SET GLOBAL event_scheduler = ON;)
CREATE EVENT IF NOT EXISTS ev_vencer_pruebas
ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY)
DO CALL sp_vencer_pruebas();

-- =====================================================================
-- 5. VISTAS DE ANÁLISIS WEB Y REPORTES  [RF 6, 9]
-- =====================================================================

-- Tráfico diario del sitio
CREATE VIEW v_trafico_diario AS
SELECT DATE(fecha_hora) AS dia,
       COUNT(*) AS eventos,
       COUNT(DISTINCT cookie_visitante) AS visitantes_unicos,
       SUM(tipo_evento = 'descarga') AS descargas
FROM visita_web
GROUP BY DATE(fecha_hora);

-- Páginas más visitadas
CREATE VIEW v_paginas_top AS
SELECT pagina, COUNT(*) AS visitas, COUNT(DISTINCT cookie_visitante) AS visitantes
FROM visita_web
GROUP BY pagina
ORDER BY visitas DESC;

-- Prospectos calificados priorizados para el vendedor
CREATE VIEW v_prospectos_calificados AS
SELECT p.id_prospecto, p.nombre, p.empresa, p.correo, p.telefono,
       p.preferencia_contacto, p.horario_preferido, p.puntaje, p.estado,
       v.nombre AS vendedor,
       (SELECT MAX(w.fecha_hora) FROM visita_web w WHERE w.id_prospecto = p.id_prospecto) AS ultima_visita
FROM prospecto p
LEFT JOIN vendedor v ON v.id_vendedor = p.id_vendedor
WHERE p.calificado = 1 AND p.estado NOT IN ('ganado','perdido')
ORDER BY p.puntaje DESC;

-- Pruebas que vencen en los próximos 7 días
CREATE VIEW v_pruebas_por_vencer AS
SELECT d.id_descarga, p.nombre, p.correo, d.fecha_vencimiento,
       DATEDIFF(d.fecha_vencimiento, CURRENT_DATE) AS dias_restantes,
       v.nombre AS vendedor
FROM descarga_prueba d
JOIN prospecto p ON p.id_prospecto = d.id_prospecto
LEFT JOIN vendedor v ON v.id_vendedor = p.id_vendedor
WHERE d.estado = 'activa'
  AND d.fecha_vencimiento BETWEEN CURRENT_DATE AND DATE_ADD(CURRENT_DATE, INTERVAL 7 DAY);

-- Embudo de conversión: prueba -> calificado -> venta
CREATE VIEW v_conversion AS
SELECT
    (SELECT COUNT(DISTINCT id_prospecto) FROM descarga_prueba)          AS pruebas_descargadas,
    (SELECT COUNT(*) FROM prospecto WHERE calificado = 1)               AS prospectos_calificados,
    (SELECT COUNT(DISTINCT id_prospecto) FROM venta)                    AS ventas_cerradas,
    ROUND(100 * (SELECT COUNT(DISTINCT id_prospecto) FROM venta)
          / NULLIF((SELECT COUNT(DISTINCT id_prospecto) FROM descarga_prueba), 0), 2) AS tasa_conversion_pct;

-- Rendimiento de campañas de correo
CREATE VIEW v_rendimiento_campanas AS
SELECT c.id_campana, c.nombre,
       COUNT(e.id_envio)  AS enviados,
       SUM(e.abierto)     AS aperturas,
       SUM(e.clic)        AS clics,
       SUM(e.convirtio)   AS conversiones
FROM campana c
LEFT JOIN envio_correo e ON e.id_campana = c.id_campana
GROUP BY c.id_campana, c.nombre;

-- Ventas por vendedor
CREATE VIEW v_ventas_por_vendedor AS
SELECT v.nombre AS vendedor, COUNT(s.id_venta) AS ventas,
       COALESCE(SUM(s.monto), 0) AS monto_total
FROM vendedor v
LEFT JOIN venta s ON s.id_vendedor = v.id_vendedor
WHERE v.rol = 'vendedor'
GROUP BY v.id_vendedor, v.nombre;

-- =====================================================================
-- 6. DATOS DE PRUEBA (simulados: mínimo 30 registros por tabla)
-- =====================================================================

-- Fuerza de ventas: 30 personas (24 vendedores, 3 marketing, 2 gerentes, 1 administrador)
INSERT INTO vendedor (nombre, correo, rol) VALUES
('Laura Gómez', 'laura.gomez@zimbra.com', 'vendedor'),
('Carlos Ruiz', 'carlos.ruiz@zimbra.com', 'vendedor'),
('Marta Díaz', 'marta.diaz@zimbra.com', 'vendedor'),
('Greg Armanini', 'greg.armanini@zimbra.com', 'marketing'),
('Paula Fonseca', 'paula.fonseca@zimbra.com', 'vendedor'),
('Camilo Uribe', 'camilo.uribe@zimbra.com', 'vendedor'),
('Carolina Dávila', 'carolina.davila@zimbra.com', 'vendedor'),
('Tomás Echeverri', 'tomas.echeverri@zimbra.com', 'vendedor'),
('Paola Toro', 'paola.toro@zimbra.com', 'vendedor'),
('Luis Rueda', 'luis.rueda@zimbra.com', 'vendedor'),
('Hugo Arias', 'hugo.arias@zimbra.com', 'vendedor'),
('Andrés Espinosa', 'andres.espinosa@zimbra.com', 'vendedor'),
('Felipe Rojas', 'felipe.rojas@zimbra.com', 'vendedor'),
('Álvaro Yepes', 'alvaro.yepes@zimbra.com', 'vendedor'),
('Julián Palacios', 'julian.palacios@zimbra.com', 'vendedor'),
('Camila Yepes', 'camila.yepes@zimbra.com', 'vendedor'),
('Luis Ladino', 'luis.ladino@zimbra.com', 'vendedor'),
('Javier Quintero', 'javier.quintero@zimbra.com', 'vendedor'),
('Samuel Beltrán', 'samuel.beltran@zimbra.com', 'vendedor'),
('Cristian Gaitán', 'cristian.gaitan@zimbra.com', 'vendedor'),
('Teresa Villamil', 'teresa.villamil@zimbra.com', 'vendedor'),
('Emilio Prieto', 'emilio.prieto@zimbra.com', 'vendedor'),
('Tatiana Franco', 'tatiana.franco@zimbra.com', 'vendedor'),
('Mariana Ochoa', 'mariana.ochoa@zimbra.com', 'vendedor'),
('Marcela Moreno', 'marcela.moreno@zimbra.com', 'vendedor'),
('Diana Duarte', 'diana.duarte@zimbra.com', 'marketing'),
('Mario Pardo', 'mario.pardo@zimbra.com', 'marketing'),
('Elena Vargas', 'elena.vargas@zimbra.com', 'gerente'),
('Silvia Ibarra', 'silvia.ibarra@zimbra.com', 'gerente'),
('Rosa Osorio', 'rosa.osorio@zimbra.com', 'administrador');

-- Campañas de correo (30)
INSERT INTO campana (nombre, asunto, disparador) VALUES
('Bienvenida a la prueba', 'Aproveche sus 60 días de prueba', 'descarga_prueba'),
('Aviso de vencimiento', 'Su prueba vence pronto', 'prueba_por_vencer'),
('Oferta prospectos calificados', 'Pase a la versión comercial', 'prospecto_calificado'),
('Webinar de migración', 'Aprenda a migrar su correo en una hora', 'manual'),
('Casos de éxito Q1', 'Empresas que ya usan Zimbra', 'manual'),
('Casos de éxito Q2', 'Resultados reales de nuestros clientes', 'manual'),
('Guía de seguridad', 'Proteja su correo corporativo', 'manual'),
('Recordatorio día 30', 'Lleva la mitad de su prueba', 'descarga_prueba'),
('Recordatorio día 45', 'Quedan 15 días de prueba', 'descarga_prueba'),
('Última semana de prueba', 'Siete días para decidir', 'prueba_por_vencer'),
('Último día de prueba', 'Su prueba termina mañana', 'prueba_por_vencer'),
('Descuento por volumen', 'Ahorre al licenciar más usuarios', 'prospecto_calificado'),
('Demostración personalizada', 'Agende una demo con un experto', 'prospecto_calificado'),
('Comparativo de ediciones', 'Standard vs Professional', 'manual'),
('Newsletter mensual enero', 'Novedades de Zimbra', 'manual'),
('Newsletter mensual febrero', 'Novedades de Zimbra', 'manual'),
('Newsletter mensual marzo', 'Novedades de Zimbra', 'manual'),
('Lanzamiento versión 10', 'Conozca las novedades de la versión 10', 'manual'),
('Webinar de colaboración', 'Trabaje en equipo con Zimbra', 'manual'),
('Oferta educación', 'Licencias especiales para instituciones', 'manual'),
('Oferta gobierno', 'Licenciamiento para entidades públicas', 'manual'),
('Pagar por usar', 'Pague solo por los usuarios que necesita', 'prospecto_calificado'),
('Lugares ilimitados', 'Licencia sin límite de usuarios', 'prospecto_calificado'),
('Encuesta de satisfacción', 'Cuéntenos su experiencia', 'manual'),
('Referidos', 'Recomiende Zimbra y obtenga beneficios', 'manual'),
('Reactivación de prospectos', 'Retomemos su proyecto de correo', 'manual'),
('Migración desde otro proveedor', 'Cambie a Zimbra sin perder datos', 'manual'),
('Respaldo y recuperación', 'Evite la pérdida de información', 'manual'),
('Movilidad empresarial', 'Su correo en cualquier dispositivo', 'manual'),
('Cierre de año', 'Aproveche las condiciones de fin de año', 'manual');

-- Campos personalizados (30)
INSERT INTO campo_personalizado (nombre, tipo_dato) VALUES
('Número de buzones', 'numero'),
('Sector de la empresa', 'texto'),
('Sistema de correo actual', 'texto'),
('Nivel de urgencia', 'numero'),
('Presupuesto estimado', 'numero'),
('Fecha estimada de decisión', 'fecha'),
('Requiere migración', 'booleano'),
('Usa dispositivos móviles', 'booleano'),
('Número de sedes', 'numero'),
('Proveedor actual', 'texto'),
('Tamaño de la empresa', 'numero'),
('Cargo del decisor', 'texto'),
('Requiere archivado legal', 'booleano'),
('Requiere respaldo', 'booleano'),
('Idioma preferido', 'texto'),
('Canal de origen detallado', 'texto'),
('Fecha de última demo', 'fecha'),
('Participó en webinar', 'booleano'),
('Número de administradores', 'numero'),
('Dominio de correo', 'texto'),
('Versión actual instalada', 'texto'),
('Usa Active Directory', 'booleano'),
('Requiere integración CRM', 'booleano'),
('Fecha de renovación del contrato actual', 'fecha'),
('Observaciones comerciales', 'texto'),
('Número de licencias deseadas', 'numero'),
('Interés en pagar por usar', 'booleano'),
('Ciudad de la sede principal', 'texto'),
('Contacto técnico', 'texto'),
('Fecha de primer contacto', 'fecha');

-- Descargas (40): usan el procedimiento, que crea al prospecto, asigna vendedor,
-- registra la descarga y puntúa mediante el trigger. Los 3 primeros son los casos
-- que se usan en las pruebas de la Sesión 2.
CALL sp_registrar_descarga('Ana Torres', 'Distribuciones ABC', 'Gerente TI', 'ana@abc.com', '3001112233', 'Colombia', 2, 'ck-0001');
CALL sp_registrar_descarga('Pedro Salas', 'Banco Norte', 'CTO', 'pedro@bnorte.com', '3002223344', 'México', 2, 'ck-0002');
CALL sp_registrar_descarga('Lucía Mora', 'Universidad Sur', 'Director TI', 'lucia@usur.edu', '3003334455', 'Chile', 2, 'ck-0003');
CALL sp_registrar_descarga('Ximena Henao', 'Consultores Delta', 'Gerente TI', 'ximena.henao@consultoresdelta.com', '3188766344', 'Colombia', 2, 'ck-0004');
CALL sp_registrar_descarga('Gabriela Giraldo', 'Alcaldía de Zipaquirá', 'Analista de Seguridad', 'gabriela.giraldo@alcaldiadezipaquira.com', '3278753477', 'España', 12, 'ck-0005');
CALL sp_registrar_descarga('Andrea Acosta', 'Fintech Nova', 'Gerente de Operaciones', 'andrea.acosta@fintechnova.com', '3204571784', 'Chile', 13, 'ck-0006');
CALL sp_registrar_descarga('Gustavo Zuluaga', 'Instituto Técnico Central', 'Director TI', 'gustavo.zuluaga@institutotecnicocentral.com', '3271475136', 'España', 14, 'ck-0007');
CALL sp_registrar_descarga('Camila Moreno', 'Cafeteros Unidos', 'Director de Tecnología', 'camila.moreno@cafeterosunidos.com', '3079819331', 'Colombia', 15, 'ck-0008');
CALL sp_registrar_descarga('Nicolás Henao', 'Inmobiliaria Torres', 'Analista de Seguridad', 'nicolas.henao@inmobiliariatorres.com', '3252059972', 'Perú', 16, 'ck-0009');
CALL sp_registrar_descarga('Jorge Cano', 'Tecnoredes Bogotá', 'Coordinador de Sistemas', 'jorge.cano@tecnoredesbogota.com', '3098416229', 'Costa Rica', 17, 'ck-0010');
CALL sp_registrar_descarga('Leonardo Lozano', 'Retail Plaza', 'CIO', 'leonardo.lozano@retailplaza.com', '3083601610', 'Ecuador', 18, 'ck-0011');
CALL sp_registrar_descarga('Valentina Vargas', 'Farmacias Salud Total', 'Director de Tecnología', 'valentina.vargas@farmaciassaludtotal.com', '3275475177', 'Panamá', 19, 'ck-0012');
CALL sp_registrar_descarga('Adriana Pardo', 'Editorial Sierra', 'CTO', 'adriana.pardo@editorialsierra.com', '3283695793', 'Costa Rica', 2, 'ck-0013');
CALL sp_registrar_descarga('Ximena Castillo', 'Logística Pacífico', 'Director TI', 'ximena.castillo@logisticapacifico.com', '3020807370', 'Costa Rica', 12, 'ck-0014');
CALL sp_registrar_descarga('Juliana Toro', 'Banco Meridional', 'CTO', 'juliana.toro@bancomeridional.com', '3222264686', 'Uruguay', 13, 'ck-0015');
CALL sp_registrar_descarga('Elena Medina', 'Alimentos del Valle', 'CIO', 'elena.medina@alimentosdelvalle.com', '3124776472', 'Costa Rica', 14, 'ck-0016');
CALL sp_registrar_descarga('Sara Palacios', 'Transportes Condor', 'Gerente de Operaciones', 'sara.palacios@transportescondor.com', '3088413301', 'Ecuador', 15, 'ck-0017');
CALL sp_registrar_descarga('Leonardo Zapata', 'Energía Solaris', 'Jefe de Infraestructura', 'leonardo.zapata@energiasolaris.com', '3220525898', 'México', 16, 'ck-0018');
CALL sp_registrar_descarga('Patricia Acosta', 'Seguros Horizonte', 'Coordinador de Sistemas', 'patricia.acosta@seguroshorizonte.com', '3239494821', 'México', 17, 'ck-0019');
CALL sp_registrar_descarga('Andrea Cárdenas', 'Cementos del Norte', 'CTO', 'andrea.cardenas@cementosdelnorte.com', '3005218549', 'Argentina', 18, 'ck-0020');
CALL sp_registrar_descarga('Javier Cárdenas', 'Clínica Santa Fe', 'CTO', 'javier.cardenas@clinicasantafe.com', '3141064600', 'Perú', 19, 'ck-0021');
CALL sp_registrar_descarga('Diego Escobar', 'Cooperativa Agrícola Sur', 'Gerente TI', 'diego.escobar@cooperativaagricolasur.com', '3018955799', 'Uruguay', 2, 'ck-0022');
CALL sp_registrar_descarga('Javier Delgado', 'Seguridad Integral SA', 'Coordinador de Sistemas', 'javier.delgado@seguridadintegralsa.com', '3097615846', 'Ecuador', 12, 'ck-0023');
CALL sp_registrar_descarga('Isabella Prieto', 'Turismo Aventura Andes', 'CIO', 'isabella.prieto@turismoaventuraandes.com', '3260454146', 'Panamá', 13, 'ck-0024');
CALL sp_registrar_descarga('Diego Zapata', 'Textiles Andinos', 'Gerente TI', 'diego.zapata@textilesandinos.com', '3138012911', 'Chile', 14, 'ck-0025');
CALL sp_registrar_descarga('Teresa Delgado', 'Aerolínea Cóndor Sur', 'Administrador de Redes', 'teresa.delgado@aerolineacondorsur.com', '3240692566', 'Perú', 15, 'ck-0026');
CALL sp_registrar_descarga('Paola Henao', 'Petrolera Orinoco', 'Director TI', 'paola.henao@petroleraorinoco.com', '3022808864', 'Perú', 16, 'ck-0027');
CALL sp_registrar_descarga('Diego Vargas', 'Hoteles Costa Azul', 'Director TI', 'diego.vargas@hotelescostaazul.com', '3187645291', 'Costa Rica', 17, 'ck-0028');
CALL sp_registrar_descarga('Sebastián Giraldo', 'Agroexportadora Verde', 'Gerente TI', 'sebastian.giraldo@agroexportadoraverde.com', '3245850037', 'Perú', 18, 'ck-0029');
CALL sp_registrar_descarga('Tatiana Camacho', 'Laboratorios Vida', 'CIO', 'tatiana.camacho@laboratoriosvida.com', '3065384535', 'España', 19, 'ck-0030');
CALL sp_registrar_descarga('Mario Acosta', 'Hospital San Rafael', 'CIO', 'mario.acosta@hospitalsanrafael.com', '3194326270', 'Costa Rica', 2, 'ck-0031');
CALL sp_registrar_descarga('Leonardo Toro', 'Telecom Andes', 'Gerente TI', 'leonardo.toro@telecomandes.com', '3021458421', 'Costa Rica', 12, 'ck-0032');
CALL sp_registrar_descarga('Juliana Barrera', 'Medios Digitales Sur', 'Director TI', 'juliana.barrera@mediosdigitalessur.com', '3294906688', 'Costa Rica', 13, 'ck-0033');
CALL sp_registrar_descarga('Carolina Moreno', 'Minera Altiplano', 'Director TI', 'carolina.moreno@mineraaltiplano.com', '3065844093', 'Argentina', 14, 'ck-0034');
CALL sp_registrar_descarga('Diana Zapata', 'Software Factory LATAM', 'CIO', 'diana.zapata@softwarefactorylatam.com', '3152630976', 'Costa Rica', 15, 'ck-0035');
CALL sp_registrar_descarga('Adriana Ochoa', 'Colegio Bilingüe Andino', 'Analista de Seguridad', 'adriana.ochoa@colegiobilingueandino.com', '3202582201', 'Colombia', 16, 'ck-0036');
CALL sp_registrar_descarga('Silvia Ramírez', 'Universidad del Caribe', 'CTO', 'silvia.ramirez@universidaddelcaribe.com', '3143829932', 'Ecuador', 17, 'ck-0037');
CALL sp_registrar_descarga('Luis Jiménez', 'Industrias Metálicas Ruiz', 'Gerente de Operaciones', 'luis.jimenez@industriasmetalicasruiz.com', '3216494157', 'México', 18, 'ck-0038');
CALL sp_registrar_descarga('Verónica Zuluaga', 'Gobernación del Meta', 'Coordinador de Sistemas', 'veronica.zuluaga@gobernaciondelmeta.com', '3179511174', 'Perú', 19, 'ck-0039');
CALL sp_registrar_descarga('Adriana Fonseca', 'Constructora Cumbre', 'Jefe de Infraestructura', 'adriana.fonseca@constructoracumbre.com', '3188557652', 'España', 2, 'ck-0040');

-- Preferencias de contacto y consentimientos (antes de la actividad web)
UPDATE prospecto
SET origen = ELT(1 + id_prospecto MOD 3, 'sitio_web', 'referido', 'campana'),
    preferencia_contacto = IF(id_prospecto MOD 2 = 0, 'telefono', 'correo'),
    horario_preferido = ELT(1 + id_prospecto MOD 4, '08:00-12:00', '14:00-18:00', 'Cualquier hora', '10:00-13:00');
UPDATE prospecto SET acepta_rastreo = 0 WHERE id_prospecto IN (9, 17, 26, 34);   -- no aceptan rastreo
UPDATE prospecto SET acepta_correos = 0 WHERE id_prospecto IN (13, 27, 36);      -- baja de comunicaciones

-- Actividad web posterior (el prospecto 1 supera el umbral y luego genera alertas)
INSERT INTO visita_web (id_prospecto, cookie_visitante, pagina, tipo_evento) VALUES
(1, 'ck-0001', '/precios',          'precios'),
(1, 'ck-0001', '/producto/correo',  'pagina'),
(1, 'ck-0001', '/prueba/uso',       'uso_prueba'),
(2, 'ck-0002', '/precios',          'precios'),
(1, 'ck-0001', '/contacto',         'contacto'),   -- supera el umbral (50)
(1, 'ck-0001', '/precios',          'precios');    -- ya calificado: genera alerta

-- Actividad de los prospectos 4 a 28: 6 eventos cada uno, en orden. En los
-- prospectos con id múltiplo de 4 solo se simulan los 2 primeros (no califican).
-- (Se generan los ids con una CTE y no leyendo la tabla prospecto: MySQL no permite que un
--  trigger actualice una tabla que la misma sentencia está leyendo, error 1442.)
INSERT INTO visita_web (id_prospecto, cookie_visitante, pagina, tipo_evento)
WITH RECURSIVE ids (id) AS (SELECT 4 UNION ALL SELECT id + 1 FROM ids WHERE id < 28)
SELECT ids.id, CONCAT('ck-', LPAD(ids.id, 4, '0')), e.pagina, e.tipo_evento
FROM ids
JOIN (SELECT 1 AS orden, '/precios/enterprise'      AS pagina, 'precios'    AS tipo_evento
      UNION ALL SELECT 2, '/producto/correo',        'pagina'
      UNION ALL SELECT 3, '/prueba/uso/migracion',   'uso_prueba'
      UNION ALL SELECT 4, '/contacto/ventas',        'contacto'
      UNION ALL SELECT 5, '/precios',                'precios'
      UNION ALL SELECT 6, '/casos-de-exito',         'pagina') e
WHERE (ids.id MOD 4 <> 0 OR e.orden <= 2)
ORDER BY ids.id, e.orden;

-- Visitantes anónimos (30): no tienen prospecto
INSERT INTO visita_web (id_prospecto, cookie_visitante, pagina, tipo_evento) VALUES
(NULL, 'ck-9001', '/', 'pagina'),
(NULL, 'ck-9002', '/precios', 'precios'),
(NULL, 'ck-9003', '/producto/correo', 'pagina'),
(NULL, 'ck-9004', '/blog/novedades', 'pagina'),
(NULL, 'ck-9005', '/casos-de-exito', 'pagina'),
(NULL, 'ck-9006', '/descargas/open-source', 'descarga'),
(NULL, 'ck-9007', '/documentacion/instalacion', 'pagina'),
(NULL, 'ck-9008', '/webinars', 'pagina'),
(NULL, 'ck-9009', '/precios/comparar', 'precios'),
(NULL, 'ck-9010', '/empresa/acerca', 'pagina'),
(NULL, 'ck-9011', '/', 'pagina'),
(NULL, 'ck-9012', '/precios', 'precios'),
(NULL, 'ck-9013', '/producto/correo', 'pagina'),
(NULL, 'ck-9014', '/blog/novedades', 'pagina'),
(NULL, 'ck-9015', '/casos-de-exito', 'pagina'),
(NULL, 'ck-9016', '/descargas/open-source', 'descarga'),
(NULL, 'ck-9017', '/documentacion/instalacion', 'pagina'),
(NULL, 'ck-9018', '/webinars', 'pagina'),
(NULL, 'ck-9019', '/precios/comparar', 'precios'),
(NULL, 'ck-9020', '/empresa/acerca', 'pagina'),
(NULL, 'ck-9021', '/', 'pagina'),
(NULL, 'ck-9022', '/precios', 'precios'),
(NULL, 'ck-9023', '/producto/correo', 'pagina'),
(NULL, 'ck-9024', '/blog/novedades', 'pagina'),
(NULL, 'ck-9025', '/casos-de-exito', 'pagina'),
(NULL, 'ck-9026', '/descargas/open-source', 'descarga'),
(NULL, 'ck-9027', '/documentacion/instalacion', 'pagina'),
(NULL, 'ck-9028', '/webinars', 'pagina'),
(NULL, 'ck-9029', '/precios/comparar', 'precios'),
(NULL, 'ck-9030', '/empresa/acerca', 'pagina');

-- Correos de campaña (60 envíos; no se envía a quien dio de baja las comunicaciones)
INSERT INTO envio_correo (id_campana, id_prospecto, abierto, clic, convirtio) VALUES
(1, 1, 1, 1, 1),
(1, 2, 1, 0, 0),
(1, 3, 0, 0, 0),
(3, 1, 1, 1, 0),
(11, 39, 1, 0, 0),
(11, 17, 1, 0, 0),
(1, 31, 0, 0, 0),
(9, 30, 1, 1, 0),
(13, 20, 1, 1, 0),
(3, 33, 0, 0, 0),
(25, 20, 0, 0, 0),
(20, 6, 0, 0, 0),
(17, 39, 1, 1, 0),
(6, 5, 0, 0, 0),
(28, 12, 0, 0, 0),
(28, 34, 1, 1, 1),
(20, 14, 1, 1, 0),
(5, 33, 1, 0, 0),
(25, 32, 1, 0, 0),
(28, 21, 1, 0, 0),
(18, 40, 0, 0, 0),
(7, 10, 1, 0, 0),
(5, 10, 1, 0, 0),
(22, 37, 1, 0, 0),
(2, 18, 0, 0, 0),
(27, 12, 1, 0, 0),
(23, 23, 1, 1, 0),
(25, 12, 0, 0, 0),
(14, 40, 1, 0, 0),
(1, 20, 1, 1, 0),
(5, 21, 1, 0, 0),
(16, 1, 1, 1, 0),
(23, 17, 1, 1, 0),
(28, 6, 1, 0, 0),
(27, 11, 1, 0, 0),
(16, 14, 1, 0, 0),
(28, 28, 0, 0, 0),
(15, 24, 0, 0, 0),
(10, 29, 0, 0, 0),
(18, 39, 1, 0, 0),
(4, 6, 1, 0, 0),
(23, 11, 1, 1, 0),
(29, 28, 1, 0, 0),
(21, 18, 1, 1, 1),
(17, 30, 0, 0, 0),
(27, 23, 1, 1, 0),
(18, 15, 0, 0, 0),
(15, 25, 1, 0, 0),
(22, 6, 1, 1, 0),
(17, 34, 0, 0, 0),
(27, 18, 1, 1, 1),
(17, 29, 1, 1, 0),
(19, 30, 1, 0, 0),
(5, 2, 1, 1, 0),
(9, 2, 0, 0, 0),
(24, 5, 0, 0, 0),
(17, 8, 0, 0, 0),
(28, 22, 0, 0, 0),
(10, 31, 1, 0, 0),
(15, 16, 1, 0, 0);

-- Seguimiento de ventas
INSERT INTO contacto_seguimiento (id_prospecto, id_vendedor, medio, resultado, notas, proximo_seguimiento)
SELECT 1, id_vendedor, 'llamada', 'Interesado', 'Pidió cotización para 30 usuarios', DATE_ADD(CURRENT_DATE, INTERVAL 3 DAY)
FROM prospecto WHERE id_prospecto = 1;

-- Un contacto de seguimiento para cada prospecto del 4 al 40 (37 registros)
INSERT INTO contacto_seguimiento (id_prospecto, id_vendedor, medio, fecha_hora, resultado, notas, proximo_seguimiento)
SELECT p.id_prospecto, p.id_vendedor,
       IF(p.id_prospecto MOD 2 = 0, 'llamada', 'correo'),
       DATE_SUB(NOW(), INTERVAL p.id_prospecto DAY),
       ELT(1 + p.id_prospecto MOD 5, 'Interesado', 'Sin respuesta', 'Solicita cotización', 'Pide demostración', 'Volver a llamar'),
       CONCAT('Seguimiento a ', p.nombre, ' de ', p.empresa),
       DATE_ADD(CURRENT_DATE, INTERVAL 1 + p.id_prospecto MOD 10 DAY)
FROM prospecto p
WHERE p.id_prospecto BETWEEN 4 AND 40 AND p.id_vendedor IS NOT NULL;

-- Estados del embudo (los prospectos 4 a 22 pasan a "ganado" solos al registrar su venta)
UPDATE prospecto SET estado = 'contactado'     WHERE id_prospecto = 1;
UPDATE prospecto SET estado = 'en_negociacion' WHERE id_prospecto = 1;
UPDATE prospecto SET estado = 'contactado'     WHERE id_prospecto BETWEEN 23 AND 28;
UPDATE prospecto SET estado = 'en_negociacion' WHERE id_prospecto BETWEEN 29 AND 33;
UPDATE prospecto SET estado = 'perdido'        WHERE id_prospecto BETWEEN 34 AND 37;

-- Sincronización con Salesforce (40 registros)
INSERT INTO sincronizacion_crm (id_prospecto, id_externo_crm, direccion, estado, detalle)
VALUES (1, 'SF-00A1', 'hacia_crm', 'exitosa', 'Prospecto y actividad web enviados');

INSERT INTO sincronizacion_crm (id_prospecto, id_externo_crm, direccion, estado, detalle)
SELECT p.id_prospecto, CONCAT('SF-', LPAD(p.id_prospecto, 5, '0')),
       IF(p.id_prospecto MOD 3 = 0, 'desde_crm', 'hacia_crm'),
       ELT(1 + p.id_prospecto MOD 5, 'exitosa', 'exitosa', 'pendiente', 'exitosa', 'error'),
       ELT(1 + p.id_prospecto MOD 5, 'Prospecto sincronizado', 'Actividad web enviada', 'En cola de envío', 'Datos de contacto actualizados', 'Tiempo de espera agotado')
FROM prospecto p
WHERE p.id_prospecto BETWEEN 2 AND 40;

-- Valores de campos personalizados (80 registros: buzones y sector para los 40 prospectos)
INSERT INTO valor_campo_prospecto (id_prospecto, id_campo, valor)
SELECT p.id_prospecto, 1, CAST(5 + (p.id_prospecto * 7) MOD 400 AS CHAR) FROM prospecto p
UNION ALL
SELECT p.id_prospecto, 2, ELT(1 + p.id_prospecto MOD 6, 'Banca', 'Educación', 'Comercio', 'Salud', 'Gobierno', 'Manufactura') FROM prospecto p;

-- Fechas repartidas en los últimos meses (para que los reportes mensuales tengan datos)
UPDATE prospecto SET fecha_registro = DATE_SUB(NOW(), INTERVAL (id_prospecto MOD 6) MONTH);
UPDATE visita_web SET fecha_hora = DATE_SUB(fecha_hora, INTERVAL (id_visita MOD 150) DAY);
UPDATE descarga_prueba
SET fecha_inicio      = DATE_SUB(CURRENT_DATE, INTERVAL ELT(1 + id_descarga MOD 5, 5, 20, 55, 90, 62) DAY),
    fecha_vencimiento = DATE_ADD(DATE_SUB(CURRENT_DATE, INTERVAL ELT(1 + id_descarga MOD 5, 5, 20, 55, 90, 62) DAY), INTERVAL 60 DAY);
CALL sp_vencer_pruebas();   -- las pruebas de 90 y 62 días atrás quedan "vencida"

-- Ventas cerradas (30): usan el procedimiento (transacción); el trigger marca "ganado"
CALL sp_registrar_venta(1, 3, 'pagar_por_usar', 30, 14500.00);
CALL sp_registrar_venta(4, 24, 'pagar_por_usar', 20, 3000.00);
CALL sp_registrar_venta(5, 20, 'pagar_por_usar', 150, 18000.00);
CALL sp_registrar_venta(6, 22, 'lugares_ilimitados', 75, 13500.00);
CALL sp_registrar_venta(7, 22, 'lugares_ilimitados', 30, 4500.00);
CALL sp_registrar_venta(8, 26, 'pagar_por_usar', 75, 9000.00);
CALL sp_registrar_venta(9, 23, 'pagar_por_usar', 200, 24000.00);
CALL sp_registrar_venta(10, 22, 'lugares_ilimitados', 15, 2250.00);
CALL sp_registrar_venta(11, 24, 'pagar_por_usar', 150, 37500.00);
CALL sp_registrar_venta(12, 29, 'lugares_ilimitados', 50, 10500.00);
CALL sp_registrar_venta(13, 4, 'pagar_por_usar', 30, 4500.00);
CALL sp_registrar_venta(14, 28, 'pagar_por_usar', 200, 50000.00);
CALL sp_registrar_venta(15, 23, 'lugares_ilimitados', 200, 36000.00);
CALL sp_registrar_venta(16, 24, 'pagar_por_usar', 200, 19000.00);
CALL sp_registrar_venta(17, 22, 'lugares_ilimitados', 300, 28500.00);
CALL sp_registrar_venta(18, 23, 'pagar_por_usar', 100, 12000.00);
CALL sp_registrar_venta(19, 25, 'pagar_por_usar', 150, 27000.00);
CALL sp_registrar_venta(20, 30, 'lugares_ilimitados', 30, 2850.00);
CALL sp_registrar_venta(21, 22, 'lugares_ilimitados', 20, 5000.00);
CALL sp_registrar_venta(22, 30, 'lugares_ilimitados', 30, 3600.00);
CALL sp_registrar_venta(1, 28, 'pagar_por_usar', 75, 15750.00);
CALL sp_registrar_venta(4, 29, 'lugares_ilimitados', 30, 6300.00);
CALL sp_registrar_venta(5, 20, 'lugares_ilimitados', 20, 1900.00);
CALL sp_registrar_venta(6, 21, 'lugares_ilimitados', 30, 5400.00);
CALL sp_registrar_venta(7, 22, 'lugares_ilimitados', 150, 37500.00);
CALL sp_registrar_venta(8, 26, 'pagar_por_usar', 10, 2500.00);
CALL sp_registrar_venta(9, 3, 'lugares_ilimitados', 200, 19000.00);
CALL sp_registrar_venta(10, 20, 'pagar_por_usar', 25, 2375.00);
CALL sp_registrar_venta(11, 28, 'lugares_ilimitados', 100, 18000.00);
CALL sp_registrar_venta(12, 23, 'pagar_por_usar', 200, 30000.00);

UPDATE venta
SET fecha_venta      = DATE_SUB(CURRENT_DATE, INTERVAL (id_venta MOD 6) MONTH),
    fecha_renovacion = DATE_ADD(DATE_SUB(CURRENT_DATE, INTERVAL (id_venta MOD 6) MONTH), INTERVAL 1 YEAR);

-- Alertas: algunas ya leídas y repartidas en el tiempo
UPDATE alerta
SET fecha_hora = DATE_SUB(fecha_hora, INTERVAL (id_alerta MOD 20) DAY),
    leida      = IF(id_alerta MOD 3 = 0, 1, 0);

-- =====================================================================
-- 7. SESIÓN 2 - TRANSACCIONES ACID Y SAVEPOINTS
-- =====================================================================
-- =====================================================================
-- PARTE 1. TRANSACCIONES MANUALES (BEGIN / COMMIT / ROLLBACK)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1.1  COMMIT: registrar el primer contacto con un prospecto.
--      Los dos cambios (estado + contacto) se guardan juntos.
-- ---------------------------------------------------------------------
START TRANSACTION;

UPDATE prospecto
SET estado = 'contactado'
WHERE correo = 'lucia@usur.edu';

INSERT INTO contacto_seguimiento (id_prospecto, id_vendedor, medio, resultado, notas, proximo_seguimiento)
SELECT id_prospecto, id_vendedor, 'correo', 'Sin respuesta aún',
       'Primer correo de presentación', DATE_ADD(CURRENT_DATE, INTERVAL 2 DAY)
FROM prospecto
WHERE correo = 'lucia@usur.edu';

COMMIT;

SELECT p.nombre, p.estado, c.medio, c.resultado
FROM prospecto p
JOIN contacto_seguimiento c ON c.id_prospecto = p.id_prospecto
WHERE p.correo = 'lucia@usur.edu';

-- ---------------------------------------------------------------------
-- 1.2  ROLLBACK: se inserta un prospecto de prueba y se descarta.
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS prospectos_antes FROM prospecto;

START TRANSACTION;

INSERT INTO prospecto (nombre, empresa, correo, pais)
VALUES ('Prospecto Temporal', 'Empresa Temporal', 'temporal@prueba.com', 'Colombia');

SELECT COUNT(*) AS prospectos_dentro_de_la_transaccion FROM prospecto;   -- uno más

ROLLBACK;

SELECT COUNT(*) AS prospectos_despues_del_rollback FROM prospecto;       -- igual que antes

-- =====================================================================
-- PARTE 2. SAVEPOINTS (puntos de recuperación parciales)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 2.1  Tres campañas en una transacción. Se vuelve a un savepoint
--      intermedio: la campaña C se deshace, A y B se conservan.
-- ---------------------------------------------------------------------
START TRANSACTION;

INSERT INTO campana (nombre, asunto, disparador)
VALUES ('Campaña A - Webinar', 'Webinar de Zimbra', 'manual');
SAVEPOINT sp_campana_a;

INSERT INTO campana (nombre, asunto, disparador)
VALUES ('Campaña B - Casos de éxito', 'Casos de éxito', 'manual');
SAVEPOINT sp_campana_b;

INSERT INTO campana (nombre, asunto, disparador)
VALUES ('Campaña C - Error de digitación', 'Asunto incorrecto', 'manual');

SELECT id_campana, nombre FROM campana WHERE nombre LIKE 'Campaña _ - %';    -- A, B y C

ROLLBACK TO SAVEPOINT sp_campana_b;                                       -- deshace solo C

SELECT id_campana, nombre FROM campana WHERE nombre LIKE 'Campaña _ - %';    -- A y B

COMMIT;                                                                   -- A y B quedan guardadas

-- ---------------------------------------------------------------------
-- 2.2  SAVEPOINT + RELEASE SAVEPOINT: cambio de una regla de puntaje.
--      Se ajustan dos reglas; la segunda se descarta y la primera se conserva.
--      RELEASE SAVEPOINT elimina un punto de recuperación que ya no se necesita.
-- ---------------------------------------------------------------------
START TRANSACTION;

UPDATE regla_puntaje SET puntos = 12 WHERE tipo_evento = 'precios' AND pagina_patron = '%';
SAVEPOINT sp_regla_precios;

UPDATE regla_puntaje SET puntos = 99 WHERE tipo_evento = 'contacto' AND pagina_patron = '%';  -- error de digitación
SAVEPOINT sp_regla_contacto;

ROLLBACK TO SAVEPOINT sp_regla_precios;      -- deshace solo la regla de contacto
RELEASE SAVEPOINT sp_regla_precios;          -- el savepoint ya no se necesita: se libera

SELECT tipo_evento, puntos FROM regla_puntaje WHERE pagina_patron = '%' ORDER BY id_regla;
COMMIT;                                      -- queda precios = 12, contacto = 25

-- =====================================================================
-- PARTE 3. SIMULACIÓN DE ERRORES Y RECUPERACIÓN (procedimientos)
-- =====================================================================
DELIMITER $$

DROP PROCEDURE IF EXISTS sp_cerrar_venta_savepoints$$

-- Cierre de venta en tres pasos con dos savepoints:
--   paso 1: pasar el prospecto a "en_negociacion"   -> SAVEPOINT sp_estado
--   paso 2: registrar el contacto de cierre         -> SAVEPOINT sp_contacto
--   paso 3: registrar la venta (el trigger trg_venta_ai marca "ganado") y la bitácora
-- Qué se conserva si algo falla:
--   falla el paso 1 -> ROLLBACK total (no se guardó nada)
--   falla el paso 2 -> ROLLBACK TO sp_estado   (se conserva solo el estado)
--   falla el paso 3 -> ROLLBACK TO sp_contacto (se conserva estado + contacto,
--                      pero no se registra una venta inválida)
-- Si el prospecto no existe o ya está cerrado se deshace todo.
--
-- CORRECCIONES respecto a la versión anterior:
--  * p_resultado era VARCHAR(250) y el mensaje de error de una FOREIGN KEY es
--    más largo: la asignación fallaba dentro del CONTINUE HANDLER y el resultado
--    quedaba en NULL. Ahora es VARCHAR(500) y el mensaje se recorta con LEFT().
--  * Se revisa la bandera de error después de CADA paso (antes solo después
--    del paso 3 y del cambio de estado).
CREATE PROCEDURE sp_cerrar_venta_savepoints(
    IN  p_correo       VARCHAR(120),
    IN  p_id_version   INT,
    IN  p_modelo       VARCHAR(30),
    IN  p_num_usuarios INT,
    IN  p_monto        DECIMAL(12,2),
    OUT p_resultado    VARCHAR(500)
)
proc: BEGIN
    DECLARE v_id_prospecto INT DEFAULT NULL;
    DECLARE v_id_vendedor  INT DEFAULT NULL;
    DECLARE v_estado       VARCHAR(20) DEFAULT NULL;
    DECLARE v_error        TINYINT DEFAULT 0;
    DECLARE v_msg          TEXT DEFAULT NULL;

    -- Cualquier error SQL marca la bandera y la ejecución continúa para
    -- decidir a qué savepoint volver.
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        SET v_error = 1;
    END;

    START TRANSACTION;

    -- Aislamiento: se bloquea la fila del prospecto durante la operación
    SELECT id_prospecto, id_vendedor, estado
      INTO v_id_prospecto, v_id_vendedor, v_estado
    FROM prospecto
    WHERE correo = LOWER(TRIM(p_correo))
    FOR UPDATE;

    IF v_error = 1 THEN
        ROLLBACK;
        SET p_resultado = CONCAT('ROLLBACK TOTAL: error al leer el prospecto: ', LEFT(IFNULL(v_msg, 'error'), 250));
        LEAVE proc;
    END IF;

    IF v_id_prospecto IS NULL OR v_id_vendedor IS NULL THEN
        ROLLBACK;
        SET p_resultado = 'ROLLBACK TOTAL: el prospecto no existe o no tiene vendedor asignado';
        LEAVE proc;
    END IF;

    IF v_estado IN ('ganado', 'perdido') THEN
        ROLLBACK;
        SET p_resultado = CONCAT('ROLLBACK TOTAL: el prospecto ya está en estado ', v_estado);
        LEAVE proc;
    END IF;

    -- Paso 1
    UPDATE prospecto SET estado = 'en_negociacion' WHERE id_prospecto = v_id_prospecto;
    IF v_error = 1 THEN
        ROLLBACK;
        SET p_resultado = CONCAT('ROLLBACK TOTAL en el paso 1: ', LEFT(IFNULL(v_msg, 'error'), 250));
        LEAVE proc;
    END IF;
    SAVEPOINT sp_estado;

    -- Paso 2
    INSERT INTO contacto_seguimiento (id_prospecto, id_vendedor, medio, resultado, notas)
    VALUES (v_id_prospecto, v_id_vendedor, 'llamada', 'Cierre en proceso',
            'Se acordaron condiciones de licencia');
    IF v_error = 1 THEN
        ROLLBACK TO SAVEPOINT sp_estado;
        COMMIT;
        SET p_resultado = CONCAT('ROLLBACK PARCIAL a sp_estado en el paso 2: ', LEFT(IFNULL(v_msg, 'error'), 250),
                                 '. Se conservó el cambio de estado.');
        LEAVE proc;
    END IF;
    SAVEPOINT sp_contacto;

    -- Paso 3 (puede fallar: CHECK, FOREIGN KEY, triggers de validación)
    INSERT INTO venta (id_prospecto, id_vendedor, id_version, modelo_licencia, num_usuarios, monto, fecha_renovacion)
    VALUES (v_id_prospecto, v_id_vendedor, p_id_version, p_modelo, p_num_usuarios, p_monto,
            DATE_ADD(CURRENT_DATE, INTERVAL 1 YEAR));

    IF v_error = 0 THEN
        INSERT INTO bitacora (tabla, id_registro, accion, detalle)
        VALUES ('venta', v_id_prospecto, 'VENTA_SAVEPOINTS',
                CONCAT(p_modelo, ' - usuarios: ', p_num_usuarios));
    END IF;

    IF v_error = 1 THEN
        ROLLBACK TO SAVEPOINT sp_contacto;
        COMMIT;
        SET p_resultado = CONCAT('ROLLBACK PARCIAL a sp_contacto. Venta rechazada: ', LEFT(IFNULL(v_msg, 'error'), 250),
                                 '. Se conservaron el estado y el contacto.');
        LEAVE proc;
    END IF;

    COMMIT;
    SET p_resultado = 'COMMIT: venta registrada correctamente';
END$$

DROP PROCEDURE IF EXISTS sp_reasignar_cartera$$

-- Reasigna todos los prospectos activos de un vendedor a otro.
-- Todo o nada: si el destino no es válido se lanza un error propio (SIGNAL)
-- y se hace ROLLBACK, así ningún prospecto queda sin vendedor.
-- Se bloquean origen y destino en una sola consulta (FOR UPDATE) para que dos
-- reasignaciones simultáneas no se mezclen (aislamiento).
CREATE PROCEDURE sp_reasignar_cartera(
    IN  p_origen    INT,
    IN  p_destino   INT,
    OUT p_resultado VARCHAR(500)
)
BEGIN
    DECLARE v_activo  TINYINT DEFAULT NULL;
    DECLARE v_rol     VARCHAR(20) DEFAULT NULL;
    DECLARE v_existen INT DEFAULT 0;
    DECLARE v_movidos INT DEFAULT 0;
    DECLARE v_msg     TEXT DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        ROLLBACK;
        SET p_resultado = CONCAT('ROLLBACK: ', LEFT(IFNULL(v_msg, 'error'), 250));
    END;

    START TRANSACTION;

    IF p_origen = p_destino THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Origen y destino son el mismo vendedor';
    END IF;

    SELECT COUNT(*) INTO v_existen
    FROM vendedor WHERE id_vendedor IN (p_origen, p_destino) FOR UPDATE;

    IF v_existen < 2 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El vendedor origen o el destino no existe';
    END IF;

    SELECT activo, rol INTO v_activo, v_rol FROM vendedor WHERE id_vendedor = p_destino;

    IF v_activo = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El vendedor destino está inactivo';
    END IF;
    IF v_rol <> 'vendedor' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El destino no tiene rol de vendedor';
    END IF;

    UPDATE prospecto
    SET id_vendedor = p_destino
    WHERE id_vendedor = p_origen AND estado NOT IN ('ganado','perdido');
    SET v_movidos = ROW_COUNT();

    INSERT INTO bitacora (tabla, id_registro, accion, detalle)
    VALUES ('prospecto', p_origen, 'REASIGNACION',
            CONCAT(v_movidos, ' prospectos de vendedor ', p_origen, ' a vendedor ', p_destino));

    COMMIT;
    SET p_resultado = CONCAT('COMMIT: ', v_movidos, ' prospectos reasignados');
END$$

DROP PROCEDURE IF EXISTS sp_demo_triggers$$

-- Prueba los triggers de validación SIN detener el script: cada sentencia
-- inválida se ejecuta en su propio bloque con un handler que captura el error.
-- Todo ocurre dentro de una transacción que termina en ROLLBACK, así que no
-- queda ningún cambio en la base (atomicidad).
CREATE PROCEDURE sp_demo_triggers()
BEGIN
    DECLARE v_m1 VARCHAR(250) DEFAULT 'SIN ERROR (inesperado)';
    DECLARE v_m2 VARCHAR(250) DEFAULT 'SIN ERROR (inesperado)';
    DECLARE v_m3 VARCHAR(250) DEFAULT 'SIN ERROR (inesperado)';
    DECLARE v_m4 VARCHAR(250) DEFAULT 'SIN ERROR (inesperado)';
    DECLARE v_correo VARCHAR(120) DEFAULT NULL;

    START TRANSACTION;

    -- 1) Un prospecto ganado no puede volver a "nuevo" (trg_prospecto_bu_estado)
    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
            BEGIN GET DIAGNOSTICS CONDITION 1 v_m1 = MESSAGE_TEXT; END;
        UPDATE prospecto SET estado = 'nuevo' WHERE id_prospecto = 1;
    END;

    -- 2) Fecha de vencimiento anterior al inicio (trg_descarga_bi_valida)
    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
            BEGIN GET DIAGNOSTICS CONDITION 1 v_m2 = MESSAGE_TEXT; END;
        INSERT INTO descarga_prueba (id_prospecto, id_version, fecha_inicio, fecha_vencimiento)
        VALUES (38, 2, CURRENT_DATE, DATE_SUB(CURRENT_DATE, INTERVAL 5 DAY));
    END;

    -- 3) Vender una versión gratuita (trg_venta_bi_valida)
    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
            BEGIN GET DIAGNOSTICS CONDITION 1 v_m3 = MESSAGE_TEXT; END;
        INSERT INTO venta (id_prospecto, id_vendedor, id_version, modelo_licencia, num_usuarios, monto)
        VALUES (38, 1, 1, 'pagar_por_usar', 10, 1000.00);
    END;

    -- 4) Vender a un prospecto perdido (trg_venta_bi_valida)
    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
            BEGIN GET DIAGNOSTICS CONDITION 1 v_m4 = MESSAGE_TEXT; END;
        INSERT INTO venta (id_prospecto, id_vendedor, id_version, modelo_licencia, num_usuarios, monto)
        VALUES (34, 1, 3, 'pagar_por_usar', 10, 1000.00);
    END;

    -- 5) Normalización del correo (trg_prospecto_bi_normaliza)
    INSERT INTO prospecto (nombre, correo) VALUES ('  Prueba Trigger  ', '  PRUEBA.Trigger@Ejemplo.COM ');
    SELECT correo INTO v_correo FROM prospecto WHERE id_prospecto = LAST_INSERT_ID();

    ROLLBACK;   -- no queda nada de esta demostración

    SELECT '1. ganado -> nuevo'          AS prueba, v_m1 AS resultado
    UNION ALL SELECT '2. vencimiento < inicio',     v_m2
    UNION ALL SELECT '3. vender versión gratuita',  v_m3
    UNION ALL SELECT '4. vender a prospecto perdido', v_m4
    UNION ALL SELECT '5. correo normalizado',       v_correo;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- 3.1  Venta exitosa -> COMMIT
-- ---------------------------------------------------------------------
CALL sp_cerrar_venta_savepoints('pedro@bnorte.com', 4, 'lugares_ilimitados', 30, 22000.00, @r1);
SELECT @r1 AS resultado_venta_exitosa;

-- ---------------------------------------------------------------------
-- 3.2  Error forzado: 0 usuarios viola el CHECK (num_usuarios > 0).
--      Se vuelve al savepoint sp_contacto.
-- ---------------------------------------------------------------------
CALL sp_cerrar_venta_savepoints('lucia@usur.edu', 3, 'pagar_por_usar', 0, 5000.00, @r2);
SELECT @r2 AS resultado_error_check;

-- Lucía debe quedar "en_negociacion" y sin venta registrada
SELECT p.nombre, p.estado,
       (SELECT COUNT(*) FROM venta v WHERE v.id_prospecto = p.id_prospecto) AS ventas
FROM prospecto p WHERE p.correo = 'lucia@usur.edu';

-- ---------------------------------------------------------------------
-- 3.3  Error forzado: versión de producto inexistente (viola la FOREIGN KEY)
-- ---------------------------------------------------------------------
CALL sp_cerrar_venta_savepoints('lucia@usur.edu', 999, 'pagar_por_usar', 10, 5000.00, @r3);
SELECT @r3 AS resultado_error_fk;

-- ---------------------------------------------------------------------
-- 3.4  Error forzado: versión gratuita (lo rechaza el trigger trg_venta_bi_valida)
-- ---------------------------------------------------------------------
CALL sp_cerrar_venta_savepoints('lucia@usur.edu', 1, 'pagar_por_usar', 10, 5000.00, @r4);
SELECT @r4 AS resultado_error_trigger;

-- ---------------------------------------------------------------------
-- 3.5  Error forzado: prospecto inexistente -> ROLLBACK total
-- ---------------------------------------------------------------------
CALL sp_cerrar_venta_savepoints('noexiste@correo.com', 3, 'pagar_por_usar', 10, 5000.00, @r5);
SELECT @r5 AS resultado_prospecto_inexistente;

-- ---------------------------------------------------------------------
-- 3.6  Prospecto que ya es cliente: no se puede cerrar otra vez -> ROLLBACK total
-- ---------------------------------------------------------------------
CALL sp_cerrar_venta_savepoints('ana@abc.com', 3, 'pagar_por_usar', 10, 5000.00, @r6);
SELECT @r6 AS resultado_prospecto_ya_ganado;

-- ---------------------------------------------------------------------
-- 3.7  Reasignación de cartera: caso válido y casos que fallan
-- ---------------------------------------------------------------------
CALL sp_reasignar_cartera(1, 2, @r7);
SELECT @r7 AS reasignacion_valida;

CALL sp_reasignar_cartera(2, 4, @r8);      -- el destino es de marketing
SELECT @r8 AS reasignacion_rol_invalido;

CALL sp_reasignar_cartera(2, 99, @r9);     -- el destino no existe
SELECT @r9 AS reasignacion_destino_inexistente;

-- ---------------------------------------------------------------------
-- 3.8  Triggers de validación (cada intento falla y se captura el mensaje)
-- ---------------------------------------------------------------------
CALL sp_demo_triggers();

-- =====================================================================
-- PARTE 4. VERIFICACIÓN DE RESULTADOS Y RECUPERACIÓN
-- =====================================================================

-- Estado final de prospectos y vendedores
SELECT p.id_prospecto, p.nombre, p.estado, v.nombre AS vendedor
FROM prospecto p LEFT JOIN vendedor v ON v.id_vendedor = p.id_vendedor
ORDER BY p.id_prospecto;

-- Ventas registradas (no debe haber ventas con 0 usuarios)
SELECT id_venta, id_prospecto, modelo_licencia, num_usuarios, monto FROM venta;

-- Bitácora: los cambios deshechos con ROLLBACK no aparecen
SELECT * FROM bitacora ORDER BY id_bitacora;

-- =====================================================================
-- PARTE 5. AISLAMIENTO Y DURABILIDAD
-- =====================================================================
-- AISLAMIENTO (probar con DOS pestañas de Workbench)
-- Pestaña 1:
--   START TRANSACTION;
--   SELECT * FROM prospecto WHERE correo = 'ana@abc.com' FOR UPDATE;
--   -- (no hacer COMMIT todavía)
--
-- Pestaña 2:
--   UPDATE prospecto SET telefono = '0000' WHERE correo = 'ana@abc.com';
--   -- queda esperando hasta que la pestaña 1 haga COMMIT o ROLLBACK
--
-- Nivel de aislamiento actual (MySQL por defecto: REPEATABLE READ):
SELECT @@transaction_isolation AS nivel_aislamiento;

-- DURABILIDAD: todas las tablas usan InnoDB (transaccional, con registro de
-- redo) y el valor 1 hace que cada COMMIT se escriba a disco.
SELECT table_name, engine
FROM information_schema.tables
WHERE table_schema = 'zimbra_oneview' AND table_type = 'BASE TABLE'
ORDER BY table_name;

SHOW VARIABLES LIKE 'innodb_flush_log_at_trx_commit';

-- =====================================================================
-- 8. REPORTE MENSUAL Y CONSULTAS DE VERIFICACIÓN GENERALES
-- =====================================================================

-- Reporte mensual (procedimiento almacenado): mes actual y los dos anteriores
CALL sp_reporte_mensual(YEAR(CURRENT_DATE), MONTH(CURRENT_DATE));
CALL sp_reporte_mensual(YEAR(DATE_SUB(CURRENT_DATE, INTERVAL 1 MONTH)), MONTH(DATE_SUB(CURRENT_DATE, INTERVAL 1 MONTH)));
CALL sp_reporte_mensual(YEAR(DATE_SUB(CURRENT_DATE, INTERVAL 2 MONTH)), MONTH(DATE_SUB(CURRENT_DATE, INTERVAL 2 MONTH)));

-- Prospectos con su puntaje, calificación y vendedor
SELECT p.id_prospecto, p.nombre, p.puntaje, p.calificado, p.estado, v.nombre AS vendedor
FROM prospecto p LEFT JOIN vendedor v ON v.id_vendedor = p.id_vendedor;

-- Alertas generadas para los vendedores
SELECT a.id_alerta, v.nombre AS vendedor, a.mensaje, a.fecha_hora, a.leida
FROM alerta a JOIN vendedor v ON v.id_vendedor = a.id_vendedor
ORDER BY a.fecha_hora DESC;

-- Reportes
SELECT * FROM v_trafico_diario;
SELECT * FROM v_paginas_top;
SELECT * FROM v_prospectos_calificados;
SELECT * FROM v_pruebas_por_vencer;
SELECT * FROM v_conversion;
SELECT * FROM v_rendimiento_campanas;
SELECT * FROM v_ventas_por_vendedor;

-- Bitácora de cambios
SELECT * FROM bitacora ORDER BY id_bitacora;

-- =====================================================================
-- 9. VERIFICACIÓN: MÍNIMO 30 REGISTROS POR TABLA
-- =====================================================================
SELECT tabla, filas, IF(filas >= 30, 'OK', 'FALTAN REGISTROS') AS estado FROM (
    SELECT 'vendedor'              AS tabla, COUNT(*) AS filas FROM vendedor
    UNION ALL SELECT 'version_producto',       COUNT(*) FROM version_producto
    UNION ALL SELECT 'prospecto',              COUNT(*) FROM prospecto
    UNION ALL SELECT 'descarga_prueba',        COUNT(*) FROM descarga_prueba
    UNION ALL SELECT 'visita_web',             COUNT(*) FROM visita_web
    UNION ALL SELECT 'regla_puntaje',          COUNT(*) FROM regla_puntaje
    UNION ALL SELECT 'configuracion',          COUNT(*) FROM configuracion
    UNION ALL SELECT 'alerta',                 COUNT(*) FROM alerta
    UNION ALL SELECT 'contacto_seguimiento',   COUNT(*) FROM contacto_seguimiento
    UNION ALL SELECT 'venta',                  COUNT(*) FROM venta
    UNION ALL SELECT 'campana',                COUNT(*) FROM campana
    UNION ALL SELECT 'envio_correo',           COUNT(*) FROM envio_correo
    UNION ALL SELECT 'campo_personalizado',    COUNT(*) FROM campo_personalizado
    UNION ALL SELECT 'valor_campo_prospecto',  COUNT(*) FROM valor_campo_prospecto
    UNION ALL SELECT 'sincronizacion_crm',     COUNT(*) FROM sincronizacion_crm
    UNION ALL SELECT 'bitacora',               COUNT(*) FROM bitacora
) t ORDER BY tabla;
