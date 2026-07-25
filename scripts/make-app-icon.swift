#!/usr/bin/env swift
//
// Genera l'icona dell'applicazione (1024×1024, PNG opaco).
//
//   swift scripts/make-app-icon.swift Cryptera/Resources/Assets.xcassets/AppIcon.appiconset
//
// L'icona è **disegnata da codice**, non è un binario opaco committato: così
// resta modificabile senza uno strumento di grafica, e la revisione di una
// modifica è leggibile in diff come qualsiasi altro sorgente.
//
// Due vincoli dell'App Store che il disegno rispetta e che non vanno persi:
//
//   1. **Nessun canale alpha.** Il contesto è creato `noneSkipLast`, quindi il
//      PNG esce opaco. Un'icona con alpha viene rifiutata in fase di validazione.
//   2. **Nessun angolo arrotondato disegnato.** La maschera (superellisse) la
//      applica il sistema: disegnarla qui la farebbe applicare due volte,
//      lasciando un bordo rientrato.
//
// Cromaticamente deriva da `ui/styles.css` del desktop — `--accent` #35D0A1 e
// il fondo scuro dei pannelli — così le due applicazioni restano riconoscibili
// come la stessa cosa senza che iOS erediti il logo desktop, che a 60 px (la
// dimensione in Impostazioni e Spotlight) perde ogni dettaglio.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024

func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255,
            green: CGFloat((h >> 8) & 0xff) / 255,
            blue: CGFloat(h & 0xff) / 255, alpha: a)
}

/// Contesto opaco con origine in alto a sinistra (come gli strumenti di
/// disegno), invece dell'origine in basso a sinistra di Core Graphics.
func newContext() -> CGContext {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func fillLinear(_ ctx: CGContext, path: CGPath?, _ c0: CGColor, _ c1: CGColor,
                from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    if let path { ctx.addPath(path); ctx.clip() }
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [c0, c1] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
    ctx.restoreGState()
}

func radialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ c: CGColor) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}

/// Scudo: spalle squadrate con raccordo, punta in basso.
func shieldPath(cx: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let x0 = cx - w / 2, x1 = cx + w / 2
    let r = w * 0.17
    let shoulder = top + h * 0.50
    p.move(to: CGPoint(x: x0, y: top + r))
    p.addArc(tangent1End: CGPoint(x: x0, y: top), tangent2End: CGPoint(x: x0 + r, y: top), radius: r)
    p.addLine(to: CGPoint(x: x1 - r, y: top))
    p.addArc(tangent1End: CGPoint(x: x1, y: top), tangent2End: CGPoint(x: x1, y: top + r), radius: r)
    p.addLine(to: CGPoint(x: x1, y: shoulder))
    p.addCurve(to: CGPoint(x: cx, y: top + h),
               control1: CGPoint(x: x1, y: top + h * 0.80),
               control2: CGPoint(x: cx + w * 0.32, y: top + h * 0.94))
    p.addCurve(to: CGPoint(x: x0, y: shoulder),
               control1: CGPoint(x: cx - w * 0.32, y: top + h * 0.94),
               control2: CGPoint(x: x0, y: top + h * 0.80))
    p.closeSubpath()
    return p
}

/// Cartella: linguetta a sinistra, raccordo diagonale verso il corpo.
///
/// È il glifo scelto invece di un buco di serratura, che leggeva come "gestore
/// di password" — Cryptera cifra file e cartelle, non custodisce credenziali.
func folderPath(x0: CGFloat, y0: CGFloat, w: CGFloat, h: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let x1 = x0 + w, y1 = y0 + h
    let r = w * 0.09
    let tabW = w * 0.46, tabH = h * 0.19, slope = tabH * 0.7
    p.move(to: CGPoint(x: x0 + r, y: y0))
    p.addLine(to: CGPoint(x: x0 + tabW - r, y: y0))
    p.addArc(tangent1End: CGPoint(x: x0 + tabW, y: y0),
             tangent2End: CGPoint(x: x0 + tabW + slope, y: y0 + tabH), radius: r)
    p.addLine(to: CGPoint(x: x0 + tabW + slope, y: y0 + tabH))
    p.addLine(to: CGPoint(x: x1 - r, y: y0 + tabH))
    p.addArc(tangent1End: CGPoint(x: x1, y: y0 + tabH),
             tangent2End: CGPoint(x: x1, y: y0 + tabH + r), radius: r)
    p.addLine(to: CGPoint(x: x1, y: y1 - r))
    p.addArc(tangent1End: CGPoint(x: x1, y: y1), tangent2End: CGPoint(x: x1 - r, y: y1), radius: r)
    p.addLine(to: CGPoint(x: x0 + r, y: y1))
    p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0, y: y1 - r), radius: r)
    p.addLine(to: CGPoint(x: x0, y: y0 + r))
    p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + r, y: y0), radius: r)
    p.closeSubpath()
    return p
}

func draw(_ ctx: CGContext) {
    // Fondo: verde accento in gradiente, con un alone chiaro in alto a sinistra
    // che dà profondità senza introdurre dettaglio (invisibile a 60 px, ma non
    // dannoso).
    fillLinear(ctx, path: nil, hex(0x3FD8A8), hex(0x199C78),
               from: CGPoint(x: 0, y: 0), to: CGPoint(x: S, y: S))
    radialGlow(ctx, center: CGPoint(x: S * 0.28, y: S * 0.22), radius: S * 0.70,
               hex(0xFFFFFF, 0.20))

    // Scudo scuro. Il contrasto scuro-su-verde è ciò che tiene l'icona leggibile
    // alle dimensioni piccole: è il motivo per cui il glifo non è verde su verde.
    let shield = shieldPath(cx: S / 2, top: S * 0.175, w: S * 0.585, h: S * 0.655)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: S * 0.016), blur: S * 0.050,
                  color: hex(0x06302A, 0.40))
    ctx.addPath(shield); ctx.setFillColor(hex(0x16202B)); ctx.fillPath()
    ctx.restoreGState()
    fillLinear(ctx, path: shield, hex(0x22303F), hex(0x0E141B),
               from: CGPoint(x: S * 0.25, y: S * 0.17), to: CGPoint(x: S * 0.78, y: S * 0.83))

    // Cartella. Una sola forma piena, nessuna linea sottile: è l'unica scelta
    // che resta nitida quando l'icona è ridotta a 60 px.
    let w = S * 0.265, h = S * 0.225
    ctx.addPath(folderPath(x0: S / 2 - w / 2, y0: S * 0.315, w: w, h: h))
    ctx.setFillColor(hex(0x3FD8A8))
    ctx.fillPath()
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let outPath = "\(outDir)/AppIcon.png"

let ctx = newContext()
draw(ctx)
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("errore: impossibile creare \(outPath)\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("errore: scrittura di \(outPath) fallita\n".utf8))
    exit(1)
}
print("scritto \(outPath) (\(Int(S))×\(Int(S)), opaco)")
