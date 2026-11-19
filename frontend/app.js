/* Zimbra OneView - lógica del frontend (JavaScript puro, sin librerías). */
"use strict";

const API = (window.API_BASE || "").replace(/\/$/, "");
const $ = (id) => document.getElementById(id);

/* ---------- Utilidades ---------- */

// Escapa texto antes de insertarlo como HTML (evita inyección de código).
function esc(valor) {
  return String(valor ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
  );
}

const ESTADOS = {
  nuevo: "Nuevo", contactado: "Contactado", en_negociacion: "En negociación",
  ganado: "Ganado", perdido: "Perdido",
};
const badge = (estado) =>
  `<span class="badge badge-${esc(estado)}">${esc(ESTADOS[estado] || estado)}</span>`;

const fmtFecha = (f) => (f ? new Date(f).toLocaleString("es-CO", { dateStyle: "medium", timeStyle: "short" }) : "—");
const fmtNum = (n) => Number(n ?? 0).toLocaleString("es-CO");

// Llamada a la API: devuelve JSON o lanza Error con el mensaje legible del backend.
async function api(ruta, opciones = {}) {
  const init = { method: "GET", headers: {}, ...opciones };
  if (init.body && typeof init.body !== "string") {
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(init.body);
  }
  let resp;
  try {
    resp = await fetch(API + ruta, init);
  } catch {
    throw new Error("No se pudo contactar la API. ¿Está corriendo el servidor?");
  }
  let datos = null;
  try { datos = await resp.json(); } catch { /* sin cuerpo JSON */ }
  if (!resp.ok) {
    let detalle = datos && datos.detail;
    if (Array.isArray(detalle)) {            // errores de validación de Pydantic
      detalle = detalle.map((d) => `${(d.loc || []).slice(1).join(".")}: ${d.msg}`).join(" | ");
    }
    throw new Error(detalle || `Error ${resp.status}`);
  }
  return datos;
}

let toastTimer;
function toast(texto) {
  const t = $("toast");
  t.textContent = texto;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.hidden = true), 3500);
}

function mostrarMensaje(id, texto, ok) {
  const m = $(id);
  m.textContent = texto;
  m.className = "msg " + (ok ? "msg-ok" : "msg-bad");
  m.hidden = false;
}

// Desactiva el botón mientras corre la petición para evitar doble envío.
async function conBoton(boton, fn) {
  boton.disabled = true;
  try { return await fn(); } finally { boton.disabled = false; }
}

function llenarSelect(select, filas, valor, texto, vacio) {
  select.innerHTML =
    (vacio ? `<option value="">${esc(vacio)}</option>` : "") +
    filas.map((f) => `<option value="${esc(f[valor])}">${esc(f[texto])}</option>`).join("");
}

/* ---------- Navegación por pestañas ---------- */

const cargadores = {
  resumen: cargarResumen,
  prospectos: cargarProspectos,
  alertas: () => {},
  cartera: cargarVendedoresTabla,
};

function mostrarVista(nombre) {
  document.querySelectorAll(".tab").forEach((t) => t.classList.toggle("active", t.dataset.view === nombre));
  document.querySelectorAll(".view").forEach((v) => v.classList.toggle("active", v.id === "view-" + nombre));
  if (cargadores[nombre]) cargadores[nombre]().catch((e) => toast(e.message));
}

$("tabs").addEventListener("click", (e) => {
  const tab = e.target.closest(".tab");
  if (tab) mostrarVista(tab.dataset.view);
});

/* ---------- Estado de la conexión ---------- */

async function revisarSalud() {
  const el = $("estado-api");
  try {
    const h = await api("/health");
    const ok = h.base_de_datos === "ok";
    el.textContent = ok ? "API y base de datos conectadas" : "API activa, base de datos sin conexión";
    el.className = "status " + (ok ? "status-ok" : "status-bad");
  } catch {
    el.textContent = "API sin conexión";
    el.className = "status status-bad";
  }
}

/* ---------- Resumen ---------- */

