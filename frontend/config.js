// URL base de la API.
//   ""                         -> el frontend lo sirve el propio FastAPI (mismo origen). Es lo normal.
//   "https://tu-api.ejemplo"   -> solo si publicas el frontend en otro sitio (ej. GitHub Pages).
//                                 En ese caso agrega ese dominio a CORS_ORIGINS en el .env del backend.
window.API_BASE = "";
