// ===========================================================================
// CATÁLOGO DE COSMÉTICOS Y MEJORAS (68 elementos)
// Solo datos: aquí se agregan, quitan o reordenan elementos sin tocar el resto.
// ===========================================================================
import 'package:flutter/material.dart';

enum CosCat { button, vinyl, frame, viz, particles, theme, transition, title }

String catName(CosCat c, bool es) {
  switch (c) {
    case CosCat.button:
      return es ? 'Botones de reproducción' : 'Play buttons';
    case CosCat.vinyl:
      return es ? 'Vinilos y discos' : 'Vinyls and discs';
    case CosCat.frame:
      return es ? 'Marcos de carátula' : 'Cover frames';
    case CosCat.viz:
      return es ? 'Ecualizadores visuales' : 'Visual equalizers';
    case CosCat.particles:
      return es ? 'Partículas y efectos' : 'Particles and effects';
    case CosCat.theme:
      return es ? 'Temas y acentos' : 'Themes and accents';
    case CosCat.transition:
      return es ? 'Transiciones del carrusel' : 'Carousel transitions';
    case CosCat.title:
      return es ? 'Títulos de perfil' : 'Profile titles';
  }
}

IconData catIcon(CosCat c) {
  switch (c) {
    case CosCat.button:
      return Icons.play_circle_outline;
    case CosCat.vinyl:
      return Icons.album;
    case CosCat.frame:
      return Icons.filter_frames_outlined;
    case CosCat.viz:
      return Icons.graphic_eq;
    case CosCat.particles:
      return Icons.auto_awesome;
    case CosCat.theme:
      return Icons.palette_outlined;
    case CosCat.transition:
      return Icons.view_carousel_outlined;
    case CosCat.title:
      return Icons.military_tech_outlined;
  }
}

class Cosmetic {
  final String id;
  final CosCat cat;
  final String es;
  final String en;
  final int minutes; // minutos necesarios para desbloquearlo
  final bool listen; // true = tiempo escuchando música; false = tiempo en la app
  final int a; // variante principal (forma / patrón / estilo)
  final int b; // variante secundaria (relleno, etc.)
  final int c1;
  final int c2;
  final int c3;
  const Cosmetic(
    this.id,
    this.cat,
    this.es,
    this.en,
    this.minutes,
    this.listen, {
    this.a = 0,
    this.b = 0,
    this.c1 = 0xFFFFFFFF,
    this.c2 = 0xFFFFFFFF,
    this.c3 = 0xFFFFFFFF,
  });
}