async function cargarResumen() {
  const [conv, calif] = await Promise.all([
    api("/reportes/conversion"),
    api("/reportes/prospectos-calificados"),
  ]);

  const kpis = [
    ["Pruebas descargadas", fmtNum(conv.pruebas_descargadas)],
    ["Prospectos calificados", fmtNum(conv.prospectos_calificados)],
    ["Ventas cerradas", fmtNum(conv.ventas_cerradas)],
    ["Tasa de conversión", conv.tasa_conversion_pct == null ? "—" : conv.tasa_conversion_pct + " %"],
  ];
  $("kpis").innerHTML = kpis.map(([t, v]) => `<div class="kpi"><span>${t}</span><strong>${esc(v)}</strong></div>`).join("");

  $("tbl-calificados").innerHTML = calif.length
    ? calif.map((p) => `<tr>
        <td>${esc(p.nombre)}<br><small>${esc(p.correo)}</small></td>
        <td>${esc(p.empresa || "—")}</td>
        <td>${esc(p.puntaje)}</td>
        <td>${badge(p.estado)}</td>
        <td>${esc(p.vendedor || "Sin asignar")}</td>
        <td>${esc(fmtFecha(p.ultima_visita))}</td></tr>`).join("")
    : `<tr><td class="empty" colspan="6">No hay prospectos calificados en seguimiento.</td></tr>`;
}
$("btn-refrescar-resumen").addEventListener("click", () => cargarResumen().catch((e) => toast(e.message)));

/* ---------- Prospectos ---------- */

let prospectosCache = [];

async function cargarProspectos() {
  const q = new URLSearchParams({ limite: $("f-limite").value });
  if ($("f-estado").value) q.set("estado", $("f-estado").value);
  if ($("f-calificado").value) q.set("calificado", $("f-calificado").value);
  prospectosCache = await api("/prospectos?" + q);
  pintarProspectos();
}

// La búsqueda de texto se aplica en el navegador sobre lo ya descargado.
function pintarProspectos() {
  const txt = $("f-buscar").value.trim().toLowerCase();
  const filas = prospectosCache.filter((p) =>
    !txt || [p.nombre, p.empresa, p.correo].some((c) => (c || "").toLowerCase().includes(txt)));

  $("tbl-prospectos").innerHTML = filas.length
    ? filas.map((p) => `<tr>
        <td>${esc(p.id_prospecto)}</td>
        <td>${esc(p.nombre)}</td>
        <td>${esc(p.empresa || "—")}</td>
        <td>${esc(p.correo)}</td>
        <td>${esc(p.puntaje)}</td>
        <td>${p.calificado ? "Sí" : "No"}</td>
        <td>${esc(p.vendedor || "—")}</td>
        <td>
          <select data-id="${esc(p.id_prospecto)}" data-actual="${esc(p.estado)}" aria-label="Cambiar estado">
            ${Object.entries(ESTADOS).map(([v, t]) =>
              `<option value="${v}"${v === p.estado ? " selected" : ""}>${t}</option>`).join("")}
          </select>
        </td></tr>`).join("")
    : `<tr><td class="empty" colspan="8">Sin resultados.</td></tr>`;
  $("contador-prospectos").textContent = `${filas.length} prospecto(s) mostrados.`;
}

$("form-filtros").addEventListener("submit", (e) => {
  e.preventDefault();
  cargarProspectos().catch((err) => toast(err.message));
});
$("f-buscar").addEventListener("input", pintarProspectos);

// Cambio de estado desde la tabla: PUT /prospectos/{id}/estado
$("tbl-prospectos").addEventListener("change", async (e) => {
  const sel = e.target.closest("select[data-id]");
  if (!sel) return;
  try {
    await api(`/prospectos/${sel.dataset.id}/estado`, { method: "PUT", body: { estado: sel.value } });
    sel.dataset.actual = sel.value;
    toast("Estado actualizado");
  } catch (err) {
    sel.value = sel.dataset.actual;   // se revierte lo que se ve si la BD lo rechazó
    toast(err.message);
  }
});

/* ---------- Nueva descarga ---------- */

$("form-descarga").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = e.target;
  const d = Object.fromEntries(new FormData(f));
  d.id_version = Number(d.id_version);
  for (const k of ["empresa", "cargo", "telefono", "pais"]) if (!d[k]) d[k] = null;

  await conBoton(f.querySelector("button"), async () => {
    try {
      const r = await api("/prospectos/descarga", { method: "POST", body: d });
      mostrarMensaje("msg-descarga",
        `Descarga registrada. Prospecto #${r.id_prospecto} · puntaje ${r.puntaje} · ${r.calificado ? "calificado" : "aún no calificado"}.`, true);
      f.reset();
    } catch (err) {
      mostrarMensaje("msg-descarga", err.message, false);
    }
  });
});

