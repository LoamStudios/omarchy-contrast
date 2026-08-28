// Colour maths for the Omarchy contrast overlay.
// Pure functions, no Qt dependencies, so they can be unit-tested with node.

.pragma library

// ---------- parsing ----------

function parseHex(s) {
  var t = String(s || "").trim().replace(/^#/, "")
  if (/^[0-9a-fA-F]{3}$/.test(t)) t = t[0] + t[0] + t[1] + t[1] + t[2] + t[2]
  if (!/^[0-9a-fA-F]{6}$/.test(t)) return null
  return {
    r: parseInt(t.substr(0, 2), 16),
    g: parseInt(t.substr(2, 2), 16),
    b: parseInt(t.substr(4, 2), 16)
  }
}

function toHex(c) {
  function h(v) {
    v = Math.max(0, Math.min(255, Math.round(v)))
    return (v < 16 ? "0" : "") + v.toString(16)
  }
  return "#" + h(c.r) + h(c.g) + h(c.b)
}

// ---------- WCAG 2.x ----------

function srgbToLinear(v) {
  v /= 255
  return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
}

function linearToSrgb(v) {
  v = Math.max(0, Math.min(1, v))
  return 255 * (v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055)
}

function luminance(c) {
  return 0.2126 * srgbToLinear(c.r) + 0.7152 * srgbToLinear(c.g) + 0.0722 * srgbToLinear(c.b)
}

function wcagRatio(fg, bg) {
  var a = luminance(fg), b = luminance(bg)
  var hi = Math.max(a, b), lo = Math.min(a, b)
  return (hi + 0.05) / (lo + 0.05)
}

// WCAG 2 success criteria thresholds.
var WCAG = {
  normalAA: 4.5, normalAAA: 7.0,
  largeAA: 3.0, largeAAA: 4.5,
  uiAA: 3.0
}

function wcagGrade(ratio) {
  if (ratio >= WCAG.normalAAA) return "AAA"
  if (ratio >= WCAG.normalAA) return "AA"
  if (ratio >= WCAG.largeAA) return "AA Large"
  return "Fail"
}

// ---------- APCA (W3 0.1.9, 4g constants) ----------

var APCA = {
  mainTRC: 2.4,
  sRco: 0.2126729, sGco: 0.7151522, sBco: 0.0721750,
  normBG: 0.56, normTXT: 0.57, revTXT: 0.62, revBG: 0.65,
  blkThrs: 0.022, blkClmp: 1.414, scaleBoW: 1.14, scaleWoB: 1.14,
  loBoWoffset: 0.027, loWoBoffset: 0.027, loClip: 0.1, deltaYmin: 0.0005
}

function apcaY(c) {
  return APCA.sRco * Math.pow(c.r / 255, APCA.mainTRC)
       + APCA.sGco * Math.pow(c.g / 255, APCA.mainTRC)
       + APCA.sBco * Math.pow(c.b / 255, APCA.mainTRC)
}

function apcaLc(fg, bg) {
  var txtY = apcaY(fg), bgY = apcaY(bg)
  if (txtY <= APCA.blkThrs) txtY += Math.pow(APCA.blkThrs - txtY, APCA.blkClmp)
  if (bgY <= APCA.blkThrs) bgY += Math.pow(APCA.blkThrs - bgY, APCA.blkClmp)
  if (Math.abs(bgY - txtY) < APCA.deltaYmin) return 0
  var sapc, out
  if (bgY > txtY) {
    sapc = (Math.pow(bgY, APCA.normBG) - Math.pow(txtY, APCA.normTXT)) * APCA.scaleBoW
    out = sapc < APCA.loClip ? 0 : sapc - APCA.loBoWoffset
  } else {
    sapc = (Math.pow(bgY, APCA.revBG) - Math.pow(txtY, APCA.revTXT)) * APCA.scaleWoB
    out = sapc > -APCA.loClip ? 0 : sapc + APCA.loWoBoffset
  }
  return out * 100
}

// Rough APCA readability bands (absolute Lc).
function apcaGrade(lc) {
  var a = Math.abs(lc)
  if (a >= 90) return "Preferred Body Text"
  if (a >= 75) return "Body Text"
  if (a >= 60) return "Content Text"
  if (a >= 45) return "Large / Headline"
  if (a >= 30) return "Non-Text Only"
  if (a >= 15) return "Disabled / Spot"
  return "Invisible"
}

// ---------- OKLab / OKLCH ----------

function srgbToOklab(c) {
  var r = srgbToLinear(c.r), g = srgbToLinear(c.g), b = srgbToLinear(c.b)
  var l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  var m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  var s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  return {
    L: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
  }
}

function oklabToLinear(lab) {
  var l_ = lab.L + 0.3963377774 * lab.a + 0.2158037573 * lab.b
  var m_ = lab.L - 0.1055613458 * lab.a - 0.0638541728 * lab.b
  var s_ = lab.L - 0.0894841775 * lab.a - 1.2914855480 * lab.b
  var l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
  return {
    r: +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    b: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
  }
}

function inGamut(lin) {
  var e = 0.0005
  return lin.r >= -e && lin.r <= 1 + e && lin.g >= -e && lin.g <= 1 + e && lin.b >= -e && lin.b <= 1 + e
}

// Convert OKLCH to sRGB, reducing chroma until the colour fits the gamut.
function oklchToSrgb(L, C, h) {
  var lo = 0, hi = C, best = null
  for (var i = 0; i < 20; i++) {
    var mid = (lo + hi) / 2
    var lab = { L: L, a: mid * Math.cos(h), b: mid * Math.sin(h) }
    var lin = oklabToLinear(lab)
    if (inGamut(lin)) { best = lin; lo = mid } else { hi = mid }
  }
  if (!best) best = oklabToLinear({ L: L, a: 0, b: 0 })
  return { r: linearToSrgb(best.r), g: linearToSrgb(best.g), b: linearToSrgb(best.b) }
}

// Find the closest foreground (same hue & chroma, lightness adjusted) that
// reaches `target` WCAG ratio against `bg`. Returns null if already passing
// or if no lightness achieves the target.
function suggestForeground(fg, bg, target) {
  if (wcagRatio(fg, bg) >= target) return null
  var lab = srgbToOklab(fg)
  var C = Math.sqrt(lab.a * lab.a + lab.b * lab.b)
  var h = Math.atan2(lab.b, lab.a)
  var bgL = srgbToOklab(bg).L
  // Move away from the background's lightness. Try that direction first,
  // then the other as a fallback.
  var dirs = lab.L >= bgL ? [1, -1] : [-1, 1]
  for (var d = 0; d < dirs.length; d++) {
    var step = 0.005 * dirs[d]
    for (var L = lab.L + step; L >= 0 && L <= 1; L += step) {
      var cand = oklchToSrgb(L, C, h)
      var rounded = { r: Math.round(cand.r), g: Math.round(cand.g), b: Math.round(cand.b) }
      if (wcagRatio(rounded, bg) >= target) return rounded
    }
  }
  return null
}

// Full report used by the UI.
function report(fg, bg) {
  var ratio = wcagRatio(fg, bg)
  var lc = apcaLc(fg, bg)
  return {
    ratio: ratio,
    ratioText: (Math.round(ratio * 100) / 100).toFixed(2) + ":1",
    grade: wcagGrade(ratio),
    normalAA: ratio >= WCAG.normalAA,
    normalAAA: ratio >= WCAG.normalAAA,
    largeAA: ratio >= WCAG.largeAA,
    largeAAA: ratio >= WCAG.largeAAA,
    uiAA: ratio >= WCAG.uiAA,
    lc: lc,
    lcText: "Lc " + (lc < 0 ? "−" : "") + Math.abs(Math.round(lc)),
    lcGrade: apcaGrade(lc)
  }
}

function summaryText(fgHex, bgHex, r) {
  return fgHex + " on " + bgHex + " — " + r.ratioText + " (" + r.grade + "), " + r.lcText
}

// ---------- HSV / HSL (for the inline picker) ----------

function clamp01(v) { return Math.max(0, Math.min(1, v)) }

// h in degrees [0,360), s/v in [0,1]
function rgbToHsv(c) {
  var r = c.r / 255, g = c.g / 255, b = c.b / 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min
  var h = 0
  if (d > 0) {
    if (max === r) h = ((g - b) / d) % 6
    else if (max === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
    h *= 60
    if (h < 0) h += 360
  }
  return { h: h, s: max === 0 ? 0 : d / max, v: max }
}

function hsvToRgb(h, s, v) {
  h = ((h % 360) + 360) % 360
  s = clamp01(s); v = clamp01(v)
  var c = v * s, x = c * (1 - Math.abs((h / 60) % 2 - 1)), m = v - c
  var r, g, b
  if (h < 60) { r = c; g = x; b = 0 }
  else if (h < 120) { r = x; g = c; b = 0 }
  else if (h < 180) { r = 0; g = c; b = x }
  else if (h < 240) { r = 0; g = x; b = c }
  else if (h < 300) { r = x; g = 0; b = c }
  else { r = c; g = 0; b = x }
  return { r: Math.round((r + m) * 255), g: Math.round((g + m) * 255), b: Math.round((b + m) * 255) }
}

// h in degrees, s/l in [0,1]
function rgbToHsl(c) {
  var r = c.r / 255, g = c.g / 255, b = c.b / 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min
  var l = (max + min) / 2
  var s = d === 0 ? 0 : d / (1 - Math.abs(2 * l - 1))
  return { h: rgbToHsv(c).h, s: s, l: l }
}

function hslToRgb(h, s, l) {
  h = ((h % 360) + 360) % 360
  s = clamp01(s); l = clamp01(l)
  var c = (1 - Math.abs(2 * l - 1)) * s, x = c * (1 - Math.abs((h / 60) % 2 - 1)), m = l - c / 2
  var r, g, b
  if (h < 60) { r = c; g = x; b = 0 }
  else if (h < 120) { r = x; g = c; b = 0 }
  else if (h < 180) { r = 0; g = c; b = x }
  else if (h < 240) { r = 0; g = x; b = c }
  else if (h < 300) { r = x; g = 0; b = c }
  else { r = c; g = 0; b = x }
  return { r: Math.round((r + m) * 255), g: Math.round((g + m) * 255), b: Math.round((b + m) * 255) }
}

// ---------- OKLCH (fields in the picker) ----------

// Returns { L: 0..1, C: >=0, h: degrees 0..360 }
function rgbToOklch(c) {
  var lab = srgbToOklab(c)
  var C = Math.sqrt(lab.a * lab.a + lab.b * lab.b)
  var h = Math.atan2(lab.b, lab.a) * 180 / Math.PI
  if (h < 0) h += 360
  return { L: lab.L, C: C, h: h }
}

// Gamut-clamped (chroma reduced until the colour fits sRGB).
function oklchToRgb(L, C, hDeg) {
  var out = oklchToSrgb(Math.max(0, Math.min(1, L)), Math.max(0, C), hDeg * Math.PI / 180)
  return { r: Math.round(out.r), g: Math.round(out.g), b: Math.round(out.b) }
}