/// Los 68 elementos, ordenados por categoría y por tiempo de desbloqueo.
/// Tiempos desde 2 minutos hasta 100 horas (6000 min).
const List<Cosmetic> kCosmetics = [
  // ---- Botones de reproducción (10) · tiempo escuchando ----
  Cosmetic('btn_pink', CosCat.button, 'Redondo Rosa', 'Pink Round', 3, true, a: 0, b: 0, c1: 0xFFEC4899),
  Cosmetic('btn_mint', CosCat.button, 'Cápsula Menta', 'Mint Capsule', 20, true, a: 6, b: 1, c1: 0xFF10B981, c2: 0xFF6EE7B7),
  Cosmetic('btn_blue', CosCat.button, 'Cuadrado Suave', 'Soft Square', 45, true, a: 1, b: 0, c1: 0xFF3B82F6),
  Cosmetic('btn_hex', CosCat.button, 'Hexágono Ámbar', 'Amber Hexagon', 90, true, a: 2, b: 1, c1: 0xFFF59E0B, c2: 0xFFFBBF24),
  Cosmetic('btn_diamond', CosCat.button, 'Diamante Neón', 'Neon Diamond', 150, true, a: 3, b: 3, c1: 0xFF22D3EE),
  Cosmetic('btn_octa', CosCat.button, 'Octágono Lava', 'Lava Octagon', 240, true, a: 5, b: 1, c1: 0xFFEF4444, c2: 0xFFF97316),
  Cosmetic('btn_ring', CosCat.button, 'Anillo Plata', 'Silver Ring', 360, true, a: 0, b: 2, c1: 0xFFE5E7EB),
  Cosmetic('btn_star', CosCat.button, 'Estrella Dorada', 'Golden Star', 600, true, a: 4, b: 1, c1: 0xFFF59E0B, c2: 0xFFFDE047),
  Cosmetic('btn_glass', CosCat.button, 'Cristal', 'Glass', 900, true, a: 1, b: 4, c1: 0xFFFFFFFF),
  Cosmetic('btn_galaxy', CosCat.button, 'Aura Galaxia', 'Galaxy Aura', 1500, true, a: 0, b: 5, c1: 0xFF7C3AED, c2: 0xFF2563EB),

  // ---- Vinilos y discos (10) · tiempo escuchando ----
  Cosmetic('vin_red', CosCat.vinyl, 'Clásico Rojo', 'Classic Red', 5, true, a: 0, c1: 0xFF111118, c2: 0xFF343442, c3: 0xFFDC2626),
  Cosmetic('vin_aurora', CosCat.vinyl, 'Aurora', 'Aurora', 30, true, a: 1, c1: 0xFF10B981, c2: 0xFF3B82F6, c3: 0xFFFFFFFF),
  Cosmetic('vin_galaxy', CosCat.vinyl, 'Galaxia', 'Galaxy', 60, true, a: 2, c1: 0xFF6D28D9, c2: 0xFF0B1026, c3: 0xFFEC4899),
  Cosmetic('vin_gold', CosCat.vinyl, 'Oro Líquido', 'Liquid Gold', 120, true, a: 1, c1: 0xFFFDE047, c2: 0xFFB45309, c3: 0xFF1F2937),
  Cosmetic('vin_ice', CosCat.vinyl, 'Hielo', 'Ice', 200, true, a: 2, c1: 0xFFE0F2FE, c2: 0xFF38BDF8, c3: 0xFF0369A1),
  Cosmetic('vin_fire', CosCat.vinyl, 'Fuego', 'Fire', 300, true, a: 1, c1: 0xFFEF4444, c2: 0xFFFBBF24, c3: 0xFF7F1D1D),
  Cosmetic('vin_neon', CosCat.vinyl, 'Neón', 'Neon', 480, true, a: 0, c1: 0xFF0A0A14, c2: 0xFF22D3EE, c3: 0xFFEC4899),
  Cosmetic('vin_cd', CosCat.vinyl, 'CD Plateado', 'Silver CD', 720, true, a: 4, c1: 0xFFE5E7EB, c2: 0xFF9CA3AF, c3: 0xFFF3F4F6),
  Cosmetic('vin_marble', CosCat.vinyl, 'Mármol', 'Marble', 1200, true, a: 2, c1: 0xFFF3F4F6, c2: 0xFF6B7280, c3: 0xFF111827),
  Cosmetic('vin_rainbow', CosCat.vinyl, 'Arcoíris', 'Rainbow', 2400, true, a: 5, c3: 0xFFFFFFFF),

  // ---- Marcos de carátula (8) · tiempo en la app ----
  Cosmetic('frm_white', CosCat.frame, 'Fino Blanco', 'Thin White', 4, false, a: 0, c1: 0xFFFFFFFF),
  Cosmetic('frm_gold', CosCat.frame, 'Doble Dorado', 'Double Gold', 25, false, a: 1, c1: 0xFFFBBF24, c2: 0xFFB45309),
  Cosmetic('frm_cyan', CosCat.frame, 'Neón Cian', 'Cyan Neon', 50, false, a: 2, c1: 0xFF22D3EE),
  Cosmetic('frm_sunset', CosCat.frame, 'Atardecer', 'Sunset', 100, false, a: 3, c1: 0xFFF97316, c2: 0xFFEC4899),
  Cosmetic('frm_polaroid', CosCat.frame, 'Polaroid', 'Polaroid', 180, false, a: 4, c1: 0xFFFFFFFF),
  Cosmetic('frm_corners', CosCat.frame, 'Esquinas Rosa', 'Pink Corners', 300, false, a: 5, c1: 0xFFF472B6),
  Cosmetic('frm_ice', CosCat.frame, 'Cristal Helado', 'Frosted Glass', 600, false, a: 6, c1: 0xFFBAE6FD),
  Cosmetic('frm_aura', CosCat.frame, 'Corona de Luz', 'Crown of Light', 1200, false, a: 7, c1: 0xFFA855F7, c2: 0xFF22D3EE),

  // ---- Ecualizadores visuales (8) · tiempo escuchando ----
  Cosmetic('viz_bars', CosCat.viz, 'Barras Clásicas', 'Classic Bars', 8, true, a: 0, c1: 0xFFA78BFA),
  Cosmetic('viz_lines', CosCat.viz, 'Líneas Finas', 'Thin Lines', 35, true, a: 1, c1: 0xFF22D3EE),
  Cosmetic('viz_dots', CosCat.viz, 'Puntos Rítmicos', 'Rhythm Dots', 75, true, a: 2, c1: 0xFFF472B6),
  Cosmetic('viz_mirror', CosCat.viz, 'Espejo', 'Mirror', 130, true, a: 3, c1: 0xFF34D399),
  Cosmetic('viz_wave', CosCat.viz, 'Onda Líquida', 'Liquid Wave', 270, true, a: 4, c1: 0xFF60A5FA),
  Cosmetic('viz_radial', CosCat.viz, 'Radial', 'Radial', 420, true, a: 5, c1: 0xFFFBBF24),
  Cosmetic('viz_grad', CosCat.viz, 'Barras Degradé', 'Gradient Bars', 840, true, a: 6, c1: 0xFFEC4899, c2: 0xFF3B82F6),
  Cosmetic('viz_pulse', CosCat.viz, 'Pulso de Anillos', 'Ring Pulse', 1800, true, a: 7, c1: 0xFFF87171),

  // ---- Partículas y efectos (10) · tiempo en la app ----
  Cosmetic('par_notes', CosCat.particles, 'Notas Flotantes', 'Floating Notes', 6, false, a: 0, c1: 0xFFFFFFFF),
  Cosmetic('par_stars', CosCat.particles, 'Lluvia de Estrellas', 'Star Shower', 15, false, a: 1, c1: 0xFFFDE047),
  Cosmetic('par_bubbles', CosCat.particles, 'Burbujas', 'Bubbles', 40, false, a: 2, c1: 0xFF7DD3FC),
  Cosmetic('par_snow', CosCat.particles, 'Nieve', 'Snow', 80, false, a: 3, c1: 0xFFFFFFFF),
  Cosmetic('par_fireflies', CosCat.particles, 'Luciérnagas', 'Fireflies', 140, false, a: 4, c1: 0xFFFDE68A),
  Cosmetic('par_confetti', CosCat.particles, 'Confeti', 'Confetti', 220, false, a: 5, c1: 0xFFF472B6),
  Cosmetic('par_hearts', CosCat.particles, 'Corazones', 'Hearts', 400, false, a: 6, c1: 0xFFF472B6),
  Cosmetic('par_embers', CosCat.particles, 'Brasas', 'Embers', 800, false, a: 7, c1: 0xFFFB923C),
  Cosmetic('par_rain', CosCat.particles, 'Lluvia', 'Rain', 1500, false, a: 8, c1: 0xFF93C5FD),
  Cosmetic('par_sparkles', CosCat.particles, 'Destellos', 'Sparkles', 3000, false, a: 9, c1: 0xFFE9D5FF),

  // ---- Temas y acentos (12) · tiempo en la app ----
  Cosmetic('th_aurora', CosCat.theme, 'Aurora', 'Aurora', 10, false, c1: 0xFF14B8A6),
  Cosmetic('th_sunset', CosCat.theme, 'Atardecer', 'Sunset', 18, false, c1: 0xFFFB7185),
  Cosmetic('th_ocean', CosCat.theme, 'Océano', 'Ocean', 28, false, c1: 0xFF0284C7),
  Cosmetic('th_forest', CosCat.theme, 'Bosque', 'Forest', 55, false, c1: 0xFF16A34A),
  Cosmetic('th_sakura', CosCat.theme, 'Sakura', 'Sakura', 110, false, c1: 0xFFF472B6),
  Cosmetic('th_midnight', CosCat.theme, 'Medianoche', 'Midnight', 170, false, c1: 0xFF4F46E5),
  Cosmetic('th_lava', CosCat.theme, 'Lava', 'Lava', 260, false, c1: 0xFFDC2626),
  Cosmetic('th_mint', CosCat.theme, 'Menta', 'Mint', 390, false, c1: 0xFF2DD4BF),
  Cosmetic('th_gold', CosCat.theme, 'Dorado', 'Gold', 540, false, c1: 0xFFEAB308),
  Cosmetic('th_neon', CosCat.theme, 'Neón', 'Neon', 780, false, c1: 0xFF84CC16),
  Cosmetic('th_ice', CosCat.theme, 'Hielo', 'Ice', 1100, false, c1: 0xFF38BDF8),
  Cosmetic('th_galaxy', CosCat.theme, 'Galaxia', 'Galaxy', 2000, false, c1: 0xFF9333EA),

  // ---- Transiciones del carrusel (4) · tiempo escuchando ----
  Cosmetic('trn_tilt', CosCat.transition, 'Inclinación 3D', '3D Tilt', 12, true, a: 0),
  Cosmetic('trn_zoom', CosCat.transition, 'Zoom Dinámico', 'Dynamic Zoom', 95, true, a: 1),
  Cosmetic('trn_spin', CosCat.transition, 'Giro Suave', 'Soft Spin', 360, true, a: 2),
  Cosmetic('trn_cascade', CosCat.transition, 'Cascada', 'Cascade', 1000, true, a: 3),

  // ---- Títulos de perfil (6) · tiempo en la app ----
  Cosmetic('ttl_1', CosCat.title, 'Primer Acorde', 'First Chord', 2, false, c1: 0xFF94A3B8),
  Cosmetic('ttl_2', CosCat.title, 'Oyente Curioso', 'Curious Listener', 60, false, c1: 0xFF60A5FA),
  Cosmetic('ttl_3', CosCat.title, 'Melómano', 'Music Lover', 300, false, c1: 0xFF34D399),
  Cosmetic('ttl_4', CosCat.title, 'Audiófilo', 'Audiophile', 1200, false, c1: 0xFFFBBF24),
  Cosmetic('ttl_5', CosCat.title, 'Leyenda del Ritmo', 'Rhythm Legend', 3000, false, c1: 0xFFF472B6),
  Cosmetic('ttl_6', CosCat.title, 'Maestro de Play Music', 'Play Music Master', 6000, false, c1: 0xFFA78BFA),
];