/* ---------- Cerrar venta ---------- */

$("form-venta").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = e.target;
  const d = Object.fromEntries(new FormData(f));
  d.id_version = Number(d.id_version);
  d.num_usuarios = Number(d.num_usuarios);
  d.monto = Number(d.monto);

  await conBoton(f.querySelector("button"), async () => {
    try {
      const r = await api("/ventas", { method: "POST", body: d });
      mostrarMensaje("msg-venta", r.resultado, true);
      f.reset();
    } catch (err) {
      // Aquí llega el texto de ROLLBACK TOTAL / ROLLBACK PARCIAL del procedimiento
      mostrarMensaje("msg-venta", err.message, false);
    }
  });
});

/* ---------- Alertas ---------- */

async function cargarAlertas() {
  const id = $("sel-vendedor-alertas").value;
  if (!id) return;
  const solo = $("chk-no-leidas").checked;
  const filas = await api(`/alertas/${id}?solo_no_leidas=${solo}`);
  $("tbl-alertas").innerHTML = filas.length
    ? filas.map((a) => `<tr>
        <td>${esc(fmtFecha(a.fecha_hora))}</td>
        <td>${esc(a.mensaje)}</td>
        <td>${a.leida ? "Sí" : "No"}</td></tr>`).join("")
    : `<tr><td class="empty" colspan="3">Sin alertas.</td></tr>`;
}
$("btn-alertas").addEventListener("click", () => cargarAlertas().catch((e) => toast(e.message)));
$("sel-vendedor-alertas").addEventListener("change", () => cargarAlertas().catch((e) => toast(e.message)));
$("chk-no-leidas").addEventListener("change", () => cargarAlertas().catch((e) => toast(e.message)));

/* ---------- Cartera ---------- */

async function cargarVendedoresTabla() {
  const v = await api("/vendedores");
  $("tbl-vendedores").innerHTML = v.map((x) => `<tr>
      <td>${esc(x.nombre)}</td><td>${esc(x.rol)}</td><td>${esc(x.prospectos_activos)}</td></tr>`).join("");
}

$("form-cartera").addEventListener("submit", async (e) => {
  e.preventDefault();
  const origen = Number($("sel-origen").value);
  const destino = Number($("sel-destino").value);
  await conBoton(e.target.querySelector("button"), async () => {
    try {
      const r = await api("/vendedores/reasignar", { method: "POST", body: { id_origen: origen, id_destino: destino } });
      mostrarMensaje("msg-cartera", r.resultado, true);
      await cargarVendedoresTabla();
    } catch (err) {
      mostrarMensaje("msg-cartera", err.message, false);
    }
  });
});

/* ---------- Arranque ---------- */

async function cargarCatalogos() {
  const [vendedores, pruebas, gratuitas, comerciales] = await Promise.all([
    api("/vendedores"), api("/versiones?tipo=prueba"), api("/versiones?tipo=gratuita"), api("/versiones?tipo=comercial"),
  ]);

  // Solo se descargan versiones gratuitas o de prueba; solo se venden las comerciales.
  const descargables = [...pruebas, ...gratuitas];
  llenarSelect($("sel-version-descarga"), descargables, "id_version", "nombre");
  $("sel-version-descarga").value = "2";
  llenarSelect($("sel-version-venta"), comerciales, "id_version", "nombre");

  const activos = vendedores.filter((v) => v.activo);
  llenarSelect($("sel-vendedor-alertas"), activos, "id_vendedor", "nombre", "Seleccione…");
  llenarSelect($("sel-origen"), activos, "id_vendedor", "nombre");
  llenarSelect($("sel-destino"), activos.filter((v) => v.rol === "vendedor"), "id_vendedor", "nombre");
}

(async function iniciar() {
  await revisarSalud();
  setInterval(revisarSalud, 30000);
  try {
    await cargarCatalogos();
    await cargarResumen();
  } catch (e) {
    toast(e.message);
  }
})();
